# Changelog

All notable changes to pgzx are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

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
- `dev/bin/pgzx-new <name> [dir]`: scaffolds a new extension from the init
  template without Nix.
- Examples: `examples/aggregate` (`geomean`). `examples/bgworker` now includes a
  dynamic worker round trip and a value passed through a DSM segment.

### Changed

- `pgzx.bgworker.registerDynamic` sets `bgw_notify_pid` to the calling backend.
  Without it, `WaitForBackgroundWorker*` never returned.
- `pgzx.pq` `waitReady` uses the latch wrapper and reports postmaster death.
- `examples/pgaudit_zig` uses `pgzx.hooks`. `ExecutorFinish` now calls
  `standard_ExecutorFinish` and no longer skips the rest of the finish
  processing. The permission hook still allows and leaves the checks to
  PostgreSQL.
- `pgzx.varatt` is documented as internal, with an accurate test status.

### Fixed

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
