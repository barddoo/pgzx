//! Minimal little-endian byte writer/reader and varint helpers used by the
//! compression codecs and the batch on-disk format. This module is pure Zig
//! and has no dependency on the PostgreSQL server, so it can be unit tested
//! with `zig build test`.

const std = @import("std");

pub const Writer = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,

    pub fn init(alloc: std.mem.Allocator) Writer {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Writer) void {
        self.list.deinit(self.alloc);
    }

    pub fn len(self: *const Writer) usize {
        return self.list.items.len;
    }

    pub fn byte(self: *Writer, b: u8) !void {
        try self.list.append(self.alloc, b);
    }

    pub fn slice(self: *Writer, s: []const u8) !void {
        try self.list.appendSlice(self.alloc, s);
    }

    /// Write a little-endian scalar.
    pub fn int(self: *Writer, comptime T: type, v: T) !void {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, v, .little);
        try self.slice(&buf);
    }

    /// LEB128 unsigned varint.
    pub fn varU64(self: *Writer, value: u64) !void {
        var v = value;
        while (v >= 0x80) {
            try self.byte(@as(u8, @truncate(v)) | 0x80);
            v >>= 7;
        }
        try self.byte(@as(u8, @truncate(v)));
    }

    pub fn zigzag(self: *Writer, value: i64) !void {
        try self.varU64(zigzagEncode(value));
    }

    /// Pad with zero bytes until the buffer length is a multiple of `align_to`.
    pub fn padTo(self: *Writer, comptime align_to: usize) !void {
        while (self.len() % align_to != 0) try self.byte(0);
    }

    pub fn toOwned(self: *Writer) ![]u8 {
        return self.list.toOwnedSlice(self.alloc);
    }
};

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    pub fn remaining(self: *const Reader) usize {
        return self.data.len - self.pos;
    }

    pub fn byte(self: *Reader) !u8 {
        if (self.pos >= self.data.len) return error.Truncated;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn slice(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.data.len) return error.Truncated;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    pub fn int(self: *Reader, comptime T: type) !T {
        var buf: [@sizeOf(T)]u8 = undefined;
        const s = try self.slice(@sizeOf(T));
        @memcpy(&buf, s);
        return std.mem.readInt(T, &buf, .little);
    }

    pub fn varU64(self: *Reader) !u64 {
        var result: u64 = 0;
        var shift: usize = 0;
        while (true) {
            const b = try self.byte();
            if (shift >= 64) return error.Truncated;
            result |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) return result;
            shift += 7;
        }
    }

    pub fn zigzag(self: *Reader) !i64 {
        return zigzagDecode(try self.varU64());
    }
};

pub inline fn zigzagEncode(x: i64) u64 {
    const u: u64 = @bitCast(x);
    return (u << 1) ^ @as(u64, @bitCast(x >> 63));
}

pub inline fn zigzagDecode(v: u64) i64 {
    const sign: u64 = 0 -% (v & 1);
    return @bitCast((v >> 1) ^ sign);
}

test "varint roundtrip" {
    const alloc = std.testing.allocator;
    var w = Writer.init(alloc);
    defer w.deinit();

    const vals = [_]u64{ 0, 1, 127, 128, 300, 16383, 16384, std.math.maxInt(u64) };
    for (vals) |v| try w.varU64(v);

    var r = Reader.init(w.list.items);
    for (vals) |v| try std.testing.expectEqual(v, try r.varU64());
}

test "zigzag roundtrip" {
    const vals = [_]i64{ 0, 1, -1, 2, -2, 123456, -123456, std.math.maxInt(i64), std.math.minInt(i64) };
    for (vals) |v| try std.testing.expectEqual(v, zigzagDecode(zigzagEncode(v)));
}

test "int roundtrip" {
    const alloc = std.testing.allocator;
    var w = Writer.init(alloc);
    defer w.deinit();

    try w.int(u32, 0xDEADBEEF);
    try w.int(i16, -32768);

    var r = Reader.init(w.list.items);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try r.int(u32));
    try std.testing.expectEqual(@as(i16, -32768), try r.int(i16));
    try std.testing.expectError(error.Truncated, r.int(u32));
}
