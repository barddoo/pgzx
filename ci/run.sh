#!/usr/bin/env bash

# Runs the full CI suite: build every example, start a local PostgreSQL, run
# the pgzx unit tests, then run each example's own CI script (build, create
# extension, unit + regression tests, drop) for the examples that declare
# tests. Every example is built; examples with no tests are skipped after the
# build phase, so a learning example cannot gate the suite. Prints "Success!"
# on completion.
#
# Requires Zig and a PostgreSQL installation with development headers. The
# `pgzx` command is built from src/cli and derives the environment from
# `PG_CONFIG` (or the `pg_config` on PATH).

#set -x
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [ ! -x "$root/zig-out/bin/pgzx" ]; then
	zig build cli
fi
export PATH="$root/zig-out/bin:$PATH"
eval "$(pgzx env)"
# pgzx init creates the default cluster under PGZX_CLUSTER_DIR; start/status
# recompute the same paths from the exported environment.
PG_CLUSTER_LOG_FILE=$PGZX_CLUSTER_DIR/postgres/log/server.log

examples=(./examples/*)

log_dir=""
started_server=0

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

# `pgzx env` must export the complete connection contract: PGDATA and PGPORT are
# what make plain `pg_ctl`/`psql` work, PGUSER/PGDATABASE what make psql connect
# to the project cluster.
check_cluster_env() {
	local var
	for var in PGDATA PGPORT PGUSER PGDATABASE PGHOST PGZX_CLUSTER; do
		if [ -z "${!var:-}" ]; then
			fail "pgzx env did not export $var"
		fi
	done
	if [ ! -f "$PGDATA/PG_VERSION" ]; then
		fail "PGDATA=$PGDATA is not an initialized cluster"
	fi
}

check_cluster_env

cleanup() {
	if [ "$started_server" = 1 ]; then
		pgzx stop 2>/dev/null || true
	fi
	if [ -n "$log_dir" ]; then
		rm -rf "$log_dir"
	fi
}
trap cleanup TERM INT EXIT

build_example() {
	if [ -f "$1/ci/run.sh" ]; then
		(cd "$1" && ./ci/run.sh build)
	else
		(cd "$1" && zig build -freference-trace -p "$PG_HOME")
	fi
}

run_example() {
	(cd "$1" && ./ci/run.sh)
}

# An example opts into the test phase by declaring tests in its build.zig
# (`.pg_regress` and/or `.unit`). Examples that only build are skipped.
has_tests() {
	grep -qE '^[[:space:]]*\.(pg_regress|unit)[[:space:]]*=' "$1/build.zig" 2>/dev/null
}

test_pgzx() {
	local rc=0
	zig build -freference-trace test || rc=1
	zig build -freference-trace -p "$PG_HOME" unit || rc=1
	psql -U postgres -c "DROP EXTENSION IF EXISTS pgzx_unit" || rc=1
	return "$rc"
}

# Print the section of the server log written since this script started, which
# is where backend crashes and errors end up.
dump_server_log() {
	local log_size
	log_size=$(wc -c <"$PG_CLUSTER_LOG_FILE")
	printf '\n\nServer log (new output since start):\n'
	if [ "$log_size" -gt "$log_init_size" ]; then
		tail -c $((log_size - log_init_size)) "$PG_CLUSTER_LOG_FILE"
	fi
}

echo "Build and install extension"

log_init_size=0
if [ -f "$PG_CLUSTER_LOG_FILE" ]; then
	# wc -c instead of stat: stat flags differ between GNU and BSD (macOS).
	log_init_size=$(wc -c <"$PG_CLUSTER_LOG_FILE")
fi
echo "Server log size: $log_init_size"

# Build every example in parallel. Each build writes to its own log file so the
# combined output stays readable; the log is only printed when that example
# fails to build.
echo "${examples[@]}"
log_dir=$(mktemp -d)
build_jobs=()
build_names=()
for example in "${examples[@]}"; do
	name=$(basename "$example")
	echo "Build example $example"
	build_example "$example" >"$log_dir/$name.log" 2>&1 &
	build_jobs+=($!)
	build_names+=("$name")
done
for i in "${!build_jobs[@]}"; do
	if ! wait "${build_jobs[$i]}"; then
		cat "$log_dir/${build_names[$i]}.log" >&2
		fail "Failed to build ${build_names[$i]}"
	fi
done

echo -e "\n\nStart PostgreSQL"
# pgzx start fails if the server is already running, so check first. Only stop
# the server on exit if this script started it.
if ! pgzx status >/dev/null 2>&1; then
	pgzx start || fail "Failed to start PostgreSQL"
	started_server=1
fi

# PGDATA from `pgzx env` is what makes plain pg_ctl/psql work; failing here
# means the env contract regressed.
pg_ctl status >/dev/null || fail "pg_ctl cannot see PGDATA=$PGDATA"
psql -c 'select 1' >/dev/null || fail "psql with the pgzx env failed"

echo -e "\n\nRun pgzx unit tests:"
if ! test_pgzx; then
	dump_server_log
	fail "Failed to run pgzx unit tests"
fi

for example in "${examples[@]}"; do
	if has_tests "$example"; then
		echo -e "\n\nRun example CI script $example"
		if ! run_example "$example"; then
			dump_server_log
			fail "Failed to run CI script for $example"
		fi
	else
		echo -e "\n\nNo tests declared in $example, skipping (already built)"
	fi
done

echo "Success!"
