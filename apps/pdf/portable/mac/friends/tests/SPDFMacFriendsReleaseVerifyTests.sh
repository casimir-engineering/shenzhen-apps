#!/usr/bin/env bash
# The release verifier's Shenzhen Friends checks (release/verify-mac-artifact.sh verify_friends_helper and
# verify_friends_usage_keys), run against app bundles made here, so no disk image is built or mounted. Brief
# § Packaging: release packaging tests assert the helper is present and signed. Run from portable/; prints
# "SPDFMacFriendsReleaseVerifyTests passed".
set -euo pipefail

verifier="release/verify-mac-artifact.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/szf-release-verify.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
failures=0
fail() { echo "SPDFMacFriendsReleaseVerifyTests: $1" >&2; failures=$((failures + 1)); }

# The function alone, so the checks run without a DMG; the source-order test below proves the verifier calls it.
sed -n '/^verify_friends_helper() {$/,/^}$/p' "$verifier" >"$scratch/verify.sh"
grep -q '^verify_friends_helper() {$' "$scratch/verify.sh" || { echo "verify_friends_helper not found" >&2; exit 1; }
# shellcheck disable=SC1091
source "$scratch/verify.sh"

app_checks_line="$(grep -n 'codesign --verify --deep --strict --verbose=2 "$app"' "$verifier" | cut -d: -f1)"
call_line="$(grep -n '^verify_friends_helper "$app" "$version" "$unsigned" "$team_id"$' "$verifier" | cut -d: -f1)"
binary_line="$(grep -n 'reported="$($binary --version)"' "$verifier" | cut -d: -f1)"
if [[ -z "$app_checks_line" || -z "$call_line" || -z "$binary_line" ]] || \
   (( call_line < app_checks_line || call_line > binary_line )); then
  fail "the verifier must check the helper after authenticating the app and before running its binary"
fi

printf 'int main(void) { return 0; }\n' >"$scratch/main.c"
clang -arch arm64 -mmacosx-version-min=12.0 "$scratch/main.c" -o "$scratch/helper-binary"

# make_app <name> <short version> <CFBundleVersion> <SZFriendsBuildNumber> [unsigned]
make_app() {
  local app="$scratch/$1/ShenzhenPDF.app"
  local helper="$app/Contents/Helpers/Shenzhen Friends.app"
  mkdir -p "$helper/Contents/MacOS"
  cp "$scratch/helper-binary" "$helper/Contents/MacOS/Shenzhen Friends"
  cat >"$helper/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Shenzhen Friends</string>
<key>CFBundleIdentifier</key><string>com.intuition.shenzhenfriends.test</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$2</string>
<key>CFBundleVersion</key><string>$3</string>
<key>SZFriendsBuildNumber</key><string>$4</string>
</dict></plist>
PLIST
  [[ "${5:-}" == unsigned ]] || codesign --force --sign - "$helper" >/dev/null 2>&1
  printf '%s\n' "$app"
}

expect() { # expect <0|1> <description> <app> <version> <unsigned> <team id>
  local wanted="$1" description="$2" status=0
  shift 2
  ( verify_friends_helper "$@" ) >"$scratch/out" 2>&1 || status=1
  [[ "$status" == "$wanted" ]] || { fail "$description (status $status): $(cat "$scratch/out")"; }
}

good="$(make_app good 26.10.12 26101201 26101201)"
expect 0 "a present, signed helper with matching integer build numbers passes" "$good" 26.10.12 1 ""
expect 1 "a helper from another version fails" "$good" 26.10.13 1 ""
expect 1 "a signed release needs the helper to carry the Team ID and the runtime flag" "$good" 26.10.12 0 ABCDE12345
mkdir -p "$scratch/missing/ShenzhenPDF.app/Contents"
expect 1 "a missing helper fails" "$scratch/missing/ShenzhenPDF.app" 26.10.12 1 ""
expect 1 "an unsigned helper fails" "$(make_app unsigned 26.10.12 26101201 26101201 unsigned)" 26.10.12 1 ""
expect 1 "a non-integer CFBundleVersion fails" "$(make_app dotted 26.10.12 26.10.12 26.10.12)" 26.10.12 1 ""
expect 1 "CFBundleVersion must equal SZFriendsBuildNumber" "$(make_app split 26.10.12 26101201 26101202)" 26.10.12 1 ""
altered="$(make_app altered 26.10.12 26101201 26101201)"
printf 'changed' >>"$altered/Contents/Helpers/Shenzhen Friends.app/Contents/MacOS/Shenzhen Friends"
expect 1 "a helper changed after signing fails" "$altered" 26.10.12 1 ""

