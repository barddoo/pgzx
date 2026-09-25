// SQL-visible functions for the `compress_zig` example.
//
// This module is kept free of export/registration calls so the SQL schema
// generator (schema.zig) can introspect the signatures without linking the
// Postgres server. The registrations live in main.zig.
//
// The implementation follows a data-oriented layout:
//
//   * Values are stored structure-of-arrays: one typed, contiguous buffer per
//     column, never a row-at-a-time tagged value.
//   * Nulls are a packed bitmap per column (compression.NullBitmapBuilder),
//     not a []bool.
//   * The runtime type tag is resolved once per column. The per-row loops are
//     monomorphic (see ColumnBuffer.scan and appendColumnJson), so there is no
//     union switch inside the hot cell loop.
//
// The example compresses any heap table into a sidecar relation
// `_compress_zig.batches`, storing one encoded batch blob per row, and
// decompresses it back into a JSON array of row objects. It is a small,
// readable demonstration of the on-disk format in compression.zig; it is not a
// transparent access-method implementation.

const std = @import("std");
const pgzx = @import("pgzx");
const pg = pgzx.c;

const compression = @import("compression.zig");
const enc = @import("compression/encoding.zig");

const Kind = enc.Kind;
const Column = enc.Column;
const EncodedColumn = enc.EncodedColumn;
const Decoded = enc.Decoded;
const NullBitmapBuilder = compression.NullBitmapBuilder;

/// Rows grouped into one batch before encoding.
const BATCH_SIZE: usize = 1000;

/// Where the compressed batches live. Created lazily by `compress_table`.
const SIDECAR_SCHEMA = "_compress_zig";
const SIDECAR_TABLE = "_compress_zig.batches";

/// text type OID. Hardcoded to avoid depending on the translated pg_type
/// header exposing TEXTOID; the value is stable across all supported versions.
const TEXTOID: pg.Oid = 25;
const TEXTOID_ARRAY = [_]pg.Oid{TEXTOID};

// ---------------------------------------------------------------------------
// Small helpers over the SPI C API
// ---------------------------------------------------------------------------

fn cstr(p: [*c]const u8) []const u8 {
    if (p == null) return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

// Results are read straight from SPI_tuptable, so queries whose rows are used
// run through `spi.query`, which leaves the tuple table in place until
// spi.finish. (`spi.exec` frees it, and SPI_freetuptable resets
// SPI_tuptable to NULL.)
fn currentTable() !*pg.SPITupleTable {
    return pg.SPI_tuptable orelse error.NoSPIResult;
}

fn kindFromOid(oid: i64) Kind {
    if (oid < 0) return .bytes;
    return enc.kindForOid(@intCast(oid)) orelse .bytes;
}

const Resolved = struct {
    oid: i64,
    qualified: [:0]const u8,
};

/// Resolve a relation name to its OID and a safely quoted, schema-qualified
/// SQL name. The raw `rel` text is passed as a bound parameter and cast to
/// `regclass`, so it never reaches the SQL parser unquoted.
fn resolveRelation(alloc: std.mem.Allocator, rel: [:0]const u8) !Resolved {
    const rel_datum = try pgzx.datum.sliceToDatumTextZ(rel);
    const values = [_]pg.NullableDatum{.{ .value = rel_datum, .isnull = false }};

    _ = try pgzx.spi.query(
        "SELECT c.oid::int8, quote_ident(n.nspname) || '.' || quote_ident(c.relname) " ++
            "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " ++
            "WHERE c.oid = $1::regclass",
        .{ .args = .{ .types = &TEXTOID_ARRAY, .values = &values } },
    );

    const tt = try currentTable();
    if (pg.SPI_processed == 0) {
        return pgzx.elog.Error(@src(), "compress_zig: relation \"{s}\" not found", .{rel});
    }
    const desc = tt.tupdesc;
    const oid = try std.fmt.parseInt(i64, cstr(pg.SPI_getvalue(tt.vals[0], desc, 1)), 10);
    const qualified = pg.SPI_getvalue(tt.vals[0], desc, 2);
    if (qualified == null) {
        return pgzx.elog.Error(@src(), "compress_zig: could not resolve relation \"{s}\"", .{rel});
    }
    return .{ .oid = oid, .qualified = try alloc.dupeZ(u8, cstr(qualified)) };
}

const ColumnMeta = struct {
    name: []const u8,
    kind: Kind,
};

/// Read column names and codec kinds from the catalog for a relation.
fn loadColumns(alloc: std.mem.Allocator, oid: i64) ![]ColumnMeta {
    const sql = try std.fmt.allocPrintSentinel(
        alloc,
        "SELECT a.attname, a.atttypid::int8 FROM pg_attribute a " ++
            "WHERE a.attrelid = {d} AND a.attnum > 0 AND NOT a.attisdropped " ++
            "ORDER BY a.attnum",
        .{oid},
        0,
    );
    _ = try pgzx.spi.query(sql, .{});

    const tt = try currentTable();
    const n: usize = @intCast(pg.SPI_processed);
    const desc = tt.tupdesc;
    const out = try alloc.alloc(ColumnMeta, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const name = try alloc.dupe(u8, cstr(pg.SPI_getvalue(tt.vals[i], desc, 1)));
        const type_oid = try std.fmt.parseInt(i64, cstr(pg.SPI_getvalue(tt.vals[i], desc, 2)), 10);
        out[i] = .{ .name = name, .kind = kindFromOid(type_oid) };
    }
    return out;
}

fn ensureStorage() !void {
    _ = try pgzx.spi.exec("CREATE SCHEMA IF NOT EXISTS " ++ SIDECAR_SCHEMA, .{});
    _ = try pgzx.spi.exec(
        "CREATE TABLE IF NOT EXISTS " ++ SIDECAR_TABLE ++ " (" ++
            "relid oid NOT NULL, batch_id int NOT NULL, row_count int NOT NULL, " ++
            "data bytea NOT NULL, PRIMARY KEY (relid, batch_id))",
        .{},
    );
}

// ---------------------------------------------------------------------------
// Column buffers (structure-of-arrays)
// ---------------------------------------------------------------------------

fn parseScalar(comptime T: type, s: []const u8) !T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, s, 10),
        .float => std.fmt.parseFloat(T, s),
        .bool => s.len > 0 and s[0] == 't',
        else => @compileError("parseScalar: unsupported type " ++ @typeName(T)),
    };
}

