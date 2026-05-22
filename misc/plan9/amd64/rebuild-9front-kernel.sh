#!/usr/bin/env bash
# Boot a writable 9front/amd64 qcow2 in QEMU, apply the loopback
# tcpsplice fix to /sys/src/9/ip/tcp.c, rebuild the kernel, and
# install the new 9pc64 into /n/9fat so it boots on next start.
#
# The host directory passed via -share is mounted as a FAT share at
# /n/dos in the guest.  This script expects that share to contain
# misc/plan9/amd64/tcp.c.patched (the patched tcp.c) and
# misc/plan9/amd64/guest-kernel-rebuild.rc.  After this script
# completes successfully, the patched qcow2 can be passed to
# run-qemu-tests.sh via PLAN9_IMAGE=...
#
# Reasonably safe: the script operates on a writable qcow2, but it
# does NOT touch the original 9front-*.amd64.qcow2; the user must
# copy that image to a new file and pass it via -image first.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
image=${PLAN9_IMAGE:-"$repo_root/tmp-9front-test/9front-11734-patched.amd64.qcow2"}
share=${PLAN9_SHARE:-"$repo_root/tmp-9front-amd64-goroot"}
share_img=${PLAN9_SHARE_IMG:-"$share.img"}
memory=${PLAN9_MEM:-3072}
smp=${PLAN9_SMP:-4}
cpu=${PLAN9_CPU:-host}
accel=${PLAN9_ACCEL:-kvm}
guest_script=${PLAN9_TEST_SCRIPT:-"/n/dos/misc/plan9/amd64/guest-kernel-rebuild.rc"}
qemu=${QEMU_SYSTEM_X86_64:-qemu-system-x86_64}

if [ -f "${PLAN9_SHARE_IMG:-$share.img}" ]; then
	share_part_default=data
else
	share_part_default=dos
fi
share_part=${PLAN9_SHARE_PART:-$share_part_default}

usage() {
	cat <<EOF
usage: $0 [options]

Options:
  -image PATH    writable 9front qcow2 image (default: $image)
  -share PATH    FAT share dir, must contain misc/plan9/amd64/tcp.c.patched
                 (default: $share)
  -m MEM         QEMU memory in MiB (default: $memory)
  -smp N         QEMU CPU count (default: $smp)
  -cpu MODEL     QEMU -cpu model (default: $cpu)
  -accel ACCEL   QEMU -accel (default: $accel)

Environment:
  PLAN9_SHARE_PART   Plan 9 USB-storage partition for the share
                     (default: $share_part)
  PLAN9_BUILD_WAIT   seconds to wait for the kernel build to finish
                     (default: 600)
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		-image) image=$2; shift 2;;
		-share) share=$2; shift 2;;
		-m) memory=$2; shift 2;;
		-smp) smp=$2; shift 2;;
		-cpu) cpu=$2; shift 2;;
		-accel) accel=$2; shift 2;;
		-h|-help|--help) usage; exit 0;;
		--) shift; break;;
		*) break;;
	esac
done

build_wait=${PLAN9_BUILD_WAIT:-600}
boot_wait=${PLAN9_BOOT_WAIT:-20}

if [ ! -f "$image" ]; then
	echo "rebuild-9front-kernel.sh: missing writable qcow2 at $image" >&2
	echo "  cp tmp-9front-test/9front-11734.amd64.qcow2 $image first" >&2
	exit 1
fi

if [ ! -d "$share" ] && [ ! -f "$share_img" ]; then
	echo "rebuild-9front-kernel.sh: missing share dir/img" >&2
	exit 1
fi

if [ ! -f "$share/misc/plan9/amd64/tcp.c.patched" ]; then
	echo "rebuild-9front-kernel.sh: missing $share/misc/plan9/amd64/tcp.c.patched" >&2
	echo "  cp ../9front/sys/src/9/ip/tcp.c $share/misc/plan9/amd64/tcp.c.patched" >&2
	exit 1
fi

if [ -f "$share_img" ]; then
	share_drive_args=(-drive if=none,file="$share_img",format=raw,id=share0,snapshot=on)
else
	share_drive_args=(-drive if=none,file=fat:rw:"$share",format=raw,id=share0)
fi

quote_rc_arg() {
	local arg=$1
	arg=${arg//\'/\'\'}
	printf "'%s'" "$arg"
}

guest_build_cmd="rc $(quote_rc_arg "$guest_script")"
shutdown_cmd='echo SHUTDOWN; fshalt -r >[2=1] >/dev/null; echo halt >/dev/reboot'

(
	sleep "$boot_wait"
	printf '\n'
	sleep 8
	printf '\n'
	sleep 8
	printf 'share=()\n'
	sleep 1
	printf 'for(d in /dev/sdU*){\n'
	sleep 1
	printf '\tif(test -e $d/%s && ! test -e $d/fs && ! test -e $d/9fat){\n' "$share_part"
	sleep 1
	printf '\t\tshare=$d/%s\n' "$share_part"
	sleep 1
	printf '\t}\n'
	sleep 1
	printf '}\n'
	sleep 1
	printf 'if(~ $#share 0){ echo rebuild-9front-kernel: no /dev/sdU*/%s found; exit noshare }\n' "$share_part"
	sleep 1
	printf 'echo share-device $share\n'
	sleep 1
	printf 'dossrv -f $share godos\n'
	sleep 2
	printf 'mount /srv/godos /n/dos\n'
	sleep 2
	printf '%s\n' "$guest_build_cmd"
	sleep "$build_wait"
	printf '%s\n' "$shutdown_cmd"
	sleep 30
) | "$qemu" \
	-M q35 \
	-accel "$accel" \
	-cpu "$cpu" \
	-smp "$smp" \
	-m "$memory" \
	-drive if=virtio,file="$image",format=qcow2 \
	-device qemu-xhci \
	"${share_drive_args[@]}" \
	-device usb-storage,drive=share0 \
	-netdev user,id=n0 \
	-device virtio-net-pci,netdev=n0 \
	-nographic \
	-serial mon:stdio
