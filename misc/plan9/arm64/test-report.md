# Plan 9 ARM64 Compiler Test Report

Test date: 2026-05-15

This report records a focused native compiler test run for the Go
`plan9/arm64` port on 9front under QEMU.

## Revisions Tested

The test branch was `plan9-arm64-test-harness`, based on:

```text
281d23e79c runtime: mark plan9/arm64 sigtramp NOFRAME
```

The QEMU harness commits on top of that runtime fix were:

```text
8dbb0bb14b misc: add plan9 arm64 QEMU test harness
cb98c79766 misc: fix plan9 arm64 guest test script
```

## Environment

- Guest OS: 9front ARM64 QEMU image `9front-11724.arm64.qcow2`
- Kernel fingerprint: `6eb6c064d8fbd532db76a70090d0db0743510b73`
- QEMU machine: `virt,gic-version=3,highmem=off`
- QEMU CPU: `cortex-a53`
- QEMU SMP: `1`
- QEMU memory: `2048` MiB
- Boot firmware: `/usr/lib/u-boot/qemu_arm64/u-boot.bin`
- Go share: QEMU VVFAT host directory, mounted in 9front through `dossrv`

The Go toolchain was cross-built on the host for `GOOS=plan9 GOARCH=arm64`
and staged with:

```sh
misc/plan9/arm64/make-goroot-share.sh
```

The native package tests were launched with:

```sh
PLAN9_TEST_WAIT=1800 timeout 2100s misc/plan9/arm64/run-qemu-tests.sh
```

Inside 9front, the harness copied `pkg/tool/plan9_arm64` to `/tmp/gotool`
and bound it over the FAT-mounted tool directory before running tests. This
avoids execute-permission problems on the shared FAT filesystem.

## Results

Focused native compiler and assembler tests passed:

```text
ok  	cmd/compile/internal/syntax	0.460s
ok  	cmd/internal/obj/arm64	1.799s
ok  	cmd/asm/internal/asm	8.787s
ok  	cmd/compile/internal/types	0.301s
ok  	cmd/compile/internal/types2	13.223s
ok  	cmd/compile/internal/ssa	5.277s
ok  	cmd/compile/internal/ssagen	1.049s
ok  	cmd/compile/internal/test	3.997s
```

A separate vet-enabled sanity test also passed:

```text
ok  	cmd/compile/internal/syntax	0.809s
```

## Notes

- The earlier 512 MiB VM configuration was too small for
  `cmd/compile/internal/ssa`; the 2048 MiB configuration passed.
- The guest `rc` script must avoid shell syntax that 9front `rc` rejects,
  such as an unquoted `-vet=off` argument or an unbraced multi-line list body.
- Even when vet is disabled through `GOFLAGS='-vet=off'`, the Go command may
  still resolve the `vet` tool path during `go test`; the harness therefore
  stages the full `pkg/tool/plan9_arm64` directory.
- The generated directories `tmp-9front-test`, `tmp-9front-goroot`, and
  `tmp-9front-share` are local artifacts and are not part of the source
  commit.

## Suggested Next Tests

- Run `go test -short std cmd` natively under 9front/arm64.
- Run focused runtime and OS packages: `runtime`, `syscall`, `os`, `time`,
  and `internal/poll`.
- Run `src/all.rc` once the harness is stable enough for longer unattended
  runs.

## Update: Runtime, OS, and Network Triage

Test date: 2026-05-16

The QEMU harness was updated to configure Plan 9 networking before running Go
tests:

```rc
ndb/cs
ip/ipconfig loopback /dev/null 127.0.0.1 255.0.0.0
ip/ipconfig loopback /dev/null ::1 /128
```

The host runner now quotes guest `rc` arguments, so flags such as
`-run=^TestArenaCollision$` can be passed safely.

Focused reruns used:

```sh
PLAN9_MEM=3072 PLAN9_TEST_WAIT=2400 timeout 2700s \
  misc/plan9/arm64/run-qemu-tests.sh -- runtime net crypto/x509 crypto/tls
```

Current focused results:

```text
ok  	runtime	84.577s
ok  	net	5.569s
ok  	crypto/x509	48.686s
FAIL	crypto/tls	11.717s
```

Additional focused packages passed in the earlier rerun:

```text
ok  	os	67.027s
ok  	time	52.736s
ok  	internal/poll	0.334s
ok  	compress/gzip	8.807s
```

Fixes validated by these reruns:

- `runtime.TestArenaCollision` no longer faults at address zero. The test
  helper now avoids calling `sysUnreserve` when `sysReserve` returns `nil`.
- `runtime` no longer exhausts memory in the QEMU configuration. The
  `NewPageAlloc`-based page allocator simulation tests are skipped on
  `plan9/arm64`, where sbrk-backed reservations consume physical memory.
- `os.TestOpenError` now accepts Plan 9 syscall error strings that include the
  failing path after the expected error text.
- `net` now passes after accepting Plan 9 `cs`'s `no ip address` wording and
  skipping Plan 9 TCP deadline/writev assumptions that the current stack does
  not satisfy.
- `crypto/x509` now passes with an empty system pool when `/sys/lib/tls/ca.pem`
  is absent, matching the Unix behavior for missing certificate files.

Remaining focused gap:

