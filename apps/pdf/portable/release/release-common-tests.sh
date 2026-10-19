#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/release-common.sh"

# The suite must assert the gates' real behaviour, not the caller's. Preparing a
# release with SPDF_README_UNCHANGED=1 exports it into these tests and silently
# turned the rejection case below into a pass -- the override neutering the very
# assertion that proves it is an override. Each case sets what it needs itself.
unset SPDF_README_UNCHANGED

failures=0
expect_equal() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    failures=$((failures + 1))
  fi
}

expect_rejected() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL %s: input was accepted\n' "$label" >&2
    failures=$((failures + 1))
  fi
}

spdf_validate_release_version "26.8.27"
expect_rejected "zero-padded month" spdf_validate_release_version "26.08.27"
expect_rejected "missing date field" spdf_validate_release_version "26.8"
expect_equal "multi-digit build selection" \
  "$(spdf_next_build_for_tags "26.8.27" $'26.8.27-2\n26.8.27-10\n26.8.26-99\n26.8.27-bad')" "11"
expect_equal "first build" "$(spdf_next_build_for_tags "26.8.27" "")" "1"

tmp="$(mktemp -d /tmp/spdf-release-common-tests.XXXXXX)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

printf '%s\n' '- Fast update' '' '---' '' 'Detailed change.' > "$tmp/valid.md"
spdf_validate_release_notes "$tmp/valid.md" >/dev/null
printf '%s\n' '- Fast update' '' '---' > "$tmp/no-details.md"
expect_rejected "empty details" spdf_validate_release_notes "$tmp/no-details.md"
printf '%s\n' '- TODO' '' '---' '' 'Detailed change.' > "$tmp/placeholder.md"
expect_rejected "placeholder" spdf_validate_release_notes "$tmp/placeholder.md"
printf '%s\n' 'not a bullet' '' '---' '' 'Detailed change.' > "$tmp/not-bullets.md"
expect_rejected "non-bullet highlights" spdf_validate_release_notes "$tmp/not-bullets.md"

# README release checklist: badge-only churn is stale, content changes or the
# explicit SPDF_README_UNCHANGED=1 acknowledgement pass, and repos with no
# prior tag are exempt.
readme_repo="$tmp/readme-repo"
git init -q "$readme_repo"
git -C "$readme_repo" -c user.name=t -c user.email=t@t config commit.gpgsign false
printf '%s\n%s\n' '<sub>Latest <b>26.8.1-1</b></sub>' 'Feature list.' > "$readme_repo/readme.md"
git -C "$readme_repo" add readme.md
git -C "$readme_repo" -c user.name=t -c user.email=t@t commit -qm base
spdf_require_fresh_readme "$readme_repo" "" >/dev/null  # no prior tag: exempt
git -C "$readme_repo" tag 26.8.1-1
sed -i '' 's/26.8.1-1/26.8.2-1/' "$readme_repo/readme.md"
git -C "$readme_repo" add readme.md
git -C "$readme_repo" -c user.name=t -c user.email=t@t commit -qm badge-only
expect_rejected "badge-only readme churn" spdf_require_fresh_readme "$readme_repo" "26.8.1-1"
expect_equal "explicit unchanged acknowledgement" \
  "$(SPDF_README_UNCHANGED=1 spdf_require_fresh_readme "$readme_repo" "26.8.1-1" && echo ok)" "ok"
printf '%s\n' 'New feature paragraph.' >> "$readme_repo/readme.md"
git -C "$readme_repo" add readme.md
git -C "$readme_repo" -c user.name=t -c user.email=t@t commit -qm content
spdf_require_fresh_readme "$readme_repo" "26.8.1-1" >/dev/null
# A README rewritten wholesale is the clearest possible pass, and it was the one
# case that failed: the gate ended its pipe in `grep -q`, which exits at the
# first changed line, and under pipefail the SIGPIPE'd upstream greps turned a
# 94-line rewrite into "only the version badge moved". Big enough to overrun
# the pipe buffer, so a regression cannot hide behind a diff that fits in it.
seq 1 20000 | sed 's/^/Rewritten line /' > "$readme_repo/readme.md"
printf '%s\n' '<sub>Latest <b>26.8.2-1</b></sub>' >> "$readme_repo/readme.md"
git -C "$readme_repo" add readme.md
git -C "$readme_repo" -c user.name=t -c user.email=t@t commit -qm rewrite
expect_equal "a wholesale readme rewrite is accepted" \
  "$(spdf_require_fresh_readme "$readme_repo" "26.8.1-1" && echo ok)" "ok"

# The standalone repository tags 26.8.2-1 on master; the Shenzhen repository, where this app is apps/pdf, tags
# pdf/26.8.2-1 on main.
layout_repo="$(mktemp -d "${TMPDIR:-/tmp}/spdf-release-layout.XXXXXX")"
git -C "$layout_repo" init -q
mkdir -p "$layout_repo/apps/pdf/portable"
expect_equal "standalone layout" \
  "$(spdf_release_layout "$layout_repo" && echo "[$SPDF_TAG_PREFIX] $SPDF_RELEASE_BRANCH")" "[] master"
expect_equal "monorepo layout" \
  "$(spdf_release_layout "$layout_repo/apps/pdf" && echo "[$SPDF_TAG_PREFIX] $SPDF_RELEASE_BRANCH")" "[pdf/] main"
rm -rf "$layout_repo"

if ((failures)); then
  printf 'release-common-tests: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'release-common-tests passed\n'
