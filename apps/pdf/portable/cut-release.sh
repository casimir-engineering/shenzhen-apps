#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Prepare, validate, or explicitly publish a direct-GitHub Shenzhen PDF release.

Usage:
  ./portable/cut-release.sh [--version YY.M.DD] [--build N] --prepare-only ["summary"]
  ./portable/cut-release.sh [--version YY.M.DD] [--build N] --dry-run
  ./portable/cut-release.sh [--version YY.M.DD] [--build N] --publish

Options:
  --version VERSION  Date version. Preparation defaults to today's unpadded
                     YY.M.DD; publication defaults to committed metadata.
  --build BUILD      Positive build number. Preparation defaults to the highest
                     matching local or origin tag (in the Shenzhen repository
                     also the release repository's) plus one; publication
                     defaults to committed metadata.
  --prepare-only     Test, update, and commit release metadata. Never builds,
                     signs, tags, pushes, notarizes, or publishes.
  --dry-run          Validate notes and run release tests without modifying state.
  --publish          Explicitly publish already-committed metadata from master.
                     Exact existing tags/releases/assets are accepted and
                     repaired; mismatched state fails closed.

Release notes live in portable/docs/releases/<VERSION>-<BUILD>.md and are
tracked. Highlights are markdown bullets above one standalone `---`; detailed
notes below it must be non-empty. The in-app highlights limit is 500 characters.

The normal go/no-go flow is: prepare on a release branch, validate the commit,
merge it to master, then invoke --publish. Publication performs a clean signed,
notarized, stapled build before atomically pushing master and its tag.
USAGE
}

log() { printf '==> %s\n' "$*"; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck disable=SC1091
source "$script_dir/release/release-common.sh"
cd "$repo_root"
spdf_release_layout "$repo_root"

requested_version=""
requested_build=""
summary=""
mode=""

set_mode() {
  local requested="$1"
  [[ -z "$mode" ]] || spdf_release_fail "Choose exactly one of --prepare-only, --dry-run, or --publish"
  mode="$requested"
}

while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --version)
      (($# >= 2)) || spdf_release_fail "--version requires a value"
      requested_version="$2"
      shift 2
      ;;
    --build)
      (($# >= 2)) || spdf_release_fail "--build requires a value"
      requested_build="$2"
      shift 2
      ;;
    --prepare-only) set_mode prepare; shift ;;
    --dry-run) set_mode dry-run; shift ;;
    --publish) set_mode publish; shift ;;
    --*) spdf_release_fail "Unknown option: $1" ;;
    *)
      [[ -z "$summary" ]] || spdf_release_fail "Only one release summary is accepted"
      summary="$1"
      shift
      ;;
  esac
done

[[ -n "$mode" ]] || spdf_release_fail "Choose --prepare-only, --dry-run, or --publish explicitly"
if [[ "$mode" == publish && -n "$summary" ]]; then
  spdf_release_fail "Release summaries belong to --prepare-only; --publish consumes committed metadata"
fi

