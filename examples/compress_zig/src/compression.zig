//! On-disk compressed batch format.
//!
//! A batch is the unit of compression: a group of rows (typically ~1000) that
//! share the same `segment_by` values, transposed into columns, encoded, and
//! serialized into a single blob. The blob is then optionally compressed as a
//! whole (see the extension layer) and stored as one row in the sidecar
//! relation.
//!
//! Layout (all integers little-endian):
//!
//!   header (16 bytes)
//!     magic      u32   = 'PGB1' (0x50474231)
//!     version    u16   = 1
//!     row_count  u32
//!     col_count  u16
//!     flags      u16   (reserved, must be 0)
//!   column directory (col_count * 24 bytes), starting at offset 16
//!     encoding   u8    (Encoding)
//!     kind       u8    (Kind)
//!     flags      u8    bit0 has_nulls, bit1 byval
//!     pad        u8
//!     type_oid   u32
//!     typlen     i16
//!     pad2       i16
//!     null_off   u32   absolute offset of the null bitmap (0 if none)
//!     data_off   u32   absolute offset of the encoded payload
//!     data_len   u32   payload length in bytes
//!   null bitmaps and payloads follow, aligned to 4 and 8 bytes respectively.
//!
//! The absolute offsets let a future reader seek straight to one column's
//! payload (column pruning) without touching the rest of the batch.
//!
//! This module is pure Zig (no PostgreSQL dependency) and is covered by
//! `zig build test`.

const std = @import("std");
const bytes = @import("compression/bytes.zig");
const encoding = @import("compression/encoding.zig");

pub const Encoding = encoding.Encoding;
pub const Kind = encoding.Kind;
pub const TypeSpec = encoding.TypeSpec;
pub const Column = encoding.Column;
pub const Decoded = encoding.Decoded;
pub const EncodedColumn = encoding.EncodedColumn;
pub const encodeColumn = encoding.encodeColumn;
pub const decodeColumn = encoding.decodeColumn;

pub const MAGIC: u32 = 0x50474231; // 'PGB1'
pub const VERSION: u16 = 1;
pub const HEADER_SIZE: usize = 16;
pub const DIR_ENTRY_SIZE: usize = 24;

const FLAG_HAS_NULLS: u8 = 0b0000_0001;
const FLAG_BYVAL: u8 = 0b0000_0010;

pub const Error = error{
    BadMagic,
    BadVersion,
    Truncated,
    UnknownEncoding,
    UnknownKind,
    Corrupt,
};

pub const Entry = struct {
    encoding: Encoding,
    kind: Kind,
    spec: TypeSpec,
    has_nulls: bool,
    null_off: u32,
    data_off: u32,
    data_len: u32,
};

fn putInt(comptime T: type, dest: []u8, v: T) void {
    var tmp: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &tmp, v, .little);
    @memcpy(dest[0..@sizeOf(T)], &tmp);
}

fn getInt(comptime T: type, src: []const u8) T {
    var tmp: [@sizeOf(T)]u8 = undefined;
    @memcpy(&tmp, src[0..@sizeOf(T)]);
    return std.mem.readInt(T, &tmp, .little);
}

/// Number of bytes in a null bitmap for `row_count` rows.
pub fn nullBitmapLen(row_count: u32) usize {
    return (@as(usize, row_count) + 7) / 8;
}

/// Whether `row` is null in a raw null bitmap.
pub fn isNull(bitmap: []const u8, row: usize) bool {
    const byte = bitmap[row / 8];
    return (byte & (@as(u8, 1) << @intCast(row % 8))) != 0;
}

/// Builds a packed null bitmap (one bit per row, LSB first) without ever
/// materializing a `[]bool`. Rows are appended in order; `view` returns null
/// when no null has been recorded, which is the common case.
pub const NullBitmapBuilder = struct {
    alloc: std.mem.Allocator,
    bits: std.ArrayList(u8) = .empty,
    count: usize = 0,
    any: bool = false,

    pub fn init(alloc: std.mem.Allocator) NullBitmapBuilder {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *NullBitmapBuilder) void {
        self.bits.deinit(self.alloc);
    }

    pub fn append(self: *NullBitmapBuilder, is_null: bool) !void {
        if (self.count % 8 == 0) try self.bits.append(self.alloc, 0);
        if (is_null) {
            self.bits.items[self.count / 8] |= (@as(u8, 1) << @intCast(self.count % 8));
            self.any = true;
        }
        self.count += 1;
    }

    pub fn view(self: *const NullBitmapBuilder) ?[]const u8 {
        return if (self.any) self.bits.items else null;
    }

    pub fn reset(self: *NullBitmapBuilder) void {
        self.bits.clearRetainingCapacity();
        self.count = 0;
        self.any = false;
    }
};

