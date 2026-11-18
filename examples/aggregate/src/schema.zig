// SQL schema for the `geomean` aggregate.
//
// `zig build schema` renders `aggregate--0.1.sql` from this declaration. The
// transition state is `internal`, so the transition function's signature is
// declared with `args`/`returns` rather than derived from Zig.

const functions = @import("functions.zig");

pub const pgzx_sql = .{
    .functions = .{
        .{ .name = "geomean_accum", .func = functions.geomean_accum, .args = &.{ "internal", "float8" }, .returns = "internal" },
        .{ .name = "geomean_final", .func = functions.geomean_final, .args = &.{"internal"}, .returns = "float8" },
    },

    .aggregates = .{
        .{
            .name = "geomean",
            .args = &.{"float8"},
            .sfunc = "geomean_accum",
            .stype = "internal",
            .finalfunc = "geomean_final",
        },
    },
};
