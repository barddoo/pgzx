<div align="center">
  <img src="brand-kit/banner/pgzx-banner-github@2x.png" alt="pgzx logo" />
</div>

<p align="center">
  <a href="https://github.com/xataio/pgzx/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-Apache_2.0-green" alt="License - Apache 2.0"></a>&nbsp;
  <a href="https://github.com/xataio/pgzx/actions?query=branch%3Amain"><img src="https://github.com/xataio/pgzx/actions/workflows/check.yaml/badge.svg" alt="CI Build"></a> &nbsp;
  <a href="https://xata.io/discord"><img src="https://img.shields.io/discord/996791218879086662?label=Discord" alt="Discord"></a> &nbsp;
  <a href="https://twitter.com/xata"><img src="https://img.shields.io/twitter/follow/xata?style=flat" alt="X (formerly Twitter) Follow" /> </a>
</p>


# pgzx - Create Postgres Extensions with Zig!

`pgzx` is a library for developing PostgreSQL extensions written in Zig. It provides utilities (error handling, memory allocators, wrappers) and a development environment that simplify integrating with the Postgres code base.

## Why Zig?

[Zig](https://ziglang.org/) is a small, simple language that aims to be a "modern C" with safe memory management, compile-time execution (comptime), and a rich standard library. It speaks the C ABI, works with C pointers and types directly, and can import and translate C headers — so a Zig extension can do anything a C extension can, with a modern language on top.

In practice you still need to understand a lot of Postgres internals, and Postgres leans on macros that cannot always be translated automatically. pgzx provides the Zig modules for those cases.

## Examples

The following sample extensions (ordered from simple to complex) show how to use pgzx:

| Extension                                  | Description |
|--------------------------------------------|-------------|
| [char_count_zig](examples/char_count_zig/) | Adds a function that counts how many times a particular character shows up in a string. Shows how to register a function and how to interpret the parameters. |
| [pghostname_zig](examples/pghostname_zig/) | Adds a function that returns the database server's host name. |
| [pg_audit_zig](examples/pgaudit_zig/)      | Inspired by the pgaudit C extension, this one registers callbacks to multiple hooks and uses more advanced error handling and memory allocation patterns. |
| [rational](examples/rational/)             | A `rational` base type with btree and hash operator classes. Shows the type system end to end: `pg_type`, operators, `pg_opclass`, casts and how they make indexes and `GROUP BY` work. |
| [arrays](examples/arrays/)                 | Port of pgrx-examples/arrays. Postgres arrays as Zig slices (`[]const i32`, `[]const ?i32`, `text[]`), plus parameter defaults, `VARIADIC` and `pgzx.IntList`. |
| [spi](examples/spi/)                       | Port of pgrx-examples/spi. Queries with arguments, a prepared plan kept for the session, cursors fetched in batches, subtransactions that skip failing rows, and `SECURITY DEFINER`. |

## Docs

The reference documentation is available at [here](https://xataio.github.io/pgzx/#docs.pgzx). The examples above are the best place to start; the sections below walk through the most important utilities.

### Getting Started

This project uses [Nix flakes](https://nixos.wiki/wiki/Flakes) to manage build dependencies and provide a development shell. A template bootstraps a new extension:

```
$ mkdir my_extension
$ cd my_extension
$ nix flake init -t github:xataio/pgzx
```

This creates a working extension named `my_extension` exporting a `hello()` function. Its [README](./nix/templates/init/README.md) explains how to enter the shell, build, and test it. Rename the project by updating the files in `extension/` and replacing `my_extension` in `README.md`, `build.zig`, `build.zig.zon`, and the extension SQL file.

The development shell sets the environment used by the project (see [devshell.nix](./devshell.nix)): `PRJ_ROOT` is the project folder, and `PG_HOME` is the Postgres install prefix (the shell relocates Postgres into `./out` and points `./out/default` at the active version). For a complete local setup guide see [HACKING.md](HACKING.md).

### Logging and error handling

Postgres [error reporting functions](https://www.postgresql.org/docs/current/error-message-reporting.html) provide log levels, formatting, and errors that can be thrown and caught like exceptions. pgzx wraps them for Zig.

Simple logging uses [Log][docs_Log], [Info][docs_Info], [Notice][docs_Notice] or [Warning][docs_Warning]:

```zig
elog.Info(@src(), "input_text: {s}\n", .{input_text});
```

The `@src()` built-in records the file location in the error report.

To report errors, use [Error][docs_Error] (returns a Zig error) or [ErrorThrow][docs_ErrorThrow] (throws a Postgres error report):

```zig
if (target_char.len > 1) {
    return elog.Error(@src(), "Target char is more than one byte", .{});
}
```

The module also exposes the C-style API (`ereport`, `errcode`, `errmsg`, ...).

Postgres handles errors with `longjmp`, which can skip Zig `defer`/`errdefer` cleanup. pgzx provides a Zig alternative to `PG_TRY`:

```zig
var errctx = pgzx.err.Context.init();
defer errctx.deinit();
if (errctx.pg_try()) {
    // Zig code that calls Postgres C functions.
} else {
    return errctx.errorValue();
}
```

This catches errors raised by Postgres functions and returns them as Zig errors, so all `defer`/`errdefer` in the callers run. The [wrap][docs_wrap] helper packages this pattern:

```zig
try pgzx.err.wrap(myFunction, .{arg1, arg2});
```

See [pgzx.err.Context][docs_Context] for details.

### Memory context allocators

Postgres uses a [memory context system](https://github.com/postgres/postgres/blob/master/src/backend/utils/mmgr/README): allocations belong to a context, and freeing a context frees everything in it at once. Contexts are hierarchical, so a child context is freed with its parent.

pgzx wraps contexts as Zig allocators. [createAllocSetContext][docs_createAllocSetContext] returns a [MemoryContextAllocator][docs_MemoryContextAllocator]:

```zig
var memctx = try pgzx.mem.createAllocSetContext("zig_context", .{ .parent = pg.CurrentMemoryContext });
const allocator = memctx.allocator();
```

`pg.CurrentMemoryContext` is the context of the running query, so memory allocated with `allocator` is freed when the query finishes. You can also register a callback for when a context is reset or deleted, to release resources tied to it:

```zig
try memctx.registerAllocResetCallback(
    queryDesc.*.estate.*.es_query_cxt,
    pgaudit_zig_MemoryContextCallback,
);
```

### Function manager

Register Zig functions so they can be called from SQL with [PG_FUNCTION_V1][docs_PG_FUNCTION_V1]:

```zig
comptime {
    pgzx.PG_FUNCTION_V1("my_function", myFunction);
}
```

Parameters are received from Postgres serialized, and pgzx deserializes them into Zig types automatically.

### SQL schema generation

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

| Option       | Meaning                                                                 |
| ------------ | ----------------------------------------------------------------------- |
| `name`       | SQL function name (required).                                            |
| `func`       | The Zig function (required).                                             |
| `volatility` | `pgzx.ddl.Volatility`: `.@"volatile"` (default), `.stable`, `.immutable`. |
| `strict`     | Emit `STRICT` (default `false`).                                         |
| `parallel`   | `pgzx.ddl.Parallel`: `.unsafe`, `.restricted`, `.safe`.                  |
| `args`       | Override argument SQL types, e.g. `&.{"text", "integer"}`.               |
| `returns`    | Override the return SQL type.                                            |
| `comment`    | Emit a `COMMENT ON FUNCTION`.                                            |

Use `args`/`returns` for signatures with no direct SQL mapping, such as raw `pg.Datum` arguments. Keep `PG_FUNCTION_V1`/`PG_EXPORT` in `main.zig`, not in the schema module: the generator is linked as a standalone executable and cannot resolve Postgres server symbols. Objects that are not `CREATE FUNCTION` (types, operators, operator classes, casts) go in a source-level `catalog.sql`, which the generator appends after the functions. See `examples/rational` and `examples/sqlfns` for the complete pattern.

### Testing your extension

pgzx provides `pg_regress` tests and in-server unit tests, set up through the `PGBuild.Project` build helper:

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

`addSteps` creates the `check`, `install`, `pg_regress` (when `.pg_regress` is set) and `unit` (when `.unit` is set) build steps, and defines the `build_options` module that gates `testfn`.

[pg_regress tests](https://www.postgresql.org/docs/current/regress.html) work like they do for C extensions: inputs go in `sql/`, expected outputs in `expected/`, and run with:

```sh
zig build pg_regress
```

Unit tests run inside Postgres, so they compile in the same environment as the tested code and can call Postgres APIs. Each function whose name starts with `test` in a registered test suite is a unit test:

```zig
comptime {
    pgzx.testing.registerTests(@import("build_options").testfn, .{Tests});
}
```

`registerTests` may only be called once per extension; pass multiple suites in the array. Run the tests with:

```sh
zig build unit -p $PG_HOME
```

This builds a dedicated `{name}_unit` library with `testfn = true`, deploys it, and calls `SELECT run_tests();`. The separate library name means the test build never collides with the production extension.

## Status/Roadmap

pgzx is under heavy development by the [Xata](https://xata.io) team. Expect breaking changes and potential instability. If you need help, join us on the [Xata discord](https://xata.io/discord).

* Utilities
  * [x] Postgres versions (compile and test)
    * [x] Postgres 15
    * [x] Postgres 16
    * [x] Postgres 17
    * [x] Postgres 18
    * [ ] Postgres 14
  * [x] Logging
  * [x] Error handling
  * [x] Memory context allocators
  * [x] Function manager
  * [x] SQL/DDL generation
  * [x] Background worker process
  * [x] LWLocks
  * [x] Signals and interrupts
  * [x] String formatting
  * [x] Shared memory
  * [x] SPI
  * [x] GUCs (custom variables)
  * Postgres data structure wrappers:
    * Array based list (List)
      * [x] Pointer list
      * [ ] int list
      * [ ] oid list
      * ...
    * [x] Single list
    * [x] Double list
    * [x] Hash tables
* Development environment
  * [ ] Download and vendor Postgres source code
  * [x] Compile example extensions against the Postgres source code
  * [x] Build target to run Postgres regression tests
  * [x] Run unit tests in the Postgres environment
  * [x] Provide a standard way to test extensions from separate repos
* Packaging
  * [x] Add support for Zig packaging

## Contributing

For a complete local development guide — creating a local PostgreSQL install, building, testing, debugging, editor setup, and switching Postgres versions — see [HACKING.md](HACKING.md).

```
$ nix develop          # enter the development shell
$ ./dev/docker/run.sh  # or use the docker development shell
```

The examples build and test through each example's `ci/run.sh`; `./ci/run.sh` at the repo root runs all of them.

## See also

* [pgrx](https://github.com/pgcentralfoundation/pgrx) - Similar project but for Rust, it served as an inspiration for this project. 
* [pg_tle](https://github.com/aws/pg_tle) - Trusted Language Extensions for PostgreSQL.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Support

If you have any questions, encounter issues, or need assistance, open an issue in this repository or join our [Discord](https://xata.io/discord), and our community will be happy to help.


<br>
<p align="right">Made with :heart: by <a href="https://xata.io">Xata 🦋</a></p>


[docs_Log]: https://xataio.github.io/pgzx/#A;pgzx:elog.Log
[docs_Info]: https://xataio.github.io/pgzx/#A;pgzx:elog.Info
[docs_Notice]: https://xataio.github.io/pgzx/#A;pgzx:elog.Notice
[docs_Warning]: https://xataio.github.io/pgzx/#A;pgzx:elog.Warning
[docs_Error]: https://xataio.github.io/pgzx/#A;pgzx:elog.Error
[docs_ErrorThrow]: https://xataio.github.io/pgzx/#A;pgzx:elog.ErrorThrow
[docs_Context]: https://xataio.github.io/pgzx/#A;pgzx:err.Context
[docs_wrap]: https://xataio.github.io/pgzx/#A;pgzx:err.wrap
[docs_createAllocSetContext]: https://xataio.github.io/pgzx/#A;pgzx:mem.createAllocSetContext
[docs_MemoryContextAllocator]: https://xataio.github.io/pgzx/#A;pgzx:mem.MemoryContextAllocator
[docs_PG_FUNCTION_V1]: https://xataio.github.io/pgzx/#A;pgzx:PG_FUNCTION_V1
