//! Column encodings for the on-disk compressed batch format.
//!
//! Each codec is generic over the Zig scalar type it supports and operates on
//! a plain slice of values. Nulls are *not* handled here: the batch format
//! stores a separate null bitmap and null slots are encoded as their zero
//! value, so a codec can always round-trip the full row count.
//!
//! This module is pure Zig (no PostgreSQL dependency) so it can be exercised
//! with `zig build test`.

const std = @import("std");
const bytes = @import("bytes.zig");

/// Identifier stored in the batch column directory. Values are part of the
/// on-disk format; append new ones, never renumber.
pub const Encoding = enum(u8) {
    /// Raw little-endian values (or length-prefixed byte strings).
    plain = 0,
    /// Run length encoding.
    rle = 1,
    /// First value + first-order deltas (zig-zag varint).
    delta = 2,
    /// First value, first delta, then second-order deltas (zig-zag varint).
    delta2 = 3,
    /// Gorilla-style XOR encoding for floats.
    gorilla = 4,
    /// Dictionary encoding (dictionary + fixed-width codes).
    dict = 5,
    /// Bit-packed booleans.
    bool = 6,
};

/// The logical type of a column as understood by the codecs.
pub const Kind = enum(u8) {
    i16 = 0,
    i32 = 1,
    i64 = 2,
    f32 = 3,
    f64 = 4,
    boolean = 5,
    bytes = 6,

    pub fn name(self: Kind) []const u8 {
        return @tagName(self);
    }
};

/// PostgreSQL type metadata needed to rebuild a `TupleDesc` on decompression.
pub const TypeSpec = struct {
    oid: u32,
    len: i16,
    byval: bool,
};

pub fn specFor(kind: Kind) TypeSpec {
    return switch (kind) {
        .i16 => .{ .oid = 21, .len = 2, .byval = true }, // int2
        .i32 => .{ .oid = 23, .len = 4, .byval = true }, // int4
        .i64 => .{ .oid = 20, .len = 8, .byval = true }, // int8
        .f32 => .{ .oid = 700, .len = 4, .byval = true }, // float4
        .f64 => .{ .oid = 701, .len = 8, .byval = true }, // float8
        .boolean => .{ .oid = 16, .len = 1, .byval = true }, // bool
        .bytes => .{ .oid = 17, .len = -1, .byval = false }, // bytea
    };
}

pub fn kindForOid(oid: u32) ?Kind {
    return switch (oid) {
        21 => .i16,
        23 => .i32,
        20 => .i64,
        700 => .f32,
        701 => .f64,
        16 => .boolean,
        17, 25, 1043 => .bytes, // bytea, text, varchar
        else => null,
    };
}

/// In-memory representation of a single column of values.
pub const Column = union(enum) {
    i16: []const i16,
    i32: []const i32,
    i64: []const i64,
    f32: []const f32,
    f64: []const f64,
    boolean: []const bool,
    bytes: []const []const u8,

    pub fn kind(self: Column) Kind {
        return switch (self) {
            .i16 => .i16,
            .i32 => .i32,
            .i64 => .i64,
            .f32 => .f32,
            .f64 => .f64,
            .boolean => .boolean,
            .bytes => .bytes,
        };
    }

    pub fn rowCount(self: Column) usize {
        return switch (self) {
            inline else => |values| values.len,
        };
    }
};

/// Decoded column; owns its memory.
pub const Decoded = union(enum) {
    i16: []i16,
    i32: []i32,
    i64: []i64,
    f32: []f32,
    f64: []f64,
    boolean: []bool,
    bytes: [][]u8,

    pub fn deinit(self: *Decoded, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .i16 => |v| alloc.free(v),
            .i32 => |v| alloc.free(v),
            .i64 => |v| alloc.free(v),
            .f32 => |v| alloc.free(v),
            .f64 => |v| alloc.free(v),
            .boolean => |v| alloc.free(v),
            .bytes => |v| {
                for (v) |s| alloc.free(s);
                alloc.free(v);
            },
        }
    }
};

