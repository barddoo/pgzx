const std = @import("std");

const pg = @import("pgzx_pgsys");

const intr = @import("interrupts.zig");

pub const Latch = pg.Latch;

/// Latch belonging to the current process.
pub inline fn my() *Latch {
    return pg.MyLatch;
}

/// Wake any process waiting on `latch`. Safe to call from signal handlers.
pub inline fn set(latch: *Latch) void {
    pg.SetLatch(latch);
}

/// Clear the latch. Reset before checking the condition you are waiting for,
/// otherwise a wakeup that arrives in between is lost.
pub inline fn reset(latch: *Latch) void {
    pg.ResetLatch(latch);
}

pub const Options = struct {
    /// Maximum time to wait in milliseconds. `null` waits until the latch is set.
    timeout_ms: ?i64 = null,

    /// `true` exits the process immediately when the postmaster dies. `false`
    /// returns `Result.postmaster_died` so the caller can clean up first.
    exit_on_postmaster_death: bool = false,

    /// Wait event reported in pg_stat_activity while waiting.
    wait_event: u32 = pg.PG_WAIT_EXTENSION,
};

pub const Result = struct {
    latch_set: bool = false,
    timeout: bool = false,
    postmaster_died: bool = false,
    socket_readable: bool = false,
    socket_writeable: bool = false,

    fn fromBits(rc: c_int) Result {
        return .{
            .latch_set = rc & pg.WL_LATCH_SET != 0,
            .timeout = rc & pg.WL_TIMEOUT != 0,
            .postmaster_died = rc & pg.WL_POSTMASTER_DEATH != 0,
            .socket_readable = rc & pg.WL_SOCKET_READABLE != 0,
            .socket_writeable = rc & pg.WL_SOCKET_WRITEABLE != 0,
        };
    }
};

/// Wait until `latch` is set, the timeout expires, or the postmaster dies.
/// Does not process pending interrupts; call `intr.CheckForInterrupts` after
/// a wakeup if the process should respond to them.
pub fn wait(latch: *Latch, opts: Options) Result {
    const events = waitEvents(opts);
    const rc = pg.WaitLatch(latch, events, opts.timeout_ms orelse 0, opts.wait_event);
    return Result.fromBits(rc);
}

/// Like `wait`, but also wakes when `sock` becomes readable or writeable.
/// `socket_events` is a mask of `WL_SOCKET_READABLE` and/or `WL_SOCKET_WRITEABLE`.
pub fn waitOrSocket(
    latch: *Latch,
    sock: pg.pgsocket,
    socket_events: c_int,
    opts: Options,
) Result {
    const events = waitEvents(opts) | socket_events;
    const rc = pg.WaitLatchOrSocket(latch, events, sock, opts.timeout_ms orelse 0, opts.wait_event);
    return Result.fromBits(rc);
}

fn waitEvents(opts: Options) c_int {
    var events: c_int = pg.WL_LATCH_SET;
    if (opts.timeout_ms != null) events |= pg.WL_TIMEOUT;
    events |= if (opts.exit_on_postmaster_death) pg.WL_EXIT_ON_PM_DEATH else pg.WL_POSTMASTER_DEATH;
    return events;
}

pub const TestSuite_Latch = struct {
    pub fn testSetThenWait() !void {
        const latch = my();
        reset(latch);

        set(latch);
        const r = wait(latch, .{ .timeout_ms = 0 });
        try std.testing.expect(r.latch_set);
        try std.testing.expect(!r.timeout);
        try std.testing.expect(!r.postmaster_died);
        reset(latch);
    }

    pub fn testWaitTimesOut() !void {
        const latch = my();
        reset(latch);

        const r = wait(latch, .{ .timeout_ms = 1 });
        try std.testing.expect(r.timeout);
        try std.testing.expect(!r.latch_set);
    }

    pub fn testResetClearsWakeup() !void {
        const latch = my();
        set(latch);
        reset(latch);

        const r = wait(latch, .{ .timeout_ms = 0 });
        try std.testing.expect(!r.latch_set);
        try std.testing.expect(r.timeout);
    }
};
