const std = @import("std");

const pg = @import("pgzx_pgsys");

const err = @import("err.zig");
const itemptr = @import("itemptr.zig");
const mem = @import("mem.zig");
const meta = @import("meta.zig");
const varatt = @import("varatt.zig");
const xid = @import("xid.zig");

pub fn fromNullableDatum(comptime T: type, d: pg.NullableDatum) !T {
    return findConv(T).fromNullableDatum(d);
}

pub fn fromNullableDatumWithOID(comptime T: type, d: pg.NullableDatum, oid: ?pg.Oid) !T {
    return findConv(T).fromNullableDatumWithOID(d, oid);
}

pub fn fromDatum(comptime T: type, d: pg.Datum, is_null: bool) !T {
    return findConv(T).fromNullableDatum(.{ .value = d, .isnull = is_null });
}

pub fn fromDatumWithOID(comptime T: type, d: pg.Datum, is_null: bool, oid: ?pg.Oid) !T {
    return findConv(T).fromNullableDatumWithOID(.{ .value = d, .isnull = is_null }, oid);
}

pub fn toNullableDatum(v: anytype) !pg.NullableDatum {
    return findConv(@TypeOf(v)).toNullableDatum(v);
}

pub fn toNullableDatumWithOID(v: anytype, oid: ?pg.Oid) !pg.NullableDatum {
    return findConv(@TypeOf(v)).toNullableDatumWithOID(v, oid);
}

// pub fn Conv(comptime T: type, comptime from: anytype, comptime to: anytype) type {
pub fn Conv(comptime context: type) type {
    return struct {
        pub const Type = context.Type;

        /// SQL name used when generating DDL for this type. `null` means the
        /// type has no direct SQL representation (e.g. `Datum`).
        pub const sql_name: ?[]const u8 = if (@hasDecl(context, "sql_name")) context.sql_name else null;

        const Self = @This();

        pub fn fromNullableDatum(d: pg.NullableDatum) !Type {
            return Self.fromNullableDatumWithOID(d, null);
        }

        pub fn fromNullableDatumWithOID(d: pg.NullableDatum, oid: ?pg.Oid) !Type {
            if (d.isnull) {
                return err.PGError.UnexpectedNullValue;
            }
            return try context.from(d.value, normalizeOid(oid));
        }

        pub fn toNullableDatum(v: Type) !pg.NullableDatum {
            return Self.toNullableDatumWithOID(v, null);
        }

        pub fn toNullableDatumWithOID(v: Type, oid: ?pg.Oid) !pg.NullableDatum {
            return .{
                .value = try context.to(v, normalizeOid(oid)),
                .isnull = false,
            };
        }
    };
}

pub fn ConvNoFail(comptime context: type) type {
    return Conv(struct {
        pub const Type = context.Type;
        pub const sql_name = if (@hasDecl(context, "sql_name")) context.sql_name else null;

        pub fn from(d: pg.Datum, oid: pg.Oid) !Type {
            return context.from(d, oid);
        }

        pub fn to(v: Type, oid: pg.Oid) !pg.Datum {
            return context.to(v, oid);
        }
    });
}

pub fn SimpleConv(
    comptime T: type,
    comptime from_datum: anytype,
    comptime to_datum: anytype,
    comptime sql_type_name: ?[]const u8,
) type {
    return ConvNoFail(struct {
        pub const Type = T;
        pub const sql_name = sql_type_name;

        pub fn from(d: pg.Datum, oid: pg.Oid) !Type {
            _ = oid;
            return from_datum(d);
        }

        pub fn to(v: Type, oid: pg.Oid) !pg.Datum {
            _ = oid;
            return to_datum(v);
        }
    });
}

/// Conversion decorator for optional types.
pub fn OptConv(comptime C: anytype) type {
    return struct {
        pub const Type = ?C.Type;
        pub const sql_name = if (@hasDecl(C, "sql_name")) C.sql_name else null;

        const Self = @This();

        pub fn fromNullableDatum(d: pg.NullableDatum) !Type {
            return try Self.fromNullableDatumWithOID(d, null);
        }

        pub fn fromNullableDatumWithOID(d: pg.NullableDatum, oid: ?pg.Oid) !Type {
            if (d.isnull) {
                return null;
            }
            return try C.fromNullableDatumWithOID(d, oid);
        }

        pub fn toNullableDatum(v: Type) !pg.NullableDatum {
            return Self.toNullableDatumWithOID(v, null);
        }

        pub fn toNullableDatumWithOID(v: Type, oid: ?pg.Oid) !pg.NullableDatum {
            if (v) |value| {
                return try C.toNullableDatumWithOID(value, oid);
            } else {
                return .{
                    .value = 0,
                    .isnull = true,
                };
            }
        }
    };
}

/// Map concrete type to their converters.
/// This allows us find to return pre-defined converters besides relying on
/// reflection only.
var directMappings = .{
    .{ pg.Datum, PGDatum },
    .{ pg.ItemPointerData, Tid },
    .{ xid.Xid, XidConv },
    .{ xid.Cid, CidConv },
    .{ xid.Xid8, Xid8Conv },
    .{ Uuid, UuidConv },
    .{ Bytea, ByteaConv },
    .{ Date, DateConv },
    .{ Time, TimeConv },
    .{ Timestamp, TimestampConv },
    .{ TimestampTz, TimestampTzConv },
    .{ pg.Interval, IntervalConv },
};

pub fn findConv(comptime T: type) type {
    if (isConv(T)) { // is T already a converter?
        return T;
    }
    comptime for (directMappings) |e| {
        if (e[0] == T) {
            return e[1];
        }
    };

    // TODO:
    // allow types to implement conversion functions directly
    // in that case we will return the original type by wrapping it in
    // Conv

    return switch (@typeInfo(T)) {
        .void => Void,
        .bool => Bool,
        .int => |i| switch (i.signedness) {
            .signed => switch (i.bits) {
                8 => Int8,
                16 => Int16,
                32 => Int32,
                64 => Int64,
                else => @compileError("unsupported int type"),
            },
            .unsigned => switch (i.bits) {
                8 => UInt8,
                16 => UInt16,
                32 => UInt32,
                64 => UInt64,
                else => @compileError("unsupported unsigned int type"),
            },
        },
        .float => |f| switch (f.bits) {
            32 => Float32,
            64 => Float64,
            else => @compileError("unsupported float type"),
        },
        .optional => |opt| OptConv(findConv(opt.child)),
        .array => @compileLog("fixed size arrays not supported"),
        .pointer => blk: {
            if (!meta.isStringLike(T) and !meta.isSlice(T)) {
                @compileLog("type:", T);
                @compileError("unsupported ptr type");
            }
            if (meta.isSlice(T) and !meta.isStringLike(T)) {
                break :blk ArrayConv(meta.sliceElemType(T));
            }
            break :blk if (meta.hasSentinal(T)) SliceU8Z else SliceU8;
        },
        else => {
            @compileLog("type:", T);
            @compileError("type not supported");
        },
    };
}