/// Result of encoding one column: the chosen encoding plus its payload.
pub const EncodedColumn = struct {
    encoding: Encoding,
    kind: Kind,
    spec: TypeSpec,
    payload: []u8,

    pub fn deinit(self: *EncodedColumn, alloc: std.mem.Allocator) void {
        alloc.free(self.payload);
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn isBytes(comptime T: type) bool {
    return T == []const u8 or T == []u8;
}

fn ScalarBits(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .int => T,
        .float => std.meta.Int(.unsigned, @bitSizeOf(T)),
        else => @compileError("encode: int or float expected, got " ++ @typeName(T)),
    };
}

fn writeScalar(w: *bytes.Writer, comptime T: type, v: T) !void {
    const B = ScalarBits(T);
    const bits: B = if (@typeInfo(T) == .float) @bitCast(v) else v;
    try w.int(B, bits);
}

fn readScalar(r: *bytes.Reader, comptime T: type) !T {
    const B = ScalarBits(T);
    const bits = try r.int(B);
    return if (@typeInfo(T) == .float) @bitCast(bits) else bits;
}

fn wrap(comptime T: type, v: []T) Decoded {
    return switch (T) {
        i16 => .{ .i16 = v },
        i32 => .{ .i32 = v },
        i64 => .{ .i64 = v },
        f32 => .{ .f32 = v },
        f64 => .{ .f64 = v },
        else => @compileError("wrap: unsupported type " ++ @typeName(T)),
    };
}

fn typeForKind(comptime k: Kind) type {
    return switch (k) {
        .i16 => i16,
        .i32 => i32,
        .i64 => i64,
        .f32 => f32,
        .f64 => f64,
        else => @compileError("typeForKind: not a scalar kind"),
    };
}

// ---------------------------------------------------------------------------
// Bit-level reader/writer (gorilla, bool)
// ---------------------------------------------------------------------------

const BitWriter = struct {
    w: *bytes.Writer,
    cur: u8 = 0,
    nbits: u4 = 0,

    fn init(w: *bytes.Writer) BitWriter {
        return .{ .w = w };
    }

    fn bit(self: *BitWriter, b: u1) !void {
        self.cur = (self.cur << 1) | b;
        self.nbits += 1;
        if (self.nbits == 8) {
            try self.w.byte(self.cur);
            self.cur = 0;
            self.nbits = 0;
        }
    }

    fn bits(self: *BitWriter, value: u64, count: u7) !void {
        var i: u7 = count;
        while (i > 0) {
            i -= 1;
            try self.bit(@intCast((value >> @intCast(i)) & 1));
        }
    }

    fn flush(self: *BitWriter) !void {
        if (self.nbits != 0) {
            self.cur <<= @intCast(8 - self.nbits);
            try self.w.byte(self.cur);
            self.cur = 0;
            self.nbits = 0;
        }
    }
};

const BitReader = struct {
    r: *bytes.Reader,
    cur: u8 = 0,
    nleft: u4 = 0,

    fn init(r: *bytes.Reader) BitReader {
        return .{ .r = r };
    }

    fn bit(self: *BitReader) !u1 {
        if (self.nleft == 0) {
            self.cur = try self.r.byte();
            self.nleft = 8;
        }
        self.nleft -= 1;
        return @intCast((self.cur >> @intCast(self.nleft)) & 1);
    }

    fn bits(self: *BitReader, count: u7) !u64 {
        var v: u64 = 0;
        var i: u7 = 0;
        while (i < count) : (i += 1) {
            v = (v << 1) | try self.bit();
        }
        return v;
    }
};

// ---------------------------------------------------------------------------
// plain
// ---------------------------------------------------------------------------

fn encodePlainScalar(comptime T: type, values: []const T, w: *bytes.Writer) !void {
    for (values) |v| try writeScalar(w, T, v);
}

fn decodePlainScalar(comptime T: type, r: *bytes.Reader, count: usize, alloc: std.mem.Allocator) ![]T {
    const out = try alloc.alloc(T, count);
    errdefer alloc.free(out);
    for (out) |*slot| slot.* = try readScalar(r, T);
    return out;
}

fn encodePlainBytes(values: []const []const u8, w: *bytes.Writer) !void {
    for (values) |v| {
        try w.int(u32, @intCast(v.len));
        try w.slice(v);
    }
}

fn decodePlainBytes(r: *bytes.Reader, count: usize, alloc: std.mem.Allocator) ![][]u8 {
    const out = try alloc.alloc([]u8, count);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |s| alloc.free(s);
        alloc.free(out);
    }
    while (i < count) : (i += 1) {
        const n = try r.int(u32);
        const b = try r.slice(n);
        out[i] = try alloc.dupe(u8, b);
    }
    return out;
}

