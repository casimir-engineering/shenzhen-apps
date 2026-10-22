#!/usr/bin/env bash
#
# test-macos-context-menu-keys.sh — check the keys a file view's right-click
# menus show on macOS.
#
# nautilus/test/friends/test-macos-context-menu-keys makes a real file view
# (a list view in a browse slot) and its selection and background menus the
# way Files pops them up, and reads from GTK's own menu items which key each
# shows: Cmd-X for Cut and Cmd-C for Copy (they showed upstream's Ctrl-X and
# Ctrl-C), Cmd for Paste, Select All, New Folder, Properties and Move to
# Trash, F2 for Rename. Both menus are rendered to
# $CONTEXT_MENU_RENDERS (default <BUILD_TESTS_FRIENDS>/renders).
#
# No window is ever mapped, and the test links the Friends views' interposer
# (that is why it builds with the Friends tests), so it never shows in the
# Dock or takes focus. It needs a logged-in session for GDK's display.
# Nothing here launches Shenzhen Files or a Friends helper.
#
#   1. configure  $BUILD_TESTS_FRIENDS (default <repo>/build-tests-friends,
#                 shared with tools/test-friends-adapter.sh): the release
#                 options, -Dtests=headless, -Dfriends_root from friends.lock
#   2. build      only the test executable and the GSettings schemas
#   3. run        it, with a scratch TMPDIR removed afterwards
#
# Run tools/setup-friends.sh and tools/setup-nautilus-tree.sh --tree-only
# first; this script never changes nautilus/.
#
# Usage: tools/test-macos-context-menu-keys.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
BREW="${HOMEBREW_PREFIX:-/opt/homebrew}"
WITH="${BUILD_TESTS_FRIENDS:-$repo_root/build-tests-friends}"
RENDERS="${CONTEXT_MENU_RENDERS:-$WITH/renders}"
TREE="$repo_root/nautilus"

for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -d "$TREE" ]] || die "nautilus/ is missing; run tools/setup-nautilus-tree.sh --tree-only first"
# shellcheck source-path=SCRIPTDIR source=friends-lock.sh
. "$script_dir/friends-lock.sh"
friends_lock_read "$repo_root" || exit 1
"$script_dir/setup-friends.sh" --check

export PKG_CONFIG_PATH="$BREW/opt/icu4c@78/lib/pkgconfig:$BREW/opt/libarchive/lib/pkgconfig\
${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

scratch="$(mktemp -d -t szf-context-menu-keys)"
trap 'rm -rf "$scratch"' EXIT

# --- 1. configure --------------------------------------------------------------
if [[ ! -f "$WITH/build.ninja" ]]; then
  log "meson setup $WITH (release options, -Dtests=headless, friends_root)"
  meson setup "$WITH" "$TREE" \
    --prefix="$WITH/prefix" \
    --buildtype=debugoptimized \
    -Dmacos_port=true \
    -Dextensions=false \
    -Dselinux=disabled \
    -Dcloudproviders=disabled \
    -Dintrospection=false \
    -Dtests=headless \
    -Dfriends_root="$FRIENDS_ROOT" >/dev/null
else
  log "meson configure $WITH"
  meson configure "$WITH" -Dtests=headless -Dfriends_root="$FRIENDS_ROOT" >/dev/null
fi

# --- 2. build ------------------------------------------------------------------
log "ninja -C $WITH test/friends/test-macos-context-menu-keys"
if ! output="$(ninja -C "$WITH" data/gschemas.compiled test/friends/test-macos-context-menu-keys 2>&1)"; then
  printf '%s\n' "$output" | grep -v '^\[' >&2
  die "the test did not build"
fi

# --- 3. run --------------------------------------------------------------------
log "test-macos-context-menu-keys"
mkdir -p "$RENDERS"
cd "$scratch"
# Bookmarks and other per-person files are looked for in the scratch folder, never the person's own.
TMPDIR="$scratch" XDG_CONFIG_HOME="$scratch/config" XDG_DATA_HOME="$scratch/data" XDG_CACHE_HOME="$scratch/cache" \
  GSETTINGS_BACKEND=memory GSETTINGS_SCHEMA_DIR="$WITH/data" GTK_A11Y=none \
  perl -e 'alarm 120; exec @ARGV' "$WITH/test/friends/test-macos-context-menu-keys" "$RENDERS"
