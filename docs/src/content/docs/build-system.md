---
title: Build system
---

How an extension's `build.zig` is wired: the dependency mechanism, the
three-file source layout, the SQL schema declaration, the available steps, and
how PostgreSQL loads the result.

## 1. The dependency mechanism

An extension is a normal Zig package whose `build.zig.zon` depends on pgzx. The
form `pgzx new` writes is a release tarball URL plus the package hash, which
pins the dependency without requiring a checkout:

```zig
// build.zig.zon
.dependencies = .{
    .pgzx = .{
        .url = "https://github.com/barddoo/pgzx/archive/refs/tags/vX.Y.Z.tar.gz",
        .hash = "pgzx-0.1.0-...",
    },
},
```

While developing pgzx itself, or any extension that lives next to a checkout,
use a path instead. `../pgzx` for a sibling checkout, and `./../..` for the
packages under `examples/` in this repository, which are two levels below the
checkout root:

```zig
// build.zig.zon
.dependencies = .{
    .pgzx = .{ .path = "../pgzx" },
},
```

`zig fetch --save=pgzx <url>` fills in the URL and hash for you, and `pgzx new`
does it automatically, pinning the release the command came from. Pass
`--pgzx-ref <tag>` to pin a different release, or `--no-fetch` when there is no
network access.

`build.zig` imports the **dependency's build script**, not the runtime library:

```zig
const std = @import("std");
const PGBuild = @import("pgzx").Build;

pub fn build(b: *std.Build) void {
    const proj = PGBuild.Project.init(b, .{
        .name = "my_extension",
        .version = .{ .major = 0, .minor = 1 },
        .root_dir = "src/",
        .root_source_file = "src/main.zig",
    });

    _ = proj.addSteps(.{
        .schema = .{},
        .pg_regress = .{
            .db_user = "postgres",
            .db_port = 5432,
            .scripts = &[_][]const u8{"my_extension_test"},
        },
        .unit = .{
            .db_user = "postgres",
            .db_port = 5432,
        },
    });
}
```

`@import("pgzx")` in a build script resolves to pgzx's root `build.zig`, which
re-exports the helper namespace:

```zig
// pgzx/build.zig
pub const Build = @import("src/pgzx/build.zig");
```

At runtime, extension code uses a *different* import with the same name,
`@import("pgzx")`, which resolves to the library entry point `src/pgzx.zig`.
The two live in separate build contexts and never conflict.

`Project.init` stores your name, version, `root_dir`, root source file, and
extension directory. It defaults `root_source_file` to `<root_dir>/<name>.zig`
and `extension_dir` (the *source* directory holding `.control`/`.sql` files) to
`./extension/`. It also creates two options modules that gate the in-server test
entry point: `build_options.testfn = false` for the production library and
`build_options.testfn = true` for the dedicated unit-test library.

## 2. Recommended source layout: the three-file split

Zig cannot introspect a function's parameter *names*, and it has no attribute
macros, so pgzx uses an explicit comptime declaration for SQL metadata. That
declaration must be reachable by a build-time generator, and the generator
cannot link against the Postgres server. As a result, the recommended layout is:

```
src/
  functions.zig   pure function definitions; no exports, no registration
  schema.zig      the pgzx_sql declaration; imports functions.zig
  main.zig        PG_MODULE_MAGIC, PG_FUNCTION_V1, PG_EXPORT, raw C exports
```

