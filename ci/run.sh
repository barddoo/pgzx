#!/usr/bin/env bash

# Runs the full CI suite: build every example, start a local PostgreSQL, run
# the pgzx unit tests, then run each example's own CI script (build, create
# extension, unit + regression tests, drop). Prints "Success!" on completion.
#
# Requires the development shell (`nix develop`), which provides the `pgenv`,
# `pgstart`, `pgstop` and `pgstatus` helpers and the `pg_config` dispatcher.

#set -x
set -euo pipefail

examples=(./examples/*)

log_dir=""
started_server=0

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

cleanup() {
	if [ "$started_server" = 1 ]; then
		pgstop 2>/dev/null || true
	fi
	if [ -n "$log_dir" ]; then
		rm -rf "$log_dir"
	fi
}
trap cleanup TERM INT EXIT

build_example() {
	(cd "$1" && ./ci/run.sh build)
}

run_example() {
	(cd "$1" && ./ci/run.sh)
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
eval "$(pgenv)"

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
# pgstart fails if the server is already running, so check first. Only stop
# the server on exit if this script started it.
if ! pgstatus >/dev/null 2>&1; then
	pgstart || fail "Failed to start PostgreSQL"
	started_server=1
fi

echo -e "\n\nRun pgzx unit tests:"
if ! test_pgzx; then
	dump_server_log
	fail "Failed to run pgzx unit tests"
fi

for example in "${examples[@]}"; do
	echo -e "\n\nRun example CI script $example"
	if ! run_example "$example"; then
		dump_server_log
		fail "Failed to run CI script for $example"
	fi
done

echo "Success!"
