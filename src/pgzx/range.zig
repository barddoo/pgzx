//! Range values (`int4range`, `numrange`, `tsrange`, ...) as Zig structs.
//!
//! This module has no Postgres dependency: it parses and formats the text
//! form, such as `["2020-01-01 00:00:00","2020-02-01 00:00:00")`. The Postgres
//! converters in `datum.zig` move values between this text form and the
//! database.
//!
//! Bounds are either integers (`Int4Range`, `Int8Range`) or text (`TextRange`,
//! for numeric and time types). Text bounds keep their exact spelling, so no
//! precision is lost.

const std = @import("std");

pub const Error = error{InvalidRange} || std.mem.Allocator.Error || std.fmt.ParseIntError;

/// A range over `Bound`. `null` bounds are unbounded. An `empty` range has no
/// bounds and ignores the other fields.
pub fn Range(comptime Bound: type) type {
    return struct {
        const Self = @This();

        empty: bool = false,
        lower: ?Bound = null,
        upper: ?Bound = null,
        lower_inclusive: bool = true,
        upper_inclusive: bool = false,

        /// Parses the text output of a range type. Text bounds are allocated
        /// with `allocator` only when they contain escapes.
        pub fn parse(allocator: std.mem.Allocator, text: []const u8) Error!Self {
            if (std.mem.eql(u8, text, "empty")) return .{ .empty = true };
            if (text.len < 3) return error.InvalidRange;

            var r: Self = .{};
            r.lower_inclusive = switch (text[0]) {
                '[' => true,
                '(' => false,
                else => return error.InvalidRange,
            };
            r.upper_inclusive = switch (text[text.len - 1]) {
                ']' => true,
                ')' => false,
                else => return error.InvalidRange,
            };

            const inner = text[1 .. text.len - 1];
            const comma = try splitIndex(inner);
            r.lower = try parseBound(Bound, allocator, inner[0..comma]);
            r.upper = try parseBound(Bound, allocator, inner[comma + 1 ..]);
            return r;
        }

        /// Formats the range in its text form. The caller owns the result.
        pub fn format(self: Self, allocator: std.mem.Allocator) ![]u8 {
            if (self.empty) return allocator.dupe(u8, "empty");

            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(allocator);

            try out.append(allocator, if (self.lower_inclusive) '[' else '(');
            if (self.lower) |b| try appendBound(Bound, allocator, &out, b);
            try out.append(allocator, ',');
            if (self.upper) |b| try appendBound(Bound, allocator, &out, b);
            try out.append(allocator, if (self.upper_inclusive) ']' else ')');

            return out.toOwnedSlice(allocator);
        }
    };
}

pub const Int4Range = Range(i32);
pub const Int8Range = Range(i64);
pub const TextRange = Range([]const u8);

/// Index of the comma that separates the bounds. Commas inside quoted bounds
/// do not count.
fn splitIndex(s: []const u8) Error!usize {
    var in_quote = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_quote) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                if (i + 1 < s.len and s[i + 1] == '"') {
                    i += 1;
                } else {
                    in_quote = false;
                }
            }
        } else if (c == '"') {
            in_quote = true;
        } else if (c == ',') {
            return i;
        }
    }
    return error.InvalidRange;
}

/// Parses one bound. An empty token is an unbounded side.
fn parseBound(comptime Bound: type, allocator: std.mem.Allocator, raw: []const u8) Error!?Bound {
    if (raw.len == 0) return null;

    const text = if (raw[0] == '"') blk: {
        if (raw.len < 2 or raw[raw.len - 1] != '"') return error.InvalidRange;
        break :blk try unescape(allocator, raw[1 .. raw.len - 1]);
    } else raw;

    return switch (@typeInfo(Bound)) {
        .int => try std.fmt.parseInt(Bound, text, 10),
        else => text,
    };
}

