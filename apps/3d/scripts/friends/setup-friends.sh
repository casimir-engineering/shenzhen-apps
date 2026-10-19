#!/usr/bin/env bash
#
# setup-friends.sh — fetch and build the pinned Shenzhen Friends components for Shenzhen 3D.
#
# Shenzhen Friends lives in shenzhen-pdf. This repository pins one commit of it in friends.lock rather than a
# submodule, which would pull all of shenzhen-pdf (MuPDF, ext/, the website) into a web and Electron app
# (docs/FRIENDS.md § Pinning). Every step is skipped when it is already done, so running it again is safe and cheap.
#
#   1. source    friends-src/ = shenzhen-pdf at friends.lock's commit: a shallow fetch of exactly that commit,
#                checked out detached. With SZF_FRIENDS_ROOT set, that checkout is used instead.
#                Either way the checkout must be detached at the pinned commit with no local changes, and the
#                lock's helper_build_number must be the one that commit's own build gives its helper.
#   2. build     make -C <checkout>/portable friends-helper-bundle friends-client, with the helper's version keys
#                from friends.lock (friends-client is the fake helper the renderer tests may use), then the
#                Electron main process's client addon from the same checkout's client library
#                (electron/friends/build-native.mjs).
#   3. verify    the built helper's identifier and version keys, the animal set, the acknowledgements, the addon,
#                and that tests/fixtures/friends/ is the pinned commit's fixtures.
#
# Never deletes, moves or resets an existing checkout. One at another commit, or with local changes, stops the
# script; remove friends-src/ to fetch the pinned commit again.
#
# In the Shenzhen repository (this tree at apps/3d, ShenzhenPDF at apps/pdf) step 1 is skipped: Friends is built
# from apps/pdf as it is in the tree, with the helper's version keys from apps/pdf/portable/Makefile, and
# friends.lock is not read (friends-lock.sh, "Two modes"); the fixtures are compared with apps/pdf's and
# --sync-fixtures copies them from there. SZF_FRIENDS_MODE=pinned builds the pin instead.
#
# Usage: scripts/friends/setup-friends.sh [--check | --sync-fixtures]
#   --check          verify the checkout and what was built; change nothing (packaging runs this)
#   --sync-fixtures  copy the pinned commit's PROTOCOL fixtures into tests/fixtures/friends/ (after moving the pin)
#
# Environment:
#   SZF_FRIENDS_ROOT  an existing shenzhen-pdf checkout to build in instead of friends-src/. Never a working copy
#                     on a branch: it moves as people commit, its work in progress would end up in the app, and
#                     the build would write into their tree. Make a dedicated one with
#                       git -C <shenzhen-pdf> worktree add --detach <dir> <commit from friends.lock>
#   SZF_FRIENDS_URL   fetch from here instead of friends.lock's url (a local mirror or clone)
#   SZF_FRIENDS_MODE  tree or pinned; see friends-lock.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=friends-lock.sh
. "$script_dir/friends-lock.sh"

mode=all
for arg in "$@"; do
  case "$arg" in
    --check) mode=check ;;
    --sync-fixtures) mode=sync ;;
    -h|--help) sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

friends_lock_read "$repo_root" || exit 1
# The addon build below reads the lock in Node; it must decide the same way.
export SZF_FRIENDS_MODE="$FRIENDS_MODE"
short="${FRIENDS_COMMIT:0:9}"
# What the messages call the Friends source: apps/pdf here, the pinned commit of shenzhen-pdf elsewhere.
source_name="shenzhen-pdf $short"
if [[ "$FRIENDS_MODE" == tree ]]; then
  source_name="apps/pdf"
  where="apps/pdf ($FRIENDS_ROOT)"
elif [[ -n "${SZF_FRIENDS_ROOT:-}" ]]; then
  where="SZF_FRIENDS_ROOT ($FRIENDS_ROOT)"
else
  where="friends-src/"
fi
fixtures_dir="$repo_root/tests/fixtures/friends"
# The fixture files the renderer tests read: every view's snapshots, the frames around them and the replies.
fixture_parts=(snapshots frames replies intents.jsonl)

