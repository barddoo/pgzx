//! A `rational` base type.
//!
//! The interesting part of this example is not the arithmetic: it is the
//! catalog wiring. A base type is made of catalog entries that point at
//! ordinary C functions (`pg_type`, `pg_operator`, `pg_opclass`, ...). Once
//! those exist, the whole server starts treating `rational` as a first class
//! type: it can be indexed with btree, hashed, grouped, sorted and cast.
//!
//! Storage: a fixed size, pass-by-reference value of 16 bytes:
//!
//!     typedef struct { int64 num; int64 den; } Rational;
//!
//! `den` is always positive and `num`/`den` are kept coprime, so every value
//! has a unique representation. That is what makes `=`/hashing/index ordering
//! consistent with the text output.
//!
//! This module holds the implementations and is kept free of registration and
//! exports so the SQL schema generator (schema.zig) can introspect the
//! signatures without linking the Postgres server. See main.zig for
//! `PG_FUNCTION_V1` and the in-server test registration.

const std = @import("std");
const pgzx = @import("pgzx");
const pg = pgzx.c;

// ---------------------------------------------------------------------------
// The value type and its pure Zig logic
// ---------------------------------------------------------------------------

/// The on-disk / in-memory representation. Must match the catalog
/// (`INTERNALLENGTH = 16`, `ALIGNMENT = double`).
pub const Rational = extern struct {
    num: i64,
    den: i64,

    fn asFloat(self: Rational) f64 {
        return @as(f64, @floatFromInt(self.num)) / @as(f64, @floatFromInt(self.den));
    }
};

pub const RationalError = error{
    InvalidInput,
    DivisionByZero,
    Overflow,
};

const max_i64: i128 = std.math.maxInt(i64);
const min_i64: i128 = std.math.minInt(i64);

/// Greatest common divisor, Euclidean.
///
/// Note: a binary GCD (`@ctz` + subtraction) was benchmarked and is *slower*
/// here. The operands are small (~20 bits), so the Euclidean loop runs in a
/// couple of divisions, while the branchy `u128` variant costs more than the
/// division it saves. Re-benchmark before changing this.
fn gcd(a: i128, b: i128) i128 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = @rem(x, y);
        x = y;
        y = t;
    }
    return if (x < 0) -x else x;
}

/// Reduce `num/den` to lowest terms with a positive denominator.
fn normalize(num: i128, den: i128) RationalError!Rational {
    if (den == 0) return error.DivisionByZero;

    var n = num;
    var d = den;
    if (d < 0) {
        n = -n;
        d = -d;
    }

    const g = gcd(if (n < 0) -n else n, d);
    n = @divTrunc(n, g);
    d = @divTrunc(d, g);

    if (n < min_i64 or n > max_i64 or d > max_i64) return error.Overflow;
    return .{ .num = @intCast(n), .den = @intCast(d) };
}

/// Parse `"N"`, `"N/D"`, with optional surrounding whitespace.
fn parse(input: []const u8) RationalError!Rational {
    const s = std.mem.trim(u8, input, " \t\r\n");
    if (s.len == 0) return error.InvalidInput;

    if (std.mem.indexOfScalar(u8, s, '/')) |idx| {
        const num_s = std.mem.trim(u8, s[0..idx], " \t");
        const den_s = std.mem.trim(u8, s[idx + 1 ..], " \t");
        if (num_s.len == 0 or den_s.len == 0) return error.InvalidInput;
        const num = std.fmt.parseInt(i64, num_s, 10) catch return error.InvalidInput;
        const den = std.fmt.parseInt(i64, den_s, 10) catch return error.InvalidInput;
        return normalize(num, den);
    }

    const num = std.fmt.parseInt(i64, s, 10) catch return error.InvalidInput;
    return normalize(num, 1);
}

fn add(a: Rational, b: Rational) RationalError!Rational {
    return normalize(
        @as(i128, a.num) * b.den + @as(i128, b.num) * a.den,
        @as(i128, a.den) * b.den,
    );
}

fn sub(a: Rational, b: Rational) RationalError!Rational {
    return normalize(
        @as(i128, a.num) * b.den - @as(i128, b.num) * a.den,
        @as(i128, a.den) * b.den,
    );
}

fn mul(a: Rational, b: Rational) RationalError!Rational {
    return normalize(
        @as(i128, a.num) * b.num,
        @as(i128, a.den) * b.den,
    );
}

fn div(a: Rational, b: Rational) RationalError!Rational {
    if (b.num == 0) return error.DivisionByZero;
    return normalize(
        @as(i128, a.num) * b.den,
        @as(i128, a.den) * b.num,
    );
}

