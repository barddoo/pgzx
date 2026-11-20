# HACKING: local development guide

This guide walks through everything you need to build, test, debug and ship a
pgzx extension on your machine. It assumes you have cloned this repository.

> Why not `docs/HACKING.md`? The `docs/` directory contains generated API
> documentation and `zig build docs` **deletes and regenerates** it, so
> hand-written pages would be lost.

## Table of contents

- [HACKING: local development guide](#hacking-local-development-guide)
  - [Table of contents](#table-of-contents)
  - [1. Prerequisites](#1-prerequisites)
  - [2. Load the project environment](#2-load-the-project-environment)
  - [3. Create the local PostgreSQL cluster](#3-create-the-local-postgresql-cluster)
  - [4. Repository layout](#4-repository-layout)
  - [5. Environment variables](#5-environment-variables)
  - [6. Build an example extension](#6-build-an-example-extension)
  - [7. Use it from SQL](#7-use-it-from-sql)
  - [8. The build helper (`PGBuild`)](#8-the-build-helper-pgbuild)
  - [9. Write extension code](#9-write-extension-code)
  - [10. Tests](#10-tests)
    - [`pg_regress` (SQL regression tests)](#pg_regress-sql-regression-tests)
    - [In-server unit tests](#in-server-unit-tests)
    - [Pure-Zig tests (no server)](#pure-zig-tests-no-server)
  - [11. Create a new extension project](#11-create-a-new-extension-project)
  - [12. Switch PostgreSQL versions](#12-switch-postgresql-versions)
  - [13. Debugging](#13-debugging)
    - [In-server unit tests](#in-server-unit-tests-1)
    - [VS Code](#vs-code)
    - [Editor setup (ZLS)](#editor-setup-zls)
    - [PostgreSQL debug build](#postgresql-debug-build)
    - [Zig standard library / compiler](#zig-standard-library--compiler)
  - [14. CI](#14-ci)
  - [15. Troubleshooting](#15-troubleshooting)
  - [16. Releasing](#16-releasing)

## 1. Prerequisites

- **Zig 0.17 or newer** — [ziglang.org/download](https://ziglang.org/download/).
- **PostgreSQL 15–18** with development headers. Debian/Ubuntu:
  `postgresql-server-dev-NN`; macOS: `postgresql@NN`; Fedora: `postgresql-devel`.
- A C toolchain and the OpenSSL/Kerberos headers (`libssl-dev libkrb5-dev`, or
  `openssl@3 krb5` on Homebrew).
- Linux or macOS (x86_64 or aarch64).
- Optionally **direnv** to load the project environment automatically.

### Install the `pgzx` command

macOS, with Homebrew:

```sh
brew install barddoo/tap/pgzx
```

Linux, and macOS without Homebrew:

```sh
curl -fsSL https://github.com/barddoo/pgzx/releases/latest/download/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
```

Check the environment before going further:

```sh
pgzx doctor
```

It reports Zig, `pg_config`, the server headers, the extra C headers needed by
the PostgreSQL header translation, and whether the extension directories are
writable. Each failure is printed with the command that fixes it.

### Option A — Homebrew (macOS)

```sh
brew install postgresql@18 openssl@3 krb5 zig
brew link --force postgresql@18
```

Homebrew prefixes are owned by your user, so installing the extension into
PostgreSQL needs no elevated permissions.

### Option B — Raw install (Linux)

Install Zig from [ziglang.org/download](https://ziglang.org/download/) and put
it on `PATH`:

```sh
ZIG_VERSION=0.17.1
curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
     -o /tmp/zig.tar.xz
sudo tar -C /usr/local -xJf /tmp/zig.tar.xz
sudo ln -s "/usr/local/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig
zig version   # should print 0.17.1
```

Install PostgreSQL and its development headers:

```sh
PG_MAJOR=18   # or 15 / 16 / 17
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
  https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update
sudo apt-get install -y \
    postgresql-${PG_MAJOR} \
    postgresql-server-dev-${PG_MAJOR} \
    libssl-dev libkrb5-dev
```

On Fedora/RHEL:

```sh
sudo dnf install -y postgresql-server postgresql-devel openssl-devel krb5-devel
```

`zig build -p "$PG_HOME"` writes the shared library and the extension SQL into
the PostgreSQL prefix. Distro packages make those directories root-owned, so
give your user write access once:

```sh
sudo chown -R "$(id -un)" \
  "$(pg_config --pkglibdir)" \
  "$(pg_config --sharedir)/extension"
```

(On Homebrew and in the Docker image this is not needed.)

### Option C — Docker (nothing installed on the host)

```sh
# Build once (~3 min; cached afterwards). Pick a PostgreSQL version if needed.
docker build \
  --build-arg PG_MAJOR=18 \
  -f dev/docker/Dockerfile.standalone \
  -t pgzx-standalone \
  .

# Scaffold into the current directory, then work in the container.
docker run -it --rm -v "$PWD:/work" -w /work pgzx-standalone
```

Inside the container, Zig, PostgreSQL (with headers), and `pgzx` are already on
`PATH`. The extension directories are owned by the container's `dev` user, so
`zig build -p "$PG_HOME"` works without `sudo`:

```sh
pgzx new my_ext
cd my_ext
eval "$(pgzx env)"
pgzx init && pgzx start
zig build -p "$PG_HOME"
psql -U postgres -c 'CREATE EXTENSION my_extension'
pgzx stop
```

Or use Compose, which mounts the repository at `/workspace`:

```sh
docker compose -f dev/docker/docker-compose.yml run --rm dev
```

### Create and run the project (all options)

```sh
pgzx doctor
pgzx new my_ext
cd my_ext
eval "$(pgzx env)"     # or: direnv allow
pgzx init && pgzx start
zig build -p "$PG_HOME"
psql -U postgres -c 'CREATE EXTENSION my_extension'
psql -U postgres -c 'SELECT hello()'
zig build -p "$PG_HOME" unit
zig build pg_regress
pgzx stop
```

`pgzx new` uses `templates/default`. Cluster state lives in `<project>/out/pg`,
so nothing is written into the PostgreSQL installation. Use `PG_CONFIG` to
pick a PostgreSQL version (see [§12](#12-switch-postgresql-versions)).

## 2. Load the project environment

From a checkout, build the CLI once and put it on `PATH`:

```sh
zig build cli
export PATH="$PWD/zig-out/bin:$PATH"
```

`pgzx env` prints shell exports for the project; evaluate them in the shell you
build from:

```sh
eval "$(pgzx env)"
```

It derives `PG_HOME`, `PGHOST`, the socket directory, the include paths and a
shared Zig cache from `pg_config`, and prepends the PostgreSQL `bin` and
`pg_regress` directories to `PATH`. Run it again after changing `PG_CONFIG`.

With direnv, the generated project's `.envrc` loads it automatically:

```sh
direnv allow
```

The commands are subcommands of the `pgzx` binary:

| Command                           | Purpose                                   |
| --------------------------------- | ----------------------------------------- |
| `pgzx new <name>`                 | Create a new extension project            |
| `pgzx env`                        | Print the project environment             |
| `pgzx init` / `start` / `stop` / `status` | Control the local cluster          |
| `pgzx doctor`                     | Check Zig, PostgreSQL and headers         |
| `pgzx fingerprint`                | Refresh the package fingerprint           |

## 3. Create the local PostgreSQL cluster

```sh
eval "$(pgzx env)"
pgzx init        # initdb + create the 'postgres' superuser
pgzx start       # start the server
pgzx status      # show the server status
psql -U postgres -c 'select version()'
pgzx stop        # stop the server
```

Notes:

- Cluster state lives in `<project>/out/pg/postgres`; it is independent of the
  PostgreSQL installation, so a read-only system prefix works.
- `pgzx init` accepts optional arguments:
  ```sh
  pgzx init <cluster> <database> <user>
  pgzx init -p 5433                    # custom port
  pgzx init -s pg_stat_statements      # shared_preload_libraries
  pgzx init -i path/to/sql/dir         # run *.sql on init
  pgzx init -c path/to/postgresql.conf # custom config
  ```
- The Unix socket lives in `out/pg/run` (not the compiled-in
  `/run/postgresql`), and `PGHOST` points at it.
- Server logs are written to `out/pg/postgres/log/server.log`.
- `PGZX_CLUSTER_DIR` moves the cluster state and `PG_SOCKET_DIR` moves the
  socket; `pgzx env` sets both under `<project>/out/pg` by default.

## 4. Repository layout

```
build.zig            top-level project (the pgzx library itself)
build.zig.zon
src/pgzx.zig         the pgzx library entry point
src/pgzx/build.zig   build helpers (PGBuild) used by extensions
src/pgzx/c/          C shims and the Postgres header translation
src/testing.zig      entry point for the in-server unit test extension
examples/            sample extensions, each its own package
dev/bin/             pgbuild and other host tooling (`pgzx` itself is built to zig-out/bin)
templates/default/   the project template used by `pgzx new`
tools/               codegen and release scripts (build-dist)
out/                 local cluster state (git-ignored)
```

Every directory under `examples/` is a self-contained Zig package with its own
`build.zig` and `build.zig.zon`, depending on pgzx via a path dependency.

## 5. Environment variables

`pgzx env` sets these for you:

| Variable              | Value                   | Meaning                                      |
| --------------------- | ----------------------- | -------------------------------------------- |
| `PRJ_ROOT`            | project root            | used by the CLI and tooling                  |
| `PG_HOME`             | `pg_config` prefix      | the PostgreSQL installation in use           |
| `PGHOST`              | `$PG_SOCKET_DIR`        | Unix socket directory for clients            |
| `PGZX_CLUSTER_DIR`    | `<project>/out/pg`      | cluster state                                 |
| `PG_SOCKET_DIR`       | `$PGZX_CLUSTER_DIR/run` | Unix socket directory used by the server     |
| `PGZX_C_INCLUDE_DIRS` | Homebrew paths          | extra C headers for the header translation   |
| `ZIG_LOCAL_CACHE_DIR` | `~/.cache/zig-pgzx`     | shared Zig cache for the whole repo          |
| `PG_CONFIG`           | optional                | `pg_config` to use (default: `pg_config`)    |

To work against a specific installation, point `PG_CONFIG` at its `pg_config`
before evaluating `pgzx env`.

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
extension and attach to the backend PID. Start VS Code from a shell that has
the project environment so it inherits it:

```sh
eval "$(pgzx env)"
code .
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
headers at configure time, so ZLS must run with the environment from
`eval "$(pgzx env)"`. Symptoms are translate-c errors such as
`'postgres.h' not found` in the ZLS output panel.

- Start the editor from a shell where `eval "$(pgzx env)"` has been run, or
  rely on direnv (the project `.envrc` calls `pgzx env`).
- Install `zls` and put it on `PATH` so the editor extension can find it.
- `zls.json` enables build-on-save so the project is re-indexed with
  `zig build check`.
- Restart the extension host after changing the environment.

### PostgreSQL debug build

For stepping into PostgreSQL itself, build it from source (needs `git`, meson,
ninja, ccache and a C toolchain):

```sh
pgbuild
export PG_CONFIG="$PRJ_ROOT/out/local/bin/pg_config"
eval "$(pgzx env)"
```

This checks out PostgreSQL into `out/postgresql_src` and installs a debug build
into `out/local`.

### Zig standard library / compiler

```sh
ziglocal clone --branch 0.16.0
zig build unit -p "$PG_HOME" --zig-lib-dir "$PRJ_ROOT/out/zig/lib"
```

The extra tooling for building the Zig compiler and PostgreSQL from source
(clang, llvm, meson, ninja, ccache) must be installed on the host.

## 14. CI

The CI is a shell script and works the same locally:

```sh
./ci/setup.sh   # zig build cli + eval "$(pgzx env)" + pgzx init
./ci/run.sh     # build all examples, run pgzx unit tests and every example
```

`ci/run.sh` builds all examples in parallel, starts the server, runs the pgzx
unit tests, then runs each example's `ci/run.sh` (build, create extension, unit
tests, regression tests, drop). It prints `Success!` on success.

The GitHub workflows run the same flow against PGDG packages for PostgreSQL
15–18, plus end-to-end jobs and a release gate (`release.yaml` calls
`check.yaml`):

- `lint` — shellcheck, shfmt and actionlint (the same tools as the local
  `.pre-commit-config.yaml`).
- `test` — the repo's `ci/setup.sh`/`ci/run.sh` on every supported PostgreSQL
  version.
- `linux` — installs the release bundle with `install.sh --local`, then
  scaffolds, builds, and runs unit + regression tests.
- `macos` — Homebrew PostgreSQL 18 + Zig, runs `pgzx doctor` and compiles the
  template.
- `templates` — scaffolds the template and asserts the release stamping writes
  the tag URL and package hash.

## 15. Troubleshooting

| Symptom                                           | Cause / fix                                                                                                           |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `failed to spawn .../pg_regress: FileNotFound`    | `pg_config --pkglibdir` does not contain the pgxs tooling; the build now derives `pg_regress` from `pg_config --pgxs` |
| `could not access file "foo_unit"`                | the unit library was not installed into the server libdir; run `zig build -p "$PG_HOME" unit`                         |
| `cannot create cluster state ...`                | the PostgreSQL prefix is read-only; set `PGZX_CLUSTER_DIR` to a writable directory (or use `pgzx env`, which does)      |
| `SET` outside the valid range instead of clamping | core validates `min/max` *before* check hooks; widen the bounds                                                       |
| `server closed the connection unexpectedly`       | a crash (e.g. a NULL value address); check `out/pg/postgres/log/server.log`                                            |
| `(unknown)` for pgzx imports in the editor        | ZLS is missing the environment from `eval "$(pgzx env)"`; see [Editor setup](#editor-setup-zls)                        |
| stale weird errors after changing `PG_CONFIG`     | `rm -rf .zig-cache` in the package and rebuild                                                                        |

Useful commands:

```sql
SHOW client_min_messages;   -- what is sent to the client
SHOW log_min_messages;      -- what is written to the server log
```

The server log is at `$PGZX_CLUSTER_DIR/postgres/log/server.log`
(`out/pg/postgres/log/server.log` by default).

## 16. Releasing

`tools/build-dist.sh` cross-compiles the CLI and writes these into `dist/`:

| Artifact | Notes |
| --- | --- |
| `pgzx-cli-<tag>-aarch64-macos.tar.gz` | Apple silicon |
| `pgzx-cli-<tag>-x86_64-macos.tar.gz` | Intel macOS |
| `pgzx-cli-<tag>-aarch64-linux-musl.tar.gz` | Linux arm64, statically linked |
| `pgzx-cli-<tag>-x86_64-linux-musl.tar.gz` | Linux x86_64, statically linked |
| `pgzx-template-<tag>.tar.gz` | project template |
| `install.sh` | target-detecting installer |
| `SHA256SUMS` | checksums for every archive |

Build them locally with the package hash of the tagged source tarball:

```sh
hash=$(zig fetch https://github.com/barddoo/pgzx/archive/refs/tags/vX.Y.Z.tar.gz | tail -n1)
tools/build-dist.sh --version vX.Y.Z --hash "$hash"
```

`PGZX_TARGETS` limits the target list while iterating, for example
`PGZX_TARGETS="aarch64-macos" tools/build-dist.sh ...`. The script also builds a
host bundle at `dist/cli/`, which is what `install.sh --local` uses.

Test the bundle before tagging:

```sh
prefix=$(mktemp -d)
./install.sh --local dist --prefix "$prefix"
"$prefix/bin/pgzx" version
demo=$(mktemp -d) && (cd "$demo" && "$prefix/bin/pgzx" new demo --no-fetch)
```

Publishing:

1. Push a `vX.Y.Z` tag. `.github/workflows/release.yaml` re-runs `check.yaml`,
   runs `build-dist`, and uploads every `dist/*.tar.gz`, `SHA256SUMS` and
   `install.sh` to the GitHub release.
2. Render `dev/homebrew/pgzx.rb`: set `version` and the four `sha256` values
   from `dist/SHA256SUMS`, then copy it to
   `barddoo/homebrew-tap/Formula/pgzx.rb`.
3. Users install with `brew install barddoo/tap/pgzx` or the release
   `install.sh`. `install.sh` detects the host target; `PGZX_TARGET` overrides
   it for cross-installs.
