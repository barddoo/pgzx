#!/usr/bin/env bash

set -e
set -x
set -o pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

# Build the CLI, point PG_HOME/PGZX_CLUSTER_DIR at the pg_config selected by
# PG_CONFIG (or the one on PATH), and initialize its cluster. The cluster lives
# in <project>/out/pg, outside the PostgreSQL prefix.
zig build cli
eval "$(./zig-out/bin/pgzx env)"
./zig-out/bin/pgzx init
