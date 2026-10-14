# srf - Set-Returning Functions

A port of pgrx's [`pgrx-examples/srf`](https://github.com/pgcentralfoundation/pgrx/tree/develop/pgrx-examples/srf),
showing `pgzx.srf.SetOf(I)` (`RETURNS SETOF`) and `pgzx.srf.Table(I)`
(`RETURNS TABLE (...)`) functions.

A set-returning function returns a `SetOf(I)` or `Table(I)` wrapping an
iterator `I`: any struct with a `next(self: *I)` method that yields the next
row, or `null` when the set is exhausted. `next` may also return `!?Item` to
raise a Zig error as a Postgres error.

| Function | Returns | Shows |
|---|---|---|
| `srf_series(start, finish, step DEFAULT 1)` | `SETOF bigint` | a scalar set, a `DEFAULT` parameter, an error raised from the function body |
| `srf_series_table(start, finish, step DEFAULT 1)` | `TABLE(id bigint, val bigint)` | a multi-column table |
| `srf_random_values(num_rows)` | `TABLE(index integer, value double precision)` | a `VOLATILE` table returning random values |
| `srf_result_table()` | `TABLE(a integer, b integer)` | nullable (`?i32`) columns |
| `srf_one_col()` | `TABLE(a integer)` | a single-column table |

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

pub fn srf_series(start: i64, finish: i64, step: i64) !srf.SetOf(Series) {
    if (step <= 0) return pgzx.elog.Error(@src(), "step must be positive, got {d}", .{step});
    return .{ .iter = .{ .cur = start, .finish = finish, .step = step } };
}
```

Postgres uses the value-per-call protocol: it calls the function once per row.
The function body runs only on the first call, in a memory context that lives
for the whole set; later calls only run `next`. See `src/pgzx/srf.zig` for the
full model, including `deinit` and iterators that fail.

```
zig build -p "$PG_HOME"   # build and install
./ci/run.sh               # build, install and run the regression tests
```
