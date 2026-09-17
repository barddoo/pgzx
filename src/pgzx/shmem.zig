const std = @import("std");

const pg = @import("pgzx_pgsys");

pub inline fn registerHooks(comptime T: anytype) void {
    if (std.meta.hasFn(T, "requestHook")) {
        registerRequestHook(T.requestHook);
    }
    if (std.meta.hasFn(T, "startupHook")) {
        registerStartupHook(T.startupHook);
    }
}

pub inline fn registerSharedState(comptime T: type, shared_state: **T) void {
    const Hooks = struct {
        // Nested functions cannot capture the runtime `shared_state` argument,
        // so it is stashed in container-level storage first.
        var state: **T = undefined;

        pub fn requestHook() void {
            if (std.meta.hasFn(T, "shmemRequest")) {
                T.shmemRequest();
            } else {
                requestSpaceFor(T);
            }
        }

        pub fn startupHook() void {
            var found = false;
            const ptr = pg.ShmemInitStruct(T.SHMEM_NAME, @sizeOf(T), &found);
            state.* = @ptrCast(@alignCast(ptr));
            if (!found) {
                if (std.meta.hasFn(T, "init")) {
                    state.*.* = T.init();
                } else {
                    state.*.* = std.mem.zeroes(T);
                }
            }
        }
    };

    Hooks.state = shared_state;
    registerHooks(Hooks);
}

pub inline fn registerRequestHook(f: anytype) void {
    registerHook(f, &pg.shmem_request_hook);
}

pub inline fn registerStartupHook(f: anytype) void {
    registerHook(f, &pg.shmem_startup_hook);
}

inline fn registerHook(f: anytype, hook: anytype) void {
    const ctx = struct {
        var prev_hook: @TypeOf(hook.*) = undefined;
        fn hook_fn() callconv(.c) void {
            if (prev_hook) |prev| {
                prev();
            }
            f();
        }
    };

    ctx.prev_hook = hook.*;
    hook.* = ctx.hook_fn;
}

pub inline fn requestSpaceFor(comptime T: type) void {
    pg.RequestAddinShmemSpace(@sizeOf(T));
}

pub inline fn createAndZero(comptime T: type) *T {
    var found = false;
    const ptr = pg.ShmemInitStruct(T.SHMEM_NAME, @sizeOf(T), &found);
    const shared_state: *T = @ptrCast(@alignCast(ptr));
    if (!found) {
        shared_state.* = std.mem.zeroes(T);
    }
    return shared_state;
}

pub inline fn createAndInit(comptime T: type) *T {
    // TODO: check that T implements init

    var found = false;
    const ptr = pg.ShmemInitStruct(T.SHMEM_NAME, @sizeOf(T), &found);
    const shared_state: *T = @ptrCast(@alignCast(ptr));
    if (!found) {
        shared_state.init();
    }
    return shared_state;
}

/// Tests for the shmem hook plumbing.
///
/// Allocating real shared memory is only possible during postmaster startup:
/// `RequestAddinShmemSpace` errors outside the `shmem_request_hook` and
/// `ShmemInitStruct` cannot grow the segment from a running backend. So these
/// tests exercise the parts that are reachable at runtime: that hooks are
/// installed, chained, and dispatched to the type's own callbacks.
pub const TestSuite_Shmem = struct {
    var request_calls: u32 = 0;
    var startup_calls: u32 = 0;

    fn requestHook() void {
        request_calls += 1;
    }

    fn startupHook() void {
        startup_calls += 1;
    }

    /// Records `shmemRequest` instead of calling `RequestAddinShmemSpace`, so
    /// the request hook can be invoked without touching the shmem APIs.
    const CountingState = struct {
        pub const SHMEM_NAME = "pgzx_test_shmem";
        value: u32 = 0,

        pub fn shmemRequest() void {
            request_calls += 1;
        }

        pub fn init() CountingState {
            return .{ .value = 0xdeadbeef };
        }
    };

    pub fn testRegisterRequestHook() !void {
        const original = pg.shmem_request_hook;
        defer pg.shmem_request_hook = original;

        pg.shmem_request_hook = null;
        request_calls = 0;

        registerRequestHook(requestHook);
        try std.testing.expect(pg.shmem_request_hook != null);

        pg.shmem_request_hook.?();
        try std.testing.expectEqual(@as(u32, 1), request_calls);
    }

    pub fn testRegisterStartupHook() !void {
        const original = pg.shmem_startup_hook;
        defer pg.shmem_startup_hook = original;

        pg.shmem_startup_hook = null;
        startup_calls = 0;

        registerStartupHook(startupHook);
        try std.testing.expect(pg.shmem_startup_hook != null);

        pg.shmem_startup_hook.?();
        try std.testing.expectEqual(@as(u32, 1), startup_calls);
    }

    pub fn testRegisterSharedState() !void {
        const original_request = pg.shmem_request_hook;
        const original_startup = pg.shmem_startup_hook;
        defer {
            pg.shmem_request_hook = original_request;
            pg.shmem_startup_hook = original_startup;
        }

        pg.shmem_request_hook = null;
        pg.shmem_startup_hook = null;

        var state: *CountingState = undefined;
        registerSharedState(CountingState, &state);

        try std.testing.expect(pg.shmem_request_hook != null);
        try std.testing.expect(pg.shmem_startup_hook != null);

        // The installed request hook must dispatch to `CountingState.shmemRequest`.
        request_calls = 0;
        pg.shmem_request_hook.?();
        try std.testing.expectEqual(@as(u32, 1), request_calls);
    }

    pub fn testRegisterHooksSkipsMissingCallbacks() !void {
        const original_request = pg.shmem_request_hook;
        const original_startup = pg.shmem_startup_hook;
        defer {
            pg.shmem_request_hook = original_request;
            pg.shmem_startup_hook = original_startup;
        }

        pg.shmem_request_hook = null;
        pg.shmem_startup_hook = null;

        // Only a `requestHook` is defined, so `registerHooks` must leave the
        // startup hook untouched.
        registerHooks(struct {
            pub fn requestHook() void {
                request_calls += 1;
            }
        });

        try std.testing.expect(pg.shmem_request_hook != null);
        try std.testing.expect(pg.shmem_startup_hook == null);
    }
};
