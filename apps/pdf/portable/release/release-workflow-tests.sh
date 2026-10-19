#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
portable_dir="$(cd "$script_dir/.." && pwd)"
# shellcheck disable=SC1091
source "$script_dir/release-common.sh"

failures=0
passed=0
tmp="$(mktemp -d "${TMPDIR:-/tmp}/spdf-release-workflow.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM

pass() {
  printf 'ok - %s\n' "$1"
  passed=$((passed + 1))
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  failures=$((failures + 1))
}

expect_equal() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then pass "$label"; else
    printf '  expected: %s\n  actual:   %s\n' "$expected" "$actual" >&2
    fail "$label"
  fi
}

expect_pass() {
  local label="$1"
  shift
  if "$@" >"$tmp/stdout" 2>"$tmp/stderr"; then pass "$label"; else
    cat "$tmp/stdout" "$tmp/stderr" >&2
    fail "$label"
  fi
}

expect_rejected() {
  local label="$1"
  shift
  if "$@" >"$tmp/stdout" 2>"$tmp/stderr"; then
    fail "$label"
  else
    pass "$label"
  fi
}

assert_before() {
  local label="$1" file="$2" first="$3" second="$4"
  local first_line second_line
  first_line="$(grep -nF -- "$first" "$file" | head -1 | cut -d: -f1)"
  second_line="$(grep -nF -- "$second" "$file" | head -1 | cut -d: -f1)"
  if [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]]; then
    pass "$label"
  else
    printf '  order not established: %s (%s), %s (%s)\n' "$first" "$first_line" "$second" "$second_line" >&2
    fail "$label"
  fi
}

expect_equal "canonical release constants" \
  "$SPDF_RELEASE_TEAM_ID|$SPDF_RELEASE_BUNDLE_ID|$SPDF_RELEASE_ARCH|$SPDF_RELEASE_MIN_OS|$SPDF_RELEASE_OPTFLAGS" \
  "66LJ4BV7Q3|com.intuition.shenzhenpdf|arm64|12.0|-O2 -DNDEBUG"

hostile_config="$(env MAC_TEAM_ID=BADTEAM MAC_BUNDLE_ID=com.example.bad MAC_ARCH=x86_64 \
  MACOSX_DEPLOYMENT_TARGET=99.0 PORTABLE_OPTFLAGS=-O0 \
  make -s --no-print-directory -C "$portable_dir" print-release-config SPDF_RELEASE_MODE=1)"
expect_equal "hostile environment cannot override release configuration" "$hostile_config" \
  "66LJ4BV7Q3|com.intuition.shenzhenpdf|arm64|12.0|-O2 -DNDEBUG"
hostile_cli_config="$(make -s --no-print-directory -C "$portable_dir" print-release-config \
  SPDF_RELEASE_MODE=1 \
  MAC_TEAM_ID=BADTEAM MAC_BUNDLE_ID=com.example.bad MAC_ARCH=x86_64 \
  MACOSX_DEPLOYMENT_TARGET=99.0 PORTABLE_OPTFLAGS=-O0)"
expect_equal "hostile make arguments cannot override release configuration" "$hostile_cli_config" \
  "66LJ4BV7Q3|com.intuition.shenzhenpdf|arm64|12.0|-O2 -DNDEBUG"
developer_config="$(make -s --no-print-directory -C "$portable_dir" print-release-config \
  MAC_TEAM_ID=DEVTEAM MAC_BUNDLE_ID=com.example.dev MAC_ARCH=x86_64 \
  MACOSX_DEPLOYMENT_TARGET=13.4 PORTABLE_OPTFLAGS='-O0 -g -fsanitize=address')"
expect_equal "developer builds retain explicit overrideability" "$developer_config" \
  "DEVTEAM|com.example.dev|x86_64|13.4|-O0 -g -fsanitize=address"
expect_rejected "release-dmg rejects an unguarded direct invocation" \
  make -s --no-print-directory -C "$portable_dir" release-dmg SPDF_RELEASE_MODE=0

targets="$(spdf_discover_test_targets "$portable_dir/Makefile")"
for target in icon-tests mac-markdown-tests linux-password-tests file-size-ratchet-tests \
  mac-selection-click-tests mac-selection-adapter-tests mac-ai-web-tests mac-ai-subagents-tests mac-ai-python-tests \
  mac-launch-performance-tests; do
  if grep -qxF "$target" <<<"$targets"; then pass "release discovery includes $target"; else fail "release discovery includes $target"; fi
