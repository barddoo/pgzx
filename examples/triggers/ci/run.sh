#!/usr/bin/env bash

set -o pipefail

EXTENSION_NAME=triggers

build() {
    echo "Build extension $EXTENSION_NAME"
    zig build -freference-trace -p "$PG_HOME" || return 1
}

create_extension() {
    echo "Create extension $EXTENSION_NAME"
    psql -U postgres -c "CREATE EXTENSION IF NOT EXISTS $EXTENSION_NAME"
}

extension_drop() {
    echo "Drop extension $EXTENSION_NAME"
    psql -U postgres -c "DROP EXTENSION IF EXISTS $EXTENSION_NAME"
}

regression_tests() {
    echo "Run regression tests: $EXTENSION_NAME"
    zig build pg_regress --verbose || return 1
}

all() {
    build && create_extension && regression_tests && extension_drop
}

command=${1:-all}

case $command in
    all) all ;;
    build) build ;;
    create_extension) create_extension ;;
    extension_drop) extension_drop ;;
    regression_tests) regression_tests ;;
    help) echo "Usage: $0 [all|build|create_extension|extension_drop|regression_tests]" ;;
    *) echo "Usage: $0 [all|build|create_extension|extension_drop|regression_tests]" ;;
esac
