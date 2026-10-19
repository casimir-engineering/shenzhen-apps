#!/usr/bin/env bash

# Public constants consumed by scripts that source this library.
# shellcheck disable=SC2034
SPDF_RELEASE_TEAM_ID="66LJ4BV7Q3"
# shellcheck disable=SC2034
SPDF_RELEASE_BUNDLE_ID="com.intuition.shenzhenpdf"
# shellcheck disable=SC2034
SPDF_RELEASE_ARCH="arm64"
# shellcheck disable=SC2034
SPDF_RELEASE_MIN_OS="12.0"
# shellcheck disable=SC2034
SPDF_RELEASE_OPTFLAGS="-O2 -DNDEBUG"
# shellcheck disable=SC2034
SPDF_RELEASE_GITHUB_REPOSITORY="casimir-engineering/shenzhen-pdf"
SPDF_RELEASE_ASSET_NAME="ShenzhenPDF-mac-arm64.dmg"

# Sets SPDF_TAG_PREFIX and SPDF_RELEASE_BRANCH for the checkout at $1. In the standalone repository they are empty
# and master. In the Shenzhen repository, where this app is apps/pdf beside the other apps, its git tags read
# pdf/<version>-<build> and its branch is main. The GitHub release on SPDF_RELEASE_GITHUB_REPOSITORY keeps the plain
# <version>-<build> either way: that is the name installed apps compare.
spdf_release_layout() {
  local prefix
  prefix="$(git -C "$1" rev-parse --show-prefix)"
  if [[ -z "$prefix" ]]; then
    SPDF_TAG_PREFIX="" SPDF_RELEASE_BRANCH=master
  else
    SPDF_TAG_PREFIX="pdf/" SPDF_RELEASE_BRANCH=main
  fi
}

spdf_release_fail() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

# Release checklist: the README's CONTENT (not just the auto-bumped version
# badge) must have been revisited since the previous release, so a headline
# feature can never ship undocumented. A release that genuinely changes no
# user-visible README content passes SPDF_README_UNCHANGED=1 explicitly.
spdf_require_fresh_readme() {
  local repo_root="$1"
  local previous_tag="$2"
  [[ "${SPDF_README_UNCHANGED:-0}" == "1" ]] && return 0
  [[ -n "$previous_tag" ]] || return 0  # first release ever: nothing to diff
  git -C "$repo_root" rev-parse -q --verify "refs/tags/$previous_tag" >/dev/null || return 0
  # Consume the whole diff rather than ending the pipe in `grep -q`: with
  # pipefail, -q exits at its first hit and the upstream greps die of SIGPIPE
  # (141), so a README that changed a LOT -- the very case this gate exists to
  # wave through -- read as unchanged. A rewrite of 94 lines was rejected as
  # "only the version badge moved".
  local content_changes
  content_changes="$(git -C "$repo_root" diff "$previous_tag"..HEAD -- readme.md \
      | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -vF 'Latest <b>' || true)"
  [[ -n "$content_changes" ]] && return 0
  spdf_release_fail "README checklist: readme.md content is unchanged since $previous_tag (only the version badge moved). Update the README for this release, or set SPDF_README_UNCHANGED=1 to state that nothing user-visible changed."
}

spdf_read_make_var() {
  local file="$1"
  local name="$2"
  awk -v key="$name" '$1 == key && $2 == "?=" { print $3; exit }' "$file"
}

spdf_discover_test_targets() {
  local makefile="$1"
  sed -nE 's/^([A-Za-z0-9_-]+-tests):.*/\1/p' "$makefile" | sort -u
}

spdf_commit_for_ref() {
  local repo_root="$1"
  local ref="$2"
  git -C "$repo_root" rev-parse --verify "${ref}^{commit}" 2>/dev/null
}

