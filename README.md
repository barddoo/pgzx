<div align="center">
  <img src="brand-kit/banner/pgzx-banner-github@2x.png" alt="pgzx logo" />
</div>

<p align="center">
  <a href="https://github.com/barddoo/pgzx/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-Apache_2.0-green" alt="License - Apache 2.0"></a>&nbsp;
  <a href="https://github.com/barddoo/pgzx/actions?query=branch%3Amain"><img src="https://github.com/barddoo/pgzx/actions/workflows/check.yaml/badge.svg" alt="CI Build"></a> &nbsp;
</p>


# pgzx - Create Postgres Extensions with Zig!

`pgzx` is a library for developing PostgreSQL extensions written in Zig. It provides utilities (error handling, memory allocators, wrappers) and a development environment that simplify integrating with the Postgres code base.

## Why Zig?

[Zig](https://ziglang.org/) is a small, simple language that aims to be a "modern C" with safe memory management, compile-time execution (comptime), and a rich standard library. It speaks the C ABI, works with C pointers and types directly, and can import and translate C headers — so a Zig extension can do anything a C extension can, with a modern language on top.

In practice you still need to understand a lot of Postgres internals, and Postgres leans on macros that cannot always be translated automatically. pgzx provides the Zig modules for those cases.

## Examples

The following sample extensions (ordered from simple to complex) show how to use pgzx:

| Extension                                  | Description                                                                                                                                                                                                                          |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [char_count_zig](examples/char_count_zig/) | Adds a function that counts how many times a particular character shows up in a string. Shows how to register a function and how to interpret the parameters.                                                                        |
| [pghostname_zig](examples/pghostname_zig/) | Adds a function that returns the database server's host name.                                                                                                                                                                        |
| [sqlfns](examples/sqlfns/)                 | The ways to export a Zig function to SQL: a raw C export, `PG_FUNCTION_V1`, and `PG_EXPORT` for a whole struct or file.                                                                                                              |
| [guc](examples/guc/)                       | Registers custom GUCs (bool, int, string, enum) in `_PG_init`, including a check hook that clamps a value, and reads them back into SQL.                                                                                             |
| [bgworker](examples/bgworker/)             | Registers a static background worker (`pgzx.bgworker.register`) that the postmaster launches on the next server start.                                                                                                               |
| [pg_audit_zig](examples/pgaudit_zig/)      | Inspired by the pgaudit C extension, this one registers callbacks to multiple hooks and uses more advanced error handling and memory allocation patterns.                                                                            |
| [srf](examples/srf/)                       | Port of pgrx-examples/srf. Set-returning functions with `pgzx.srf.SetOf` (`RETURNS SETOF`) and `pgzx.srf.Table` (`RETURNS TABLE`), driven by a plain Zig iterator.                                                                   |
| [arrays](examples/arrays/)                 | Port of pgrx-examples/arrays. Postgres arrays as Zig slices (`[]const i32`, `[]const ?i32`, `text[]`), plus parameter defaults, `VARIADIC` and `pgzx.IntList`.                                                                       |
| [spi_sql](examples/spi_sql/)               | Uses SPI to run SQL statements; the exported functions double as the regression-test fixture.                                                                                                                                        |
| [spi](examples/spi/)                       | Port of pgrx-examples/spi. Queries with arguments, a prepared plan kept for the session, cursors fetched in batches, subtransactions that skip failing rows, and `SECURITY DEFINER`.                                                 |
| [rational](examples/rational/)             | A `rational` base type with btree and hash operator classes. Shows the type system end to end: `pg_type`, operators, `pg_opclass`, casts and how they make indexes and `GROUP BY` work.                                              |
| [file_io](examples/file_io/)               | Backend-safe file I/O through the virtual file descriptor layer (`pgzx.fd`), plus asynchronous VFD reads on PostgreSQL 18 (`pgzx.aio`).                                                                                              |
| [compress_zig](examples/compress_zig/)     | A Timescale-style columnar compression layer: SPI reads a heap table, encodes it into type-aware batches (`plain`, `rle`, `delta`, `delta2`, `gorilla`, `dictionary`, bit-packed bool) in a sidecar relation, and decodes them back. |

## Docs

Documentation lives at **[pgzx.barddoo.com](https://pgzx.barddoo.com/)**:

* [Installation](https://pgzx.barddoo.com/start/install/) — install the `pgzx` command, then scaffold and run an extension.
* [Quickstart](https://pgzx.barddoo.com/start/quickstart/) — scaffold, build, call it from SQL, run the tests.
* [Guides](https://pgzx.barddoo.com/guides/function-manager/) — logging and errors, memory contexts, the function manager, set-returning functions, SQL schema generation, testing.
* [Build system](https://pgzx.barddoo.com/build-system/) — how `build.zig` is wired and how the extension SQL is generated.
* [API reference](https://pgzx.barddoo.com/api/) — the full Zig API, generated with `zig build docs`.

The [examples](examples/) above are the best place to start; each one is a
self-contained package with its own `build.zig`.

## Status

pgzx is under heavy development. Expect breaking changes and potential instability. If you need help, open an issue in this repository.

PostgreSQL 15, 16, 17, 18 and 19 are supported: the examples and unit tests are compiled and run against all five in CI. PostgreSQL 14 is not supported yet.

[ROADMAP.md](ROADMAP.md) tracks the feature status relative to [pgrx](https://github.com/pgcentralfoundation/pgrx):

* **Done** — SQL/DDL generation, set-returning functions, composite and custom types, arrays and int/oid lists, operators and casts, SPI, GUCs, background workers, heap tuple access.
* **In progress** — the remaining Datum conversions (json/jsonb, numeric, inet/cidr, ranges), a generic hook/callback registry, concurrency (latches, dynamic workers, DSM/DSA), and a full FFI error-safety audit.
* **Planned** — triggers, aggregates, `zig build package`, and PostgreSQL 14 support, among other items.

## Contributing

For a complete local development guide — creating a local PostgreSQL install, building, testing, debugging, editor setup, and switching Postgres versions — see [Local environment](https://pgzx.barddoo.com/contributing/environment/).

```
$ zig build cli        # build ./zig-out/bin/pgzx
$ export PATH="$PWD/zig-out/bin:$PATH"
$ eval "$(pgzx env)"   # set PG_HOME/PGHOST for the checkout
$ ./dev/docker/run.sh  # or use the Docker image
```

The examples build and test through each example's `ci/run.sh`; `./ci/run.sh` at the repo root runs all of them.

## Releasing

Releases are cut from a `v*.*.*` tag. The release workflow runs the checks and
`tools/build-dist.sh`, then uploads per-target archives
(`pgzx-cli-<tag>-<target>.tar.gz`), the template archive, `install.sh` and
`SHA256SUMS`. See the
[release guide](https://pgzx.barddoo.com/contributing/debugging/#16-releasing)
for the artifact list, local test steps and the Homebrew formula update.

## See also

* [pgrx](https://github.com/pgcentralfoundation/pgrx) - Similar project but for Rust, it served as an inspiration for this project. 
* [pg_tle](https://github.com/aws/pg_tle) - Trusted Language Extensions for PostgreSQL.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Support

If you have any questions, encounter issues, or need assistance, open an issue in this repository and our community will be happy to help.


<br>
<p align="right">This project is based on the original <a href="https://github.com/xataio/pgzx">pgzx</a> code.</p>
