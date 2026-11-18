//! Chaining for PostgreSQL hook variables such as `ExecutorStart_hook`.
//!
//! A hook variable holds a single function pointer. An extension that installs
//! a hook must keep the previous pointer and call it, or the standard function
//! when nothing else hooked the same point. `Hook` keeps that bookkeeping per
//! hook variable:
//!
//! ```zig
//! const start = pgzx.hooks.Hook(&pg.ExecutorStart_hook, pg.standard_ExecutorStart);
//!
//! fn myStart(queryDesc: [*c]pg.QueryDesc, eflags: c_int) callconv(.c) void {
//!     // work before the query starts
//!     start.callNext(.{ queryDesc, eflags });
//! }
//!
//! pub export fn _PG_init() void {
//!     start.install(myStart);
//! }
//! ```
//!
//! Each hook still needs its own `callconv(.c)` function with the exact C
//! signature. Zig cannot generate functions with a runtime argument list, so
//! the registry only removes the chaining code, not the callback declaration.
//!
//! Hooks are process-local and are never uninstalled: PostgreSQL does not call
//! `_PG_fini`, so `install` is for use from `_PG_init`.

const std = @import("std");

/// Chaining for the hook variable `hook_var`, falling back to `standard`.
///
/// `hook_var` is a pointer to the hook variable and `standard` is the function
/// PostgreSQL uses when no hook is installed. Zig makes one type per distinct
/// pair of arguments, and that type holds the previous-hook state, so one
/// binary needs one `Hook` per hook point. Separate extensions are separate
/// binaries and never share state.
pub fn Hook(comptime hook_var: anytype, comptime standard: anytype) type {
    const Slot = @typeInfo(@TypeOf(hook_var)).pointer.child;
    const FnPtr = @typeInfo(Slot).optional.child;
    const Ret = @typeInfo(@typeInfo(FnPtr).pointer.child).@"fn".return_type.?;

    return struct {
        var previous: Slot = null;
        var installed = false;

        /// Makes `callback` the active hook. The hook that was active before
        /// is kept for `callNext`. Call once per instance: a second install
        /// would make `callNext` reach the callback itself.
        pub fn install(callback: Slot) void {
            std.debug.assert(!installed);
            installed = true;
            previous = hook_var.*;
            hook_var.* = callback;
        }

        /// Calls the hook installed before the current one, or `standard` when
        /// there is none. `args` is a tuple of the hook's arguments.
        pub fn callNext(args: anytype) Ret {
            if (previous) |hook| {
                return @call(.auto, hook, args);
            }
            return @call(.auto, standard, args);
        }
    };
}

pub const TestSuite_Hooks = struct {
    var test_hook: ?*const fn (c_int) callconv(.c) c_int = null;

    fn standardImpl(x: c_int) callconv(.c) c_int {
        return x + 1;
    }

    fn standardOther(x: c_int) callconv(.c) c_int {
        return x + 2;
    }

    // Two instances stand in for two extensions hooking the same variable.
    // They need distinct fallbacks, otherwise Zig would give them one type.
    const First = Hook(&test_hook, standardImpl);
    const Second = Hook(&test_hook, standardOther);

    fn first(x: c_int) callconv(.c) c_int {
        return First.callNext(.{x}) * 10;
    }

    fn second(x: c_int) callconv(.c) c_int {
        return Second.callNext(.{x}) + 100;
    }

    pub fn testChainsToStandard() !void {
        First.install(first);
        try std.testing.expectEqual(@as(c_int, 20), test_hook.?(1));

        Second.install(second);
        try std.testing.expectEqual(@as(c_int, 120), test_hook.?(1));
    }
};
