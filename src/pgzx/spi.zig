const std = @import("std");
const pg = @import("pgzx_pgsys");

const meta = @import("meta.zig");
const mem = @import("mem.zig");
const err = @import("err.zig");
const datum = @import("datum.zig");

pub fn connect() err.PGError!void {
    const status = pg.SPI_connect();
    if (status == pg.SPI_ERROR_CONNECT) {
        return err.PGError.SPIConnectFailed;
    }
}

pub fn connectNonAtomic() err.PGError!void {
    const status = pg.SPI_connect_ext(pg.SPI_OPT_NONATOMIC);
    try checkStatus(status);
}

pub fn finish() void {
    _ = pg.SPI_finish();
}

pub const Args = struct {
    types: []const pg.Oid,
    values: []const pg.NullableDatum,

    pub fn has_nulls(self: *const Args) bool {
        for (self.values) |value| {
            if (value.isnull) {
                return true;
            }
        }
        return false;
    }
};

pub const ExecOptions = struct {
    read_only: bool = false,
    limit: c_long = 0,
    args: ?Args = null,
};

pub const SPIError = err.PGError || std.mem.Allocator.Error;

pub fn exec(sql: [:0]const u8, options: ExecOptions) SPIError!isize {
    _ = try execImpl(sql, options);
    var rows = Rows.init();
    defer rows.deinit();
    // SPI_execute returns a status code (SPI_OK_*), not the row count. The
    // number of rows affected/returned is exposed via the SPI_processed global.
    return @intCast(pg.SPI_processed);
}

pub fn query(sql: [:0]const u8, options: ExecOptions) SPIError!Rows {
    _ = try execImpl(sql, options);
    return Rows.init();
}

pub fn queryTyped(comptime T: type, sql: [:0]const u8, options: ExecOptions) SPIError!RowsOf(T) {
    const rows = try query(sql, options);
    return rows.typed(T);
}