/// Append one whole column of values, parsed from the SPI tuptable.
///
/// This is instantiated once per column, so the loop body is monomorphic: no
/// type tag is examined per cell.
fn scanInto(
    comptime T: type,
    alloc: std.mem.Allocator,
    tt: *pg.SPITupleTable,
    nrows: usize,
    col: usize,
    list: *std.ArrayList(T),
    nulls: *NullBitmapBuilder,
) !void {
    const desc = tt.tupdesc;
    try list.ensureTotalCapacity(alloc, nrows);

    var r: usize = 0;
    while (r < nrows) : (r += 1) {
        // SPI column numbers are 1-based.
        const raw = pg.SPI_getvalue(tt.vals[r], desc, @intCast(col + 1));
        try nulls.append(raw == null);

        if (comptime T == []const u8) {
            try list.append(alloc, if (raw == null) "" else try alloc.dupe(u8, cstr(raw)));
        } else {
            try list.append(alloc, if (raw == null) std.mem.zeroes(T) else try parseScalar(T, cstr(raw)));
        }
    }
}

/// One contiguous buffer per column. The tag is consulted when the buffer is
/// created and when a batch window is encoded, never per value.
const ColumnBuffer = union(enum) {
    i16: std.ArrayList(i16),
    i32: std.ArrayList(i32),
    i64: std.ArrayList(i64),
    f32: std.ArrayList(f32),
    f64: std.ArrayList(f64),
    boolean: std.ArrayList(bool),
    bytes: std.ArrayList([]const u8),

    fn init(kind: Kind) ColumnBuffer {
        return switch (kind) {
            .i16 => .{ .i16 = .empty },
            .i32 => .{ .i32 = .empty },
            .i64 => .{ .i64 = .empty },
            .f32 => .{ .f32 = .empty },
            .f64 => .{ .f64 = .empty },
            .boolean => .{ .boolean = .empty },
            .bytes => .{ .bytes = .empty },
        };
    }

    fn scan(
        self: *ColumnBuffer,
        alloc: std.mem.Allocator,
        tt: *pg.SPITupleTable,
        nrows: usize,
        col: usize,
        nulls: *NullBitmapBuilder,
    ) !void {
        switch (self.*) {
            .i16 => |*l| try scanInto(i16, alloc, tt, nrows, col, l, nulls),
            .i32 => |*l| try scanInto(i32, alloc, tt, nrows, col, l, nulls),
            .i64 => |*l| try scanInto(i64, alloc, tt, nrows, col, l, nulls),
            .f32 => |*l| try scanInto(f32, alloc, tt, nrows, col, l, nulls),
            .f64 => |*l| try scanInto(f64, alloc, tt, nrows, col, l, nulls),
            .boolean => |*l| try scanInto(bool, alloc, tt, nrows, col, l, nulls),
            .bytes => |*l| try scanInto([]const u8, alloc, tt, nrows, col, l, nulls),
        }
    }

    fn encode(self: *ColumnBuffer, alloc: std.mem.Allocator, start: usize, end: usize) !EncodedColumn {
        return switch (self.*) {
            .i16 => |*l| enc.encodeColumn(alloc, .{ .i16 = l.items[start..end] }),
            .i32 => |*l| enc.encodeColumn(alloc, .{ .i32 = l.items[start..end] }),
            .i64 => |*l| enc.encodeColumn(alloc, .{ .i64 = l.items[start..end] }),
            .f32 => |*l| enc.encodeColumn(alloc, .{ .f32 = l.items[start..end] }),
            .f64 => |*l| enc.encodeColumn(alloc, .{ .f64 = l.items[start..end] }),
            .boolean => |*l| enc.encodeColumn(alloc, .{ .boolean = l.items[start..end] }),
            .bytes => |*l| enc.encodeColumn(alloc, .{ .bytes = l.items[start..end] }),
        };
    }
};

