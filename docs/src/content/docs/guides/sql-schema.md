---
title: SQL schema generation
---

Instead of hand-writing the versioned extension script (`<name>--<version>.sql`), you can describe your SQL objects in a comptime declaration and let `zig build` render it. By convention the declaration lives in `src/schema.zig` and is named `pgzx_sql`:

```zig
const functions = @import("functions.zig");

pub const pgzx_sql = .{
    .functions = .{
        .{ .name = "char_count_zig", .func = functions.char_count_zig },
    },
};
```

Then enable the `schema` step in `build.zig`:

```zig
_ = proj.addSteps(.{
    .schema = .{},
    // ...
});
```

`zig build` (or `zig build sql`) compiles a small generator, renders the SQL, and installs it next to the `.control` file so `CREATE EXTENSION` picks it up. Argument types are derived from the Zig signatures through the `pgzx.datum` converters: `i32` becomes `integer`, `[]const u8` becomes `text`, and optional arguments do not change the SQL type. A `pg.FunctionCallInfo` parameter is treated as the fmgr context and is not emitted as an SQL argument.

Per-function options:

| Option       | Meaning                                                                   |
| ------------ | ------------------------------------------------------------------------- |
| `name`       | SQL function name (required).                                             |
| `func`       | The Zig function (required).                                              |
| `volatility` | `pgzx.ddl.Volatility`: `.@"volatile"` (default), `.stable`, `.immutable`. |
| `strict`     | Emit `STRICT` (default `false`).                                          |
| `parallel`   | `pgzx.ddl.Parallel`: `.unsafe`, `.restricted`, `.safe`.                   |
| `args`       | Override argument SQL types, e.g. `&.{"text", "integer"}`.                |
| `returns`    | Override the return SQL type.                                             |
| `comment`    | Emit a `COMMENT ON FUNCTION`.                                             |

Use `args`/`returns` for signatures with no direct SQL mapping, such as raw `pg.Datum` arguments. Keep `PG_FUNCTION_V1`/`PG_EXPORT` in `main.zig`, not in the schema module: the generator is linked as a standalone executable and cannot resolve Postgres server symbols. Objects that are not `CREATE FUNCTION` (types, operators, operator classes, casts) go in a source-level `catalog.sql`, which the generator appends after the functions. See `examples/rational` and `examples/sqlfns` for the complete pattern.
