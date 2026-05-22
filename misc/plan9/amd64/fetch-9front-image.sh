#!/usr/bin/env bash
# Download and unpack a 9front AMD64 QEMU disk image.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
out_dir=${OUT_DIR:-"$repo_root/tmp-9front-test"}
build=${9FRONT_BUILD:-11734}
url=${9FRONT_URL:-"http://build.9front.org/9front/9front-${build}.amd64.qcow2.gz"}

mkdir -p "$out_dir"

archive="$out_dir/$(basename "$url")"
image="${archive%.gz}"

echo "downloading $url"
if command -v wget >/dev/null 2>&1; then
	wget -c -O "$archive" "$url"
elif command -v curl >/dev/null 2>&1; then
	curl -L -C - -o "$archive" "$url"
else
	echo "fetch-9front-image.sh: need wget or curl" >&2
	exit 1
fi

echo "unpacking $archive"
gzip -dkf "$archive"

echo "$image"
