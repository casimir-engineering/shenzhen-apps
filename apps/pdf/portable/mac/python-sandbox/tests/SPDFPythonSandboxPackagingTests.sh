#!/usr/bin/env bash
# How the Python sandbox helper ships: the Info.plist linked into it carries the app's version and a whole-number
# build (no SPDF_PYTHON_SANDBOX_ placeholder left), and the release verifier's verify_python_sandbox_helper
# (release/verify-mac-artifact.sh) checks it in app bundles made here, so no disk image is built or mounted.
# Run from portable/: SPDFPythonSandboxPackagingTests.sh <built helper> <generated Info.plist> <MAC_VERSION>.
# Prints "SPDFPythonSandboxPackagingTests passed".
set -euo pipefail

[[ $# -eq 3 ]] || { echo "usage: $0 <spdf-python-sandbox> <Info.plist> <version>" >&2; exit 2; }
built="$1" generated="$2" version="$3"
verifier="release/verify-mac-artifact.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/szf-python-packaging.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
failures=0
fail() { echo "SPDFPythonSandboxPackagingTests: $1" >&2; failures=$((failures + 1)); }
embedded() { # embedded <binary> <key>: one value of the Info.plist linked into a Mach-O
  launchctl plist __TEXT,__info_plist "$1" 2>/dev/null | sed -n "s/^[[:space:]]*\"$2\" = \"\\(.*\\)\";\$/\\1/p"
}

# The plist the build generated, and the one linked into the helper it built.
if grep -q SPDF_PYTHON_SANDBOX_ "$generated"; then fail "the generated Info.plist still has a placeholder"; fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$generated")" == "$version" ]] || \
  fail "the generated Info.plist does not carry MAC_VERSION $version"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$generated")" =~ ^[0-9]+$ ]] || \
  fail "the generated Info.plist's CFBundleVersion is not a whole number"
[[ "$(embedded "$built" CFBundleShortVersionString)" == "$version" && \
   "$(embedded "$built" CFBundleVersion)" =~ ^[0-9]+$ && \
   "$(embedded "$built" CFBundleIdentifier)" == "com.intuition.shenzhenpdf.python-sandbox" ]] || \
  fail "the helper's embedded Info.plist is not the generated one"

# The verifier's function alone; the source-order check below proves the verifier calls it.
sed -n '/^verify_python_sandbox_helper() {$/,/^}$/p' "$verifier" >"$scratch/verify.sh"
grep -q '^verify_python_sandbox_helper() {$' "$scratch/verify.sh" || {
  echo "verify_python_sandbox_helper not found in $verifier" >&2
  exit 1
}
# shellcheck disable=SC1091
source "$scratch/verify.sh"
app_checks_line="$(grep -n 'codesign --verify --deep --strict --verbose=2 "$app"' "$verifier" | cut -d: -f1)"
call_line="$(grep -n '^verify_python_sandbox_helper "$app" "$version" "$unsigned" "$team_id"$' "$verifier" | \
  cut -d: -f1)"
binary_line="$(grep -n 'reported="$($binary --version)"' "$verifier" | cut -d: -f1)"
if [[ -z "$app_checks_line" || -z "$call_line" || -z "$binary_line" ]] || \
   (( call_line < app_checks_line || call_line > binary_line )); then
  fail "the verifier must check the Python helper after authenticating the app and before running its binary"
fi

printf 'int main(void) { return 0; }\n' >"$scratch/main.c"
# helper_with <name> <identifier> <short version> <build>: a stand-in helper with its own embedded Info.plist.
helper_with() {
  cat >"$scratch/$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleShortVersionString</key><string>$3</string>
<key>CFBundleVersion</key><string>$4</string>
</dict></plist>
PLIST
  clang -arch arm64 -mmacosx-version-min=12.0 "$scratch/main.c" -sectcreate __TEXT __info_plist "$scratch/$1.plist" \
    -o "$scratch/$1.bin"
  printf '%s\n' "$scratch/$1.bin"
}
# make_app <name> <helper binary> [unsigned]
make_app() {
  local app="$scratch/$1/ShenzhenPDF.app"
  mkdir -p "$app/Contents/Helpers"
  cp "$2" "$app/Contents/Helpers/spdf-python-sandbox"
  [[ "${3:-}" == unsigned ]] || codesign --force --sign - "$app/Contents/Helpers/spdf-python-sandbox" >/dev/null 2>&1
  printf '%s\n' "$app"
}
expect() { # expect <0|1> <description> <app> <version> <unsigned> <team id>
  local wanted="$1" description="$2" status=0
  shift 2
  ( verify_python_sandbox_helper "$@" ) >"$scratch/out" 2>&1 || status=1
  [[ "$status" == "$wanted" ]] || fail "$description (status $status): $(cat "$scratch/out")"
}

real="$(make_app real "$built")"
expect 0 "the helper this build made passes" "$real" "$version" 1 ""
expect 1 "a helper from another version fails" "$real" "0.0.1" 1 ""
expect 1 "a signed release needs the helper's Team ID and hardened runtime" "$real" "$version" 0 ABCDE12345
mkdir -p "$scratch/missing/ShenzhenPDF.app/Contents/Helpers"
expect 1 "a missing helper fails" "$scratch/missing/ShenzhenPDF.app" "$version" 1 ""
good="$(helper_with good com.intuition.shenzhenpdf.python-sandbox 26.10.12 7)"
expect 0 "a stand-in with the right keys passes, so the failures below are the keys'" \
  "$(make_app good "$good")" 26.10.12 1 ""
expect 1 "the old placeholders fail" "$(make_app placeholder "$(helper_with placeholder \
  com.intuition.shenzhenpdf.python-sandbox SPDF_PYTHON_SANDBOX_VERSION SPDF_PYTHON_SANDBOX_BUILD)")" \
  SPDF_PYTHON_SANDBOX_VERSION 1 ""
expect 1 "a build that is not a whole number fails" \
  "$(make_app dotted "$(helper_with dotted com.intuition.shenzhenpdf.python-sandbox 26.10.12 26.10.12)")" \
  26.10.12 1 ""
expect 1 "another identifier fails" "$(make_app other "$(helper_with other com.example.other 26.10.12 7)")" \
  26.10.12 1 ""
expect 1 "a helper not signed as the Python helper fails" "$(make_app unsigned "$good" unsigned)" 26.10.12 1 ""
altered="$(make_app altered "$good")"
printf 'changed' >>"$altered/Contents/Helpers/spdf-python-sandbox"
expect 1 "a helper changed after signing fails" "$altered" 26.10.12 1 ""

((failures == 0)) || exit 1
echo "SPDFPythonSandboxPackagingTests passed"
