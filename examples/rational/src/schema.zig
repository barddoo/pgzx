// SQL schema for the `rational` base type.
//
// `zig build` renders `rational--0.1.sql` from this declaration:
//
//   1. `.sql`        the shell type, so the I/O functions can return it
//   2. `.functions`  the type I/O, arithmetic, comparison and support funcs
//   3. `.post_sql`   the completed type, operators, opclasses and casts
//
// The custom types (`rational`, `cstring`) are passed through `args`/`returns`
// because they have no direct Zig mapping. See `./catalog.sql` for the raw
// catalog objects.

const functions = @import("functions.zig");

const rational = [_][]const u8{"rational"};
const rational_pair = [_][]const u8{ "rational", "rational" };

const opts = .{
    .volatility = .immutable,
    .strict = true,
    .parallel = .safe,
};

pub const pgzx_sql = .{
    .sql = "CREATE TYPE rational;",

    .functions = .{
        // Type I/O.
        .{ .name = "rational_in", .func = functions.rational_in, .args = &.{"cstring"}, .returns = "rational", .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },
        .{ .name = "rational_out", .func = functions.rational_out, .args = &rational, .returns = "cstring", .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },

        // Constructor and arithmetic.
        .{ .name = "rational", .func = functions.rational_from_ints, .returns = "rational", .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },
        .{ .name = "rational_add", .func = functions.rational_add, .args = &rational_pair, .returns = "rational", .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },
        .{ .name = "rational_sub", .func = functions.rational_sub, .args = &rational_pair, .returns = "rational", .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },
        .{ .name = "rational_mul", .func = functions.rational_mul, .args = &rational_pair, .returns = "rational", .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },
        .{ .name = "rational_div", .func = functions.rational_div, .args = &rational_pair, .returns = "rational", .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },
        .{ .name = "rational_neg", .func = functions.rational_neg, .args = &rational, .returns = "rational", .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },
        // Named `abs`, not `rational_abs`, so overload resolution finds it next
        // to the built-in abs() family. `symbol` selects the exported C symbol.
        .{ .name = "abs", .func = functions.rational_abs, .symbol = "rational_abs", .args = &rational, .returns = "rational", .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },

        // Comparison.
        .{ .name = "rational_eq", .func = functions.rational_eq, .args = &rational_pair, .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },
        .{ .name = "rational_ne", .func = functions.rational_ne, .args = &rational_pair, .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },
        .{ .name = "rational_lt", .func = functions.rational_lt, .args = &rational_pair, .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },
        .{ .name = "rational_le", .func = functions.rational_le, .args = &rational_pair, .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },
        .{ .name = "rational_gt", .func = functions.rational_gt, .args = &rational_pair, .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },
        .{ .name = "rational_ge", .func = functions.rational_ge, .args = &rational_pair, .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },

        // btree/hash support and the float8 cast.
        .{ .name = "rational_cmp", .func = functions.rational_cmp, .args = &rational_pair, .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },
        .{ .name = "rational_hash", .func = functions.rational_hash, .args = &rational, .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },
        .{ .name = "rational_to_float8", .func = functions.rational_to_float8, .args = &rational, .volatility = opts.volatility, .strict = opts.strict, .parallel = opts.parallel },
    },

    .post_sql = @embedFile("catalog.sql"),
};