spdf_remote_tag_commit() {
  local repo_root="$1"
  local remote="$2"
  local tag="$3"
  local refs peeled direct

  refs="$(git -C "$repo_root" ls-remote --tags "$remote" "refs/tags/$tag" "refs/tags/$tag^{}")"
  peeled="$(printf '%s\n' "$refs" | awk -v ref="refs/tags/$tag^{}" '$2 == ref { print $1; exit }')"
  direct="$(printf '%s\n' "$refs" | awk -v ref="refs/tags/$tag" '$2 == ref { print $1; exit }')"
  printf '%s\n' "${peeled:-$direct}"
}

spdf_require_ref_at_commit() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  [[ -z "$actual" || "$actual" == "$expected" ]] || \
    spdf_release_fail "$label points to $actual instead of prepared commit $expected"
}

spdf_ensure_local_tag() {
  local repo_root="$1"
  local tag="$2"
  local commit="$3"
  local existing

  existing="$(spdf_commit_for_ref "$repo_root" "refs/tags/$tag" || true)"
  spdf_require_ref_at_commit "Local tag $tag" "$existing" "$commit" || return 1
  if [[ -z "$existing" ]]; then
    git -C "$repo_root" tag "$tag" "$commit"
  fi
}

spdf_verify_release_asset() {
  local repository="$1"
  local tag="$2"
  local dmg="$3"
  local expected_name="$4"
  local expected_draft="$5"
  local tmp remote_dmg expected_hash actual_hash metadata

  # `gh release view` resolves drafts, which the REST "release by tag name"
  # endpoint never returns: GitHub only associates a draft with its tag once
  # the release is published, so verifying a staged draft through that
  # endpoint always 404s.
  metadata="$(gh release view "$tag" -R "$repository" \
    --json tagName,isDraft,isPrerelease,assets \
    --jq '[.tagName, .isDraft, .isPrerelease, ([.assets[] | select(.name == "'"$expected_name"'")] | length)] | @tsv')"
  [[ "$metadata" == "$tag"$'\t'"$expected_draft"$'\t'"false"$'\t'"1" ]] || \
    spdf_release_fail "GitHub release $tag is not in the expected draft=$expected_draft, prerelease=false state with exactly one $expected_name asset" || return 1

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/spdf-release-asset.XXXXXX")"
  remote_dmg="$tmp/$expected_name"
  if ! gh release download "$tag" -R "$repository" --pattern "$expected_name" --dir "$tmp" --clobber; then
    rm -rf "$tmp"
    return 1
  fi
  [[ -f "$remote_dmg" ]] || {
    rm -rf "$tmp"
    spdf_release_fail "GitHub release download did not produce $expected_name"
    return 1
  }
  expected_hash="$(shasum -a 256 "$dmg" | awk '{print $1}')"
  actual_hash="$(shasum -a 256 "$remote_dmg" | awk '{print $1}')"
  rm -rf "$tmp"
  [[ "$actual_hash" == "$expected_hash" ]] || \
    spdf_release_fail "GitHub $expected_name hash $actual_hash != local release hash $expected_hash"
}

spdf_verify_draft_asset() {
  spdf_verify_release_asset "$1" "$2" "$3" "$4" true
}

spdf_verify_published_asset() {
  spdf_verify_release_asset "$1" "$2" "$3" "$4" false
}

