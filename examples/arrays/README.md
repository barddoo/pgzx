# arrays - Postgres arrays as Zig slices

A port of pgrx's [`pgrx-examples/arrays`](https://github.com/pgcentralfoundation/pgrx/tree/develop/pgrx-examples/arrays).

Postgres arrays map to Zig slices in function signatures, both as arguments
and return values, and `zig build` derives the SQL types from them:

| Zig                  | SQL                          |
|----------------------|------------------------------|
| `[]const i32`        | `integer[]` (NULL elements rejected) |
| `[]const ?i32`       | `integer[]` (NULL elements allowed)  |
| `[]const f32`        | `real[]`                     |
| `[]const i64`        | `bigint[]`                   |
| `[]const ?[]const u8`| `text[]`                     |

```zig
pub fn sum_array(input: []const ?i32) i64 {
    var sum: i64 = 0;
    for (input) |v| sum += v orelse -1;
    return sum;
}
```

Four ways to sum a `real[]`, timed on a 1M-element array in a ReleaseFast
build (20 calls each):

| Function | Input | Per call |
|---|---|---|
| `sum_vector` | `[]const f32`: decoded element by element and copied | 2.6 ms |
| `sum_vector_view` | `pgzx.datum.ArrayView(f32)`: reads the array in place, like pgrx's `Array::as_slice` | 0.66 ms |
| `sum_vector_fastmath` | view + `@setFloatMode(.optimized)` | 0.66 ms (the loop was still scalar in this build) |
| `sum_vector_simd` | view + `@Vector` at the native width (`std.simd.suggestVectorLength`) with 4 accumulators, like pgrx's `sum_vector_simd` | 0.11 ms |

The compiler does not vectorize a plain float sum on its own, because
reordering float additions changes the result. The SIMD version keeps 4
independent vector accumulators (with just one it runs about 2x slower, since
each add waits for the previous one), which here is also more accurate: for an exact sum of
499,500,000 the sequential loop returns 499,015,260 and the SIMD version
499,500,540. `ArrayView` rejects arrays with NULLs; use `[]const ?f32` for
those.

Beyond the pgrx example, [`src/schema.zig`](src/schema.zig) shows the
function attributes of `pgzx_sql`: parameter names and `DEFAULT`s
(`sum_array`, `clamp_all`), `VARIADIC` (`sum_all`), `COST` and `COMMENT`.
`distinct_sorted` uses `pgzx.IntList`, a Postgres integer `List`.

Not ported (not yet supported by pgzx): set-returning functions
(`static_names_set`) and arrays of custom types (`return_vec_of_customtype`).

```
zig build -p "$PG_HOME"   # build and install
./ci/run.sh               # build, install and run the regression tests
```