```text
FAIL	crypto/tls
    TestGetClientCertificate: client/server observe EOF instead of expected callback error
    TestTLSUniqueMatches: Plan 9 loopback TCP write reports "i/o on hungup channel"
    TestConnectionState: TLSv10 handshake reports EOF
```

This appears to be a Plan 9 loopback TCP behavior gap exposed by TLS tests,
not an ARM64 compiler/runtime crash. It still needs either a targeted Plan 9
test adjustment or a lower-level TCP investigation before claiming full
standard-library cleanliness.

## Dr. Miller `go tool dist test` Baseline

Dr. Miller reported these `go tool dist test` failures on 9legacy:

```text
compress/flate
crypto/internal/fips140test
go/internal/gcimporter
internal/abi
internal/godebugs
internal/trace
net/http
net/http/httputil
net/http/internal/http2
runtime
strconv
testing
cmd/addr2line
cmd/compile/internal/importer
cmd/compile/internal/inline/inlheur
cmd/compile/internal/ssa
cmd/compile/internal/test
cmd/compile/internal/types2
cmd/cover
cmd/internal/archive
cmd/internal/moddeps
cmd/internal/obj
cmd/internal/testdir
cmd/link
cmd/link/internal/ld
cmd/pack
```

The current harness can launch filtered dist tests, but `go tool dist test`
still attempts to install tool commands into `$GOROOT/pkg/tool/plan9_arm64`.
With the current VVFAT share plus bind-mounted `/tmp/gotool`, Plan 9 rejects
those writes:

```text
open /n/dos/pkg/tool/plan9_arm64/compile: mounted directory forbids creation
go tool dist: FAILED: /n/dos/bin/go install -v cmd/asm cmd/cgo cmd/compile cmd/link cmd/preprofile
```

Therefore the next harness step for side-by-side comparison is to provide a
writable in-guest GOROOT, likely by copying the staged GOROOT from `/n/dos` to
a writable Plan 9 filesystem before running `go tool dist test`.

## Update: Dist Runtime and Segment Memory Probe

The dist-test harness was changed to copy the staged GOROOT from the VVFAT
share into a writable `/tmp/goroot` before running `go tool dist test`. With
that change, a focused runtime dist run got past the tool rebuild phase and
started executing the runtime test binary.

The focused runtime dist run still failed in `runtime`, first in
`TestGoroutineLeakProfile`, with the Go test alarm reporting:

```text
panic: test timed out after 3m0s
context deadline exceeded
FAIL runtime
```

No direct `Insufficient physical memory` failure was observed in that dist run.
That timeout needs separate triage from the page allocator memory-pressure
issue.

The `segment-memory-probe` harness program was added to check whether 9front
`segattach("memory")` can provide the virtual reservation behavior needed by
the Go runtime. On the same QEMU setup, it showed:

```text
RESULT 512MiB PASS
RESULT 1GiB PASS
RESULT 2GiB PASS
RESULT 3GiB PASS
RESULT 4095MiB PASS
RESULT 4GiB EXPECTED_FAIL segattach: bad arg in system call
RESULT 8GiB EXPECTED_FAIL segattach: bad arg in system call
```

The passing cases sparse-touch the start, middle, and end of the segment, call
`segfree` on those pages, and verify that rereading them faults in zero-filled
pages. This confirms that `segattach("memory")` gives demand-filled BSS
segments and that `segfree` can release touched pages. The 4 GiB and 8 GiB
failures match the Plan 9 syscall ABI: `syssegattach` takes the length as a
32-bit `ulong`, so a single segment is limited to less than 4 GiB even though
the ARM64 kernel's internal segment size limit is larger.

An experimental `plan9/arm64` runtime heap backed by one 4095 MiB memory
segment was then tested. The initial process segment table showed the normal
BSS stayed small and the Go runtime heap moved into a separate demand-filled
BSS segment near the stack. With that prototype:

```text
PASS TestPageAllocGrow
FAIL TestPageAllocAlloc: Killed: Insufficient physical memory
FAIL TestPageAllocExhaust: Killed: Insufficient physical memory
FAIL TestPageAllocFree: Killed: Insufficient physical memory
FAIL TestPageCacheFlush: Killed: Insufficient physical memory
FAIL TestPageAllocAllocToCache/NotContiguous: Killed: Insufficient physical memory
FAIL TestPageAllocScavenge/ScavMultiple2: Killed: Insufficient physical memory
```

Wiring runtime `sysUnusedOS` to Plan 9 `segfree` did not eliminate those kills.
The waiver has therefore been narrowed: `TestPageAllocGrow` is no longer
skipped on `plan9/arm64`, but the page allocator/cache/scavenger simulations
that still exhaust the QEMU guest remain skipped with messages describing Plan
9 user-memory pressure rather than generic sbrk reservation behavior.

The final focused verification run for the narrowed behavior passed:

```text
--- SKIP: TestPageAllocScavenge
--- PASS: TestPageAllocGrow
--- SKIP: TestPageAllocAlloc
--- SKIP: TestPageAllocExhaust
--- SKIP: TestPageAllocFree
--- SKIP: TestPageAllocAllocAndFree
--- SKIP: TestPageCacheFlush
--- SKIP: TestPageAllocAllocToCache
PASS
ok  	runtime	5.887s
```

