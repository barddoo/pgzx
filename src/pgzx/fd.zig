//! Backend-safe file I/O through PostgreSQL's virtual file descriptor layer
//! (src/backend/storage/file/fd.c).
//!
//! A backend must not use std.fs / open(2) for files it holds open: fd.c is
//! what keeps the process under `max_files_per_process`, shares descriptors
//! through the LRU, and removes temporary files at transaction end. Use this
//! module for every file a backend opens.
//!
//! Error conventions mirror fd.c exactly:
//!   * open-family returns -1 (errno set)               -> `FileError`.
//!   * I/O on an open File calls ereport(ERROR)         -> `err.wrap`.
//! `err.wrap` turns that longjmp into a Zig error so defer/errdefer run;
//! re-throw with `err.pgRethrow` before returning to Postgres.
//!
//! PG18 asynchronous reads are layered on top in `aio.zig`; only reads are
//! async through the VFD API (`FileStartReadV`). `File.startReadV` bridges to
//! an `aio.AioHandle`.

const std = @import("std");

const pg = @import("pgzx_pgsys");
const elog = @import("elog.zig");
const err = @import("err.zig");
const aio = @import("aio.zig");

pub const RawFile = pg.File;
pub const Mode = pg.mode_t;

// FileRead/FileWrite changed shape across versions:
//   PG15        FileRead(File, char *, int, ...)
//   PG16+       FileRead(File, void *, size_t, ...)
//   PG17+       static inline over FileReadV/FileWriteV (same void */size_t)
const ReadBuffer = if (pg.PG_VERSION_NUM >= 160000) ?*anyopaque else [*c]u8;
const WriteBuffer = if (pg.PG_VERSION_NUM >= 160000) ?*const anyopaque else [*c]u8;
const BufferLen = if (pg.PG_VERSION_NUM >= 160000) usize else c_int;

/// Wait event reported for every fd.c call made through this module.
pub inline fn waitEvent() u32 {
    return aio.waitEvent();
}

pub const FileError = error{OpenFailed};

/// How to open a virtual file. `append` is deliberately not offered: fd.c
/// writes with pwrite at an explicit offset, so O_APPEND would be
/// inconsistent with FileWrite.
pub const OpenFlags = struct {
    read: bool = true,
    write: bool = false,
    create: bool = false,
    exclusive: bool = false,
    truncate: bool = false,

    pub fn toC(self: OpenFlags) c_int {
        var f: c_int = if (self.write)
            (if (self.read) pg.O_RDWR else pg.O_WRONLY)
        else
            pg.O_RDONLY;
        if (self.create) f |= pg.O_CREAT;
        if (self.exclusive) f |= pg.O_EXCL;
        if (self.truncate) f |= pg.O_TRUNC;
        return f | pg.PG_BINARY;
    }
};