# Prints nothing and returns 0 when $1 is a checkout this script may build from; otherwise prints why not.
source_problems() {
  local root="$1" top head branch changes
  top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || { echo "it is not a git checkout"; return 1; }
  if [[ "$(cd "$top" && pwd -P)" != "$(cd "$root" && pwd -P)" ]]; then
    echo "it is inside the checkout $top, not the top of one"
    return 1
  fi
  head="$(git -C "$root" rev-parse HEAD)"
  if [[ "$head" != "$FRIENDS_COMMIT" ]]; then
    echo "it is at $head, but friends.lock pins $FRIENDS_COMMIT"
    return 1
  fi
  if branch="$(git -C "$root" symbolic-ref -q --short HEAD)"; then
    echo "it has the branch $branch checked out, so it looks like a working copy in use;" \
         "build from a detached checkout instead: git -C '$root' worktree add --detach <dir> $FRIENDS_COMMIT"
    return 1
  fi
  # Untracked files count: the Friends makefiles compile sources by wildcard, so a stray file changes the helper.
  # The build directory is ignored by shenzhen-pdf's own .gitignore, so building here does not trip this.
  changes="$(git -C "$root" status --porcelain=v1 --untracked-files=normal)"
  if [[ -n "$changes" ]]; then
    echo "it has local changes, so the helper would not be the pinned code:"
    printf '%s\n' "$changes" | head -n 10 | sed 's/^/    /'
    return 1
  fi
}

# The lock's number must be the one the pinned commit's own build stamps on its helper: helper.mk's formula over
# the MAC_VERSION and MAC_BUILD defaults in its portable/Makefile.
check_pinned_build_number() {
  local makefile="$FRIENDS_ROOT/portable/Makefile" number version build
  [[ -f "$makefile" ]] || die "$where has no portable/Makefile; is it a shenzhen-pdf checkout?"
  version="$(awk '$1 == "MAC_VERSION" && $2 == "?=" { print $3; exit }' "$makefile")"
  build="$(awk '$1 == "MAC_BUILD" && $2 == "?=" { print $3; exit }' "$makefile")"
  [[ -n "$version" && -n "$build" ]] || die "cannot read MAC_VERSION and MAC_BUILD from $makefile"
  number="$(echo "$version $build" |
    awk '{ split($1, v, "."); printf "%02d%02d%02d%02d", v[1] % 100, v[2], v[3], $2 }')"
  if [[ "$number" != "$FRIENDS_BUILD_NUMBER" ]]; then
    die "friends.lock: helper_build_number is $FRIENDS_BUILD_NUMBER, but shenzhen-pdf $short builds its helper as" \
        "$number (MAC_VERSION $version, MAC_BUILD $build in portable/Makefile). Use that number, so the running" \
        "helper can tell which Friends code is newer."
  fi
}

# Prints nothing when the built helper carries the identifier and version keys friends.lock asks for.
helper_problems() {
  local plist="$FRIENDS_HELPER_BUILT/Contents/Info.plist" key want got
  if [[ ! -x "$FRIENDS_HELPER_BUILT/Contents/MacOS/$FRIENDS_HELPER_NAME" ]]; then
    echo "no helper bundle at $FRIENDS_HELPER_BUILT"
    return
  fi
  for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion SZFriendsBuildNumber; do
    case "$key" in
      CFBundleIdentifier) want="$FRIENDS_HELPER_ID" ;;
      CFBundleShortVersionString) want="$FRIENDS_SHORT_VERSION" ;;
      *) want="$FRIENDS_BUILD_NUMBER" ;;
    esac
    got="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)" || got="(missing)"
    [[ "$got" == "$want" ]] || echo "the helper's $key is $got, $FRIENDS_KEYS_FROM asks for $want"
  done
}

# Prints nothing when tests/fixtures/friends/ holds exactly the pinned commit's fixtures.
fixture_problems() {
  local part
  [[ -f "$fixtures_dir/SOURCE" ]] || { echo "tests/fixtures/friends/SOURCE is missing"; return; }
  if [[ "$FRIENDS_MODE" == pinned ]] && ! grep -qx "commit=$FRIENDS_COMMIT" "$fixtures_dir/SOURCE"; then
    echo "tests/fixtures/friends/ came from another commit than friends.lock pins; run --sync-fixtures"
  fi
  for part in "${fixture_parts[@]}"; do
    if ! diff -rq "$FRIENDS_ROOT/portable/friends/fixtures/$part" "$fixtures_dir/$part" >/dev/null 2>&1; then
      echo "tests/fixtures/friends/$part differs from $source_name; run --sync-fixtures"
    fi
  done
}

# --- 1. source -------------------------------------------------------------------
if [[ "$FRIENDS_MODE" == tree ]]; then
  log "building Friends from $where"
elif [[ -e "$FRIENDS_ROOT" ]]; then
  if ! problems="$(source_problems "$FRIENDS_ROOT")"; then
    printf 'error: not building from %s: %s\n' "$where" "$problems" >&2
    if [[ -z "${SZF_FRIENDS_ROOT:-}" ]]; then
      echo "Not touching it. Remove friends-src/ and run this script again to fetch the pinned commit." >&2
    fi
    exit 1
  fi
  log "$where is shenzhen-pdf $short, unmodified"
