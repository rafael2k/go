# Plan 9 ARM64 QEMU Test Harness

This directory contains host-side scripts for testing the Go `plan9/arm64`
port on 9front under QEMU. The harness was written for Linux hosts and the
9front ARM64 QEMU image.

## Host Dependencies

- `qemu-system-aarch64`
- U-Boot for QEMU ARM64, normally
  `/usr/lib/u-boot/qemu_arm64/u-boot.bin`
- `wget` or `curl`
- `gzip`
- `mtools` (`mformat` + `mcopy`) -- optional but strongly recommended;
  enables the FAT image share, which is much more reliable than qemu's
  vvfat layer (see *Go Share* below).  Set `NO_FAT_IMAGE=1` if you do
  not want it.

On Debian/Ubuntu systems the useful packages are usually:

```sh
sudo apt install qemu-system-arm qemu-utils u-boot-qemu wget mtools
```

## Basic Workflow

From the Go repository root:

```sh
# 1. Download and unpack a 9front ARM64 QEMU disk image.
misc/plan9/arm64/fetch-9front-image.sh

# 2. Cross-build Go for plan9/arm64 and create a QEMU VVFAT share.
misc/plan9/arm64/make-goroot-share.sh

# 3. Boot 9front and run the focused compiler tests.
misc/plan9/arm64/run-qemu-tests.sh
```

The default image is `tmp-9front-test/9front-11724.arm64.qcow2`.
The default Go share is `tmp-9front-goroot` (staged directory) plus
`tmp-9front-goroot.img` (FAT32 image built by `mtools`).

`make-goroot-share.sh` produces both forms.  `run-qemu-tests.sh`
prefers the `.img` file when present (auto-discovered, no
configuration needed); set `NO_FAT_IMAGE=1` in `make-goroot-share.sh`
to skip the image build and fall back to qemu's vvfat layer.

The FAT image is more reliable than vvfat: under heavy concurrent
reads/writes (especially with KVM-accelerated guests) vvfat has been
observed to corrupt the cluster chain of large files, producing
mysterious mid-file truncations.  A bit-for-bit FAT32 image avoids
that entirely and is read by Plan 9's `dossrv` just like a real disk.

## QEMU Notes

The working QEMU shape is:

```sh
qemu-system-aarch64 \
  -M virt,gic-version=3,highmem=off \
  -cpu cortex-a72 -smp 4 -m 3072 \
  -bios /usr/lib/u-boot/qemu_arm64/u-boot.bin \
  -drive if=none,file=tmp-9front-test/9front-11724.arm64.qcow2,format=qcow2,id=hd0,snapshot=on \
  -device qemu-xhci -device usb-storage,drive=hd0 \
  -drive if=none,file=fat:rw:tmp-9front-goroot,format=raw,id=share0 \
  -device usb-storage,drive=share0 \
  -netdev user,id=n0 -device virtio-net-pci-non-transitional,netdev=n0 \
  -nographic -serial mon:stdio
```

The defaults emulate a Raspberry Pi 4 class machine: 4 cortex-a72 cores,
3 GiB RAM, GICv3. Override with:

```sh
PLAN9_MEM=NNNN PLAN9_SMP=N PLAN9_CPU=cortex-a53 misc/plan9/arm64/run-qemu-tests.sh
```

The QEMU `-M virt,highmem=off` cap is 3 GiB. The 9front 11724 ARM64
kernel panics with `kenter: -88 stack bytes left` as soon as RAM is
placed above 4 GiB (e.g. when `highmem=off` is dropped or `-m` is set
above 3072 MiB), so the harness keeps `highmem=off` and caps at 3 GiB.
With the swap setup below, the `runtime` page-allocator simulation
tests (`TestPageAllocScavenge`, `TestPageAllocAlloc`, …) fit and run
without exhausting Plan 9 user memory.

The scripts intentionally use USB storage rather than virtio block for the
disks because the tested 9front ARM64 image exposed the USB disks reliably.

The Go share device is auto-discovered: the guest script scans
`/dev/sdU*/<part>` and picks the first entry that does *not* also have
`/fs` (hjfs, the boot disk) or `/9fat` (the boot disk's FAT
partition).  `<part>` is `data` when the share is a real FAT image and
`dos` when it is qemu vvfat; override with `PLAN9_SHARE_PART`.

## Network Setup

The raw serial-console test path does not necessarily run the normal
`termrc`/`cpurc` network setup, and 9front boot starts `ndb/cs` *before*
any IP interfaces exist, so cs's `dnsipvers` is 0 and it refuses to
resolve names (`cs: no ip address`).  The guest script therefore:

1. Kills the boot-time `ndb/cs` and `ndb/dns` so we own them.
2. Brings up IPv4 / IPv6 loopback:
   ```rc
   ip/ipconfig loopback /dev/null 127.0.0.1 255.0.0.0
   ip/ipconfig loopback /dev/null ::1 /128
   ```
3. If `/net/ether0` exists, brings it up over slirp DHCP:
   ```rc
   ip/ipconfig ether /net/ether0
   ```
   On `qemu-system-aarch64 -M virt` the user-mode network gives the
   guest `10.0.2.15`, a default route via `10.0.2.2`, and a DNS server
   at `10.0.2.3`.
4. Restarts `ndb/cs` (and `ndb/dns -r`) so they see the new interfaces
   and run as our user (the only one that can write `refresh` to
   `/net/cs`).

