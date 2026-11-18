aggregate
=========

Demonstrates a user-defined aggregate with pgzx: `geomean(float8)`.

The transition state is `internal`: a Zig struct allocated in the aggregate's
memory context with `pgzx.aggregate.stateOrInit`. The final function returns
the result, or NULL when no rows were aggregated. NULL inputs are skipped.

The SQL schema lives in `src/schema.zig` under `pgzx_sql.aggregates`. Build the
extension script and run the regression tests:

```sh
zig build schema
zig build -p $PG_HOME
zig build pg_regress
```
