// The SQL-visible functions. This module is import-safe for the schema
// generator because it does not export or register anything.
//
// The functions show two things:
//
//   * `pgzx.fd` - synchronous, backend-safe file access through PostgreSQL's
//     virtual file descriptor layer. A backend must not use std.fs / open(2)
//     directly: fd.c enforces max_files_per_process, shares descriptors via
//     the LRU, and removes temporary files at transaction end.
//
//   * `pgzx.aio` - PG18's asynchronous reads on top of a VFD. It is only
//     available on PG18+; the async path is exercised by the unit test below
//     and skipped on older servers.

const std = @import("std");
const pgzx = @import("pgzx");

/// Write `data` to a transaction-scoped temporary file, fsync it, then read it
/// back and return the contents.
pub fn file_io_roundtrip(data: []const u8) ![]const u8 {
    var file = try pgzx.fd.openTemp(false);
    defer file.close();

    _ = try file.writeAll(data, 0);
    try file.sync();

    const size = try file.size();
    if (size != data.len) {
        return pgzx.elog.Error(@src(), "unexpected size {d} for {d} bytes", .{ size, data.len });
    }

    const out = try pgzx.mem.PGCurrentContextAllocator.alloc(u8, data.len);
    const n = try file.readAll(out, 0);
    if (n != data.len) {
        return pgzx.elog.Error(@src(), "short read: {d} of {d} bytes", .{ n, data.len });
    }
    return out;
}

/// Write `data` to a temporary file, truncate it to `keep` bytes, and return
/// what remains.
pub fn file_io_truncate(data: []const u8, keep: i32) ![]const u8 {
    if (keep < 0 or keep > data.len) {
        return pgzx.elog.Error(@src(), "keep ({d}) is out of range for {d} bytes", .{ keep, data.len });
    }
    const keep_len: usize = @intCast(keep);

    var file = try pgzx.fd.openTemp(false);
    defer file.close();

    _ = try file.writeAll(data, 0);
    try file.truncate(keep);

    const out = try pgzx.mem.PGCurrentContextAllocator.alloc(u8, keep_len);
    const n = try file.readAll(out, 0);
    if (n != keep_len) {
        return pgzx.elog.Error(@src(), "short read after truncate: {d} of {d}", .{ n, keep_len });
    }
    return out;
}

/// Async counterpart of `file_io_roundtrip`, using a PG18 AIO handle.
///
/// Only referenced when `pgzx.aio.enabled`; the buffer is backend-local, so we
/// declare `.local` and the I/O falls back to synchronous execution instead of
/// an I/O worker.
fn aioRoundtrip(data: []const u8) ![]const u8 {
    var file = try pgzx.fd.openTemp(false);
    defer file.close();

    _ = try file.writeAll(data, 0);
    try file.sync();

    const out = try pgzx.mem.PGCurrentContextAllocator.alloc(u8, data.len);

    var handle = try pgzx.aio.AioHandle.acquire();
    defer handle.release();

    try file.startReadV(&handle, &.{out}, 0, .local);
    if (try handle.wait() != .ok) {
        return pgzx.elog.Error(@src(), "async read failed", .{});
    }
    return out;
}

pub const Testsuite = struct {
    pub fn testSyncRoundtrip() !void {
        const data = "pgzx file_io example";
        try std.testing.expectEqualStrings(data, try file_io_roundtrip(data));
        try std.testing.expectEqualStrings("", try file_io_roundtrip(""));
    }

    pub fn testTruncate() !void {
        try std.testing.expectEqualStrings("0123", try file_io_truncate("0123456789", 4));
        try std.testing.expectEqualStrings("", try file_io_truncate("0123456789", 0));
    }

    pub fn testAsyncRoundtrip() !void {
        // The async I/O subsystem only exists on PG18+.
        if (comptime pgzx.aio.enabled) {
            const data = "pgzx async file_io example";
            try std.testing.expectEqualStrings(data, try aioRoundtrip(data));
        }
    }
};