spdf_publish_github_release() {
  local repository="$1"
  local tag="$2"
  local notes="$3"
  local dmg="$4"
  local existing_state existing_tag existing_draft existing_prerelease

  existing_state="$(gh release view "$tag" -R "$repository" \
    --json tagName,isDraft,isPrerelease \
    --jq '[.tagName, .isDraft, .isPrerelease] | @tsv' 2>/dev/null || true)"
  if [[ -n "$existing_state" ]]; then
    IFS=$'\t' read -r existing_tag existing_draft existing_prerelease <<<"$existing_state"
    [[ "$existing_tag" == "$tag" ]] || \
      spdf_release_fail "GitHub returned release $existing_tag while publishing $tag" || return 1
    [[ "$existing_draft" == "true" || "$existing_draft" == "false" ]] || \
      spdf_release_fail "GitHub returned an invalid draft state for $tag" || return 1
    [[ "$existing_prerelease" == "true" || "$existing_prerelease" == "false" ]] || \
      spdf_release_fail "GitHub returned an invalid prerelease state for $tag" || return 1
    [[ "$existing_prerelease" == "false" ]] || \
      spdf_release_fail "GitHub release $tag is unexpectedly a prerelease" || return 1

    if [[ "$existing_draft" == "false" ]]; then
      # Public releases are immutable here. An exact prior publication is an
      # idempotent success; mismatched bytes fail before any replacement work.
      spdf_verify_published_asset "$repository" "$tag" "$dmg" "$SPDF_RELEASE_ASSET_NAME"
      return
    fi

    # Refresh recoverable draft metadata while explicitly retaining draft state.
    gh release edit "$tag" -R "$repository" --title "$tag" --notes-file "$notes" \
      --draft=true --prerelease=false
  else
    gh release create "$tag" -R "$repository" --title "$tag" --notes-file "$notes" \
      --draft --prerelease=false
  fi

  gh release upload "$tag" -R "$repository" "$dmg" --clobber
  spdf_verify_draft_asset "$repository" "$tag" "$dmg" "$SPDF_RELEASE_ASSET_NAME" || return 1

  gh release edit "$tag" -R "$repository" --title "$tag" --notes-file "$notes" \
    --draft=false --prerelease=false --latest
  spdf_verify_published_asset "$repository" "$tag" "$dmg" "$SPDF_RELEASE_ASSET_NAME"
}

spdf_validate_release_version() {
  local version="$1"
  [[ "$version" =~ ^[0-9]{2}\.[1-9][0-9]*\.[1-9][0-9]*$ ]] || \
    spdf_release_fail "Version must be an unpadded YY.M.DD value: $version"
}

# The <version>-<build> tags of the GitHub releases on SPDF_RELEASE_GITHUB_REPOSITORY for one version. The Shenzhen
# repository starts from one commit without the earlier releases' tags: those are only on the release repository, so
# the next build number has to count them too.
spdf_release_repository_tags() {
  local version="$1"
  git ls-remote --tags --refs "https://github.com/$SPDF_RELEASE_GITHUB_REPOSITORY.git" "refs/tags/${version}-*" |
    awk '{ sub("^refs/tags/", "", $2); print $2 }'
}

spdf_next_build_for_tags() {
  local version="$1"
  local tags="$2"
  local escaped highest
  escaped="${version//./\\.}"
  highest="$(printf '%s\n' "$tags" | sed -nE "s/^${escaped}-([0-9]+)$/\\1/p" | sort -n | tail -1)"
  printf '%s\n' "$(( ${highest:-0} + 1 ))"
}

spdf_validate_release_notes() {
  local notes="$1"
  local divider_count highlights details chars

  [[ -f "$notes" ]] || spdf_release_fail "Release notes are missing: $notes" || return 1
  divider_count="$(grep -c '^---$' "$notes" || true)"
  [[ "$divider_count" == "1" ]] || spdf_release_fail "Release notes must contain exactly one standalone --- divider." || return 1

  highlights="$(sed '/^---$/q' "$notes" | sed '$d')"
  details="$(sed '1,/^---$/d' "$notes")"
  [[ -n "$(printf '%s' "$highlights" | tr -d '[:space:]')" ]] || spdf_release_fail "Release-note highlights are empty." || return 1
  [[ -n "$(printf '%s' "$details" | tr -d '[:space:]')" ]] || spdf_release_fail "Detailed release notes are empty." || return 1
  if printf '%s\n%s\n' "$highlights" "$details" | grep -Eiq 'EDIT ME|Nothing yet|(^|[^A-Za-z])(TBD|TODO)([^A-Za-z]|$)'; then
    spdf_release_fail "Release notes still contain a placeholder."
    return 1
  fi
  if ! printf '%s\n' "$highlights" | awk 'NF && $0 !~ /^- / { exit 1 }'; then
    spdf_release_fail "Every non-empty highlight line must start with '- '."
    return 1
  fi

  chars="$(printf '%s' "$highlights" | wc -m | tr -d ' ')"
  (( chars <= 500 )) || spdf_release_fail "Release-note highlights are ${chars} characters; the updater limit is 500." || return 1
  printf 'Release notes: %s highlight characters, strict format OK.\n' "$chars"
}

