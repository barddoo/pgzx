// The `arrays` example extension: a port of pgrx's `pgrx-examples/arrays`
// showing how Postgres arrays map to Zig slices.
//
// The functions live in functions.zig so the SQL generator (schema.zig) can
// introspect them; this file only registers them with Postgres.

const pgzx = @import("pgzx");

comptime {
    pgzx.PG_MODULE_MAGIC();

    // Export every public function of functions.zig as a V1 function.
    pgzx.PG_EXPORT(@import("functions.zig"));
}
