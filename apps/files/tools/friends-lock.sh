# shellcheck shell=bash disable=SC2034  # sourced: the variables it sets are read by the scripts that source it
# friends-lock.sh — read friends.lock and name the shenzhen-pdf checkout Shenzhen Friends is built from.
#
# Sourced, never run, by tools/setup-friends.sh, package/make-app.sh and package/check-friends-bundle.sh, so all
# three agree on the pin, the helper's version keys and where the build lives (docs/friends-integration.md § 3.2).
#
# friends_lock_read <repo_root> sets these, or prints what is wrong and returns 1:
#   FRIENDS_URL             url=, or SZF_FRIENDS_URL when set (a local mirror or clone)
#   FRIENDS_COMMIT          commit=, 40 lowercase hex digits
#   FRIENDS_BUILD_NUMBER    helper_build_number=, YYMMDDBB: the pinned shenzhen-pdf build's own helper number
#   FRIENDS_SHORT_VERSION   YY.M.D read from it, written like ShenzhenPDF's versions (no leading zeros)
#   FRIENDS_BUNDLE_VERSION  BB read from it, what helper.mk calls FRIENDS_HELPER_BUNDLE_VERSION
#   FRIENDS_ROOT            SZF_FRIENDS_ROOT made absolute, or <repo_root>/friends-src
#   FRIENDS_HELPER_BUILT    the helper bundle friends-helper-bundle writes in that checkout
#   FRIENDS_GTK_LIB         the GTK views library friends-gtk-lib writes there
#   FRIENDS_ANIMALS         the animal set (manifest.json, svg/, pdf/) in that checkout
#   FRIENDS_ACKNOWLEDGEMENTS  the third-party notices in that checkout
#   FRIENDS_MODE            tree or pinned, below
#   FRIENDS_KEYS_FROM       what the helper's version keys come from, for messages
#
# Two modes:
#   pinned  the standalone shenzhen-files repository: Friends is shenzhen-pdf at friends.lock's commit, in
#           friends-src/ or SZF_FRIENDS_ROOT, as described above.
#   tree    Shenzhen Files at apps/files of the Shenzhen repository, beside ShenzhenPDF in apps/pdf: Friends is
#           built from apps/pdf in the same tree. Nothing is pinned or fetched and friends.lock is not read;
#           FRIENDS_ROOT is apps/pdf, FRIENDS_URL and FRIENDS_COMMIT are empty, and the helper's version keys are
#           the ones ShenzhenPDF's own build stamps: MAC_VERSION and MAC_BUILD in apps/pdf/portable/Makefile.
# Tree is the default when apps/pdf/portable/friends exists beside this tree and SZF_FRIENDS_ROOT is not set;
# SZF_FRIENDS_MODE=tree or SZF_FRIENDS_MODE=pinned chooses one explicitly.
#
# The lock is parsed, never sourced: it is data, and a stray line must be an error rather than a command.

FRIENDS_HELPER_NAME="Shenzhen Friends"
# Both apps embed the helper under this one identifier, so they share one Friends identity per Mac user and its
# Keychain item reads without a prompt.
FRIENDS_HELPER_ID="com.intuition.shenzhenfriends"

# Prints tree or pinned for the tree at $1 (see above).
friends_mode() {
  local repo_root="$1"
  case "${SZF_FRIENDS_MODE:-}" in
    tree|pinned) echo "$SZF_FRIENDS_MODE"; return 0 ;;
    "") ;;
    *) echo "error: SZF_FRIENDS_MODE must be tree or pinned, not '$SZF_FRIENDS_MODE'" >&2; return 1 ;;
  esac
  if [[ -z "${SZF_FRIENDS_ROOT:-}" && "$(basename "$(dirname "$repo_root")")" == apps &&
        -d "$repo_root/../pdf/portable/friends" ]]; then
    echo tree
  else
    echo pinned
  fi
}

# Tree mode: apps/pdf beside $1, with the helper's version keys from its portable/Makefile, YYMMDDBB as helper.mk
# computes it.
friends_tree_read() {
  local pdf="$1/../pdf" makefile version build
  if [[ ! -d "$pdf/portable/friends" ]]; then
    echo "error: building Friends from this tree needs ShenzhenPDF beside it: no $pdf/portable/friends" >&2
    return 1
  fi
  FRIENDS_ROOT="$(cd "$pdf" && pwd -P)"
  makefile="$FRIENDS_ROOT/portable/Makefile"
  version="$(awk '$1 == "MAC_VERSION" && $2 == "?=" { print $3; exit }' "$makefile" 2>/dev/null)"
  build="$(awk '$1 == "MAC_BUILD" && $2 == "?=" { print $3; exit }' "$makefile" 2>/dev/null)"
  if [[ ! "$version" =~ ^[0-9]+\.[1-9][0-9]?\.[1-9][0-9]?$ || ! "$build" =~ ^[1-9][0-9]?$ ]]; then
    echo "error: cannot read MAC_VERSION (YY.M.D) and MAC_BUILD from $makefile" >&2
    return 1
  fi
  FRIENDS_URL="" FRIENDS_COMMIT=""
  FRIENDS_SHORT_VERSION="$version"
  FRIENDS_BUNDLE_VERSION="$build"
  FRIENDS_BUILD_NUMBER="$(echo "$version $build" |
    awk '{ split($1, v, "."); printf "%02d%02d%02d%02d", v[1] % 100, v[2], v[3], $2 }')"
  FRIENDS_KEYS_FROM="apps/pdf/portable/Makefile"
}

