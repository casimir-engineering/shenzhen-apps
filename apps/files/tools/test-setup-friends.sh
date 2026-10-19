#!/usr/bin/env bash
#
# test-setup-friends.sh — tools/setup-friends.sh against a small fake shenzhen-pdf repository.
#
# The fake has the paths the script reads (portable/Makefile with MAC_VERSION and MAC_BUILD, the animal manifest,
# ACKNOWLEDGEMENTS.txt) and a portable/Makefile whose friends-helper-bundle writes a stand-in helper bundle in
# seconds, stamped with the version values it is given and logging every real build. Everything is local: the
# fetch is over file://, nothing is built from the real shenzhen-pdf, and the temporary directory is removed on
# exit, pass or fail.
#
# Usage: tools/test-setup-friends.sh   (prints "SetupFriendsTests passed" and exits 0)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d -t szf-pkg-test)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
# Runs that test friends-src/ clear SZF_FRIENDS_ROOT; the ones that test it set their own. A value from the
# caller's environment (tools/test-friends-adapter.sh is often run with one) must reach neither, so this
# stand-in, which does not exist, makes any run that inherits it fail.
export SZF_FRIENDS_ROOT="$T/inherited-friends-root"

fail() { echo "FAIL: $*" >&2; exit 1; }
# expect <exit status | fails> <command…>: run it with output in $T/out and check its status.
expect() {
  local want="$1" got=0
  shift
  "$@" >"$T/out" 2>&1 || got=$?
  if [[ "$got" != "$want" && ! ( "$want" == fails && "$got" != 0 ) ]]; then
    cat "$T/out" >&2
    fail "exit $got, expected $want: $*"
  fi
}
says() { grep -qF -- "$1" "$T/out" || { cat "$T/out" >&2; fail "output lacks: $1"; }; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/portable/build/friends/Shenzhen Friends.app/Contents/Info.plist"; }
builds() { wc -l <"$1/portable/build/builds.log" 2>/dev/null | tr -d ' ' || echo 0; }

# --- the fake shenzhen-pdf ---------------------------------------------------------
P="$T/pdf"
git init -q "$P"
mkdir -p "$P/portable/friends/service/helper" "$P/portable/friends/avatars/animals"
echo '/build/' >"$P/portable/.gitignore"
echo '{"set":1}' >"$P/portable/friends/avatars/animals/manifest.json"
echo 'notices' >"$P/portable/friends/ACKNOWLEDGEMENTS.txt"
cat >"$P/portable/friends/service/helper/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.intuition.shenzhenfriends</string>
<key>CFBundleShortVersionString</key><string>0</string>
<key>CFBundleVersion</key><string>0</string>
<key>SZFriendsBuildNumber</key><integer>0</integer>
</dict></plist>
EOF
# Recipe lines start with '>' here and become tabs below (macOS make 3.81 has no .RECIPEPREFIX).
sed $'s/^>/\t/' >"$P/portable/Makefile" <<'EOF'
MAC_VERSION ?= 26.10.11
MAC_BUILD ?= 1
BUILD := build
FRIENDS_HELPER_SHORT_VERSION ?= 0.0.0
FRIENDS_HELPER_BUNDLE_VERSION ?= 0
FRIENDS_HELPER_SIGN_IDENTITY ?= (default)
NUMBER = $(shell echo "$(FRIENDS_HELPER_SHORT_VERSION) $(FRIENDS_HELPER_BUNDLE_VERSION)" | \
	awk '{ split($$1, v, "."); printf "%02d%02d%02d%02d", v[1] % 100, v[2], v[3], $$2 }')
APP = $(BUILD)/friends/Shenzhen Friends.app
STAMP := $(BUILD)/friends/helper/bundle.stamp
$(STAMP): friends/service/helper/Info.plist
>rm -rf "$(APP)"
>mkdir -p "$(APP)/Contents/MacOS" "$(@D)"
>cp friends/service/helper/Info.plist "$(APP)/Contents/Info.plist"
>/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(FRIENDS_HELPER_SHORT_VERSION)" \
>  -c "Set :CFBundleVersion $(NUMBER)" -c "Set :SZFriendsBuildNumber $(NUMBER)" "$(APP)/Contents/Info.plist"
>printf '#!/bin/sh\n' >"$(APP)/Contents/MacOS/Shenzhen Friends"
>chmod +x "$(APP)/Contents/MacOS/Shenzhen Friends"
>echo "$(FRIENDS_HELPER_SIGN_IDENTITY)" >"$(BUILD)/sign-identity"
>echo built >>"$(BUILD)/builds.log"
>touch "$@"
.PHONY: friends-helper-bundle friends-gtk-lib
friends-helper-bundle: $(STAMP)
friends-gtk-lib:
>mkdir -p $(BUILD)/friends/gtk
>touch $(BUILD)/friends/gtk/libszfriends_gtk.a
EOF
gitc() { git -C "$P" -c user.name=test -c user.email=test@localhost "$@"; }
gitc add -A && gitc commit -q -m A
A="$(git -C "$P" rev-parse HEAD)"
echo 'change' >"$P/portable/friends/ACKNOWLEDGEMENTS.txt"
gitc commit -q -am B
B="$(git -C "$P" rev-parse HEAD)"
gitc checkout -q -b with-gtk "$A"
mkdir -p "$P/portable/friends/gtk" && echo '# GTK views' >"$P/portable/friends/gtk/gtk.mk"
gitc add -A && gitc commit -q -m C
C="$(git -C "$P" rev-parse HEAD)"
gitc checkout -q main 2>/dev/null || gitc checkout -q master

# --- a Shenzhen Files tree holding only what the script uses -------------------------
F="$T/files"
mkdir -p "$F/tools"
cp "$script_dir/setup-friends.sh" "$script_dir/friends-lock.sh" "$F/tools/"
lock() {  # lock <commit> [build number] [extra line]
  printf '# test pin\nurl=file:///nonexistent/szf-test-origin\ncommit=%s\nhelper_build_number=%s\n%s' \
    "$1" "${2:-26101101}" "${3:-}" >"$F/friends.lock"
}
setup() { env -u SZF_FRIENDS_ROOT SZF_FRIENDS_URL="file://$P" "$F/tools/setup-friends.sh" "$@"; }
setup_from() { local root="$1"; shift; SZF_FRIENDS_ROOT="$root" "$F/tools/setup-friends.sh" "$@"; }
no_tree() { [[ ! -e "$F/friends-src" ]] || fail "friends-src/ created: $1"; }

# --- friends.lock is read strictly, before anything is fetched -----------------------
expect 1 setup; says "friends.lock is missing"; no_tree "missing lock"
lock "${A:0:12}"; expect 1 setup; says "full 40-digit"; no_tree "short commit"
lock "$A" 2610110; expect 1 setup; says "YYMMDDBB"; no_tree "seven digits"
lock "$A" 26131101; expect 1 setup; says "YYMMDDBB"; no_tree "month 13"
lock "$A" 26101100; expect 1 setup; says "YYMMDDBB"; no_tree "build 0"
lock "$A" 26101101 $'branch=main\n'; expect 1 setup; says "unknown key 'branch'"; no_tree "unknown key"
lock "$A" 26101101 "commit=$A"$'\n'; expect 1 setup; says "sets commit a second time"; no_tree "duplicate"
echo "lock parsing ok"

# --- a failed fetch leaves nothing behind -----------------------------------------
lock "$A"
expect fails env -u SZF_FRIENDS_ROOT SZF_FRIENDS_URL="file://$T/missing" "$F/tools/setup-friends.sh"
says "fetching shenzhen-pdf"
no_tree "failed fetch"
[[ -z "$(find "$F" -maxdepth 1 -name '.friends-setup.*')" ]] || fail "staging directory left behind"
echo "failed fetch ok"

# --- first run: fetch the pinned commit, detached, and build it once ------------------
expect 0 setup
says "friends-gtk-lib skipped"
[[ "$(git -C "$F/friends-src" rev-parse HEAD)" == "$A" ]] || fail "friends-src/ is not at the pinned commit"
! git -C "$F/friends-src" symbolic-ref -q HEAD >/dev/null || fail "friends-src/ is on a branch"
[[ "$(builds "$F/friends-src")" == 1 ]] || fail "expected one build, got $(builds "$F/friends-src")"
[[ "$(plist "$F/friends-src" CFBundleShortVersionString)" == 26.10.11 ]] || fail "short version"
[[ "$(plist "$F/friends-src" CFBundleVersion)" == 26101101 ]] || fail "CFBundleVersion"
[[ "$(plist "$F/friends-src" SZFriendsBuildNumber)" == 26101101 ]] || fail "SZFriendsBuildNumber"
[[ "$(cat "$F/friends-src/portable/build/sign-identity")" == - ]] || fail "helper not built ad hoc"
[[ ! -e "$F/friends-src/portable/build/friends/gtk" ]] || fail "friends-gtk-lib built without GTK views"
echo "first run ok"

# --- rerun: no fetch (the URL is unreachable now), no rebuild -----------------------
expect 0 env -u SZF_FRIENDS_ROOT SZF_FRIENDS_URL="file://$T/missing" "$F/tools/setup-friends.sh"
[[ "$(builds "$F/friends-src")" == 1 ]] || fail "rerun rebuilt the helper"
expect 0 setup --check
says "friends-src/ is shenzhen-pdf"
echo "idempotent rerun ok"

# --- --check changes nothing; a missing helper fails it ----------------------------
rm -rf "$F/friends-src/portable/build/friends/Shenzhen Friends.app"
expect 1 setup --check; says "no helper bundle"; says "Run tools/setup-friends.sh"
[[ ! -e "$F/friends-src/portable/build/friends/Shenzhen Friends.app" ]] || fail "--check built the helper"
rm -f "$F/friends-src/portable/build/friends/helper/bundle.stamp"
expect 0 setup
echo "check ok"

# --- a helper built earlier with other version values is made again -----------------
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 25010101" \
  "$F/friends-src/portable/build/friends/Shenzhen Friends.app/Contents/Info.plist"
before="$(builds "$F/friends-src")"
expect 0 setup; says "making its bundle again"
[[ "$(plist "$F/friends-src" CFBundleVersion)" == 26101101 ]] || fail "stale CFBundleVersion kept"
[[ "$(builds "$F/friends-src")" == $((before + 1)) ]] || fail "the bundle was not made again exactly once"
echo "stale version keys ok"

# --- pin mismatch: an existing friends-src/ at another commit is refused, untouched ----
lock "$B"
expect 1 setup; says "friends.lock pins $B"; says "Remove friends-src/"
[[ "$(git -C "$F/friends-src" rev-parse HEAD)" == "$A" ]] || fail "friends-src/ was moved"
lock "$A" 26101201
expect 1 setup; says "builds its helper as 26101101"
echo "pin mismatch ok"

# --- SZF_FRIENDS_ROOT must be detached at the pin and unmodified ----------------------
lock "$A"
clone() { git clone -q "$P" "$1" && git -C "$1" -c advice.detachedHead=false checkout -q --detach "$2"; }
clone "$T/at-b" "$B"
expect 1 setup_from "$T/at-b"; says "is at $B, but friends.lock pins $A"
[[ ! -e "$T/at-b/portable/build" ]] || fail "built in a checkout at the wrong commit"
git clone -q "$P" "$T/on-branch"
git -C "$T/on-branch" checkout -q -B work "$A"
expect 1 setup_from "$T/on-branch"; says "has the branch work checked out"
[[ ! -e "$T/on-branch/portable/build" ]] || fail "built in a working copy on a branch"
clone "$T/modified" "$A"
echo 'local edit' >>"$T/modified/portable/friends/ACKNOWLEDGEMENTS.txt"
expect 1 setup_from "$T/modified"; says "local changes"
clone "$T/untracked" "$A"
echo 'stray' >"$T/untracked/portable/friends/Stray.m"
expect 1 setup_from "$T/untracked"; says "Stray.m"
mkdir -p "$T/plain"
expect 1 setup_from "$T/plain"; says "not a git checkout"
expect 1 setup_from "$T/modified/portable"; says "not the top of one"
clone "$T/good" "$A"
expect 0 setup_from "$T/good"
[[ "$(builds "$T/good")" == 1 ]] || fail "SZF_FRIENDS_ROOT not built"
echo "SZF_FRIENDS_ROOT ok"

# --- the GTK views are built once the pinned commit has them --------------------------
lock "$C"
clone "$T/gtk" "$C"
expect 0 setup_from "$T/gtk"
[[ -f "$T/gtk/portable/build/friends/gtk/libszfriends_gtk.a" ]] || fail "friends-gtk-lib not built"
grep -qF "skipped" "$T/out" && fail "friends-gtk-lib reported as skipped"
rm "$T/gtk/portable/build/friends/gtk/libszfriends_gtk.a"
expect 1 setup_from "$T/gtk" --check; says "no GTK views library"
echo "GTK views ok"

# --- the Shenzhen repository: Friends is built from apps/pdf beside apps/files, nothing pinned or fetched -------
M="$T/mono"
mkdir -p "$M/apps/files/tools"
cp "$script_dir/setup-friends.sh" "$script_dir/friends-lock.sh" "$M/apps/files/tools/"
git clone -q "$P" "$M/apps/pdf"
in_tree() { env -u SZF_FRIENDS_ROOT -u SZF_FRIENDS_MODE "$M/apps/files/tools/setup-friends.sh" "$@"; }
expect 0 in_tree; says "building Friends from apps/pdf"
[[ "$(builds "$M/apps/pdf")" == 1 ]] || fail "apps/pdf not built"
[[ "$(plist "$M/apps/pdf" SZFriendsBuildNumber)" == 26101101 ]] || fail "number not from apps/pdf's Makefile"
[[ ! -e "$M/apps/files/friends-src" ]] || fail "a pin was fetched in the Shenzhen repository"
sed -i '' 's/^MAC_BUILD ?= 1$/MAC_BUILD ?= 2/' "$M/apps/pdf/portable/Makefile"
expect 0 in_tree
[[ "$(plist "$M/apps/pdf" CFBundleVersion)" == 26101102 ]] || fail "a new MAC_BUILD did not reach the helper"
expect 0 in_tree --check
expect 1 env -u SZF_FRIENDS_ROOT SZF_FRIENDS_MODE=pinned "$M/apps/files/tools/setup-friends.sh"
says "friends.lock is missing"
expect 1 env -u SZF_FRIENDS_ROOT SZF_FRIENDS_MODE=sideways "$M/apps/files/tools/setup-friends.sh"
says "SZF_FRIENDS_MODE must be tree or pinned"
echo "same tree ok"

echo "SetupFriendsTests passed"
