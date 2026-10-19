#!/usr/bin/env bash
#
# test-macos-quicklook.sh — build and run the Quick Look focus tests, no display.
#
# nautilus/test/displayless/test-macos-quicklook drives the Quick Look
# panel's keyboard-focus controller (src/nautilus-macos-previewer.m) through
# a fake panel and fake windows that model what AppKit and Quick Look do:
# space, Escape and Cmd-Y in the file view, the panel taking the keyboard when
# clicked, Quick Look closing the panel itself, arrows, Return and typing
# while the panel has the keyboard. It also sends real NSEvents through the
# panel delegate the app installs. It creates no window, panel or
# NSApplication; what needs a real panel is the manual checklist K in
# docs/STATUS.md.
#
#   1. configure  $BUILD_TESTS (default <repo>/build-tests, gitignored, shared
#                 with tools/test-macos-volumes.sh) from nautilus/ with the
#                 release options plus -Dtests=headless
#   2. build      only the test executable: upstream's other tests need
#                 Linux-only dependencies (glycin) and do not build here
#   3. run        meson test test-macos-quicklook; the script exits with its
#                 status
#
# Run tools/setup-nautilus-tree.sh first; this script never changes nautilus/.
#
# Usage: tools/test-macos-quicklook.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
BREW="${HOMEBREW_PREFIX:-/opt/homebrew}"
BUILD="${BUILD_TESTS:-$repo_root/build-tests}"
TREE="$repo_root/nautilus"

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
log "ninja -C $BUILD test/displayless/test-macos-quicklook"
ninja -C "$BUILD" test/displayless/test-macos-quicklook

# --- 3. run --------------------------------------------------------------------
log "meson test test-macos-quicklook"
meson test -C "$BUILD" --no-rebuild --verbose --print-errorlogs test-macos-quicklook