Why the split matters (details in [Part II, §7](/build-system/internals/#7-the-linking-constraint-why-the-three-file-split-exists)): `PG_FUNCTION_V1` and `@export`
force the compiler to emit a function's body, which references Postgres backend
symbols. The SQL generator is linked as a standalone executable and has no way
to resolve those symbols. By keeping `schema.zig` (and `functions.zig`) free of
registration, the generator can import the signatures as *compile-time metadata
only*; the optimized generator build discards the bodies.

- `functions.zig` holds the actual SQL-visible functions. A plain `fn` here is
  enough; it does not need to be `export`.
- `schema.zig` names the SQL objects and points at the functions.
- `main.zig` is what PostgreSQL loads. It declares the module magic, registers
  each function with the fmgr wrapper, and re-exports raw C-convention
  functions. This file is never imported by the generator.

If your extension has no SQL functions (for example a pure background-worker
extension), you do not need `schema.zig` or the `.schema` build option at all.

## 3. Describing the schema

`src/schema.zig` exports a comptime value, conventionally named `pgzx_sql`:

```zig
const functions = @import("functions.zig");

pub const pgzx_sql = .{
    // Raw SQL emitted before the generated statements. Use it for anything the
    // generator does not model yet, or that must exist first (shell types,
    // schemas, ...).
    .sql = "CREATE SCHEMA IF NOT EXISTS my_extension;",

    .functions = .{
        .{ .name = "char_count_zig", .func = functions.char_count_zig },
        .{
            .name = "char_count_ci",
            .func = functions.char_count_ci,
            .volatility = .immutable,
            .strict = true,
            .parallel = .safe,
            .comment = "Count non-overlapping occurrences of a character.",
        },
    },

    // Raw SQL emitted after the generated statements, for objects that depend
    // on the functions (operators, operator classes, casts, ...).
    .post_sql = "GRANT EXECUTE ON FUNCTION char_count_zig(text, text) TO PUBLIC;",
};
```

The three sections are emitted in order: `.sql`, then the generated functions,
then `.post_sql`. That ordering is what allows a type whose shell is declared
first, whose I/O functions are generated, and whose operators/casts are added
last; see `examples/rational`.

Only `name` and `func` are required. Every other field has a default:

| Field        | Type                     | Default            | Meaning |
| ------------ | ------------------------ | ------------------ | ------- |
| `name`       | `[]const u8`             | none               | SQL function name. |
| `func`       | a function               | none               | The Zig implementation. |
| `volatility` | `pgzx.ddl.Volatility`    | `.@"volatile"`     | `VOLATILE` / `STABLE` / `IMMUTABLE`. |
| `strict`     | `bool`                   | `false`            | Emit `STRICT` (returns NULL on NULL input). |
| `parallel`   | `?pgzx.ddl.Parallel`     | `null`             | `UNSAFE` / `RESTRICTED` / `SAFE`; omitted when null. |
| `args`       | `?[]const []const u8`    | `null`             | Override argument SQL types. |
| `returns`    | `?[]const u8`            | `null`             | Override the return SQL type. |
| `symbol`     | `?[]const u8`            | `null`             | C symbol when it differs from the SQL name (emits `AS 'MODULE_PATHNAME', 'symbol'`). |
| `comment`    | `?[]const u8`            | `null`             | Emit `COMMENT ON FUNCTION`. |

`pgzx.ddl.Volatility` and `pgzx.ddl.Parallel` are exported by the library so the
schema file can import them through `pgzx`:

```zig
const pgzx = @import("pgzx");
// .volatility = pgzx.ddl.Volatility.immutable
```

### Derived types

Unless overridden, argument and return types are derived from the Zig signature
through the same converters that marshal datums at runtime. A `pg.FunctionCallInfo`
parameter is treated as the fmgr context and is not emitted as a SQL argument.

Current built-in mappings:

| Zig type | SQL type |
| --- | --- |
| `void` | `void` |
| `bool` | `boolean` |
| `i8`, `i16`, `u8` | `smallint` |
| `i32`, `u16` | `integer` |
| `i64`, `u32`, `u64` | `bigint` |
| `f32` | `real` |
| `f64` | `double precision` |
| `[]const u8`, `[:0]const u8` | `text` |
| `?T` | same as `T` |

Because the mapping lives on the type converters (`Conv` in
`src/pgzx/datum.zig`), a type without a direct SQL representation raises a
compile error at generation time, which is much better than emitting a broken
script.

### Overrides

Use `args`/`returns` when the Zig type has no direct SQL mapping: a raw
`pg.Datum`, a C-convention wrapper, or a type you want to name differently:

```zig
// fn hello_world_c(fcinfo: pg.FunctionCallInfo) pg.Datum
.{ .name = "hello_world_c", .func = functions.hello_world_c,
   .args = &.{"text"}, .returns = "text" },
```

The generated statement is always:

```sql
CREATE FUNCTION name(argtypes) RETURNS rettype
AS 'MODULE_PATHNAME'
LANGUAGE C [IMMUTABLE|STABLE] [STRICT] [PARALLEL ...];
```

Note that argument names are not generated (`text`, not `name text`): Zig 0.16
does not expose parameter names through `@typeInfo`. That is valid SQL and does
not affect calls. If you need names, put the full spelling in `args`
(`&.{"name text"}`).

## 4. Build steps

`addSteps` registers a consistent set:

| Step | Command | What it does |
| --- | --- | --- |
| install | `zig build` | Builds the shared library, installs the `.control`/static SQL directory, and installs the generated versioned SQL script. |
| check | `zig build check` | Compiles the extension as an object without linking/installing. Fast feedback. |
| sql | `zig build sql` | Generates and installs only the versioned SQL script. |
| unit | `zig build unit` | Builds a `<name>_unit` library with `testfn = true`, installs it, runs `SELECT run_tests()`. |
| pg_regress | `zig build pg_regress` | Runs the SQL regression tests via the PostgreSQL `pg_regress` tool. |

Install location:

```sh
zig build                     # everything lands in ./zig-out
zig build -p "$PG_HOME"       # installs into the running PostgreSQL:
                              #   $PG_HOME/lib/<name>.so
                              #   $PG_HOME/share/postgresql/extension/*
```

The `sql` step exists so you can regenerate and inspect the script without a
full build:

```sh
zig build sql
cat zig-out/share/postgresql/extension/my_extension--0.1.sql
```

## 5. The extension directory and loading

The source `extension/` directory is installed verbatim into
`$PG_HOME/share/postgresql/extension`. It must contain a control file:

```ini
# extension/my_extension.control
comment = 'my extension'
default_version = '0.1'
module_pathname = '$libdir/my_extension'
relocatable = true
```

The generated script uses the token `MODULE_PATHNAME`, which PostgreSQL
substitutes using `module_pathname` from the control file when the extension is
created. The generated file is named `<name>--<major>.<minor>.sql`, matching
`default_version` in the control file.

```sh
psql -U postgres -c 'CREATE EXTENSION my_extension;'
```

## 6. Testing

- **In-server unit tests.** Put suites in `functions.zig` and register them from
  `main.zig`:

  ```zig
  comptime {
      pgzx.testing.registerTests(@import("build_options").testfn, .{
          functions.Testsuite1,
          functions.Testsuite2,
      });
  }
  ```

  Any function whose name starts with `test` is a test. Run with
  `zig build unit -p "$PG_HOME"`.

- **`pg_regress`.** Provide `sql/<script>.sql` and `expected/<script>.out` and
  list the scripts in `.pg_regress`. Run with
  `zig build pg_regress -p "$PG_HOME"`.

- **Pure Zig tests.** Not part of the extension build; used inside pgzx itself
  for modules that do not need a server.

Complete working examples:

- `examples/char_count_zig`: minimal, one function.
- `examples/sqlfns`: every registration style, including raw C exports and
  `PG_EXPORT`.
- `examples/rational`: a base type; shows `.post_sql` (embedded
  `catalog.sql`) and `.symbol` (SQL name `abs`, C symbol `rational_abs`), and
  the ordering trick of a shell type followed by generated I/O functions.

## 7. Pitfalls

- **Do not put `PG_FUNCTION_V1`/`PG_EXPORT` in `schema.zig`.** The generator
  will fail to link with `undefined symbol: palloc`-style errors. Keep
  registration in `main.zig`.
- **Point `.schema.source` at the right file.** The default is
  `<root_dir>/schema.zig`. If you name it differently, pass
  `.schema = .{ .source = "src/my_schema.zig" }`.
- **Keep the control file's `default_version` in sync with `.version`** in
  `Project.init`, or PostgreSQL will look for a SQL file that does not exist.
- **A missing SQL type mapping is a compile error**, not silent output. Add the
  type to `datum.zig` or use `args`/`returns`.
- **Regenerate on every build.** The SQL step runs as part of `zig build`; do
  not hand-edit the generated file (it is overwritten).

---

## Appendix: complete minimal example

`examples/char_count_zig` in full.

```
examples/char_count_zig/
  build.zig
  build.zig.zon
  extension/char_count_zig.control
  src/functions.zig
  src/schema.zig
  src/main.zig
  sql/char_count_test.sql
  expected/char_count_test.out
```

`build.zig`:

```zig
const std = @import("std");
const PGBuild = @import("pgzx").Build;

pub fn build(b: *std.Build) void {
    const proj = PGBuild.Project.init(b, .{
        .name = "char_count_zig",
        .version = .{ .major = 0, .minor = 1 },
        .root_dir = "src/",
        .root_source_file = "src/main.zig",
    });

    _ = proj.addSteps(.{
        .schema = .{},
        .pg_regress = .{
            .db_user = "postgres",
            .db_port = 5432,
            .scripts = &[_][]const u8{"char_count_test"},
        },
        .unit = .{
            .db_user = "postgres",
            .db_port = 5432,
        },
    });
}
```

`src/schema.zig`:

```zig
const functions = @import("functions.zig");

pub const pgzx_sql = .{
    .functions = .{
        .{ .name = "char_count_zig", .func = functions.char_count_zig },
    },
};
```

`src/main.zig`:

```zig
const pgzx = @import("pgzx");
const functions = @import("functions.zig");

comptime {
    pgzx.PG_MODULE_MAGIC();
    pgzx.PG_FUNCTION_V1("char_count_zig", functions.char_count_zig);
}

comptime {
    pgzx.testing.registerTests(@import("build_options").testfn, .{
        functions.Testsuite1,
        functions.Testsuite2,
    });
}
```

Generated script (`zig build sql`):

```sql
CREATE FUNCTION char_count_zig(text, text) RETURNS bigint
AS 'MODULE_PATHNAME'
LANGUAGE C;
```