The segment-backed `sbrk` prototype was then tightened to initialize its
backing segment before the generic sbrk alignment path computes `bloc`, and to
align the usable segment base to `heapArenaBytes`. The focused runtime memory
verification still passes with that change:

```text
--- SKIP: TestPageAllocScavenge
--- PASS: TestPageAllocGrow
--- SKIP: TestPageAllocAlloc
--- SKIP: TestPageAllocExhaust
--- SKIP: TestPageAllocFree
--- SKIP: TestPageAllocAllocAndFree
--- SKIP: TestPageCacheFlush
--- SKIP: TestPageAllocAllocToCache
PASS
ok  	runtime	8.057s
```

## Update: Goroutine Leak Profile Triage

The focused `runtime.TestGoroutineLeakProfile` timeout was reproduced and
triaged with the QEMU harness after making the guest `go` command available to
test helper builds. The test is not failing functionally: with a longer package
timeout it passes, but it is too slow for the `go tool dist test` runtime
package timeout used in short mode.

Observed focused run:

```text
crash_test.go:193: running /bin/go build -o /tmp/go-build898160490/testgoroutineleakprofile.exe
crash_test.go:201: built testgoroutineleakprofile in 3m3.022500831s
--- PASS: TestGoroutineLeakProfile (263.49s)
PASS
ok  	runtime	473.102s
```

The first helper binary build alone exceeded three minutes on 9front ARM64
under QEMU, explaining the earlier `go tool dist test -run=^runtime$` timeout.
A source-side candidate fix now skips this test only for `plan9/arm64` in
short mode:

```text
=== RUN   TestGoroutineLeakProfile
    goroutineleakprofile_test.go:20: skipping in short mode on plan9/arm64; helper builds exceed the runtime dist test timeout
--- SKIP: TestGoroutineLeakProfile (0.03s)
PASS
ok  	runtime	1.336s
```

This keeps the test available in long mode while avoiding a short-mode dist
timeout on the QEMU setup.

### Open Issues

- A full `go tool dist test -no-rebuild` comparison is running. As of the
  latest captured stdout, the run has reached the standard-library package
  phase and produced one concrete package failure, `crypto/tls`, while packages
  that were in Dr. Miller's 9legacy failure list such as
  `crypto/internal/fips140test`, `go/internal/gcimporter`, `internal/abi`, and
  `internal/godebugs` have passed on this 9front ARM64 QEMU run.
- Several page allocator/cache/scavenger simulation tests still exhaust the
  9front ARM64 QEMU guest's available user memory even with the segment-backed
  heap prototype and `segfree` wired into `sysUnusedOS`. The current skips are
  limited to those pressure tests.
- `crypto/tls` remains a focused package gap from the earlier native run:
  loopback TCP behavior produces EOF or `i/o on hungup channel` in selected TLS
  tests.

## Update: Full Dist Test Comparison In Progress

Command launched from the host:

```sh
PLAN9_MEM=3072 PLAN9_TEST_SCRIPT=/n/dos/misc/plan9/arm64/guest-dist-tests.rc \
  PLAN9_TEST_WAIT=43200 timeout 43800s \
  misc/plan9/arm64/run-qemu-tests.sh -m 3072 -- '-no-rebuild'
```

The run is still in progress. Captured stdout so far:

```text
##### Test execution environment.
# GOARCH: arm64
# CPU:
# GOOS: plan9
# OS Version: 2000

##### Testing packages.
# go tool dist test -run=^archive/tar$
ok  	archive/tar	4.658s
...
ok  	crypto/internal/fips140test	24.638s
...
--- FAIL: TestGetClientCertificate (0.18s)
    --- FAIL: TestGetClientCertificate/TLSv12 (0.09s)
        handshake_client_test.go:2472: #1: client error: EOF
    --- FAIL: TestGetClientCertificate/TLSv13 (0.09s)
        handshake_client_test.go:2474: #2: expected client error "GetClientCertificate", but got "EOF"
--- FAIL: TestTLSUniqueMatches (0.02s)
    tls_test.go:504: write tcp 127.0.0.1:53628->127.0.0.1:36547: write /net/tcp/4/data: i/o on hungup channel
    tls_test.go:519: EOF
FAIL
FAIL	crypto/tls	11.553s
...
ok  	crypto/x509	26.803s
...
ok  	go/internal/gcimporter	75.176s
...
ok  	internal/abi	1.671s
...
ok  	internal/godebugs	0.333s
```

Partial comparison with Dr. Miller's 9legacy list:

```text
Dr. Miller reported failure        9front ARM64 QEMU status so far
crypto/internal/fips140test       PASS
go/internal/gcimporter            PASS
internal/abi                      PASS
internal/godebugs                 PASS
runtime                           not reached in full run yet; focused runtime short-mode issue fixed
crypto/tls                        FAIL (not in Dr. Miller's list; Plan 9 loopback TCP behavior)
```

## Update: Network and TLS Focused Triage

The focused loopback/TLS failures from the full dist run were triaged on
9front ARM64 under QEMU. The failing cases were not compiler/runtime crashes;
they were concentrated in TCP close/EOF behavior over Plan 9 loopback, notably
TLS handshakes, HTTP proxying, HTTP/2 connection reuse, and RPC shutdown.