/// RAII wrapper around a Postgres `File`. A File is a VFD slot, not an OS fd;
/// always close via `close`/`deinit`.
pub const File = struct {
    fd: RawFile,

    const Self = @This();
    const INVALID: RawFile = -1;

    pub fn close(self: *Self) void {
        if (self.fd >= 0) {
            pg.FileClose(self.fd);
            self.fd = INVALID;
        }
    }

    pub fn deinit(self: *Self) void {
        self.close();
    }

    /// The raw `File` value, for passing to lower-level APIs.
    pub fn raw(self: *Self) RawFile {
        return self.fd;
    }

    pub fn read(self: *Self, buf: []u8, offset: i64) err.ElogIndicator!usize {
        const n = try err.wrap(pg.FileRead, .{
            self.fd,
            @as(ReadBuffer, @ptrCast(buf.ptr)),
            @as(BufferLen, @intCast(buf.len)),
            @as(pg.off_t, @intCast(offset)),
            waitEvent(),
        });
        if (n < 0) return error.PGErrorStack;
        return @intCast(n);
    }

    pub fn write(self: *Self, buf: []const u8, offset: i64) err.ElogIndicator!usize {
        const n = try err.wrap(pg.FileWrite, .{
            self.fd,
            // PG15 takes `char *`, so the const cast is needed there.
            if (comptime pg.PG_VERSION_NUM >= 160000)
                @as(WriteBuffer, @ptrCast(buf.ptr))
            else
                @as(WriteBuffer, @ptrCast(@constCast(buf.ptr))),
            @as(BufferLen, @intCast(buf.len)),
            @as(pg.off_t, @intCast(offset)),
            waitEvent(),
        });
        if (n < 0) return error.PGErrorStack;
        return @intCast(n);
    }

    pub fn readAll(self: *Self, buf: []u8, offset: i64) err.ElogIndicator!usize {
        var done: usize = 0;
        while (done < buf.len) {
            const n = try self.read(buf[done..], offset + @as(i64, @intCast(done)));
            if (n == 0) break;
            done += n;
        }
        return done;
    }

    pub fn writeAll(self: *Self, buf: []const u8, offset: i64) err.ElogIndicator!usize {
        var done: usize = 0;
        while (done < buf.len) {
            const n = try self.write(buf[done..], offset + @as(i64, @intCast(done)));
            if (n == 0) break;
            done += n;
        }
        return done;
    }

    pub fn size(self: *Self) err.ElogIndicator!i64 {
        return @intCast(try err.wrap(pg.FileSize, .{self.fd}));
    }

    pub fn sync(self: *Self) err.ElogIndicator!void {
        _ = try err.wrap(pg.FileSync, .{ self.fd, waitEvent() });
    }

    pub fn truncate(self: *Self, offset: i64) err.ElogIndicator!void {
        _ = try err.wrap(pg.FileTruncate, .{ self.fd, @as(pg.off_t, @intCast(offset)), waitEvent() });
    }

    pub fn prefetch(self: *Self, offset: i64, amount: i64) err.ElogIndicator!void {
        _ = try err.wrap(pg.FilePrefetch, .{
            self.fd,
            @as(pg.off_t, @intCast(offset)),
            @as(pg.off_t, @intCast(amount)),
            waitEvent(),
        });
    }

    pub fn writeback(self: *Self, offset: i64, nbytes: i64) err.ElogIndicator!void {
        try err.wrap(pg.FileWriteback, .{
            self.fd,
            @as(pg.off_t, @intCast(offset)),
            @as(pg.off_t, @intCast(nbytes)),
            waitEvent(),
        });
    }

    /// PG16+.
    pub fn zero(self: *Self, offset: i64, amount: i64) err.ElogIndicator!void {
        if (comptime pg.PG_VERSION_NUM < 160000) {
            @compileError("fd.File.zero requires PostgreSQL 16 or newer");
        }
        _ = try err.wrap(pg.FileZero, .{
            self.fd,
            @as(pg.off_t, @intCast(offset)),
            @as(pg.off_t, @intCast(amount)),
            waitEvent(),
        });
    }

    /// PG16+.
    pub fn fallocate(self: *Self, offset: i64, amount: i64) err.ElogIndicator!void {
        if (comptime pg.PG_VERSION_NUM < 160000) {
            @compileError("fd.File.fallocate requires PostgreSQL 16 or newer");
        }
        _ = try err.wrap(pg.FileFallocate, .{
            self.fd,
            @as(pg.off_t, @intCast(offset)),
            @as(pg.off_t, @intCast(amount)),
            waitEvent(),
        });
    }

    /// The VFD file name. Valid only while the file is open.
    pub fn pathName(self: *Self) err.ElogIndicator![:0]const u8 {
        const p = try err.wrap(pg.FilePathName, .{self.fd});
        return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
    }

    /// The underlying kernel fd. Only for libraries that insist on an int fd;
    /// never close it yourself, and treat it as invalid after `close`.
    pub fn rawDesc(self: *Self) c_int {
        return pg.FileGetRawDesc(self.fd);
    }

    pub fn rawFlags(self: *Self) c_int {
        return pg.FileGetRawFlags(self.fd);
    }

    pub fn rawMode(self: *Self) Mode {
        return pg.FileGetRawMode(self.fd);
    }

    /// PG18+: issue an asynchronous read of `bufs` through `h`.
    ///
    /// `bufs` must stay valid and pinned until `h.wait()` returns, and
    /// `locality` must reflect where they live (see aio.BufferLocality).
    pub fn startReadV(
        self: *Self,
        h: *aio.AioHandle,
        bufs: []const []u8,
        offset: i64,
        locality: aio.BufferLocality,
    ) err.ElogIndicator!void {
        return h.startReadFile(self.fd, bufs, offset, locality);
    }
};

