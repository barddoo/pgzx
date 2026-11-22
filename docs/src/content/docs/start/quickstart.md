---
title: Quickstart
description: Scaffold, build and run a pgzx extension in five commands.
---

This walks through the project `pgzx new` generates. For installing the `pgzx`
command and PostgreSQL itself, see [Installation](/start/install/).

## Scaffold and start

```sh
pgzx doctor                 # check Zig, pg_config, headers, writable dirs
pgzx new my_extension
cd my_extension
eval "$(pgzx env)"          # or: direnv allow
pgzx init && pgzx start     # throwaway cluster in ./out/pg
zig build -p "$PG_HOME"     # install into the running PostgreSQL
```

`pgzx env` derives `PG_HOME` from `pg_config` and keeps cluster state in
`./out/pg`, so nothing is written into the PostgreSQL installation. It also
exports `PGDATA`, `PGPORT`, `PGUSER` and `PGDATABASE` from the cluster that
`init` created, so `psql` needs no connection flags.

## Call it from SQL

```sh
psql -U postgres -c 'CREATE EXTENSION my_extension'
psql -U postgres -c 'SELECT hello()'
```

`CREATE EXTENSION` works because `-p "$PG_HOME"` installed the `.so`, the control
file and the generated SQL script into the server's `lib` and
`share/postgresql/extension` directories.

## Where the code lives

The template splits an extension into three files:

```text
src/
  functions.zig   pure function definitions; no exports, no registration
  schema.zig      the pgzx_sql declaration; imports functions.zig
  main.zig        PG_MODULE_MAGIC, PG_FUNCTION_V1, PG_EXPORT, raw C exports
```

`main.zig` is what PostgreSQL loads. `schema.zig` is read at build time by the
SQL generator, which derives each `CREATE FUNCTION` from the Zig signature. A
minimal extension therefore looks like this:

```zig
// src/functions.zig
pub fn hello() ![:0]const u8 {
    return "Hello, world!";
}
```

```zig
// src/schema.zig
const functions = @import("functions.zig");

pub const pgzx_sql = .{
    .functions = .{
        .{ .name = "hello", .func = functions.hello },
    },
};
```

```zig
// src/main.zig
const pgzx = @import("pgzx");
const functions = @import("functions.zig");

comptime {
    pgzx.PG_MODULE_MAGIC();
    pgzx.PG_FUNCTION_V1("hello", functions.hello);
}
```

The reasoning behind the split, and the full set of schema fields and build
steps, is in [Build system](/build-system/). A complete worked example is in
the [appendix](/build-system/#appendix-complete-minimal-example).

## Run the tests

```sh
zig build pg_regress                          # sql/ against expected/
zig build -p "$PG_HOME" unit                  # in-server unit tests
```

`pgzx stop` shuts the cluster down. For the development loop, debugging and
PostgreSQL version switching, see
[Build, test and ship](/contributing/build-and-test/).
