---
title: Build, test and ship
---

Building an example, calling it from SQL, the `PGBuild` helper, and the three
kinds of tests.

## 6. Build an example extension

```sh
cd examples/char_count_zig

zig build                       # compile + install into ./zig-out
zig build -p "$PG_HOME"         # compile + install into the local PostgreSQL
zig build check                 # compile only (fast feedback)
```

`-p "$PG_HOME"` is what makes the extension usable from the running server: it
installs the shared library into `$PG_HOME/lib` (the server's `$libdir`) and the
extension files into `$PG_HOME/share/postgresql/extension`.

Without `-p` everything goes to `./zig-out`, which is handy when you only want
to inspect artifacts or debug the build itself.

## 7. Use it from SQL

```sh
psql -U postgres -c 'CREATE EXTENSION char_count_zig;'
psql -U postgres -c "SELECT char_count_zig('aaabc', 'a');"
```

The `CREATE EXTENSION` statement works because the control file and SQL script
were installed into the server's `sharedir/extension` directory in step 6.

## 8. The build helper (`PGBuild`)

Extensions use the build helpers exported from pgzx. A minimal `build.zig`:

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

`addSteps` wires up:

- `check`: compiles the extension without installing.
- `install`: the default `zig build` target; installs the library and the
  extension directory.
- `pg_regress`: runs the SQL regression tests.
- `unit`: builds and runs the in-server unit tests.

You can also use the lower level API (`@import("pgzx").Build`) directly if you
need custom steps.

## 9. Write extension code

A module declares its magic and its SQL-callable functions at comptime:

```zig
const pgzx = @import("pgzx");

comptime {
    pgzx.PG_MODULE_MAGIC();

    pgzx.PG_FUNCTION_V1("hello", hello);
}

fn hello() ![:0]const u8 {
    return "Hello, world!";
}
```

More features, each with a runnable example:

- Function manager, arguments and return values: `examples/char_count_zig`.
- Calling Postgres C APIs: `examples/pghostname_zig`.
- Several SQL functions: `examples/sqlfns`.
- Running SQL from inside the server (SPI): `examples/spi_sql`.
- Custom GUCs and hooks: `examples/guc`.
- Backend-safe file I/O and PG18 async reads: `examples/file_io`.
- Background workers: `examples/bgworker`.
- Executor hooks, memory contexts, error handling: `examples/pgaudit_zig`.

Useful building blocks:

- Logging: `pgzx.elog.Info/Notice/Warning/Error`.
- Memory: `pgzx.mem.createAllocSetContext` and the PG memory context
  allocators. Remember `TopMemoryContext` for process-lifetime data.
- Errors and `PG_TRY`-style handling: `pgzx.err`.

## 10. Tests

There are three kinds of tests.

### `pg_regress` (SQL regression tests)

Put input scripts in `sql/` and expected output in `expected/`. The test name
(e.g. `char_count_test`) matches `sql/char_count_test.sql`. Run:

```sh
zig build pg_regress --verbose
```

On failure a `regression.diffs` file is written next to the test. To accept new
behavior, review the diffs and update the file in `expected/`.

### In-server unit tests

These are Zig test suites compiled into a dedicated `{name}_unit` library and
executed with `SELECT run_tests()` inside a real backend. Register them in your
module:

```zig
comptime {
    pgzx.testing.registerTests(@import("build_options").testfn, .{Tests});
}
```

Run them with the install prefix so the library lands in the server's libdir:

```sh
zig build -p "$PG_HOME" unit
```

### Pure-Zig tests (no server)

For code that does not need a running Postgres (e.g. `meta`), the repository
has a `zig build test` target that runs under `zig test`.

## 11. Create a new extension project

```sh
pgzx new my_extension
cd my_extension
eval "$(pgzx env)"
pgzx init && pgzx start
zig build -p "$PG_HOME"
```

While developing pgzx itself, build the CLI and template from your checkout instead:

```sh
zig build cli
./zig-out/bin/pgzx new my_extension
```

The template ships `build.zig`, `build.zig.zon`, `src/main.zig`, `extension/`,
and `sql/` + `expected/` folders, plus a `Makefile` and an `.envrc` that calls
`pgzx env`.

`pgzx new` pins the pgzx dependency to the release it came from and writes the
package hash, so the generated project builds without editing
`build.zig.zon`. From a checkout it runs `zig fetch --save=pgzx <ref>` instead;
pass `--pgzx-ref <tag>` to pin a specific release, or `--no-fetch` when the
environment has no network access.

For local development point the dependency at your checkout:

```zig
// build.zig.zon
.pgzx = .{ .path = "../pgzx" },
```

## 12. Switch PostgreSQL versions

Install the versions you want side by side (apt PGDG, Homebrew `postgresql@NN`)
and select one with `PG_CONFIG`:

```sh
export PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config   # or $(brew --prefix postgresql@17)/bin/pg_config
eval "$(pgzx env)"
pgzx init && pgzx start
cd examples/char_count_zig
rm -rf .zig-cache       # IMPORTANT: rebuild the Postgres header translation
zig build -p "$PG_HOME"
```

Each version needs its own cluster: `pgzx env` derives `PGZX_CLUSTER_DIR` from
the project, so remove `out/pg` (or point `PGZX_CLUSTER_DIR` elsewhere) when
switching. Always delete the local `.zig-cache` when switching versions (or
when you changed the PostgreSQL headers), otherwise Zig may reuse a
translation of the old headers.
