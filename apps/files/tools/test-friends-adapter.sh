#!/usr/bin/env bash
#
# test-friends-adapter.sh — build Files with and without Shenzhen Friends and
# test the Friends host adapter (patches/friends-host-adapter.patch).
#
#   1. without  $BUILD_TESTS_NOFRIENDS (default <repo>/build-tests-nofriends):
#               nautilus/ with the release options and no friends_root.
#               src/nautilus must build and carry no Friends code and no
#               json-glib.
#   2. with     $BUILD_TESTS_FRIENDS (default <repo>/build-tests-friends): the
#               release options, -Dtests=headless and -Dfriends_root from
#               friends.lock (tools/friends-lock.sh). src/nautilus must link
#               the Friends views, the client library and Files' adapter.
#               Builds only nautilus, the Friends tests and the GSettings
#               schemas: upstream's other tests need Linux-only dependencies.
#   3. run      the URL scheme in package/Info.plist.template, then
#               test-nautilus-friends through meson test: no display, no
#               helper, no network. Then test-nautilus-friends-toolbar, which
#               checks where the Friends button sits in a window's header bars
#               (sidebar shown, hidden, narrow, dark, Friends off), checks the
#               Friends Preferences page and Copy Download Link in a
#               selection menu, and renders the first two offscreen to
#               $FRIENDS_RENDERS (default <BUILD_TESTS_FRIENDS>/renders).
#               It needs a logged-in session for GDK's display, never maps a
#               window, and links the views' interposer, so it never shows in
#               the Dock or takes focus.
#
# Both runs get TMPDIR set to a fresh directory, removed afterwards whatever
# happens, so no scratch folder or state directory survives a failed check.
# Nothing here launches Shenzhen Files or a Friends helper.
#
# Run tools/setup-friends.sh and tools/setup-nautilus-tree.sh --tree-only
# first; this script never changes nautilus/.
#
# Usage: tools/test-friends-adapter.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
BREW="${HOMEBREW_PREFIX:-/opt/homebrew}"
WITH="${BUILD_TESTS_FRIENDS:-$repo_root/build-tests-friends}"
WITHOUT="${BUILD_TESTS_NOFRIENDS:-$repo_root/build-tests-nofriends}"
RENDERS="${FRIENDS_RENDERS:-$WITH/renders}"
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
[[ -f "$TREE/src/nautilus-friends.c" ]] ||
  die "nautilus/ has no Friends adapter; run tools/setup-nautilus-tree.sh --tree-only to apply it"
# shellcheck source-path=SCRIPTDIR source=friends-lock.sh
. "$script_dir/friends-lock.sh"
friends_lock_read "$repo_root" || exit 1
"$script_dir/setup-friends.sh" --check

# Keg-only formulae the build finds through pkg-config, as tools/setup-nautilus-tree.sh sets them.
export PKG_CONFIG_PATH="$BREW/opt/icu4c@78/lib/pkgconfig:$BREW/opt/libarchive/lib/pkgconfig\
${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

scratch="$(mktemp -d -t szf-friends-adapter)"
trap 'rm -rf "$scratch"' EXIT

# The release options (tools/setup-nautilus-tree.sh) plus $@.
configure() {
  local build="$1"
  shift
  if [[ ! -f "$build/build.ninja" ]]; then
    log "meson setup $build $*"
    meson setup "$build" "$TREE" \
      --prefix="$build/prefix" \
      --buildtype=debugoptimized \
      -Dmacos_port=true \
      -Dextensions=false \
      -Dselinux=disabled \
      -Dcloudproviders=disabled \
      -Dintrospection=false \
      "$@" >/dev/null
  else
    log "meson configure $build $*"
    meson configure "$build" "$@" >/dev/null
  fi
}

# Symbols defined in a binary, without the leading underscore.
defined() { nm -U "$1" | awk '{ print $NF }' | sed 's/^_//'; }

# --- 1. without Friends --------------------------------------------------------
configure "$WITHOUT" -Dtests=none -Dfriends_root=
log "ninja -C $WITHOUT src/nautilus"
ninja -C "$WITHOUT" src/nautilus >/dev/null
if found="$(defined "$WITHOUT/src/nautilus" | grep -E '^(szfriends_|nautilus_friends_)' | head -n 3)" &&
   [[ -n "$found" ]]; then
  die "built without friends_root, but src/nautilus defines Friends symbols: $found"
fi
if otool -L "$WITHOUT/src/nautilus" | grep -q json-glib; then
  die "built without friends_root, but src/nautilus links json-glib"
fi
# Cmd+J is listed in the shortcuts dialog only when Friends is built in.
if grep -q "Show/Hide Friends" "$WITHOUT/src/resources/ui/shortcuts-dialog.ui"; then
  die "built without friends_root, but the shortcuts dialog lists Show/Hide Friends"
fi
grep -q "Search Commands" "$WITHOUT/src/resources/ui/shortcuts-dialog.ui" ||
  die "built without friends_root, the shortcuts dialog lost Search Commands"
log "without friends_root: src/nautilus builds with no Friends code"

# --- 2. with Friends -----------------------------------------------------------
configure "$WITH" -Dtests=headless -Dfriends_root="$FRIENDS_ROOT"
log "ninja -C $WITH src/nautilus test/friends/test-nautilus-friends test/friends/test-nautilus-friends-toolbar"
ninja -C "$WITH" src/nautilus data/gschemas.compiled test/friends/test-nautilus-friends \
  test/friends/test-nautilus-friends-toolbar >/dev/null
grep -q "Show/Hide Friends" "$WITH/src/resources/ui/shortcuts-dialog.ui" ||
  die "with friends_root, the shortcuts dialog does not list Show/Hide Friends"
symbols="$(defined "$WITH/src/nautilus")"
for symbol in szfriends_gtk_link_new szfriends_gtk_link_add_window szfriends_gtk_settings_section_new \
              szfriends_client_new szfriends_set_signing_policy nautilus_friends_startup \
              nautilus_friends_host_init nautilus_friends_place_button nautilus_toolbar_set_friends_button \
              nautilus_friends_toggle_dropdown nautilus_command_palette_present; do
  grep -qx "$symbol" <<<"$symbols" || die "with friends_root, src/nautilus does not define $symbol"
done
otool -L "$WITH/src/nautilus" | grep -q json-glib || die "with friends_root, src/nautilus does not link json-glib"
log "with friends_root: src/nautilus carries the Friends views and the adapter"

# The app answers its links' pages: package/Info.plist.template registers shenzhenfiles: (PROTOCOL.md § Links).
scheme="$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw -o - "$repo_root/package/Info.plist.template")" ||
  die "package/Info.plist.template registers no URL scheme"
[[ "$scheme" == "shenzhenfiles" ]] || die "package/Info.plist.template registers $scheme, not shenzhenfiles"

# --- 3. run --------------------------------------------------------------------
log "meson test test-nautilus-friends"
TMPDIR="$scratch" meson test -C "$WITH" --no-rebuild --print-errorlogs test-nautilus-friends

log "test-nautilus-friends-toolbar $RENDERS"
mkdir -p "$RENDERS"
(
  cd "$scratch"
  TMPDIR="$scratch" GSETTINGS_BACKEND=memory GSETTINGS_SCHEMA_DIR="$WITH/data" GTK_A11Y=none \
    perl -e 'alarm 60; exec @ARGV' "$WITH/test/friends/test-nautilus-friends-toolbar" "$RENDERS"
)

echo "test-friends-adapter passed"
