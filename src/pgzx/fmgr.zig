const std = @import("std");

const pg = @import("pgzx_pgsys");

const elog = @import("elog.zig");
const datum = @import("datum.zig");
const heap_tuple = @import("heap_tuple.zig");
const mem = @import("mem.zig");
const meta = @import("meta.zig");
const srf = @import("srf.zig");

pub const args = @import("fmgr/args.zig");
pub const varatt = pg.varatt;

pub const Pg_magic_struct = pg.Pg_magic_struct;
pub const Pg_finfo_record = pg.Pg_finfo_record;

pub const MAGIC = [*c]const Pg_magic_struct;
pub const FN_INFO_V1 = [*c]const Pg_finfo_record;

/// Use PG_MAGIC value to indicate to PostgreSQL that we have a loadable module.
/// This value must be returned by a function named `Pg_magic_func`.
pub const PG_MAGIC = if (pg.PG_VERSION_NUM >= 180000)
    // PG18 nests the ABI fields in a `Pg_abi_values abi_fields` struct
    // (name/version for PG_MODULE_MAGIC_EXT come after it; NULL here).
    Pg_magic_struct{
        .len = @bitCast(@as(c_uint, @truncate(@sizeOf(Pg_magic_struct)))),
        .abi_fields = .{
            .version = @divTrunc(pg.PG_VERSION_NUM, @as(c_int, 100)),
            .funcmaxargs = pg.FUNC_MAX_ARGS,
            .indexmaxkeys = pg.INDEX_MAX_KEYS,
            .namedatalen = pg.NAMEDATALEN,
            .float8byval = pg.FLOAT8PASSBYVAL,
            .abi_extra = [32]u8{ 'P', 'o', 's', 't', 'g', 'r', 'e', 'S', 'Q', 'L', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        },
    }
else
    // PG15-17: same ABI fields, flat in the struct.
    Pg_magic_struct{
        .len = @bitCast(@as(c_uint, @truncate(@sizeOf(Pg_magic_struct)))),
        .version = @divTrunc(pg.PG_VERSION_NUM, @as(c_int, 100)),
        .funcmaxargs = pg.FUNC_MAX_ARGS,
        .indexmaxkeys = pg.INDEX_MAX_KEYS,
        .namedatalen = pg.NAMEDATALEN,
        .float8byval = pg.FLOAT8PASSBYVAL,
        .abi_extra = [32]u8{ 'P', 'o', 's', 't', 'g', 'r', 'e', 'S', 'Q', 'L', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    };

/// Postgres magic indicator that a function uses the v1 UDF API.
pub const PG_FINFO_V1_RECORD = Pg_finfo_record{
    .api_version = 1,
};

/// Magic PostgreSQL symbols to indicate it's a loadable module.
///
/// We do not export the symbol to postgres. If you want to indicate that you have a loadable module
/// use `Pg_magic_func` like so in your module:
///
///   pub export fn Pg_magic_func() [*c]const pg.Pg_magic_struct {
///     return pgzx.Pg_magic_func();
///   }
///
pub inline fn PG_MODULE_MAGIC() void {
    @export(&Pg_magic_func, .{ .name = "Pg_magic_func" });
}

fn Pg_magic_func() callconv(.c) [*c]const Pg_magic_struct {
    return &PG_MAGIC;
}

pub fn FunctionV1() callconv(.c) [*c]const Pg_finfo_record {
    return &PG_FINFO_V1_RECORD;
}

pub inline fn PG_FUNCTION_INFO_V1(comptime fun: []const u8) void {
    const finfo_name = "pg_finfo_" ++ fun;
    @export(&FunctionV1, .{ .name = finfo_name });
}

pub inline fn PG_FUNCTION_V1(comptime name: []const u8, comptime callback: anytype) void {
    PG_FUNCTION_INFO_V1(name);

    const reg = genFnCall(callback);
    @export(&reg.call, .{ .name = name });
}

pub inline fn PG_EXPORT(comptime mod: type) void {
    const decl_names = switch (@typeInfo(mod)) {
        .@"struct" => |s| s.decl_names,
        else => @compileError("PG_EXPORT requires a struct"),
    };

    inline for (decl_names) |decl_name| {
        const value = @field(mod, decl_name);
        const ft = @typeInfo(@TypeOf(value));
        if (ft != .@"fn" or ft.@"fn".is_generic or ft.@"fn".attrs.varargs) {
            continue;
        }
        PG_FUNCTION_V1(decl_name, value);
    }
}

inline fn genFnCall(comptime f: anytype) type {
    return struct {
        const function: @TypeOf(f) = f;
        fn call(fcinfo: pg.FunctionCallInfo) callconv(.c) pg.Datum {
            return pgCall(@src(), function, fcinfo);
        }
    };
}

pub const Arg = args.Arg;
pub const ArgType = args.ArgType;

/// Reads the call arguments of `impl` from `fcinfo`.
inline fn readCallArgs(
    comptime src: std.builtin.SourceLocation,
    comptime impl: anytype,
    fcinfo: pg.FunctionCallInfo,
) std.meta.ArgsTuple(@TypeOf(impl)) {
    const funcArgType = std.meta.ArgsTuple(@TypeOf(impl));

    var callArgs: funcArgType = undefined;
    comptime var info_idx = 0;
    inline for (@typeInfo(@TypeOf(callArgs)).@"struct".field_types, 0..) |field_type, i| {
        const arg = ArgType(field_type);
        callArgs[i] = arg.read(fcinfo, info_idx) catch |e| elog.throwAsPostgresError(src, e);
        if (arg.consumesArgument()) {
            info_idx += 1;
        }
    }
    return callArgs;
}

/// The value a function returns once an error union is unwrapped.
fn ReturnPayload(comptime fnType: type) type {
    const R = meta.fnReturnType(fnType);
    return switch (@typeInfo(R)) {
        .error_union => |eu| eu.payload,
        .error_set => void,
        else => R,
    };
}

inline fn callImpl(
    comptime src: std.builtin.SourceLocation,
    comptime impl: anytype,
    callArgs: std.meta.ArgsTuple(@TypeOf(impl)),
) ReturnPayload(@TypeOf(impl)) {
    return switch (@typeInfo(meta.fnReturnType(@TypeOf(impl)))) {
        .error_union, .error_set => @call(.no_suspend, impl, callArgs) catch |e| elog.throwAsPostgresError(src, e),
        else => @call(.no_suspend, impl, callArgs),
    };
}

pub inline fn pgCall(
    comptime src: std.builtin.SourceLocation,
    comptime impl: anytype,
    fcinfo: pg.FunctionCallInfo,
) pg.Datum {
    if (comptime srf.isSetReturning(ReturnPayload(@TypeOf(impl)))) {
        return pgCallSetReturning(src, impl, fcinfo);
    }

    const callArgs = readCallArgs(src, impl, fcinfo);
    const value = callImpl(src, impl, callArgs);

    const result_conv = datum.findConv(@TypeOf(value));
    const nullable_datum = result_conv.toNullableDatum(value) catch |e| elog.throwAsPostgresError(src, e);
    if (nullable_datum.isnull) {
        fcinfo.*.isnull = true;
        return 0;
    }
    return nullable_datum.value;
}

/// State of a running set, kept in `FuncCallContext.user_fctx` for the
/// lifetime of the set.
fn SetState(comptime R: type) type {
    return struct {
        iter: R.Iter,
        /// Blessed row descriptor for `Table` results with several columns.
        tupdesc: pg.TupleDesc,
    };
}

/// Value-per-call protocol: the first call runs `impl` in the set's memory
/// context and moves the returned iterator there; every call then produces
/// one row from `next`.
fn pgCallSetReturning(
    comptime src: std.builtin.SourceLocation,
    comptime impl: anytype,
    fcinfo: pg.FunctionCallInfo,
) pg.Datum {
    const R = ReturnPayload(@TypeOf(impl));
    const State = SetState(R);

    if (pg.pgzx_srf_is_first_call(fcinfo)) {
        pg.pgzx_srf_check_context(fcinfo);
        const cx = pg.pgzx_srf_init(fcinfo);
        const set_ctx = pg.pgzx_srf_memctx(cx);

        const old_ctx = pg.MemoryContextSwitchTo(set_ctx);
        const callArgs = readCallArgs(src, impl, fcinfo);
        const returned = callImpl(src, impl, callArgs);

        var allocator = mem.MemoryContextAllocator.init(set_ctx, .{ .flags = 0 });
        const state = allocator.allocator().create(State) catch |e| elog.throwAsPostgresError(src, e);
        state.* = .{ .iter = returned.iter, .tupdesc = null };

        if (comptime R.pgzx_srf == srf.Kind.table and srf.columnCount(R.Item) > 1) {
            var tupdesc: pg.TupleDesc = null;
            if (pg.pgzx_srf_result_tupdesc(fcinfo, &tupdesc) != pg.PGZX_SRF_RESULT_COMPOSITE) {
                elog.throwAsPostgresError(src, error.NotACompositeType);
            }
            if (tupdesc.*.natts != srf.columnCount(R.Item)) {
                elog.throwAsPostgresError(src, error.IncorrectAttributeCount);
            }
            state.tupdesc = tupdesc;
        }

        if (comptime @hasDecl(R.Iter, "deinit")) {
            allocator.registerAllocResetCallback(state, struct {
                fn run(s: *State) void {
                    s.iter.deinit();
                }
            }.run) catch |e| elog.throwAsPostgresError(src, e);
        }

        pg.pgzx_srf_set_user(cx, state);
        _ = pg.MemoryContextSwitchTo(old_ctx);
    }

    const cx = pg.pgzx_srf_per_call(fcinfo);
    const state: *State = @ptrCast(@alignCast(pg.pgzx_srf_user(cx)));

    const next = if (comptime srf.nextCanFail(R.Iter))
        state.iter.next() catch |e| elog.throwAsPostgresError(src, e)
    else
        state.iter.next();

    const item = next orelse {
        pg.pgzx_srf_return_done(fcinfo, cx);
        return 0;
    };

    const nullable_datum = srfItemToDatum(R, state, item) catch |e| elog.throwAsPostgresError(src, e);
    pg.pgzx_srf_return_next(fcinfo, cx);
    if (nullable_datum.isnull) {
        fcinfo.*.isnull = true;
        return 0;
    }
    return nullable_datum.value;
}

fn srfItemToDatum(comptime R: type, state: *SetState(R), item: R.Item) !pg.NullableDatum {
    if (comptime R.pgzx_srf == srf.Kind.table and srf.columnCount(R.Item) > 1) {
        const tupdesc = heap_tuple.TupleDesc.fromPg(state.tupdesc).?;
        var tuple = try heap_tuple.HeapTuple.fromValues(tupdesc, item);
        defer tuple.deinit();
        return .{ .value = try tuple.toCompositeDatum(), .isnull = false };
    }

    // `SETOF` and single-column `TABLE` results are plain values.
    const value = if (comptime R.pgzx_srf == srf.Kind.table) @field(item, @typeInfo(R.Item).@"struct".field_names[0]) else item;
    return datum.findConv(@TypeOf(value)).toNullableDatum(value);
}