// ---------------------------------------------------------------------------
// rle
// ---------------------------------------------------------------------------

fn encodeRle(comptime T: type, values: []const T, w: *bytes.Writer) !void {
    if (values.len == 0) {
        try w.int(u32, 0);
        return;
    }
    var runs: u32 = 0;
    var i: usize = 0;
    while (i < values.len) {
        var j = i + 1;
        while (j < values.len and values[j] == values[i]) j += 1;
        runs += 1;
        i = j;
    }
    try w.int(u32, runs);

    i = 0;
    while (i < values.len) {
        var j = i + 1;
        while (j < values.len and values[j] == values[i]) j += 1;
        try writeScalar(w, T, values[i]);
        try w.varU64(j - i);
        i = j;
    }
}

fn decodeRle(comptime T: type, r: *bytes.Reader, count: usize, alloc: std.mem.Allocator) ![]T {
    const out = try alloc.alloc(T, count);
    errdefer alloc.free(out);
    const runs = try r.int(u32);
    var idx: usize = 0;
    var ri: u32 = 0;
    while (ri < runs) : (ri += 1) {
        const v = try readScalar(r, T);
        const n = try r.varU64();
        var k: u64 = 0;
        while (k < n) : (k += 1) {
            if (idx >= count) return error.Corrupt;
            out[idx] = v;
            idx += 1;
        }
    }
    if (idx != count) return error.Corrupt;
    return out;
}

// ---------------------------------------------------------------------------
// delta / delta2
// ---------------------------------------------------------------------------

fn encodeDelta(comptime T: type, values: []const T, w: *bytes.Writer) !void {
    if (values.len == 0) return;
    const first: i64 = values[0];
    try w.zigzag(first);
    var prev: i64 = first;
    for (values[1..]) |v| {
        const cur: i64 = v;
        try w.zigzag(cur -% prev);
        prev = cur;
    }
}

fn decodeDelta(comptime T: type, r: *bytes.Reader, count: usize, alloc: std.mem.Allocator) ![]T {
    const out = try alloc.alloc(T, count);
    errdefer alloc.free(out);
    if (count == 0) return out;
    var prev = try r.zigzag();
    out[0] = @intCast(prev);
    var i: usize = 1;
    while (i < count) : (i += 1) {
        prev = prev +% (try r.zigzag());
        out[i] = @intCast(prev);
    }
    return out;
}

fn encodeDelta2(comptime T: type, values: []const T, w: *bytes.Writer) !void {
    if (values.len == 0) return;
    const first: i64 = values[0];
    try w.zigzag(first);
    if (values.len == 1) return;

    var prev: i64 = first;
    var prev_delta: i64 = @as(i64, values[1]) -% first;
    try w.zigzag(prev_delta);
    prev = values[1];

    for (values[2..]) |v| {
        const cur: i64 = v;
        const delta = cur -% prev;
        try w.zigzag(delta -% prev_delta);
        prev_delta = delta;
        prev = cur;
    }
}