The virtio NIC is wired with **`-device virtio-net-pci-non-transitional`**.
9front's arm64 kernel ships only the `ethervirtio10` driver (modern
virtio 1.0, PCI device id `0x1041`); the QEMU default
`-device virtio-net-pci` is the *transitional* device (id `0x1000`),
which is invisible to that driver and yields a guest with no
`/net/ether0` and no DNS.

Go tests that create local TCP listeners or do `LookupHost` should be
treated as harness failures until `/net/cs`, loopback, and the DHCP'd
ether interface are all present.

## Swap Setup

After network setup, both guest scripts pre-allocate a 1 GiB swap file at
`/tmp/swap` and enable it with 9front's `swap` command (`swap /tmp/swap`,
which opens the file and writes its fd to `/dev/swap`). The file lives on
the snapshot overlay so it does not modify the underlying qcow2 image and
it disappears when QEMU exits. The swap size is limited because the hjfs
partition inside the 9front 11724 ARM64 qcow2 image is only ~3.7 GiB
virtual, with about 2 GiB free after the base system; a 2 GiB swap file
overflows hjfs and the kernel logs `executeio: disk full` instead of
backing pages. With 2 GiB user RAM plus the 1 GiB swap, the page-allocator
simulation tests no longer trip Plan 9's user memory limit.

## Tests

The default guest script runs focused compiler and assembler tests:

```text
cmd/compile/internal/syntax
cmd/internal/obj/arm64
cmd/asm/internal/asm
cmd/compile/internal/types
cmd/compile/internal/types2
cmd/compile/internal/ssa
cmd/compile/internal/ssagen
cmd/compile/internal/test
```

It also runs one vet-enabled sanity pass for
`cmd/compile/internal/syntax`.

To run a custom package list:

```sh
misc/plan9/arm64/run-qemu-tests.sh -- runtime syscall os time
```

Leading arguments beginning with `-` are passed through to `go test` for each
package. This is useful for focused triage:

```sh
misc/plan9/arm64/run-qemu-tests.sh -- '-v' '-run=^TestArenaCollision$' runtime
```

To run `go tool dist test` instead of package tests, select the dist guest
script. The script copies the staged VVFAT GOROOT into `/tmp/goroot` first so
`dist test` can reinstall tools into a writable `$GOROOT/pkg/tool` directory.
Pass dist flags after `--`; the host runner quotes each argument for Plan 9
`rc`, so flags with `=` are safe:

```sh
PLAN9_TEST_SCRIPT=/n/dos/misc/plan9/arm64/guest-dist-tests.rc \
PLAN9_TEST_WAIT=7200 timeout 7800s \
  misc/plan9/arm64/run-qemu-tests.sh -- '-run=^runtime$'
```

To reproduce intermittent native compiler/cache corruption with a clean
cache, use the native rebuild script. Its first argument controls both
`GOMAXPROCS` and `go build -p`:

```sh
PLAN9_TEST_SCRIPT=/n/dos/misc/plan9/arm64/guest-native-rebuild.rc \
PLAN9_SMP=4 PLAN9_TEST_WAIT=7200 timeout 7800s \
  misc/plan9/arm64/run-qemu-tests.sh -m 3072 -- 4
```

`guest-native-rebuild-stress.rc` repeats fresh-cache builds of the packages
from the compiler crash reports on Gerrit CL 719643.

## Optional: Build a Patched 9front Kernel

The harness can stage three files from a patched 9front checkout:
`sys/src/9/ip/tcp.c`, `sys/src/9/port/proc.c`, and
`sys/src/9/port/fault.c`. These cover the spliced-loopback close fixes,
the SMP TLB-shootdown fix, and the shared-segment COW flush. The rebuild
script installs the staged files and verifies them end-to-end against a
writable 9front qcow2.

Workflow:

```sh
# 1. Take a writable copy of the stock 9front image.
cp tmp-9front-test/9front-11724.arm64.qcow2 \
   tmp-9front-test/9front-11724-patched.arm64.qcow2

# 2. Stage patched tcp.c, proc.c, and fault.c into the share dir.
PLAN9_KERNEL_SRC=../9front \
  misc/plan9/arm64/make-goroot-share.sh

# 3. Boot, install the staged kernel sources, mk install, copy 9qemu
#    into /n/9fat, and shut down.
misc/plan9/arm64/rebuild-9front-kernel.sh

# 4. Re-run probe / tests pointing at the patched image.
PLAN9_IMAGE=tmp-9front-test/9front-11724-patched.arm64.qcow2 \
PLAN9_TEST_SCRIPT=/n/dos/misc/plan9/arm64/guest-loopback-close-probe.rc \
  misc/plan9/arm64/run-qemu-tests.sh -m 1024
```

The kernel rebuild script `misc/plan9/arm64/rebuild-9front-kernel.sh`
deliberately runs without `snapshot=on` so the rebuilt kernel
persists.  It expects the share to contain
`misc/plan9/arm64/tcp.c.patched` and
`misc/plan9/arm64/guest-kernel-rebuild.rc`; both ship in this
directory.

The build script writes to `/n/9fat/9qemu` and `/n/9fat/9qemu.u`
(the U-Boot image), so subsequent boots use the patched kernel
without further intervention.

## Vet Flag Note

Plan 9 `rc` treats `=` as syntax, so `-vet=off` must be quoted when typed
directly:

```rc
go test '-vet=off' ./...
```

The default guest test script uses:

```rc
GOFLAGS='-vet=off' go test ...
```

Even when vet is disabled, the Go command currently resolves the `vet` tool
path during `go test`, so `make-goroot-share.sh` copies the full
`pkg/tool/plan9_arm64` directory into the guest share.