# The Nearby permission keys (brief § Nearby; ADR 0002 § Permission attribution): the reader is the app macOS holds
# responsible for the helper it starts, and its Info.plist had none of them, so the first Bluetooth request would end
# the helper and the Local Network prompt would explain nothing.
sed -n '/^verify_friends_usage_keys() {$/,/^}$/p' "$verifier" >"$scratch/keys.sh"
grep -q '^verify_friends_usage_keys() {$' "$scratch/keys.sh" || {
  echo "verify_friends_usage_keys not found" >&2
  exit 1
}
# shellcheck disable=SC1091
source "$scratch/keys.sh"
keys_call="$(grep -n '^verify_friends_usage_keys "$plist"$' "$verifier" | cut -d: -f1)"
helper_plist_call='^verify_friends_usage_keys "$app/Contents/Helpers/Shenzhen Friends.app/Contents/Info.plist"$'
helper_keys_call="$(grep -n "$helper_plist_call" "$verifier" | cut -d: -f1)"
if [[ -z "$keys_call" || -z "$helper_keys_call" ]] || (( keys_call < app_checks_line || keys_call > binary_line )) || \
   (( helper_keys_call < app_checks_line || helper_keys_call > binary_line )); then
  fail "the verifier must check the app's and the helper's usage keys before running the app's binary"
fi

expect_keys() { # expect_keys <0|1> <description> <plist>
  local status=0
  ( verify_friends_usage_keys "$3" ) >"$scratch/out" 2>&1 || status=1
  [[ "$status" == "$1" ]] || fail "$2 (status $status): $(cat "$scratch/out")"
}
expect_keys 0 "the reader's own Info.plist carries every key" mac/Info.plist
expect_keys 0 "the helper's Info.plist carries every key" friends/service/helper/Info.plist

# usage_plist <name> <bluetooth text> <local network text> <bonjour type>; an empty argument leaves the key out.
usage_plist() {
  local plist="$scratch/$1.plist"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>\n' >"$plist"
  [[ -z "$2" ]] || printf '<key>NSBluetoothAlwaysUsageDescription</key><string>%s</string>\n' "$2" >>"$plist"
  [[ -z "$3" ]] || printf '<key>NSLocalNetworkUsageDescription</key><string>%s</string>\n' "$3" >>"$plist"
  [[ -z "$4" ]] || printf '<key>NSBonjourServices</key><array><string>%s</string></array>\n' "$4" >>"$plist"
  printf '</dict></plist>\n' >>"$plist"
  printf '%s\n' "$plist"
}
expect_keys 0 "all three keys pass" "$(usage_plist all 'Finds people.' 'Finds people.' _szfriends._tcp)"
expect_keys 1 "no Bluetooth text fails" "$(usage_plist nobt '' 'Finds people.' _szfriends._tcp)"
expect_keys 1 "no Local Network text fails" "$(usage_plist nolan 'Finds people.' '' _szfriends._tcp)"
expect_keys 1 "a blank text fails" "$(usage_plist blank '   ' 'Finds people.' _szfriends._tcp)"
expect_keys 1 "no Bonjour services fails" "$(usage_plist nobonjour 'Finds people.' 'Finds people.' '')"
expect_keys 1 "another Bonjour type fails" "$(usage_plist other 'Finds people.' 'Finds people.' _szfriends._tcpx)"

# The mode the app build's bundle check runs: the app and its embedded helper, from the bundle itself.
mode_app="$scratch/mode/ShenzhenPDF.app"
mkdir -p "$mode_app/Contents/Helpers/Shenzhen Friends.app/Contents"
cp mac/Info.plist "$mode_app/Contents/Info.plist"
cp friends/service/helper/Info.plist "$mode_app/Contents/Helpers/Shenzhen Friends.app/Contents/Info.plist"
status=0; "$verifier" --friends-usage-keys "$mode_app" >"$scratch/out" 2>&1 || status=$?
[[ "$status" == 0 ]] || fail "--friends-usage-keys refused a bundle with every key ($status): $(cat "$scratch/out")"
/usr/libexec/PlistBuddy -c 'Delete :NSBonjourServices' "$mode_app/Contents/Info.plist" >/dev/null
status=0; "$verifier" --friends-usage-keys "$mode_app" >"$scratch/out" 2>&1 || status=$?
[[ "$status" == 1 ]] || fail "--friends-usage-keys passed an app without NSBonjourServices ($status)"
status=0; "$verifier" --friends-usage-keys >"$scratch/out" 2>&1 || status=$?
[[ "$status" == 2 ]] || fail "--friends-usage-keys without a bundle must print usage ($status)"

((failures == 0)) || exit 1
echo "SPDFMacFriendsReleaseVerifyTests passed"
