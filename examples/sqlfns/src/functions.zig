// This module contains the SQL-visible functions. It is kept free of any
// export/registration calls so that the SQL schema generator (see schema.zig)
// can introspect the signatures without linking the Postgres server.
//
// The registrations themselves (`PG_FUNCTION_V1`/`PG_EXPORT`) and the raw C
// exports live in main.zig.

const std = @import("std");
const pgzx = @import("pgzx");
const pg = pgzx.c;

// Exported functions with C calling convention
// ============================================

// It is always possible to export a function by writing a C function directly.
// The function accepts the FunctionCallInfoData struct and must return a Datum
// and no Zig errors. The `export fn` wrapper lives in main.zig; here we only
// define the implementation.
pub fn hello_world_c(fcinfo: pg.FunctionCallInfo) pg.Datum {
    // When using the C interface we can not use any of the PG_RETURN or
    // PG_GETARG macros directly. This function accepts a 'string' of type
    // 'text' and returns a new string of type 'text'. We start by getting the
    // first argument of the function call.
    const arg = pgzx.fmgr.args.mustGetArgNullable(fcinfo, 0) catch {
        pgzx.elog.ErrorThrow(@src(), "missing argument", .{});
        unreachable;
    };

    const message = if (arg.isnull) "Hello World" else blk: {
        const name = pgzx.datum.getDatumTextSliceZ(arg.value) catch |e| {
            pgzx.elog.throwAsPostgresError(@src(), e);
            unreachable;
        };

        const allocator = pgzx.mem.PGCurrentContextAllocator;
        const hello = std.fmt.allocPrintSentinel(allocator, "Hello, {s}!", .{name}, 0) catch |e| {
            pgzx.elog.throwAsPostgresError(@src(), e);
            unreachable;
        };
        break :blk hello;
    };

    return pgzx.datum.sliceToDatumTextZ(message) catch |e| {
        pgzx.elog.throwAsPostgresError(@src(), e);
        unreachable;
    };
}

// Zig functions exported through PG_FUNCTION_V1
// ==============================================

// The fmgr module wraps the function, checks argument and return types, and
// implements argument unpacking, return value packing and Zig to PostgreSQL
// error conversion.
pub fn hello_world_zig(name: ?[:0]const u8) ![:0]const u8 {
    return if (name) |n|
        try std.fmt.allocPrintSentinel(pgzx.mem.PGCurrentContextAllocator, "Hello, {s}!", .{n}, 0)
    else
        "Hello World";
}

// A variant that returns `NULL` when the argument is null by returning an
// optional value.
pub fn hello_world_zig_null(name: ?[:0]const u8) !?[:0]const u8 {
    return if (name) |n|
        try std.fmt.allocPrintSentinel(pgzx.mem.PGCurrentContextAllocator, "Hello, {s}!", .{n}, 0)
    else
        null;
}

// It is also possible to capture the FunctionCallInfo as an argument. This
// example accepts and returns a Datum and marks a NULL return in the
// FunctionCallInfo itself.
pub fn hello_world_zig_datum(fcinfo: pg.FunctionCallInfo, arg: ?pg.Datum) !pg.Datum {
    if (arg == null) {
        fcinfo.*.isnull = true;
        return 0;
    }

    const name = try pgzx.datum.getDatumTextSliceZ(arg.?);
    const message = try std.fmt.allocPrintSentinel(pgzx.mem.PGCurrentContextAllocator, "Hello, {s}!", .{name}, 0);
    return try pgzx.datum.sliceToDatumTextZ(message);
}

// Functions exported from structs
// ===============================

pub const anon_funcs = struct {
    pub fn hello_world_anon(name: ?[:0]const u8) ![:0]const u8 {
        return if (name) |n|
            try std.fmt.allocPrintSentinel(pgzx.mem.PGCurrentContextAllocator, "Hello, {s}!", .{n}, 0)
        else
            "Hello World";
    }
};

pub const mod_hello_world = struct {
    pub fn hello_world_mod(name: ?[:0]const u8) ![:0]const u8 {
        return if (name) |n|
            try std.fmt.allocPrintSentinel(pgzx.mem.PGCurrentContextAllocator, "Hello, {s}!", .{n}, 0)
        else
            "Hello World";
    }
};
