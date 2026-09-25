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
//!
//! Use `params` instead of `args` to name parameters, give them defaults, or
//! declare `OUT`/`INOUT`/`VARIADIC` modes. A param without `type` takes the
//! next SQL type derived from the Zig signature, so only `OUT` params (which
//! have no Zig counterpart) must spell their type:
//!
//! ```zig
//! .{
//!     .name = "clamp",
//!     .func = clamp,
//!     .params = &.{
//!         .{ .name = "value" },
//!         .{ .name = "lo", .default = "0" },
//!         .{ .name = "hi", .default = "100" },
//!     },
//!     .security = .definer,
//!     .set = &.{.{ .name = "search_path", .value = "pg_catalog, pg_temp" }},
//!     .cost = 10,
//! },
//! ```
//!
//! When a function has `OUT`/`INOUT` params and no explicit `returns`, the
//! `RETURNS` clause is omitted so PostgreSQL infers it from the params.

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

/// SQL function security. `invoker` is the PostgreSQL default.
pub const Security = enum {
    invoker,
    definer,
};

/// SQL parameter mode. `in` is the PostgreSQL default and is not rendered.
pub const ParamMode = enum {
    in,
    out,
    inout,
    variadic,

    fn prefix(self: ParamMode) []const u8 {
        return switch (self) {
            .in => "",
            .out => "OUT ",
            .inout => "INOUT ",
            .variadic => "VARIADIC ",
        };
    }

    /// Whether the param is part of the call signature (and consumes a Zig
    /// argument). `OUT` params are result columns only.
    fn isInput(self: ParamMode) bool {
        return self != .out;
    }

    fn isOutput(self: ParamMode) bool {
        return self == .out or self == .inout;
    }
};

/// A SQL function parameter, see the module docs.
pub const Param = struct {
    name: ?[]const u8 = null,
    /// SQL type. `null` derives it from the matching Zig parameter; required
    /// for `OUT` params.
    type: ?[]const u8 = null,
    mode: ParamMode = .in,
    /// SQL expression rendered verbatim after `DEFAULT`.
    default: ?[]const u8 = null,
};

/// A `SET <name> = <value>` clause. `value` is rendered verbatim, `null`
/// renders `FROM CURRENT`.
pub const Setting = struct {
    name: []const u8,
    value: ?[]const u8,
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
        pub const params: ?[]const Param = if (@hasField(D, "params")) coerceSlice(Param, decl.params) else null;
        pub const security: Security = if (@hasField(D, "security")) decl.security else .invoker;
        pub const leakproof: bool = if (@hasField(D, "leakproof")) decl.leakproof else false;
        pub const cost: ?u32 = if (@hasField(D, "cost")) decl.cost else null;
        pub const rows: ?u32 = if (@hasField(D, "rows")) decl.rows else null;
        pub const set: []const Setting = if (@hasField(D, "set")) coerceSlice(Setting, decl.set) else &.{};
        pub const or_replace: bool = if (@hasField(D, "or_replace")) decl.or_replace else false;

        comptime {
            if (@hasField(D, "args") and @hasField(D, "params")) {
                @compileError("pgzx.ddl: '" ++ name ++ "' sets both `args` and `params`");
            }
        }
    };
}

