#!/bin/sh
# Install a Zig release.
#
# Prefers the community mirrors and verifies every download against the ZSF
# minisign key; the signature's trusted-comment "file" field must match the name
# we asked for (downgrade protection). Without minisign, fall back to
# ziglang.org and verify the SHA256 published in index.json.
#
# usage: install-zig.sh VERSION [DEST] [MINISIGN_PUBKEY]
#   VERSION   Zig release, e.g. 0.17.1
#   DEST      install prefix (default: ~/.local); the binary is linked into DEST/bin
#   PUBKEY    minisign public key (default: the Zig 0.17.1 download key)
set -eu

version=${1:?zig version required}
dest=${2:-$HOME/.local}
pubkey=${3:-RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U}

case $(uname -s) in
	Linux) os=linux ;;
	Darwin) os=macos ;;
	*)
		echo "unsupported OS: $(uname -s)" >&2
		exit 1
		;;
esac
case $(uname -m) in
	x86_64 | amd64) arch=x86_64 ;;
	aarch64 | arm64) arch=aarch64 ;;
	*)
		echo "unsupported architecture: $(uname -m)" >&2
		exit 1
		;;
esac

name="zig-${arch}-${os}-${version}.tar.xz"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$dest/bin"

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

install_tarball() {
	tar -xJf "$1" -C "$dest"
	ln -sf "$dest/zig-${arch}-${os}-${version}/zig" "$dest/bin/zig"
	echo "installed zig ${version} (${arch}-${os}) into $dest/bin" >&2
}

if command -v minisign >/dev/null 2>&1; then
	mirror_list=https://ziglang.org/download/community-mirrors.txt
	mirrors=$(curl -fsSL --retry 3 "$mirror_list" |
		awk 'BEGIN{srand()} {print rand(), $0}' | sort -n | cut -d' ' -f2- ||
		true)
	if [ -z "$mirrors" ]; then
		echo "could not fetch $mirror_list; using ziglang.org only" >&2
	fi

	# Official site last; its tarballs live under /download/<version>/.
	for base in $mirrors "https://ziglang.org/download/${version}"; do
		echo "trying $base" >&2
		curl -fsSL --connect-timeout 10 --speed-limit 102400 --speed-time 15 --retry 2 \
			-o "$work/$name" "$base/$name" || continue
		curl -fsSL --connect-timeout 10 --max-time 15 --retry 2 \
			-o "$work/$name.minisig" "$base/$name.minisig" || continue

		minisign -Vm "$work/$name" -x "$work/$name.minisig" -P "$pubkey" >/dev/null || {
			echo "signature check failed for $base" >&2
			continue
		}

		signed_name=$(grep '^trusted comment:' "$work/$name.minisig" | grep -o 'file:[^[:space:]]*' | head -n1 | cut -d: -f2-)
		if [ "$signed_name" != "$name" ]; then
			echo "signature is for '$signed_name', expected '$name' ($base)" >&2
			continue
		fi

		install_tarball "$work/$name"
		exit 0
	done

	echo "failed to install zig ${version} from any mirror" >&2
	exit 1
fi

# No minisign: verify against the checksum published on ziglang.org. Mirrors do
# not publish index.json, so use the official host only.
echo "minisign not found; verifying $name against ziglang.org/download/index.json" >&2
curl -fsSL --retry 3 -o "$work/$name" "https://ziglang.org/download/${version}/${name}" ||
	{
		echo "failed to download $name" >&2
		exit 1
	}

index=$(curl -fsSL --retry 3 https://ziglang.org/download/index.json) ||
	{
		echo "failed to download index.json" >&2
		exit 1
	}

if command -v python3 >/dev/null 2>&1; then
	expected=$(printf '%s' "$index" | python3 -c \
		'import json,sys; print(json.load(sys.stdin)[sys.argv[1]][sys.argv[2]]["shasum"])' \
		"$version" "$arch-$os") || expected=""
elif command -v jq >/dev/null 2>&1; then
	expected=$(printf '%s' "$index" | jq -r --arg v "$version" --arg t "$arch-$os" '.[$v][$t].shasum') || expected=""
else
	echo "install minisign (or python3/jq) to verify the download" >&2
	exit 1
fi

if [ -z "$expected" ] || [ "$expected" = "null" ]; then
	echo "no checksum for $arch-$os in index.json for ${version}" >&2
	exit 1
fi
actual=$(sha256 "$work/$name")
if [ "$actual" != "$expected" ]; then
	echo "checksum mismatch for $name: got $actual, expected $expected" >&2
	exit 1
fi

install_tarball "$work/$name"
