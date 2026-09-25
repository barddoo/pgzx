// SQL schema of the `arrays` extension; `zig build` renders
// `arrays--0.1.sql` from it. SQL types are derived from the Zig signatures
// (`[]const i32` is `integer[]`, `[]const f32` is `real[]`, ...).

const functions = @import("functions.zig");

pub const pgzx_sql = .{
    .functions = .{
        .{ .name = "sq_euclid", .func = functions.sq_euclid, .strict = true },
        .{ .name = "approx_distance", .func = functions.approx_distance, .volatility = .immutable, .parallel = .safe, .strict = true },

        // default_array() must exist before sum_array's DEFAULT refers to it.
        .{ .name = "default_array", .func = functions.default_array, .volatility = .immutable },
        .{
            .name = "sum_array",
            .func = functions.sum_array,
            .strict = true,
            .params = &.{.{ .name = "input", .default = "default_array()" }},
        },
        .{ .name = "sum_vec", .func = functions.sum_vec, .strict = true },

        .{ .name = "static_names", .func = functions.static_names, .volatility = .immutable },
        .{ .name = "i32_array_no_nulls", .func = functions.i32_array_no_nulls, .volatility = .immutable },
        .{ .name = "i32_array_with_nulls", .func = functions.i32_array_with_nulls, .volatility = .immutable },
        .{ .name = "strip_nulls", .func = functions.strip_nulls, .volatility = .immutable, .strict = true },
        .{ .name = "sum_vector", .func = functions.sum_vector, .volatility = .immutable, .parallel = .safe, .strict = true },
        .{ .name = "sum_vector_view", .func = functions.sum_vector_view, .volatility = .immutable, .parallel = .safe, .strict = true },
        .{ .name = "sum_vector_simd", .func = functions.sum_vector_simd, .volatility = .immutable, .parallel = .safe, .strict = true },
        .{ .name = "sum_vector_fastmath", .func = functions.sum_vector_fastmath, .volatility = .immutable, .parallel = .safe, .strict = true },

        // Beyond the pgrx example: VARIADIC, named params with defaults, COST.
        .{
            .name = "sum_all",
            .func = functions.sum_all,
            .volatility = .immutable,
            .strict = true,
            .params = &.{.{ .name = "nums", .mode = .variadic }},
        },
        .{
            .name = "clamp_all",
            .func = functions.clamp_all,
            .volatility = .immutable,
            .strict = true,
            .params = &.{
                .{ .name = "vals" },
                .{ .name = "lo", .default = "0" },
                .{ .name = "hi", .default = "100" },
            },
            .comment = "Clamps every element into [lo, hi].",
        },
        .{ .name = "distinct_sorted", .func = functions.distinct_sorted, .volatility = .immutable, .strict = true, .cost = 10 },
    },
};