fn decodeDelta2(comptime T: type, r: *bytes.Reader, count: usize, alloc: std.mem.Allocator) ![]T {
    const out = try alloc.alloc(T, count);
    errdefer alloc.free(out);
    if (count == 0) return out;
    var prev = try r.zigzag();
    out[0] = @intCast(prev);
    if (count == 1) return out;

    var prev_delta = try r.zigzag();
    prev = prev +% prev_delta;
    out[1] = @intCast(prev);

    var i: usize = 2;
    while (i < count) : (i += 1) {
        const d2 = try r.zigzag();
        prev_delta = prev_delta +% d2;
        prev = prev +% prev_delta;
        out[i] = @intCast(prev);
    }
    return out;
}

// ---------------------------------------------------------------------------
// gorilla (XOR floating point)
// ---------------------------------------------------------------------------

fn encodeGorilla(comptime T: type, values: []const T, w: *bytes.Writer) !void {
    if (values.len == 0) return;
    const B = ScalarBits(T);
    const nbits = @bitSizeOf(T);
    const W: u7 = @intCast(std.math.log2_int(usize, nbits));

    var bw = BitWriter.init(w);
    var prev: B = @bitCast(values[0]);
    try bw.bits(prev, @intCast(nbits));

    var prev_leading: u7 = 0;
    var prev_trailing: u7 = 0;
    var have_window = false;

    for (values[1..]) |v| {
        const cur: B = @bitCast(v);
        const xor = cur ^ prev;
        if (xor == 0) {
            try bw.bit(0);
        } else {
            try bw.bit(1);
            const leading: u7 = @intCast(@clz(xor));
            const trailing: u7 = @intCast(@ctz(xor));
            const meaningful = nbits - leading - trailing;
            const reuse = have_window and leading >= prev_leading and trailing >= prev_trailing;
            if (reuse) {
                try bw.bit(0);
                const window = nbits - prev_leading - prev_trailing;
                try bw.bits(xor >> @intCast(prev_trailing), @intCast(window));
            } else {
                try bw.bit(1);
                try bw.bits(leading, W);
                try bw.bits(meaningful - 1, W);
                try bw.bits(xor >> @intCast(trailing), @intCast(meaningful));
                prev_leading = leading;
                prev_trailing = trailing;
                have_window = true;
            }
        }
        prev = cur;
    }
    try bw.flush();
}

fn decodeGorilla(comptime T: type, r: *bytes.Reader, count: usize, alloc: std.mem.Allocator) ![]T {
    const B = ScalarBits(T);
    const nbits = @bitSizeOf(T);
    const W: u7 = @intCast(std.math.log2_int(usize, nbits));

    const out = try alloc.alloc(T, count);
    errdefer alloc.free(out);
    if (count == 0) return out;

    var br = BitReader.init(r);
    var prev: B = @intCast(try br.bits(@intCast(nbits)));
    out[0] = @bitCast(prev);

    var prev_leading: u7 = 0;
    var prev_trailing: u7 = 0;
    var have_window = false;

    var i: usize = 1;
    while (i < count) : (i += 1) {
        if (try br.bit() == 0) {
            out[i] = @bitCast(prev);
            continue;
        }
        if (try br.bit() == 1) {
            prev_leading = @intCast(try br.bits(W));
            const m1 = try br.bits(W);
            if (prev_leading > nbits or m1 + 1 > nbits - prev_leading) return error.Corrupt;
            prev_trailing = @intCast(nbits - prev_leading - (m1 + 1));
            have_window = true;
        } else if (!have_window) {
            return error.Corrupt;
        }
        const meaningful = nbits - prev_leading - prev_trailing;
        const shifted = try br.bits(@intCast(meaningful));
        const xor: B = @intCast(shifted << @intCast(prev_trailing));
        prev = prev ^ xor;
        out[i] = @bitCast(prev);
    }
    return out;
}

// ---------------------------------------------------------------------------
// dict
// ---------------------------------------------------------------------------