done
markdown_gate="$(sed -n '/^mac-markdown-tests:/,/^[^[:space:]].*:/p' "$portable_dir/Makefile")"
if grep -qF 'mac/tests/markdown/run-tests.sh' <<<"$markdown_gate" && \
   grep -qF 'mac/tests/run-markdown-integration-tests.sh' <<<"$markdown_gate"; then
  pass "mac-markdown-tests runs foundation and native integration suites"
else
  fail "mac-markdown-tests runs foundation and native integration suites"
fi

expect_pass "release command help is side-effect free" "$portable_dir/cut-release.sh" --help
expect_rejected "release mode must be explicit" "$portable_dir/cut-release.sh"
expect_rejected "release modes are mutually exclusive" "$portable_dir/cut-release.sh" --dry-run --publish
# shellcheck disable=SC2016
assert_before "publish loads committed metadata before release actions" "$portable_dir/cut-release.sh" \
  'spdf_load_committed_release_metadata "$repo_root"' '  run_release_tests'
# shellcheck disable=SC2016
assert_before "publish exits before preparation mutates metadata" "$portable_dir/cut-release.sh" \
  'log "Published and byte-verified $tag"' 'sed -i'
if grep -Fq 'SPDF_RELEASE_MODE=1' "$portable_dir/build-mac-release.sh"; then
  pass "release builder activates immutable release mode"
else
  fail "release builder activates immutable release mode"
fi
if grep -Fq 'git push --atomic origin' "$portable_dir/cut-release.sh" && \
   grep -Fq 'spdf_publish_github_release' "$portable_dir/cut-release.sh"; then
  pass "publication has atomic ref creation and recoverable GitHub operation"
else
  fail "publication has atomic ref creation and recoverable GitHub operation"
fi

git init -q --bare "$tmp/origin.git"
git init -q "$tmp/work"
git -C "$tmp/work" config user.email release-test@example.invalid
git -C "$tmp/work" config user.name "Release Test"
printf 'one\n' >"$tmp/work/file"
git -C "$tmp/work" add file
git -C "$tmp/work" commit -qm first
git -C "$tmp/work" remote add origin "$tmp/origin.git"
commit_one="$(git -C "$tmp/work" rev-parse HEAD)"
expect_pass "local tag is created" spdf_ensure_local_tag "$tmp/work" 26.8.27-1 "$commit_one"
expect_pass "local tag creation is idempotent" spdf_ensure_local_tag "$tmp/work" 26.8.27-1 "$commit_one"
git -C "$tmp/work" push -q origin refs/tags/26.8.27-1
expect_equal "remote tag resolves to prepared commit" \
  "$(spdf_remote_tag_commit "$tmp/work" origin 26.8.27-1)" "$commit_one"
printf 'two\n' >>"$tmp/work/file"
git -C "$tmp/work" commit -qam second
commit_two="$(git -C "$tmp/work" rev-parse HEAD)"
expect_rejected "mismatched local tag fails closed" spdf_ensure_local_tag "$tmp/work" 26.8.27-1 "$commit_two"
expect_rejected "mismatched remote tag fails closed" spdf_require_ref_at_commit \
  "Origin tag 26.8.27-1" "$(spdf_remote_tag_commit "$tmp/work" origin 26.8.27-1)" "$commit_two"

mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_GH_LOG"

read_release_state() {
  IFS=$'\t' read -r state_tag state_draft state_prerelease <"$FAKE_RELEASE_STATE"
}

apply_visibility_flags() {
  for arg in "$@"; do
    case "$arg" in
      --draft) state_draft=true ;;
      --draft=true) state_draft=true ;;
      --draft=false) state_draft=false ;;
      --prerelease=true) state_prerelease=true ;;
      --prerelease=false) state_prerelease=false ;;
    esac
  done
}

if [[ "$1 $2" == "release view" ]]; then
  [[ -f "$FAKE_RELEASE_STATE" ]] || exit 1
  # `gh release view` resolves drafts as well as published releases. Asking
  # for the asset list yields the four-field verification tuple; the metadata
  # form stays three fields.
  if [[ "$*" == *assets* ]]; then
    read_release_state
    asset_count=0
    [[ -f "$FAKE_REMOTE_ASSET" ]] && asset_count=1
    printf '%s\t%s\t%s\t%s\n' "$state_tag" "$state_draft" "$state_prerelease" "$asset_count"
  else
    cat "$FAKE_RELEASE_STATE"
  fi
elif [[ "$1 $2" == "release create" ]]; then
  state_tag="$3"
  state_draft=false
  state_prerelease=false
  apply_visibility_flags "$@"
  printf '%s\t%s\t%s\n' "$state_tag" "$state_draft" "$state_prerelease" >"$FAKE_RELEASE_STATE"
  for arg in "$@"; do [[ "$arg" == *.dmg ]] && cp "$arg" "$FAKE_REMOTE_ASSET"; done
