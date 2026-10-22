#!/usr/bin/env bash
#
# test-macos-trash-undo.sh — build and run the Undo after Move to Trash test, no display.
#
# nautilus/test/displayless/test-macos-trash-undo trashes throwaway files the
# way Cmd-Delete does (NSFileManager, nautilus-macos-trash.m) and checks that
# Undo moves each back to where it was, that Redo trashes it again and Undo
# brings it back once more, and that a file whose folder is gone stays in
# the Trash. The files are created in a scratch directory, go through the
# real macOS Trash, and every one the test does not get back is removed from
# the Trash at the end. It opens no window and starts no app.
#
#   1. configure  $BUILD_TESTS (default <repo>/build-tests, gitignored, shared
#                 with tools/test-macos-volumes.sh) from nautilus/ with the
#                 release options plus -Dtests=headless
#   2. build      only the test executable and the GSettings schemas:
#                 upstream's other tests need Linux-only dependencies (glycin)
#                 and do not build here
#   3. run        meson test test-macos-trash-undo, with a scratch directory
#                 removed afterwards; the script exits with its status
#
# Run tools/setup-nautilus-tree.sh first; this script never changes nautilus/.
#
# Usage: tools/test-macos-trash-undo.sh
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

scratch="$(mktemp -d -t szf-trash-undo-test)"
trap 'rm -rf "$scratch"' EXIT

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
log "ninja -C $BUILD test/displayless/test-macos-trash-undo"
ninja -C "$BUILD" data/gschemas.compiled test/displayless/test-macos-trash-undo

# --- 3. run --------------------------------------------------------------------
log "meson test test-macos-trash-undo"
NAUTILUS_TEST_SCRATCH="$scratch" \
  meson test -C "$BUILD" --no-rebuild --verbose --print-errorlogs test-macos-trash-undo