// ---------------------------------------------------------------------------
// SQL functions
// ---------------------------------------------------------------------------

/// Compress a table into the sidecar relation. Returns the number of rows
/// written and is idempotent: any previous batches for the relation are
/// dropped first.
pub fn compress_table(rel: [:0]const u8) !i64 {
    try pgzx.spi.connect();
    defer pgzx.spi.finish();
    const alloc = pgzx.mem.PGCurrentContextAllocator;

    const res = try resolveRelation(alloc, rel);
    try ensureStorage();
    const cols = try loadColumns(alloc, res.oid);

    // Structure-of-arrays: one buffer and one null bitmap per column.
    const buffers = try alloc.alloc(ColumnBuffer, cols.len);
    const nulls = try alloc.alloc(NullBitmapBuilder, cols.len);
    for (cols, 0..) |col, i| {
        buffers[i] = ColumnBuffer.init(col.kind);
        nulls[i] = NullBitmapBuilder.init(alloc);
    }

    const scan_sql = try std.fmt.allocPrintSentinel(alloc, "SELECT * FROM {s}", .{res.qualified}, 0);
    _ = try pgzx.spi.query(scan_sql, .{});
    const tt = try currentTable();
    const nrows: usize = @intCast(pg.SPI_processed);

    // Column-major fill: each buffer is filled by one monomorphic loop.
    for (buffers, 0..) |*buf, c| {
        try buf.scan(alloc, tt, nrows, c, &nulls[c]);
    }

    const del = try std.fmt.allocPrintSentinel(
        alloc,
        "DELETE FROM " ++ SIDECAR_TABLE ++ " WHERE relid = {d}",
        .{res.oid},
        0,
    );
    _ = try pgzx.spi.exec(del, .{});

    const encoded = try alloc.alloc(EncodedColumn, cols.len);
    const null_views = try alloc.alloc(?[]const u8, cols.len);
    var blob_alloc = std.heap.ArenaAllocator.init(alloc);
    defer blob_alloc.deinit();
    const scratch = blob_alloc.allocator();

    var batch_id: i64 = 0;
    var start: usize = 0;
    while (start < nrows) : (start += BATCH_SIZE) {
        _ = blob_alloc.reset(.retain_capacity);

        const end = @min(start + BATCH_SIZE, nrows);
        const count = end - start;

        for (buffers, 0..) |*buf, c| {
            encoded[c] = try buf.encode(scratch, start, end);
            null_views[c] = nulls[c].view();
            // The bitmap covers all rows; slice it down to this batch window.
            if (null_views[c]) |bits| {
                null_views[c] = try sliceBitmap(scratch, bits, start, count);
            }
        }

        const blob = try compression.writeBatch(scratch, @intCast(count), encoded, null_views);
        try insertBatch(alloc, res.oid, batch_id, count, blob);
        batch_id += 1;
    }

    return @intCast(nrows);
}

