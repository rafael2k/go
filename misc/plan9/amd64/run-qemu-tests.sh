#!/usr/bin/env bash
# Boot 9front/amd64 in QEMU and run the guest test script.
#
# Mirrors misc/plan9/arm64/run-qemu-tests.sh.  Differences:
#   * uses qemu-system-x86_64 with KVM (much faster than aarch64 TCG)
#   * no U-Boot; the qcow2's own boot sector is used
#   * default boot uses virtio-blk for the root disk (fast); the Go share
#     stays on USB so the guest can locate it the same way as on arm64
#     (/dev/sdU*/dos -> dossrv -> /n/dos)

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
image=${PLAN9_IMAGE:-"$repo_root/tmp-9front-test/9front-11734.amd64.qcow2"}
share=${PLAN9_SHARE:-"$repo_root/tmp-9front-amd64-goroot"}
share_img=${PLAN9_SHARE_IMG:-"$share.img"}
memory=${PLAN9_MEM:-3072}
smp=${PLAN9_SMP:-4}
cpu=${PLAN9_CPU:-host}
accel=${PLAN9_ACCEL:-kvm}
guest_script=${PLAN9_TEST_SCRIPT:-"/n/dos/misc/plan9/amd64/guest-compiler-tests.rc"}
tool_arch=${PLAN9_GOTOOL_ARCH:-plan9_amd64}
qemu=${QEMU_SYSTEM_X86_64:-qemu-system-x86_64}

if [ -f "${PLAN9_SHARE_IMG:-$share.img}" ]; then
	share_part_default=data
else
	share_part_default=dos
fi
share_part=${PLAN9_SHARE_PART:-$share_part_default}

usage() {
	cat <<EOF
usage: $0 [options] [-- package ...]

Options:
  -image PATH    9front qcow2 image (default: $image)
  -share PATH    prepared GOROOT VVFAT share (default: $share)
  -m MEM         QEMU memory in MiB (default: $memory)
  -smp N         QEMU CPU count (default: $smp)
  -cpu MODEL     QEMU -cpu model (default: $cpu)
  -accel ACCEL   QEMU -accel (default: $accel; set "tcg" if no KVM)

Environment:
  PLAN9_SHARE_PART  Plan 9 USB-storage partition name to mount as the share
                    (default: $share_part, auto-picked: "data" for image,
                    "dos" for vvfat)
  PLAN9_TEST_SCRIPT  Guest rc script to run after setup
                    (default: $guest_script)
  PLAN9_BOOT_WAIT   seconds before sending login newline (default: 20)
  PLAN9_COPY_WAIT   seconds to wait while copying tools (default: 30)
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

boot_wait=${PLAN9_BOOT_WAIT:-20}
copy_wait=${PLAN9_COPY_WAIT:-30}

quote_rc_arg() {
	local arg=$1
	arg=${arg//\'/\'\'}
	printf "'%s'" "$arg"
}

if [ ! -f "$image" ]; then
	echo "run-qemu-tests.sh: missing image: $image" >&2
	echo "run misc/plan9/amd64/fetch-9front-image.sh first" >&2
	exit 1
fi
if [ ! -d "$share" ] && [ ! -f "$share_img" ]; then
	echo "run-qemu-tests.sh: missing share dir ($share) and image ($share_img)" >&2
	echo "run misc/plan9/amd64/make-goroot-share.sh first" >&2
	exit 1
fi

if [ -f "$share_img" ]; then
	share_drive_args=(-drive if=none,file="$share_img",format=raw,id=share0,snapshot=on)
else
	share_drive_args=(-drive if=none,file=fat:rw:"$share",format=raw,id=share0)
fi
if ! command -v "$qemu" >/dev/null 2>&1; then
	echo "run-qemu-tests.sh: missing $qemu" >&2
	exit 1
fi

guest_test_cmd="rc $(quote_rc_arg "$guest_script")"
for arg in "$@"; do
	guest_test_cmd="$guest_test_cmd $(quote_rc_arg "$arg")"
done

(
	sleep "$boot_wait"
	printf '\n'
	sleep 8
	printf '\n'
	sleep 8
	# Auto-discover the USB-storage device that backs the GOROOT share.
	# Both the boot disk and the share are exposed as usb-storage, both
	# have a /data leaf, so filter out anything that also has /fs (hjfs)
	# or /9fat (the boot disk).
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
	printf 'if(~ $#share 0){ echo run-qemu-tests: no share /dev/sdU*/%s found; exit noshare }\n' "$share_part"
	sleep 1
	printf 'echo share-device $share\n'
	sleep 1
	printf 'dossrv -f $share godos\n'
	sleep 2
	printf 'mount /srv/godos /n/dos\n'
	sleep 2
	printf 'mkdir -p /tmp/gobin /tmp/gotool /tmp/gocache /tmp/gotmp\n'
	sleep 1
	printf 'cp /n/dos/bin/go /tmp/gobin/go\n'
	sleep 2
	printf 'cp /n/dos/pkg/tool/%s/* /tmp/gotool\n' "$tool_arch"
	sleep "$copy_wait"
	printf 'chmod 775 /tmp/gobin/*\n'
	sleep 1
	printf 'chmod 775 /tmp/gotool/*\n'
	sleep 2
	printf 'bind -a /tmp/gobin /bin\n'
	sleep 1
	printf 'bind /tmp/gotool /n/dos/pkg/tool/%s\n' "$tool_arch"
	sleep 1
	printf 'cd /n/dos/src\n'
	sleep 1
	printf '%s\n' "$guest_test_cmd"
	sleep "${PLAN9_TEST_WAIT:-2400}"
) | "$qemu" \
	-M q35 \
	-accel "$accel" \
	-cpu "$cpu" \
	-smp "$smp" \
	-m "$memory" \
	-drive if=virtio,file="$image",format=qcow2,snapshot=on \
	-device qemu-xhci \
	"${share_drive_args[@]}" \
	-device usb-storage,drive=share0 \
	-netdev user,id=n0 \
	-device virtio-net-pci,netdev=n0 \
	-nographic \
	-serial mon:stdio
