#!/usr/bin/env bash
#
# check-friends-bundle.sh — check what Shenzhen Files.app carries of Shenzhen Friends.
#
# What the release depends on and a stale or partial packaging run could get wrong; ShenzhenPDF checks the same
# in its MAC_FRIENDS_BUNDLE_CHECK (shenzhen-pdf portable/Makefile):
#   - Contents/Helpers/Shenzhen Friends.app: the identifier both apps embed, so they share one Friends identity
#     per Mac user; version keys from friends.lock, with CFBundleVersion equal to SZFriendsBuildNumber (the app
#     sends one, the running helper compares it with the other to decide on a handover); no animal set of its own
#     (it reads the app's); the same acknowledgements as the app; the app's minimum macOS; system libraries only,
#     because bundle-dylibs.sh bundles libraries for the app's own code and not for the helper.
#   - Contents/Resources/Friends/: exactly the pinned animal set (manifest.json, svg/, pdf/) and
#     Acknowledgements.txt.
#   - The usage descriptions and the _szfriends._tcp Bonjour service in both Info.plists: macOS holds the app
#     responsible for the helper it starts, so without them a permission prompt explains nothing, Local Network
#     browsing can be refused, and asking for Bluetooth ends the helper.
#
# Usage: package/check-friends-bundle.sh [--libraries | --signed] <app>
#   (default)    all of the above, before signing; make-app.sh ends with it
#   --libraries  only the helper's libraries; bundle-dylibs.sh runs it before signing the helper
#   --signed     all of the above, plus codesign --verify --strict on the helper and --deep --strict on the app;
#                bundle-dylibs.sh ends with it
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=../tools/friends-lock.sh
. "$repo_root/tools/friends-lock.sh"

mode=all
case "${1:-}" in
  --libraries) mode=libraries; shift ;;
  --signed) mode=signed; shift ;;
esac
[[ $# -eq 1 && -d "$1" ]] || { echo "usage: $0 [--libraries | --signed] <app>" >&2; exit 2; }
APP="$(cd "$1" && pwd -P)"
HELPER="$APP/Contents/Helpers/$FRIENDS_HELPER_NAME.app"
HELPER_EXE="$HELPER/Contents/MacOS/$FRIENDS_HELPER_NAME"
FRIENDS_RES="$APP/Contents/Resources/Friends"

problems=()
problem() { problems+=("$*"); }
plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

check_libraries() {
  local deps bad
  if [[ ! -x "$HELPER_EXE" ]]; then
    problem "no helper executable at $HELPER_EXE"
    return
  fi
  # Library lines are the tab-indented ones; the first line names the file itself.
  deps="$(otool -L "$HELPER_EXE" | awk '/^\t/ { print $1 }')" || { problem "otool -L failed on $HELPER_EXE"; return; }
  bad="$(grep -Ev '^(/usr/lib/|/System/Library/)' <<<"$deps" || true)"
  [[ -z "$bad" ]] || problem "the helper links libraries macOS does not provide: $(tr '\n' ' ' <<<"$bad")"
}

check_usage_keys() {
  local plist="$1" key value services
  for key in NSBluetoothAlwaysUsageDescription NSLocalNetworkUsageDescription; do
    value="$(plist_get "$plist" "$key")" || value=""
    [[ -n "${value//[[:space:]]/}" ]] || problem "$plist has no $key"
  done
  # Captured first: grep -q ending a pipeline can SIGPIPE its writer and fail under pipefail.
  services="$(plist_get "$plist" NSBonjourServices)" || services=""
  grep -Eq '^[[:space:]]*_szfriends\._tcp$' <<<"$services" ||
    problem "$plist does not declare the _szfriends._tcp Bonjour service"
}

# $1 bundle directory, $2 source directory, $3 glob of the source files that ship: same names, same bytes.
check_same_files() {
  local got want name
  got="$(cd "$1" 2>/dev/null && LC_ALL=C ls -A)" || got=""
  # $3 unquoted on purpose: it is a list of names or a glob, expanded in the source directory.
  # shellcheck disable=SC2086
  want="$(cd "$2" && LC_ALL=C ls -d -- $3 2>/dev/null)" || want=""
  if [[ -z "$want" || "$got" != "$want" ]]; then
    problem "$1 holds [$(tr '\n' ' ' <<<"$got")], the pinned set is [$(tr '\n' ' ' <<<"$want")]"
    return
  fi
  while IFS= read -r name; do
    [[ -d "$2/$name" ]] || cmp -s "$2/$name" "$1/$name" || problem "$1/$name differs from $2/$name"
  done <<<"$want"
}

check_bundle() {
  local plist="$HELPER/Contents/Info.plist" app_plist="$APP/Contents/Info.plist" key want got
  friends_lock_read "$repo_root" || { problem "friends.lock cannot be read"; return; }
  if [[ ! -f "$plist" ]]; then
    problem "no Friends helper at $HELPER"
    return
  fi
  for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion SZFriendsBuildNumber; do
    case "$key" in
      CFBundleIdentifier) want="$FRIENDS_HELPER_ID" ;;
      CFBundleShortVersionString) want="$FRIENDS_SHORT_VERSION" ;;
      *) want="$FRIENDS_BUILD_NUMBER" ;;
    esac
    got="$(plist_get "$plist" "$key")" || got="(missing)"
    [[ "$got" == "$want" ]] || problem "the helper's $key is $got, friends.lock asks for $want"
  done
  want="$(plist_get "$app_plist" LSMinimumSystemVersion)" || want="(missing)"
  got="$(plist_get "$plist" LSMinimumSystemVersion)" || got="(missing)"
  [[ "$got" == "$want" ]] || problem "the helper needs macOS $got, the app says it runs on $want"
  [[ ! -e "$HELPER/Contents/Resources/Friends" ]] ||
    problem "the helper carries its own Contents/Resources/Friends; it should read the app's"
  check_libraries
  check_usage_keys "$app_plist"
  check_usage_keys "$plist"

  if [[ ! -d "$FRIENDS_ANIMALS" ]]; then
    problem "no pinned animal set at $FRIENDS_ANIMALS to compare with; run tools/setup-friends.sh"
    return
  fi
  check_same_files "$FRIENDS_RES/animals" "$FRIENDS_ANIMALS" "manifest.json pdf svg"
  check_same_files "$FRIENDS_RES/animals/svg" "$FRIENDS_ANIMALS/svg" "*.svg"
  check_same_files "$FRIENDS_RES/animals/pdf" "$FRIENDS_ANIMALS/pdf" "*.pdf"
  for got in "$FRIENDS_RES/Acknowledgements.txt" "$HELPER/Contents/Resources/Acknowledgements.txt"; do
    cmp -s "$FRIENDS_ACKNOWLEDGEMENTS" "$got" || problem "$got is missing or differs from $FRIENDS_ACKNOWLEDGEMENTS"
  done
}

check_signatures() {
  local out
  out="$(codesign --verify --strict --verbose=2 "$HELPER" 2>&1)" || problem "helper signature: $out"
  out="$(codesign --verify --deep --strict --verbose=2 "$APP" 2>&1)" || problem "app signature: $out"
}

case "$mode" in
  libraries) check_libraries ;;
  all) check_bundle ;;
  signed) check_bundle; check_signatures ;;
esac

if (( ${#problems[@]} )); then
  echo "error: Shenzhen Friends in $APP:" >&2
  printf '  %s\n' "${problems[@]}" >&2
  exit 1
fi
echo "==> Friends bundle check passed ($mode): $APP"