/// Copy a bit sub-range [start, start+count) out of a packed bitmap into a new
/// bitmap starting at bit 0. Used when a batch is a window of the full column.
fn sliceBitmap(alloc: std.mem.Allocator, bits: []const u8, start: usize, count: usize) ![]u8 {
    const out = try alloc.alloc(u8, compression.nullBitmapLen(@intCast(count)));
    @memset(out, 0);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (compression.isNull(bits, start + i)) {
            out[i / 8] |= (@as(u8, 1) << @intCast(i % 8));
        }
    }
    return out;
}

fn insertBatch(alloc: std.mem.Allocator, oid: i64, batch_id: i64, row_count: usize, blob: []const u8) !void {
    const digits = "0123456789abcdef";
    const hex = try alloc.alloc(u8, blob.len * 2);
    for (blob, 0..) |b, i| {
        hex[i * 2] = digits[b >> 4];
        hex[i * 2 + 1] = digits[b & 0x0f];
    }

    const sql = try std.fmt.allocPrintSentinel(
        alloc,
        "INSERT INTO " ++ SIDECAR_TABLE ++ "(relid, batch_id, row_count, data) " ++
            "VALUES ({d}, {d}, {d}, decode('{s}', 'hex'))",
        .{ oid, batch_id, row_count, hex },
        0,
    );
    _ = try pgzx.spi.exec(sql, .{});
}

/// Number of batches stored for a relation.
pub fn batch_count(rel: [:0]const u8) !i64 {
    try pgzx.spi.connect();
    defer pgzx.spi.finish();
    const alloc = pgzx.mem.PGCurrentContextAllocator;
    const res = try resolveRelation(alloc, rel);
    try ensureStorage();

    const sql = try std.fmt.allocPrintSentinel(
        alloc,
        "SELECT count(*)::int8 FROM " ++ SIDECAR_TABLE ++ " WHERE relid = {d}",
        .{res.oid},
        0,
    );
    _ = try pgzx.spi.query(sql, .{});
    const tt = try currentTable();
    return std.fmt.parseInt(i64, cstr(pg.SPI_getvalue(tt.vals[0], tt.tupdesc, 1)), 10);
}

/// Total size in bytes of the compressed payloads for a relation.
pub fn compressed_size(rel: [:0]const u8) !i64 {
    try pgzx.spi.connect();
    defer pgzx.spi.finish();
    const alloc = pgzx.mem.PGCurrentContextAllocator;
    const res = try resolveRelation(alloc, rel);
    try ensureStorage();

    const sql = try std.fmt.allocPrintSentinel(
        alloc,
        "SELECT COALESCE(sum(octet_length(data)), 0)::int8 FROM " ++ SIDECAR_TABLE ++ " WHERE relid = {d}",
        .{res.oid},
        0,
    );
    _ = try pgzx.spi.query(sql, .{});
    const tt = try currentTable();
    return std.fmt.parseInt(i64, cstr(pg.SPI_getvalue(tt.vals[0], tt.tupdesc, 1)), 10);
}