friends_lock_read() {
  local repo_root="$1"
  FRIENDS_MODE="$(friends_mode "$repo_root")" || return 1
  if [[ "$FRIENDS_MODE" == tree ]]; then
    friends_tree_read "$repo_root" || return 1
  else
    friends_pinned_read "$repo_root" || return 1
  fi
  FRIENDS_HELPER_BUILT="$FRIENDS_ROOT/portable/build/friends/$FRIENDS_HELPER_NAME.app"
  FRIENDS_GTK_LIB="$FRIENDS_ROOT/portable/build/friends/gtk/libszfriends_gtk.a"
  FRIENDS_ANIMALS="$FRIENDS_ROOT/portable/friends/avatars/animals"
  FRIENDS_ACKNOWLEDGEMENTS="$FRIENDS_ROOT/portable/friends/ACKNOWLEDGEMENTS.txt"
}

friends_pinned_read() {
  local repo_root="$1" lock="$1/friends.lock" line key value n=0 seen=" "
  FRIENDS_URL="" FRIENDS_COMMIT="" FRIENDS_BUILD_NUMBER=""
  if [[ ! -f "$lock" ]]; then
    echo "error: $lock is missing" >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    if [[ "$key" == "$line" ]]; then
      echo "error: friends.lock line $n is not key=value: $line" >&2
      return 1
    fi
    if [[ "$seen" == *" $key "* ]]; then
      echo "error: friends.lock line $n sets $key a second time" >&2
      return 1
    fi
    seen+="$key "
    case "$key" in
      url) FRIENDS_URL="$value" ;;
      commit) FRIENDS_COMMIT="$value" ;;
      helper_build_number) FRIENDS_BUILD_NUMBER="$value" ;;
      *) echo "error: friends.lock line $n: unknown key '$key'" >&2; return 1 ;;
    esac
  done < "$lock"

  if [[ -z "$FRIENDS_URL" ]]; then
    echo "error: friends.lock has no url=" >&2
    return 1
  fi
  if [[ ! "$FRIENDS_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: friends.lock: commit must be a full 40-digit lowercase commit id, not '$FRIENDS_COMMIT'" >&2
    return 1
  fi
  # YYMMDDBB, as helper.mk computes it from ShenzhenPDF's "YY.M.D" version and build. Checked here because a
  # wrong number silently decides which app's helper wins a handover (PROTOCOL.md § Lifecycle).
  local month day build
  if [[ "$FRIENDS_BUILD_NUMBER" =~ ^[0-9]{8}$ ]]; then
    month=$((10#${FRIENDS_BUILD_NUMBER:2:2}))
    day=$((10#${FRIENDS_BUILD_NUMBER:4:2}))
    build=$((10#${FRIENDS_BUILD_NUMBER:6:2}))
  else
    month=0 day=0 build=0
  fi
  if (( month < 1 || month > 12 || day < 1 || day > 31 || build < 1 )); then
    echo "error: friends.lock: helper_build_number must be YYMMDDBB (for example 26101101), not" \
         "'$FRIENDS_BUILD_NUMBER'" >&2
    return 1
  fi
  FRIENDS_SHORT_VERSION="$((10#${FRIENDS_BUILD_NUMBER:0:2})).$month.$day"
  FRIENDS_BUNDLE_VERSION="$build"

  if [[ -n "${SZF_FRIENDS_URL:-}" ]]; then
    FRIENDS_URL="$SZF_FRIENDS_URL"
  fi
  if [[ -n "${SZF_FRIENDS_ROOT:-}" ]]; then
    if [[ ! -d "$SZF_FRIENDS_ROOT" ]]; then
      echo "error: SZF_FRIENDS_ROOT is not a directory: $SZF_FRIENDS_ROOT" >&2
      return 1
    fi
    FRIENDS_ROOT="$(cd "$SZF_FRIENDS_ROOT" && pwd -P)"
  else
    FRIENDS_ROOT="$repo_root/friends-src"
  fi
  FRIENDS_KEYS_FROM="friends.lock"
}
