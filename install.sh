#!/bin/sh
#
# Install the pgzx command and project templates.
#
#   curl -fsSL https://github.com/barddoo/pgzx/releases/latest/download/install.sh | sh
#
# Options:
#   --prefix DIR      install prefix (default: ~/.local)
#   --version TAG     release to install (default: latest)
#   --local DIR       install from a local dist/ directory (no network)
#   --with-zig        also install Zig into the prefix
#   --zig-version V   Zig version for --with-zig (default: 0.17.1)
#
# Environment:
#   PGZX_REPO         GitHub repository (default: barddoo/pgzx)
#   PGZX_TARGET       release target (default: detected from uname)

set -eu

REPO=${PGZX_REPO:-barddoo/pgzx}
PREFIX=${PREFIX:-$HOME/.local}
VERSION=${PGZX_VERSION:-}
LOCAL=""
WITH_ZIG=0
ZIG_VERSION=${ZIG_VERSION:-0.17.1}

usage() {
	sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
	printf 'install: %s\n' "$*" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case $1 in
		--prefix)
			PREFIX=${2:?--prefix needs a value}
			shift 2
			;;
		--prefix=*)
			PREFIX=${1#*=}
			shift
			;;
		--version)
			VERSION=${2:?--version needs a value}
			shift 2
			;;
		--version=*)
			VERSION=${1#*=}
			shift
			;;
		--local)
			LOCAL=${2:?--local needs a value}
			shift 2
			;;
		--local=*)
			LOCAL=${1#*=}
			shift
			;;
		--with-zig)
			WITH_ZIG=1
			shift
			;;
		--zig-version)
			ZIG_VERSION=${2:?--zig-version needs a value}
			shift 2
			;;
		--zig-version=*)
			ZIG_VERSION=${1#*=}
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "unknown option '$1'"
			;;
	esac
done

case $(uname -s) in
	Linux | Darwin) ;;
	*) die "unsupported OS $(uname -s); use the Docker image instead" ;;
esac

detect_target() {
	case $(uname -s) in
		Darwin) os=macos ;;
		Linux) os=linux ;;
	esac
	case $(uname -m) in
		arm64 | aarch64) arch=aarch64 ;;
		x86_64 | amd64) arch=x86_64 ;;
		*) die "unsupported architecture $(uname -m)" ;;
	esac
	# Linux releases are static (musl) so they run on any distribution.
	case $os in
		linux) printf '%s-%s-musl' "$arch" "$os" ;;
		*) printf '%s-%s' "$arch" "$os" ;;
	esac
}

TARGET=${PGZX_TARGET:-$(detect_target)}

mkdir -p "$PREFIX"

if [ -n "$LOCAL" ]; then
	if [ -d "$LOCAL/cli-$TARGET" ]; then
		src=$LOCAL/cli-$TARGET
	elif [ -d "$LOCAL/cli" ]; then
		src=$LOCAL/cli
	else
		die "$LOCAL contains neither cli-$TARGET nor cli"
	fi
	cp -R "$src/." "$PREFIX/"
else
	command -v curl >/dev/null 2>&1 || die "curl is required"
	if [ -z "$VERSION" ]; then
		VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
			sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
		[ -n "$VERSION" ] || die "could not determine the latest release; pass --version"
	fi

	base="https://github.com/$REPO/releases/download/$VERSION"
	archive="pgzx-cli-$VERSION-$TARGET.tar.gz"
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT

	curl -fsSL "$base/$archive" -o "$tmp/$archive" ||
		die "failed to download $base/$archive (is $TARGET supported?)"
	curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS" ||
		die "failed to download $base/SHA256SUMS"

	(
		cd "$tmp"
		grep " $archive\$" SHA256SUMS >sums
		[ -s sums ] || die "no checksum for $archive"
		if command -v sha256sum >/dev/null 2>&1; then
			sha256sum -c sums >/dev/null
		else
			shasum -a 256 -c sums >/dev/null
		fi
	) || die "checksum verification failed"

	tar -xzf "$tmp/$archive" -C "$PREFIX"
fi

if [ "$WITH_ZIG" = 1 ]; then
	sh "$PREFIX/share/pgzx/install-zig.sh" "$ZIG_VERSION" "$PREFIX" ||
		die "Zig installation failed; install Zig from https://ziglang.org/download/"
fi

printf 'Installed pgzx to %s\n' "$PREFIX"
# shellcheck disable=SC2016
case ":$PATH:" in
	*":$PREFIX/bin:"*) ;;
	*) printf '\nAdd it to your PATH:\n  export PATH="%s/bin:$PATH"\n' "$PREFIX" ;;
esac
printf '\nNext:\n  pgzx doctor\n  pgzx new my_extension\n'
