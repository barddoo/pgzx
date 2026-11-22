---
title: Installation
---

You need **Zig 0.17+** and **PostgreSQL 15–19 with development headers**
(`postgresql-server-dev-NN` on Debian/Ubuntu, `postgresql@NN` on Homebrew).

## Install the `pgzx` command

Prebuilt commands are published for macOS (Apple silicon and Intel) and Linux
(x86_64 and aarch64, statically linked).

**Any platform**: the release installer picks the binary for your OS and
architecture and verifies it against the release checksum. It accepts
`--prefix DIR` (default `~/.local`) and `--with-zig`:

```sh
curl -fsSL https://github.com/barddoo/pgzx/releases/latest/download/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
```

**macOS, with Homebrew:**

```sh
brew install barddoo/tap/pgzx
```

The tap formula is updated by hand after each release, so it can lag the latest
tag; the installer above always fetches the current release.

**From source** (needs Zig and PostgreSQL headers):

```sh
zig build cli
./zig-out/bin/pgzx version
```

Then create and run an extension:

```sh
pgzx doctor
pgzx new my_extension
cd my_extension
eval "$(pgzx env)"
pgzx init && pgzx start
zig build -p "$PG_HOME"
psql -U postgres -c 'CREATE EXTENSION my_extension'
psql -U postgres -c 'SELECT hello()'
```

**With Docker** (nothing installed on the host):

```sh
docker build -f dev/docker/Dockerfile.standalone -t pgzx-standalone .
docker run -it --rm -v "$PWD:/work" -w /work pgzx-standalone
```

Both the native flow and the Docker image produce a working extension named
`my_extension` exporting a `hello()` function.

The generated [README](https://github.com/barddoo/pgzx/blob/main/templates/default/README.md) covers tests, the
development loop and renaming the project. For a complete local setup guide see
[Local environment](/contributing/environment/).

`pgzx env` derives the project environment from `pg_config`: `PG_HOME` is the
PostgreSQL install prefix and cluster state lives in `./out/pg`, so nothing is
written into the PostgreSQL installation.