/// Open an existing file. Returns a Zig error (errno is preserved) instead of
/// throwing; use `openOrReport` for the Postgres-idiomatic longjmp.
pub fn open(path: [:0]const u8, flags: OpenFlags) FileError!File {
    const f = pg.PathNameOpenFile(path.ptr, flags.toC());
    if (f < 0) return error.OpenFailed;
    return .{ .fd = f };
}

/// Like `open`, but raises a Postgres ERROR (errcode_for_file_access) on
/// failure. Safe here: no resources are held yet, so the longjmp skips
/// nothing.
pub fn openOrReport(path: [:0]const u8, flags: OpenFlags) File {
    return open(path, flags) catch {
        elog.ereport(@src(), .Error, .{
            elog.errcodeForFile(),
            elog.errmsg("could not open file \"{s}\": {s}", .{
                path,
                std.c.strerror(std.c._errno().*),
            }),
        });
        unreachable;
    };
}

/// Open with an explicit mode, e.g. for O_CREAT.
pub fn create(path: [:0]const u8, flags: OpenFlags, mode: Mode) FileError!File {
    const f = pg.PathNameOpenFilePerm(path.ptr, flags.toC(), mode);
    if (f < 0) return error.OpenFailed;
    return .{ .fd = f };
}

/// Open a transaction-scoped temporary file. fd.c removes it on close, and at
/// end of (sub)transaction when `inter_xact` is false.
pub fn openTemp(inter_xact: bool) FileError!File {
    const f = pg.OpenTemporaryFile(inter_xact);
    if (f < 0) return error.OpenFailed;
    return .{ .fd = f };
}

/// Escape hatch: a raw kernel fd registered with fd.c so it still counts
/// toward the FD budget. Close with `close`.
pub const TransientFile = struct {
    fd: c_int,

    const Self = @This();

    pub fn close(self: *Self) void {
        if (self.fd >= 0) {
            _ = pg.CloseTransientFile(self.fd);
            self.fd = -1;
        }
    }

    pub fn deinit(self: *Self) void {
        self.close();
    }
};

pub fn openTransient(path: [:0]const u8, flags: OpenFlags) FileError!TransientFile {
    const fd = pg.OpenTransientFile(path.ptr, flags.toC());
    if (fd < 0) return error.OpenFailed;
    return .{ .fd = fd };
}

pub fn maxFilesPerProcess() c_int {
    return pg.max_files_per_process;
}

/// PG16+; 0 on older versions.
pub fn ioDirectFlags() c_int {
    if (comptime pg.PG_VERSION_NUM >= 160000) return pg.io_direct_flags;
    return 0;
}

/// PG16+; 0 on older versions.
pub fn fileExtendMethod() c_int {
    if (comptime pg.PG_VERSION_NUM >= 160000) return pg.file_extend_method;
    return 0;
}

pub const TestSuite_Fd = struct {
    pub fn testTemporaryFileRoundTrip() !void {
        var f = try openTemp(false);
        defer f.close();

        const data = "pgzx vfd";
        _ = try f.writeAll(data, 0);
        try f.sync();
        try std.testing.expectEqual(@as(i64, data.len), try f.size());

        var buf: [data.len]u8 = undefined;
        const n = try f.readAll(&buf, 0);
        try std.testing.expectEqual(data.len, n);
        try std.testing.expectEqualStrings(data, &buf);
    }

    pub fn testTruncate() !void {
        var f = try openTemp(false);
        defer f.close();

        _ = try f.writeAll("0123456789", 0);
        try f.truncate(4);
        try std.testing.expectEqual(@as(i64, 4), try f.size());
    }

    pub fn testOpenMissing() !void {
        try std.testing.expectError(
            error.OpenFailed,
            open("/pgzx/does-not-exist", .{ .read = true }),
        );
    }
};
