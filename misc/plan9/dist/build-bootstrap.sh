#!/usr/bin/env bash
# Build the seven-file webroot drop for the Plan 9 / 9front Go bootstrap.
#
# Output (default: $REPO_ROOT/tmp-9front-dist/):
#   go-plan9-amd64.tar.gz   plan9/amd64 bootstrap
#   go-plan9-arm64.tar.gz   plan9/arm64 bootstrap
#   go-src.tar.gz           matching source archive
#   SHA256SUMS              checksums of the three tarballs above
#   install-go.rc           9front rc(1) installer (run with `hget URL | rc`)
#   index.md                landing page (markdown, with BASE_URL substituted)
#   index.html              landing page (html,    with BASE_URL substituted)
#
# Environment:
#   BASE_URL          Public URL prefix where the six files will be served.
#                     Substituted into the @@BASE_URL@@ placeholder in
#                     templates/index.{md,html}.tmpl.  Default placeholder
#                     remains in output ("BASE-URL") if BASE_URL is unset,
#                     so the page can be re-stamped after upload.
#   OUT_DIR           Output directory (default: $REPO_ROOT/tmp-9front-dist).
#   GO_BOOTSTRAP      Pre-existing host go used to build (defaults to a
#                     fresh ./src/make.bash run).
#   SKIP_HOST_BUILD   Set non-empty to skip the host make.bash run (useful
#                     when GO_BOOTSTRAP already matches HEAD).
#
# Requirements on the build host:
#   - bash, git, tar, gzip, sha256sum, sed
#   - GCC or any working host Go bootstrap that make.bash accepts
#     (Go >= 1.22 is required to build Go tip).
#   - A clean GOROOT with no tmp-* directories at the root
#     (this script will stash any it finds before running distpack).

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
out_dir=${OUT_DIR:-"$repo_root/tmp-9front-dist"}
# Public webroot where the artifacts are (or will be) hosted.  The default
# matches the canonical drop maintained for the plan9/arm64 port; override
# with BASE_URL=... when republishing to a different host.
base_url=${BASE_URL:-"https://sdrtelecom.com.br/go-plan9"}
template_dir=$repo_root/misc/plan9/dist/templates

if [ ! -d "$template_dir" ]; then
	echo "build-bootstrap.sh: missing template dir: $template_dir" >&2
	exit 1
fi

log() { printf '\n=== %s\n' "$*"; }

# --- step 1: stash any tmp-* dirs at the GOROOT root --------------------
# distpack walks $GOROOT and refuses anything it didn't generate; leftover
# scratch dirs from misc/plan9 testing (or a previous bootstrap run, which
# may have left $OUT_DIR sitting inside $GOROOT) must be moved aside.
stash_dir=$(mktemp -d "$repo_root/../tmp-distpack-stash.XXXXXX")
stashed=()
shopt -s nullglob
for d in "$repo_root"/tmp-9front-* "$repo_root"/tmp-9front-*.img; do
	[ -e "$d" ] || continue
	mv "$d" "$stash_dir/"
	stashed+=("$(basename "$d")")
done
shopt -u nullglob

restore_stash() {
	for name in "${stashed[@]:-}"; do
		mv "$stash_dir/$name" "$repo_root/" 2>/dev/null || true
	done
	rmdir "$stash_dir" 2>/dev/null || true
}
trap restore_stash EXIT