/// Resolves the escapes used inside quoted bounds: a doubled quote and a
/// backslash before any character. Returns the input when there is nothing
/// to resolve.
fn unescape(allocator: std.mem.Allocator, s: []const u8) Error![]const u8 {
    if (std.mem.indexOfAny(u8, s, "\"\\") == null) return s;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len) {
            try out.append(allocator, s[i + 1]);
            i += 2;
        } else if (c == '"' and i + 1 < s.len and s[i + 1] == '"') {
            try out.append(allocator, '"');
            i += 2;
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn appendBound(comptime Bound: type, allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: Bound) !void {
    switch (@typeInfo(Bound)) {
        .int => {
            var buf: [24]u8 = undefined;
            const digits = try std.fmt.bufPrint(&buf, "{d}", .{value});
            try out.appendSlice(allocator, digits);
        },
        else => {
            // Quote every text bound so commas, spaces and brackets inside it
            // cannot change how the range is read.
            try out.append(allocator, '"');
            for (value) |c| {
                if (c == '"' or c == '\\') try out.append(allocator, c);
                try out.append(allocator, c);
            }
            try out.append(allocator, '"');
        },
    }
}

pub const TestSuite_Range = struct {
    const alloc = std.testing.allocator;

    pub fn testParseInt4() !void {
        const r = try Int4Range.parse(alloc, "[1,10)");
        try std.testing.expect(!r.empty);
        try std.testing.expectEqual(@as(?i32, 1), r.lower);
        try std.testing.expectEqual(@as(?i32, 10), r.upper);
        try std.testing.expect(r.lower_inclusive);
        try std.testing.expect(!r.upper_inclusive);
    }

    pub fn testParseUnbounded() !void {
        const r = try Int8Range.parse(alloc, "(,5]");
        try std.testing.expectEqual(@as(?i64, null), r.lower);
        try std.testing.expectEqual(@as(?i64, 5), r.upper);
        try std.testing.expect(!r.lower_inclusive);
        try std.testing.expect(r.upper_inclusive);
    }

    pub fn testParseEmpty() !void {
        const r = try Int4Range.parse(alloc, "empty");
        try std.testing.expect(r.empty);
    }

    pub fn testParseQuotedText() !void {
        const r = try TextRange.parse(alloc, "[\"2020-01-01 00:00:00\",\"2020-02-01, noon\")");
        try std.testing.expectEqualStrings("2020-01-01 00:00:00", r.lower.?);
        try std.testing.expectEqualStrings("2020-02-01, noon", r.upper.?);
    }

    pub fn testParseQuotedTextWithEscapes() !void {
        const r = try TextRange.parse(alloc, "[\"a\"\"b\",\"c\\\\d\")");
        defer alloc.free(r.lower.?);
        defer alloc.free(r.upper.?);
        try std.testing.expectEqualStrings("a\"b", r.lower.?);
        try std.testing.expectEqualStrings("c\\d", r.upper.?);
    }

    pub fn testParseQuotedTextNoAllocation() !void {
        const r = try TextRange.parse(alloc, "[\"a,b\",c)");
        try std.testing.expectEqualStrings("a,b", r.lower.?);
        try std.testing.expectEqualStrings("c", r.upper.?);
    }

    pub fn testFormatRoundTrip() !void {
        const r: Int4Range = .{ .lower = 2, .upper = 7, .upper_inclusive = true };
        const text = try r.format(alloc);
        defer alloc.free(text);
        try std.testing.expectEqualStrings("[2,7]", text);

        const back = try Int4Range.parse(alloc, text);
        try std.testing.expectEqual(r.upper, back.upper);
    }

    pub fn testFormatEmptyAndUnbounded() !void {
        const empty: Int4Range = .{ .empty = true };
        const e = try empty.format(alloc);
        defer alloc.free(e);
        try std.testing.expectEqualStrings("empty", e);

        const open: Int4Range = .{ .lower = null, .upper = null, .lower_inclusive = false };
        const o = try open.format(alloc);
        defer alloc.free(o);
        try std.testing.expectEqualStrings("(,)", o);
    }

    pub fn testFormatQuotesText() !void {
        const r: TextRange = .{ .lower = "a,\"b\"", .upper = "z" };
        const text = try r.format(alloc);
        defer alloc.free(text);
        try std.testing.expectEqualStrings("[\"a,\"\"b\"\"\",\"z\")", text);
    }

    pub fn testInvalidInput() !void {
        try std.testing.expectError(error.InvalidRange, Int4Range.parse(alloc, "1,2"));
        try std.testing.expectError(error.InvalidRange, Int4Range.parse(alloc, "[1,2"));
        try std.testing.expectError(error.InvalidRange, Int4Range.parse(alloc, "[12)"));
    }
};
