#!/usr/bin/env bash
# One entry point for the local dev loop.
#
#   scripts/dev.sh pginit     build pgzx CLI, then initialise a local cluster (first-time setup)
#   scripts/dev.sh build      build the pgzx library + CLI
#   scripts/dev.sh start      start the local cluster
#   scripts/dev.sh stop       stop it
#   scripts/dev.sh test       run pgzx unit + zig tests (no examples)
#   scripts/dev.sh ci         full CI suite (all examples + tests)
#
# Environment:
#   PG_HOME      Postgres install prefix with bin/pg_config
#                (default: brew postgresql@18 if available, else brew postgresql@17, else out/pg)
#   PGPORT       port   (default: set by pgzx env)
#   PGUSER       role   (default: set by pgzx env)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

_brew_pg() {
    for v in 19 18 17 16; do
        local p
        p=$(brew --prefix "postgresql@$v" 2>/dev/null) || continue
        [[ -x "$p/bin/pg_config" ]] && echo "$p" && return
    done
}

if [[ -z "${PG_HOME:-}" ]]; then
    PG_HOME=$(_brew_pg || true)
fi

_ensure_cli() {
    [[ -x "$root/zig-out/bin/pgzx" ]] || zig build cli
}

_load_env() {
    _ensure_cli
    if [[ -n "${PG_HOME:-}" ]]; then
        export PG_CONFIG="$PG_HOME/bin/pg_config"
    fi
    eval "$("$root/zig-out/bin/pgzx" env)"
    export PATH="$root/zig-out/bin:$PATH"
}

cmd_pginit() {
    _load_env
    if [[ -f "${PGDATA:-}/PG_VERSION" ]]; then
        echo "cluster already exists at $PGDATA"
        return
    fi
    pgzx init
    echo "initialised cluster at $PGDATA"
}

cmd_build() {
    zig build
    _ensure_cli
    echo "build ok"
}

cmd_start() {
    _load_env
    pgzx status >/dev/null 2>&1 && { echo "already running"; return; }
    pgzx start
}

cmd_stop() {
    _load_env
    pgzx status >/dev/null 2>&1 || { echo "not running"; return; }
    pgzx stop
}

cmd_test() {
    _load_env
    zig build test --summary all
    zig build -p "$PG_HOME" unit
}

cmd_ci() {
    _load_env
    pgzx init 2>/dev/null || true
    exec "$root/ci/run.sh"
}

case "${1:-}" in
    pginit) cmd_pginit ;;
    build)  cmd_build ;;
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    test)   cmd_test ;;
    ci)     cmd_ci ;;
    *) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
