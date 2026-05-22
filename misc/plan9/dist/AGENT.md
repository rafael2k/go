# Build-and-Publish Agent — Plan 9 / 9front Go bootstrap

You produce a six-file static drop and place it behind a single public
HTTP(S) base URL so 9front users can `hget` a Go bootstrap straight onto
their machine.

Inputs to you: a clean checkout of this Go repo (branch `plan9-arm64-dev`
or any branch that contains `misc/plan9/dist/`) and a target webroot you
control.

Output: six URLs under one base, all returning the expected bytes.

---

## 0. The six files

Final webroot must look exactly like:

```
$BASE_URL/
├── go-plan9-amd64.tar.gz   ~66 MiB   Go bootstrap, plan9/amd64
├── go-plan9-arm64.tar.gz   ~62 MiB   Go bootstrap, plan9/arm64
├── go-src.tar.gz           ~34 MiB   matching source archive
├── SHA256SUMS                256 B   sha256 of the three tarballs above
├── index.md                ~3 KiB    markdown landing page
└── index.html              ~5 KiB    standalone HTML landing page
```

All links inside `index.md` / `index.html` are relative, so the drop is
self-contained and can be hosted at any path.

No other files. Don't publish `AGENT.md`, the build script, the
`templates/` directory, or anything from `tmp-9front-dist/` that isn't
listed above.

---

## 1. Prereqs on the build host

- Linux or macOS host (the script is tested on Linux).
- `bash`, `git`, `tar`, `gzip`, `sha256sum` (coreutils), `sed`, `numfmt`.
- A Go bootstrap that `src/make.bash` accepts (Go >= 1.22 for Go tip).
- ~3 GiB free under the repo root (host toolchain + cross builds + tmp).
- Network access for whatever transport your webroot uses
  (`scp` / `rsync` / `aws s3 cp` / `gh release upload` / web panel …).

You should also have the `upstream` remote configured if you want the
landing page to record the upstream base commit accurately:

```sh
git -C $REPO remote add upstream https://go.googlesource.com/go
git -C $REPO fetch upstream master
```

Without `upstream`, the rendered page just says "upstream base: unknown".

---

## 2. Build phase — fully scripted

Everything in this phase is deterministic and lives in
`misc/plan9/dist/build-bootstrap.sh`.  Run it from anywhere inside the
repo:

```sh
cd $REPO
# Optional, recommended once you know the public URL.
# If unset, templates keep the literal "BASE-URL" placeholder so you can
# substitute it after upload.
export BASE_URL=https://your-host.example.com/path/to/go-plan9/

bash misc/plan9/dist/build-bootstrap.sh
```

What the script does:

1. Moves any `tmp-9front-*` scratch dirs at the repo root into a sibling
   `tmp-distpack-stash.XXXX/` so they don't trip `cmd/distpack`, and
   restores them on exit.
2. Writes a `VERSION` file
   (`go1.27-devel-plan9arm64-<short-sha>` + `time <ISO-8601>`) and clears
   `VERSION.cache`.
3. Runs `src/make.bash` to rebuild the host toolchain matching HEAD
   (skip with `SKIP_HOST_BUILD=1` if you know `bin/go` already matches
   HEAD; the version string written into the tarballs will otherwise be
   stale).
4. Runs `GOOS=plan9 GOARCH=amd64 src/make.bash -distpack`, then drains
   `pkg/distpack/` into `$OUT_DIR/` (`OUT_DIR` defaults to
   `$REPO/tmp-9front-dist`).
5. Same for `GOOS=plan9 GOARCH=arm64`.
6. Renames to short, hostable names: `go-plan9-{amd64,arm64}.tar.gz` and
   `go-src.tar.gz`.
7. Writes `SHA256SUMS` (`sha256sum` of the three tarballs).
8. Renders `index.md` and `index.html` from
   `misc/plan9/dist/templates/index.{md,html}.tmpl`, substituting
   `@@VERSION@@`, `@@SHA256_*@@`, `@@SIZE_*@@`, `@@SOURCE_COMMIT@@`,
   `@@UPSTREAM_BASE@@`, `@@BUILD_DATE@@`, `@@BASE_URL@@`.
9. Removes the temporary `VERSION` file and unstashes the `tmp-*` dirs.

Final layout:

```
$REPO/tmp-9front-dist/
├── go-plan9-amd64.tar.gz
├── go-plan9-arm64.tar.gz
├── go-src.tar.gz
├── SHA256SUMS
├── index.md
└── index.html
```

