#!/usr/bin/env bash
# End-to-end plan9 test pipeline for arm64 and/or amd64.
#
# Stages:
#   1. fetch       Download the stock 9front qcow2 image
#   2. share       Cross-build plan9/<arch> Go and stage GOROOT + FAT image
#   3. probe       Boot the stock kernel and run loopback-close-probe
#                  (expected to FAIL: confirms the tcpsplice bug)
#   4. compiler    Boot the stock kernel and run focused compiler tests
#   5. patch       Build a writable copy of the qcow2 and install the
#                  tcpsplice-fix kernel by running guest-kernel-rebuild
#   6. probe-patched  Re-run loopback-close-probe against the patched kernel
#                     (expected to PASS: confirms the fix)
#
# By default all stages run for both arm64 and amd64.  Pass --arch=arm64
# or --arch=amd64 to limit, and --stages=<comma-separated> to limit
# stages (default: fetch,share,probe,compiler).  The "patch" and
# "probe-patched" stages require PLAN9_KERNEL_SRC to point at a 9front
# tree that contains the patched sys/src/9/ip/tcp.c.
#
# Each stage logs to $LOG_DIR/<arch>-<stage>.log (default $LOG_DIR
# is tmp-9front-test/pipeline-logs).

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

arches=arm64,amd64
stages=fetch,share,probe,compiler
log_dir=${LOG_DIR:-"$repo_root/tmp-9front-test/pipeline-logs"}

usage() {
	cat <<EOF
usage: $0 [--arch=arm64|amd64|both] [--stages=stage1,stage2,...]

Stages:
  fetch          download the stock 9front qcow2 (per arch)
  share          stage GOROOT + FAT image (per arch)
  probe          stock kernel: loopback-close-probe (expect FAIL = bug)
  compiler       stock kernel: focused compiler test suite
  patch          build patched-kernel qcow2 via guest rebuild
                 (needs PLAN9_KERNEL_SRC=/path/to/9front)
  probe-patched  patched kernel: loopback-close-probe (expect PASS)

Examples:
  $0                                              # default: fetch+share+probe+compiler
  $0 --arch=amd64                                 # only amd64
  $0 --arch=both --stages=fetch,share,probe       # just fetch, stage, probe both
  PLAN9_KERNEL_SRC=../9front $0 --stages=patch,probe-patched
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--arch=*) arches=${1#--arch=}; [ "$arches" = both ] && arches=arm64,amd64; shift;;
		--stages=*) stages=${1#--stages=}; shift;;
		-h|--help) usage; exit 0;;
		*) echo "$0: unknown argument: $1" >&2; usage; exit 1;;
	esac
done

mkdir -p "$log_dir"

has_stage() {
	local s=$1
	[[ ",$stages," == *",$s,"* ]]
}

run_logged() {
	local arch=$1 stage=$2; shift 2
	local log="$log_dir/$arch-$stage.log"
	echo "==> [$arch] $stage : $* (-> $log)"
	if "$@" >"$log" 2>&1; then
		echo "    OK"
	else
		local rc=$?
		echo "    FAILED rc=$rc; last 20 lines:"
		tail -20 "$log" | sed 's/^/      /'
		return $rc
	fi
}

probe_summary() {
	local log=$1
	grep -E "^RESULT" "$log" | tail -1
}

compiler_summary() {
	local log=$1
	grep -E "^(ok|FAIL)\s|^DONE [a-z]" "$log" | tail -25
}

for arch in ${arches//,/ }; do
	case "$arch" in
		arm64) build=11724;;
		amd64) build=11734;;
		*) echo "$0: unknown arch: $arch" >&2; exit 1;;
	esac

	image="$repo_root/tmp-9front-test/9front-${build}.${arch}.qcow2"
	patched_image="$repo_root/tmp-9front-test/9front-${build}-patched.${arch}.qcow2"

	if has_stage fetch; then
		run_logged "$arch" fetch "misc/plan9/$arch/fetch-9front-image.sh"
	fi

	if has_stage share; then
		PLAN9_KERNEL_SRC=${PLAN9_KERNEL_SRC:-} \
			run_logged "$arch" share "misc/plan9/$arch/make-goroot-share.sh"
	fi

	if has_stage probe; then
		PLAN9_TEST_WAIT=180 \
		PLAN9_TEST_SCRIPT=/n/dos/misc/plan9/$arch/guest-loopback-close-probe.rc \
			run_logged "$arch" probe "misc/plan9/$arch/run-qemu-tests.sh" -m 1024 || true
		probe_summary "$log_dir/$arch-probe.log" | sed 's/^/    /'
	fi

	if has_stage compiler; then
		PLAN9_TEST_WAIT=2400 \
			run_logged "$arch" compiler "misc/plan9/$arch/run-qemu-tests.sh" -m 3072 || true
		compiler_summary "$log_dir/$arch-compiler.log" | sed 's/^/    /'
	fi

	if has_stage patch; then
		if [ -z "${PLAN9_KERNEL_SRC:-}" ]; then
			echo "    SKIP patch (set PLAN9_KERNEL_SRC=/path/to/9front)"
		else
			cp -n "$image" "$patched_image"
			PLAN9_IMAGE="$patched_image" \
			PLAN9_BUILD_WAIT=600 \
				run_logged "$arch" patch "misc/plan9/$arch/rebuild-9front-kernel.sh"
		fi
	fi

	if has_stage probe-patched; then
		if [ ! -f "$patched_image" ]; then
			echo "    SKIP probe-patched (no $patched_image)"
		else
			PLAN9_IMAGE="$patched_image" \
			PLAN9_TEST_WAIT=180 \
			PLAN9_TEST_SCRIPT=/n/dos/misc/plan9/$arch/guest-loopback-close-probe.rc \
				run_logged "$arch" probe-patched "misc/plan9/$arch/run-qemu-tests.sh" -m 1024 || true
			probe_summary "$log_dir/$arch-probe-patched.log" | sed 's/^/    /'
		fi
	fi
done

echo "==> pipeline done; logs in $log_dir"