fn encodeDict(comptime T: type, values: []const T, w: *bytes.Writer) !void {
    var map = std.AutoHashMap(T, u32).init(w.alloc);
    defer map.deinit();
    var dict: std.ArrayList(T) = .empty;
    defer dict.deinit(w.alloc);
    var codes: std.ArrayList(u32) = .empty;
    defer codes.deinit(w.alloc);

    for (values) |v| {
        const gop = try map.getOrPut(v);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(dict.items.len);
            try dict.append(w.alloc, v);
        }
        try codes.append(w.alloc, gop.value_ptr.*);
    }

    try w.int(u32, @intCast(dict.items.len));
    for (dict.items) |v| try writeScalar(w, T, v);

    const width: u8 = if (dict.items.len <= 256) 1 else if (dict.items.len <= 65536) 2 else 4;
    try w.byte(width);
    for (codes.items) |c| switch (width) {
        1 => try w.int(u8, @intCast(c)),
        2 => try w.int(u16, @intCast(c)),
        else => try w.int(u32, c),
    };
}

fn decodeDict(comptime T: type, r: *bytes.Reader, count: usize, alloc: std.mem.Allocator) ![]T {
    const dict_len = try r.int(u32);
    const dict = try alloc.alloc(T, dict_len);
    defer alloc.free(dict);
    for (dict) |*slot| slot.* = try readScalar(r, T);

    const width = try r.byte();
    const out = try alloc.alloc(T, count);
    errdefer alloc.free(out);
    for (out) |*slot| {
        const code: u32 = switch (width) {
            1 => try r.int(u8),
            2 => try r.int(u16),
            4 => try r.int(u32),
            else => return error.Corrupt,
        };
        if (code >= dict_len) return error.Corrupt;
        slot.* = dict[code];
    }
    return out;
}

// ---------------------------------------------------------------------------
// bool
// ---------------------------------------------------------------------------

fn encodeBool(values: []const bool, w: *bytes.Writer) !void {
    try w.int(u32, @intCast(values.len));
    var bw = BitWriter.init(w);
    for (values) |v| try bw.bit(@intFromBool(v));
    try bw.flush();
}

fn decodeBool(r: *bytes.Reader, count: usize, alloc: std.mem.Allocator) ![]bool {
    const n = try r.int(u32);
    if (n != count) return error.Corrupt;
    const out = try alloc.alloc(bool, count);
    errdefer alloc.free(out);
    var br = BitReader.init(r);
    for (out) |*slot| slot.* = (try br.bit()) != 0;
    return out;
}

// ---------------------------------------------------------------------------
// Selection + dispatch
// ---------------------------------------------------------------------------

/// Encode a column, trying every applicable encoding and keeping the smallest.
pub fn encodeColumn(alloc: std.mem.Allocator, col: Column) !EncodedColumn {
    return switch (col) {
        .i16 => |values| encodeForKind(i16, .i16, values, alloc),
        .i32 => |values| encodeForKind(i32, .i32, values, alloc),
        .i64 => |values| encodeForKind(i64, .i64, values, alloc),
        .f32 => |values| encodeForKind(f32, .f32, values, alloc),
        .f64 => |values| encodeForKind(f64, .f64, values, alloc),
        .boolean => |values| encodeForKind(bool, .boolean, values, alloc),
        .bytes => |values| encodeForKind([]const u8, .bytes, values, alloc),
    };
}

fn encodeForKind(comptime T: type, kind: Kind, values: []const T, alloc: std.mem.Allocator) !EncodedColumn {
    var best: ?EncodedColumn = null;
    errdefer if (best) |b| alloc.free(b.payload);

    if (comptime T == bool) {
        try consider(T, kind, .bool, values, alloc, &best);
    } else if (comptime isBytes(T)) {
        try consider(T, kind, .plain, values, alloc, &best);
    } else if (comptime @typeInfo(T) == .int) {
        inline for (.{ .plain, .rle, .delta, .delta2, .dict }) |enc| {
            try consider(T, kind, enc, values, alloc, &best);
        }
    } else {
        inline for (.{ .plain, .rle, .gorilla }) |enc| {
            try consider(T, kind, enc, values, alloc, &best);
        }
    }

    return best.?;
}