/// Decompress a relation back into a JSON array of row objects.
///
/// Example:
///   SELECT jsonb_array_elements(decompress_table('events')::jsonb);
pub fn decompress_table(rel: [:0]const u8) ![:0]const u8 {
    // Everything allocated while connected lives in the SPI procedure context
    // and is freed by spi.finish; the JSON result is copied out to `caller`.
    var caller = pgzx.mem.MemoryContextAllocator.init(pg.CurrentMemoryContext, .{});
    try pgzx.spi.connect();
    defer pgzx.spi.finish();
    const alloc = pgzx.mem.PGCurrentContextAllocator;
    const res = try resolveRelation(alloc, rel);
    const cols = try loadColumns(alloc, res.oid);

    const sql = try std.fmt.allocPrintSentinel(
        alloc,
        "SELECT row_count, data FROM " ++ SIDECAR_TABLE ++ " WHERE relid = {d} ORDER BY batch_id",
        .{res.oid},
        0,
    );
    _ = try pgzx.spi.query(sql, .{});

    const tt = try currentTable();
    const nbatches: usize = @intCast(pg.SPI_processed);
    const desc = tt.tupdesc;

    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '[');
    var first_row = true;

    var bi: usize = 0;
    while (bi < nbatches) : (bi += 1) {
        const row_count = try std.fmt.parseInt(usize, cstr(pg.SPI_getvalue(tt.vals[bi], desc, 1)), 10);
        const raw = try hexToBytes(alloc, cstr(pg.SPI_getvalue(tt.vals[bi], desc, 2)));

        const view = try compression.BatchView.init(raw);
        const decoded = try alloc.alloc(Decoded, view.col_count);
        const nullmaps = try alloc.alloc(?[]const u8, view.col_count);
        for (0..view.col_count) |c| {
            decoded[c] = try view.decode(c, alloc);
            nullmaps[c] = try view.nullBitmap(c);
        }

        // Column-major emission into one small buffer per row. Each column is
        // dispatched once; the inner loop over rows is monomorphic.
        const rows = try alloc.alloc(std.ArrayList(u8), row_count);
        for (rows) |*b| b.* = .empty;
        for (rows) |*b| try b.append(alloc, '{');

        for (0..view.col_count) |c| {
            const name = if (c < cols.len) cols[c].name else "column";
            switch (decoded[c]) {
                .i16 => |v| try appendColumnJson(i16, alloc, rows, v, nullmaps[c], name, c == 0),
                .i32 => |v| try appendColumnJson(i32, alloc, rows, v, nullmaps[c], name, c == 0),
                .i64 => |v| try appendColumnJson(i64, alloc, rows, v, nullmaps[c], name, c == 0),
                .f32 => |v| try appendColumnJson(f32, alloc, rows, v, nullmaps[c], name, c == 0),
                .f64 => |v| try appendColumnJson(f64, alloc, rows, v, nullmaps[c], name, c == 0),
                .boolean => |v| try appendColumnJson(bool, alloc, rows, v, nullmaps[c], name, c == 0),
                .bytes => |v| try appendColumnJson([]const u8, alloc, rows, v, nullmaps[c], name, c == 0),
            }
        }

        for (rows) |*b| {
            try b.append(alloc, '}');
            if (!first_row) try out.append(alloc, ',');
            first_row = false;
            try out.appendSlice(alloc, b.items);
        }
    }

    try out.append(alloc, ']');
    return caller.allocator().dupeZ(u8, out.items);
}

// ---------------------------------------------------------------------------
// JSON output helpers
// ---------------------------------------------------------------------------

fn appendFmt(alloc: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(s);
    try out.appendSlice(alloc, s);
}

fn appendJsonString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (ch < 0x20) {
            try appendFmt(alloc, out, "\\u{x:0>4}", .{ch});
        } else {
            try out.append(alloc, ch);
        },
    };
    try out.append(alloc, '"');
}

fn appendScalarJson(comptime T: type, alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: T) !void {
    if (comptime T == []const u8) {
        try appendJsonString(alloc, out, v);
    } else if (comptime T == bool) {
        try out.appendSlice(alloc, if (v) "true" else "false");
    } else {
        try appendFmt(alloc, out, "{d}", .{v});
    }
}

/// Write one column of a batch into every row buffer, dispatching on the value
/// type once for the whole column.
fn appendColumnJson(
    comptime T: type,
    alloc: std.mem.Allocator,
    rows: []std.ArrayList(u8),
    values: []const T,
    nulls: ?[]const u8,
    name: []const u8,
    first: bool,
) !void {
    for (rows, 0..) |*b, r| {
        if (!first) try b.append(alloc, ',');
        try appendJsonString(alloc, b, name);
        try b.append(alloc, ':');
        if (nulls) |nb| {
            if (compression.isNull(nb, r)) {
                try b.appendSlice(alloc, "null");
                continue;
            }
        }
        try appendScalarJson(T, alloc, b, values[r]);
    }
}

/// Decode the hex representation returned by SPI for a `bytea` value.
/// Postgres renders bytea as `\x<hex>` in text output.
fn hexToBytes(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const hex = if (s.len >= 2 and s[0] == '\\' and s[1] == 'x') s[2..] else s;
    if (hex.len % 2 != 0) return error.Corrupt;
    const out = try alloc.alloc(u8, hex.len / 2);
    for (out, 0..) |*b, i| {
        b.* = try std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16);
    }
    return out;
}
