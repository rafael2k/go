#!/usr/bin/env bash
# Smoke-test misc/plan9/dist/install-go.rc inside a 9front amd64 QEMU
# guest.  Shares the installer + guest wrapper via a tiny FAT image,
# boots 9front, mounts the share, and runs the wrapper.
#
# Requires:
#   - qemu-system-x86_64 with KVM access
#   - mtools (mformat/mcopy/mdir)
#   - a 9front amd64 qcow2 image at $PLAN9_IMAGE
#     (default: $REPO/tmp-9front-test/9front-11734-patched2.amd64.qcow2)
#
# All stdin/stdout/stderr from the guest is teed to
# $REPO/tmp-install-go-test.log so you can grep "DONE install-go.rc smoke
# test" to know it finished successfully.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
share_dir=${SHARE_DIR:-"$repo_root/tmp-install-go-share"}
share_img=${SHARE_IMG:-"$share_dir.img"}
image=${PLAN9_IMAGE:-"$repo_root/tmp-9front-test/9front-11734-patched2.amd64.qcow2"}
memory=${PLAN9_MEM:-2048}
smp=${PLAN9_SMP:-2}
cpu=${PLAN9_CPU:-host}
accel=${PLAN9_ACCEL:-kvm}
qemu=${QEMU:-qemu-system-x86_64}
boot_wait=${PLAN9_BOOT_WAIT:-20}
# Generous: actual download is ~66 MB through slirp TLS, then ~17000-file
# tar extract on top of hjfs.  Real hardware finishes in ~1 min, QEMU/TCG
# may need 5-10.
test_wait=${PLAN9_TEST_WAIT:-900}
log=${LOG:-"$repo_root/tmp-install-go-test.log"}

# Build the share image fresh every time so we always test the script
# currently on disk (not a stale snapshot from a previous run).
rm -rf "$share_dir" "$share_img"
mkdir -p "$share_dir"
cp "$repo_root/misc/plan9/dist/install-go.rc" \
   "$repo_root/misc/plan9/dist/guest-install-test.rc" \
   "$share_dir/"
truncate -s 16M "$share_img"
mformat -i "$share_img" -F -v INSTALLGO ::
mcopy -i "$share_img" -s "$share_dir"/* ::/

if [ ! -f "$image" ]; then
	echo "run-install-test.sh: missing $image" >&2
	echo "use misc/plan9/amd64/fetch-9front-image.sh first" >&2
	exit 1
fi

echo "logging to $log"

(
	sleep "$boot_wait"
	# Two newlines to skip "press any key" and land at the rc prompt.
	printf '\n'; sleep 6
	printf '\n'; sleep 6

	# Mount the share.  mformat-created images appear as /dev/sdU*/data;
	# vvfat as /dev/sdU*/dos.  Filter out the boot disk (has /fs or /9fat).
	printf 'share=()\n'; sleep 1
	printf 'for(d in /dev/sdU*){\n'; sleep 1
	printf '\tfor(p in data dos){\n'; sleep 1
	printf '\t\tif(test -e $d/$p && ! test -e $d/fs && ! test -e $d/9fat){\n'; sleep 1
	printf '\t\t\tshare=$d/$p\n'; sleep 1
	printf '\t\t}\n'; sleep 1
	printf '\t}\n'; sleep 1
	printf '}\n'; sleep 1
	printf 'if(~ $#share 0){ echo install-test: no share found; ls /dev/sdU* >[2=1]; exit noshare }\n'; sleep 1
	printf 'echo share-device $share\n'; sleep 1
	printf 'dossrv -f $share godos\n'; sleep 2
	printf 'mount /srv/godos /n/dos\n'; sleep 2
	printf 'ls /n/dos\n'; sleep 1

	# Run the wrapper that runs install-go.rc.
	printf 'rc /n/dos/guest-install-test.rc\n'

	sleep "$test_wait"
) | "$qemu" \
	-M q35 \
	-accel "$accel" \
	-cpu "$cpu" \
	-smp "$smp" \
	-m "$memory" \
	-drive if=virtio,file="$image",format=qcow2,snapshot=on \
	-device qemu-xhci \
	-drive if=none,file="$share_img",format=raw,id=share0,snapshot=on \
	-device usb-storage,drive=share0 \
	-netdev user,id=n0 \
	-device virtio-net-pci,netdev=n0 \
	-nographic \
	-serial mon:stdio \
	2>&1 | tee "$log"
