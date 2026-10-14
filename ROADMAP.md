# pgzx Roadmap

Feature gaps relative to [pgrx](https://github.com/pgcentralfoundation/pgrx), with current status.

Legend: ✅ done · 🚧 partial · ⬜ planned

## Done

- ✅ **SQL/DDL generation** — comptime `pgzx_sql` schema, type→SQL mapping, build step + pg_regress wiring
- ✅ **Set-returning functions** — `SetOf`/`Table` value-per-call iterators with `SETOF`/`TABLE` DDL
- ✅ **Reusable test harness** — `PGBuild`, `pg_regress`, in-server unit tests, `nix flake` template
- ✅ **Composite + custom types** — base types, I/O functions, `pg_type` registration, composite rows
- ✅ **Arrays + int/oid lists** — `[]T`, `text[]`, `IntList`/`OidList`, slist/dlist/htab
- ✅ **GUCs** — `DefineCustom*Variable` wrappers with assign/show hooks
- ✅ **Operators, casts, opclasses** — btree/hash opclasses so custom types are indexable
- ✅ **SPI** — queries, cursors, prepared/saved plans, subtransactions
- ✅ **Function attributes** — defaults, `VARIADIC`, `OUT`/`INOUT`, `SECURITY DEFINER`, `COST`/`ROWS`, `SET`
- ✅ **Heap tuple / relation access** — `HeapTuple`, `TupleDesc`, form/deform

## In progress

- 🚧 **Datum conversions** — text, bytea, uuid, date/time/timestamp/tz, interval, tid, xid, arrays done; json/jsonb, numeric, inet/cidr, range pending
- 🚧 **Hook/callback registry** — manual registration works (`pgaudit_zig`); no generic comptime registry
- 🚧 **Shmem / concurrency** — atomics, spinlocks, lwlocks, shmem, bgworkers; latches, dynamic bgworkers, DSM/DSA pending
- 🚧 **FFI error-safety** — `err.Context`/`pg_try` in place; full audit ongoing

## Planned

- ⬜ **Triggers**
- ⬜ **Aggregates** — also unblocks window + ordered-set aggregates
- ⬜ **`zig build package`**
- ⬜ **PG 14 support** — CI matrix currently covers 15–18

## Later / on demand

- ⬜ Vendored Postgres source
- ⬜ pgzx CLI
- ⬜ WAL decoder / logical replication
- ⬜ Index / table access methods

## Skipped by choice

Rust proc macros, `pgrx_embed`, pgrx's isolated-DB-per-test runner.
