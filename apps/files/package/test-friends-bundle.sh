#!/usr/bin/env bash
#
# test-friends-bundle.sh — package Shenzhen Files.app with Shenzhen Friends and check the result. The app is
# signed ad hoc and never launched.
#
#   1. make-app.sh refuses to start without the pinned Friends build, before it touches the app path.
#   2. make-app.sh then bundle-dylibs.sh produce the app (default dist/Shenzhen Files.app) with the helper in
#      Contents/Helpers/, signed, version keys from friends.lock, and codesign --verify --deep --strict passes.
#   3. Copies of that app with one defect each fail check-friends-bundle.sh, so each check is known to fire, and
#      bundle-dylibs.sh stops on a helper that links a library macOS does not provide.
#
# Needs install/ (tools/setup-nautilus-tree.sh) and the Friends build (tools/setup-friends.sh; SZF_FRIENDS_ROOT is
# honoured). Copies go to a temporary directory removed on exit, pass or fail.
#
# Usage: package/test-friends-bundle.sh [app-path]   (prints "FriendsBundleTests passed" and exits 0)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
APP="${1:-$repo_root/dist/Shenzhen Files.app}"
T="$(mktemp -d -t szf-pkg-bundle)"
trap 'rm -rf "$T"' EXIT
# shellcheck source-path=SCRIPTDIR source=../tools/friends-lock.sh
. "$repo_root/tools/friends-lock.sh"
friends_lock_read "$repo_root"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect() {  # expect <0 | fails> <command…>, output in $T/out
  local want="$1" got=0
  shift
  "$@" >"$T/out" 2>&1 || got=$?
  if [[ "$got" != "$want" && ! ( "$want" == fails && "$got" != 0 ) ]]; then
    tail -n 40 "$T/out" >&2
    fail "exit $got, expected $want: $*"
  fi
}
says() { grep -qF -- "$1" "$T/out" || { tail -n 40 "$T/out" >&2; fail "output lacks: $1"; }; }

[[ -x "$repo_root/install/bin/nautilus" ]] || fail "no install/bin/nautilus; run tools/setup-nautilus-tree.sh first"
"$repo_root/tools/setup-friends.sh" --check >"$T/out" 2>&1 || { cat "$T/out" >&2; fail "run tools/setup-friends.sh"; }

# --- 1. no Friends build, no app ----------------------------------------------------
mkdir -p "$T/not-a-checkout"
expect fails env SZF_FRIENDS_ROOT="$T/not-a-checkout" "$script_dir/make-app.sh" "$T/refused.app"
says "not a git checkout"
[[ ! -e "$T/refused.app" ]] || fail "make-app.sh started assembling without the Friends build"
echo "refusal without the Friends build ok"

# --- 2. the packaging run -----------------------------------------------------------
expect 0 "$script_dir/make-app.sh" "$APP"
says "Friends bundle check passed (all)"
expect 0 "$script_dir/bundle-dylibs.sh" "$APP"
says "Friends bundle check passed (libraries)"
says "Friends bundle check passed (signed)"
expect 0 codesign --verify --deep --strict --verbose=2 "$APP"
HELPER="$APP/Contents/Helpers/$FRIENDS_HELPER_NAME.app"
expect 0 codesign --display --verbose=2 "$HELPER"
says "Identifier=$FRIENDS_HELPER_ID"
says "Signature=adhoc"
for key in CFBundleVersion SZFriendsBuildNumber; do
  got="$(/usr/libexec/PlistBuddy -c "Print :$key" "$HELPER/Contents/Info.plist")"
  [[ "$got" == "$FRIENDS_BUILD_NUMBER" ]] || fail "helper $key is $got, friends.lock says $FRIENDS_BUILD_NUMBER"