/// Serialize a batch. `nulls` is parallel to `columns`; each entry is either a
/// packed bitmap of `nullBitmapLen(row_count)` bytes or null when the column
/// has no nulls.
pub fn writeBatch(
    alloc: std.mem.Allocator,
    row_count: u32,
    columns: []const EncodedColumn,
    nulls: []const ?[]const u8,
) ![]u8 {
    std.debug.assert(nulls.len == columns.len);

    var w = bytes.Writer.init(alloc);
    errdefer w.deinit();

    const n = columns.len;
    const dir_size = n * DIR_ENTRY_SIZE;

    try w.int(u32, MAGIC);
    try w.int(u16, VERSION);
    try w.int(u32, row_count);
    try w.int(u16, @intCast(n));
    try w.int(u16, 0);

    var i: usize = 0;
    while (i < dir_size) : (i += 1) try w.byte(0);

    for (columns, 0..) |col, ci| {
        const bitmap = nulls[ci];
        const has_nulls = bitmap != null;

        try w.padTo(4);
        const null_off: u32 = @intCast(w.len());
        if (bitmap) |bits| {
            std.debug.assert(bits.len == nullBitmapLen(row_count));
            try w.slice(bits);
        }

        try w.padTo(8);
        const data_off: u32 = @intCast(w.len());
        try w.slice(col.payload);
        const data_len: u32 = @intCast(col.payload.len);

        const off = HEADER_SIZE + ci * DIR_ENTRY_SIZE;
        const e = w.list.items[off .. off + DIR_ENTRY_SIZE];
        e[0] = @intFromEnum(col.encoding);
        e[1] = @intFromEnum(col.kind);
        e[2] = (if (has_nulls) FLAG_HAS_NULLS else 0) | (if (col.spec.byval) FLAG_BYVAL else 0);
        e[3] = 0;
        putInt(u32, e[4..8], col.spec.oid);
        putInt(i16, e[8..10], col.spec.len);
        putInt(i16, e[10..12], 0);
        putInt(u32, e[12..16], if (has_nulls) null_off else 0);
        putInt(u32, e[16..20], data_off);
        putInt(u32, e[20..24], data_len);
    }

    return w.toOwned();
}