/// Total order: cross multiply to avoid floating point.
fn cmp(a: Rational, b: Rational) i32 {
    const left = @as(i128, a.num) * b.den;
    const right = @as(i128, b.num) * a.den;
    if (left < right) return -1;
    if (left > right) return 1;
    return 0;
}

/// FNV-1a over the 16 bytes of the canonical representation. Equal values
/// have identical bytes, so equal values hash equally.
fn hash(r: Rational) u32 {
    var h: u64 = 0xcbf29ce484222325;
    const bytes = std.mem.asBytes(&r);
    for (bytes) |b| {
        h = (h ^ b) *% 0x100000001b3;
    }
    return @truncate(h);
}

fn format(allocator: std.mem.Allocator, r: Rational) ![:0]u8 {
    if (r.den == 1) {
        return std.fmt.allocPrintSentinel(allocator, "{d}", .{r.num}, 0);
    }
    return std.fmt.allocPrintSentinel(allocator, "{d}/{d}", .{ r.num, r.den }, 0);
}

// ---------------------------------------------------------------------------
// Datum <-> Rational helpers
//
// A fixed-length, pass-by-reference type stores a pointer to the value in the
// Datum, so the conversion is just a pointer round trip.
// ---------------------------------------------------------------------------

inline fn fromDatum(d: pg.Datum) Rational {
    const p: *const Rational = @ptrFromInt(d);
    return p.*;
}

fn makeDatum(r: Rational) !pg.Datum {
    const p = try pgzx.mem.PGCurrentContextAllocator.create(Rational);
    p.* = r;
    return pg.PointerGetDatum(p);
}

const PGErrorStack = pgzx.err.PGErrorStack;

fn inputError(input: []const u8, e: RationalError) noreturn {
    switch (e) {
        error.DivisionByZero => pgzx.elog.ErrorThrow(
            @src(),
            "division by zero in input syntax for type rational: \"{s}\"",
            .{input},
        ),
        else => pgzx.elog.ErrorThrow(
            @src(),
            "invalid input syntax for type rational: \"{s}\"",
            .{input},
        ),
    }
    unreachable;
}

fn arithError(e: RationalError) error{PGErrorStack} {
    return switch (e) {
        error.DivisionByZero => pgzx.elog.Error(@src(), "division by zero", .{}),
        error.Overflow => pgzx.elog.Error(@src(), "rational value out of range", .{}),
        error.InvalidInput => pgzx.elog.Error(@src(), "invalid rational value", .{}),
    };
}

// ---------------------------------------------------------------------------
// Type I/O functions
// ---------------------------------------------------------------------------

pub fn rational_in(arg: pg.Datum) !pg.Datum {
    const cstr: [*:0]const u8 = @ptrFromInt(arg);
    const s = std.mem.span(cstr);
    const r = parse(s) catch |e| inputError(s, e);
    return makeDatum(r);
}

pub fn rational_out(arg: pg.Datum) !pg.Datum {
    const text = try format(pgzx.mem.PGCurrentContextAllocator, fromDatum(arg));
    return pg.CStringGetDatum(text.ptr);
}

// ---------------------------------------------------------------------------
// SQL callable functions
// ---------------------------------------------------------------------------

pub fn rational_from_ints(num: i64, den: i64) !pg.Datum {
    return makeDatum(normalize(num, den) catch |e| return arithError(e));
}

pub fn rational_add(a: pg.Datum, b: pg.Datum) !pg.Datum {
    return makeDatum(add(fromDatum(a), fromDatum(b)) catch |e| return arithError(e));
}

pub fn rational_sub(a: pg.Datum, b: pg.Datum) !pg.Datum {
    return makeDatum(sub(fromDatum(a), fromDatum(b)) catch |e| return arithError(e));
}

pub fn rational_mul(a: pg.Datum, b: pg.Datum) !pg.Datum {
    return makeDatum(mul(fromDatum(a), fromDatum(b)) catch |e| return arithError(e));
}

pub fn rational_div(a: pg.Datum, b: pg.Datum) !pg.Datum {
    return makeDatum(div(fromDatum(a), fromDatum(b)) catch |e| return arithError(e));
}

pub fn rational_neg(a: pg.Datum) !pg.Datum {
    const x = fromDatum(a);
    return makeDatum(.{ .num = -x.num, .den = x.den });
}

pub fn rational_abs(a: pg.Datum) !pg.Datum {
    const x = fromDatum(a);
    return makeDatum(.{ .num = if (x.num < 0) -x.num else x.num, .den = x.den });
}

pub fn rational_eq(a: pg.Datum, b: pg.Datum) !bool {
    return cmp(fromDatum(a), fromDatum(b)) == 0;
}

