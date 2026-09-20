# HACKING: local development guide

This guide walks through everything you need to build, test, debug and ship a
pgzx extension on your machine. It assumes you have cloned this repository.

> Why not `docs/HACKING.md`? The `docs/` directory contains generated API
> documentation and `zig build docs` **deletes and regenerates** it, so
> hand-written pages would be lost.

## Table of contents

- [1. Prerequisites](#1-prerequisites)
- [2. Enter the development shell](#2-enter-the-development-shell)
- [3. Create the local PostgreSQL installation](#3-create-the-local-postgresql-installation)
- [4. Repository layout](#4-repository-layout)
- [5. Environment variables](#5-environment-variables)
- [6. Build an example extension](#6-build-an-example-extension)
- [7. Use it from SQL](#7-use-it-from-sql)
- [8. The build helper (`PGBuild`)](#8-the-build-helper-pgbuild)
- [9. Write extension code](#9-write-extension-code)
- [10. Tests](#10-tests)
- [11. Create a new extension project](#11-create-a-new-extension-project)
- [12. Switch PostgreSQL versions](#12-switch-postgresql-versions)
- [13. Debugging](#13-debugging)
- [14. CI](#14-ci)
- [15. Troubleshooting](#15-troubleshooting)

## 1. Prerequisites

- **Nix** with flakes enabled. The
  [DeterminateSystems installer](https://github.com/DeterminateSystems/nix-installer)
  enables flakes out of the box.
- Optionally **direnv** to load the shell automatically.
- Linux or macOS (x86_64 or aarch64).

If you cannot or do not want to install Nix, there is a Docker based
development shell:

```sh
./dev/docker/build.sh   # builds the pgzx:latest image
./dev/docker/run.sh     # enters a shell inside the container
```

## 2. Enter the development shell

```sh
nix develop
```

The first entry is slow: Nix builds/fetches Zig, `zls`, PostgreSQL 15-18, the
linters, and a few tools. Subsequent entries are cached.

With direnv the shell loads automatically:

```sh
direnv allow
```

There is a second shell with extra tooling to build PostgreSQL and Zig from
source (see [Debugging](#13-debugging)):

```sh
nix develop '.#debug'
```

On shell entry you get a menu of the helper commands:

| Command | Purpose |
| --- | --- |
| `pguse <15\|16\|17\|18\|local>` | Select the PostgreSQL version to use |
| `pglocal` | Relocate a PostgreSQL install into `out/<version>` |
| `pginit` | Initialize the local cluster and database |
| `pgstart` / `pgstop` / `pgstatus` | Control the local server |
| `menu` | Show the command list |
| `root` (alias) | `cd` back to the project root |

## 3. Create the local PostgreSQL installation

We never install into the Nix store. Instead `pglocal` copies (relocates) a
PostgreSQL installation into `out/<version>` and symlinks `out/default` to it,
so we can write extension libraries into it.

```sh
pguse 16        # choose a version (writes out/.pgversion)
pglocal         # relocate out/16 and point out/default at it
pginit          # initdb + create the 'postgres' superuser
pgstart        # start the server
pgstatus       # show the server status
psql -U postgres -c 'select version()'
pgstop         # stop the server
```

Notes:

- Run `pglocal` once per version, and `pginit` once per version. Each version
  keeps its own cluster under `out/<version>/var/postgres`.
- `pginit` accepts optional arguments:
  ```sh
  pginit <cluster> <database> <user>
  pginit -p 5433                       # custom port
  pginit -s pg_stat_statements         # shared_preload_libraries
  pginit -i path/to/sql/dir            # run *.sql on init
  pginit -c path/to/postgresql.conf    # custom config
  ```
- The Unix socket lives in `out/default/run` (not the compiled-in
  `/run/postgresql`), and `PGHOST` is exported to point at it.
- Server logs are written to `out/default/var/postgres/log/server.log`.

## 4. Repository layout

```
build.zig            top-level project (the pgzx library itself)
build.zig.zon
src/pgzx.zig         the pgzx library entry point
src/pgzx/build.zig   build helpers (PGBuild) used by extensions
src/pgzx/c/          C shims and the Postgres header translation
src/testing.zig      entry point for the in-server unit test extension
examples/            sample extensions, each its own package
dev/bin/             pglocal, pginit, pgstart, ... helper scripts
nix/                 flake modules and the project template
tools/               codegen tools (e.g. gennodetags)
out/                 relocated PostgreSQL installs (git-ignored)
```

Every directory under `examples/` is a self-contained Zig package with its own
`build.zig` and `build.zig.zon`, depending on pgzx via a path dependency.

## 5. Environment variables

The development shell sets these for you:

| Variable | Value | Meaning |
| --- | --- | --- |
| `PRJ_ROOT` | project root | used by the helper scripts |
| `PG_HOME` | `$PRJ_ROOT/out/default` | the relocated install in use |
| `PGHOST` | `$PG_HOME/run` | Unix socket directory for clients |
| `NIX_PGLIBDIR` | `$PG_HOME/lib` | where the Nix PostgreSQL looks for modules |
| `PGZX_C_INCLUDE_DIRS` | store paths | extra C headers for the header translation |
| `ZIG_LOCAL_CACHE_DIR` | `~/.cache/zig-pgzx` | shared Zig cache for the whole repo |
| `PG_VERSION` | optional | overrides the `pg_config` dispatcher version |

`pg_config` in the shell is a dispatcher: it picks the version from
`$PG_VERSION`, else `out/.pgversion`, else PostgreSQL 16.

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

- `check` — compiles the extension without installing.
- `install` — the default `zig build` target; installs the library and the
  extension directory.
- `pg_regress` — runs the SQL regression tests.
- `unit` — builds and runs the in-server unit tests.

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

Use the flake template:

```sh
nix flake init -t github:xataio/pgzx
nix develop
pguse 16 && pglocal && pginit
zig build -p "$PG_HOME"
```

While developing pgzx itself, template from your checkout instead:

```sh
nix flake init -t /path/to/pgzx
```

The template ships a `flake.nix`, `devshell.nix`, `.envrc`, `build.zig`,
`build.zig.zon`, `src/main.zig`, `extension/`, and `sql/` + `expected/` folders.
For local development point the dependency at your checkout:

```zig
// build.zig.zon
.pgzx = .{ .path = "../pgzx" },
```

## 12. Switch PostgreSQL versions

```sh
pguse 17
pglocal
pginit
cd examples/char_count_zig
rm -rf .zig-cache       # IMPORTANT: rebuild the Postgres header translation
zig build -p "$PG_HOME"
```

Always delete the local `.zig-cache` when switching versions (or when you
changed the PostgreSQL headers), otherwise Zig may reuse a translation of the
old headers.

## 13. Debugging

### In-server unit tests

Because Postgres forks a backend per connection, attach a debugger to a running
session:

```sh
psql -U postgres
```

```sql
SELECT pg_backend_pid();   -- e.g. 14985
DROP FUNCTION IF EXISTS run_tests;
CREATE FUNCTION run_tests() RETURNS INTEGER
AS '$libdir/pgzx_unit' LANGUAGE C IMMUTABLE;
```

Then attach (`lldb -p 14985`, `gdb -p 14985`, or VS Code) and run
`SELECT run_tests();`.

### VS Code

Use the [CodeLLDB](https://marketplace.visualstudio.com/items?itemName=vadimcn.vscode-lldb)
extension and attach to the backend PID. Start VS Code from the dev shell so it
inherits the environment:

```sh
nix develop '.#debug' --command code .
```

If a VS Code instance is already running, the `code` launcher forwards to it
and the environment is not updated; quit VS Code first. The repository ships a
`.vscode/launch.json` with two configurations:

- `Attach to Postgres backend` — prompts for the PID and attaches.
- `Attach to Postgres backend (unit tests)` — same, but runs the
  `ext: build unit lib` task first so the `{name}_unit` library is installed
  into the server libdir with `-p "$PG_HOME"`.

`.vscode/tasks.json` provides `ext: build`, `ext: build unit lib` and
`ext: pg_regress` with a picker for the example.

For the production library, load it and call a function:

```sql
LOAD 'char_count_zig';
SELECT char_count_zig('aaabc', 'a');
```

To debug a unit test suite, open a psql session, get the PID, run the
`Attach to Postgres backend (unit tests)` configuration (it rebuilds the
`{name}_unit` library first), then:

```sql
DROP FUNCTION IF EXISTS run_tests;
CREATE FUNCTION run_tests() RETURNS INTEGER
AS '$libdir/char_count_zig_unit' LANGUAGE C IMMUTABLE;
SELECT run_tests();
```

### Editor setup (ZLS)

If the editor shows `(unknown)` for `@import("pgzx")`, ZLS could not evaluate
`build.zig`. The pgzx build runs `pg_config` and translates the Postgres
headers at configure time, so ZLS must run with the development shell
environment. Symptoms are translate-c errors such as `'postgres.h' not found`
in the ZLS output panel.

- Start the editor from `nix develop`, or rely on direnv (`.envrc` uses
  `use flake`).
- `.vscode/settings.json` pins `zig.zls.path` to the shell's `zls`. Refresh it
  with `which zls` after `flake.lock` updates.
- `zls.json` enables build-on-save so the project is re-indexed with
  `zig build check`.
- Restart the extension host after changing the environment.

### PostgreSQL debug build

For stepping into PostgreSQL itself:

```sh
nix develop '.#debug'
pgbuild
pguse local
```

This checks out PostgreSQL into `out/postgresql_src` and installs a debug build
into `out/local`, which you can select with `pguse local`.

### Zig standard library / compiler

```sh
ziglocal clone --branch 0.16.0
zig build unit -p "$PG_HOME" --zig-lib-dir "$PRJ_ROOT/out/zig/lib"
```

The `debug` shell has the extra dependencies to build the Zig compiler too.

## 14. CI

The CI is a shell script and works the same locally:

```sh
./ci/setup.sh   # pglocal + pginit
./ci/run.sh     # build all examples, run pgzx unit tests and every example
```

`ci/run.sh` builds all examples in parallel, starts the server, runs the pgzx
unit tests, then runs each example's `ci/run.sh` (build, create extension, unit
tests, regression tests, drop). It prints `Success!` on success.

## 15. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `failed to spawn .../pg_regress: FileNotFound` | `pg_config --pkglibdir` does not contain the pgxs tooling; the build now derives `pg_regress` from `pg_config --pgxs` |
| `could not access file "foo_unit"` | the unit library was not installed into the server libdir; run `zig build -p "$PG_HOME" unit` |
| `SET` outside the valid range instead of clamping | core validates `min/max` *before* check hooks; widen the bounds |
| `server closed the connection unexpectedly` | a crash (e.g. a NULL value address); check `out/default/var/postgres/log/server.log` |
| `(unknown)` for pgzx imports in the editor | ZLS is missing the dev-shell environment; see [Editor setup](#editor-setup-zls) |
| stale weird errors after `pguse` | `rm -rf .zig-cache` in the package and rebuild |

Useful commands:

```sql
SHOW client_min_messages;   -- what is sent to the client
SHOW log_min_messages;      -- what is written to the server log
```

The server log is at `$PG_HOME/var/postgres/log/server.log`.
