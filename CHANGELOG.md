# Changelog

All notable changes to pgzx are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- PostgreSQL 19 support: the library, examples and CI matrix now cover
  PostgreSQL 15–19. `libpqsrv_connect_complete`, the PG19 `SpinLockFree`
  removal and the `postgres.h`-first translation are handled.
- `pgzx.latch`: typed `my`, `set`, `reset`, `wait` and `waitOrSocket`, returning
  a `Result` with named fields instead of raw wake-event bits.
- `pgzx.bgworker.waitForStartup` and `waitForShutdown` for dynamic workers.
- `pgzx.aggregate`: `stateOrInit` and `toDatum` for `internal` transition state.
- `ddl.AggregateDecl` and `pgzx_sql.aggregates`, rendering `CREATE AGGREGATE`
  with SFUNC, STYPE, FINALFUNC, COMBINEFUNC, SERIALFUNC, DESERIALFUNC,
  INITCOND and PARALLEL.
- `pgzx.dsm`: dynamic shared memory segments (create, attach, detach, pin).
- `pgzx.dsa`: dynamic shared areas (create, attach, allocate, free, address),
  with `newTranche` to register the LWLock tranche.
- `pgzx.hooks.Hook`: chaining for hook variables such as `ExecutorStart_hook`.
  `install` once per hook point per binary; `callNext` runs the previous hook or
  the standard function.
- `pgzx.lwlock`: `acquire`, `tryAcquire`, `release` and `hold` (a guard for
  `defer`).
- `pgzx.fdw.routine` and `pgzx.fdw.handler`: build an `FdwRoutine` table from
  typed callback declarations. Callbacks that are not declared stay NULL.
- Range types: `int4range`, `int8range`, `numrange`, `tsrange`, `tstzrange` and
  `daterange`, through `pgzx.range` (`Range(T)`, `Int4Range`, `Int8Range`,
  `TextRange`) and the matching `datum` converters. `numrange`, `tsrange`,
  `tstzrange` and `daterange` use wrapper types with a `value` field.
- `zig build package`: writes `pgzx-<version>.tar.gz` and PGXN `META.json` to
  `zig-out/package/`.
- `pgzx` command implemented as a Zig binary (`src/cli`, built with
  `zig build cli`): `new`, `env`, `init`, `start`, `stop`, `status`, `doctor`,
  `fingerprint` and `version`. Works from a checkout and from an installed
  bundle; `pgzx new` supports `--template`, `--pgzx-ref` and `--no-fetch`, and
  pins the dependency URL and hash.
- `pgzx init` prints the created cluster (data directory, socket, log, port,
  user, database) and the next commands, and accepts `--force`/`-f` to delete
  an existing cluster before recreating it. Without `--force` it refuses to
  overwrite one.
- `pgzx env [cluster]` writes `PGDATA`, `PGPORT`, `PGUSER`, `PGDATABASE` and
  `PGZX_CLUSTER` from the cluster's `cluster.conf`, so `psql` and `pg_ctl` need
  no flags. `start`/`stop`/`status` take the same optional cluster name and fall
  back to `PGZX_CLUSTER`, then `postgres`.
- `pgzx init`, `start` and `doctor` reject unix socket paths longer than the
  platform's `sun_path` (107 bytes on Linux, 103 on macOS) and suggest
  `PG_SOCKET_DIR`.
- `templates/default`: project template with `Makefile` and `.envrc`.
- Documentation site: an Astro/Starlight project in `docs/`, published at
  <https://pgzx.barddoo.com/>, with installation, guides, the build system and
  contributing pages, and the Zig Autodoc reference at `/api/`.
- `install.sh` and `tools/build-dist.sh`: per-target release bundles
  (`pgzx-cli-<tag>-<target>.tar.gz`, `pgzx-template-<tag>.tar.gz`,
  `SHA256SUMS`) with the CLI cross-compiled for macOS (aarch64/x86_64) and Linux
  (aarch64/x86_64, static musl), and the templates stamped to the release tag
  and package hash.