inline fn isConv(comptime T: type) bool {
    // we require T to be a struct with the following fields:
    // Type: type
    // fromDatum: fn(d: pg.Datum) !Type
    // toDatum: fn(v: Type) !pg.Datum

    if (@typeInfo(T) != .@"struct") {
        return false;
    }

    // TODO: improve checks
    return @hasDecl(T, "Type") and @hasDecl(T, "fromNullableDatum") and @hasDecl(T, "toNullableDatum");
}

/// Returns the PostgreSQL SQL type name for a Zig type. The mapping is derived
/// from the type's converter and is used to generate DDL. Types without a SQL
/// representation (for example a raw `pg.Datum`) produce a compile error.
pub fn sqlType(comptime T: type) []const u8 {
    const C = findConv(T);
    if (@hasDecl(C, "sql_name")) {
        if (C.sql_name) |name| return name;
    }
    @compileError("pgzx.datum: no SQL type mapping for Zig type " ++ @typeName(T));
}

inline fn normalizeOid(oid: ?pg.Oid) pg.Oid {
    return oid orelse pg.InvalidOid;
}

pub const Void = SimpleConv(void, idDatum, toVoid, "void");
pub const Bool = SimpleConv(bool, scalar.getBool, scalar.putBool, "boolean");
pub const Int8 = SimpleConv(i8, scalar.get(i8), scalar.put(i8), "smallint");
pub const Int16 = SimpleConv(i16, scalar.get(i16), scalar.put(i16), "smallint");
pub const Int32 = SimpleConv(i32, scalar.get(i32), scalar.put(i32), "integer");
pub const Int64 = SimpleConv(i64, scalar.get(i64), scalar.put(i64), "bigint");
pub const UInt8 = SimpleConv(u8, scalar.get(u8), scalar.put(u8), "smallint");
pub const UInt16 = SimpleConv(u16, scalar.get(u16), scalar.put(u16), "integer");
pub const UInt32 = SimpleConv(u32, scalar.get(u32), scalar.put(u32), "bigint");
pub const UInt64 = SimpleConv(u64, scalar.get(u64), scalar.put(u64), "bigint");
pub const Float32 = SimpleConv(f32, scalar.getFloat4, scalar.putFloat4, "real");
pub const Float64 = SimpleConv(f64, scalar.getFloat8, scalar.putFloat8, "double precision");
pub const PGDatum = SimpleConv(pg.Datum, idDatum, idDatum, null);

/// Converter for PostgreSQL's `tid` type, mapped to the raw
/// `pg.ItemPointerData` struct so it stays bit-compatible with the C layout.
/// Helpers for reading/writing it live in `itemptr.zig`.
pub const Tid = Conv(struct {
    pub const Type = pg.ItemPointerData;
    pub const sql_name = "tid";

    pub fn from(d: pg.Datum, oid: pg.Oid) !Type {
        _ = oid;
        const src = pg.DatumGetItemPointer(d);
        var tid: Type = .{};
        itemptr.itemPointerSetAll(
            &tid,
            itemptr.itemPointerGetBlockNumber(src),
            itemptr.itemPointerGetOffsetNumber(src),
        );
        return tid;
    }

    pub fn to(v: Type, oid: pg.Oid) !pg.Datum {
        _ = oid;
        const tid = try itemptr.newItemPointer(
            itemptr.itemPointerGetBlockNumberNoCheck(v),
            itemptr.itemPointerGetOffsetNumberNoCheck(v),
        );
        return pg.ItemPointerGetDatum(tid);
    }
});

// Transaction identifier types. `xid` and `cid` are passed by value as 32-bit
// integers, `xid8` as a 64-bit integer. See `xid.zig` for the Zig types.
const XidConv = SimpleConv(xid.Xid, getXid, putXid, "xid");
const CidConv = SimpleConv(xid.Cid, getCid, putCid, "cid");
const Xid8Conv = SimpleConv(xid.Xid8, getXid8, putXid8, "xid8");

fn getXid(d: pg.Datum) xid.Xid {
    return .{ .value = scalar.get(u32)(d) };
}

fn putXid(v: xid.Xid) pg.Datum {
    return scalar.put(u32)(v.value);
}

fn getCid(d: pg.Datum) xid.Cid {
    return .{ .value = scalar.get(u32)(d) };
}

fn putCid(v: xid.Cid) pg.Datum {
    return scalar.put(u32)(v.value);
}

fn getXid8(d: pg.Datum) xid.Xid8 {
    return .{ .value = scalar.get(u64)(d) };
}

fn putXid8(v: xid.Xid8) pg.Datum {
    return scalar.put(u64)(v.value);
}

// ---------------------------------------------------------------------------
// Built-in non-scalar types: uuid, bytea and the date/time family.
//
// The value types mirror PostgreSQL's on-the-wire units rather than a calendar
// API: `Date` is days since 2000-01-01, `Time` is microseconds since midnight
// and `Timestamp`/`TimestampTz` are microseconds since 2000-01-01 (PostgreSQL's
// epoch, not the Unix one). Calendar helpers can be layered on top later.
// ---------------------------------------------------------------------------

/// `uuid`, stored as the server's 16 raw bytes (bit-compatible with
/// `pg_uuid_t`).
pub const Uuid = extern struct {
    data: [16]u8,
};

