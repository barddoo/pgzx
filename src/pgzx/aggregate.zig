//! Helpers for user-defined aggregates.
//!
//! An aggregate is a transition function, an optional final function, and an
//! optional combine function for parallel plans. Transition state is declared
//! with `STYPE = internal`: a pointer to a Zig struct kept in the aggregate's
//! memory context. PostgreSQL resets that context between groups, so state
//! must not be stored anywhere else.
//!
//! ```zig
//! const State = struct { sum: f64, count: i64 };
//!
//! pub fn accum(fcinfo: pg.FunctionCallInfo, state: ?pg.Datum, value: f64) !?pg.Datum {
//!     const s = try aggregate.stateOrInit(State, fcinfo, state);
//!     s.sum += value;
//!     s.count += 1;
//!     return aggregate.toDatum(s);
//! }
//! ```
//!
//! Transition functions declared with `internal` arguments have no direct SQL
//! mapping, so declare their types with `args`/`returns` in the schema. See
//! `ddl.AggregateDecl`.

const std = @import("std");

const pg = @import("pgzx_pgsys");

const err = @import("err.zig");
const mem = @import("mem.zig");

/// Memory context in which the aggregate's transition state must live.
/// Fails with `NotCalledAsAggregate` when the function is called outside an
/// aggregate.
pub fn context(fcinfo: pg.FunctionCallInfo) !pg.MemoryContext {
    var agg_ctx: pg.MemoryContext = null;
    if (pg.AggCheckCallContext(fcinfo, &agg_ctx) == 0) {
        return err.PGError.NotCalledAsAggregate;
    }
    return agg_ctx;
}

/// Returns the state stored in `current`. On the first call (`current` is
/// null) a zeroed `T` is allocated in the aggregate context and returned.
pub fn stateOrInit(comptime T: type, fcinfo: pg.FunctionCallInfo, current: ?pg.Datum) !*T {
    if (current) |d| {
        return @ptrFromInt(d);
    }

    const agg_ctx = try context(fcinfo);
    const old_ctx = pg.MemoryContextSwitchTo(agg_ctx);
    defer _ = pg.MemoryContextSwitchTo(old_ctx);

    const ptr = try mem.PGCurrentContextAllocator.create(T);
    ptr.* = std.mem.zeroes(T);
    return ptr;
}

/// Encodes a state pointer as the `internal` datum PostgreSQL passes between
/// the aggregate's functions.
pub inline fn toDatum(ptr: anytype) pg.Datum {
    return @intFromPtr(ptr);
}

pub const TestSuite_Aggregate = struct {
    const Counter = struct { count: i64, sum: f64 };

    pub fn testZeroedState() !void {
        const ptr = try mem.PGCurrentContextAllocator.create(Counter);
        defer mem.PGCurrentContextAllocator.destroy(ptr);
        ptr.* = std.mem.zeroes(Counter);

        try std.testing.expectEqual(@as(i64, 0), ptr.count);
        try std.testing.expectEqual(@as(f64, 0), ptr.sum);
    }

    pub fn testDatumRoundTrip() !void {
        var value = Counter{ .count = 3, .sum = 1.5 };
        const d = toDatum(&value);
        const back: *Counter = @ptrFromInt(d);
        try std.testing.expectEqual(@as(i64, 3), back.count);
    }
};
