// SQL-visible functions of the `spi` example, a port of pgrx's
// `pgrx-examples/spi`, plus prepared plans, cursors and subtransactions.
//
// Every function opens its own SPI connection. Values read through SPI are
// allocated in the SPI procedure context, which `spi.finish` frees, so text
// results are copied into the caller's memory context before returning.
//
// This file only defines the functions. main.zig exports them and schema.zig
// describes their SQL signatures and the example table.

const std = @import("std");
const pgzx = @import("pgzx");
const pg = pgzx.c;

const spi = pgzx.spi;

/// Copies `s` into `ctx` so it outlives the SPI connection.
fn dupeInto(ctx: pg.MemoryContext, s: []const u8) ![]const u8 {
    var ctx_alloc = pgzx.mem.MemoryContextAllocator.init(ctx, .{});
    return ctx_alloc.allocator().dupe(u8, s);
}

fn textArg(value: []const u8) !pg.NullableDatum {
    return pgzx.datum.toNullableDatum(value);
}

fn int8Arg(value: i64) !pg.NullableDatum {
    return pgzx.datum.toNullableDatum(value);
}

// Ported from pgrx-examples/spi
// =============================

pub fn spi_query_random_id() !?i64 {
    try spi.connect();
    defer spi.finish();

    var rows = try spi.queryTyped(i64, "SELECT id FROM spi.spi_example ORDER BY random() LIMIT 1", .{ .read_only = true });
    defer rows.deinit();
    return try rows.next();
}

pub fn spi_query_title(title: []const u8) !?i64 {
    try spi.connect();
    defer spi.finish();

    var rows = try spi.queryTyped(i64, "SELECT id FROM spi.spi_example WHERE title = $1", .{
        .read_only = true,
        .args = .{ .types = &.{pg.TEXTOID}, .values = &.{try textArg(title)} },
    });
    defer rows.deinit();
    return try rows.next();
}

pub fn spi_query_by_id(id: i64) !?[]const u8 {
    const caller = pg.CurrentMemoryContext;
    try spi.connect();
    defer spi.finish();

    var rows = try spi.query("SELECT id, title FROM spi.spi_example WHERE id = $1", .{
        .read_only = true,
        .args = .{ .types = &.{pg.INT8OID}, .values = &.{try int8Arg(id)} },
    });
    defer rows.deinit();
    if (!rows.next()) return null;

    var returned_id: i64 = undefined;
    var title: ?[]const u8 = undefined;
    try rows.scan(.{ &returned_id, &title });
    pgzx.elog.Info(@src(), "id={d}", .{returned_id});
    return if (title) |t| try dupeInto(caller, t) else null;
}

pub fn spi_insert_title(title: []const u8) !?i64 {
    try spi.connect();
    defer spi.finish();

    var rows = try spi.queryTyped(i64, "INSERT INTO spi.spi_example (title) VALUES ($1) RETURNING id", .{
        .args = .{ .types = &.{pg.TEXTOID}, .values = &.{try textArg(title)} },
    });
    defer rows.deinit();
    return try rows.next();
}

/// pgrx issue #1209: fetch a large batch through a cursor and read the first
/// row.
pub fn issue1209_fixed() !?[]const u8 {
    const caller = pg.CurrentMemoryContext;
    try spi.connect();
    defer spi.finish();

    const cursor = try spi.Cursor.open(null, "SELECT 'hello' FROM generate_series(1, 10000)", .{ .read_only = true });
    defer cursor.close();

    var rows = try cursor.fetchTyped([]const u8, 10000);
    defer rows.deinit();
    const first = (try rows.next()) orelse return null;
    return try dupeInto(caller, first);
}

// Prepared plans
// ==============

/// Prepared once per session. `keep` moves the plan out of the SPI procedure
/// context so it survives `spi.finish`.
var title_plan: ?spi.Plan = null;

fn titlePlan() !spi.Plan {
    if (title_plan) |p| return p;
    const p = try spi.Plan.prepare("SELECT title FROM spi.spi_example WHERE id = $1", &.{pg.INT8OID}, .{});
    try p.keep();
    title_plan = p;
    return p;
}

pub fn spi_title_by_id_cached(id: i64) !?[]const u8 {
    const caller = pg.CurrentMemoryContext;
    try spi.connect();
    defer spi.finish();

    const plan = try titlePlan();
    var rows = try plan.queryTyped(?[]const u8, &.{try int8Arg(id)}, .{ .read_only = true });
    defer rows.deinit();
    const title = (try rows.next()) orelse return null;
    return if (title) |t| try dupeInto(caller, t) else null;
}

// Cursors
// =======

/// Counts the rows of `query`, fetching `batch` rows at a time.
pub fn spi_cursor_count(query: [:0]const u8, batch: i32) !i64 {
    if (batch <= 0) return pgzx.elog.Error(@src(), "batch must be positive, got {d}", .{batch});

    try spi.connect();
    defer spi.finish();

    const cursor = try spi.Cursor.open(null, query, .{ .read_only = true });
    defer cursor.close();

    var total: i64 = 0;
    var batches: i32 = 0;
    while (true) {
        var rows = try cursor.fetch(batch);
        defer rows.deinit();
        var n: i64 = 0;
        while (rows.next()) n += 1;
        if (n == 0) break;
        total += n;
        batches += 1;
    }
    pgzx.elog.Info(@src(), "{d} rows in {d} batches", .{ total, batches });
    return total;
}

// Subtransactions
// ===============

fn insertOne(title: []const u8) !void {
    _ = try spi.exec("INSERT INTO spi.spi_example (title) VALUES ($1)", .{
        .args = .{ .types = &.{pg.TEXTOID}, .values = &.{try textArg(title)} },
    });
}

/// Inserts every title in its own subtransaction, like a PL/pgSQL
/// `BEGIN ... EXCEPTION` block: rows that fail (here the CHECK constraint on
/// empty titles) are skipped with a NOTICE, the rest are kept. Returns the
/// number of inserted rows.
pub fn spi_insert_titles(titles: []const []const u8) !i32 {
    try spi.connect();
    defer spi.finish();

    var inserted: i32 = 0;
    for (titles) |title| {
        var edata: ?*pg.ErrorData = null;
        spi.subtransaction(insertOne, .{title}, .{ .error_data = &edata }) catch |e| {
            const data = edata orelse return e;
            defer pg.FreeErrorData(data);
            pgzx.elog.Notice(@src(), "skipped \"{s}\": {s}", .{ title, std.mem.span(data.*.message) });
            continue;
        };
        inserted += 1;
    }
    return inserted;
}

// SECURITY DEFINER
// ================

/// Runs with the privileges of the extension owner; schema.zig pins its
/// search_path as recommended for SECURITY DEFINER functions.
pub fn spi_count_titles() !i64 {
    try spi.connect();
    defer spi.finish();

    var rows = try spi.queryTyped(i64, "SELECT count(*) FROM spi.spi_example", .{ .read_only = true });
    defer rows.deinit();
    return (try rows.next()) orelse 0;
}