spdf_load_committed_release_metadata() {
  local repo_root="$1"
  local makefile="$repo_root/portable/Makefile"
  local plist="$repo_root/portable/mac/Info.plist"
  local mac_source="$repo_root/portable/mac/ShenzhenPDFMac.mm"
  local linux_header="$repo_root/portable/linux/gtk4/spdf_app.h"
  local readme="$repo_root/readme.md"
  local next_notes="$repo_root/portable/docs/release-notes-next.md"
  local plist_version plist_build

  SPDF_RELEASE_VERSION="$(spdf_read_make_var "$makefile" MAC_VERSION)"
  SPDF_RELEASE_BUILD="$(spdf_read_make_var "$makefile" MAC_BUILD)"
  spdf_validate_release_version "$SPDF_RELEASE_VERSION" || return 1
  [[ "$SPDF_RELEASE_BUILD" =~ ^[1-9][0-9]*$ ]] || spdf_release_fail "Invalid MAC_BUILD: $SPDF_RELEASE_BUILD" || return 1
  SPDF_RELEASE_TAG="$SPDF_RELEASE_VERSION-$SPDF_RELEASE_BUILD"
  SPDF_RELEASE_NOTES="$repo_root/portable/docs/releases/$SPDF_RELEASE_TAG.md"
  git -C "$repo_root" ls-files --error-unmatch -- "portable/docs/releases/$SPDF_RELEASE_TAG.md" >/dev/null 2>&1 || spdf_release_fail "Release notes are not tracked: $SPDF_RELEASE_NOTES" || return 1

  plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
  plist_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
  [[ "$plist_version" == "$SPDF_RELEASE_VERSION" ]] || spdf_release_fail "Info.plist version $plist_version != $SPDF_RELEASE_VERSION" || return 1
  [[ "$plist_build" == "$SPDF_RELEASE_BUILD" ]] || spdf_release_fail "Info.plist build $plist_build != $SPDF_RELEASE_BUILD" || return 1
  grep -Fq "if (version.length == 0) version = @\"$SPDF_RELEASE_VERSION\";" "$mac_source" || spdf_release_fail "Mac display-version fallback is stale." || return 1
  grep -Fq "if (build.length == 0) build = @\"$SPDF_RELEASE_BUILD\";" "$mac_source" || spdf_release_fail "Mac display-build fallback is stale." || return 1
  grep -Fq "#define SPDF_APP_VERSION \"$SPDF_RELEASE_VERSION\"" "$linux_header" || spdf_release_fail "Linux release version is stale." || return 1
  grep -Fq "#define SPDF_APP_BUILD \"$SPDF_RELEASE_BUILD\"" "$linux_header" || spdf_release_fail "Linux release build is stale." || return 1
  grep -Fq "<sub>Latest <b>$SPDF_RELEASE_TAG</b>" "$readme" || spdf_release_fail "README release badge is stale." || return 1
  grep -Fq "since the last release ($SPDF_RELEASE_VERSION build $SPDF_RELEASE_BUILD)" "$next_notes" || spdf_release_fail "release-notes-next.md header is stale." || return 1
  spdf_validate_release_notes "$SPDF_RELEASE_NOTES" || return 1

  export SPDF_RELEASE_VERSION SPDF_RELEASE_BUILD SPDF_RELEASE_TAG SPDF_RELEASE_NOTES
}
