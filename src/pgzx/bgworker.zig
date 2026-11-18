const std = @import("std");

const pgzx = @import("../pgzx.zig");
const pg = pgzx.c;

const elog = @import("elog.zig");
const err = @import("err.zig");
const latch = @import("latch.zig");
const lwlock = @import("lwlock.zig");

pub const BackgroundWorker = pg.BackgroundWorker;

pub const WorkerOptions = struct {
    flags: c_int,
    worker_type: ?[]const u8 = null,
    start_time: pg.BgWorkerStartTime = pg.BgWorkerStart_RecoveryFinished,
    restart_time: c_int = 1,
    main_arg: pg.Datum = 0,
    extra: ?[]const u8 = null,
    notify_pid: pg.pid_t = 0,
};

pub fn register(
    comptime name: []const u8,
    comptime library_name: []const u8,
    comptime function_name: []const u8,
    options: WorkerOptions,
) void {
    var bw = initBackgroundWorker(name, library_name, function_name, options);
    pg.RegisterBackgroundWorker(&bw);
}

pub fn registerDynamic(
    comptime name: []const u8,
    comptime library_name: []const u8,
    comptime function_name: []const u8,
    options: WorkerOptions,
) !*pg.BackgroundWorkerHandle {
    std.log.debug("init background worker: {s} {s} {s}", .{
        name,
        library_name,
        function_name,
    });

    var bw = initBackgroundWorker(name, library_name, function_name, options);
    // The postmaster only signals the backend about start and exit when
    // bgw_notify_pid is set. Without it WaitForBackgroundWorker* never wakes.
    if (options.notify_pid == 0) {
        bw.bgw_notify_pid = pg.MyProcPid;
    }

    std.log.debug("registering dynamic background worker: {s} {s} {s}", .{
        name,
        library_name,
        function_name,
    });
    var handle: ?*pg.BackgroundWorkerHandle = null;
    const ok = pg.RegisterDynamicBackgroundWorker(&bw, &handle);
    if (!ok) {
        return err.PGError.FailStartBackgroundWorker;
    }

    std.log.debug("registered dynamic background worker: {s} {s} {s}", .{
        name,
        library_name,
        function_name,
    });
    return handle.?;
}

/// Block until a dynamic worker has started. Returns its PID. Fails if the
/// worker stopped before starting or the postmaster died.
pub fn waitForStartup(handle: *pg.BackgroundWorkerHandle) !pg.pid_t {
    var pid: pg.pid_t = 0;
    return switch (pg.WaitForBackgroundWorkerStartup(handle, &pid)) {
        pg.BGWH_STARTED => pid,
        pg.BGWH_STOPPED => err.PGError.FailStartBackgroundWorker,
        pg.BGWH_POSTMASTER_DIED => err.PGError.PostmasterDied,
        else => err.PGError.WorkerNotRunning,
    };
}

/// Block until a dynamic worker has exited. Fails if the postmaster died
/// before the worker's exit could be confirmed.
pub fn waitForShutdown(handle: *pg.BackgroundWorkerHandle) !void {
    return switch (pg.WaitForBackgroundWorkerShutdown(handle)) {
        pg.BGWH_STOPPED => {},
        pg.BGWH_POSTMASTER_DIED => err.PGError.PostmasterDied,
        else => err.PGError.WorkerNotRunning,
    };
}

fn initBackgroundWorker(
    comptime name: []const u8,
    comptime library_name: []const u8,
    comptime function_name: []const u8,
    options: WorkerOptions,
) pg.BackgroundWorker {
    var bw = std.mem.zeroInit(pg.BackgroundWorker, .{
        .bgw_flags = options.flags,
        .bgw_start_time = options.start_time,
        .bgw_restart_time = options.restart_time,
        .bgw_main_arg = options.main_arg,
        .bgw_notify_pid = options.notify_pid,
    });

    checkLen(name, bw.bgw_name);
    checkLen(library_name, bw.bgw_library_name);
    checkLen(function_name, bw.bgw_function_name);
    std.mem.copyForwards(u8, @constCast(&bw.bgw_name), name);
    std.mem.copyForwards(u8, @constCast(&bw.bgw_library_name), library_name);
    std.mem.copyForwards(u8, @constCast(&bw.bgw_function_name), function_name);

    if (options.worker_type) |wt| {
        std.mem.copyForwards(u8, @constCast(&bw.bgw_type), wt);
    }
    if (options.extra) |e| {
        std.mem.copyForwards(u8, @constCast(&bw.bgw_extra), e);
    }

    return bw;
}

pub fn checkLen(comptime str: []const u8, into: anytype) void {
    if (str.len > @sizeOf(@TypeOf(into))) {
        @compileError("string is too long to copy");
    }
}

pub inline fn sigFlagHandler(sig: *pgzx.intr.Signal) fn (c_int) callconv(.c) void {
    return struct {
        fn handler(num: c_int) callconv(.c) void {
            sig.set(1);
            finalizeSignal(num);
        }
    }.handler;
}

pub fn finalizeSignal(arg: c_int) void {
    _ = arg;
    const save_errno = std.c._errno().*;
    if (pg.MyProc != null) {
        latch.set(&pg.MyProc.*.procLatch);
    }
    std.c._errno().* = save_errno;
}
