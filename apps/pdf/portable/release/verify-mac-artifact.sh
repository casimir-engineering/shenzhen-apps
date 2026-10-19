#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [--unsigned] --dmg <path> --version <YY.M.DD> --build <n> --bundle-id <id> [--team-id <id>] --min-os <version>" >&2
  echo "       $0 --friends-usage-keys <ShenzhenPDF.app>" >&2
  exit 2
}

# Shenzhen Friends finds people over the local network and Bluetooth from its helper, which macOS holds the app
# responsible for when the app starts it (ADR 0002 § Permission attribution). Without these keys a prompt explains
# nothing, the Local Network check may refuse browsing _szfriends._tcp, and asking for Bluetooth ends the process.
# The app and the helper both carry them, so the prompt reads the same whichever one macOS names.
verify_friends_usage_keys() {
  local plist="$1" key value services
  for key in NSBluetoothAlwaysUsageDescription NSLocalNetworkUsageDescription; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)" || value=""
    [[ -n "${value//[[:space:]]/}" ]] || { echo "$plist has no $key." >&2; return 1; }
  done
  # Captured first: grep -q ending a pipeline can SIGPIPE its writer and fail under pipefail.
  services="$(/usr/libexec/PlistBuddy -c 'Print :NSBonjourServices' "$plist" 2>/dev/null)" || services=""
  grep -Eq '^[[:space:]]*_szfriends\._tcp$' <<<"$services" || {
    echo "$plist does not declare the _szfriends._tcp Bonjour service." >&2
    return 1
  }
}

# The app build's own check (mac-friends-bundle-check), on the bundle before it is packaged.
if [[ "${1:-}" == "--friends-usage-keys" ]]; then
  [[ $# -eq 2 && -d "$2" ]] || usage
  verify_friends_usage_keys "$2/Contents/Info.plist"
  verify_friends_usage_keys "$2/Contents/Helpers/Shenzhen Friends.app/Contents/Info.plist"
  exit 0
fi

unsigned=0
dmg=""
version=""
build=""
bundle_id=""
team_id=""
min_os=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --unsigned) unsigned=1; shift ;;
    --dmg) dmg="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --build) build="${2:-}"; shift 2 ;;
    --bundle-id) bundle_id="${2:-}"; shift 2 ;;
    --team-id) team_id="${2:-}"; shift 2 ;;
    --min-os) min_os="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -f "$dmg" && -n "$version" && -n "$build" && -n "$bundle_id" && -n "$min_os" ]] || usage
[[ "$unsigned" == 1 || -n "$team_id" ]] || usage
[[ "$(basename "$dmg")" == "ShenzhenPDF-mac-arm64.dmg" ]] || {
  echo "Unexpected update asset name: $(basename "$dmg")" >&2
  exit 1
}

bytes="$(stat -f '%z' "$dmg")"
(( bytes < 64 * 1024 * 1024 )) || {
  echo "DMG is $bytes bytes; the updater requires less than 64 MiB." >&2
  exit 1
}

if [[ "$unsigned" == 0 ]]; then
  codesign --verify --strict --verbose=2 "$dmg"
  dmg_signing="$(codesign -d --verbose=4 "$dmg" 2>&1)"
  grep -Fq "TeamIdentifier=$team_id" <<<"$dmg_signing" || { echo "DMG Team ID mismatch." >&2; exit 1; }
  xcrun stapler validate "$dmg"
  spctl -a -vv -t open --context context:primary-signature "$dmg"
fi

