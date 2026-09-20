//! SQL/DDL generation.
//!
//! Extensions describe their SQL-visible objects with a comptime declaration
//! (conventionally `pub const pgzx_sql`) and this module renders the SQL that
//! ships as the extension's versioned script (`<name>--<version>.sql`).
//!
//! The declaration is a plain struct literal. Only `functions` is understood
//! today; `sql` is emitted verbatim before the generated statements so that
//! user-defined types and schemas exist by the time functions are created.
//!
//! ```zig
//! pub const pgzx_sql = .{
//!     .functions = .{
//!         .{ .name = "hello_world", .func = hello_world },
//!         .{ .name = "char_count", .func = char_count, .volatility = .immutable, .strict = true },
//!     },
//! };
//! ```
//!
//! Argument types are derived from the Zig function signature through
//! `pgzx.datum`. A `FunctionCallInfo` parameter is treated as the fmgr context
//! and is not emitted as a SQL argument. Use the `args` and `returns` overrides
//! when a signature uses types without a direct SQL mapping (for example a raw
//! `pg.Datum`).

const std = @import("std");

const pg = @import("pgzx_pgsys");

const datum = @import("datum.zig");
const meta = @import("meta.zig");

/// SQL function volatility. `volatile` is the PostgreSQL default.
pub const Volatility = enum {
    @"volatile",
    stable,
    immutable,

    fn clause(self: Volatility) []const u8 {
        return switch (self) {
            .@"volatile" => "",
            .stable => " STABLE",
            .immutable => " IMMUTABLE",
        };
    }
};

/// SQL function parallel safety. When `null` the clause is omitted.
pub const Parallel = enum {
    unsafe,
    restricted,
    safe,

    fn clause(self: Parallel) []const u8 {
        return switch (self) {
            .unsafe => "UNSAFE",
            .restricted => "RESTRICTED",
            .safe => "SAFE",
        };
    }
};

/// Normalized view of a `.functions` entry. Optional fields fall back to their
/// defaults so the renderer does not have to guard every access.
fn Function(comptime decl: anytype) type {
    const D = @TypeOf(decl);
    return struct {
        pub const name: []const u8 = decl.name;
        pub const function = decl.func;
        pub const volatility: Volatility = if (@hasField(D, "volatility")) decl.volatility else .@"volatile";
        pub const strict: bool = if (@hasField(D, "strict")) decl.strict else false;
        pub const parallel: ?Parallel = if (@hasField(D, "parallel")) decl.parallel else null;
        pub const returns: ?[]const u8 = if (@hasField(D, "returns")) decl.returns else null;
        pub const args: ?[]const []const u8 = if (@hasField(D, "args")) decl.args else null;
        pub const symbol: ?[]const u8 = if (@hasField(D, "symbol")) decl.symbol else null;
        pub const comment: ?[]const u8 = if (@hasField(D, "comment")) decl.comment else null;
    };
}

/// Returns the SQL type for a function's return value, unwrapping the error
/// union used by the fmgr wrapper.
fn returnSqlType(comptime FnType: type) []const u8 {
    const ret = meta.fnReturnType(FnType);
    const payload = switch (@typeInfo(ret)) {
        .error_union => |eu| eu.payload,
        .error_set => void,
        else => ret,
    };
    if (payload == void) return "void";
    return datum.sqlType(payload);
}

/// Renders the SQL script for a schema declaration into `writer`.
///
/// `schema` is the comptime declaration value (for example `ext.pgzx_sql`).
/// The `writer` may be any type exposing a `writeAll([]const u8) !void` method,
/// such as `*std.Io.Writer`.
pub fn render(writer: anytype, comptime schema: anytype) !void {
    const S = @TypeOf(schema);
    if (@hasField(S, "sql")) try renderRawSql(writer, schema.sql);
    if (@hasField(S, "functions")) {
        inline for (schema.functions) |decl| {
            try renderFunction(writer, decl);
        }
    }
    if (@hasField(S, "post_sql")) try renderRawSql(writer, schema.post_sql);
}

fn renderRawSql(writer: anytype, raw: []const u8) !void {
    if (raw.len == 0) return;
    try writer.writeAll(raw);
    if (raw[raw.len - 1] != '\n') try writer.writeAll("\n");
}

