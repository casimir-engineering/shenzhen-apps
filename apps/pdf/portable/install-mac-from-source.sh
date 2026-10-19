#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Install Shenzhen PDF for macOS without Apple Developer notarization by building it
locally on this Mac.

Usage:
  ./portable/install-mac-from-source.sh
  ./portable/install-mac-from-source.sh <git-repo-url> [branch-or-tag]

For a one-line remote install, publish this repository first, then run:
  curl -fsSL https://example.com/install-mac-from-source.sh | bash -s -- <git-repo-url> [branch-or-tag]
USAGE
}

have() {
  command -v "$1" >/dev/null 2>&1
}

script_path="${BASH_SOURCE[0]:-}"
repo_root=""
cleanup_dir=""

if [[ -n "$script_path" && -f "$script_path" ]]; then
  repo_root="$(cd "$(dirname "$script_path")/.." && pwd)"
fi

repo_url="${1:-${SHENZHENPDF_REPO_URL:-}}"
repo_ref="${2:-${SHENZHENPDF_REPO_REF:-}}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "$repo_root" || ! -f "$repo_root/portable/Makefile" ]]; then
  if [[ -z "$repo_url" ]]; then
    usage
    exit 2
  fi
  if ! have git; then
    echo "git is required. Install Xcode Command Line Tools first: xcode-select --install" >&2
    exit 2
  fi

  cleanup_dir="$(mktemp -d "${TMPDIR:-/tmp}/shenzhenpdf-build.XXXXXX")"
  trap '[[ -n "$cleanup_dir" ]] && rm -rf "$cleanup_dir"' EXIT
  clone_args=(clone --depth 1)
  if [[ -n "$repo_ref" ]]; then
    clone_args+=(--branch "$repo_ref")
  fi
  clone_args+=("$repo_url" "$cleanup_dir/ShenzhenPDF")
  git "${clone_args[@]}"
  repo_root="$cleanup_dir/ShenzhenPDF"
fi

if ! xcrun --find clang >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required. Run: xcode-select --install" >&2
  exit 2
fi

if ! have pkg-config; then
  if have brew; then
    brew install pkg-config
  else
    echo "pkg-config is required. Install Homebrew, then run: brew install pkg-config openssl@3" >&2
    exit 2
  fi
fi

if ! pkg-config --exists openssl; then
  if have brew; then
    brew install openssl@3
  else
    echo "OpenSSL is required. Install Homebrew, then run: brew install openssl@3" >&2
    exit 2
  fi
fi

make -C "$repo_root/portable" install MAC_SIGN_IDENTITY=-

# Defensive cleanup if the source archive or enclosing folder was downloaded
# through a quarantine-aware app before this script built the app locally.
xattr -dr com.apple.quarantine "/Applications/ShenzhenPDF.app" 2>/dev/null || true

echo
echo "Installed /Applications/ShenzhenPDF.app"
echo "Open it from Finder or run: open /Applications/ShenzhenPDF.app"
