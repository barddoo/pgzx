//! Transition and final functions for the `geomean` aggregate.
//!
//! The state is a Zig struct allocated in the aggregate context. Keeping the
//! functions out of schema.zig lets the schema generator link without the
//! Postgres server.

const std = @import("std");

const pgzx = @import("pgzx");
const pg = pgzx.c;

const GeoState = struct {
    sum_ln: f64,
    count: i64,
};

/// Transition: folds one value into the state. NULL inputs are skipped, as
/// for every built-in aggregate.
pub fn geomean_accum(fcinfo: pg.FunctionCallInfo, state: ?pg.Datum, value: ?f64) !?pg.Datum {
    const v = value orelse return state;
    if (v <= 0) return error.NonPositiveInput;

    const s = try pgzx.aggregate.stateOrInit(GeoState, fcinfo, state);
    s.sum_ln += @log(v);
    s.count += 1;
    return pgzx.aggregate.toDatum(s);
}

/// Final: returns the geometric mean, or NULL when no values were aggregated.
pub fn geomean_final(state: ?pg.Datum) !?f64 {
    const d = state orelse return null;
    const s: *GeoState = @ptrFromInt(d);
    if (s.count == 0) return null;
    return @exp(s.sum_ln / @as(f64, @floatFromInt(s.count)));
}

test "geomean_final returns null without state" {
    try std.testing.expectEqual(@as(?f64, null), try geomean_final(null));
}