fn consider(
    comptime T: type,
    kind: Kind,
    comptime enc: Encoding,
    values: []const T,
    alloc: std.mem.Allocator,
    best: *?EncodedColumn,
) !void {
    var w = bytes.Writer.init(alloc);
    errdefer w.deinit();
    try encodeWith(T, enc, values, &w);
    const payload = try w.toOwned();

    if (best.* == null or payload.len < best.*.?.payload.len) {
        if (best.*) |b| alloc.free(b.payload);
        best.* = .{
            .encoding = enc,
            .kind = kind,
            .spec = specFor(kind),
            .payload = payload,
        };
    } else {
        alloc.free(payload);
    }
}

fn encodeWith(comptime T: type, comptime enc: Encoding, values: []const T, w: *bytes.Writer) !void {
    if (comptime enc == .bool) return encodeBool(values, w);
    if (comptime isBytes(T)) return encodePlainBytes(values, w);
    switch (enc) {
        .plain => try encodePlainScalar(T, values, w),
        .rle => try encodeRle(T, values, w),
        .delta => try encodeDelta(T, values, w),
        .delta2 => try encodeDelta2(T, values, w),
        .gorilla => try encodeGorilla(T, values, w),
        .dict => try encodeDict(T, values, w),
        .bool => unreachable,
    }
}

/// Decode a payload produced by `encodeColumn`.
pub fn decodeColumn(
    alloc: std.mem.Allocator,
    enc: Encoding,
    kind: Kind,
    payload: []const u8,
    count: usize,
) !Decoded {
    var r = bytes.Reader.init(payload);
    return switch (kind) {
        .boolean => .{ .boolean = try decodeBool(&r, count, alloc) },
        .bytes => .{ .bytes = try decodePlainBytes(&r, count, alloc) },
        else => try decodeScalarDispatch(alloc, enc, kind, &r, count),
    };
}

fn decodeScalarDispatch(
    alloc: std.mem.Allocator,
    enc: Encoding,
    kind: Kind,
    r: *bytes.Reader,
    count: usize,
) !Decoded {
    return switch (enc) {
        .plain => try dispatch(.plain, alloc, kind, r, count, .{ .i16, .i32, .i64, .f32, .f64 }),
        .rle => try dispatch(.rle, alloc, kind, r, count, .{ .i16, .i32, .i64, .f32, .f64 }),
        .dict => try dispatch(.dict, alloc, kind, r, count, .{ .i16, .i32, .i64, .f32, .f64 }),
        .delta => try dispatch(.delta, alloc, kind, r, count, .{ .i16, .i32, .i64 }),
        .delta2 => try dispatch(.delta2, alloc, kind, r, count, .{ .i16, .i32, .i64 }),
        .gorilla => try dispatch(.gorilla, alloc, kind, r, count, .{ .f32, .f64 }),
        .bool => error.UnsupportedKind,
    };
}

fn dispatch(
    comptime enc: Encoding,
    alloc: std.mem.Allocator,
    kind: Kind,
    r: *bytes.Reader,
    count: usize,
    comptime kinds: anytype,
) !Decoded {
    inline for (kinds) |K| {
        if (kind == K) {
            const T = typeForKind(K);
            return wrap(T, try decodeScalarWith(T, enc, r, count, alloc));
        }
    }
    return error.UnsupportedKind;
}

