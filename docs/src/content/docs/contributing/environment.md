---
title: Local environment
---

How to get a working Zig and PostgreSQL toolchain, a throwaway cluster, and the
project environment loaded into your shell.

## 1. Prerequisites

- **Zig 0.17 or newer**: [ziglang.org/download](https://ziglang.org/download/).
- **PostgreSQL 15–19** with development headers. Debian/Ubuntu:
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

### Option A: Homebrew (macOS)

```sh
brew install postgresql@18 openssl@3 krb5 zig
brew link --force postgresql@18
```

Homebrew has no `postgresql@19` formula yet; 18 is the newest available there.
For 19, use the Docker image or the PGDG packages on Linux. Homebrew prefixes are
owned by your user, so installing the extension into PostgreSQL needs no elevated
permissions.

### Option B: Raw install (Linux)

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
PG_MAJOR=19   # or 15 / 16 / 17 / 18
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

### Option C: Docker (nothing installed on the host)

```sh
# Build once (~3 min; cached afterwards). Pick a PostgreSQL version if needed.
docker build \
  --build-arg PG_MAJOR=19 \
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
pick a PostgreSQL version (see [12](/contributing/build-and-test/#12-switch-postgresql-versions)).

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
| `pgzx env [cluster]`              | Print the project environment             |
| `pgzx init` / `start` / `stop` / `status` | Control the local cluster          |
| `pgzx doctor`                     | Check Zig, PostgreSQL and headers         |
| `pgzx fingerprint`                | Refresh the package fingerprint           |

## 3. Create the local PostgreSQL cluster

```sh
eval "$(pgzx env)"
pgzx init        # initdb + create the 'postgres' superuser
pgzx start       # start the server
pgzx status      # show the server status
psql -c 'select version()'   # PGUSER/PGDATABASE come from pgzx env
pgzx stop        # stop the server
```

`pgzx init` ends by printing the cluster's data directory, socket, log file,
port, user and database, plus the next commands to run.

Notes:

- Cluster state lives in `<project>/out/pg/postgres`; it is independent of the
  PostgreSQL installation, so a read-only system prefix works. `rm -rf out/pg`
  resets the project's clusters.
- `pgzx env` exports `PGHOST`, `PGDATA`, `PGPORT`, `PGUSER`, `PGDATABASE` and
  `PGZX_CLUSTER` from `<cluster>/cluster.conf` (written by `init`), so `psql`
  and `pg_ctl` work without extra flags. Pass a cluster name to select one:
  `eval "$(pgzx env mytest)"`.
- `pgzx init` accepts optional arguments:
  ```sh
  pgzx init <cluster> <database> <user>
  pgzx init -p 5433                    # custom port
  pgzx init -s pg_stat_statements      # shared_preload_libraries
  pgzx init -i path/to/sql/dir         # run *.sql on init
  pgzx init -c path/to/postgresql.conf # custom config
  pgzx init --force                    # delete the cluster and recreate it
  ```
  `init` refuses to overwrite an existing cluster unless `--force` is given;
  `--force` stops the server (if running) and deletes `<cluster base>/<cluster>`.
- The Unix socket lives in `out/pg/run` (not the compiled-in
  `/run/postgresql`), and `PGHOST` points at it. Socket paths are limited by
  `sun_path` (107 bytes on Linux, 103 on macOS), so `init`, `start` and
  `doctor` reject an over-long path; set `PG_SOCKET_DIR=/tmp/pgzx-<cluster>` to
  shorten it.
- Server logs are written to `out/pg/postgres/log/server.log`.
- `PGZX_CLUSTER_DIR` moves the cluster state and `PG_SOCKET_DIR` moves the
  socket; `pgzx env` sets both under `<project>/out/pg` by default.
- `start`, `stop` and `status` use the cluster name argument, else
  `PGZX_CLUSTER`, else `postgres`.

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
| `PGDATA`              | `<cluster>/data`        | data directory of the selected cluster       |
| `PGPORT`              | `cluster.conf`          | port of the selected cluster                 |
| `PGUSER`              | `cluster.conf`          | role `init` created (`postgres`)             |
| `PGDATABASE`          | `cluster.conf`          | database `init` created (`postgres`)         |
| `PGZX_CLUSTER`        | resolved cluster name   | cluster used when a command omits the name   |
| `PGZX_CLUSTER_DIR`    | `<project>/out/pg`      | cluster state                                 |
| `PG_SOCKET_DIR`       | `$PGZX_CLUSTER_DIR/run` | Unix socket directory used by the server     |
| `PGZX_C_INCLUDE_DIRS` | Homebrew paths          | extra C headers for the header translation   |
| `ZIG_LOCAL_CACHE_DIR` | `~/.cache/zig-pgzx`     | shared Zig cache for the whole repo          |
| `PG_CONFIG`           | optional                | `pg_config` to use (default: `pg_config`)    |

To work against a specific installation, point `PG_CONFIG` at its `pg_config`
before evaluating `pgzx env`.