fn execImpl(sql: [:0]const u8, options: ExecOptions) SPIError!c_int {
    if (options.args) |args| {
        if (args.types.len != args.values.len) {
            return err.PGError.SPIArgument;
        }

        var arena = std.heap.ArenaAllocator.init(mem.PGCurrentContextAllocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const n = args.types.len;
        const nulls: [*c]const u8 = blk: {
            if (args.has_nulls()) {
                var buf = try allocator.alloc(u8, n);
                for (args.values, 0..) |value, i| {
                    buf[i] = if (value.isnull) 'n' else ' ';
                }
                break :blk buf.ptr;
            } else {
                break :blk null;
            }
        };

        const values: [*c]pg.Datum = blk: {
            var buf = try allocator.alloc(pg.Datum, n);
            for (args.values, 0..) |arg, i| {
                buf[i] = arg.value;
            }
            break :blk buf.ptr;
        };

        const status = pg.SPI_execute_with_args(
            sql.ptr,
            @intCast(n),
            @constCast(args.types.ptr),
            values,
            nulls,
            options.read_only,
            options.limit,
        );
        try checkStatus(status);
        return status;
    } else {
        const status = pg.SPI_execute(sql.ptr, options.read_only, options.limit);
        try checkStatus(status);
        return status;
    }
}

// ---------------------------------------------------------------------------
// Prepared plans
// ---------------------------------------------------------------------------

/// Bound parameter values in the layout SPI expects. Allocated in the current
/// memory context; SPI copies what it needs, so `deinit` can run right after
/// the call.
const ParamBuffers = struct {
    arena: std.heap.ArenaAllocator,
    values: [*c]pg.Datum,
    nulls: [*c]const u8,

    fn init(params: []const pg.NullableDatum) SPIError!ParamBuffers {
        var self: ParamBuffers = .{
            .arena = std.heap.ArenaAllocator.init(mem.PGCurrentContextAllocator),
            .values = null,
            .nulls = null,
        };
        errdefer self.arena.deinit();
        if (params.len == 0) return self;

        const allocator = self.arena.allocator();
        const values = try allocator.alloc(pg.Datum, params.len);
        var has_nulls = false;
        for (params, 0..) |p, i| {
            values[i] = p.value;
            has_nulls = has_nulls or p.isnull;
        }
        self.values = values.ptr;
        if (has_nulls) {
            const nulls = try allocator.alloc(u8, params.len);
            for (params, 0..) |p, i| {
                nulls[i] = if (p.isnull) 'n' else ' ';
            }
            self.nulls = nulls.ptr;
        }
        return self;
    }

    fn deinit(self: *ParamBuffers) void {
        self.arena.deinit();
    }
};

pub const PrepareOptions = struct {
    /// `CURSOR_OPT_*` flags passed to `SPI_prepare_cursor`, e.g.
    /// `pg.CURSOR_OPT_SCROLL` for a plan that backs a scrollable cursor.
    cursor_options: c_int = 0,
};

pub const PlanExecOptions = struct {
    read_only: bool = false,
    limit: c_long = 0,
};

/// A prepared statement (`SPI_prepare`).
///
/// A plan lives in the SPI procedure context and is released by `finish`
/// unless `keep` moves it to a long-lived context. Kept plans must be released
/// with `deinit`.
pub const Plan = struct {
    ptr: pg.SPIPlanPtr,

    pub fn prepare(sql: [:0]const u8, arg_types: []const pg.Oid, options: PrepareOptions) SPIError!Plan {
        const ptr = try err.wrap(pg.SPI_prepare_cursor, .{
            sql.ptr,
            @as(c_int, @intCast(arg_types.len)),
            @as([*c]pg.Oid, @constCast(arg_types.ptr)),
            options.cursor_options,
        });
        if (ptr == null) {
            try checkStatus(pg.SPI_result);
            return err.PGError.SPIError;
        }
        return .{ .ptr = ptr };
    }

    /// Moves the plan out of the SPI procedure context so it survives
    /// `finish`, e.g. to cache it in a static for the rest of the session.
    pub fn keep(self: Plan) SPIError!void {
        try checkStatus(pg.SPI_keepplan(self.ptr));
    }

    pub fn deinit(self: Plan) void {
        _ = pg.SPI_freeplan(self.ptr);
    }

    pub fn argCount(self: Plan) usize {
        return @intCast(pg.SPI_getargcount(self.ptr));
    }

    /// Whether the plan returns rows and can back a cursor.
    pub fn isCursorPlan(self: Plan) bool {
        return pg.SPI_is_cursor_plan(self.ptr);
    }

    /// Executes the plan and returns the number of rows processed.
    pub fn exec(self: Plan, params: []const pg.NullableDatum, options: PlanExecOptions) SPIError!isize {
        try self.execImpl(params, options);
        var rows = Rows.init();
        defer rows.deinit();
        return @intCast(pg.SPI_processed);
    }

    pub fn query(self: Plan, params: []const pg.NullableDatum, options: PlanExecOptions) SPIError!Rows {
        try self.execImpl(params, options);
        return Rows.init();
    }

    pub fn queryTyped(self: Plan, comptime T: type, params: []const pg.NullableDatum, options: PlanExecOptions) SPIError!RowsOf(T) {
        const rows = try self.query(params, options);
        return rows.typed(T);
    }

    /// Opens a cursor for the plan. `name` `null` lets SPI pick a unique
    /// portal name.
    pub fn openCursor(self: Plan, name: ?[:0]const u8, params: []const pg.NullableDatum, options: CursorOptions) SPIError!Cursor {
        if (params.len != self.argCount()) return err.PGError.SPIArgument;
        var buffers = try ParamBuffers.init(params);
        defer buffers.deinit();
        const portal = try err.wrap(pg.SPI_cursor_open, .{
            optNamePtr(name),
            self.ptr,
            buffers.values,
            buffers.nulls,
            options.read_only,
        });
        return Cursor.fromPortal(portal);
    }

    fn execImpl(self: Plan, params: []const pg.NullableDatum, options: PlanExecOptions) SPIError!void {
        if (params.len != self.argCount()) return err.PGError.SPIArgument;
        var buffers = try ParamBuffers.init(params);
        defer buffers.deinit();
        const status = try err.wrap(pg.SPI_execute_plan, .{
            self.ptr,
            buffers.values,
            buffers.nulls,
            options.read_only,
            options.limit,
        });
        try checkStatus(status);
    }
};

// ---------------------------------------------------------------------------
// Cursors
// ---------------------------------------------------------------------------

pub const CursorOptions = struct {
    read_only: bool = false,
    /// `CURSOR_OPT_*` flags. Only used when the cursor is opened from SQL
    /// text; for a `Plan` pass them to `Plan.prepare`.
    cursor_options: c_int = 0,
    args: ?Args = null,
};

pub const FetchDirection = enum {
    forward,
    backward,
    absolute,
    relative,

    fn toPg(self: FetchDirection) pg.FetchDirection {
        return switch (self) {
            .forward => pg.FETCH_FORWARD,
            .backward => pg.FETCH_BACKWARD,
            .absolute => pg.FETCH_ABSOLUTE,
            .relative => pg.FETCH_RELATIVE,
        };
    }
};

/// An SPI cursor (portal). Rows are fetched in batches; every `fetch` replaces
/// `SPI_tuptable`, so the returned `Rows` must be consumed (and `deinit`ed)
/// before the next fetch.
pub const Cursor = struct {
    portal: pg.Portal,

    /// Opens a cursor for a SQL query. `name` `null` lets SPI pick a
    /// unique portal name.
    pub fn open(name: ?[:0]const u8, sql: [:0]const u8, options: CursorOptions) SPIError!Cursor {
        const args = options.args orelse Args{ .types = &.{}, .values = &.{} };
        if (args.types.len != args.values.len) return err.PGError.SPIArgument;
        var buffers = try ParamBuffers.init(args.values);
        defer buffers.deinit();
        const portal = try err.wrap(pg.SPI_cursor_open_with_args, .{
            optNamePtr(name),
            sql.ptr,
            @as(c_int, @intCast(args.types.len)),
            @as([*c]pg.Oid, @constCast(args.types.ptr)),
            buffers.values,
            buffers.nulls,
            options.read_only,
            options.cursor_options,
        });
        return fromPortal(portal);
    }

    /// Finds an open cursor by portal name.
    pub fn find(name: [:0]const u8) ?Cursor {
        const portal = pg.SPI_cursor_find(name.ptr);
        if (portal == null) return null;
        return .{ .portal = portal };
    }

    fn fromPortal(portal: pg.Portal) SPIError!Cursor {
        if (portal == null) {
            try checkStatus(pg.SPI_result);
            return err.PGError.SPIError;
        }
        return .{ .portal = portal };
    }

    pub fn portalName(self: Cursor) [:0]const u8 {
        return std.mem.span(self.portal.*.name);
    }

    /// Fetches up to `count` rows moving forward. An empty result means the
    /// cursor is exhausted.
    pub fn fetch(self: Cursor, count: c_long) SPIError!Rows {
        try err.wrap(pg.SPI_cursor_fetch, .{ self.portal, true, count });
        return Rows.init();
    }

    pub fn fetchBackward(self: Cursor, count: c_long) SPIError!Rows {
        try err.wrap(pg.SPI_cursor_fetch, .{ self.portal, false, count });
        return Rows.init();
    }

    pub fn fetchTyped(self: Cursor, comptime T: type, count: c_long) SPIError!RowsOf(T) {
        const rows = try self.fetch(count);
        return rows.typed(T);
    }

    /// Scrollable fetch; the plan must have been prepared with
    /// `pg.CURSOR_OPT_SCROLL`.
    pub fn scrollFetch(self: Cursor, direction: FetchDirection, count: c_long) SPIError!Rows {
        try err.wrap(pg.SPI_scroll_cursor_fetch, .{ self.portal, direction.toPg(), count });
        return Rows.init();
    }

    pub fn move(self: Cursor, forward: bool, count: c_long) SPIError!void {
        try err.wrap(pg.SPI_cursor_move, .{ self.portal, forward, count });
    }

    pub fn scrollMove(self: Cursor, direction: FetchDirection, count: c_long) SPIError!void {
        try err.wrap(pg.SPI_scroll_cursor_move, .{ self.portal, direction.toPg(), count });
    }

    pub fn close(self: Cursor) void {
        pg.SPI_cursor_close(self.portal);
    }
};

fn optNamePtr(name: ?[:0]const u8) [*c]const u8 {
    return if (name) |n| n.ptr else null;
}

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------

/// Commits the current transaction and starts a new one. Only valid in a
/// non-atomic context (a procedure connected via `connectNonAtomic`).
pub fn commit() err.ElogIndicator!void {
    try err.wrap(pg.SPI_commit, .{});
}

/// Rolls back the current transaction and starts a new one. Only valid in a
/// non-atomic context (a procedure connected via `connectNonAtomic`).
pub fn rollback() err.ElogIndicator!void {
    try err.wrap(pg.SPI_rollback, .{});
}

pub const SubtransactionOptions = struct {
    name: ?[:0]const u8 = null,
    /// When set and the body raised a Postgres error, receives a copy of the
    /// error (allocated in the caller's memory context; release it with
    /// `pg.FreeErrorData`). Otherwise the error data is discarded.
    error_data: ?*?*pg.ErrorData = null,
};

fn SubtransactionReturn(comptime F: type) type {
    const R = meta.fnReturnType(F);
    return switch (@typeInfo(R)) {
        .error_union => |eu| (eu.error_set || err.ElogIndicator)!eu.payload,
        else => err.ElogIndicator!R,
    };
}

/// Runs `@call(f, args)` inside an internal subtransaction, like a PL/pgSQL
/// `BEGIN ... EXCEPTION` block.
///
/// On success the subtransaction is released (its changes become part of the
/// outer transaction). If `f` returns a Zig error or raises a Postgres error,
/// the subtransaction is rolled back, the memory context and resource owner
/// are restored, the Postgres error state is flushed, and the error is
/// returned (`error.PGErrorStack` for Postgres errors). The outer transaction
/// stays usable either way.
pub fn subtransaction(comptime f: anytype, args: anytype, options: SubtransactionOptions) SubtransactionReturn(@TypeOf(f)) {
    const returns_error = comptime @typeInfo(meta.fnReturnType(@TypeOf(f))) == .error_union;

    const old_context = pg.CurrentMemoryContext;
    const old_owner = pg.CurrentResourceOwner;

    try err.wrap(pg.BeginInternalSubTransaction, .{optNamePtr(options.name)});
    // BeginInternalSubTransaction switches to the subtransaction's context;
    // keep allocating in the caller's context so results outlive it.
    _ = pg.MemoryContextSwitchTo(old_context);

    var errctx = err.Context.init();
    defer errctx.deinit();
    if (errctx.pg_try()) {
        const result = @call(.auto, f, args);
        if (returns_error) {
            if (result) |_| {} else |_| {
                // Leave the try block first: if the rollback itself raises,
                // it must propagate to the outer handler, not back here.
                errctx.pg_try_end();
                pg.RollbackAndReleaseCurrentSubTransaction();
                restoreSubtransactionState(old_context, old_owner);
                return result;
            }
        }
        pg.ReleaseCurrentSubTransaction();
        errctx.pg_try_end();
        restoreSubtransactionState(old_context, old_owner);
        return result;
    } else {
        errctx.pg_try_end();
        _ = pg.MemoryContextSwitchTo(old_context);
        const edata = pg.CopyErrorData();
        pg.FlushErrorState();
        pg.RollbackAndReleaseCurrentSubTransaction();
        restoreSubtransactionState(old_context, old_owner);
        if (options.error_data) |out| {
            out.* = edata;
        } else {
            pg.FreeErrorData(edata);
        }
        return error.PGErrorStack;
    }
}

fn restoreSubtransactionState(context: pg.MemoryContext, owner: pg.ResourceOwner) void {
    _ = pg.MemoryContextSwitchTo(context);
    pg.CurrentResourceOwner = owner;
}

fn scanProcessed(row: usize, values: anytype) !void {
    scanProcessedFrame(SPIFrame.get(), row, values);
}

inline fn scanProcessedFrame(frame: SPIFrame, row: usize, values: anytype) !void {
    var column: c_int = 1;
    inline for (std.meta.fields(@TypeOf(values)), 0..) |field, i| {
        column = try scanField(field.type, frame, values[i], row, column);
    }
}

fn scanField(
    comptime fieldType: type,
    frame: SPIFrame,
    to: anytype,
    row: usize,
    column: c_int,
) !c_int {
    if (!meta.isPointer(fieldType)) {
        @compileError("scanField requires a pointer");
    }

    const child_type = meta.pointerElemType(fieldType);
    if (@typeInfo(child_type) == .@"struct") {
        var struct_column = column;
        inline for (std.meta.fields(child_type)) |field| {
            const child_ptr = &@field(to.*, field.name);
            struct_column = try scanField(@TypeOf(child_ptr), frame, child_ptr, row, struct_column);
        }
        return struct_column;
    } else {
        const value = try convBinValue(child_type, frame, row, column);
        to.* = value;
        return column + 1;
    }
}

pub fn OwnedSPIFrameRows(comptime R: type) type {
    return struct {
        rows: R,

        const Self = @This();

        pub inline fn init(r: R) Self {
            return .{ .rows = r };
        }

        pub inline fn deinit(self: *Self) void {
            self.rows.deinit();
            finish();
        }

        pub fn next(self: *Self) meta.fnReturnType(@TypeOf(R.next)) {
            return self.rows.next();
        }

        pub const scan = if (@hasField(R, "scan"))
            R.scan
        else
            @compileError("no scan method available");
    };
}

// Rows iterates over SPI_tuptable from the last executed SPI query.
// When initializing a Rows iterator we capture the current SPI_tuptable from
// the active SPI frame.
//
// Safety:
// =======
//
// The underlying tuple table is released when the current frame is released
// via `finish`. The iterator must not be used after. We have no way to check
// if the current frame was released or not. Accessing the tuple table after a
// release will result in undefined behavior.
//
// Due to SPI managing a stack of SPI frames it is safe to use `connect` to
// create a child frame to run queries while iterating over the rows.
//
pub const Rows = struct {
    row: isize,
    spi_frame: SPIFrame,

    fn init() Rows {
        return .{
            .row = -1,
            .spi_frame = SPIFrame.get(),
        };
    }

    fn typed(self: Rows, comptime T: type) RowsOf(T) {
        return RowsOf(T).init(self);
    }

    fn ownedSPIFrame(self: Rows) OwnedSPIFrameRows(Rows) {
        return OwnedSPIFrameRows(Rows).init(self);
    }

    pub fn deinit(self: *Rows) void {
        if (self.spi_frame.tuptable) |tt| {
            pg.SPI_freetuptable(tt);
        }
        self.row = -1;
    }

    pub fn next(self: *Rows) bool {
        const next_idx = self.row + 1;
        if (self.spi_frame.tuptable == null or next_idx >= self.spi_frame.processed) {
            return false;
        }
        self.row = next_idx;
        return true;
    }

    pub fn scan(self: *Rows, values: anytype) !void {
        if (self.row < 0) {
            return err.PGError.SPIInvalidRowIndex;
        }
        try scanProcessedFrame(self.spi_frame, @intCast(self.row), values);
    }
};

pub fn RowsOf(comptime T: type) type {
    return struct {
        rows: Rows,

        const Self = @This();
        pub const Owned = OwnedSPIFrameRows(Self);

        pub fn init(rows: Rows) Self {
            return .{ .rows = rows };
        }

        pub fn deinit(self: *Self) void {
            self.rows.deinit();
        }

        pub fn ownedSPIFrame(self: Self) Self.Owned {
            return OwnedSPIFrameRows(Self).init(self);
        }

        pub fn next(self: *Self) !?T {
            if (!self.rows.next()) {
                return null;
            }
            var value: T = undefined;
            try self.rows.scan(.{&value});
            return value;
        }
    };
}

// The SPI interface uses a
const SPIFrame = struct {
    processed: u64,
    tuptable: ?*pg.SPITupleTable,

    inline fn get() SPIFrame {
        return .{
            .processed = pg.SPI_processed,
            .tuptable = pg.SPI_tuptable,
        };
    }
};

pub fn convProcessed(comptime T: type, row: c_int, col: c_int) !T {
    if (pg.SPI_processed <= row) {
        return err.PGError.SPIInvalidRowIndex;
    }
    return convBinValue(T, SPIFrame.get(), row, col);
}

pub fn convBinValue(comptime T: type, frame: SPIFrame, row: usize, col: c_int) !T {
    // TODO: check index?

    var nd: pg.NullableDatum = undefined;
    const table = frame.tuptable.?;
    const desc = table.*.tupdesc;
    nd.value = pg.SPI_getbinval(table.*.vals[row], desc, col, @ptrCast(&nd.isnull));
    try checkStatus(pg.SPI_result);
    // SPI_gettypeid instead of poking TupleDescData.attrs: PG18 moved to
    // compact attributes and the translated TupleDescAttr helper is broken.
    const oid = pg.SPI_gettypeid(desc, col);
    return try datum.fromNullableDatumWithOID(T, nd, oid);
}

fn checkStatus(st: c_int) err.PGError!void {
    switch (st) {
        pg.SPI_ERROR_CONNECT => return err.PGError.SPIConnectFailed,
        pg.SPI_ERROR_ARGUMENT => return err.PGError.SPIArgument,
        pg.SPI_ERROR_COPY => return err.PGError.SPICopy,
        pg.SPI_ERROR_TRANSACTION => return err.PGError.SPITransaction,
        pg.SPI_ERROR_OPUNKNOWN => return err.PGError.SPIOpUnknown,
        pg.SPI_ERROR_UNCONNECTED => return err.PGError.SPIUnconnected,
        pg.SPI_ERROR_NOATTRIBUTE => return err.PGError.SPINoAttribute,
        else => {
            if (st < 0) {
                return err.PGError.SPIError;
            }
        },
    }
}

pub const TestSuite_Spi = struct {
    pub fn testExecSelect() !void {
        try connect();
        defer finish();

        const count = try exec("SELECT 1", .{});
        try std.testing.expectEqual(@as(isize, 1), count);
    }

    pub fn testPlanExec() !void {
        try connect();
        defer finish();

        const plan = try Plan.prepare("SELECT $1::int4 + 1", &.{pg.INT4OID}, .{});
        try std.testing.expectEqual(@as(usize, 1), plan.argCount());
        try std.testing.expect(plan.isCursorPlan());

        var rows = try plan.queryTyped(i32, &.{try datum.toNullableDatum(@as(i32, 41))}, .{ .read_only = true });
        defer rows.deinit();
        try std.testing.expectEqual(@as(i32, 42), (try rows.next()).?);
    }

    pub fn testPlanArgCountMismatch() !void {
        try connect();
        defer finish();

        const plan = try Plan.prepare("SELECT $1::int4", &.{pg.INT4OID}, .{});
        try std.testing.expectError(err.PGError.SPIArgument, plan.exec(&.{}, .{}));
    }

    pub fn testCursorFetchBatches() !void {
        try connect();
        defer finish();

        const cursor = try Cursor.open(null, "SELECT g FROM generate_series(1, 5) g", .{ .read_only = true });
        defer cursor.close();

        var total: i32 = 0;
        var batches: usize = 0;
        while (true) {
            var rows = try cursor.fetchTyped(i32, 2);
            defer rows.deinit();
            var n: usize = 0;
            while (try rows.next()) |v| {
                total += v;
                n += 1;
            }
            if (n == 0) break;
            batches += 1;
        }
        try std.testing.expectEqual(@as(i32, 15), total);
        try std.testing.expectEqual(@as(usize, 3), batches);
    }

    pub fn testCursorFind() !void {
        try connect();
        defer finish();

        const cursor = try Cursor.open("pgzx_test_cursor", "SELECT 1", .{ .read_only = true });
        defer cursor.close();
        const found = Cursor.find("pgzx_test_cursor") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("pgzx_test_cursor", found.portalName());
    }

    fn failingStatement() !void {
        _ = try exec("SELECT 1/0", .{});
    }

    fn zigFailure() !void {
        _ = try exec("CREATE TEMP TABLE pgzx_subxact_zig (v int)", .{});
        return error.TestExpectedFailure;
    }

    fn successfulStatement() !isize {
        return exec("CREATE TEMP TABLE pgzx_subxact_ok (v int)", .{});
    }

    pub fn testSubtransactionCatchesPgError() !void {
        try connect();
        defer finish();

        var edata: ?*pg.ErrorData = null;
        const result = subtransaction(failingStatement, .{}, .{ .error_data = &edata });
        try std.testing.expectError(error.PGErrorStack, result);
        const e = edata orelse return error.TestUnexpectedResult;
        defer pg.FreeErrorData(e);
        try std.testing.expectEqual(@as(c_int, pg.ERRCODE_DIVISION_BY_ZERO), e.*.sqlerrcode);

        // The outer transaction is still usable.
        try std.testing.expectEqual(@as(isize, 1), try exec("SELECT 1", .{}));
    }

    pub fn testSubtransactionRollsBackOnZigError() !void {
        try connect();
        defer finish();

        try std.testing.expectError(error.TestExpectedFailure, subtransaction(zigFailure, .{}, .{}));
        var rows = try queryTyped(i64, "SELECT count(*) FROM pg_class WHERE relname = 'pgzx_subxact_zig'", .{});
        defer rows.deinit();
        try std.testing.expectEqual(@as(i64, 0), (try rows.next()).?);
    }

    pub fn testSubtransactionReleases() !void {
        try connect();
        defer finish();

        _ = try subtransaction(successfulStatement, .{}, .{});
        var rows = try queryTyped(i64, "SELECT count(*) FROM pg_class WHERE relname = 'pgzx_subxact_ok'", .{});
        defer rows.deinit();
        try std.testing.expectEqual(@as(i64, 1), (try rows.next()).?);
        _ = try exec("DROP TABLE pgzx_subxact_ok", .{});
    }

    pub fn testQueryTyped() !void {
        try connect();
        defer finish();

        var rows = try queryTyped(i32, "SELECT 42::int4", .{});
        defer rows.deinit();

        const value = (try rows.next()) orelse unreachable;
        try std.testing.expectEqual(@as(i32, 42), value);
    }
};
