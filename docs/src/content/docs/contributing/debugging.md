---
title: Debugging, CI and releasing
---

Attaching a debugger to a backend, editor setup, the CI scripts, troubleshooting
and the release process.

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

- `Attach to Postgres backend`: prompts for the PID and attaches.
- `Attach to Postgres backend (unit tests)`: same, but runs the
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

### Testing Zig code with LLDB

[@jacobly0](https://github.com/jacobly0) maintains a fork of LLDB with Zig
support: <https://github.com/jacobly0/llvm-project/tree/lldb-zig>.

The fork only contains changes for debugging programs compiled by Zig's
self-hosted backends, i.e. `zig build-exe -fno-llvm ...`. Extensions built with
Zig's LLVM backend (the default) are better served by vanilla LLDB built against
the LLVM version your Zig uses.

To build the fork, install the prerequisites, then:

```sh
cmake llvm -G Ninja -B build \
  -DLLVM_ENABLE_PROJECTS="clang;lldb" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  -DLLDB_ENABLE_LIBEDIT=ON \
  -DLLDB_ENABLE_PYTHON=ON
cmake --build build --target lldb --target lldb-server
```

You may need to configure dependencies manually if CMake cannot find them. Once
built, run `./build/bin/lldb`.

#### Pretty printers

If you are debugging the Zig compiler itself, or anything compiled with Zig's
LLVM backend, `lldb/pretty_printers.py` in Zig's installed `lib` directory gives
a better experience. Add this to `~/.lldbinit`:

```text
command script import /path/to/zig/lib/lldb/pretty_printers.py
```

For a Zig compiler built with the self-hosted backends:

```text
type category enable zig.compiler
```

For Zig's LLVM backend (with the fork, which is not recommended; prefer vanilla
LLDB matching Zig's LLVM version):

```text
type category enable zig.lang
type category enable zig.std
```

And when debugging a Zig compiler built with the LLVM backend *without* the
fork:

```text
type category enable zig
```

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
15–19, plus end-to-end jobs and a release gate (`release.yaml` calls
`check.yaml`):

- `lint`: shellcheck, shfmt and actionlint (the same tools as the local
  `.pre-commit-config.yaml`).
- `test`: the repo's `ci/setup.sh`/`ci/run.sh` on every supported PostgreSQL
  version.
- `linux`: installs the release bundle with `install.sh --local`, then
  scaffolds, builds, and runs unit + regression tests.
- `macos`: Homebrew PostgreSQL 19 + Zig, runs `pgzx doctor` and compiles the
  template.
- `templates`: scaffolds the template and asserts the release stamping writes
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
