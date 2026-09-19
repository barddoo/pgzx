guc
===

Demonstrates custom GUC (Grand Unified Configuration) variables with pgzx.

The extension registers four custom GUCs in `_PG_init`:

| GUC                  | Type   | Default  |
| -------------------- | ------ | -------- |
| `guc.sample_bool`    | bool   | `off`    |
| `guc.sample_int`     | int    | `42`     |
| `guc.sample_string`  | string | `hello`  |
| `guc.sample_enum`    | enum   | `medium` |

`guc.sample_int` also has a *check hook* (registered via the
`pgzx.guc.checkIntHook` trampoline) that clamps the value to `[0, 100]`.

The SQL functions `guc_bool()`, `guc_int()`, `guc_string()` and `guc_enum()`
read the current value of each GUC back into SQL.

## Try it

```sh
psql -U postgres -c 'CREATE EXTENSION guc'
psql -U postgres -c 'SELECT guc_int()'            # 42
psql -U postgres -c 'SET guc.sample_int = 500; SELECT guc_int()'  # 100 (clamped)
```

Run the tests with `zig build unit` and `zig build pg_regress`.