elif [[ "$mode" != all ]]; then
  die "$where does not exist; run scripts/friends/setup-friends.sh"
else
  stage="$(mktemp -d "$repo_root/.friends-setup.XXXXXX")"
  trap 'rm -rf "$stage"' EXIT
  log "fetching shenzhen-pdf $short from $FRIENDS_URL"
  git init -q "$stage/src"
  git -C "$stage/src" remote add origin "$FRIENDS_URL"
  git -C "$stage/src" fetch -q --no-tags --depth 1 origin "$FRIENDS_COMMIT"
  git -C "$stage/src" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
  got="$(git -C "$stage/src" rev-parse HEAD)"
  [[ "$got" == "$FRIENDS_COMMIT" ]] || die "fetched $got, expected $FRIENDS_COMMIT"
  mv "$stage/src" "$FRIENDS_ROOT"
  rm -rf "$stage"
  trap - EXIT
  log "friends-src/ created at $short"
fi
[[ "$FRIENDS_MODE" == tree ]] || check_pinned_build_number

if [[ "$mode" == sync ]]; then
  rm -rf "$fixtures_dir"
  mkdir -p "$fixtures_dir"
  for part in "${fixture_parts[@]}"; do
    cp -R "$FRIENDS_ROOT/portable/friends/fixtures/$part" "$fixtures_dir/$part"
  done
  if [[ "$FRIENDS_MODE" == tree ]]; then
    printf 'path=apps/pdf/portable/friends/fixtures\n' > "$fixtures_dir/SOURCE"
  else
    printf 'url=%s\ncommit=%s\npath=portable/friends/fixtures\n' "$FRIENDS_URL" "$FRIENDS_COMMIT" \
      > "$fixtures_dir/SOURCE"
  fi
  log "tests/fixtures/friends/ is now $source_name's fixtures"
  exit 0
fi

# --- 2. build --------------------------------------------------------------------
# The helper is built ad hoc here: packaging signs the copy inside the app, and signing this one with a release
# identity would only ask for keychain access.
make_args=(
  -C "$FRIENDS_ROOT/portable" -j "$(sysctl -n hw.ncpu)"
  FRIENDS_HELPER_SHORT_VERSION="$FRIENDS_SHORT_VERSION"
  FRIENDS_HELPER_BUNDLE_VERSION="$FRIENDS_BUNDLE_VERSION"
  FRIENDS_HELPER_SIGN_IDENTITY=-
)
if [[ "$mode" == all ]]; then
  log "make friends-helper-bundle friends-client (helper $FRIENDS_SHORT_VERSION, build number $FRIENDS_BUILD_NUMBER)"
  make "${make_args[@]}" friends-helper-bundle friends-client
  # make rebuilds by file time, not by the version values it is given, so a bundle built earlier with other
  # values counts as up to date. -W marks the bundle's Info.plist changed, which redoes only the bundle step.
  if [[ -n "$(helper_problems)" ]]; then
    log "the built helper carries other version keys; making its bundle again"
    make "${make_args[@]}" -W friends/service/helper/Info.plist friends-helper-bundle
  fi
  log "building the Electron client addon from $source_name's client library"
  SZF_FRIENDS_ROOT="$FRIENDS_ROOT" node "$repo_root/electron/friends/build-native.mjs"
fi

# --- 3. verify -------------------------------------------------------------------
problems="$(helper_problems)"
if [[ ! -f "$FRIENDS_ANIMALS/manifest.json" || ! -f "$FRIENDS_ACKNOWLEDGEMENTS" ]]; then
  problems+="${problems:+$'\n'}the animal set or ACKNOWLEDGEMENTS.txt is missing from $where"
fi
if ! addon="$(SZF_FRIENDS_ROOT="$FRIENDS_ROOT" node "$repo_root/electron/friends/build-native.mjs" --check)"; then
  problems+="${problems:+$'\n'}the Electron client addon is missing or was built from other sources"
fi
fixtures="$(fixture_problems)"
if [[ -n "$fixtures" ]]; then
  problems+="${problems:+$'\n'}$fixtures"
fi
if [[ -n "$problems" ]]; then
  if [[ "$FRIENDS_MODE" == tree ]]; then
    printf 'error: the Friends build does not match apps/pdf as it is now:\n' >&2
  else
    printf 'error: the Friends build does not match friends.lock:\n' >&2
  fi
  printf '%s\n' "$problems" | sed 's/^/  /' >&2
  [[ "$mode" == check ]] && echo "Run scripts/friends/setup-friends.sh to build it." >&2
  exit 1
fi
log "Friends helper $FRIENDS_SHORT_VERSION ($FRIENDS_BUILD_NUMBER) from $source_name: $FRIENDS_HELPER_BUILT"
log "Client addon: $addon"
