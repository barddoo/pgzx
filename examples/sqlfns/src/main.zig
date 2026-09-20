// With this extension we want to show you how you can use pgzx to create
// and export functions to PostgreSQL.
//
// The function implementations live in functions.zig so that the SQL schema
// generator (schema.zig) can introspect them without linking the server. This
// file is responsible for the runtime registration and the raw C exports.

const pgzx = @import("pgzx");
const pg = pgzx.c;
const functions = @import("functions.zig");

comptime {
    pgzx.PG_MODULE_MAGIC();
}

// Exported functions with C calling convention
// ============================================

// It is always possible to export a function by writing a C function directly.
// The function accepts the FunctionCallInfoData struct and must return a Datum
// and no Zig errors. The implementation is in functions.zig.

export fn pg_finfo_hello_world_c() callconv(.c) [*c]const pg.Pg_finfo_record {
    return pgzx.fmgr.FunctionV1();
}

export fn hello_world_c(fcinfo: pg.FunctionCallInfo) callconv(.c) pg.Datum {
    return functions.hello_world_c(fcinfo);
}

// Use PG_FUNCTION_V1 to declare and export a zig function
// =======================================================

// Similar to extensions written in C we use PG_FUNCTION_V1 to declare a
// function. This produces a wrapper that checks the argument and return type
// of the function, implements argument unpacking, return value packing and Zig
// error to PostgreSQL error conversion.

comptime {
    pgzx.PG_FUNCTION_V1("hello_world_zig", functions.hello_world_zig);
    pgzx.PG_FUNCTION_V1("hello_world_zig_null", functions.hello_world_zig_null);
    pgzx.PG_FUNCTION_V1("hello_world_zig_datum", functions.hello_world_zig_datum);
}

// PG_EXPORT: Export all public functions from a struct
// ====================================================

// Exporting a number of functions can become a bit tedious over time. The
// `PG_EXPORT` function can be used to automatically export all public
// functions from a struct.

comptime {
    pgzx.PG_EXPORT(functions.anon_funcs);
    pgzx.PG_EXPORT(functions.mod_hello_world);
}

// In Zig when importing a file, the file is also treated as a struct. Let's
// try this:

comptime {
    pgzx.PG_EXPORT(@import("hello_world.zig"));
}
