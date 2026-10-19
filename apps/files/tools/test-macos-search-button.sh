#!/usr/bin/env bash
#
# test-macos-search-button.sh — build and run the toolbar search button
# tests, no display.
#
# nautilus/test/displayless/test-macos-search-button checks what the
# magnifier button at the end of the macOS toolbar does. It reads the
# toolbar and window UI the app loads (compiled from the blueprints into the
# nautilus resource): the button turns on the tab's folder search
# (slot.search-visible, what Cmd-F opens), no toolbar button starts Search
# Everywhere, the upstream toggle next to the path bar is hidden where the
# button is shown, and both toggles sit in a stack with a placeholder the
# toolbar shows instead during Search Everywhere. It then runs the query the search field builds for a
# real throwaway folder through a real search directory: rooted at the
# folder, recursive under the default search settings, matches in nested
# subfolders and none beside the folder; Recent, Starred, Trash and Other
# Locations keep the search in that place. It creates no widget or window
# (a GTK display would make the test process a foreground app); what needs
# a display is the manual checklist O in docs/STATUS.md.
#
#   1. configure  $BUILD_TESTS (default <repo>/build-tests, gitignored, shared
#                 with the other tools/test-macos-*.sh) from nautilus/ with
#                 the release options plus -Dtests=headless
#   2. build      only the test executable and the GSettings schemas (the
#                 search settings): upstream's other tests need Linux-only
#                 dependencies (glycin) and do not build here
#   3. run        meson test test-macos-search-button; the script exits with
#                 its status
#
# Run tools/setup-nautilus-tree.sh first; this script never changes nautilus/.
#
# Usage: tools/test-macos-search-button.sh
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
log "ninja -C $BUILD test-macos-search-button and the schemas"
ninja -C "$BUILD" \
  test/displayless/test-macos-search-button \
  data/gschemas.compiled

# --- 3. run --------------------------------------------------------------------
log "meson test test-macos-search-button"
meson test -C "$BUILD" --no-rebuild --verbose --print-errorlogs test-macos-search-button