/// Accepts either a typed slice (`&[_]Param{...}`) or a plain literal
/// (`&.{.{ .name = "x" }}`) and returns `[]const T`. Literal fields are
/// copied by name; omitted fields take their declared defaults.
fn coerceSlice(comptime T: type, comptime raw: anytype) []const T {
    comptime {
        const R = @TypeOf(raw);
        if (R == []const T) return raw;
        const items = switch (@typeInfo(R)) {
            .pointer => raw.*,
            else => raw,
        };
        var out: [items.len]T = undefined;
        for (0..items.len) |i| {
            const item = items[i];
            if (@TypeOf(item) == T) {
                out[i] = item;
                continue;
            }
            const I = @TypeOf(item);
            for (@typeInfo(I).@"struct".fields) |field| {
                if (!@hasField(T, field.name)) {
                    @compileError("pgzx.ddl: unknown " ++ @typeName(T) ++ " field '" ++ field.name ++ "'");
                }
            }
            var value: T = undefined;
            for (@typeInfo(T).@"struct".fields) |field| {
                if (@hasField(I, field.name)) {
                    @field(value, field.name) = @field(item, field.name);
                } else if (field.defaultValue()) |default| {
                    @field(value, field.name) = default;
                } else {
                    @compileError("pgzx.ddl: missing " ++ @typeName(T) ++ " field '" ++ field.name ++ "'");
                }
            }
            out[i] = value;
        }
        const final = out;
        return &final;
    }
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

    try writer.writeAll(if (F.or_replace) "CREATE OR REPLACE FUNCTION " else "CREATE FUNCTION ");
    try writer.writeAll(F.name);
    try writer.writeAll("(");
    try renderArgs(writer, F, fn_info, .definition);
    try writer.writeAll(")");
    if (F.returns) |r| {
        try writer.writeAll(" RETURNS ");
        try writer.writeAll(r);
    } else if (!comptime hasOutputParams(F)) {
        try writer.writeAll(" RETURNS ");
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
    if (F.security == .definer) try writer.writeAll(" SECURITY DEFINER");
    if (F.leakproof) try writer.writeAll(" LEAKPROOF");
    if (F.parallel) |p| {
        try writer.writeAll(" PARALLEL ");
        try writer.writeAll(p.clause());
    }
    if (F.cost) |cost| try writer.print(" COST {d}", .{cost});
    if (F.rows) |rows| try writer.print(" ROWS {d}", .{rows});
    inline for (F.set) |setting| {
        try writer.writeAll("\nSET ");
        try writer.writeAll(setting.name);
        if (setting.value) |v| {
            try writer.writeAll(" = ");
            try writer.writeAll(v);
        } else {
            try writer.writeAll(" FROM CURRENT");
        }
    }
    try writer.writeAll(";");
    if (F.comment) |c| {
        try writer.writeAll("\nCOMMENT ON FUNCTION ");
        try writer.writeAll(F.name);
        try writer.writeAll("(");
        try renderArgs(writer, F, fn_info, .identity);
        try writer.writeAll(") IS ");
        try writeSqlString(writer, c);
        try writer.writeAll(";");
    }
    try writer.writeAll("\n");
}

const ArgStyle = enum {
    /// Full parameter list for `CREATE FUNCTION`: modes, names, defaults.
    definition,
    /// Input argument types only, as used to identify the function (`COMMENT
    /// ON FUNCTION`, `ALTER FUNCTION`, ...).
    identity,
};

fn hasOutputParams(comptime F: anytype) bool {
    const params = F.params orelse return false;
    for (params) |p| {
        if (p.mode.isOutput()) return true;
    }
    return false;
}

/// SQL types of the Zig signature's parameters, `FunctionCallInfo` skipped.
fn derivedArgTypes(comptime F: anytype, comptime fn_info: anytype) []const []const u8 {
    comptime {
        var n: usize = 0;
        for (fn_info.params) |param| {
            const P = param.type orelse
                @compileError("pgzx.ddl: '" ++ F.name ++ "' has an unresolved parameter type");
            if (P != pg.FunctionCallInfo) n += 1;
        }
        var types: [n][]const u8 = undefined;
        var i: usize = 0;
        for (fn_info.params) |param| {
            const P = param.type.?;
            if (P == pg.FunctionCallInfo) continue;
            types[i] = datum.sqlType(P);
            i += 1;
        }
        const final = types;
        return &final;
    }
}

/// Resolves `params` against the Zig signature: every input param without an
/// explicit `type` takes the next derived type in order.
fn resolvedParams(comptime F: anytype, comptime fn_info: anytype) []const Param {
    comptime {
        const params = F.params.?;
        var resolved: [params.len]Param = undefined;
        var next: usize = 0;
        for (params, 0..) |p, i| {
            resolved[i] = p;
            if (p.type == null) {
                if (!p.mode.isInput()) {
                    @compileError("pgzx.ddl: OUT param in '" ++ F.name ++ "' needs an explicit `type`");
                }
                const derived = derivedArgTypes(F, fn_info);
                if (next >= derived.len) {
                    @compileError("pgzx.ddl: '" ++ F.name ++ "' has more untyped params than Zig arguments");
                }
                resolved[i].type = derived[next];
            }
            if (p.mode.isInput()) next += 1;
        }
        const final = resolved;
        return &final;
    }
}

/// Writes the comma-separated SQL argument list. `params` wins over `args`,
/// which wins over the types derived from the Zig signature.
fn renderArgs(writer: anytype, comptime F: anytype, comptime fn_info: anytype, comptime style: ArgStyle) !void {
    if (F.params != null) {
        const params = comptime resolvedParams(F, fn_info);
        var first = true;
        inline for (params) |p| {
            if (comptime (style == .identity and !p.mode.isInput())) continue;
            if (!first) try writer.writeAll(", ");
            first = false;
            if (style == .definition) {
                try writer.writeAll(p.mode.prefix());
                if (p.name) |n| {
                    try writer.writeAll(n);
                    try writer.writeAll(" ");
                }
            } else if (p.mode == .variadic) {
                try writer.writeAll(p.mode.prefix());
            }
            try writer.writeAll(p.type.?);
            if (style == .definition) {
                if (p.default) |d| {
                    try writer.writeAll(" DEFAULT ");
                    try writer.writeAll(d);
                }
            }
        }
        return;
    }
    const types = F.args orelse comptime derivedArgTypes(F, fn_info);
    for (types, 0..) |arg, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.writeAll(arg);
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

    const attr_schema = .{
        .functions = .{
            .{
                .name = "demo_clamp",
                .func = sample_functions.add,
                .params = &[_]Param{
                    .{ .name = "a" },
                    .{ .name = "b", .default = "0" },
                },
                .security = .definer,
                .leakproof = true,
                .cost = 10,
                .set = &[_]Setting{
                    .{ .name = "search_path", .value = "pg_catalog, pg_temp" },
                    .{ .name = "work_mem", .value = null },
                },
                .comment = "clamped",
            },
            .{
                .name = "demo_split",
                .func = sample_functions.add,
                .params = &[_]Param{
                    .{ .name = "a" },
                    .{ .name = "b", .mode = .inout },
                    .{ .name = "c", .type = "text", .mode = .out },
                },
                .or_replace = true,
                .rows = 5,
            },
            .{
                .name = "demo_sum",
                .func = sample_functions.add,
                .params = &[_]Param{
                    .{},
                    .{ .type = "integer[]", .mode = .variadic },
                },
                .comment = "variadic",
            },
        },
    };

    pub fn testRenderAttributes() !void {
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try render(&writer, attr_schema);
        const out = writer.buffered();

        const expected =
            \\CREATE FUNCTION demo_clamp(a integer, b integer DEFAULT 0) RETURNS integer
            \\AS 'MODULE_PATHNAME'
            \\LANGUAGE C SECURITY DEFINER LEAKPROOF COST 10
            \\SET search_path = pg_catalog, pg_temp
            \\SET work_mem FROM CURRENT;
            \\COMMENT ON FUNCTION demo_clamp(integer, integer) IS 'clamped';
            \\CREATE OR REPLACE FUNCTION demo_split(a integer, INOUT b integer, OUT c text)
            \\AS 'MODULE_PATHNAME'
            \\LANGUAGE C ROWS 5;
            \\CREATE FUNCTION demo_sum(integer, VARIADIC integer[]) RETURNS integer
            \\AS 'MODULE_PATHNAME'
            \\LANGUAGE C;
            \\COMMENT ON FUNCTION demo_sum(integer, VARIADIC integer[]) IS 'variadic';
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