run_release_tests() {
  local targets=()
  local target
  while IFS= read -r target; do
    [[ -n "$target" ]] && targets+=("$target")
  done < <(spdf_discover_test_targets "$script_dir/Makefile")
  ((${#targets[@]} > 0)) || spdf_release_fail "No *-tests targets found"
  # Compile every test binary across all cores first. The suites then run one
  # at a time, in discovery order, off binaries that are already built, so the
  # sweep spends its wall clock on tests rather than on serial clang calls and
  # the release log stays readable.
  local jobs
  jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  # In the Shenzhen repository each suite that passes is recorded for the commit (tools/test-stamp.sh), and one that
  # passed on this commit already is not run again; the first failure stops the sweep, as before.
  local stamp="$repo_root/../../tools/test-stamp.sh"
  if [[ -x "$stamp" ]]; then
    local missing=()
    for target in "${targets[@]}"; do
      "$stamp" check "pdf/$target" || missing+=("$target")
    done
    if ((${#missing[@]} == 0)); then
      log "All ${#targets[@]} release suites passed on this commit already"
      return 0
    fi
    log "Building test binaries with -j$jobs"
    make -C "$script_dir" -j"$jobs" test-binaries
    log "Running release tests not yet passed on this commit: ${missing[*]}"
    for target in "${missing[@]}"; do
      "$stamp" run "pdf/$target" -- make -C "$script_dir" "$target"
    done
    return 0
  fi
  log "Building test binaries with -j$jobs"
  make -C "$script_dir" -j"$jobs" test-binaries
  log "Running release tests: ${targets[*]}"
  make -C "$script_dir" "${targets[@]}"
}

require_publish_credentials() {
  gh auth status -h github.com >/dev/null 2>&1 || spdf_release_fail "gh is not authenticated for github.com"
  if [[ -f "$script_dir/.release.env" ]]; then
    # shellcheck disable=SC1090,SC1091
    source "$script_dir/.release.env"
  fi
  [[ "${MAC_SIGN_IDENTITY:-}" == "Developer ID Application:"* ]] || \
    spdf_release_fail "MAC_SIGN_IDENTITY must be a Developer ID Application identity"
  [[ -n "${NOTARY_PROFILE:-}" ]] || spdf_release_fail "NOTARY_PROFILE is required"
  security find-identity -v -p codesigning | grep -qF "$MAC_SIGN_IDENTITY" || \
    spdf_release_fail "Developer ID identity is unavailable"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null || \
    spdf_release_fail "Notary profile is unavailable"
  export MAC_SIGN_IDENTITY NOTARY_PROFILE
}

if [[ "$mode" == publish ]]; then
  branch="$(git symbolic-ref --quiet --short HEAD || true)"
  [[ "$branch" == "$SPDF_RELEASE_BRANCH" ]] || \
    spdf_release_fail "Publishing must run on $SPDF_RELEASE_BRANCH (currently ${branch:-detached})"
  [[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] || \
    spdf_release_fail "Publishing requires a clean worktree"

  spdf_load_committed_release_metadata "$repo_root"
  version="$SPDF_RELEASE_VERSION"
  build="$SPDF_RELEASE_BUILD"
  tag="$SPDF_RELEASE_TAG"
  git_tag="$SPDF_TAG_PREFIX$tag"
  notes_file="$SPDF_RELEASE_NOTES"
  [[ -z "$requested_version" || "$requested_version" == "$version" ]] || \
    spdf_release_fail "Requested version $requested_version != committed version $version"
  [[ -z "$requested_build" || "$requested_build" == "$build" ]] || \
    spdf_release_fail "Requested build $requested_build != committed build $build"

  head_commit="$(git rev-parse HEAD)"
  local_tag_commit="$(spdf_commit_for_ref "$repo_root" "refs/tags/$git_tag" || true)"
  remote_tag_commit="$(spdf_remote_tag_commit "$repo_root" origin "$git_tag")"
  spdf_require_ref_at_commit "Local tag $git_tag" "$local_tag_commit" "$head_commit"
  spdf_require_ref_at_commit "Origin tag $git_tag" "$remote_tag_commit" "$head_commit"

  run_release_tests
  require_publish_credentials
  "$script_dir/build-mac-release.sh"
  [[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] || \
    spdf_release_fail "Release build changed the worktree"

  spdf_ensure_local_tag "$repo_root" "$git_tag" "$head_commit"
  remote_tag_commit="$(spdf_remote_tag_commit "$repo_root" origin "$git_tag")"
  spdf_require_ref_at_commit "Origin tag $git_tag" "$remote_tag_commit" "$head_commit"
  if [[ -z "$remote_tag_commit" ]]; then
    log "Atomically publishing $SPDF_RELEASE_BRANCH and $git_tag"
    git push --atomic origin "HEAD:refs/heads/$SPDF_RELEASE_BRANCH" "refs/tags/$git_tag:refs/tags/$git_tag"
  else
    log "Origin already has the exact $git_tag; publishing $SPDF_RELEASE_BRANCH idempotently"
    git push origin "HEAD:refs/heads/$SPDF_RELEASE_BRANCH"
  fi
  remote_tag_commit="$(spdf_remote_tag_commit "$repo_root" origin "$git_tag")"
  [[ "$remote_tag_commit" == "$head_commit" ]] || \
    spdf_release_fail "Origin tag $git_tag was not published at $head_commit"

  dmg="$repo_root/dist/$SPDF_RELEASE_ASSET_NAME"
  spdf_publish_github_release "$SPDF_RELEASE_GITHUB_REPOSITORY" "$tag" "$notes_file" "$dmg"
  log "Published and byte-verified $tag"
  exit 0
fi

version="$requested_version"
if [[ -z "$version" ]]; then
  version="$((10#$(date +%y))).$((10#$(date +%m))).$((10#$(date +%d)))"
fi
spdf_validate_release_version "$version"

remote_tags="$(git ls-remote --tags --refs origin "refs/tags/${SPDF_TAG_PREFIX}${version}-*" |
  awk -v prefix="refs/tags/$SPDF_TAG_PREFIX" '{sub(prefix, "", $2); print $2}')"
local_tags="$(git tag --list "${SPDF_TAG_PREFIX}${version}-*" | sed "s|^$SPDF_TAG_PREFIX||")"
release_repo_tags=""
if [[ -n "$SPDF_TAG_PREFIX" ]]; then
  release_repo_tags="$(spdf_release_repository_tags "$version")"
fi
all_tags="$(printf '%s\n%s\n%s\n' "$local_tags" "$remote_tags" "$release_repo_tags" | sed '/^$/d' | sort -u)"
build="$requested_build"
if [[ -z "$build" ]]; then
  build="$(spdf_next_build_for_tags "$version" "$all_tags")"
fi
[[ "$build" =~ ^[1-9][0-9]*$ ]] || spdf_release_fail "Build must be a positive integer: $build"

tag="${version}-${build}"
notes_file="$script_dir/docs/releases/${tag}.md"
if printf '%s\n' "$all_tags" | grep -qxF "$tag"; then
  spdf_release_fail "Release tag already exists locally, on origin or on $SPDF_RELEASE_GITHUB_REPOSITORY: $tag"
fi

branch="$(git symbolic-ref --quiet --short HEAD || true)"
[[ -n "$branch" ]] || spdf_release_fail "Release preparation requires a named branch"
status="$(git status --porcelain=v1 --untracked-files=all)"
unexpected="$(printf '%s\n' "$status" | awk -v allowed="portable/docs/releases/${tag}.md" '
  NF && substr($0, 4) != allowed { print }
')"
[[ -z "$unexpected" ]] || {
  printf '%s\n' "$unexpected" >&2
  spdf_release_fail "Working tree has changes outside the release notes for $tag"
}

next_notes="$script_dir/docs/release-notes-next.md"
if [[ ! -f "$notes_file" ]]; then
  [[ "$mode" != dry-run ]] || spdf_release_fail "Missing tracked release notes: $notes_file"
  mkdir -p "$(dirname "$notes_file")"
  apply_body="$(sed -n '/^## Next release$/,$p' "$next_notes" | tail -n +2)"
  {
    printf '%s\n' '- REPLACE: concise user-visible highlight'
    printf '\n---\n\n%s\n' "$apply_body"
  } > "$notes_file"
  spdf_release_fail "Seeded $notes_file; edit it, then rerun this command"
fi

# Re-preparing an existing (never-tagged) release must not silently discard
# notes accumulated since the last attempt: preparation resets
# release-notes-next.md, so anything written there after the notes file was
# created would vanish unnoticed. Fail closed and name the entries instead.
pending_notes="$(sed -n '/^## Next release$/,$p' "$next_notes" | tail -n +2 | sed '/^[[:space:]]*$/d')"
if [[ -n "$pending_notes" && "$pending_notes" != "Nothing yet." ]]; then
  printf '%s\n' "$pending_notes" >&2
  spdf_release_fail "release-notes-next.md has entries not in $notes_file; fold them in (or clear them), then rerun"
fi
spdf_validate_release_notes "$notes_file"
git check-ignore -q "$notes_file" && spdf_release_fail "Release notes are ignored: $notes_file"
log "Validated release notes for $tag"
run_release_tests

if [[ "$mode" == dry-run ]]; then
  log "Dry run complete for $tag; no files, refs, remotes, or releases were changed"
  exit 0
fi

if [[ -z "$summary" ]]; then
  read -r -p "Release summary: " summary
fi
[[ -n "$summary" ]] || spdf_release_fail "A release summary is required"

# Release checklist: README content must be current for this release (the
# version badge below is automated; the feature sections are not).
previous_tag="$(git describe --tags --abbrev=0 ${SPDF_TAG_PREFIX:+--match "${SPDF_TAG_PREFIX}*"} 2>/dev/null || true)"
spdf_require_fresh_readme "$repo_root" "$previous_tag"

log "Committing release metadata for $tag"
sed -i '' -E "s/^MAC_VERSION \?= .*/MAC_VERSION ?= ${version}/" "$script_dir/Makefile"
sed -i '' -E "s/^MAC_BUILD \?= .*/MAC_BUILD ?= ${build}/" "$script_dir/Makefile"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version}" "$script_dir/mac/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${build}" "$script_dir/mac/Info.plist"
sed -i '' -E "s/if \(version\.length == 0\) version = @\"[^\"]*\";/if (version.length == 0) version = @\"${version}\";/" "$script_dir/mac/ShenzhenPDFMac.mm"
sed -i '' -E "s/if \(build\.length == 0\) build = @\"[^\"]*\";/if (build.length == 0) build = @\"${build}\";/" "$script_dir/mac/ShenzhenPDFMac.mm"
sed -i '' -E "s|<sub>Latest <b>[^<]*</b>|<sub>Latest <b>${tag}</b>|" "$repo_root/readme.md"
sed -i '' -E "s/^#define SPDF_APP_VERSION \".*\"/#define SPDF_APP_VERSION \"${version}\"/" "$script_dir/linux/gtk4/spdf_app.h"
sed -i '' -E "s/^#define SPDF_APP_BUILD \".*\"/#define SPDF_APP_BUILD \"${build}\"/" "$script_dir/linux/gtk4/spdf_app.h"

cat > "$next_notes" <<EOF
# Release notes

User-facing notes for changes merged since the last release (${version} build ${build}).

Release notes are tracked in \`portable/docs/releases/\`. Prepare the next release
with \`./portable/cut-release.sh --prepare-only ["summary"]\`; publish the
validated metadata from master with \`./portable/cut-release.sh --publish\`.

## Next release

Nothing yet.
EOF

git add -- "$script_dir/Makefile" "$script_dir/mac/Info.plist" \
  "$script_dir/mac/ShenzhenPDFMac.mm" "$script_dir/linux/gtk4/spdf_app.h" \
  "$repo_root/readme.md" "$next_notes" "$notes_file"
git diff --check --cached
git commit -m "Release ${version} (build ${build}): ${summary}"
[[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] || \
  spdf_release_fail "Release metadata commit did not leave a clean tree"
spdf_load_committed_release_metadata "$repo_root"
[[ "$SPDF_RELEASE_TAG" == "$tag" ]] || spdf_release_fail "Committed metadata resolved to $SPDF_RELEASE_TAG"
log "Prepared $tag on $branch. Stopped before build, tag, push, notarization, or publication."