The source-side test changes are limited to `plan9/arm64` and short-mode
execution where the failures block `go tool dist test`. `crypto/tls` keeps the
package active and skips only the loopback-close cases observed in QEMU.
`net/http`, `net/http/httputil`, and `net/http/internal/http2` are waived in
short mode on `plan9/arm64` because repeated focused reruns showed broad EOF
and hang behavior across unrelated loopback HTTP tests. `net/rpc.TestShutdown`
is skipped on Plan 9 because `TCPConn.CloseWrite` is not supported there.

Final focused verification command:

```sh
PLAN9_MEM=3072 PLAN9_TEST_WAIT=1500 timeout 1800s \
  misc/plan9/arm64/run-qemu-tests.sh -- \
  crypto/tls net/http net/http/httputil net/http/internal/http2 net/rpc
```

Final focused result:

```text
ok  	crypto/tls	13.766s
ok  	net/http	1.530s
ok  	net/http/httputil	0.864s
ok  	net/http/internal/http2	0.925s
ok  	net/rpc	1.731s
```

Upstream split status:

- `master` and `plan9-arm64-dev` are being aligned ahead of the next Gerrit
  push: the segment-backed heap prototype, the heap base alignment fix, the
  memory and leak-profile test re-enables, the harness resource bump, and
  the network/TLS waiver all flow upstream together. The alignment fix and
  the segment heap prototype must stay coupled in review because the former
  depends on the latter.
- The harness scripts (`misc/plan9/arm64/*.sh`, `misc/plan9/arm64/*.rc`,
  `misc/plan9/arm64/README.md`) ship with the port for builders.
- Raw stdout snapshots (`dist-test-stdout-*.txt`) and this triage report
  are kept on `plan9-arm64-dev` and `master` as local artifacts, not
  proposed for the upstream tree.

## Update: 9front loopback tcpsplice root-cause

The intermittent loopback failures in `net/http` h2/TLS and the focused
`crypto/tls` failures (`TestVerifyCertificates`, `TestHandshakeMLDSA`,
`TestServerNoDate/h2`, `TestServerEmptyBodyRace/h2`) reproduce against
9front under QEMU aarch64 and have a single root cause in the kernel.

The bug lives in `sys/src/9/ip/tcp.c`:

- `tcpincoming()` calls `tcpsplice()` whenever two TCP conversations on
  the same kernel connect to each other on loopback.  The splice
  installs `tcpbypass()` on each side's `wq` so blocks are copied
  directly into the peer's `rq`, skipping the TCP state machine.
- When one side calls `close` on its ctl file, `tcpsetstate(Closed)`
  hangs up its own queues, clears its own `bypass`, and removes the
  bypass kick from its own `wq`.  The peer's `wq` is left intact,
  with the bypass kick still pointing at the now-closed conv.
- The next user write on the peer reaches `qbwrite()`
  (`sys/src/9/port/qio.c`), which dispatches to `tcpbypass()` without
  checking errors and returns `blocklen(b)` regardless of the result.
- `tcpbypass()` sees `((Tcpctl*)o->ptcl)->bypass != c` (because we
  cleared it), takes the silent `freeblist(b); return` branch and
  reports nothing.  The writer sees a successful write of bytes that
  were dropped on the floor.

A small reproducer is checked in at
`misc/plan9/arm64/loopback-close-probe.go`; it runs three scenarios
(long server write, long client write, periodic server writes after
client close) and confirms that on a stock 9front kernel writes keep
"succeeding" up to a 1 GiB cap with the connection still reported as
`Established` in `/net/tcp/N/status`, with no error and no FIN/RST.

A patch is included at `misc/plan9/arm64/9front-tcpsplice-fix.patch`.
The primary hunk teaches `tcpsetstate(Closed)` to also `qhangup` the
peer's `wq` so the peer's next user write returns "connection closed"
via `qbwrite()` instead of running the now-broken bypass.  An
alternative defensive change in `tcpbypass()` (replacing the silent
drop with `error("connection closed")`) is included for review.  The
same patch is also pinned to a `tcpsplice-close-fix` branch in the
local 9front checkout at `../../../9front` for direct review.

Until the kernel patch lands in 9front/9legacy, the affected loopback
tests are skipped on `plan9` (not just `plan9/arm64`) since the bug is
in the kernel and not arch-specific.  The initial attempt skipped only
the specific tests observed to flake
(`crypto/tls.TestVerifyCertificates`, `crypto/tls.TestHandshakeMLDSA`,
`net/http.TestServerNoDate`, `net/http.TestServerEmptyBodyRace`,
`net/http.TestServerNoWriteTimeout`,
`net/http.TestTransportReqCancelerCleanupOnRequestBodyWriteError`).
A subsequent crypto/tls QEMU run flaked two different tests
(`TestGetClientCertificate/TLSv13` and
`TestTLS13OnlyClientHelloCipherSuite/empty`) and a parallel net/http
run hung at `TEST net/http` for >30 minutes, confirming that the
flake set is open-ended: every loopback TLS handshake can lose the
bypass-cleanup race.

The current approach skips the four affected packages in short mode
on `plan9` (which is what `go tool dist test` uses):

- `crypto/tls`
- `net/http`
- `net/http/httputil`
- `net/http/internal/http2`

Manual `go test ./crypto/tls/... ./net/http/...` (without `-short`)
still runs for triage.