if [ ${#stashed[@]} -gt 0 ]; then
	log "stashed ${#stashed[@]} tmp dir(s) to $stash_dir"
fi

# All build outputs land in a private work dir under the stash; we only
# sync them into $OUT_DIR at the very end (step 9).  This keeps $GOROOT
# clean during the two distpack runs no matter where $OUT_DIR points.
work_dir=$(mktemp -d "$stash_dir/work.XXXXXX")

# --- step 2: write VERSION file so distpack has a release name ----------
commit=$(git -C "$repo_root" rev-parse --short HEAD)
version="go1.27-devel-plan9arm64-$commit"
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)

log "writing VERSION ($version)"
{
	printf '%s\n' "$version"
	printf 'time %s\n' "$build_date"
} > "$repo_root/VERSION"
rm -f "$repo_root/VERSION.cache"

restore_full() {
	rm -f "$repo_root/VERSION"
	restore_stash
}
trap restore_full EXIT

# --- step 3: build host toolchain so we have a working bin/go -----------
if [ -z "${SKIP_HOST_BUILD:-}" ]; then
	log "building host Go toolchain (src/make.bash)"
	(cd "$repo_root/src" && bash make.bash) >/dev/null
fi

# --- step 4: cross-build + distpack for plan9/amd64 ---------------------
log "distpack plan9/amd64"
(cd "$repo_root/src" && GOOS=plan9 GOARCH=amd64 bash make.bash -distpack) >/dev/null

amd64_tgz=$(ls "$repo_root/pkg/distpack"/*plan9-amd64.tar.gz)
src_tgz=$(ls "$repo_root/pkg/distpack"/*.src.tar.gz)
mv "$amd64_tgz" "$work_dir/go-plan9-amd64.tar.gz"
mv "$src_tgz"   "$work_dir/go-src.tar.gz"
rm -f "$repo_root"/pkg/distpack/*

# --- step 5: cross-build + distpack for plan9/arm64 ---------------------
log "distpack plan9/arm64"
(cd "$repo_root/src" && GOOS=plan9 GOARCH=arm64 bash make.bash -distpack) >/dev/null

arm64_tgz=$(ls "$repo_root/pkg/distpack"/*plan9-arm64.tar.gz)
mv "$arm64_tgz" "$work_dir/go-plan9-arm64.tar.gz"
rm -f "$repo_root"/pkg/distpack/*

# --- step 6: SHA256SUMS -------------------------------------------------
log "computing SHA256SUMS"
(cd "$work_dir" && sha256sum \
	go-plan9-amd64.tar.gz \
	go-plan9-arm64.tar.gz \
	go-src.tar.gz \
	> SHA256SUMS)
cat "$work_dir/SHA256SUMS"

# --- step 7: capture metadata for templates -----------------------------
sha_amd64=$(awk '$2=="go-plan9-amd64.tar.gz"{print $1}' "$work_dir/SHA256SUMS")
sha_arm64=$(awk '$2=="go-plan9-arm64.tar.gz"{print $1}' "$work_dir/SHA256SUMS")
sha_src=$(awk   '$2=="go-src.tar.gz"{print $1}'         "$work_dir/SHA256SUMS")

size_amd64=$(numfmt --to=iec --suffix=B --format='%.0f' \
	"$(stat -c%s "$work_dir/go-plan9-amd64.tar.gz")")
size_arm64=$(numfmt --to=iec --suffix=B --format='%.0f' \
	"$(stat -c%s "$work_dir/go-plan9-arm64.tar.gz")")
size_src=$(numfmt --to=iec --suffix=B --format='%.0f' \
	"$(stat -c%s "$work_dir/go-src.tar.gz")")

source_repo=$(git -C "$repo_root" config --get remote.origin.url \
	| sed -E 's#(git@|https://)([^:/]+)[:/]([^.]+)(\.git)?#\3#' \
	|| true)
source_branch=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)
upstream_base=$(git -C "$repo_root" merge-base HEAD upstream/master 2>/dev/null \
	| cut -c1-10 || echo "unknown")

# --- step 8: render templates ------------------------------------------
render() {
	local in=$1 out=$2
	sed \
		-e "s|@@VERSION@@|$version|g" \
		-e "s|@@SOURCE_REPO@@|${source_repo:-github.com/rafael2knokia/go}|g" \
		-e "s|@@SOURCE_BRANCH@@|$source_branch|g" \
		-e "s|@@SOURCE_COMMIT@@|$commit|g" \
		-e "s|@@UPSTREAM_BASE@@|$upstream_base|g" \
		-e "s|@@BUILD_DATE@@|$build_date|g" \
		-e "s|@@SHA256_AMD64@@|$sha_amd64|g" \
		-e "s|@@SHA256_ARM64@@|$sha_arm64|g" \
		-e "s|@@SHA256_SRC@@|$sha_src|g" \
		-e "s|@@SIZE_AMD64@@|$size_amd64|g" \
		-e "s|@@SIZE_ARM64@@|$size_arm64|g" \
		-e "s|@@SIZE_SRC@@|$size_src|g" \
		-e "s|@@BASE_URL@@|$base_url|g" \
		"$in" > "$out"
}

log "rendering landing pages (BASE_URL=$base_url)"
render "$template_dir/index.md.tmpl"   "$work_dir/index.md"
render "$template_dir/index.html.tmpl" "$work_dir/index.html"

# --- step 8b: bake BASE_URL into install-go.rc as its default ----------
sed -e "s|^base=.*|base=$base_url|" \
	"$repo_root/misc/plan9/dist/install-go.rc" \
	> "$work_dir/install-go.rc"
chmod +x "$work_dir/install-go.rc"

# --- step 9: publish work dir into $OUT_DIR (atomic) --------------------
# Replace any existing $OUT_DIR contents wholesale, so partial outputs
# from a previous failed run can't survive into a new publish.
log "syncing work dir → $out_dir"
mkdir -p "$out_dir"
rm -f "$out_dir"/go-plan9-*.tar.gz "$out_dir"/go-src.tar.gz \
      "$out_dir"/SHA256SUMS "$out_dir"/install-go.rc \
      "$out_dir"/index.md "$out_dir"/index.html
mv "$work_dir"/go-plan9-amd64.tar.gz \
   "$work_dir"/go-plan9-arm64.tar.gz \
   "$work_dir"/go-src.tar.gz \
   "$work_dir"/SHA256SUMS \
   "$work_dir"/install-go.rc \
   "$work_dir"/index.md \
   "$work_dir"/index.html \
   "$out_dir"/

# --- step 10: report ----------------------------------------------------
log "done"
printf 'output directory: %s\n' "$out_dir"
ls -lh "$out_dir"
printf '\nversion: %s\nbase_url placeholder in templates: %s\n' "$version" "$base_url"

if [ "$base_url" = "BASE-URL" ]; then
	cat <<'EOF'

Note: BASE_URL was explicitly set to "BASE-URL", so index.{md,html} keep
the placeholder.  Re-run with `BASE_URL=https://YOUR-HOST/path/` (or
accept the default) to produce final pages.
EOF
fi
