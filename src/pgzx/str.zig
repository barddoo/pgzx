const std = @import("std");
const mem = @import("mem.zig");

pub const CString = [:0]const u8;
pub const CStringPtr = [*c]const u8;

/// Return a formatted string or error.
///
/// The string will be allocated on the current PostgreSQL memory context.
pub fn format(
    comptime fmt: []const u8,
    args: anytype,
) !CString {
    return try std.fmt.allocPrintSentinel(mem.PGCurrentContextAllocator, fmt, args, 0);
}

/// Return a formatted string or error.
/// The memory for the message is allocated from the given allocator (or
/// mem.PGCurrentContextAllocator if null).
pub fn formatMemCtx(
    alloc: ?*mem.MemoryContextAllocator,
    comptime fmt: []const u8,
    args: anytype,
) !CString {
    const use_alloc = if (alloc) |a| a.allocator() else mem.PGCurrentContextAllocator;
    return try std.fmt.allocPrintSentinel(use_alloc, fmt, args, 0);
}

pub const TestSuite_Str = struct {
    pub fn testFormat() !void {
        const s = try format("hello {s} {d}", .{ "world", 42 });
        try std.testing.expectEqualStrings("hello world 42", s);
    }

    pub fn testFormatMemCtx() !void {
        const s = try formatMemCtx(null, "value {d}", .{7});
        try std.testing.expectEqualStrings("value 7", s);
    }
};