const UuidConv = Conv(struct {
    pub const Type = Uuid;
    pub const sql_name = "uuid";

    pub fn from(d: pg.Datum, oid: pg.Oid) !Type {
        _ = oid;
        const src: *const Uuid = @ptrFromInt(d);
        return src.*;
    }

    pub fn to(v: Type, oid: pg.Oid) !pg.Datum {
        _ = oid;
        const p = try mem.PGCurrentContextAllocator.create(Uuid);
        p.* = v;
        return pg.PointerGetDatum(@ptrCast(p));
    }
});

/// `bytea`, mapped to a borrowed byte slice. Distinct from `[]const u8` (which
/// is `text`) so the SQL type is explicit.
pub const Bytea = struct {
    bytes: []const u8,
};

const ByteaConv = Conv(struct {
    pub const Type = Bytea;
    pub const sql_name = "bytea";

    pub fn from(d: pg.Datum, oid: pg.Oid) !Type {
        _ = oid;
        // `DatumGetByteaPP` already detoasts, so `ptr` is a plain in-line
        // varlena; read the payload straight out of it.
        const ptr = pg.DatumGetByteaPP(d);
        const len = varatt.VARSIZE_ANY_EXHDR(ptr);
        const buf = try mem.PGCurrentContextAllocator.alloc(u8, len);
        @memcpy(buf, varatt.VARDATA_ANY(ptr)[0..len]);
        return .{ .bytes = buf };
    }

    pub fn to(v: Type, oid: pg.Oid) !pg.Datum {
        _ = oid;
        const hdr: usize = @intCast(varatt.VARHDRSZ);
        const total = hdr + v.bytes.len;
        const buf = try mem.PGCurrentContextAllocator.alloc(u8, total);
        varatt.SET_VARSIZE(buf.ptr, total);
        @memcpy(buf[hdr..], v.bytes);
        return pg.PointerGetDatum(@ptrCast(buf.ptr));
    }
});

/// `date`: days since 2000-01-01.
pub const Date = struct {
    days: i32,
};

const DateConv = Conv(struct {
    pub const Type = Date;
    pub const sql_name = "date";

    pub fn from(d: pg.Datum, oid: pg.Oid) !Type {
        _ = oid;
        return .{ .days = scalar.get(i32)(d) };
    }

    pub fn to(v: Type, oid: pg.Oid) !pg.Datum {
        _ = oid;
        return scalar.put(i32)(v.days);
    }
});

/// `time`: microseconds since midnight.
pub const Time = struct {
    micros: i64,
};

const TimeConv = Conv(struct {
    pub const Type = Time;
    pub const sql_name = "time";

    pub fn from(d: pg.Datum, oid: pg.Oid) !Type {
        _ = oid;
        return .{ .micros = scalar.get(i64)(d) };
    }

    pub fn to(v: Type, oid: pg.Oid) !pg.Datum {
        _ = oid;
        return scalar.put(i64)(v.micros);
    }
});

/// `timestamp`: microseconds since 2000-01-01.
pub const Timestamp = struct {
    micros: i64,
};

const TimestampConv = Conv(struct {
    pub const Type = Timestamp;
    pub const sql_name = "timestamp";

    pub fn from(d: pg.Datum, oid: pg.Oid) !Type {
        _ = oid;
        return .{ .micros = scalar.get(i64)(d) };
    }

    pub fn to(v: Type, oid: pg.Oid) !pg.Datum {
        _ = oid;
        return scalar.put(i64)(v.micros);
    }
});

/// `timestamp with time zone`: microseconds since 2000-01-01, UTC.
pub const TimestampTz = struct {
    micros: i64,
};

const TimestampTzConv = Conv(struct {
    pub const Type = TimestampTz;
    pub const sql_name = "timestamp with time zone";

    pub fn from(d: pg.Datum, oid: pg.Oid) !Type {
        _ = oid;
        return .{ .micros = scalar.get(i64)(d) };
    }

    pub fn to(v: Type, oid: pg.Oid) !pg.Datum {
        _ = oid;
        return scalar.put(i64)(v.micros);
    }
});

/// `interval`: PostgreSQL's 16-byte struct (`time` usec, `day`, `month`).
pub const Interval = pg.Interval;

const IntervalConv = Conv(struct {
    pub const Type = Interval;
    pub const sql_name = "interval";

    pub fn from(d: pg.Datum, oid: pg.Oid) !Type {
        _ = oid;
        return pg.DatumGetIntervalP(d).*;
    }

    pub fn to(v: Type, oid: pg.Oid) !pg.Datum {
        _ = oid;
        const p = try mem.PGCurrentContextAllocator.create(pg.Interval);
        p.* = v;
        return pg.IntervalPGetDatum(@ptrCast(p));
    }
});

pub const SliceU8Z = Conv(struct {
    pub const Type = [:0]const u8;
    pub const sql_name = "text";
    pub const from = getDatumStringLikeZ;
    pub const to = sliceToDatumStringLikeZ;
});

pub const SliceU8 = Conv(struct {
    pub const Type = []const u8;
    pub const sql_name = "text";
    pub const from = getDatumStringLikeZ;
    pub const to = sliceToDatumStringLike;
});

/// Returns the OID of the built-in PostgreSQL type a Zig type maps to. Only
/// types that can be array elements are supported.
pub fn typeOid(comptime T: type) pg.Oid {
    return switch (T) {
        bool => pg.BOOLOID,
        i16 => pg.INT2OID,
        i32 => pg.INT4OID,
        i64 => pg.INT8OID,
        f32 => pg.FLOAT4OID,
        f64 => pg.FLOAT8OID,
        []const u8, [:0]const u8 => pg.TEXTOID,
        pg.ItemPointerData => pg.TIDOID,
        Uuid => pg.UUIDOID,
        Bytea => pg.BYTEAOID,
        Date => pg.DATEOID,
        Time => pg.TIMEOID,
        Timestamp => pg.TIMESTAMPOID,
        TimestampTz => pg.TIMESTAMPTZOID,
        pg.Interval => pg.INTERVALOID,
        else => @compileError("pgzx.datum: no type OID for Zig type " ++ @typeName(T)),
    };
}