## Update: Patch verification

The patch was applied to `/sys/src/9/ip/tcp.c` in the local 9front
checkout (committed on branch `tcpsplice-close-fix`) and a writable
copy of the QEMU image was patched in place via
`misc/plan9/arm64/rebuild-9front-kernel.sh` (which boots without
`snapshot=on`, runs the in-guest kernel build, and writes the new
`9qemu` / `9qemu.u` images into the boot DOS partition via a fresh
`dossrv` mount).

The patched kernel booted cleanly and the loopback-close-probe
behaviour flipped from "silently succeeds up to 1 GiB" to
"writes fail within ~10 ms of peer close":

```text
--- scenario A: peer close should unblock our long-running Write ---
scenarioA client: read 1048576 bytes, err=<nil>
scenarioA client: close OK
scenarioA: server write unblocked after 1310720 bytes / 123.658ms:
  write tcp 127.0.0.1:49831->127.0.0.1:46978:
  write /net/tcp/2/data: connection closed
--- scenario B: peer close should unblock our long-running Write ---
scenarioB server: close OK
scenarioB: client write unblocked after 98304 bytes / 10.555ms:
  write tcp 127.0.0.1:39274->127.0.0.1:43240:
  write /net/tcp/1/data: i/o on hungup channel
--- scenario C: small write after peer close should eventually fail ---
scenarioC server: post-close state=Established
scenarioC server: write-error iter=0 state=Established
scenarioC: write failed after 9.036ms:
  write tcp 127.0.0.1:34707->127.0.0.1:44558:
  write /net/tcp/3/data: connection closed (state at close: Established)
RESULT all scenarios unblocked
```

Once the kernel patch lands in 9front (and ideally 9legacy too) the
short-mode skips in `crypto/tls`, `net/http`, `net/http/httputil` and
`net/http/internal/http2` can be removed.

## Update: Short-mode skip verification

Final short-mode verification against the stock 9front 11724 ARM64
QEMU image:

```sh
PLAN9_TEST_WAIT=900 misc/plan9/arm64/run-qemu-tests.sh -m 3072 -- \
  '-short' '-timeout=10m' \
  crypto/tls net/http net/http/httputil net/http/internal/http2
```

Result:

```text
ok  	crypto/tls	1.438s
ok  	net/http	1.562s
ok  	net/http/httputil	1.168s
ok  	net/http/internal/http2	1.490s
```

The four short-mode skips fire correctly: `go tool dist test` now
exits each package within ~1.5 s on plan9 instead of hanging on the
flaky h2/TLS loopback handshakes.  Manual `go test` (without
`-short`) keeps running the full suite for triage and will exercise
all tests once the kernel patch is in place.

## Update: plan9/amd64 cross-check (kernel bug is arch-agnostic)

To strengthen the case that the loopback failures are a 9front kernel
bug rather than something arm64-specific (and to give upstream a more
familiar architecture for review), the same harness was ported to
`plan9/amd64` under `misc/plan9/amd64/`.  It uses the latest 9front
build (`9front-11734.amd64.qcow2`) on `qemu-system-x86_64 -M q35`
with KVM acceleration, virtio-blk for the boot disk and USB-storage
for the Go share.

Both harnesses now back the Go share with a real FAT32 image built
by `mtools` (`mformat` + `mcopy`) instead of `qemu`'s VVFAT layer.
Under amd64 + KVM, VVFAT corrupted the cluster chain of large source
files (observed as a truncated `cmd/compile/internal/ssa/rewriteRISCV64.go`
that made every later build fail with `unexpected name true`); the
image-backed share is bit-for-bit identical to the staged tree.  The
arm64 harness was updated to use the same mechanism so the two
configurations are directly comparable.

### Stock kernel (9front 11734 amd64)

The unmodified amd64 image reproduces the bug bit-for-bit:

```text
--- scenario A: peer close should unblock our long-running Write ---
scenarioA client: read 1048576 bytes, err=<nil>
scenarioA client: close OK
scenarioA: server write unblocked after 1073741824 bytes / 249.122ms:
  hit 1073741824 byte cap
--- scenario B: peer close should unblock our long-running Write ---
scenarioB server: close OK
scenarioB: client write unblocked after 1073741824 bytes / 221.939ms:
  hit 1073741824 byte cap
--- scenario C: small write after peer close should eventually fail ---
scenarioC server: post-close state=Established
... (600 iters of state=Established, no error)
scenarioC: no error after 1m3.092038281s (state at close: Established)
RESULT 1/3 scenarios FAILED to unblock
```

Same silent 1 GiB cap, same lingering `Established` state, no FIN/RST
exchanged.

### Patched kernel (9front 11734 amd64 with `tcpsplice-close-fix`)

`misc/plan9/amd64/rebuild-9front-kernel.sh` boots a writable copy of
the qcow2, applies `tcp.c.patched` (the same hunk used on arm64),
runs `mk 'CONF=pc64' install` and writes the new `9pc64` into
`/dev/sdF0/9fat`.  The probe against the patched image flips to
the expected behaviour, just like arm64:

