const std = @import("std");
const pgzx = @import("pgzx");
const pg = pgzx.c;

comptime {
    pgzx.fmgr.PG_MODULE_MAGIC();
}

const executor_start = pgzx.hooks.Hook(&pg.ExecutorStart_hook, pg.standard_ExecutorStart);
const executor_finish = pgzx.hooks.Hook(&pg.ExecutorFinish_hook, pg.standard_ExecutorFinish);
// ExecCheckPermissions() calls this hook before its own checks, and it returns
// early only when the hook denies. Calling ExecCheckPermissions from here would
// re-enter the hook, so the fallback is "no objection".
fn checkPermsAllow(rangeTables: [*c]pg.List, rtePermInfos: [*c]pg.List, violation: bool) callconv(.c) bool {
    _ = rangeTables;
    _ = rtePermInfos;
    _ = violation;
    return true;
}

fn checkPermsAllowPg15(rangeTables: [*c]pg.List, violation: bool) callconv(.c) bool {
    _ = rangeTables;
    _ = violation;
    return true;
}

const check_perms = if (pg.PG_VERSION_NUM >= 160000)
    pgzx.hooks.Hook(&pg.ExecutorCheckPerms_hook, checkPermsAllow)
else
    pgzx.hooks.Hook(&pg.ExecutorCheckPerms_hook, checkPermsAllowPg15);

pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = pgzx.elog.logFn,
};

const Commands = enum {
    CMD_UNKNOWN,
    CMD_SELECT,
    CMD_UPDATE,
    CMD_INSERT,
    CMD_DELETE,
    CMD_MERGE,
    CMD_UTILITY,
    CMD_NOTHING,
};

const AuditEvent = struct {
    command: Commands,
    commandText: []const u8,
    relations: ?std.ArrayList(RelEntry) = null,

    queryContext: ?pg.MemoryContext = null,

    memctx: pgzx.mem.MemoryContextAllocator,
};

const RelEntry = struct {
    rel_oid: pg.Oid,
    rel_name: []u8,
    rel_namespace_oid: pg.Oid,
    rel_namespace_name: []u8,
};

const EventsError = error{
    EventNotFound,
};

var audit_events_list: ?std.ArrayList(*AuditEvent) = null;
var global_memctx: pgzx.mem.MemoryContextAllocator = undefined;

const settings = struct {
    var log_statement: pgzx.guc.CustomBoolVariable = undefined;

    fn register() void {
        log_statement.register(.{
            .name = "pgaudit_zig.log_statement",
            .short_desc =
            \\ Specifies whether logging will include the statement text and
            \\ parameters. Depending on requirements, the full statement text might
            \\ not be required in the audit log. The default is true.
            ,
            .initial_value = true,
            .context = pg.PGC_SUSET,
        });
    }
};

pub export fn _PG_init() void {
    // Setup logging. We want to see all messages in the client session ;)
    pgzx.elog.options.postgresLogFnLeven = pg.LOG;

    settings.register();

    executor_start.install(pgaudit_zig_ExecutorStart_hook);
    executor_finish.install(pgaudit_zig_ExecutorFinish_hook);
    if (pg.PG_VERSION_NUM >= 160000) {
        check_perms.install(pgaudit_zig_ExecutorCheckPerms_hook);
    } else {
        check_perms.install(pgaudit_zig_ExecutorCheckPerms_hook_pg15);
    }

    std.log.debug("pgaudit_zig: hooks installed\n", .{});
}

// Return the session local list of audit events. Initialized the memory context and the list if necessary.
fn getAuditList() error{PGErrorStack}!*std.ArrayList(*AuditEvent) {
    if (audit_events_list) |*list| {
        return list;
    }

    // Create a memory context for the global list. The parent is TopMemoryContext, so it will never be destroyed.
    global_memctx = pgzx.mem.createAllocSetContext("pgaudit_zig_context_global", .{ .parent = pg.TopMemoryContext }) catch |err| {
        return pgzx.elog.Error(@src(), "pgaudit_zig: failed to create memory context: {}\n", .{err});
    };
    audit_events_list = std.ArrayList(*AuditEvent).empty;
    return &audit_events_list.?;
}

fn executorStartHook(queryDesc: [*c]pg.QueryDesc, eflags: c_int) !void {
    var memctx = try pgzx.mem.createAllocSetContext("pgaudit_zig_context", .{ .parent = pg.CurrentMemoryContext });
    const allocator = memctx.allocator();

    const commandText = try allocator.dupe(u8, std.mem.span(queryDesc.*.sourceText));

    const event = try allocator.create(AuditEvent);
    event.* = .{
        .command = @fromBackingInt(@intCast(queryDesc.*.operation)),
        .commandText = commandText,
        .memctx = memctx,
    };

    // The event's own context runs this callback when it is deleted. That also
    // covers an error inside the standard hook below, which never reaches the
    // code after it and would otherwise leave the event in the list.
    try memctx.registerAllocResetCallback(event, pgaudit_zig_MemoryContextCallback);

    var audit_list = try getAuditList();
    try audit_list.append(global_memctx.allocator(), event);

    executor_start.callNext(.{ queryDesc, eflags });

    // reading queryDesc.*.estate.*.es_query_cxt needs to happen *after* calling the standard hook.
    // However, we need the event in the list before calling the standard hook, because it calls the CheckPerms hook.
    event.queryContext = queryDesc.*.estate.*.es_query_cxt;
}

