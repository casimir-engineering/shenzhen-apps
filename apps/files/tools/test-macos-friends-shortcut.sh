#!/usr/bin/env bash
#
# test-macos-friends-shortcut.sh — press Cmd+J and Cmd+K on a real window and
# check what Files does.
#
# nautilus/test/friends/test-nautilus-friends-shortcut builds a window like a
# Files browser window, with the real Friends button from the Friends views
# and the same wiring the app installs (win.friends and Cmd+J,
# win.command-palette and Cmd+K, the View menu's Friends item on a native
# menu bar). It maps the window and posts real key presses (NSEvents) to the
# application's event queue, so they go through GDK, GTK and AppKit's menu
# key equivalents as typed keys do, and checks:
#   - Cmd+J opens the Friends dropdown with the keyboard in its search field,
#     and closes it again from inside that field; one toggle per press;
#   - a dropdown reopened on another page keeps that page;
#   - the button's tooltip names the key, and the menu bar has Friends ⌘J;
#   - Cmd+K opens the palette; typing "friends" and Return opens Friends;
#     "friend", "nearby", "add by id" and "chat" list Open Friends; Down and
#     Return run another command; Escape closes it;
#   - with Friends off, Cmd+J does nothing and the palette has no Friends
#     commands; the shortcuts dialog lists both keys.
#
# Nothing appears on screen: every window the test makes is transparent and
# click-through and is never ordered in, the test fails if any window of its
# process becomes visible, and it links the Friends views' interposer, so it
# never shows in the Dock or takes focus. It needs a logged-in session for GDK's display. Nothing here launches
# Shenzhen Files or a Friends helper, or reads the Keychain.
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
# Usage: tools/test-macos-friends-shortcut.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
BREW="${HOMEBREW_PREFIX:-/opt/homebrew}"
WITH="${BUILD_TESTS_FRIENDS:-$repo_root/build-tests-friends}"
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
[[ -f "$TREE/src/nautilus-friends-shortcut.c" ]] ||
  die "nautilus/ has no Friends shortcut; run tools/setup-nautilus-tree.sh --tree-only to apply the adapter"
# shellcheck source-path=SCRIPTDIR source=friends-lock.sh
. "$script_dir/friends-lock.sh"
friends_lock_read "$repo_root" || exit 1
"$script_dir/setup-friends.sh" --check

export PKG_CONFIG_PATH="$BREW/opt/icu4c@78/lib/pkgconfig:$BREW/opt/libarchive/lib/pkgconfig\
${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

scratch="$(mktemp -d -t szf-friends-shortcut)"
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
log "ninja -C $WITH test/friends/test-nautilus-friends-shortcut"
if ! output="$(ninja -C "$WITH" data/gschemas.compiled test/friends/test-nautilus-friends-shortcut 2>&1)"; then
  printf '%s\n' "$output" | grep -v '^\[' >&2
  die "the test did not build"
fi

# --- 3. run --------------------------------------------------------------------
log "test-nautilus-friends-shortcut"
cd "$scratch"
TMPDIR="$scratch" GSETTINGS_BACKEND=memory GSETTINGS_SCHEMA_DIR="$WITH/data" GTK_A11Y=none \
  perl -e 'alarm 120; exec @ARGV' "$WITH/test/friends/test-nautilus-friends-shortcut"