elif [[ "$1 $2" == "release edit" ]]; then
  read_release_state
  apply_visibility_flags "$@"
  printf '%s\t%s\t%s\n' "$state_tag" "$state_draft" "$state_prerelease" >"$FAKE_RELEASE_STATE"
elif [[ "$1 $2" == "release upload" ]]; then
  [[ "${FAKE_GH_FAIL_UPLOAD:-0}" != "1" ]] || exit 42
  for arg in "$@"; do [[ "$arg" == *.dmg ]] && cp "$arg" "$FAKE_REMOTE_ASSET"; done
  if [[ "${FAKE_GH_TAMPER_UPLOAD:-0}" == "1" ]]; then
    printf 'tampered upload bytes\n' >"$FAKE_REMOTE_ASSET"
  fi
elif [[ "$1" == api ]]; then
  read_release_state
  # Real GitHub: "get a release by tag name" never resolves a draft, because a
  # draft carries no server-side tag until it is published. Mirroring that 404
  # keeps the verification path off this endpoint.
  if [[ "$*" == */releases/tags/* && "$state_draft" == true ]]; then
    printf 'gh: Not Found (HTTP 404)\n' >&2
    exit 1
  fi
  asset_count=0
  [[ -f "$FAKE_REMOTE_ASSET" ]] && asset_count=1
  printf '%s\t%s\t%s\t%s\n' "$state_tag" "$state_draft" "$state_prerelease" "$asset_count"
elif [[ "$1 $2" == "release download" ]]; then
  [[ -f "$FAKE_REMOTE_ASSET" ]] || exit 43
  directory=""
  while (($#)); do
    if [[ "$1" == --dir ]]; then directory="$2"; shift 2; else shift; fi
  done
  mkdir -p "$directory"
  cp "$FAKE_REMOTE_ASSET" "$directory/ShenzhenPDF-mac-arm64.dmg"
else
  exit 2
fi
MOCK
chmod +x "$tmp/bin/gh"
export FAKE_GH_LOG="$tmp/gh.log"
export FAKE_RELEASE_STATE="$tmp/release.state"
export FAKE_REMOTE_ASSET="$tmp/remote.dmg"
export FAKE_TAG="26.8.27-1"
notes="$tmp/notes.md"
dmg="$tmp/ShenzhenPDF-mac-arm64.dmg"
printf '%s\n' '- Fixed things' '---' 'Details' >"$notes"
printf 'signed release bytes\n' >"$dmg"

publish_mock() {
  PATH="$tmp/bin:$PATH" spdf_publish_github_release \
    "$SPDF_RELEASE_GITHUB_REPOSITORY" "$FAKE_TAG" "$notes" "$dmg"
}

verify_mock() {
  PATH="$tmp/bin:$PATH" spdf_verify_published_asset \
    "$SPDF_RELEASE_GITHUB_REPOSITORY" "$FAKE_TAG" "$dmg" "$SPDF_RELEASE_ASSET_NAME"
}

expect_pass "first GitHub publication creates and verifies the exact asset" publish_mock
expect_equal "new release is explicitly public and final" "$(cat "$FAKE_RELEASE_STATE")" \
  "$FAKE_TAG"$'\t'"false"$'\t'"false"
assert_before "new release is created as a draft before upload" "$FAKE_GH_LOG" \
  "release create $FAKE_TAG" "release upload $FAKE_TAG"
assert_before "draft upload is downloaded before promotion" "$FAKE_GH_LOG" \
  "release download $FAKE_TAG" "release edit $FAKE_TAG"
expect_equal "new release create is explicitly draft" \
  "$(grep -c '^release create .*--draft ' "$FAKE_GH_LOG" || true)" "1"
expect_equal "draft and public bytes are both verified" \
  "$(grep -c '^release download ' "$FAKE_GH_LOG" || true)" "2"
expect_equal "promotion happens only after draft verification" \
  "$(grep -c '^release edit .*--draft=false --prerelease=false --latest' "$FAKE_GH_LOG" || true)" "1"

printf '' >"$FAKE_GH_LOG"
expect_pass "exact public publication rerun is idempotent" publish_mock
expect_equal "public rerun performs no release mutation" \
  "$(grep -Ec '^release (create|edit|upload) ' "$FAKE_GH_LOG" || true)" "0"

printf 'tampered public bytes\n' >"$FAKE_REMOTE_ASSET"
printf '' >"$FAKE_GH_LOG"
expect_rejected "mismatched public asset fails closed" publish_mock
expect_equal "public mismatch performs no release mutation" \
  "$(grep -Ec '^release (create|edit|upload) ' "$FAKE_GH_LOG" || true)" "0"

printf '%s\tfalse\ttrue\n' "$FAKE_TAG" >"$FAKE_RELEASE_STATE"
printf '' >"$FAKE_GH_LOG"
expect_rejected "public prerelease fails closed" publish_mock
expect_equal "public prerelease performs no release mutation" \
  "$(grep -Ec '^release (create|edit|upload) ' "$FAKE_GH_LOG" || true)" "0"

printf '%s\ttrue\tfalse\n' "$FAKE_TAG" >"$FAKE_RELEASE_STATE"
printf 'stale draft bytes\n' >"$FAKE_REMOTE_ASSET"
printf '' >"$FAKE_GH_LOG"
expect_rejected "verification rejects a draft release" verify_mock
expect_pass "publication rerun recovers and verifies an existing draft" publish_mock
expect_equal "recovered draft becomes public" "$(cat "$FAKE_RELEASE_STATE")" \
  "$FAKE_TAG"$'\t'"false"$'\t'"false"
assert_before "existing draft stays draft while its asset is replaced" "$FAKE_GH_LOG" \
  "release edit $FAKE_TAG" "release upload $FAKE_TAG"
assert_before "recovered draft bytes are downloaded before promotion" "$FAKE_GH_LOG" \
  "release download $FAKE_TAG" "--draft=false --prerelease=false --latest"
expect_equal "existing draft metadata retains draft state" \
  "$(grep -c '^release edit .*--draft=true --prerelease=false' "$FAKE_GH_LOG" || true)" "1"

printf '%s\ttrue\ttrue\n' "$FAKE_TAG" >"$FAKE_RELEASE_STATE"
printf '' >"$FAKE_GH_LOG"
expect_rejected "draft prerelease fails closed" publish_mock
expect_equal "draft prerelease performs no release mutation" \
  "$(grep -Ec '^release (create|edit|upload) ' "$FAKE_GH_LOG" || true)" "0"

rm -f "$FAKE_RELEASE_STATE" "$FAKE_REMOTE_ASSET"
printf '' >"$FAKE_GH_LOG"
export FAKE_GH_FAIL_UPLOAD=1
expect_rejected "upload failure leaves the new release as a draft" publish_mock
unset FAKE_GH_FAIL_UPLOAD
expect_equal "upload failure retains draft state" "$(cat "$FAKE_RELEASE_STATE")" \
  "$FAKE_TAG"$'\t'"true"$'\t'"false"
expect_equal "upload failure never promotes" \
  "$(grep -c '^release edit .*--draft=false' "$FAKE_GH_LOG" || true)" "0"

printf '%s\ttrue\tfalse\n' "$FAKE_TAG" >"$FAKE_RELEASE_STATE"
printf '' >"$FAKE_GH_LOG"
export FAKE_GH_TAMPER_UPLOAD=1
expect_rejected "draft byte-verification failure leaves the release as a draft" publish_mock
unset FAKE_GH_TAMPER_UPLOAD
expect_equal "verification failure retains draft state" "$(cat "$FAKE_RELEASE_STATE")" \
  "$FAKE_TAG"$'\t'"true"$'\t'"false"
expect_equal "verification failure never promotes" \
  "$(grep -c '^release edit .*--draft=false' "$FAKE_GH_LOG" || true)" "0"

printf '%s\tunknown\tfalse\n' "$FAKE_TAG" >"$FAKE_RELEASE_STATE"
expect_rejected "invalid GitHub visibility state fails closed" publish_mock

verifier="$script_dir/verify-mac-artifact.sh"
# The literal snippets are source-order assertions, not shell expressions.
# shellcheck disable=SC2016
assert_before "signed DMG is authenticated before mounting" "$verifier" \
  'codesign --verify --strict --verbose=2 "$dmg"' 'hdiutil attach -readonly'
# shellcheck disable=SC2016
assert_before "app is authenticated before executing its binary" "$verifier" \
  'codesign --verify --deep --strict --verbose=2 "$app"' 'reported="$($binary --version)"'
if grep -Fq 'mktemp -u' "$portable_dir/mac/make-installer-dmg.sh"; then
  fail "installer avoids mktemp -u"
else
  pass "installer avoids mktemp -u"
fi
if grep -Fq 'hdiutil detach -force' "$verifier" && \
   grep -Fq 'hdiutil detach -force' "$portable_dir/mac/make-installer-dmg.sh"; then
  pass "DMG cleanup has forced-detach fallback"
else
  fail "DMG cleanup has forced-detach fallback"
fi

printf 'release-workflow-tests: %d passed, %d failed\n' "$passed" "$failures"
((failures == 0))
