#!/usr/bin/env bash
#
# test-macos-blueprints.sh — check that a build compiles the UI blueprints it
# was given, also after it is reconfigured. No display.
#
# The window and toolbar UI the app loads is compiled from the .blp files in
# nautilus/src/resources/ui into <build>/src/resources/ui/*.ui and from there
# into the nautilus resource. A blueprint that changes (a patch applied, an
# edit) before a reconfigure (meson configure -Dfriends_root=..., as
# tools/test-friends-adapter.sh and a friends.lock move do) must still be
# compiled again. A reconfigure rewrites a file in <build>/src/resources and
# then has ninja record every output's current time; while the blueprints'
# only declared output was that directory, they then counted as compiled and
# the app and the tests loaded the old window. That is how the placement
# probe once saw the toolbar from before the search fix.
#
#   1. copy       nautilus/ (without .git) into a scratch directory, so the
#                 blueprint can be edited without touching nautilus/
#   2. configure  a scratch build with the release options, no friends_root
#   3. build      only the nautilus resource (blueprints, menus, metainfo)
#   4. edit       the window blueprint's default width in the copy, then
#                 meson setup --reconfigure and build the resource again
#   5. check      the compiled window UI has the new width
#
# The scratch directory is removed on exit, whatever happens.
#
# Run tools/setup-nautilus-tree.sh --tree-only first; this script never
# changes nautilus/.
#
# Usage: tools/test-macos-blueprints.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
BREW="${HOMEBREW_PREFIX:-/opt/homebrew}"
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

export PKG_CONFIG_PATH="$BREW/opt/icu4c@78/lib/pkgconfig:$BREW/opt/libarchive/lib/pkgconfig\
${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

scratch="$(mktemp -d -t szf-blueprints)"
trap 'rm -rf "$scratch"' EXIT
copy="$scratch/nautilus"
build="$scratch/build"
blp="$copy/src/resources/ui/nautilus-window.blp"
ui="$build/src/resources/ui/nautilus-window.ui"

# --- 1. copy -------------------------------------------------------------------
log "copying nautilus/ to $copy"
rsync -a --exclude .git "$TREE/" "$copy/"

# --- 2. configure --------------------------------------------------------------
log "meson setup $build (release options)"
meson setup "$build" "$copy" \
  --prefix="$build/prefix" \
  --buildtype=debugoptimized \
  -Dmacos_port=true \
  -Dextensions=false \
  -Dselinux=disabled \
  -Dcloudproviders=disabled \
  -Dtests=none \
  -Dintrospection=false >/dev/null

# --- 3. build ------------------------------------------------------------------
log "ninja -C $build src/resources/nautilus-resources.c"
ninja -C "$build" src/resources/nautilus-resources.c >/dev/null
grep -q '<property name="default-width">890</property>' "$ui" ||
  die "the compiled window UI does not have the blueprint's default width 890"

# --- 4. edit, reconfigure, build again ----------------------------------------
grep -q '^  default-width: 890;$' "$blp" || die "nautilus-window.blp has no 'default-width: 890;' line"
sed -i '' 's/^  default-width: 890;$/  default-width: 891;/' "$blp"
log "nautilus-window.blp edited; meson setup --reconfigure $build, then the resource again"
meson setup --reconfigure "$build" "$copy" >/dev/null
ninja -C "$build" src/resources/nautilus-resources.c >/dev/null

# --- 5. check ------------------------------------------------------------------
if ! grep -q '<property name="default-width">891</property>' "$ui"; then
  die "after the reconfigure, the compiled window UI is still the old one (default width 890, the blueprint says 891)"
fi
log "the compiled window UI follows its blueprint after a reconfigure"
echo "test-macos-blueprints passed"
