const std = @import("std");
const pgzx = @import("pgzx");
const pg = pgzx.c;

comptime {
    pgzx.PG_MODULE_MAGIC();

    pgzx.PG_FUNCTION_V1("pgzx_bgworker_roundtrip", bgworker_roundtrip);
    pgzx.PG_FUNCTION_V1("pgzx_bgworker_double", bgworker_double);
}

const BGWORKER_LIB = "bgworker";
const BGWORKER_FUNC = "bgworker_main";
const BGWORKER_DYNAMIC_FUNC = "bgworker_dynamic_main";
const BGWORKER_DSM_FUNC = "bgworker_dsm_main";

// Background worker main function. Runs in a separate process launched by the
// postmaster.
export fn bgworker_main(main_arg: pg.Datum) callconv(.c) void {
    _ = main_arg;

    // Unblock signals that the postmaster set up before launching us.
    pg.BackgroundWorkerUnblockSignals();

    pgzx.elog.Log(@src(), "pgzx bgworker example: worker started", .{});

    pg.proc_exit(0);
}

// Dynamic worker main function. Sleeps on its latch until the postmaster asks
// it to terminate, then exits through CheckForInterrupts.
export fn bgworker_dynamic_main(main_arg: pg.Datum) callconv(.c) void {
    _ = main_arg;

    pg.BackgroundWorkerUnblockSignals();

    while (true) {
        pgzx.latch.reset(pgzx.latch.my());
        _ = pgzx.latch.wait(pgzx.latch.my(), .{
            .timeout_ms = 1000,
            .exit_on_postmaster_death = true,
        });
        pgzx.intr.CheckForInterrupts() catch pg.proc_exit(1);
    }
}

// Start a dynamic worker, wait until it is running, terminate it and wait for
// it to exit. Returns true when every step succeeds.
pub fn bgworker_roundtrip() !bool {
    const handle = try pgzx.bgworker.registerDynamic(
        "pgzx_bgworker_dynamic",
        BGWORKER_LIB,
        BGWORKER_DYNAMIC_FUNC,
        .{
            .flags = pg.BGWORKER_SHMEM_ACCESS,
            .worker_type = "bgworker",
            .restart_time = pg.BGW_NEVER_RESTART,
        },
    );

    const pid = try pgzx.bgworker.waitForStartup(handle);
    pg.TerminateBackgroundWorker(handle);
    try pgzx.bgworker.waitForShutdown(handle);

    return pid > 0;
}

// Dynamic worker that reads an i64 from a shared segment, writes back twice the
// value and exits. The segment handle arrives as the main argument.
export fn bgworker_dsm_main(main_arg: pg.Datum) callconv(.c) void {
    pg.BackgroundWorkerUnblockSignals();

    const seg = pgzx.dsm.attach(@intCast(main_arg)) catch pg.proc_exit(1);
    const slots: *[2]i64 = @ptrCast(@alignCast(pgzx.dsm.address(seg)));
    slots[1] = slots[0] * 2;
    pgzx.dsm.detach(seg);
    pg.proc_exit(0);
}

// Sentinel the worker overwrites. Seeing it afterwards means the worker never ran.
const NOT_RUN: i64 = -1;

// Hands `value` to a worker through a shared segment and returns the doubled
// value the worker wrote back.
pub fn bgworker_double(value: i64) !i64 {
    const seg = try pgzx.dsm.create(@sizeOf([2]i64));
    defer pgzx.dsm.detach(seg);

    const slots: *[2]i64 = @ptrCast(@alignCast(pgzx.dsm.address(seg)));
    slots.* = .{ value, NOT_RUN };

    const handle = try pgzx.bgworker.registerDynamic(
        "pgzx_bgworker_dsm",
        BGWORKER_LIB,
        BGWORKER_DSM_FUNC,
        .{
            .flags = pg.BGWORKER_SHMEM_ACCESS,
            .worker_type = "bgworker",
            .restart_time = pg.BGW_NEVER_RESTART,
            .main_arg = @intCast(pgzx.dsm.handle(seg)),
        },
    );
    // Wait for exit only: a worker that already finished would make the
    // startup wait fail, and shutdown waits correctly for a worker not yet started.
    try pgzx.bgworker.waitForShutdown(handle);

    if (slots[1] == NOT_RUN) return error.WorkerDidNotRun;
    return slots[1];
}

// Register the background worker. Static workers registered in _PG_init are
// launched by the postmaster on the next server start.
pub export fn _PG_init() void {
    pgzx.bgworker.register(
        "pgzx_bgworker",
        BGWORKER_LIB,
        BGWORKER_FUNC,
        .{
            .flags = pg.BGWORKER_SHMEM_ACCESS,
            .worker_type = "bgworker",
            .restart_time = pg.BGW_NEVER_RESTART,
        },
    );
}
