// SQL schema of the `srf` extension; `zig build` renders `srf--0.1.sql`
// from this declaration. The `RETURNS SETOF`/`RETURNS TABLE` clauses are
// derived from the `SetOf`/`Table` return types.
//
// `step` gets a SQL-level `DEFAULT` so callers can omit it, even though the
// Zig function still takes all three arguments.

const functions = @import("functions.zig");

pub const pgzx_sql = .{
    .functions = .{
        .{
            .name = "srf_series",
            .func = functions.srf_series,
            .params = &.{
                .{ .name = "start" },
                .{ .name = "finish" },
                .{ .name = "step", .default = "1" },
            },
        },
        .{
            .name = "srf_series_table",
            .func = functions.srf_series_table,
            .params = &.{
                .{ .name = "start" },
                .{ .name = "finish" },
                .{ .name = "step", .default = "1" },
            },
        },
        .{ .name = "srf_random_values", .func = functions.srf_random_values },
        .{ .name = "srf_result_table", .func = functions.srf_result_table, .volatility = .stable },
        .{ .name = "srf_one_col", .func = functions.srf_one_col, .volatility = .stable },
    },
};
