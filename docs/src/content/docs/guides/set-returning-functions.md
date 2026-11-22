---
title: Set-returning functions
---

`SETOF` and `TABLE` functions return a `pgzx.srf.SetOf(I)` or `pgzx.srf.Table(I)` wrapping an iterator `I`: any struct with a `next(self: *I)` method that yields the next row, or `null` when the set is exhausted. `next` may also return `!?Item` to raise a Zig error as a Postgres error.

```zig
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

pub fn srf_series(start: i64, finish: i64, step: i64) pgzx.srf.SetOf(Series) {
    return .{ .iter = .{ .cur = start, .finish = finish, .step = step } };
}
```

For `Table(I)` the item is a struct with one field per column; the field names and the `pgzx.datum` converters (see [SQL schema generation](/guides/sql-schema/)) produce the `RETURNS TABLE (...)` clause in generated DDL. Use `SetOf` for a single unnamed column.

Postgres uses the value-per-call protocol: it calls the function once per row. The function body runs only on the first call, in a memory context that lives for the whole set, and the iterator is moved there; later calls run only `next`. Allocate everything the iterator needs while building it with `mem.PGCurrentContextAllocator`: `next` runs in a short-lived per-call context, so memory it allocates is only good for the row it returns. An iterator type may also define `fn deinit(self: *I) void`, which runs when the set ends or the query stops early (a `LIMIT`, an error, a cancelled query); it must not allocate or raise errors.

See `examples/srf` for a complete set of fixtures, including nullable columns and iterators that fail.