/// Zero-copy view over a serialized batch.
pub const BatchView = struct {
    data: []const u8,
    row_count: u32,
    col_count: u16,

    pub fn init(data: []const u8) Error!BatchView {
        if (data.len < HEADER_SIZE) return error.Truncated;
        if (getInt(u32, data[0..4]) != MAGIC) return error.BadMagic;
        if (getInt(u16, data[4..6]) != VERSION) return error.BadVersion;
        const row_count = getInt(u32, data[6..10]);
        const col_count = getInt(u16, data[10..12]);
        const dir_end = HEADER_SIZE + @as(usize, col_count) * DIR_ENTRY_SIZE;
        if (data.len < dir_end) return error.Truncated;
        return .{ .data = data, .row_count = row_count, .col_count = col_count };
    }

    pub fn entry(self: BatchView, i: usize) Error!Entry {
        if (i >= self.col_count) return error.Corrupt;
        const off = HEADER_SIZE + i * DIR_ENTRY_SIZE;
        const e = self.data[off .. off + DIR_ENTRY_SIZE];

        const enc = std.enums.fromInt(Encoding, e[0]) orelse return error.UnknownEncoding;
        const kind = std.enums.fromInt(Kind, e[1]) orelse return error.UnknownKind;
        const flags = e[2];

        const data_off = getInt(u32, e[16..20]);
        const data_len = getInt(u32, e[20..24]);
        if (@as(usize, data_off) + data_len > self.data.len) return error.Truncated;

        return .{
            .encoding = enc,
            .kind = kind,
            .spec = .{
                .oid = getInt(u32, e[4..8]),
                .len = getInt(i16, e[8..10]),
                .byval = (flags & FLAG_BYVAL) != 0,
            },
            .has_nulls = (flags & FLAG_HAS_NULLS) != 0,
            .null_off = getInt(u32, e[12..16]),
            .data_off = data_off,
            .data_len = data_len,
        };
    }

    pub fn payload(self: BatchView, i: usize) Error![]const u8 {
        const e = try self.entry(i);
        return self.data[e.data_off .. e.data_off + e.data_len];
    }

    /// Raw null bitmap for column `i`, or null when the column has no nulls.
    pub fn nullBitmap(self: BatchView, i: usize) Error!?[]const u8 {
        const e = try self.entry(i);
        if (!e.has_nulls) return null;
        const len = nullBitmapLen(self.row_count);
        if (@as(usize, e.null_off) + len > self.data.len) return error.Truncated;
        return self.data[e.null_off .. e.null_off + len];
    }

    /// Decode column `i`. Values at null positions are placeholders; consult
    /// `nullBitmap` to build a correct tuple.
    pub fn decode(self: BatchView, i: usize, alloc: std.mem.Allocator) !Decoded {
        const e = try self.entry(i);
        const raw = self.data[e.data_off .. e.data_off + e.data_len];
        return decodeColumn(alloc, e.encoding, e.kind, raw, self.row_count);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "batch roundtrip with nulls" {
    const alloc = std.testing.allocator;

    const ts = [_]i64{ 100, 101, 102, 103, 104 };
    const labels = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" };

    var c0 = try encodeColumn(alloc, .{ .i64 = &ts });
    defer c0.deinit(alloc);
    var c1 = try encodeColumn(alloc, .{ .bytes = &labels });
    defer c1.deinit(alloc);

    const columns = [_]EncodedColumn{ c0, c1 };
    var nb0 = NullBitmapBuilder.init(alloc);
    defer nb0.deinit();
    for ([_]bool{ false, true, false, false, true }) |n| try nb0.append(n);
    const nulls = [_]?[]const u8{ nb0.view(), null };

    const buf = try writeBatch(alloc, 5, &columns, &nulls);
    defer alloc.free(buf);

    const view = try BatchView.init(buf);
    try std.testing.expectEqual(@as(u32, 5), view.row_count);
    try std.testing.expectEqual(@as(u16, 2), view.col_count);

    var d0 = try view.decode(0, alloc);
    defer d0.deinit(alloc);
    try std.testing.expectEqualSlices(i64, &ts, d0.i64);

    const nb = (try view.nullBitmap(0)).?;
    try std.testing.expect(!isNull(nb, 0));
    try std.testing.expect(isNull(nb, 1));
    try std.testing.expect(isNull(nb, 4));
    try std.testing.expect((try view.nullBitmap(1)) == null);

    var d1 = try view.decode(1, alloc);
    defer d1.deinit(alloc);
    try std.testing.expectEqual(labels.len, d1.bytes.len);
    for (labels, d1.bytes) |a, b| try std.testing.expectEqualStrings(a, b);
}

test "batch rejects corrupted magic" {
    const alloc = std.testing.allocator;
    const values = [_]i32{ 1, 2, 3 };
    var c0 = try encodeColumn(alloc, .{ .i32 = &values });
    defer c0.deinit(alloc);

    const columns = [_]EncodedColumn{c0};
    const nulls = [_]?[]const u8{null};
    const buf = try writeBatch(alloc, 3, &columns, &nulls);
    defer alloc.free(buf);

    buf[0] ^= 0xFF;
    try std.testing.expectError(error.BadMagic, BatchView.init(buf));
}

test "batch with no nulls" {
    const alloc = std.testing.allocator;
    const values = [_]f64{ 1.0, 2.0, 3.0, 4.0 };
    var c0 = try encodeColumn(alloc, .{ .f64 = &values });
    defer c0.deinit(alloc);

    const columns = [_]EncodedColumn{c0};
    const nulls = [_]?[]const u8{null};
    const buf = try writeBatch(alloc, 4, &columns, &nulls);
    defer alloc.free(buf);

    const view = try BatchView.init(buf);
    var d0 = try view.decode(0, alloc);
    defer d0.deinit(alloc);
    try std.testing.expectEqualSlices(f64, &values, d0.f64);
    try std.testing.expect((try view.nullBitmap(0)) == null);
}
