//! Bindings for PostgreSQL 18's asynchronous I/O subsystem (storage/aio.c).
//!
//! PG18 added `io_method` = sync|worker|io_uring, dedicated I/O worker
//! processes, and per-backend `PgAioHandle`s owned by the resource owner.
//! Through the virtual file descriptor layer only reads are asynchronous:
//! `FileStartReadV()` is the sole async entry point in fd.h (there is no
//! async write for VFDs). Writes stay synchronous — see `fd.File`.
//!
//! The interesting types (`PgAioResult`, `PgAioReturn`) carry C bitfields,
//! which zig's translate-c demotes to opaque. The small C shim in
//! src/pgzx/c/aio.c owns that storage and exposes the accessors below.
//!
//! WORKER SAFETY: with the default `io_method = worker`, an I/O may be
//! executed by a different process. Buffers that live in backend-local memory
//! (palloc'd, local buffers, stack) can then not be written: you must declare
//! them `BufferLocality.local` so the I/O falls back to synchronous execution.
//! Anything reachable from the worker must be in shared memory.
//!
//! Handle lifetime is the resource owner (i.e. the transaction): on an ERROR
//! the handle is released by Postgres and any Zig reference to it is dangling.
//! Use `defer h.release()` on the normal path and never let a handle escape
//! the transaction.

const std = @import("std");

const pg = @import("pgzx_pgsys");
const err = @import("err.zig");

/// Async I/O does not exist before PG18.
pub const enabled = pg.PG_VERSION_NUM >= 180000;

/// Wait event reported for IO started through this module.
pub inline fn waitEvent() u32 {
    return pg.PG_WAIT_EXTENSION;
}

/// Values of the `io_method` GUC.
pub const IoMethod = enum(c_int) {
    sync = 0,
    worker = 1,
    /// Only present when built with liburing and without EXEC_BACKEND.
    io_uring = 2,
};

pub fn ioMethod() IoMethod {
    return if (comptime enabled) @enumFromInt(pg.io_method) else .sync;
}

/// Where the buffers handed to an async read live.
pub const BufferLocality = enum { shared, local };

/// Completion status of an async I/O. The names are stable across versions;
/// only PG18+ can actually produce a non-`unknown` status.
pub const Status = if (!enabled) enum { unknown, ok, partial, warning, failed } else enum(c_int) {
    unknown = pg.PGAIO_RS_UNKNOWN,
    ok = pg.PGAIO_RS_OK,
    partial = pg.PGAIO_RS_PARTIAL,
    warning = pg.PGAIO_RS_WARNING,
    failed = pg.PGAIO_RS_ERROR,
};

pub const AioHandle = if (!enabled) struct {
    // Pre-PG18 stubs so callers can compile against a uniform API.
    pub fn acquire() err.ElogIndicator!AioHandle {
        return error.PGErrorStack;
    }
    pub fn release(_: *AioHandle) void {}
    pub fn deinit(self: *AioHandle) void {
        self.release();
    }
    pub fn startReadFile(_: *AioHandle, _: pg.File, _: []const []u8, _: i64, _: BufferLocality) err.ElogIndicator!void {
        return error.PGErrorStack;
    }
    pub fn wait(_: *AioHandle) err.ElogIndicator!Status {
        return error.PGErrorStack;
    }
    pub fn result(_: *AioHandle) i32 {
        return 0;
    }
} else struct {
    ptr: *pg.pgzx_aio,

    const Self = @This();

    /// Acquire a handle from the current resource owner. The handle (and its
    /// result storage) is freed with the transaction.
    pub fn acquire() err.ElogIndicator!Self {
        const p = try err.wrap(pg.pgzx_aio_acquire, .{});
        if (p) |ptr| return .{ .ptr = ptr };
        return error.PGErrorStack;
    }

    /// Release the handle's storage. Must be called after `wait` when an IO was
    /// started (the handle itself is reclaimed by completion/resowner); an
    /// unstarted handle is released back to the pool.
    pub fn release(self: *Self) void {
        pg.pgzx_aio_release(self.ptr);
    }

    pub fn deinit(self: *Self) void {
        self.release();
    }

    /// Start a read of `bufs` into the virtual `file` at `offset`.
    ///
    /// The buffers must stay valid and pinned until `wait` returns. Set
    /// `locality` honestly: `.local` is required for anything not in shared
    /// memory, otherwise a worker process reads into memory you cannot see.
    pub fn startReadFile(
        self: *Self,
        file: pg.File,
        bufs: []const []u8,
        offset: i64,
        locality: BufferLocality,
    ) err.ElogIndicator!void {
        var iovcnt: c_int = 0;
        const iov = pg.pgzx_aio_iovec(self.ptr, &iovcnt);
        if (iov == null or bufs.len == 0 or bufs.len > @as(usize, @intCast(iovcnt)))
            return error.PGErrorStack;

        for (bufs, 0..) |buf, i| {
            iov[i].iov_base = @ptrCast(buf.ptr);
            iov[i].iov_len = buf.len;
        }
        pg.pgzx_aio_set_local(self.ptr, locality == .local);

        const rc = try err.wrap(pg.pgzx_aio_start_read_file, .{
            self.ptr,
            file,
            @as(c_int, @intCast(bufs.len)),
            @as(pg.off_t, @intCast(offset)),
            waitEvent(),
        });
        if (rc != 0) return error.PGErrorStack;
    }

    /// Block until the I/O completes (or fails).
    pub fn wait(self: *Self) err.ElogIndicator!Status {
        const status = try err.wrap(pg.pgzx_aio_wait, .{self.ptr});
        return @enumFromInt(status);
    }

    /// Bytes transferred (meaning is op-specific; for reads, bytes read).
    /// Only meaningful after `wait`.
    pub fn result(self: *Self) i32 {
        return pg.pgzx_aio_result(self.ptr);
    }
};

pub const TestSuite_Aio = struct {
    pub fn testReadTempFile() !void {
        // Skipped before PG18: the whole subsystem does not exist there.
        if (comptime enabled) {
            const file = pg.OpenTemporaryFile(false);
            if (file < 0) return error.OpenFailed;
            defer pg.FileClose(file);

            const payload = "pgzx async read";
            _ = pg.FileWrite(file, payload.ptr, payload.len, 0, waitEvent());

            var buf: [payload.len]u8 = undefined;
            var h = try AioHandle.acquire();
            defer h.release();

            try h.startReadFile(file, &.{&buf}, 0, .local);
            const status = try h.wait();
            try std.testing.expectEqual(Status.ok, status);
            try std.testing.expectEqual(@as(i32, payload.len), h.result());
            try std.testing.expectEqualStrings(payload, &buf);
        }
    }
};
