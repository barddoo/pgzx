#!/usr/bin/env bash
#
# Build the release artifacts into dist/:
#
#   templates/default                 project template, pinned to --version and --hash
#   cli/                              host bundle (<prefix>/bin + <prefix>/share/pgzx)
#   cli-<target>/                     one bundle per release target
#   pgzx-template-<v>.tar.gz          templates only
#   pgzx-cli-<v>-<target>.tar.gz      CLI bundle for <target>
#   install.sh                        installer
#   SHA256SUMS
#
# Usage: tools/build-dist.sh [--version TAG] [--hash HASH] [--out DIR]
#
# PGZX_TARGETS overrides the release target list (default: the four targets
# published in a GitHub release).
#
# The hash is the Zig package hash of the tagged source tarball
# (`zig fetch https://github.com/barddoo/pgzx/archive/refs/tags/<TAG>.tar.gz`).
# Without it the generated build.zig.zon keeps the commented-out hash.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
version=""
hash=""
out=$root/dist
targets=${PGZX_TARGETS:-"aarch64-macos x86_64-macos x86_64-linux-musl aarch64-linux-musl"}

usage() {
	sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
	case $1 in
		--version)
			version=${2:-}
			shift 2
			;;
		--version=*)
			version=${1#*=}
			shift
			;;
		--hash)
			hash=${2:-}
			shift 2
			;;
		--hash=*)
			hash=${1#*=}
			shift
			;;
		--out)
			out=${2:-}
			shift 2
			;;
		--out=*)
			out=${1#*=}
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "build-dist: unknown option '$1'" >&2
			exit 2
			;;
	esac
done

if [ -z "$version" ]; then
	version=$(git -C "$root" describe --tags --always 2>/dev/null || echo "v0.0.0-dev")
fi

stamp() {
	local file=$1
	perl -pi -e "s#https://github\.com/barddoo/pgzx/archive/main\.tar\.gz#https://github.com/barddoo/pgzx/archive/refs/tags/${version}.tar.gz#" "$file"
	if [ -n "$hash" ]; then
		perl -pi -e "s#^(\s*)// \.hash = \"\.\.\.\"#\${1}.hash = \"${hash}\"#" "$file"
	fi
}

fill_bundle() {
	local dir=$1
	mkdir -p "$dir/share/pgzx"
	cp -R "$out/templates" "$dir/share/pgzx/templates"
	printf '%s\n' "$version" >"$dir/share/pgzx/VERSION"
	cp "$root/install.sh" "$dir/install.sh"
	cp "$root/dev/docker/install-zig.sh" "$dir/share/pgzx/install-zig.sh"
	mkdir -p "$dir/bin"
	cp "$root/dev/bin/"* "$dir/bin/"
	chmod +x "$dir/bin/"*
}

rm -rf "$out"
mkdir -p "$out/templates"

cp -R "$root/templates/default" "$out/templates/default"
stamp "$out/templates/default/build.zig.zon"

# Host bundle, used by the test jobs and `install.sh --local dist`.
zig build cli -Doptimize=ReleaseSafe --prefix "$out/cli"
fill_bundle "$out/cli"

for target in $targets; do
	dir=$out/cli-$target
	zig build cli -Doptimize=ReleaseSafe -Dtarget="$target" --prefix "$dir"
	fill_bundle "$dir"
	tar -czf "$out/pgzx-cli-$version-$target.tar.gz" -C "$dir" .
done

cp "$root/install.sh" "$out/install.sh"

tar -czf "$out/pgzx-template-$version.tar.gz" -C "$out/templates" default

if command -v sha256sum >/dev/null 2>&1; then
	(cd "$out" && sha256sum ./*.tar.gz >SHA256SUMS)
else
	(cd "$out" && shasum -a 256 ./*.tar.gz >SHA256SUMS)
fi

printf 'Built %s\n' "$out"
ls -1 "$out"
