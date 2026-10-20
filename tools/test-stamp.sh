#!/usr/bin/env bash
# test-stamp.sh: which test suites passed on which commit, so a release runs only the suites that have not.
#
#   tools/test-stamp.sh check  <suite>                  exit 0 when <suite> passed on this commit
#   tools/test-stamp.sh record <suite> [seconds]        record that <suite> passed on this commit
#   tools/test-stamp.sh run    <suite> -- <command...>  skip when it passed; otherwise run the command and record it
#                                                       when it exits 0 (its exit status is passed on)
#   tools/test-stamp.sh list   [<commit>]               the suites that passed on that commit (default HEAD)
#
# <suite> names the app and the suite: pdf/friends-tests, files/friends-adapter, 3d/unit. The commit is HEAD of the
# worktree the command runs in. A stamp is filed under the content the app's suites are built from at that commit:
# apps/pdf for pdf/, apps/files and apps/pdf (Friends) for files/, apps/3d and apps/pdf for 3d/, the whole tree for
# anything else. So a commit that changes nothing there keeps the stamps: a fast-forward, a merge that changed
# nothing, a release of another app. A worktree with uncommitted changes, untracked files included, records nothing
# and finds nothing: what ran there is not what any commit holds.
#
# The normal test entry points record themselves: make -C apps/pdf/portable friends-tests and
# mac-launch-performance-tests, every ShenzhenPDF suite the release sweep runs (cut-release.sh, tools/release.sh), and
# Shenzhen Files' tools/test-friends-adapter.sh and tools/test-macos-friends-shortcut.sh. Shenzhen 3D's npm scripts
# take extra arguments for a subset, so they are recorded when run through `run` (tools/release.sh does).
#
# Stamps live in $SHENZHEN_BUILD_CACHE/test-stamps/<content>/<app>/<suite> (default ~/Library/Caches/shenzhen-build),
# one directory for every worktree. SHENZHEN_TEST_STAMPS=0 neither records nor finds any.
set -euo pipefail

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

cache="${SHENZHEN_BUILD_CACHE:-$HOME/Library/Caches/shenzhen-build}"
enabled="${SHENZHEN_TEST_STAMPS:-1}"

valid_suite() {
  [[ "$1" =~ ^[a-z0-9]+/[A-Za-z0-9._-]+$ ]] || { echo "test-stamp: not a suite name (app/name): $1" >&2; exit 2; }
}

# The content an app's suites build from at <rev>: one hash of the trees named above.
content_key() {
  local app="$1" rev="$2" paths=() path
  case "$app" in
    pdf) paths=(apps/pdf) ;;
    files) paths=(apps/files apps/pdf) ;;
    3d) paths=(apps/3d apps/pdf) ;;
    *) git rev-parse "$rev^{tree}"; return ;;
  esac
  for path in "${paths[@]}"; do
    printf '%s %s\n' "$path" "$(git rev-parse "$rev:$path")"
  done | git hash-object --stdin
}

# Prints the content key of HEAD for <app> when the worktree holds exactly HEAD; returns 1 otherwise.
clean_key() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  [[ -z "$(git status --porcelain=v1 --untracked-files=normal 2>/dev/null)" ]] || return 1
  content_key "$1" HEAD
}

stamp_path() { printf '%s/test-stamps/%s/%s\n' "$cache" "$1" "$2"; }

check() {
  local suite="$1" key
  [[ "$enabled" != 0 ]] || return 1
  key="$(clean_key "${suite%%/*}")" || return 1
  [[ -f "$(stamp_path "$key" "$suite")" ]]
}

record() {
  local suite="$1" seconds="${2:-}" key file tmp
  [[ "$enabled" != 0 ]] || return 0
  if ! key="$(clean_key "${suite%%/*}")"; then
    echo "test-stamp: $suite passed, not recorded: the worktree has uncommitted changes" >&2
    return 0
  fi
  file="$(stamp_path "$key" "$suite")"
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "$file.XXXXXX")"
  printf 'commit=%s\ncontent=%s\npassed=%s\nseconds=%s\nhost=%s\n' "$(git rev-parse HEAD)" "$key" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$seconds" "$(hostname -s)" > "$tmp"
  mv -f "$tmp" "$file"
  echo "test-stamp: recorded $suite on $(git rev-parse --short HEAD)" >&2
}

(($# >= 1)) || usage
command="$1"
shift
case "$command" in
  check)
    (($# == 1)) || usage
    valid_suite "$1"
    check "$1"
    ;;
  record)
    (($# == 1 || $# == 2)) || usage
    valid_suite "$1"
    record "$@"
    ;;
  run)
    (($# >= 3)) && [[ "$2" == "--" ]] || usage
    suite="$1"
    valid_suite "$suite"
    shift 2
    if check "$suite"; then
      echo "test-stamp: $suite already passed on $(git rev-parse --short HEAD); skipped" >&2
      exit 0
    fi
    start="$(date +%s)"
    status=0
    "$@" || status=$?
    if ((status == 0)); then
      record "$suite" "$(($(date +%s) - start))"
    fi
    exit "$status"
    ;;
  list)
    (($# <= 1)) || usage
    [[ "$enabled" != 0 ]] || exit 0
    rev="${1:-HEAD}"
    git rev-parse -q --verify "$rev^{commit}" >/dev/null || { echo "test-stamp: not a commit: $rev" >&2; exit 2; }
    for app in pdf files 3d; do
      dir="$cache/test-stamps/$(content_key "$app" "$rev")/$app"
      [[ -d "$dir" ]] || continue
      (cd "$dir" && find . -type f ! -name '*.??????' | sed "s|^\./|$app/|")
    done | sort
    ;;
  *) usage ;;
esac
