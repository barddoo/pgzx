My Extension
============

A PostgreSQL extension written in Zig with [pgzx](https://github.com/barddoo/pgzx).
The `pgzx` command and your system toolchain provide everything.

## Prerequisites

- **Zig 0.17 or newer** — https://ziglang.org/download/
- **PostgreSQL 15–19 with development headers**
  - Debian/Ubuntu: `sudo apt install postgresql-19 postgresql-server-dev-19 libssl-dev libkrb5-dev`
  - macOS: `brew install postgresql@19 openssl@3 krb5 && brew link --force postgresql@19`
- **pgzx** — `brew install barddoo/tap/pgzx`, or run the install script from the
  [releases page](https://github.com/barddoo/pgzx/releases/latest).

Check everything before you start:

```
$ pgzx doctor
```

## Development

1. Load the project environment (or run `direnv allow` once):

```
$ eval "$(pgzx env)"
```

2. Create and start the local PostgreSQL cluster. The state lives in `out/pg`,
   so it never writes into the PostgreSQL installation:

```
$ pgzx init
$ pgzx start
```

3. Build and install the extension into the local cluster:

```
$ zig build -p "$PG_HOME"
```

4. Create the extension and call it:

```
$ psql -U postgres -c 'CREATE EXTENSION my_extension'
$ psql -U postgres -c 'SELECT hello()'
```

5. Run the tests:

```
$ zig build -p "$PG_HOME" unit   # in-server unit tests
$ zig build pg_regress           # SQL regression tests
```

6. Stop the server:

```
$ pgzx stop
```

## Using `make`

The `Makefile` wraps the commands above, with the environment loaded for you:

```
$ make build      # zig build
$ make install    # zig build -p "$PG_HOME"
$ make test       # zig build pg_regress
$ make unit       # zig build -p "$PG_HOME" unit
$ make start      # pgzx start
$ make stop       # pgzx stop
```

## Layout

```
build.zig                       build definition
build.zig.zon                   pgzx dependency (pinned by `pgzx new`)
src/main.zig                    extension code
extension/my_extension.control  extension metadata
extension/my_extension--0.1.sql SQL objects
sql/ and expected/              pg_regress tests
```

## Renaming the project

Replace `my_extension` in `extension/`, `sql/`, `expected/`, `build.zig`,
`build.zig.zon`, and `README.md`.