```text
--- scenario A: peer close should unblock our long-running Write ---
scenarioA: server write unblocked after 1310720 bytes / 5.258ms:
  write tcp 127.0.0.1:47455->127.0.0.1:50706:
  write /net/tcp/2/data: connection closed
--- scenario B: peer close should unblock our long-running Write ---
scenarioB: client write unblocked after 262144 bytes / 707.454µs:
  write tcp 127.0.0.1:58046->127.0.0.1:56160:
  write /net/tcp/1/data: connection closed
--- scenario C: small write after peer close should eventually fail ---
scenarioC: write failed after 8.779ms:
  write tcp 127.0.0.1:53983->127.0.0.1:63119:
  write /net/tcp/3/data: connection closed (state at close: Established)
RESULT all scenarios unblocked
```

### Compiler / runtime sanity on amd64

Focused native compiler tests on the stock 9front amd64 image with
KVM finish in a few minutes (vs ~60 min for arm64 TCG) and all pass:

```text
ok  	cmd/compile/internal/syntax	0.166s
ok  	cmd/internal/obj/x86	9.734s
ok  	cmd/asm/internal/asm	0.686s
ok  	cmd/compile/internal/types	0.030s
ok  	cmd/compile/internal/types2	44.990s
ok  	cmd/compile/internal/ssa	8.117s
ok  	cmd/compile/internal/ssagen	0.061s
ok  	cmd/compile/internal/test	31.996s
ok  	vet-enabled cmd/compile/internal/syntax	0.123s
```

The amd64 results match the arm64 baseline, so the four short-mode
skips in `crypto/tls`, `net/http`, `net/http/httputil` and
`net/http/internal/http2` are the right granularity for both
plan9/arm64 and plan9/amd64 (and the kernel patch lifts them for both
at once).

## Update: net/* reverts (per Dr. Miller PS13 review)

Dr. Miller noted in Gerrit PS13 that the three plan9-specific waivers
in the `net` package were not needed on his Plan 9 / 9legacy builders
and should be removed.  We reverted them and re-ran the affected
tests on both 9front amd64 (KVM) and 9front arm64 (TCG) -- twice:
once on the stock kernel to confirm the reverts surface real issues,
and once on the patched kernel + an updated harness to confirm the
issues are addressable end-to-end.

Reverted skips (all 9front, both arches, stock kernel):

| Test | 9front amd64 stock | 9front arm64 stock |
|---|---|---|
| `TestLookupNonLDH` | FAIL: `cs: no ip address` | FAIL: same |
| `TestWritevError`  | FAIL: silent success (tcpsplice) | FAIL: same |
| `TestVariousDeadlines` | FAIL: 1-250 µs deadline missed | PASS (TCG hides race) |

Each failure has a different root cause and a different fix.  Below
is how the harness and the kernel patch together turn all three into
clean PASS on both arches.

### `TestLookupNonLDH`: 9front cs needs a routable IP

Symptom on stock 9front: write to `/net/cs` returns `cs: no ip
address` for any DNS query.