- `dev/docker/install-zig.sh` installs Zig on macOS as well as Linux, falls back
  to the `index.json` checksum when minisign is unavailable, and accepts an
  install prefix.
- Examples: `examples/aggregate` (`geomean`). `examples/bgworker` now includes a
  dynamic worker round trip and a value passed through a DSM segment.

### Changed

- The default PostgreSQL version is now 19: the Docker image and Compose
  service, the CI end-to-end jobs, the documentation and `pgzx doctor` all
  point at PostgreSQL 19. The test matrix still covers 15–19.
- `pgzx.bgworker.registerDynamic` sets `bgw_notify_pid` to the calling backend.
  Without it, `WaitForBackgroundWorker*` never returned.
- `pgzx.pq` `waitReady` uses the latch wrapper and reports postmaster death.
- `examples/pgaudit_zig` uses `pgzx.hooks`. `ExecutorFinish` now calls
  `standard_ExecutorFinish` and no longer skips the rest of the finish
  processing. The permission hook still allows and leaves the checks to
  PostgreSQL.
- `pgzx.varatt` is documented as internal, with an accurate test status.
- Cluster state honours `PGZX_CLUSTER_DIR` and `PG_SOCKET_DIR`, so it no longer
  has to live inside the PostgreSQL installation prefix.
- `eval "$(pgzx env)"` now also exports the cluster's `PGUSER` and `PGDATABASE`
  (default `postgres`), so a bare `psql` connects to the project cluster instead
  of using the OS user.
- `zig build docs` now only installs the Autodoc bundle into
  `zig-out/share/pgzx/docs`; it no longer copies it into `./docs`, which holds
  the site sources. The site's `bun run build` merges the bundle into
  `dist/api`.
- The release workflow also builds and publishes the docs site, so a broken docs
  build blocks a release.

### Removed

- The shell implementation of the CLI and its helpers: `dev/bin/pgzx`,
  `pgzx-new`, `pginit`, `pgenv`, `pgstart`, `pgstop` and `pgstatus`.
  `pgzx` is now a single Zig binary.
- `dev/bin/pglocal` and `dev/bin/pguse`; the cluster now lives in
  `<project>/out/pg` and `PG_CONFIG` selects the PostgreSQL version.
- `tools/check-templates.sh`; there is a single template.
- `zig build serve_docs`; the site's `bun run dev` serves both the prose and the
  API bundle. `HACKING.md` and `docs/BUILD.md` moved into the site.

### Fixed

- Cluster creation no longer requires a writable PostgreSQL prefix: `pgzx init`
  writes to `PGZX_CLUSTER_DIR` and prints the fix instead of failing with a bare
  permission error. Also fixes the Docker workflow on `postgresql-server-dev`.
- `datum`: `dupeZ` calls replaced with `dupeSentinel`, which Zig 0.17 provides.
- `datum`: the `json` round-trip test expected `jsonb` formatting. The `json`
  type stores its input text, so the expected value is `{"a":1}`.
- `examples/pgaudit_zig` aborted the backend when a query failed. The cleanup
  callback was registered on the event's own context, so a failed
  `ExecutorStart` left the event in the list and a later cleanup deleted a
  context twice. The callback now registers on the event's context before
  `ExecutorStart` and only removes the event from the list.

### Known issues

- The FDW scan and modify callbacks have no example extension yet.
- Hook registration is process-local and cannot be uninstalled. PostgreSQL does
  not call `_PG_fini`.

## [0.1.0]

Initial release.

- Zig bindings and helpers for PostgreSQL extensions: fmgr, datum conversions,
  SPI, SRF, triggers, heap tuples, collections, GUCs, shared memory, spinlocks,
  atomics, error handling and the DDL generator (`pgzx_sql`).
- Build integration: `pgzx.Build` for extensions, pg_regress and unit test
  steps, and `zig build docs`.
- Examples: `arrays`, `bgworker`, `char_count_zig`, `compress_zig`, `file_io`,
  `guc`, `pghostname_zig`, `pgaudit_zig`, `rational`, `spi`, `spi_sql`, `srf` and
  `sqlfns`.
