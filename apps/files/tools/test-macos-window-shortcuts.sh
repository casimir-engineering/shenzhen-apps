#!/usr/bin/env bash
#
# test-macos-window-shortcuts.sh — build and run the window shortcut tests,
# no display.
#
# nautilus/test/displayless/test-macos-window-shortcuts checks the keys each
# window binds after the focused widget (nautilus_macos_window_shortcuts_new()):
# Delete (BackSpace) alone goes back, Cmd-Delete still moves to the Trash and
# Cmd-Shift-Delete still deletes, Fn-Delete is not Back, the bindings run
# after the focused widget so text fields keep Backspace, and while a search
# is open Delete is left to the search field. It creates no
# widget or window; pressing the keys in the app is checklist Q in
# docs/STATUS.md.
#
#   1. configure  $BUILD_TESTS (default <repo>/build-tests, gitignored, shared
#                 with the other tools/test-macos-*.sh) from nautilus/ with
#                 the release options plus -Dtests=headless
#   2. build      only the test executable
#   3. run        meson test test-macos-window-shortcuts; the script exits
#                 with its status
#
# Run tools/setup-nautilus-tree.sh first; this script never changes nautilus/.
#
# Usage: tools/test-macos-window-shortcuts.sh
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
log "ninja -C $BUILD test-macos-window-shortcuts"
ninja -C "$BUILD" test/displayless/test-macos-window-shortcuts

# --- 3. run --------------------------------------------------------------------
log "meson test test-macos-window-shortcuts"
meson test -C "$BUILD" --no-rebuild --verbose --print-errorlogs test-macos-window-shortcuts