# Shenzhen Friends ships as a helper inside the app (Contents/Helpers), signed on its own before the outer bundle.
# The release must carry it present and signed, with the version keys the running helper and the views compare to
# decide a handover: the same checks the app build makes (mac-friends-bundle-check), here on what people download.
verify_friends_helper() {
  local app="$1" version="$2" unsigned="$3" team_id="$4"
  local helper="$app/Contents/Helpers/Shenzhen Friends.app"
  local helper_plist="$helper/Contents/Info.plist"
  local helper_version helper_build helper_number helper_signing
  [[ -d "$helper" && ! -L "$helper" ]] || { echo "The Shenzhen Friends helper is missing." >&2; return 1; }
  [[ -x "$helper/Contents/MacOS/Shenzhen Friends" ]] || {
    echo "The Shenzhen Friends helper has no executable." >&2
    return 1
  }
  codesign --verify --strict --verbose=2 "$helper" || {
    echo "The Shenzhen Friends helper is not validly signed." >&2
    return 1
  }
  helper_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$helper_plist")" || return 1
  helper_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$helper_plist")" || return 1
  helper_number="$(/usr/libexec/PlistBuddy -c 'Print :SZFriendsBuildNumber' "$helper_plist")" || return 1
  [[ "$helper_version" == "$version" ]] || { echo "Friends helper version mismatch: $helper_version" >&2; return 1; }
  [[ "$helper_build" =~ ^[0-9]+$ ]] || {
    echo "Friends helper CFBundleVersion is not an integer: $helper_build" >&2
    return 1
  }
  [[ "$helper_build" == "$helper_number" ]] || {
    echo "Friends helper CFBundleVersion $helper_build differs from SZFriendsBuildNumber $helper_number." >&2
    return 1
  }
  if [[ "$unsigned" == 0 ]]; then
    helper_signing="$(codesign -d --verbose=4 "$helper" 2>&1)" || return 1
    grep -Fq "TeamIdentifier=$team_id" <<<"$helper_signing" || {
      echo "Friends helper Team ID mismatch." >&2
      return 1
    }
    grep -Eq 'flags=.*runtime' <<<"$helper_signing" || {
      echo "Friends helper hardened runtime is missing." >&2
      return 1
    }
  fi
}

# The assistant's Python sandbox (mac/python-sandbox/SPDFPythonSandbox.h) is a bare Mach-O in Contents/Helpers,
# signed on its own before the outer bundle. Every run_python goes through it, so a release must carry it validly
# signed by the same team with the hardened runtime, and with this release's version in its embedded Info.plist.
verify_python_sandbox_helper() {
  local app="$1" version="$2" unsigned="$3" team_id="$4"
  local helper="$app/Contents/Helpers/spdf-python-sandbox"
  local helper_signing helper_plist helper_version helper_build
  [[ -f "$helper" && ! -L "$helper" && -x "$helper" ]] || {
    echo "The Python sandbox helper is missing or not executable." >&2
    return 1
  }
  codesign --verify --strict --verbose=2 "$helper" || {
    echo "The Python sandbox helper is not validly signed." >&2
    return 1
  }
  helper_signing="$(codesign -d --verbose=4 "$helper" 2>&1)" || return 1
  grep -Fxq "Identifier=com.intuition.shenzhenpdf.python-sandbox" <<<"$helper_signing" || {
    echo "Python sandbox helper identifier mismatch." >&2
    return 1
  }
  helper_plist="$(launchctl plist __TEXT,__info_plist "$helper" 2>/dev/null)" || helper_plist=""
  helper_version="$(sed -n 's/^[[:space:]]*"CFBundleShortVersionString" = "\(.*\)";$/\1/p' <<<"$helper_plist")"
  helper_build="$(sed -n 's/^[[:space:]]*"CFBundleVersion" = "\(.*\)";$/\1/p' <<<"$helper_plist")"
  [[ "$helper_version" == "$version" ]] || {
    echo "Python sandbox helper version mismatch: $helper_version" >&2
    return 1
  }
  [[ "$helper_build" =~ ^[0-9]+$ ]] || {
    echo "Python sandbox helper CFBundleVersion is not an integer: $helper_build" >&2
    return 1
  }
  if [[ "$unsigned" == 0 ]]; then
    grep -Fq "TeamIdentifier=$team_id" <<<"$helper_signing" || {
      echo "Python sandbox helper Team ID mismatch." >&2
      return 1
    }
    grep -Eq 'flags=.*runtime' <<<"$helper_signing" || {
      echo "Python sandbox helper hardened runtime is missing." >&2
      return 1
    }
  fi
}

