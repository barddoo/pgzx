// SQL-visible functions of the `arrays` example, a port of pgrx's
// `pgrx-examples/arrays`.
//
// Postgres arrays map to Zig slices: `integer[]` is `[]const i32`, and an
// optional element type (`[]const ?i32`) accepts arrays with NULL elements.
// With a non-optional element type a NULL element is rejected with an error,
// like pgrx's `iter_deny_null`. Decoded slices and returned arrays are
// allocated in the current memory context.
//
// This file only defines the functions. main.zig exports them and schema.zig
// describes their SQL signatures.

const std = @import("std");
const pgzx = @import("pgzx");

const allocator = pgzx.mem.PGCurrentContextAllocator;

/// Squared euclidean distance of two vectors.
pub fn sq_euclid(a: []const f32, b: []const f32) !f32 {
    if (a.len != b.len) {
        return pgzx.elog.Error(@src(), "vectors differ in length: {d} vs {d}", .{ a.len, b.len });
    }
    var sum: f32 = 0;
    for (a, b) |x, y| sum += (x - y) * (x - y);
    return sum;
}

/// Sums `distances[cc]` for every code `cc` in `compressed`.
pub fn approx_distance(compressed: []const i64, distances: []const f64) !f64 {
    var sum: f64 = 0;
    for (compressed) |cc| {
        if (cc < 0 or cc >= distances.len) {
            return pgzx.elog.Error(@src(), "code {d} out of range for {d} distances", .{ cc, distances.len });
        }
        const d = distances[@intCast(cc)];
        pgzx.elog.Info(@src(), "cc={d}, d={d}", .{ cc, d });
        sum += d;
    }
    return sum;
}

/// Empty array, used as the default value of `sum_array`.
pub fn default_array() []const i32 {
    return &.{};
}

/// Sums the array, counting NULL elements as -1.
pub fn sum_array(input: []const ?i32) i64 {
    var sum: i64 = 0;
    for (input) |v| sum += v orelse -1;
    return sum;
}

/// Appends 6 to the input and sums it, counting NULL elements as 0.
pub fn sum_vec(input: []const ?i32) !i64 {
    var list = try std.ArrayList(?i32).initCapacity(allocator, input.len + 1);
    list.appendSliceAssumeCapacity(input);
    list.appendAssumeCapacity(6);

    var sum: i64 = 0;
    for (list.items) |v| sum += v orelse 0;
    return sum;
}

/// Returns a text array with a NULL element.
pub fn static_names() []const ?[]const u8 {
    return &.{ "Brandy", "Sally", null, "Anchovy" };
}

pub fn i32_array_no_nulls() []const i32 {
    return &.{ 1, 2, 3, 4, 5 };
}

pub fn i32_array_with_nulls() []const ?i32 {
    return &.{ 1, null, 2, 3, null, 4, 5 };
}

/// Drops the NULL elements.
pub fn strip_nulls(input: []const ?i32) ![]const i32 {
    var out = try std.ArrayList(i32).initCapacity(allocator, input.len);
    for (input) |v| {
        if (v) |x| out.appendAssumeCapacity(x);
    }
    return out.toOwnedSlice(allocator);
}

pub fn sum_vector(input: []const f32) f32 {
    var sum: f32 = 0;
    for (input) |v| sum += v;
    return sum;
}

/// Same as `sum_vector`, but reads the array in place through
/// `pgzx.datum.ArrayView`: no per-element conversion and no copy, like
/// pgrx's `Array::as_slice` (`sum_vector_slice`). Arrays with NULLs are
/// rejected.
pub fn sum_vector_view(input: pgzx.datum.ArrayView(f32)) f32 {
    var sum: f32 = 0;
    for (input.items) |v| sum += v;
    return sum;
}

/// `sum_vector_view` with explicit SIMD, like pgrx's `sum_vector_simd`.
///
/// The compiler does not vectorize a plain float sum on its own: float
/// addition is not associative, so reordering it changes the result. This
/// version uses the target's native vector width
/// (`std.simd.suggestVectorLength`: 4 lanes on NEON, 8 on AVX2, 16 on
/// AVX-512) and keeps several independent accumulators so consecutive adds do
/// not wait on each other. The partial sums are reduced at the end, so the
/// rounding can differ slightly from the sequential loop.
pub fn sum_vector_simd(input: pgzx.datum.ArrayView(f32)) f32 {
    const lanes = std.simd.suggestVectorLength(f32) orelse 4;
    const unroll = 4;
    const block = lanes * unroll;
    const V = @Vector(lanes, f32);
    const values = input.items;

    var acc: [unroll]V = @splat(@splat(0));
    var i: usize = 0;
    while (i + block <= values.len) : (i += block) {
        inline for (0..unroll) |u| {
            acc[u] += values[i + u * lanes ..][0..lanes].*;
        }
    }
    var total: V = @splat(0);
    inline for (acc) |a| total += a;
    var sum = @reduce(.Add, total);
    while (i < values.len) : (i += 1) sum += values[i];
    return sum;
}

/// The plain loop again, but `@setFloatMode(.optimized)` allows the compiler
/// to reassociate the adds, so it vectorizes the loop by itself.
pub fn sum_vector_fastmath(input: pgzx.datum.ArrayView(f32)) f32 {
    @setFloatMode(.optimized);
    var sum: f32 = 0;
    for (input.items) |v| sum += v;
    return sum;
}

// Beyond the pgrx example
// =======================

/// Sums all arguments; declared `VARIADIC` in schema.zig so it is called as
/// `sum_all(1, 2, 3)`.
pub fn sum_all(values: []const i32) i64 {
    var sum: i64 = 0;
    for (values) |v| sum += v;
    return sum;
}

/// Clamps every element into `[lo, hi]`. `lo` and `hi` have defaults.
pub fn clamp_all(values: []const i32, lo: i32, hi: i32) ![]const i32 {
    if (lo > hi) return pgzx.elog.Error(@src(), "lo ({d}) must not exceed hi ({d})", .{ lo, hi });
    const out = try allocator.alloc(i32, values.len);
    for (values, out) |v, *o| o.* = std.math.clamp(v, lo, hi);
    return out;
}

/// Sorted distinct elements, built with a Postgres integer `List`
/// (`pgzx.IntList`).
pub fn distinct_sorted(values: []const i32) ![]const i32 {
    var list = pgzx.IntList.init();
    defer list.deinit();
    for (values) |v| list.appendUnique(v);
    list.sort();
    return list.toSlice(allocator);
}