pub fn rational_ne(a: pg.Datum, b: pg.Datum) !bool {
    return cmp(fromDatum(a), fromDatum(b)) != 0;
}

pub fn rational_lt(a: pg.Datum, b: pg.Datum) !bool {
    return cmp(fromDatum(a), fromDatum(b)) < 0;
}

pub fn rational_le(a: pg.Datum, b: pg.Datum) !bool {
    return cmp(fromDatum(a), fromDatum(b)) <= 0;
}

pub fn rational_gt(a: pg.Datum, b: pg.Datum) !bool {
    return cmp(fromDatum(a), fromDatum(b)) > 0;
}

pub fn rational_ge(a: pg.Datum, b: pg.Datum) !bool {
    return cmp(fromDatum(a), fromDatum(b)) >= 0;
}

pub fn rational_cmp(a: pg.Datum, b: pg.Datum) !i32 {
    return cmp(fromDatum(a), fromDatum(b));
}

pub fn rational_hash(a: pg.Datum) !i32 {
    return @bitCast(hash(fromDatum(a)));
}

pub fn rational_to_float8(a: pg.Datum) !f64 {
    return fromDatum(a).asFloat();
}

// ---------------------------------------------------------------------------
// Tests
//
// These never touch Postgres: they exercise the pure value logic. That also
// makes them useful as documentation of the normalization rules.
// ---------------------------------------------------------------------------

pub const Tests = struct {
    pub fn testNormalize() !void {
        try std.testing.expectEqual(Rational{ .num = 3, .den = 4 }, try normalize(6, 8));
        try std.testing.expectEqual(Rational{ .num = 3, .den = 4 }, try normalize(-3, -4));
        try std.testing.expectEqual(Rational{ .num = -3, .den = 4 }, try normalize(3, -4));
        try std.testing.expectEqual(Rational{ .num = 5, .den = 1 }, try normalize(5, 1));
        try std.testing.expectEqual(Rational{ .num = 0, .den = 1 }, try normalize(0, 7));
        try std.testing.expectError(error.DivisionByZero, normalize(1, 0));
    }

    pub fn testParse() !void {
        try std.testing.expectEqual(Rational{ .num = 3, .den = 4 }, try parse(" 6/8 "));
        try std.testing.expectEqual(Rational{ .num = 7, .den = 1 }, try parse("7"));
        try std.testing.expectEqual(Rational{ .num = -1, .den = 2 }, try parse("-2/4"));
        try std.testing.expectError(error.InvalidInput, parse("abc"));
        try std.testing.expectError(error.InvalidInput, parse("1/2/3"));
        try std.testing.expectError(error.InvalidInput, parse(""));
    }

    pub fn testFormat() !void {
        const allocator = pgzx.mem.PGCurrentContextAllocator;
        const a = try format(allocator, .{ .num = 3, .den = 4 });
        defer allocator.free(a);
        try std.testing.expectEqualStrings("3/4", a);

        const b = try format(allocator, .{ .num = 5, .den = 1 });
        defer allocator.free(b);
        try std.testing.expectEqualStrings("5", b);
    }

    pub fn testArithmetic() !void {
        const half = Rational{ .num = 1, .den = 2 };
        const third = Rational{ .num = 1, .den = 3 };

        try std.testing.expectEqual(Rational{ .num = 5, .den = 6 }, try add(half, third));
        try std.testing.expectEqual(Rational{ .num = 1, .den = 6 }, try sub(half, third));
        try std.testing.expectEqual(Rational{ .num = 1, .den = 6 }, try mul(half, third));
        try std.testing.expectEqual(Rational{ .num = 3, .den = 2 }, try div(half, third));
        try std.testing.expectError(error.DivisionByZero, div(half, .{ .num = 0, .den = 1 }));
    }

    pub fn testOrdering() !void {
        try std.testing.expectEqual(@as(i32, 0), cmp(.{ .num = 3, .den = 4 }, .{ .num = 6, .den = 8 }));
        try std.testing.expectEqual(@as(i32, -1), cmp(.{ .num = 1, .den = 2 }, .{ .num = 2, .den = 3 }));
        try std.testing.expectEqual(@as(i32, 1), cmp(.{ .num = 3, .den = 4 }, .{ .num = 2, .den = 3 }));
    }

    pub fn testHashEqualValues() !void {
        // Hashing is over the canonical bytes, so normalize first.
        try std.testing.expectEqual(
            hash(try normalize(3, 4)),
            hash(try normalize(6, 8)),
        );
    }

    pub fn testAsFloat() !void {
        try std.testing.expectApproxEqAbs(@as(f64, 0.125), (Rational{ .num = 1, .den = 8 }).asFloat(), 1e-12);
    }
};
