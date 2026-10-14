// SQL-visible functions of the `srf` example: set-returning functions
// (`SETOF` and `TABLE`), a port of pgrx's `pgrx-examples/srf`.
//
// A set-returning function returns a `pgzx.srf.SetOf(I)` or `pgzx.srf.Table(I)`
// wrapping an iterator `I`: any struct with a `next(self: *I)` method that
// yields the next row, or null when the set is exhausted. `next` may also
// return `!?Item` to raise a Zig error as a Postgres error.
//
// Postgres calls the function once per row (the value-per-call protocol). The
// function body runs only on the first call, in a memory context that lives
// for the whole set; later calls only run `next`. So build the iterator in the
// function body and keep it self-contained.
//
// This file only defines the functions. main.zig exports them and schema.zig
// describes their SQL signatures.

const std = @import("std");
const pgzx = @import("pgzx");
const pg = pgzx.c;

const srf = pgzx.srf;

// SETOF bigint
// ============

/// A range of numbers like `generate_series`, yielded one per row.
const Series = struct {
    cur: i64,
    finish: i64,
    step: i64,

    pub fn next(self: *Series) ?i64 {
        if (self.cur > self.finish) return null;
        defer self.cur += self.step;
        return self.cur;
    }
};

pub fn srf_series(start: i64, finish: i64, step: i64) !srf.SetOf(Series) {
    if (step <= 0) return pgzx.elog.Error(@src(), "step must be positive, got {d}", .{step});
    return .{ .iter = .{ .cur = start, .finish = finish, .step = step } };
}

// TABLE(id bigint, val bigint)
// ============================

/// The same range, with an extra index column.
const SeriesRow = struct { id: i64, val: i64 };

const SeriesTable = struct {
    cur: i64,
    finish: i64,
    step: i64,
    id: i64 = 0,

    pub fn next(self: *SeriesTable) ?SeriesRow {
        if (self.cur > self.finish) return null;
        defer {
            self.cur += self.step;
            self.id += 1;
        }
        return .{ .id = self.id, .val = self.cur };
    }
};

pub fn srf_series_table(start: i64, finish: i64, step: i64) !srf.Table(SeriesTable) {
    if (step <= 0) return pgzx.elog.Error(@src(), "step must be positive, got {d}", .{step});
    return .{ .iter = .{ .cur = start, .finish = finish, .step = step } };
}

// TABLE(index integer, value double precision)
// ============================================

/// Random values. `next` runs in a short-lived per-call context, so it only
/// returns plain values (no allocation).
const RandomRow = struct { index: i32, value: f64 };

const RandomValues = struct {
    remaining: i32,
    next_index: i32 = 1,

    pub fn next(self: *RandomValues) ?RandomRow {
        if (self.next_index > self.remaining) return null;
        defer self.next_index += 1;
        return .{ .index = self.next_index, .value = pg.pg_prng_double(&pg.pg_global_prng_state) };
    }
};

pub fn srf_random_values(num_rows: i32) !srf.Table(RandomValues) {
    if (num_rows < 0) return pgzx.elog.Error(@src(), "num_rows must not be negative, got {d}", .{num_rows});
    return .{ .iter = .{ .remaining = num_rows } };
}

// TABLE(a integer, b integer) with nullable columns
// =================================================

/// A single row with nullable columns. The `?i32` fields still map to `integer`
/// in SQL; Postgres columns are nullable by default.
const PairRow = struct { a: ?i32, b: ?i32 };

const PairSet = struct {
    done: bool = false,

    pub fn next(self: *PairSet) ?PairRow {
        if (self.done) return null;
        self.done = true;
        return .{ .a = 1, .b = 2 };
    }
};

pub fn srf_result_table() srf.Table(PairSet) {
    return .{ .iter = .{} };
}

// Single-column TABLE(a integer)
// ==============================

/// A `TABLE` with a single column is also supported.
const SingleRow = struct { a: ?i32 };

const SingleSet = struct {
    done: bool = false,

    pub fn next(self: *SingleSet) ?SingleRow {
        if (self.done) return null;
        self.done = true;
        return .{ .a = 42 };
    }
};

pub fn srf_one_col() srf.Table(SingleSet) {
    return .{ .iter = .{} };
}