fn pgaudit_zig_ExecutorStart_hook(queryDesc: [*c]pg.QueryDesc, eflags: c_int) callconv(.c) void {
    std.log.debug("pgaudit_zig: ExecutorStart_hook\n", .{});

    executorStartHook(queryDesc, eflags) catch |err| {
        std.log.err("pgaudit_zig: failed to call executorStartHook: {}\n", .{err});
    };
}

fn executorCheckPermsHook(rangeTables: [*c]pg.List, violation: bool) error{ OutOfMemory, EventNotFound, PGErrorStack }!void {
    _ = violation;

    const list = try getAuditList();
    const event = list.last().?;
    var allocator = event.memctx.allocator();

    var relList = std.ArrayList(RelEntry).empty;
    errdefer relList.deinit(allocator);

    var errctx = pgzx.err.Context.init();
    defer errctx.deinit();
    if (errctx.pg_try()) {
        var it = pgzx.PointerListOf(pg.RangeTblEntry).initFrom(rangeTables).iterator();
        while (it.next()) |rte| {
            const relOid = rte.?.relid;
            const relNamespaceOid = pg.get_rel_namespace(relOid);

            if (pg.IsCatalogNamespace(relNamespaceOid) or relOid == 0 or relNamespaceOid == 0) {
                continue;
            }

            const namespaceName = pg.get_namespace_name(relNamespaceOid);
            const relName = pg.get_rel_name(relOid);

            const relEntry = RelEntry{
                .rel_oid = relOid,
                .rel_name = try allocator.dupe(u8, std.mem.span(relName)),
                .rel_namespace_oid = relNamespaceOid,
                .rel_namespace_name = try allocator.dupe(u8, std.mem.span(namespaceName)),
            };
            try relList.append(allocator, relEntry);

            std.log.debug("pgaudit_zig: ExecutorCheckPerms_hook: relNamespaceOid: {}, relOid: {}\n", .{ relNamespaceOid, relOid });
            std.log.debug("pgaudit_zig: ExecutorCheckPerms_hook: namespace: {s}, rel: {s}\n", .{ namespaceName, relName });
        }
        event.relations = relList;
    } else {
        return errctx.errorValue();
    }
}

fn executorCheckPermsHookImpl(rangeTables: [*c]pg.List, violation: bool) void {
    executorCheckPermsHook(rangeTables, violation) catch |err| {
        // Forward reported errors to the postgres error stack.
        pgzx.elog.throwAsPostgresError(@src(), err);
    };
}

// ExecutorCheckPerms_hook gained the rtePermInfos argument in PG16.
// Audit first, so denied attempts are still recorded, then let the standard
// permission check decide.
pub fn pgaudit_zig_ExecutorCheckPerms_hook(rangeTables: [*c]pg.List, rtePermInfos: [*c]pg.List, violation: bool) callconv(.c) bool {
    std.log.debug("pgaudit_zig: ExecutorCheckPerms_hook\n", .{});

    executorCheckPermsHookImpl(rangeTables, violation);
    return check_perms.callNext(.{ rangeTables, rtePermInfos, violation });
}

pub fn pgaudit_zig_ExecutorCheckPerms_hook_pg15(rangeTables: [*c]pg.List, violation: bool) callconv(.c) bool {
    std.log.debug("pgaudit_zig: ExecutorCheckPerms_hook\n", .{});

    executorCheckPermsHookImpl(rangeTables, violation);
    return check_perms.callNext(.{ rangeTables, violation });
}

fn pgaudit_zig_ExecutorFinish_hook(queryDesc: [*c]pg.QueryDesc) callconv(.c) void {
    std.log.debug("pgaudit_zig: ExecutorFinish_hook\n", .{});

    executor_finish.callNext(.{queryDesc});

    const queryContext = queryDesc.*.estate.*.es_query_cxt;

    const audit_list = getAuditList() catch |e| pgzx.elog.throwAsPostgresError(@src(), e);
    const event = popEvent(audit_list, queryContext) catch |err| {
        pgzx.elog.Log(@src(), "pgaudit_zig: failed to pop event from audit_events_list: {}\n", .{err});
        return;
    };
    defer freeEvent(event);

    logAuditEvent(event) catch |err| {
        std.log.err("pgaudit_zig: failed to log audit event: {}\n", .{err});
    };
}

