// Triggers example extension.
//
// Demonstrates PG_TRIGGER_V1: a BEFORE INSERT OR UPDATE trigger that
// rewrites the `name` column of the `products` table to upper-case.

const pgzx = @import("pgzx");
const trigger_fns = @import("trigger_fns.zig");

comptime {
    pgzx.PG_MODULE_MAGIC();
    pgzx.PG_TRIGGER_V1("upcase_name", trigger_fns.upcase_name);
}