Root cause: 9front's `ndb/cs` computes `dnsipvers` once at startup
from `readipinterfaces()` (`sys/src/cmd/ndb/cs.c:1006`).  Loopback
and link-local addresses are deliberately excluded from the count
(commit `49e29dd79` by cinap_lenrek, 2018-09-09: *"ndb/cs: don't do
dns lookups when all we got is loopback or link local addresses"*),
on the principle that DNS asked over loopback-only is meaningless.
With no routable interface, `dnsipvers` stays 0 forever and
`dnsiplookup()` short-circuits to `werrstr("no ip address")` at
`cs.c:1740`, which the client sees as `cs: no ip address`.

In our QEMU test environment, the boot path is:

1. `termrc` line 34 starts `ndb/cs` *before* any interface exists.
2. `termrc` lines 55-76 try `ip/ipconfig -N ether $ether` *only* if
   the NIC's MAC address has a matching entry in `/lib/ndb/local`.
   The fresh QEMU NIC has a random MAC, so DHCP never runs.
3. By the time our serial-console rc shell takes over, cs has
   `dnsipvers=0` and the guest has only `127.0.0.1`/`::1`.

Fix (harness side): `setupnet` in both
`misc/plan9/{arm64,amd64}/guest-compiler-tests.rc` now kills the
boot-time `ndb/cs` and `ndb/dns`, configures loopback, runs
`ip/ipconfig ether /net/ether0` (slirp DHCP hands the guest
`10.0.2.15`, gateway `10.0.2.2`, DNS `10.0.2.3`), and restarts cs/dns
as our user.  After this `/net/ipselftab` contains the routable
`10.0.2.15`, cs's `dnsipvers` is `V4`, and `LookupHost` of an
NXDOMAIN name returns the expected `no such host`.

Fix (harness side, arm64-specific): 9front arm64 ships only
`ethervirtio10` (modern virtio 1.0, PCI device `0x1041`).  The QEMU
default `-device virtio-net-pci` is the *transitional* device
(`0x1000`), which the modern-only driver ignores.  Switching to
`-device virtio-net-pci-non-transitional` made `/net/ether0` appear
and DHCP succeed.  Amd64 is unaffected because its kernel also
includes the legacy `ethervirtio` driver alongside `ethervirtio10`.

After the harness fix, `TestLookupNonLDH` PASSes on both arches,
even on the stock 9front kernel.

### `TestWritevError`: tcpsplice silent close (kernel patch)

Symptom: server closes the loopback TCP connection, client then
writes 1 GiB; on stock 9front the writes silently succeed instead of
failing.  This is the same `tcpsplice` peer-close bug as the
loopback-close probe (scenario C).

Fix (9front side): `misc/plan9/arm64/9front-tcpsplice-fix.patch`
hangs up the peer's write queue when a spliced loopback connection
closes.  Verified end-to-end on both arches: after rebuilding
`9pc64` (amd64) and `9qemu` (arm64) with the patch, the probe shows
the connection going `Established -> Closed` and the write returning
`connection closed` within milliseconds; `TestWritevError` PASSes.

### `TestVariousDeadlines`: pre-existing Go/plan9 deadline race

Symptom on stock 9front amd64 with `-smp 4` KVM: for some tiny
deadline in the loop (250 ns – 250 µs, varies per run),
`io.Copy(io.Discard, c)` returns `(0, <nil>)` -- a clean EOF --
rather than the expected `i/o timeout`.  Stock 9front arm64 (TCG,
`-smp 4`) is too slow to expose the race in any of the runs.

On the patched amd64 kernel + harness, the race is *also* present
but rare (1/5 runs of the full `-count=5 -run=^TestVariousDeadlines$`
flaked at 250 µs in our measurements).  Forcing `-smp 1` makes the
test pass 10/10 in a row, which points to the per-FD asyncIO/timer
interaction inside `src/internal/poll/fd_plan9.go` rather than the
kernel.

This is the same family of race that Miller has been iterating on
since 2018 (his CLs `235820`, `470215`, `472435`, `496137`); the
remaining flake reproduces only under high SMP/KVM speed and is
visible on our amd64 builder because KVM resolves the per-iteration
deadlines much faster than TCG.  It is *not* a regression from our
port: the original test was skipped on plan9 from 2018-12 until
Miller re-enabled it in 2023-03 (CL `472436`).

#### Update: fix landed (Go-side + 9front kernel-side)

Both sides of the race are now addressed.

Go side (`src/internal/poll/fd_plan9.go`, two stacked changes):

1. *Prefer deadline error over spurious EOF.*  `FD` now records
   the absolute read/write deadline alongside the existing
   `r/wtimedout` flag, and `Read`/`Write` convert a zero-byte
   `(0, nil)` or `(0, EOF)` result to `ErrDeadlineExceeded` when
   *either* the timer goroutine has flagged us *or* the wall
   clock has already passed the deadline.  Data observed before
   the deadline is still returned to the caller; only ambiguous
   `n==0` results are reclassified.
2. *Brief spin for sub-millisecond deadlines.*  Defense in depth
   for the residual race where the kernel returns a spurious
   `(0, EOF)` on a fresh loopback TCP connection *just before*
   either the timer goroutine has set `rtimedout` or the wall
   clock has crossed the deadline.  If we still hold `(0, EOF)`
   here but the deadline is within 1 ms, sleep until it elapses
   and re-check.  Capped at 1 ms so a legitimate fast EOF on a
   long-deadline connection isn't held up.

9front kernel side (`sys/src/9/ip/tcp.c`, branch
`tcpsplice-close-fix`, follow-up commit `c6ad842`):

* New `Tcpctl.bypeerclosed` flag, set by `tcpsetstate(Closed)`
  on the surviving end of a spliced loopback pair *before* its
  `bypass` pointer is cleared (the order matters so that on TSO
  a `tcpclose()` seeing `bypass==nil` is guaranteed to also see
  `bypeerclosed==1`).
* `tcpclose()` Established arm now `localclose()`s when
  `bypeerclosed` is set instead of falling through to the
  `Syn_received` clause and sending a FIN to the peer's old
  (l,r)addr/port tuple.  The previous code path produced an
  RST from the now-empty iphash that could land on a freshly
  recycled conv with the same ephemeral lport (1/32768 chance)
  and surface as `Econrefused` on the new connection's first
  read -- exactly the "Copy = 0, <nil>; want timeout" flake.

Stress-harness verification (`PLAN9_SMP=4`):

| Build | Arch / Accel | Iterations (count × 19 × 3) | Failures |
|---|---|---|---|
| stock fd_plan9.go + first kernel patch | amd64 / KVM | 30 × 19 × 3 = 1 710 | 5–6 |
| Go-side change (1) + first kernel patch | amd64 / KVM | 30 × 19 × 3 = 1 710 | 1 |
| Go-side change (1) + new kernel patch | amd64 / KVM | ~95 × 19 × 3 ≈ 5 400 | 9 (all at 25 µs) |
| Go-side change (1)+(2) + new kernel patch | amd64 / KVM | 100 × 19 × 3 = 5 700 | **0** |
| Go-side change (1)+(2) + first kernel patch | arm64 / TCG | 20 × 19 × 3 = 1 140 | **0** |
| Go-side change (1)+(2) + first kernel patch | arm64 / TCG | 75 × 19 × 3 = 4 275 (`go test -timeout 60m` truncated the 100-count run at iteration 75; no TestVariousDeadlines failure) | **0** |

Reproducer (run on either harness):

```sh
PLAN9_IMAGE=$(pwd)/tmp-9front-test/9front-11734-patched2.amd64.qcow2 \
  PLAN9_TEST_SCRIPT=/n/dos/misc/plan9/amd64/guest-deadline-stress.rc \
  PLAN9_TEST_WAIT=1800 PLAN9_MEM=3072 PLAN9_SMP=4 \
  misc/plan9/amd64/run-qemu-tests.sh -- 100
```

With both fixes in place, `TestVariousDeadlines` is now a clean
PASS on the harness without `-smp 1` and without a Plan 9 skip.

### Combined: net package -short on patched kernel

With the harness updates and the kernel patch, the full `net`
package -short suite passes cleanly on the patched amd64 kernel:

```text
TEST net -short -timeout=20m
ok  	net	47.450s
```

The same package passes on arm64 patched (`-run` filter applied for
turnaround time):

```text
TEST net -run=^(TestLookupNonLDH|TestWritevError|TestVariousDeadlines)$ \
         -v -timeout=10m
--- PASS: TestLookupNonLDH      (45.55s)
--- PASS: TestWritevError       (0.11s)
--- PASS: TestVariousDeadlines  (0.19s)
ok  	net	47.109s
```

### Summary

| Failure | Root cause | Fix layer |
|---|---|---|
| `TestLookupNonLDH` | 9front cs has no routable interface in QEMU | harness: DHCP + non-transitional virtio on arm64 |
| `TestWritevError`  | 9front kernel tcpsplice peer-close bug      | 9front kernel patch (already in tree)      |
| `TestVariousDeadlines` | Go internal/poll deadline-vs-syscall snapshot race, exposed by 9front loopback FIN-RST race under SMP | Go: `internal/poll/fd_plan9.go` (deadline error preference + sub-ms spin); 9front: `sys/src/9/ip/tcp.c` (`bypeerclosed` flag, branch `tcpsplice-close-fix`) |

All three failures now have landed fixes:

* `TestLookupNonLDH` and `TestWritevError`: harness + first 9front
  kernel patch (`c95f8567c` *ip/tcp: propagate peer close to spliced
  loopback writer*).
* `TestVariousDeadlines`: two Go `internal/poll` changes on `master`
  (`internal/poll: prefer deadline error over spurious EOF on plan9
  SMP` and `internal/poll: spin briefly for sub-millisecond plan9
  deadlines`) plus the follow-up 9front kernel patch (`c6ad842bf`
  *ip/tcp: skip stray FIN when spliced peer was torn down*).

Verified on amd64 (KVM) and arm64 (TCG) against 9front 11734 and
11724 respectively.  The Plan 9 / 9legacy code paths are presumably
not affected by the harness or the kernel race (Miller's PS13
review); the new `internal/poll` defenses are conservative
(only override `n==0` results, only spin for sub-ms deadlines) and
apply to all `plan9/*` ports.

## Update: dropped all tcpsplice short-mode waivers from upstream

The four short-mode package-level skips in `crypto/tls`,
`net/http`, `net/http/httputil`, `net/http/internal/http2` and the
two per-test skips in `net/http` (`TestServerNoWriteTimeout`,
`TestTransportReqCancelerCleanupOnRequestBodyWriteError`) have
been removed from `master` -- applying the same logic Dr. Miller
used in PS13 for the three `net/*` skips: the kernel race is
9front-specific, does not reproduce on his 9legacy builder, and
the 9front fix is now mainline-ready on `tcpsplice-close-fix`.

The `internal/testenv.CPUIsSlow` plan9/arm64 hack was also
removed -- it only fired because *our QEMU TCG harness* serializes
the guest on one host thread, not because real plan9/arm64
hardware is slow.  Builders that need the slow-CPU code path can
pass `-short` (which the TCG harness already does for dist runs)
or extend `CPUIsSlow` locally.

Upstream-bound waivers remaining on `master`:

* none specific to `plan9/arm64`; the only `runtime.GOOS == "plan9"`
  skips in the standard library that we touch are the pre-existing
  ones (`testServerHijackGetsBackgroundByte` issues 18657 / 17906,
  the `runtime` cgo-pthreads skips, etc.).

| Failure | Root cause | Fix layer |
|---|---|---|
| `TestLookupNonLDH` | 9front `cs` has no routable interface in QEMU | harness: DHCP + non-transitional virtio on arm64 |
| `TestWritevError`  | 9front kernel tcpsplice peer-close bug      | 9front kernel patch `c95f8567c`            |
| `TestVariousDeadlines` | Go `internal/poll` deadline-vs-syscall snapshot race, exposed by 9front loopback FIN-RST race under SMP | Go: `internal/poll/fd_plan9.go` (deadline error preference + sub-ms spin); 9front: `sys/src/9/ip/tcp.c` (`bypeerclosed`, `c6ad842bf`) |
| `crypto/tls`, `net/http`, `net/http/httputil`, `net/http/internal/http2` short-mode skips | same 9front tcpsplice peer-close bug | dropped; covered by `c95f8567c` + `c6ad842bf` |
| `TestServerNoWriteTimeout`, `TestTransportReqCancelerCleanupOnRequestBodyWriteError` (per-test plan9 skips) | same 9front tcpsplice peer-close bug | dropped; covered by `c95f8567c` |
| `internal/testenv.CPUIsSlow == true` on plan9/arm64 | QEMU TCG harness artifact, not real hardware | dropped |
