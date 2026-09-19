const std = @import("std");
const pgzx = @import("pgzx");
const pg = pgzx.c;

comptime {
    pgzx.PG_MODULE_MAGIC();
}

const BGWORKER_LIB = "bgworker";
const BGWORKER_FUNC = "bgworker_main";

// Background worker main function. Runs in a separate process launched by the
// postmaster.
export fn bgworker_main(main_arg: pg.Datum) callconv(.c) void {
    _ = main_arg;

    // Unblock signals that the postmaster set up before launching us.
    pg.BackgroundWorkerUnblockSignals();

    pgzx.elog.Log(@src(), "pgzx bgworker example: worker started", .{});

    pg.proc_exit(0);
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