fn decodeScalarWith(comptime T: type, comptime enc: Encoding, r: *bytes.Reader, count: usize, alloc: std.mem.Allocator) ![]T {
    return switch (enc) {
        .plain => decodePlainScalar(T, r, count, alloc),
        .rle => decodeRle(T, r, count, alloc),
        .delta => decodeDelta(T, r, count, alloc),
        .delta2 => decodeDelta2(T, r, count, alloc),
        .gorilla => decodeGorilla(T, r, count, alloc),
        .dict => decodeDict(T, r, count, alloc),
        .bool => @compileError("bool encoding is not scalar"),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn roundTrip(comptime T: type, comptime kind: Kind, values: []const T) !void {
    const alloc = std.testing.allocator;
    var encoded = try encodeColumn(alloc, @unionInit(Column, @tagName(kind), values));
    defer encoded.deinit(alloc);

    var decoded = try decodeColumn(alloc, encoded.encoding, kind, encoded.payload, values.len);
    defer decoded.deinit(alloc);

    const got = @field(decoded, @tagName(kind));
    try std.testing.expectEqual(values.len, got.len);
    for (values, got) |a, b| try std.testing.expectEqual(a, b);
}

test "plain selection roundtrip" {
    try roundTrip(i64, .i64, &.{ 1, 2, 3, 4, 5 });
    try roundTrip(i32, .i32, &.{ -1, 0, 1 });
    try roundTrip(f64, .f64, &.{ 1.5, 2.5, -3.25 });
}

test "delta roundtrip" {
    const alloc = std.testing.allocator;
    const values = [_]i64{ 1_000_000, 1_000_001, 1_000_002, 1_000_003, 1_000_004 };
    var encoded = try encodeColumn(alloc, .{ .i64 = &values });
    defer encoded.deinit(alloc);
    try std.testing.expectEqual(Encoding.delta, encoded.encoding);

    var decoded = try decodeColumn(alloc, encoded.encoding, .i64, encoded.payload, values.len);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualSlices(i64, &values, decoded.i64);
}

test "delta2 roundtrip" {
    const alloc = std.testing.allocator;
    var values: [200]i64 = undefined;
    var v: i64 = 1000;
    var step: i64 = 5;
    for (&values) |*slot| {
        slot.* = v;
        v += step;
        step += 2;
    }
    var encoded = try encodeColumn(alloc, .{ .i64 = &values });
    defer encoded.deinit(alloc);

    var decoded = try decodeColumn(alloc, encoded.encoding, .i64, encoded.payload, values.len);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualSlices(i64, &values, decoded.i64);
}

fn codecRoundTrip(comptime T: type, comptime enc: Encoding, values: []const T) !void {
    const alloc = std.testing.allocator;
    var w = bytes.Writer.init(alloc);
    defer w.deinit();
    try encodeWith(T, enc, values, &w);

    var r = bytes.Reader.init(w.list.items);
    const decoded = try decodeScalarWith(T, enc, &r, values.len, alloc);
    defer alloc.free(decoded);
    try std.testing.expectEqualSlices(T, values, decoded);
}

test "rle codec" {
    try codecRoundTrip(i32, .rle, &.{ 7, 7, 7, 7, 9, 9, 1, 1, 1, 1, 1 });
    try codecRoundTrip(f64, .rle, &.{ 1.5, 1.5, 1.5, 2.5, 2.5 });
}

test "dict codec" {
    try codecRoundTrip(i32, .dict, &.{ 10, 20, 10, 30, 20, 10, 30, 30, 10, 10 });
    try codecRoundTrip(i64, .dict, &.{ 1 << 40, -(1 << 40), 1 << 40 });
}

test "delta/delta2 codecs" {
    try codecRoundTrip(i64, .delta, &.{ 5, 6, 7, 100, -100, 0 });
    try codecRoundTrip(i32, .delta2, &.{ 1, 2, 4, 7, 11, 16 });
}

test "gorilla codec" {
    try codecRoundTrip(f64, .gorilla, &.{ 1.0, 1.0, 2.0, 2.0, 3.0, -1.0e10, 1.0e-10 });
    try codecRoundTrip(f32, .gorilla, &.{ 1.0, 1.0, 2.0, 2.0, 3.0 });
}

test "plain codec" {
    try codecRoundTrip(i64, .plain, &.{ 1, 2, 3, 4, 5 });
    try codecRoundTrip(f64, .plain, &.{ 1.5, 2.5, -3.25 });
}

test "selector picks rle for long runs" {
    const alloc = std.testing.allocator;
    var values: [200]i32 = undefined;
    for (&values) |*v| v.* = 42;
    var encoded = try encodeColumn(alloc, .{ .i32 = &values });
    defer encoded.deinit(alloc);
    try std.testing.expectEqual(Encoding.rle, encoded.encoding);

    var decoded = try decodeColumn(alloc, encoded.encoding, .i32, encoded.payload, values.len);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualSlices(i32, &values, decoded.i32);
}

test "selector picks dict for low-cardinality wide ints" {
    const alloc = std.testing.allocator;
    var values: [300]i64 = undefined;
    for (&values, 0..) |*v, i| v.* = if (i % 2 == 0) 0 else 1 << 40;
    var encoded = try encodeColumn(alloc, .{ .i64 = &values });
    defer encoded.deinit(alloc);
    try std.testing.expectEqual(Encoding.dict, encoded.encoding);

    var decoded = try decodeColumn(alloc, encoded.encoding, .i64, encoded.payload, values.len);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualSlices(i64, &values, decoded.i64);
}

test "gorilla roundtrip" {
    const alloc = std.testing.allocator;
    var values: [500]f64 = undefined;
    var x: f64 = 1.0;
    for (&values, 0..) |*slot, i| {
        slot.* = @sin(@as(f64, @floatFromInt(i)) / 10.0) * 1000.0 + x;
        x += 0.001;
    }
    var encoded = try encodeColumn(alloc, .{ .f64 = &values });
    defer encoded.deinit(alloc);

    var decoded = try decodeColumn(alloc, encoded.encoding, .f64, encoded.payload, values.len);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualSlices(f64, &values, decoded.f64);
}

test "bool roundtrip" {
    const alloc = std.testing.allocator;
    const values = [_]bool{ true, false, true, true, false, false, true, false, true };
    var encoded = try encodeColumn(alloc, .{ .boolean = &values });
    defer encoded.deinit(alloc);
    try std.testing.expectEqual(Encoding.bool, encoded.encoding);

    var decoded = try decodeColumn(alloc, encoded.encoding, .boolean, encoded.payload, values.len);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualSlices(bool, &values, decoded.boolean);
}

test "bytes roundtrip" {
    const alloc = std.testing.allocator;
    const values = [_][]const u8{ "alpha", "", "gamma-delta", "b" };
    var encoded = try encodeColumn(alloc, .{ .bytes = &values });
    defer encoded.deinit(alloc);
    try std.testing.expectEqual(Encoding.plain, encoded.encoding);

    var decoded = try decodeColumn(alloc, encoded.encoding, .bytes, encoded.payload, values.len);
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(values.len, decoded.bytes.len);
    for (values, decoded.bytes) |a, b| try std.testing.expectEqualStrings(a, b);
}

test "i64 extremes roundtrip" {
    const alloc = std.testing.allocator;
    const values = [_]i64{ std.math.minInt(i64), 0, std.math.maxInt(i64), -1, 1 };
    var encoded = try encodeColumn(alloc, .{ .i64 = &values });
    defer encoded.deinit(alloc);
    var decoded = try decodeColumn(alloc, encoded.encoding, .i64, encoded.payload, values.len);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualSlices(i64, &values, decoded.i64);
}

test "empty column roundtrip" {
    const alloc = std.testing.allocator;
    const values = [_]i64{};
    var encoded = try encodeColumn(alloc, .{ .i64 = &values });
    defer encoded.deinit(alloc);
    var decoded = try decodeColumn(alloc, encoded.encoding, .i64, encoded.payload, 0);
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), decoded.i64.len);
}
