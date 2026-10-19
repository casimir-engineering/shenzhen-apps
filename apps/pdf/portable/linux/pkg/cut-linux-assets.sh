#!/usr/bin/env bash
# Build, sign and upload the Linux release assets for an EXISTING GitHub
# release (created by portable/cut-release.sh on the Mac).
#
#   portable/linux/pkg/cut-linux-assets.sh <tag>          # e.g. 26.7.19-1
#   portable/linux/pkg/cut-linux-assets.sh <tag> --dry-run
#
# Run on the Linux release machine (needs: docker image shenzhen-build,
# gh authenticated, minisign secret key at
# ~/.config/shenzhenpdf-release/minisign.key). Produces and uploads:
#   ShenzhenPDF-linux-amd64.deb      + .minisig
#   ShenzhenPDF-linux-amd64.tar.gz   + .minisig
set -euo pipefail

TAG=${1:?usage: cut-linux-assets.sh <tag> [--dry-run]}
DRY=${2:-}
VERSION=${TAG%-*}
KEY="$HOME/.config/shenzhenpdf-release/minisign.key"
repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$repo_root"

fail() { echo "FAIL: $*" >&2; exit 1; }
log()  { echo "==> $*"; }

[ -f "$KEY" ] || fail "minisign secret key not found at $KEY"
docker image inspect shenzhen-build >/dev/null 2>&1 || fail "docker image shenzhen-build missing (docker build -t shenzhen-build portable/linux/dev)"
gh release view "$TAG" >/dev/null || fail "GitHub release $TAG does not exist — cut the Mac release first."
grep -q "#define SPDF_APP_VERSION \"${VERSION}\"" portable/linux/gtk4/spdf_app.h \
  || fail "spdf_app.h SPDF_APP_VERSION != ${VERSION} — check out the release tag/commit first."

log "Building binary + tests in container"
docker run --rm -v "$PWD:/work" -w /work shenzhen-build \
  bash -c 'make -C portable linux-gtk4 && make -C portable linux-gtk4-tests' >/dev/null

mkdir -p dist
log "Building deb"
docker run --rm -v "$PWD:/work" -w /work shenzhen-build \
  portable/linux/pkg/build-deb.sh "$VERSION" >/dev/null
cp "dist/shenzhenpdf_${VERSION}_amd64.deb" dist/ShenzhenPDF-linux-amd64.deb

log "Building tarball (user-local installs; binary + desktop + icons)"
stage=$(mktemp -d)
install -Dm755 portable/build/ShenzhenPDF-gtk4 "$stage/shenzhenpdf/ShenzhenPDF-gtk4"
install -Dm644 portable/linux/pkg/shenzhenpdf.desktop "$stage/shenzhenpdf/shenzhenpdf.desktop"
install -Dm644 portable/linux/pkg/minisign.pub "$stage/shenzhenpdf/minisign.pub"
for size in 16 32 48 128 256; do
  f="gfx/ShenzhenPDF-${size}x${size}x32.png"
  [ -f "$f" ] && install -Dm644 "$f" "$stage/shenzhenpdf/icons/${size}.png"
done
tar -C "$stage" -czf dist/ShenzhenPDF-linux-amd64.tar.gz shenzhenpdf
rm -rf "$stage"

log "Signing with minisign"
for a in dist/ShenzhenPDF-linux-amd64.deb dist/ShenzhenPDF-linux-amd64.tar.gz; do
  rm -f "$a.minisig"
  docker run --rm -v "$PWD/dist:/d" -v "$HOME/.config/shenzhenpdf-release:/k:ro" shenzhen-build \
    minisign -Sm "/d/$(basename "$a")" -s /k/minisign.key -t "ShenzhenPDF $TAG" >/dev/null
  docker run --rm -v "$PWD/dist:/d" -v "$PWD/portable/linux/pkg:/p:ro" shenzhen-build \
    minisign -Vm "/d/$(basename "$a")" -p /p/minisign.pub >/dev/null || fail "signature self-check failed for $a"
done
docker run --rm -v "$PWD/dist:/d" shenzhen-build chown -R "$(id -u):$(id -g)" /d

if [ "$DRY" = "--dry-run" ]; then
  log "DRY RUN — would upload to release $TAG:"
  ls -la dist/ShenzhenPDF-linux-amd64.*
  exit 0
fi

log "Uploading assets to $TAG"
gh release upload "$TAG" --clobber \
  dist/ShenzhenPDF-linux-amd64.deb dist/ShenzhenPDF-linux-amd64.deb.minisig \
  dist/ShenzhenPDF-linux-amd64.tar.gz dist/ShenzhenPDF-linux-amd64.tar.gz.minisig
log "Done. Linux updaters will now see $TAG."