fn popEvent(event_list: *std.ArrayList(*AuditEvent), memctx: pg.MemoryContext) error{EventNotFound}!*AuditEvent {
    const idx = try findEvent(event_list, memctx);
    return event_list.swapRemove(idx);
}

fn findEvent(event_list: *std.ArrayList(*AuditEvent), memctx: pg.MemoryContext) error{EventNotFound}!usize {
    for (event_list.items, 0..) |event, i| {
        if (event.queryContext) |cxt| {
            if (cxt == memctx) {
                return i;
            }
        }
    }
    return error.EventNotFound;
}

fn freeEvent(event: *AuditEvent) void {
    std.log.debug("pgaudit_zig: freeEvent\n", .{});

    // destroying the memory context frees everything we have allocated in it.
    var memctx = event.memctx;
    memctx.deinit();
}

// Runs while the event's context is being deleted, so the context must not be
// deleted again here. Removing the event from the list is enough: freeEvent has
// already done its part when the event was popped by ExecutorFinish.
fn pgaudit_zig_MemoryContextCallback(event: *AuditEvent) void {
    std.log.debug("pgaudit_zig: MemoryContextCallback\n", .{});

    const list = getAuditList() catch return;
    for (list.items, 0..) |item, i| {
        if (item == event) {
            _ = list.swapRemove(i);
            return;
        }
    }
}

fn eventToJSON(event: *AuditEvent, writer: *std.Io.Writer) !void {
    _ = try writer.write("{\"operation\": ");
    try std.json.Stringify.encodeJsonString(@tagName(event.command), .{}, writer);

    if (event.relations) |relations| {
        _ = try writer.write(", \"relations\": [");

        for (relations.items, 0..) |rel, i| {
            if (i != 0) {
                _ = try writer.write(", ");
            }
            _ = try writer.write("{");
            _ = try writer.write("\"relOid\": ");
            try writer.print("{d}", .{rel.rel_oid});
            _ = try writer.write(", \"relname\": ");
            try std.json.Stringify.encodeJsonString(rel.rel_name, .{}, writer);
            _ = try writer.write(", \"namespaceOid\": ");
            try writer.print("{d}", .{rel.rel_namespace_oid});
            _ = try writer.write(", \"relnamespaceName\": ");
            try std.json.Stringify.encodeJsonString(rel.rel_namespace_name, .{}, writer);
            _ = try writer.write("}");
        }
        _ = try writer.write("]");
    }

    if (settings.log_statement.value) {
        _ = try writer.write(", \"commandText\": ");
        try std.json.Stringify.encodeJsonString(event.commandText, .{}, writer);
    }
    _ = try writer.write("}");
}

fn logAuditEvent(event: *AuditEvent) !void {
    std.log.debug("pgaudit_zig: logAuditEvent\n", .{});

    var str_writer: std.Io.Writer.Allocating = .init(pgzx.mem.PGCurrentContextAllocator);
    defer str_writer.deinit();

    try eventToJSON(event, &str_writer.writer);
    try str_writer.writer.flush();

    std.log.debug("pgaudit_zig: logAuditEvent: {s}\n", .{str_writer.written()});
}

const Tests = struct {

    // Test that exercises adding, searching, and removing an event from the global list.
    pub fn testAddAndRemoveEvent() !void {
        var memctx = try pgzx.mem.createAllocSetContext("pgaudit_zig_tests_context", .{ .parent = pg.CurrentMemoryContext });
        defer memctx.deinit();
        const allocator = memctx.allocator();

        const query_ctx = memctx.context();

        const event = try allocator.create(AuditEvent);
        event.* = .{
            .command = Commands.CMD_SELECT,
            .commandText = "select test()",
            .memctx = memctx,
            .queryContext = query_ctx,
        };

        const list = try getAuditList();
        try list.append(global_memctx.allocator(), event);

        const last = list.last().?;
        try std.testing.expectEqual(event, last);

        const popped = try popEvent(list, query_ctx);
        try std.testing.expectEqual(event, popped);

        try std.testing.expectEqual(0, list.items.len);
    }

    // Test for eventToJSON function.
    pub fn testEventToJSON() !void {
        var memctx = try pgzx.mem.createAllocSetContext("pgaudit_zig_tests_context", .{ .parent = pg.CurrentMemoryContext });
        defer memctx.deinit();
        const allocator = memctx.allocator();

        var event = AuditEvent{
            .command = Commands.CMD_SELECT,
            .commandText = "select test()",
            .memctx = memctx,
        };

        var str_writer: std.Io.Writer.Allocating = .init(allocator);
        defer str_writer.deinit();

        try eventToJSON(&event, &str_writer.writer);
        try str_writer.writer.flush();

        const expected =
            \\{"operation": "CMD_SELECT", "commandText": "select test()"}
        ;
        try std.testing.expectEqualSlices(u8, expected, str_writer.written());
    }
};

comptime {
    pgzx.testing.registerTests(@import("build_options").testfn, .{Tests});
}