/// Converter for one-dimensional PostgreSQL arrays, mapped to `[]const Elem`.
///
/// `Elem` may be optional (`[]const ?i32`) to accept arrays with NULL
/// elements; with a non-optional `Elem` a NULL element is an
/// `UnexpectedNullValue` error. Multi-dimensional inputs are flattened in
/// storage order. Decoded slices are allocated in the current memory context.
pub fn ArrayConv(comptime Elem: type) type {
    const Base = switch (@typeInfo(Elem)) {
        .optional => |o| o.child,
        else => Elem,
    };
    const elem_oid = typeOid(Base);
    return Conv(struct {
        pub const Type = []const Elem;
        pub const sql_name = sqlType(Base) ++ "[]";

        pub fn from(d: pg.Datum, oid: pg.Oid) !Type {
            _ = oid;
            return arrayFromDatum(Elem, elem_oid, d);
        }

        pub fn to(v: Type, oid: pg.Oid) !pg.Datum {
            _ = oid;
            return arrayToDatum(Elem, elem_oid, v);
        }
    });
}

/// Zero-copy view of a one-dimensional (or flattened) array of a fixed-width
/// built-in element type: `bool`, `i16`, `i32`, `i64`, `f32` or `f64`.
///
/// `items` points straight at the array's element data: no
/// `deconstruct_array`, no per-element conversion, no copy. Postgres stores
/// these element types packed and aligned, so the data is a plain `[]const T`.
/// The array is only copied when it has to be detoasted (compressed,
/// out-of-line or short-header values).
///
/// An array containing NULLs is rejected with `UnexpectedNullValue`, like
/// pgrx's `Array::as_slice`; use `[]const ?T` (`ArrayConv`) for those.
///
/// `items` is valid while the datum is, i.e. for the duration of the
/// function call. Copy it to keep it longer.
///
/// `ArrayView(T)` is itself a converter, so it can be used as a function
/// parameter (or return) type; the SQL type is `<element>[]`:
///
/// ```zig
/// pub fn sum_vector(v: pgzx.datum.ArrayView(f32)) f32 {
///     var sum: f32 = 0;
///     for (v.items) |x| sum += x;
///     return sum;
/// }
/// ```
pub fn ArrayView(comptime T: type) type {
    const elem_oid = typeOid(T);
    switch (T) {
        bool, i16, i32, i64, f32, f64 => {},
        else => @compileError("pgzx.datum.ArrayView: " ++ @typeName(T) ++ " is not a fixed-width element type"),
    }

    return struct {
        items: []const T,

        const Self = @This();

        // Converter interface (see `isConv`).
        pub const Type = Self;
        pub const sql_name: ?[]const u8 = sqlType(T) ++ "[]";

        pub fn fromDatum(d: pg.Datum) !Self {
            const detoasted = try err.wrap(pg.pg_detoast_datum, .{@as([*c]pg.struct_varlena, @ptrCast(@alignCast(pg.DatumGetPointer(d))))});
            const arr: *const pg.ArrayType = @ptrCast(@alignCast(detoasted));
            if (arr.elemtype != elem_oid) {
                return err.PGError.UnexpectedArrayElementType;
            }

            const ndim: usize = @intCast(arr.ndim);
            const base: [*]const u8 = @ptrCast(arr);
            // ARR_DIMS: the dimensions follow the fixed header.
            const dims: [*]const c_int = @ptrCast(@alignCast(base + @sizeOf(pg.ArrayType)));
            const count: usize = if (ndim == 0) 0 else @intCast(try err.wrap(pg.ArrayGetNItems, .{ arr.ndim, dims }));

            // ARR_HASNULL only says a null bitmap is present; it may still
            // hold no NULLs.
            if (arr.dataoffset != 0 and pg.array_contains_nulls(@constCast(arr))) {
                return err.PGError.UnexpectedNullValue;
            }

            // ARR_DATA_OFFSET
            const data_offset: usize = if (arr.dataoffset != 0)
                @intCast(arr.dataoffset)
            else
                std.mem.alignForward(usize, @sizeOf(pg.ArrayType) + 2 * @sizeOf(c_int) * ndim, pg.MAXIMUM_ALIGNOF);
            const data: [*]const T = @ptrCast(@alignCast(base + data_offset));
            return .{ .items = data[0..count] };
        }

        pub fn fromNullableDatum(d: pg.NullableDatum) !Self {
            return Self.fromNullableDatumWithOID(d, null);
        }

        pub fn fromNullableDatumWithOID(d: pg.NullableDatum, oid: ?pg.Oid) !Self {
            _ = oid;
            if (d.isnull) return err.PGError.UnexpectedNullValue;
            return Self.fromDatum(d.value);
        }

        pub fn toNullableDatum(v: Self) !pg.NullableDatum {
            return Self.toNullableDatumWithOID(v, null);
        }

        /// Builds a new array from `items` (a copy).
        pub fn toNullableDatumWithOID(v: Self, oid: ?pg.Oid) !pg.NullableDatum {
            _ = oid;
            return .{ .value = try arrayToDatum(T, elem_oid, v.items), .isnull = false };
        }
    };
}

const ElemLayout = struct {
    len: i16,
    byval: bool,
    alignment: u8,

    fn of(oid: pg.Oid) ElemLayout {
        var layout: ElemLayout = undefined;
        pg.get_typlenbyvalalign(oid, &layout.len, &layout.byval, &layout.alignment);
        return layout;
    }
};

fn arrayFromDatum(comptime Elem: type, elem_oid: pg.Oid, d: pg.Datum) ![]const Elem {
    const detoasted = try err.wrap(pg.pg_detoast_datum, .{@as([*c]pg.struct_varlena, @ptrCast(@alignCast(pg.DatumGetPointer(d))))});
    const arr: [*c]pg.ArrayType = @ptrCast(@alignCast(detoasted));
    if (arr.*.elemtype != elem_oid) {
        return err.PGError.UnexpectedArrayElementType;
    }

    const layout = ElemLayout.of(elem_oid);
    var elems: [*c]pg.Datum = null;
    var nulls: [*c]bool = null;
    var n: c_int = 0;
    try err.wrap(pg.deconstruct_array, .{ arr, elem_oid, layout.len, layout.byval, layout.alignment, &elems, &nulls, &n });

    const count: usize = @intCast(n);
    const out = try mem.PGCurrentContextAllocator.alloc(Elem, count);
    for (0..count) |i| {
        const nd: pg.NullableDatum = .{ .value = elems[i], .isnull = nulls[i] };
        out[i] = try findConv(Elem).fromNullableDatumWithOID(nd, elem_oid);
    }
    return out;
}