done
got="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$HELPER/Contents/Info.plist")"
[[ "$got" == "$FRIENDS_SHORT_VERSION" ]] || fail "helper version is $got, expected $FRIENDS_SHORT_VERSION"
svgs="$(find "$APP/Contents/Resources/Friends/animals/svg" -name '*.svg' | wc -l | tr -d ' ')"
(( svgs > 0 )) || fail "no animals in Contents/Resources/Friends"
echo "packaging run ok: $APP (helper $got, $svgs animals)"

# --- 3. each check fires ------------------------------------------------------------
X="$T/defect.app"
XH="$X/Contents/Helpers/$FRIENDS_HELPER_NAME.app"
pb() { /usr/libexec/PlistBuddy -c "$1" "$2"; }
fresh() { rm -rf "$X"; cp -cR "$APP" "$X" 2>/dev/null || cp -R "$APP" "$X"; }
# defect <mode or ""> <text the check prints> <description>; the defect itself is made by the caller after fresh.
defect() {
  expect fails "$script_dir/check-friends-bundle.sh" ${1:+"$1"} "$X"
  says "$2"
  echo "  caught: $3"
}

fresh; pb "Set :CFBundleVersion 26101102" "$XH/Contents/Info.plist"
defect "" "CFBundleVersion is 26101102" "helper build number not from friends.lock"
fresh; pb "Set :CFBundleIdentifier com.intuition.shenzhenfiles.friends" "$XH/Contents/Info.plist"
defect "" "CFBundleIdentifier is com.intuition.shenzhenfiles.friends" "helper identifier not the shared one"
fresh; pb "Set :LSMinimumSystemVersion 13.0" "$XH/Contents/Info.plist"
defect "" "the helper needs macOS 13.0" "helper needs a newer macOS than the app"
fresh; pb "Delete :NSLocalNetworkUsageDescription" "$X/Contents/Info.plist"
defect "" "has no NSLocalNetworkUsageDescription" "app without the local network string"
fresh; pb "Delete :NSBonjourServices" "$X/Contents/Info.plist"
defect "" "_szfriends._tcp" "app without the Bonjour service"
fresh; pb "Delete :NSBluetoothAlwaysUsageDescription" "$XH/Contents/Info.plist"
defect "" "has no NSBluetoothAlwaysUsageDescription" "helper without the Bluetooth string"
fresh; mkdir -p "$XH/Contents/Resources/Friends/animals"
defect "" "carries its own Contents/Resources/Friends" "helper with its own animal set"
fresh; rm "$(find "$X/Contents/Resources/Friends/animals/svg" -name '*.svg' | head -n 1)"
defect "" "Friends/animals/svg holds" "an animal missing"
fresh; echo "stale" >>"$X/Contents/Resources/Friends/animals/manifest.json"
defect "" "manifest.json differs" "a stale animal manifest"
fresh; echo "edited" >>"$X/Contents/Resources/Friends/Acknowledgements.txt"
defect "" "Acknowledgements.txt is missing or differs" "edited acknowledgements"

# A helper executable that needs a library from outside macOS (one built here, so nothing is installed).
printf 'int szf_dep(void) { return 0; }\n' >"$T/dep.c"
cc -dynamiclib -install_name "$T/libszfdep.dylib" -o "$T/libszfdep.dylib" "$T/dep.c"
printf 'int szf_dep(void);\nint main(void) { return szf_dep(); }\n' >"$T/exe.c"
fresh; cc -o "$XH/Contents/MacOS/$FRIENDS_HELPER_NAME" "$T/exe.c" -L"$T" -lszfdep
defect --libraries "libraries macOS does not provide: $T/libszfdep.dylib" "helper linking a non-system library"
expect fails "$script_dir/bundle-dylibs.sh" "$X"
says "libraries macOS does not provide"
echo "  caught: bundle-dylibs.sh stops before signing such a helper"

fresh; echo "added after signing" >"$XH/Contents/Resources/added.txt"
expect 0 "$script_dir/check-friends-bundle.sh" "$X"
defect --signed "helper signature" "helper changed after signing"
rm -rf "$X"

echo "FriendsBundleTests passed"
