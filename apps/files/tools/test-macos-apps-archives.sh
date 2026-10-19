#!/usr/bin/env bash
#
# test-macos-apps-archives.sh — build and run the app, package and archive
# tests, no display.
#
# nautilus/test/displayless/test-macos-apps-archives checks what opening an
# item does: an application bundle is launched through NSWorkspace, another
# macOS package (.rtfd, .bundle, …) opens with its default app, a folder is
# browsed, an archive opens with its default app (or is extracted when
# Shenzhen Files is that app). It checks that every archive format autoar
# extracts is detected as one, so Extract is offered, and it extracts and
# compresses real throwaway archives whose names contain spaces and non-ASCII
# characters. test-macos-package-listing checks that loading a folder with
# "folders first" on tells its subfolders from packages before the sort asks,
# asks nothing with it off, and on a network volume (stubbed) does not read
# the folder twice.
#
# The only apps it launches are its own throwaway bundles, built from
# test/displayless/macos-test-marker-app.m: they are LSBackgroundOnly, show
# nothing, record their launch next to their bundle and quit. It opens no
# windows.
#
#   1. configure  $BUILD_TESTS (default <repo>/build-tests, gitignored) from
#                 nautilus/ with the release options plus -Dtests=headless
#   2. build      only the tests, the marker app and the GSettings schemas:
#                 upstream's other tests need Linux-only dependencies (glycin)
#                 and do not build here
#   3. run        meson test test-macos-apps-archives test-macos-package-listing;
#                 the script exits with its status
#   4. clean up   remove the throwaway apps from LaunchServices (launching or
#                 querying an app registers it) and delete the scratch
#                 directory, also after an aborted test
#
# Run tools/setup-nautilus-tree.sh first; this script never changes nautilus/.
#
# Usage: tools/test-macos-apps-archives.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
BREW="${HOMEBREW_PREFIX:-/opt/homebrew}"
BUILD="${BUILD_TESTS:-$repo_root/build-tests}"
TREE="$repo_root/nautilus"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$TREE" ]]; then
  echo "error: nautilus/ is missing; run tools/setup-nautilus-tree.sh first" >&2
  exit 1
fi

export PKG_CONFIG_PATH="$BREW/opt/icu4c@78/lib/pkgconfig:$BREW/opt/libarchive/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

log() { printf '==> %s\n' "$*"; }

scratch="$(mktemp -d -t szf-apps-archives-test)"

cleanup() {
  local status=$?
  set +e
  # The test unregisters its apps itself; this catches an aborted run.
  find "$scratch" -name '*.app' -type d -prune 2>/dev/null | while IFS= read -r app; do
    "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
  done
  rm -rf "$scratch"
  exit "$status"
}
trap cleanup EXIT

# --- 1. configure --------------------------------------------------------------
if [[ ! -f "$BUILD/build.ninja" ]]; then
  log "meson setup $BUILD (release options, -Dtests=headless)"
  meson setup "$BUILD" "$TREE" \
    --prefix="$BUILD/prefix" \
    --buildtype=debugoptimized \
    -Dmacos_port=true \
    -Dextensions=false \
    -Dselinux=disabled \
    -Dcloudproviders=disabled \
    -Dtests=headless \
    -Dintrospection=false >/dev/null
fi

# --- 2. build ------------------------------------------------------------------
log "ninja -C $BUILD test-macos-apps-archives, test-macos-package-listing, the marker app and the schemas"
ninja -C "$BUILD" \
  test/displayless/test-macos-apps-archives \
  test/displayless/test-macos-package-listing \
  test/displayless/macos-test-marker-app \
  data/gschemas.compiled

# --- 3. run --------------------------------------------------------------------
export NAUTILUS_TEST_SCRATCH="$scratch"
log "meson test test-macos-apps-archives test-macos-package-listing"
meson test -C "$BUILD" --no-rebuild --verbose --print-errorlogs test-macos-apps-archives test-macos-package-listing