fn arrayToDatum(comptime Elem: type, elem_oid: pg.Oid, values: []const Elem) !pg.Datum {
    const layout = ElemLayout.of(elem_oid);

    var arena = std.heap.ArenaAllocator.init(mem.PGCurrentContextAllocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const elems = try allocator.alloc(pg.Datum, values.len);
    const nulls = try allocator.alloc(bool, values.len);
    for (values, 0..) |v, i| {
        const nd = try findConv(Elem).toNullableDatumWithOID(v, elem_oid);
        elems[i] = nd.value;
        nulls[i] = nd.isnull;
    }

    // construct_md_array copies the element data into the new array, so the
    // scratch buffers (and any text datums built for them) can go right after.
    var dims = [1]c_int{@intCast(values.len)};
    var lbs = [1]c_int{1};
    const arr = try err.wrap(pg.construct_md_array, .{
        elems.ptr,
        nulls.ptr,
        @as(c_int, if (values.len == 0) 0 else 1),
        &dims,
        &lbs,
        elem_oid,
        @as(c_int, layout.len),
        layout.byval,
        layout.alignment,
    });
    return pg.PointerGetDatum(arr);
}

// TODO: conversion decorator for jsonb decoding/encoding types

fn idDatum(d: pg.Datum) pg.Datum {
    return d;
}

fn toVoid(d: void) pg.Datum {
    _ = d;
    return 0;
}

/// Scalar Datum conversions, written in Zig rather than using the translated
/// `DatumGetInt32`/`Int32GetDatum`/... helpers: those are macros on PG15 and
/// static inline functions on PG16+, and translate-c mistranslates some of
/// them (`DatumGetBool` on PG15 becomes a call to the type `bool`;
/// `DatumGetInt64` on macOS drops its cast). These follow postgres.h:
/// integers are sign/zero-extended into the Datum like a C cast and truncated
/// on the way out, `float4` is stored as its `int32` bit pattern (through
/// Int32GetDatum, so sign-extended) and `float8` as its `int64` bit pattern.
const scalar = struct {
    comptime {
        // PG18 requires a 64-bit Datum; older versions use uintptr_t, which is
        // 64-bit on every platform pgzx supports.
        if (@sizeOf(pg.Datum) != 8) @compileError("pgzx.datum: expected a 64-bit Datum");
    }

    fn get(comptime T: type) fn (pg.Datum) T {
        return struct {
            fn f(d: pg.Datum) T {
                const U = @Int(.unsigned, @bitSizeOf(T));
                return @bitCast(@as(U, @truncate(d)));
            }
        }.f;
    }

    fn put(comptime T: type) fn (T) pg.Datum {
        return struct {
            fn f(v: T) pg.Datum {
                return switch (@typeInfo(T).int.signedness) {
                    .signed => @bitCast(@as(i64, v)),
                    .unsigned => v,
                };
            }
        }.f;
    }

    fn getBool(d: pg.Datum) bool {
        return d != 0;
    }

    fn putBool(v: bool) pg.Datum {
        return @intFromBool(v);
    }

    fn getFloat4(d: pg.Datum) f32 {
        return @bitCast(@as(u32, @truncate(d)));
    }

    fn putFloat4(v: f32) pg.Datum {
        return put(i32)(@bitCast(v));
    }

    fn getFloat8(d: pg.Datum) f64 {
        return @bitCast(@as(u64, d));
    }

    fn putFloat8(v: f64) pg.Datum {
        return @as(u64, @bitCast(v));
    }
};

pub fn getDatumStringLikeZ(datum: pg.Datum, oid: pg.Oid) ![:0]const u8 {
    return if (useStringPointer(oid)) getDatumCStringZ(datum) else getDatumTextSliceZ(datum);
}

pub inline fn getDatumCStringZ(datum: pg.Datum) ![:0]const u8 {
    return std.mem.span(pg.DatumGetCString(datum));
}

/// Convert a datum to a TEXT slice. This function detoast the datum if necessary.
/// All allocations will be performed in the Current Memory Context.
///
pub fn getDatumTextSliceZ(datum: pg.Datum) ![:0]const u8 {
    // `DatumGetTextPP` already detoasts, so no further `pg_detoast_datum_packed`.
    const ptr = pg.DatumGetTextPP(datum);

    const len = varatt.VARSIZE_ANY_EXHDR(ptr);
    var buffer = try mem.PGCurrentContextAllocator.alloc(u8, len + 1);
    std.mem.copyForwards(u8, buffer, varatt.VARDATA_ANY(ptr)[0..len]);
    buffer[len] = 0;
    return buffer[0..len :0];
}

pub fn sliceToDatumStringLikeZ(slice: [:0]const u8, oid: pg.Oid) !pg.Datum {
    return if (useStringPointer(oid)) sliceToDatumCStringZ(slice) else sliceToDatumTextZ(slice);
}

pub fn sliceToDatumStringLike(slice: []const u8, oid: pg.Oid) !pg.Datum {
    return if (useStringPointer(oid)) sliceToDatumCString(slice) else sliceToDatumText(slice);
}

pub inline fn sliceToDatumCString(slice: []const u8) !pg.Datum {
    const alloc = mem.PGCurrentContextAllocator;
    const slice_z = try alloc.dupeSentinel(u8, slice, 0);
    return pg.CStringGetDatum(slice_z.ptr);
}

pub inline fn sliceToDatumCStringZ(slice: [:0]const u8) !pg.Datum {
    return pg.CStringGetDatum(slice.ptr);
}

pub inline fn sliceToDatumText(slice: []const u8) !pg.Datum {
    const text = pg.cstring_to_text_with_len(slice.ptr, @intCast(slice.len));
    return pg.PointerGetDatum(text);
}

pub inline fn sliceToDatumTextZ(slice: [:0]const u8) !pg.Datum {
    return sliceToDatumText(slice);
}

pub inline fn useStringPointer(oid: pg.Oid) bool {
    return switch (oid) {
        pg.CHAROID, pg.NAMEOID, pg.CSTRINGOID => true,
        else => false,
    };
}

pub const TestSuite_Datum = struct {
    pub fn testInt32RoundTrip() !void {
        const value: i32 = 12345;
        const d = try toNullableDatum(value);
        try std.testing.expectEqual(false, d.isnull);
        try std.testing.expectEqual(value, try fromNullableDatum(i32, d));
    }

    pub fn testBoolRoundTrip() !void {
        const value = true;
        const d = try toNullableDatum(value);
        try std.testing.expectEqual(false, d.isnull);
        try std.testing.expectEqual(value, try fromNullableDatum(bool, d));
    }

    pub fn testTextRoundTrip() !void {
        const value: [:0]const u8 = "hello world";
        const d = try toNullableDatum(value);
        try std.testing.expectEqual(false, d.isnull);
        try std.testing.expectEqualStrings("hello world", try fromNullableDatum([:0]const u8, d));
    }

    pub fn testArrayRoundTrip() !void {
        const values = [_]i32{ 1, 2, 3 };
        const d = try toNullableDatum(@as([]const i32, &values));
        try std.testing.expectEqual(false, d.isnull);
        try std.testing.expectEqualSlices(i32, &values, try fromNullableDatum([]const i32, d));
    }

    pub fn testArrayWithNulls() !void {
        const values = [_]?i64{ 7, null, 9 };
        const d = try toNullableDatum(@as([]const ?i64, &values));
        const decoded = try fromNullableDatum([]const ?i64, d);
        try std.testing.expectEqual(@as(usize, 3), decoded.len);
        try std.testing.expectEqual(@as(?i64, 7), decoded[0]);
        try std.testing.expectEqual(@as(?i64, null), decoded[1]);
        try std.testing.expectEqual(@as(?i64, 9), decoded[2]);

        try std.testing.expectError(err.PGError.UnexpectedNullValue, fromNullableDatum([]const i64, d));
    }

    pub fn testTextArrayRoundTrip() !void {
        const values = [_][]const u8{ "a", "bc", "" };
        const d = try toNullableDatum(@as([]const []const u8, &values));
        const decoded = try fromNullableDatum([]const []const u8, d);
        try std.testing.expectEqual(@as(usize, 3), decoded.len);
        for (values, decoded) |want, got| try std.testing.expectEqualStrings(want, got);
    }

    pub fn testEmptyArray() !void {
        const d = try toNullableDatum(@as([]const f64, &.{}));
        try std.testing.expectEqual(@as(usize, 0), (try fromNullableDatum([]const f64, d)).len);
    }

    pub fn testArrayElementTypeMismatch() !void {
        const d = try toNullableDatum(@as([]const i32, &.{1}));
        try std.testing.expectError(err.PGError.UnexpectedArrayElementType, fromNullableDatum([]const i64, d));
    }

    pub fn testArrayViewZeroCopy() !void {
        const values = [_]f64{ 1.5, -2.0, 3.25 };
        const d = try toNullableDatum(@as([]const f64, &values));
        const view = try fromNullableDatum(ArrayView(f64), d);
        try std.testing.expectEqualSlices(f64, &values, view.items);

        // items points into the array value itself, not into a copy.
        const array_ptr = pg.DatumGetPointer(d.value);
        const start = @intFromPtr(array_ptr);
        const end = start + varatt.VARSIZE(array_ptr);
        const at = @intFromPtr(view.items.ptr);
        try std.testing.expect(at > start and at + view.items.len * @sizeOf(f64) <= end);
    }

    pub fn testArrayViewTypes() !void {
        const ints = [_]i16{ -1, 0, 7 };
        const iv = try fromNullableDatum(ArrayView(i16), try toNullableDatum(@as([]const i16, &ints)));
        try std.testing.expectEqualSlices(i16, &ints, iv.items);

        const bools = [_]bool{ true, false, true };
        const bv = try fromNullableDatum(ArrayView(bool), try toNullableDatum(@as([]const bool, &bools)));
        try std.testing.expectEqualSlices(bool, &bools, bv.items);

        const empty = try fromNullableDatum(ArrayView(i32), try toNullableDatum(@as([]const i32, &.{})));
        try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    }

    pub fn testArrayViewRejectsNulls() !void {
        const d = try toNullableDatum(@as([]const ?i32, &.{ 1, null }));
        try std.testing.expectError(err.PGError.UnexpectedNullValue, fromNullableDatum(ArrayView(i32), d));
    }

    pub fn testArrayViewElementTypeMismatch() !void {
        const d = try toNullableDatum(@as([]const i32, &.{1}));
        try std.testing.expectError(err.PGError.UnexpectedArrayElementType, fromNullableDatum(ArrayView(i64), d));
    }

    pub fn testArrayViewRoundTrip() !void {
        const values = [_]i32{ 4, 5, 6 };
        const view: ArrayView(i32) = .{ .items = &values };
        const d = try toNullableDatum(view);
        try std.testing.expectEqualSlices(i32, &values, try fromNullableDatum([]const i32, d));
        try std.testing.expectEqualStrings("real[]", sqlType(ArrayView(f32)));
    }

    pub fn testArraySqlType() !void {
        try std.testing.expectEqualStrings("integer[]", sqlType([]const i32));
        try std.testing.expectEqualStrings("text[]", sqlType([]const ?[]const u8));
    }

    pub fn testScalarRoundTrips() !void {
        inline for (.{ @as(i8, -128), @as(i16, -32768), @as(i32, -7), @as(i64, std.math.minInt(i64)), @as(u8, 255), @as(u16, 65535), @as(u32, 4294967295), @as(u64, std.math.maxInt(u64)), @as(f32, -1.5), @as(f64, -2.25), true, false }) |v| {
            const T = @TypeOf(v);
            try std.testing.expectEqual(v, try fromNullableDatum(T, try toNullableDatum(v)));
        }
    }

    /// Decodes Datums produced by the server and feeds Datums encoded here
    /// back to it, so the Zig conversions are checked against PostgreSQL's own
    /// representation rather than only against themselves.
    pub fn testScalarsMatchServer() !void {
        const spi = @import("spi.zig");
        try spi.connect();
        defer spi.finish();

        {
            var rows = try spi.query("SELECT (-5)::int2, (-7)::int4, (-9)::int8, (-1.5)::float4, (-2.25)::float8, true, false", .{ .read_only = true });
            defer rows.deinit();
            try std.testing.expect(rows.next());
            var raw: [7]pg.Datum = undefined;
            try rows.scan(.{ &raw[0], &raw[1], &raw[2], &raw[3], &raw[4], &raw[5], &raw[6] });
            try std.testing.expectEqual(@as(i16, -5), try fromDatum(i16, raw[0], false));
            try std.testing.expectEqual(@as(i32, -7), try fromDatum(i32, raw[1], false));
            try std.testing.expectEqual(@as(i64, -9), try fromDatum(i64, raw[2], false));
            try std.testing.expectEqual(@as(f32, -1.5), try fromDatum(f32, raw[3], false));
            try std.testing.expectEqual(@as(f64, -2.25), try fromDatum(f64, raw[4], false));
            try std.testing.expectEqual(true, try fromDatum(bool, raw[5], false));
            try std.testing.expectEqual(false, try fromDatum(bool, raw[6], false));
        }

        var rows = try spi.queryTyped(bool,
            \\SELECT $1 = (-5)::int2 AND $2 = (-7)::int4 AND $3 = (-9)::int8
            \\   AND $4 = (-1.5)::float4 AND $5 = (-2.25)::float8 AND $6 AND NOT $7
        , .{
            .read_only = true,
            .args = .{
                .types = &.{ pg.INT2OID, pg.INT4OID, pg.INT8OID, pg.FLOAT4OID, pg.FLOAT8OID, pg.BOOLOID, pg.BOOLOID },
                .values = &.{
                    try toNullableDatum(@as(i16, -5)),
                    try toNullableDatum(@as(i32, -7)),
                    try toNullableDatum(@as(i64, -9)),
                    try toNullableDatum(@as(f32, -1.5)),
                    try toNullableDatum(@as(f64, -2.25)),
                    try toNullableDatum(true),
                    try toNullableDatum(false),
                },
            },
        });
        defer rows.deinit();
        try std.testing.expectEqual(true, (try rows.next()).?);
    }

    pub fn testOptionalNull() !void {
        const d = try toNullableDatum(@as(?i32, null));
        try std.testing.expectEqual(true, d.isnull);
    }

    pub fn testTidRoundTrip() !void {
        var original: pg.ItemPointerData = .{};
        itemptr.itemPointerSetAll(&original, 42, 7);

        const d = try toNullableDatum(original);
        try std.testing.expectEqual(false, d.isnull);

        const decoded = try fromNullableDatum(pg.ItemPointerData, d);
        try std.testing.expectEqual(@as(pg.BlockNumber, 42), itemptr.itemPointerGetBlockNumberNoCheck(decoded));
        try std.testing.expectEqual(@as(pg.OffsetNumber, 7), itemptr.itemPointerGetOffsetNumberNoCheck(decoded));
    }

    pub fn testXidRoundTrip() !void {
        const x: xid.Xid = .{ .value = 0xFFFFFFF0 };
        const d = try toNullableDatum(x);
        try std.testing.expectEqual(false, d.isnull);
        try std.testing.expectEqual(x.value, (try fromNullableDatum(xid.Xid, d)).value);

        const c: xid.Cid = .{ .value = 7 };
        try std.testing.expectEqual(c.value, (try fromNullableDatum(xid.Cid, try toNullableDatum(c))).value);

        const full: xid.Xid8 = .fromParts(3, .{ .value = 99 });
        try std.testing.expectEqual(full.value, (try fromNullableDatum(xid.Xid8, try toNullableDatum(full))).value);
    }

    pub fn testXidSqlNames() !void {
        try std.testing.expectEqualStrings("xid", sqlType(xid.Xid));
        try std.testing.expectEqualStrings("cid", sqlType(xid.Cid));
        try std.testing.expectEqualStrings("xid8", sqlType(xid.Xid8));
    }

    /// Checks the Zig `xid`, `cid` and `xid8` conversions against the server.
    pub fn testXidMatchesServer() !void {
        const spi = @import("spi.zig");
        try spi.connect();
        defer spi.finish();

        // server -> Zig
        {
            var rows = try spi.queryTyped(xid.Xid, "SELECT '4000000000'::xid", .{ .read_only = true });
            defer rows.deinit();
            try std.testing.expectEqual(@as(u32, 4000000000), (try rows.next()).?.value);
        }
        {
            var rows = try spi.queryTyped(xid.Cid, "SELECT '12'::cid", .{ .read_only = true });
            defer rows.deinit();
            try std.testing.expectEqual(@as(u32, 12), (try rows.next()).?.value);
        }
        {
            var rows = try spi.queryTyped(xid.Xid8, "SELECT '4294967299'::xid8", .{ .read_only = true });
            defer rows.deinit();
            const full = (try rows.next()).?;
            try std.testing.expectEqual(@as(u32, 1), full.epoch());
            try std.testing.expectEqual(@as(u32, 3), full.xid().value);
        }

        // Zig -> server
        {
            var rows = try spi.queryTyped(bool, "SELECT $1 = '4000000000'::xid", .{
                .read_only = true,
                .args = .{
                    .types = &.{pg.XIDOID},
                    .values = &.{try toNullableDatum(xid.Xid{ .value = 4000000000 })},
                },
            });
            defer rows.deinit();
            try std.testing.expectEqual(true, (try rows.next()).?);
        }
        {
            var rows = try spi.queryTyped(bool, "SELECT $1::text = '12'", .{
                .read_only = true,
                .args = .{
                    .types = &.{pg.CIDOID},
                    .values = &.{try toNullableDatum(xid.Cid{ .value = 12 })},
                },
            });
            defer rows.deinit();
            try std.testing.expectEqual(true, (try rows.next()).?);
        }
        {
            var rows = try spi.queryTyped(bool, "SELECT $1 = '4294967299'::xid8", .{
                .read_only = true,
                .args = .{
                    .types = &.{pg.XID8OID},
                    .values = &.{try toNullableDatum(xid.Xid8.fromParts(1, .{ .value = 3 }))},
                },
            });
            defer rows.deinit();
            try std.testing.expectEqual(true, (try rows.next()).?);
        }
    }

    /// Checks the Zig `tid` conversions against the server's own representation.
    pub fn testTidMatchesServer() !void {
        const spi = @import("spi.zig");
        try spi.connect();
        defer spi.finish();

        // server -> Zig
        {
            var rows = try spi.query("SELECT '(3,42)'::tid", .{ .read_only = true });
            defer rows.deinit();
            try std.testing.expect(rows.next());
            var raw: [1]pg.Datum = undefined;
            try rows.scan(.{&raw[0]});
            const tid = try fromDatum(pg.ItemPointerData, raw[0], false);
            try std.testing.expectEqual(@as(pg.BlockNumber, 3), itemptr.itemPointerGetBlockNumberNoCheck(tid));
            try std.testing.expectEqual(@as(pg.OffsetNumber, 42), itemptr.itemPointerGetOffsetNumberNoCheck(tid));
        }

        // Zig -> server
        var tid: pg.ItemPointerData = .{};
        itemptr.itemPointerSetAll(&tid, 3, 42);
        var rows = try spi.queryTyped(bool, "SELECT $1 = '(3,42)'::tid", .{
            .read_only = true,
            .args = .{
                .types = &.{pg.TIDOID},
                .values = &.{try toNullableDatum(tid)},
            },
        });
        defer rows.deinit();
        try std.testing.expectEqual(true, (try rows.next()).?);
    }

    pub fn testUuidRoundTrip() !void {
        const v = Uuid{ .data = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } };
        const back = try fromNullableDatum(Uuid, try toNullableDatum(v));
        try std.testing.expectEqualSlices(u8, &v.data, &back.data);
    }

    pub fn testByteaRoundTrip() !void {
        const v = Bytea{ .bytes = &.{ 0, 1, 2, 255 } };
        const back = try fromNullableDatum(Bytea, try toNullableDatum(v));
        try std.testing.expectEqualSlices(u8, v.bytes, back.bytes);
    }

    pub fn testDateRoundTrip() !void {
        const back = try fromNullableDatum(Date, try toNullableDatum(Date{ .days = -3 }));
        try std.testing.expectEqual(@as(i32, -3), back.days);
    }

    pub fn testTimeRoundTrip() !void {
        const back = try fromNullableDatum(Time, try toNullableDatum(Time{ .micros = 3_600_000_000 }));
        try std.testing.expectEqual(@as(i64, 3_600_000_000), back.micros);
    }

    pub fn testTimestampRoundTrip() !void {
        const back = try fromNullableDatum(Timestamp, try toNullableDatum(Timestamp{ .micros = -1 }));
        try std.testing.expectEqual(@as(i64, -1), back.micros);
    }

    pub fn testTimestampTzRoundTrip() !void {
        const back = try fromNullableDatum(TimestampTz, try toNullableDatum(TimestampTz{ .micros = 1_000_000 }));
        try std.testing.expectEqual(@as(i64, 1_000_000), back.micros);
    }

    pub fn testIntervalRoundTrip() !void {
        const v = Interval{ .month = 1, .day = 2, .time = 3_000_000 };
        const back = try fromNullableDatum(Interval, try toNullableDatum(v));
        try std.testing.expectEqual(@as(i32, 1), back.month);
        try std.testing.expectEqual(@as(i32, 2), back.day);
        try std.testing.expectEqual(@as(i64, 3_000_000), back.time);
    }

    /// Checks the uuid/bytea/date-time conversions against the server's own
    /// representation, in both directions.
    pub fn testBuiltinTypesMatchServer() !void {
        const spi = @import("spi.zig");
        try spi.connect();
        defer spi.finish();

        // server -> Zig
        {
            var rows = try spi.query(
                "SELECT '2000-01-02'::date, '00:00:00.000001'::time, " ++
                    "'2000-01-01 00:00:00.000001'::timestamp, " ++
                    "'2000-01-01 00:00:00.000001+00'::timestamptz, " ++
                    "'1 mon 2 days 3 secs'::interval, " ++
                    "'00000000-0000-0000-0000-000000000001'::uuid, " ++
                    "'\\x010203'::bytea",
                .{ .read_only = true },
            );
            defer rows.deinit();
            try std.testing.expect(rows.next());
            var raw: [7]pg.Datum = undefined;
            try rows.scan(.{ &raw[0], &raw[1], &raw[2], &raw[3], &raw[4], &raw[5], &raw[6] });

            try std.testing.expectEqual(@as(i32, 1), (try fromDatum(Date, raw[0], false)).days);
            try std.testing.expectEqual(@as(i64, 1), (try fromDatum(Time, raw[1], false)).micros);
            try std.testing.expectEqual(@as(i64, 1), (try fromDatum(Timestamp, raw[2], false)).micros);
            try std.testing.expectEqual(@as(i64, 1), (try fromDatum(TimestampTz, raw[3], false)).micros);

            const iv = try fromDatum(Interval, raw[4], false);
            try std.testing.expectEqual(@as(i32, 1), iv.month);
            try std.testing.expectEqual(@as(i32, 2), iv.day);
            try std.testing.expectEqual(@as(i64, 3_000_000), iv.time);

            const uuid = try fromDatum(Uuid, raw[5], false);
            try std.testing.expectEqual(@as(u8, 1), uuid.data[15]);

            const bytes = try fromDatum(Bytea, raw[6], false);
            try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, bytes.bytes);
        }

        // Zig -> server
        var rows = try spi.queryTyped(
            bool,
            "SELECT $1 = '2000-01-02'::date AND $2 = '00:00:00.000001'::time " ++
                "AND $3 = '2000-01-01 00:00:00.000001'::timestamp " ++
                "AND $4 = '00000000-0000-0000-0000-000000000001'::uuid " ++
                "AND $5 = '\\x010203'::bytea AND $6 = '1 mon 2 days 3 secs'::interval",
            .{
                .read_only = true,
                .args = .{
                    .types = &.{ pg.DATEOID, pg.TIMEOID, pg.TIMESTAMPOID, pg.UUIDOID, pg.BYTEAOID, pg.INTERVALOID },
                    .values = &.{
                        try toNullableDatum(Date{ .days = 1 }),
                        try toNullableDatum(Time{ .micros = 1 }),
                        try toNullableDatum(Timestamp{ .micros = 1 }),
                        try toNullableDatum(Uuid{ .data = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } }),
                        try toNullableDatum(Bytea{ .bytes = &.{ 1, 2, 3 } }),
                        try toNullableDatum(Interval{ .month = 1, .day = 2, .time = 3_000_000 }),
                    },
                },
            },
        );
        defer rows.deinit();
        try std.testing.expectEqual(true, (try rows.next()).?);
    }
};