That's all six files. If anything else lands in there, delete it before
publishing.

### Local sanity checks (do these before uploading)

```sh
cd $REPO/tmp-9front-dist

# 1. Six files, no surprises.
ls -1
# expect: SHA256SUMS  go-plan9-amd64.tar.gz  go-plan9-arm64.tar.gz
#         go-src.tar.gz  index.html  index.md

# 2. Checksums round-trip locally.
sha256sum -c SHA256SUMS

# 3. Each tarball is well-formed and starts with a single "go/" prefix.
for f in go-plan9-amd64.tar.gz go-plan9-arm64.tar.gz go-src.tar.gz; do
    echo "=== $f ==="
    tar -tzf "$f" | head -5
done

# 4. VERSION inside the tarballs matches what the landing page advertises.
tar -xzOf go-plan9-amd64.tar.gz go/VERSION
grep -E '^- Version: ' index.md
```

Both `tar` commands above must yield the same version string. If they
don't, abort — you have a stale build.

---

## 3. Publish phase — the actual upload

This step depends on the transport your webroot expects. The contract is:

- Same six filenames, no renames, no recompression.
- Same byte-for-byte content (no text-mode mangling on Windows or FTP).
- World-readable (`0644`), no authentication required to download.
- Plain HTTPS (or HTTP) under a single hostname + path. No cross-origin
  redirects, no JS challenges; 9front's `hget` cannot solve them.

### Suggested MIME types

| extension       | MIME type                          |
|-----------------|------------------------------------|
| `*.tar.gz`      | `application/gzip`                 |
| `SHA256SUMS`    | `text/plain; charset=utf-8`        |
| `*.md`          | `text/markdown; charset=utf-8`     |
| `*.html`        | `text/html; charset=utf-8`         |

### Example transports

`scp` / `rsync` to a static webroot:

```sh
rsync -av --chmod=F644 tmp-9front-dist/ \
    user@host:/var/www/yourdomain/go-plan9/
```

S3-compatible object storage:

```sh
aws s3 cp tmp-9front-dist/ s3://your-bucket/go-plan9/ \
    --recursive --acl public-read \
    --exclude '*' --include 'go-plan9-*.tar.gz' --include 'go-src.tar.gz' \
    --content-type application/gzip

aws s3 cp tmp-9front-dist/SHA256SUMS s3://your-bucket/go-plan9/ \
    --acl public-read --content-type 'text/plain; charset=utf-8'

aws s3 cp tmp-9front-dist/index.md   s3://your-bucket/go-plan9/ \
    --acl public-read --content-type 'text/markdown; charset=utf-8'

aws s3 cp tmp-9front-dist/index.html s3://your-bucket/go-plan9/ \
    --acl public-read --content-type 'text/html; charset=utf-8'
```

GitHub release (no per-file MIME control, but Plan 9's `hget` doesn't
care about the response Content-Type):

```sh
gh release create plan9-go-$(date +%Y%m%d) \
    --title "Go for 9front (plan9/amd64 + plan9/arm64)" \
    --notes-file tmp-9front-dist/index.md \
    tmp-9front-dist/go-plan9-amd64.tar.gz \
    tmp-9front-dist/go-plan9-arm64.tar.gz \
    tmp-9front-dist/go-src.tar.gz \
    tmp-9front-dist/SHA256SUMS
```

(For GitHub releases, the resulting URLs are awkward for `hget`; prefer a
real static host if you can.)

### Re-stamp templates after upload (only if you ran the build without
`BASE_URL`)

```sh
sed -i "s|BASE-URL|$BASE_URL|g" tmp-9front-dist/index.md tmp-9front-dist/index.html
# then re-upload index.md and index.html
```

---

## 4. Post-upload verification

All four checks must pass.