fn renderFunction(writer: anytype, comptime decl: anytype) !void {
    const F = Function(decl);
    const FnType = @TypeOf(F.function);
    const type_info = @typeInfo(FnType);
    if (type_info != .@"fn") {
        @compileError("pgzx.ddl: `func` for '" ++ F.name ++ "' must be a function");
    }
    const fn_info = type_info.@"fn";
    if (fn_info.is_generic or fn_info.is_var_args) {
        @compileError("pgzx.ddl: '" ++ F.name ++ "' must not be generic or variadic");
    }

    try writer.writeAll("CREATE FUNCTION ");
    try writer.writeAll(F.name);
    try writer.writeAll("(");
    try renderArgTypes(writer, F, fn_info);
    try writer.writeAll(") RETURNS ");
    if (F.returns) |r| {
        try writer.writeAll(r);
    } else {
        try writer.writeAll(returnSqlType(FnType));
    }

    try writer.writeAll("\nAS 'MODULE_PATHNAME'");
    if (F.symbol) |symbol| {
        try writer.writeAll(", ");
        try writeSqlString(writer, symbol);
    }
    try writer.writeAll("\nLANGUAGE C");
    try writer.writeAll(F.volatility.clause());
    if (F.strict) try writer.writeAll(" STRICT");
    if (F.parallel) |p| {
        try writer.writeAll(" PARALLEL ");
        try writer.writeAll(p.clause());
    }
    try writer.writeAll(";");
    if (F.comment) |c| {
        try writer.writeAll("\nCOMMENT ON FUNCTION ");
        try writer.writeAll(F.name);
        try writer.writeAll("(");
        try renderArgTypes(writer, F, fn_info);
        try writer.writeAll(") IS ");
        try writeSqlString(writer, c);
        try writer.writeAll(";");
    }
    try writer.writeAll("\n");
}

/// Writes the comma-separated SQL argument types. Explicit `args` win over the
/// types derived from the Zig signature (with `FunctionCallInfo` skipped).
fn renderArgTypes(writer: anytype, comptime F: anytype, comptime fn_info: anytype) !void {
    if (F.args) |args| {
        for (args, 0..) |arg, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(arg);
        }
        return;
    }
    var first = true;
    inline for (fn_info.params) |param| {
        const P = param.type orelse
            @compileError("pgzx.ddl: '" ++ F.name ++ "' has an unresolved parameter type");
        if (P == pg.FunctionCallInfo) continue;
        if (!first) try writer.writeAll(", ");
        first = false;
        try writer.writeAll(datum.sqlType(P));
    }
}

fn writeSqlString(writer: anytype, value: []const u8) !void {
    try writer.writeAll("'");
    for (value) |ch| {
        if (ch == '\'') try writer.writeAll("''") else try writer.writeByte(ch);
    }
    try writer.writeAll("'");
}

pub const TestSuite_Ddl = struct {
    const sample_functions = struct {
        pub fn add(a: i32, b: i32) i32 {
            return a + b;
        }

        pub fn greet(name: ?[]const u8) ![]const u8 {
            return name orelse "world";
        }

        pub fn noop() void {}
    };

    const schema = .{
        .sql = "CREATE SCHEMA IF NOT EXISTS demo;",
        .functions = .{
            .{ .name = "demo_add", .func = sample_functions.add },
            .{
                .name = "demo_greet",
                .func = sample_functions.greet,
                .volatility = .immutable,
                .strict = true,
                .parallel = .safe,
            },
            .{ .name = "demo_noop", .func = sample_functions.noop, .comment = "does nothing" },
            .{ .name = "demo_alias", .func = sample_functions.add, .symbol = "demo_add", .args = &.{ "integer", "integer" } },
        },
        .post_sql = "GRANT EXECUTE ON FUNCTION demo_noop() TO PUBLIC;",
    };

    pub fn testRender() !void {
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try render(&writer, schema);
        const out = writer.buffered();

        const expected =
            \\CREATE SCHEMA IF NOT EXISTS demo;
            \\CREATE FUNCTION demo_add(integer, integer) RETURNS integer
            \\AS 'MODULE_PATHNAME'
            \\LANGUAGE C;
            \\CREATE FUNCTION demo_greet(text) RETURNS text
            \\AS 'MODULE_PATHNAME'
            \\LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
            \\CREATE FUNCTION demo_noop() RETURNS void
            \\AS 'MODULE_PATHNAME'
            \\LANGUAGE C;
            \\COMMENT ON FUNCTION demo_noop() IS 'does nothing';
            \\CREATE FUNCTION demo_alias(integer, integer) RETURNS integer
            \\AS 'MODULE_PATHNAME', 'demo_add'
            \\LANGUAGE C;
            \\GRANT EXECUTE ON FUNCTION demo_noop() TO PUBLIC;
            \\
        ;
        try std.testing.expectEqualStrings(expected, out);
    }

    pub fn testSqlType() !void {
        try std.testing.expectEqualStrings("integer", datum.sqlType(i32));
        try std.testing.expectEqualStrings("text", datum.sqlType([]const u8));
        try std.testing.expectEqualStrings("text", datum.sqlType(?[:0]const u8));
        try std.testing.expectEqualStrings("double precision", datum.sqlType(f64));
        try std.testing.expectEqualStrings("boolean", datum.sqlType(bool));
    }
};