mount_point="$(mktemp -d /tmp/spdf-release-verify.XXXXXX)"
cleanup() {
  hdiutil detach "$mount_point" >/dev/null 2>&1 || \
    hdiutil detach -force "$mount_point" >/dev/null 2>&1 || true
  rmdir "$mount_point" >/dev/null 2>&1 || true
}
trap cleanup EXIT
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount_point" "$dmg" >/dev/null

shopt -s nullglob
all_apps=("$mount_point"/*.app)
apps=()
for candidate in "${all_apps[@]}"; do
  [[ -L "$candidate" ]] || apps+=("$candidate")
done
[[ ${#apps[@]} -eq 1 ]] || {
  echo "Expected exactly one non-symlink root app; found ${#apps[@]}." >&2
  exit 1
}
app="${apps[0]}"
plist="$app/Contents/Info.plist"
binary="$app/Contents/MacOS/ShenzhenPDF"

codesign --verify --deep --strict --verbose=2 "$app"
app_signing="$(codesign -d --verbose=4 "$app" 2>&1)"
if [[ "$unsigned" == 0 ]]; then
  grep -Fq "TeamIdentifier=$team_id" <<<"$app_signing" || { echo "App Team ID mismatch." >&2; exit 1; }
  grep -Eq 'flags=.*runtime' <<<"$app_signing" || { echo "Hardened runtime is missing." >&2; exit 1; }
  spctl -a -vv -t execute "$app"
fi
verify_friends_helper "$app" "$version" "$unsigned" "$team_id"
verify_python_sandbox_helper "$app" "$version" "$unsigned" "$team_id"
verify_friends_usage_keys "$plist"
verify_friends_usage_keys "$app/Contents/Helpers/Shenzhen Friends.app/Contents/Info.plist"

actual_bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
[[ "$actual_bundle" == "$bundle_id" ]] || { echo "Bundle ID mismatch: $actual_bundle" >&2; exit 1; }
[[ "$actual_version" == "$version" ]] || { echo "Version mismatch: $actual_version" >&2; exit 1; }
[[ "$actual_build" == "$build" ]] || { echo "Build mismatch: $actual_build" >&2; exit 1; }
[[ ! -e "$app/Contents/embedded.provisionprofile" ]] || { echo "A provisioning profile is embedded in the direct-download app." >&2; exit 1; }

mach_count=0
while IFS= read -r -d '' file_path; do
  file_description="$(file -b "$file_path")"
  [[ "$file_description" == *Mach-O* ]] || continue
  mach_count=$((mach_count + 1))
  archs="$(lipo -archs "$file_path")"
  [[ "$archs" == "arm64" ]] || { echo "Unexpected architectures in $file_path: $archs" >&2; exit 1; }
  object_min_os="$(vtool -show-build "$file_path" | awk '$1 == "minos" { print $2; exit }')"
  [[ "$object_min_os" == "$min_os" ]] || { echo "Unexpected minOS in $file_path: $object_min_os (expected $min_os)" >&2; exit 1; }
  if otool -L "$file_path" | grep -Eq 'libcrypto|/opt/homebrew|/usr/local'; then
    echo "Mutable or forbidden runtime dependency in $file_path:" >&2
    otool -L "$file_path" >&2
    exit 1
  fi
done < <(find "$app" -type f -print0)
(( mach_count > 0 )) || { echo "No Mach-O payload found in app." >&2; exit 1; }

entitlements="$(codesign -d --entitlements - "$app" 2>/dev/null || true)"
if grep -q 'com.apple.security.app-sandbox' <<<"$entitlements"; then
  echo "The direct-download app unexpectedly has the sandbox entitlement." >&2
  exit 1
fi

reported="$($binary --version)"
[[ "$reported" == *"$version-$build"* ]] || { echo "--version mismatch: $reported" >&2; exit 1; }

echo "Verified $(basename "$dmg"): $version-$build, arm64, minOS $min_os, $bytes bytes."