```sh
BASE_URL=https://your-host.example.com/path/to/go-plan9

# 1. Each URL returns 200 and the expected byte length.
for f in go-plan9-amd64.tar.gz go-plan9-arm64.tar.gz go-src.tar.gz \
         SHA256SUMS index.md index.html; do
    remote=$(curl -fsSLI "$BASE_URL/$f" | awk '/[Cc]ontent-[Ll]ength/{print $2}' | tr -d '\r')
    local=$(stat -c%s "tmp-9front-dist/$f")
    printf '%-25s remote=%s local=%s %s\n' "$f" "$remote" "$local" \
        "$([ "$remote" = "$local" ] && echo OK || echo MISMATCH)"
done

# 2. SHA256 round-trips over the wire.
tmp=$(mktemp -d) && cd "$tmp"
curl -fsSLO "$BASE_URL/SHA256SUMS"
for f in go-plan9-amd64.tar.gz go-plan9-arm64.tar.gz go-src.tar.gz; do
    curl -fsSLO "$BASE_URL/$f"
done
sha256sum -c SHA256SUMS

# 3. Inside-tarball VERSION matches landing-page version.
v_amd64=$(tar -xzOf go-plan9-amd64.tar.gz go/VERSION | head -1)
v_arm64=$(tar -xzOf go-plan9-arm64.tar.gz go/VERSION | head -1)
v_page=$(curl -fsSL "$BASE_URL/index.md" | sed -nE 's/^- Version: `(.+)`/\1/p')
[ "$v_amd64" = "$v_arm64" ] && [ "$v_amd64" = "$v_page" ] && echo "version OK"

# 4. index.html renders and its three Download links resolve.
curl -fsSI "$BASE_URL/index.html" >/dev/null
for link in go-plan9-amd64.tar.gz go-plan9-arm64.tar.gz go-src.tar.gz; do
    curl -fsSI "$BASE_URL/$link" >/dev/null
done
echo "links OK"
```

If any of these fails, do **not** announce the URL — fix and re-verify
first. A bad `SHA256SUMS` line or a stale `index.md` will silently break
the install for everyone who follows it.

---

## 5. Final report (machine-readable)

When everything passes, emit:

```yaml
base_url: https://your-host.example.com/path/to/go-plan9/
version:  go1.27-devel-plan9arm64-<short-sha>
artifacts:
  - https://your-host.example.com/path/to/go-plan9/go-plan9-amd64.tar.gz
  - https://your-host.example.com/path/to/go-plan9/go-plan9-arm64.tar.gz
  - https://your-host.example.com/path/to/go-plan9/go-src.tar.gz
  - https://your-host.example.com/path/to/go-plan9/SHA256SUMS
  - https://your-host.example.com/path/to/go-plan9/index.md
  - https://your-host.example.com/path/to/go-plan9/index.html
sha256_ok: true
size_ok:   true
landing_page: https://your-host.example.com/path/to/go-plan9/
```

Hand `base_url` back to the maintainer of this repo. They'll wire it
into `misc/plan9/dist/install-go.rc` (the 9front-native installer that
performs `hget | gunzip | tar x` plus profile patching).

---

## 6. Non-goals (do not do)

- Do **not** edit, re-tar, or rename the three `*.tar.gz` files.
- Do **not** strip the `VERSION` file from inside the tarballs; the
  installer cross-checks it against `SHA256SUMS` and `index.md`.
- Do **not** require authentication, paywalls, or non-standard TLS
  features.
- Do **not** mix multiple build runs into one webroot; if you rebuild,
  re-publish all six files together so `SHA256SUMS` stays consistent
  with the tarballs.
- Do **not** publish the contents of `tmp-9front-test/` or other dev
  scratch dirs.
- Do **not** publish `misc/plan9/dist/AGENT.md`, `build-bootstrap.sh`,
  or `templates/`. Those stay in the source repo.

---

## 7. Trouble-shooting

| symptom | likely cause | fix |
|---|---|---|
| `distpack: unexpected source archive file: .../tmp-9front-*` | leftover scratch dir at the GOROOT root | the script stashes them automatically; if you got here, the stash trap didn't run — move them by hand and rerun |
| `distpack: open .../VERSION: no such file or directory` | a previous run aborted before recreating VERSION | rerun the script; it writes a fresh `VERSION` every time |
| `go tool dist: VERSION: unexpected line: Time …` | wrong keyword case in `VERSION` | must be lowercase `time` on line 2 (the script does this for you) |
| `hget` succeeds on Linux but 9front sees a zero-byte file | server returns chunked encoding without `Content-Length`, and 9front's `hget` then reads zero | force a normal `Content-Length` response, or pre-stage the file via `wget` from a Linux box and `import` into 9front |
| Different version strings between `index.md` and the in-tarball `VERSION` | a partial re-render after rebuilding only one arch | always rerun the full `build-bootstrap.sh` so all six files share one provenance, then re-upload all six |
