#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Build the committed Shenzhen PDF release metadata as a signed, notarized,
stapled, and fully verified direct-GitHub DMG. This command never tags, pushes,
or publishes.

Usage: ./portable/build-mac-release.sh

Requires a clean worktree, an arm64 Mac, and portable/.release.env containing:
  MAC_SIGN_IDENTITY="Developer ID Application: ..."
  NOTARY_PROFILE="notarytool-keychain-profile"
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
[[ $# == 0 ]] || { usage >&2; exit 2; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck disable=SC1091
source "$script_dir/release/release-common.sh"
cd "$repo_root"

[[ "$(uname -s)" == "Darwin" ]] || spdf_release_fail "macOS is required"
[[ "$(uname -m)" == "arm64" ]] || spdf_release_fail "An arm64 Mac is required"
[[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] || \
  spdf_release_fail "The release build requires a clean worktree"

spdf_load_committed_release_metadata "$repo_root"
if [[ -f "$script_dir/.release.env" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$script_dir/.release.env"
fi
[[ "${MAC_SIGN_IDENTITY:-}" == "Developer ID Application:"* ]] || \
  spdf_release_fail "MAC_SIGN_IDENTITY must be a Developer ID Application identity"
[[ -n "${NOTARY_PROFILE:-}" ]] || spdf_release_fail "NOTARY_PROFILE is required"
security find-identity -v -p codesigning | grep -qF "$MAC_SIGN_IDENTITY" || \
  spdf_release_fail "Signing identity is unavailable: $MAC_SIGN_IDENTITY"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null || \
  spdf_release_fail "Notary profile is unavailable: $NOTARY_PROFILE"

dmg="$repo_root/dist/ShenzhenPDF-mac-arm64.dmg"
notary_result="$repo_root/dist/notarytool-${SPDF_RELEASE_VERSION}-${SPDF_RELEASE_BUILD}.json"
mupdf_out="build/release-macos-${SPDF_RELEASE_ARCH}-${SPDF_RELEASE_MIN_OS}"

printf '==> Clean release build for %s\n' "$SPDF_RELEASE_TAG"
make -C "$script_dir" clean
rm -rf "$repo_root/mupdf/$mupdf_out" "$notary_result"
env -u SPDF_RELEASE_MODE -u MAC_ARCH -u MACOSX_DEPLOYMENT_TARGET -u MAC_BUNDLE_ID \
  -u MAC_TEAM_ID -u PORTABLE_OPTFLAGS -u MUPDF_OUT \
  make -C "$script_dir" release-dmg \
  SPDF_RELEASE_MODE=1 \
  MAC_VERSION="$SPDF_RELEASE_VERSION" \
  MAC_BUILD="$SPDF_RELEASE_BUILD" \
  MAC_ARCH="$SPDF_RELEASE_ARCH" \
  MACOSX_DEPLOYMENT_TARGET="$SPDF_RELEASE_MIN_OS" \
  MAC_BUNDLE_ID="$SPDF_RELEASE_BUNDLE_ID" \
  MAC_TEAM_ID="$SPDF_RELEASE_TEAM_ID" \
  PORTABLE_OPTFLAGS="$SPDF_RELEASE_OPTFLAGS" \
  MUPDF_OUT="$mupdf_out" \
  MAC_SIGN_IDENTITY="$MAC_SIGN_IDENTITY" \
  NOTARY_PROFILE="$NOTARY_PROFILE" \
  NOTARY_RESULT="$notary_result"

[[ -f "$notary_result" ]] || spdf_release_fail "Missing notarytool result: $notary_result"
notary_status="$(plutil -extract status raw -o - "$notary_result")"
notary_id="$(plutil -extract id raw -o - "$notary_result")"
[[ "$notary_status" == "Accepted" ]] || spdf_release_fail "Notarization was not accepted: $notary_status"
sha256="$(shasum -a 256 "$dmg" | awk '{print $1}')"
[[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] || \
  spdf_release_fail "Build changed the worktree"

printf 'Release candidate: %s\n' "$dmg"
printf 'Version: %s\n' "$SPDF_RELEASE_TAG"
printf 'SHA-256: %s\n' "$sha256"
printf 'Notarization: %s (%s)\n' "$notary_status" "$notary_id"
