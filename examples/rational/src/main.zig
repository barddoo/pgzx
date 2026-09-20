//! Runtime registration for the `rational` base type.
//!
//! The implementations live in functions.zig and the SQL schema in
//! schema.zig; keeping them out of this file lets the schema generator link
//! without the Postgres server. See docs/BUILD.md.

const pgzx = @import("pgzx");
const functions = @import("functions.zig");

comptime {
    pgzx.PG_MODULE_MAGIC();

    // Type I/O. These are called by the type system, not by SQL expressions.
    pgzx.PG_FUNCTION_V1("rational_in", functions.rational_in);
    pgzx.PG_FUNCTION_V1("rational_out", functions.rational_out);

    // Everything that is reached through SQL.
    pgzx.PG_FUNCTION_V1("rational", functions.rational_from_ints);
    pgzx.PG_FUNCTION_V1("rational_add", functions.rational_add);
    pgzx.PG_FUNCTION_V1("rational_sub", functions.rational_sub);
    pgzx.PG_FUNCTION_V1("rational_mul", functions.rational_mul);
    pgzx.PG_FUNCTION_V1("rational_div", functions.rational_div);
    pgzx.PG_FUNCTION_V1("rational_neg", functions.rational_neg);
    // The SQL function `abs(rational)` selects this symbol through the second
    // AS argument in the generated DDL.
    pgzx.PG_FUNCTION_V1("rational_abs", functions.rational_abs);

    pgzx.PG_FUNCTION_V1("rational_eq", functions.rational_eq);
    pgzx.PG_FUNCTION_V1("rational_ne", functions.rational_ne);
    pgzx.PG_FUNCTION_V1("rational_lt", functions.rational_lt);
    pgzx.PG_FUNCTION_V1("rational_le", functions.rational_le);
    pgzx.PG_FUNCTION_V1("rational_gt", functions.rational_gt);
    pgzx.PG_FUNCTION_V1("rational_ge", functions.rational_ge);

    pgzx.PG_FUNCTION_V1("rational_cmp", functions.rational_cmp);
    pgzx.PG_FUNCTION_V1("rational_hash", functions.rational_hash);
    pgzx.PG_FUNCTION_V1("rational_to_float8", functions.rational_to_float8);
}

comptime {
    pgzx.testing.registerTests(@import("build_options").testfn, .{functions.Tests});
}
