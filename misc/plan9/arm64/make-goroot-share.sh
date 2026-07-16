#!/usr/bin/env bash
# Cross-build plan9/arm64 Go and prepare a trimmed GOROOT for QEMU.
#
# By default also packages the staged tree into a real FAT32 image via
# mtools (mformat/mcopy).  That image is much more reliable than qemu's
# vvfat layer, which can corrupt the cluster chain of large files under
# concurrent reads/writes (observed on amd64 + KVM; on aarch64 + TCG
# the slow IO mostly hides it but it can still bite).  Set NO_FAT_IMAGE=1
# to skip the image build and fall back to vvfat.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
stage=${1:-"$repo_root/tmp-9front-goroot"}
go_cmd=${GO:-"$repo_root/bin/go"}
fat_image=${FAT_IMAGE:-"$stage.img"}
fat_size_mib=${FAT_SIZE_MIB:-1024}

case "$stage" in
	/*) ;;
	*) stage="$(pwd)/$stage" ;;
esac

if [ "$stage" = "$repo_root" ] || [ "$stage" = "/" ]; then
	echo "make-goroot-share.sh: refusing dangerous stage path: $stage" >&2
	exit 1
fi

if [ ! -x "$go_cmd" ]; then
	echo "make-goroot-share.sh: $go_cmd is not executable; run ./make.bash first" >&2
	exit 1
fi

echo "building std and cmd for plan9/arm64"
GOOS=plan9 GOARCH=arm64 "$go_cmd" install std cmd

echo "creating $stage"
rm -rf "$stage"
mkdir -p "$stage"

copy_if_exists() {
	local path=$1
	if [ -e "$repo_root/$path" ]; then
		cp -R "$repo_root/$path" "$stage/"
	fi
}

for path in VERSION VERSION.cache go.env codereview.cfg README.md LICENSE PATENTS api lib misc src test; do
	copy_if_exists "$path"
done

mkdir -p "$stage/bin" "$stage/pkg/tool" "$stage/pkg"

cp -R "$repo_root/bin/plan9_arm64" "$stage/bin/"
cp "$repo_root/bin/plan9_arm64/go" "$stage/bin/go"
if [ -f "$repo_root/bin/plan9_arm64/gofmt" ]; then
	cp "$repo_root/bin/plan9_arm64/gofmt" "$stage/bin/gofmt"
fi

cp -R "$repo_root/pkg/tool/plan9_arm64" "$stage/pkg/tool/"
if [ -d "$repo_root/pkg/include" ]; then
	cp -R "$repo_root/pkg/include" "$stage/pkg/"
fi

echo "building segment memory probe"
GOOS=plan9 GOARCH=arm64 "$go_cmd" build -o "$stage/bin/segment-memory-probe" "$repo_root/misc/plan9/arm64/segment-memory-probe.go"

echo "building loopback close probe"
GOOS=plan9 GOARCH=arm64 "$go_cmd" build -o "$stage/bin/loopback-close-probe" "$repo_root/misc/plan9/arm64/loopback-close-probe.go"

if [ -n "${PLAN9_KERNEL_SRC:-}" ] && [ -f "$PLAN9_KERNEL_SRC/sys/src/9/ip/tcp.c" ]; then
	echo "staging patched 9front tcp.c from $PLAN9_KERNEL_SRC"
	cp "$PLAN9_KERNEL_SRC/sys/src/9/ip/tcp.c" "$stage/misc/plan9/arm64/tcp.c.patched"
	# Also stage under amd64/ so the same source tree can drive amd64 rebuilds.
	mkdir -p "$stage/misc/plan9/amd64"
	cp "$PLAN9_KERNEL_SRC/sys/src/9/ip/tcp.c" "$stage/misc/plan9/amd64/tcp.c.patched"
fi

if [ -n "${PLAN9_KERNEL_SRC:-}" ] &&
   [ -f "$PLAN9_KERNEL_SRC/sys/src/9/port/proc.c" ] &&
   [ -f "$PLAN9_KERNEL_SRC/sys/src/9/port/fault.c" ]; then
	echo "staging patched 9front proc.c and fault.c from $PLAN9_KERNEL_SRC"
	cp "$PLAN9_KERNEL_SRC/sys/src/9/port/proc.c" "$stage/misc/plan9/arm64/proc.c.patched"
	cp "$PLAN9_KERNEL_SRC/sys/src/9/port/fault.c" "$stage/misc/plan9/arm64/fault.c.patched"
fi

echo "prepared QEMU VVFAT share at $stage"
echo "use with: -drive if=none,file=fat:rw:$stage,format=raw,id=share0"

if [ "${NO_FAT_IMAGE:-}" = "1" ]; then
	exit 0
fi

if ! command -v mformat >/dev/null 2>&1 || ! command -v mcopy >/dev/null 2>&1; then
	echo "make-goroot-share.sh: mtools not found; skipping FAT image build" >&2
	echo "  (set NO_FAT_IMAGE=1 to silence this, or install mtools for the more reliable image-file share)" >&2
	exit 0
fi

stage_bytes=$(du -sb "$stage" | awk '{print $1}')
needed_mib=$(( (stage_bytes + 256*1024*1024 + 1024*1024 - 1) / (1024*1024) ))
if [ "$needed_mib" -gt "$fat_size_mib" ]; then
	fat_size_mib=$needed_mib
fi

echo "building FAT32 image $fat_image (${fat_size_mib} MiB)"
rm -f "$fat_image"
truncate -s "${fat_size_mib}M" "$fat_image"
mformat -i "$fat_image" -F -v GOROOT ::
mcopy -i "$fat_image" -s -Q "$stage"/* ::/

echo "prepared FAT image at $fat_image"
echo "use with: -drive if=none,file=$fat_image,format=raw,id=share0"
