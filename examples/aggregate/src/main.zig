const pgzx = @import("pgzx");
const functions = @import("functions.zig");

comptime {
    pgzx.PG_MODULE_MAGIC();

    // Called by the aggregate machinery, not by SQL expressions directly.
    pgzx.PG_FUNCTION_V1("geomean_accum", functions.geomean_accum);
    pgzx.PG_FUNCTION_V1("geomean_final", functions.geomean_final);
}
