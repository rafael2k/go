# Plan 9 AMD64 QEMU Test Harness

This directory mirrors `misc/plan9/arm64/` for the `plan9/amd64`
port.  It is the easier of the two harnesses because:

- `qemu-system-x86_64` runs under KVM, so the guest runs at near
  native speed (the focused compiler suite finishes in a few minutes
  vs ~60 min for arm64 TCG).
- No external firmware is needed -- the 9front amd64 qcow2 ships
  with its own boot sector.
- The boot disk is virtio-blk (`/dev/sdF0`), so it does not collide
  with the USB-storage Go share.

The same kernel bug as on arm64 (`tcpsplice` peer-close races, see
`misc/plan9/arm64/test-report.md`) is reproducible bit-for-bit on
amd64, and the same `tcp.c` patch fixes both.  The amd64 harness is
therefore primarily useful for: (a) confirming that the bug is not
arch-specific when reviewing upstream changes, and (b) running the
compiler / runtime tests much faster than under arm64 TCG.

## Host Dependencies

- `qemu-system-x86_64` with KVM (`/dev/kvm` accessible to the user)
- `wget` or `curl`, `gzip`
- `mtools` (`mformat` + `mcopy`) for the FAT image share

On Debian/Ubuntu:

```sh
sudo apt install qemu-system-x86 qemu-utils wget mtools
```

## Basic Workflow

From the Go repository root:

```sh
# 1. Download and unpack a 9front amd64 QEMU disk image (11734 by default).
misc/plan9/amd64/fetch-9front-image.sh

# 2. Cross-build Go for plan9/amd64 and stage a FAT image share.
misc/plan9/amd64/make-goroot-share.sh

# 3. Boot 9front and run the focused compiler tests.
misc/plan9/amd64/run-qemu-tests.sh
```

The default image is `tmp-9front-test/9front-11734.amd64.qcow2`.
The default Go share is `tmp-9front-amd64-goroot` plus
`tmp-9front-amd64-goroot.img`.  Both forms are populated by
`make-goroot-share.sh`; `run-qemu-tests.sh` prefers the `.img` file
when present.

## QEMU Notes

The working QEMU shape is:

```sh
qemu-system-x86_64 \
  -M q35 -accel kvm -cpu host -smp 4 -m 3072 \
  -drive if=virtio,file=tmp-9front-test/9front-11734.amd64.qcow2,format=qcow2,snapshot=on \
  -device qemu-xhci \
  -drive if=none,file=tmp-9front-amd64-goroot.img,format=raw,id=share0,snapshot=on \
  -device usb-storage,drive=share0 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -nographic -serial mon:stdio
```

If KVM is unavailable, pass `-accel tcg` and pick a portable cpu, e.g.
`-cpu qemu64`:

```sh
PLAN9_ACCEL=tcg PLAN9_CPU=qemu64 misc/plan9/amd64/run-qemu-tests.sh
```

The Go share device is auto-discovered the same way as on arm64: the
guest script picks the first `/dev/sdU*/<part>` that is not also a
boot disk (no `/fs`, no `/9fat`).

## Network Setup

The serial-console boot path does not run the normal `termrc`/`cpurc`
network setup, and 9front boot starts `ndb/cs` *before* any IP
interfaces exist, so cs's `dnsipvers` is 0 and any `LookupHost`
returns `cs: no ip address`.  The guest script therefore:

1. Kills the boot-time `ndb/cs` and `ndb/dns` so we own them.
2. Configures loopback (`127.0.0.1`, `::1`).
3. If `/net/ether0` exists, brings it up over slirp DHCP
   (`ip/ipconfig ether /net/ether0`).  The user-mode network hands
   the guest `10.0.2.15`, a default route via `10.0.2.2`, and a DNS
   server at `10.0.2.3`.
4. Restarts `ndb/cs` and `ndb/dns -r` so they see the new interfaces
   and run as our user (only the owner can refresh cs).

On amd64 the default `-device virtio-net-pci` works because 9front's
amd64 kernel ships the legacy `ethervirtio` driver alongside
`ethervirtio10`.  (Arm64 has only `ethervirtio10` and therefore
requires `-device virtio-net-pci-non-transitional`; see the arm64
README.)

## Tests

The default guest script runs:

```text
cmd/compile/internal/syntax
cmd/internal/obj/x86
cmd/asm/internal/asm
cmd/compile/internal/types
cmd/compile/internal/types2
cmd/compile/internal/ssa
cmd/compile/internal/ssagen
cmd/compile/internal/test
```

plus a vet-enabled sanity pass.  Custom package lists work just like
on arm64:

```sh
misc/plan9/amd64/run-qemu-tests.sh -- runtime syscall os time
```

## Optional: Build a Patched 9front amd64 Kernel

```sh
# 1. Take a writable copy of the stock 9front image.
cp tmp-9front-test/9front-11734.amd64.qcow2 \
   tmp-9front-test/9front-11734-patched.amd64.qcow2

# 2. Stage the patched tcp.c into the share dir.
PLAN9_KERNEL_SRC=../9front \
  misc/plan9/amd64/make-goroot-share.sh

# 3. Boot, apply the patch, mk 'CONF=pc64' install, copy 9pc64 into
#    /dev/sdF0/9fat (via dossrv), shut down.
misc/plan9/amd64/rebuild-9front-kernel.sh

# 4. Re-run probe / tests pointing at the patched image.
PLAN9_IMAGE=tmp-9front-test/9front-11734-patched.amd64.qcow2 \
PLAN9_TEST_SCRIPT=/n/dos/misc/plan9/amd64/guest-loopback-close-probe.rc \
  misc/plan9/amd64/run-qemu-tests.sh -m 1024
```

Verified end-to-end: the patched kernel converts the "silent 1 GiB
cap" into "writes fail within ~10 ms of peer close", matching the
arm64 behaviour after the same patch.
