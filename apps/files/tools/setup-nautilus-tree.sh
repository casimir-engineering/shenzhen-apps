#!/usr/bin/env bash
#
# setup-nautilus-tree.sh — reproduce the integrated nautilus/ tree and build it.
#
# The upstream tree stays out of git (.gitignore: /nautilus/); this script and
# the files in patches/ are the record. Every step is skipped when it is
# already done, so running the script again is safe and cheap.
#
#   1. tree       nautilus/ = upstream GNOME Nautilus at BASE_COMMIT (a shallow
#                 fetch of exactly that commit), plus
#                 patches/base-46d27d6-prioritize-copied-files.patch committed
#                 on top with its original identity (HEAD becomes 46d27d6, the
#                 commit the port patch has been generated against since
#                 2ec197e), plus patches/macos-port-full.patch applied to the
#                 working tree, then patches/friends-host-adapter.patch (the
#                 Shenzhen Friends host adapter, docs/friends-integration.md
#                 § 3.3) when it exists. Every file the patches touch is then
#                 checked against the post-image blob id recorded in the last
#                 patch that touches it. A tree made before the adapter patch
#                 existed, and otherwise unchanged, gets it applied.
#   2. configure  meson setup build nautilus, with the options the releases
#                 use (from build/meson-logs of the 26.9.14-1 release build),
#                 plus -Dfriends_root: the shenzhen-pdf checkout friends.lock
#                 names (tools/friends-lock.sh), whose views
#                 tools/setup-friends.sh must have built.
#   3. build      ninja -C build
#   4. install    meson install -C build --no-rebuild  (prefix <repo>/install,
#                 which package/make-app.sh reads)
#
# Never deletes or resets an existing nautilus/. A tree that is exactly what an
# earlier committed revision of the patches made (the release's cached tree after
# the patches changed) is brought to today's patches by reversing those and
# applying these. A tree whose files differ from the patch's post-images
# otherwise (local work in progress) stops the script, unless --allow-modified
# is given, in which case it is configured and built as is.
#
# Usage: tools/setup-nautilus-tree.sh [--check | --tree-only] [--allow-modified]
#   --check           verify nautilus/ against the patches; change nothing
#   --tree-only       stop after step 1
#   --allow-modified  build a nautilus/ that differs from the patches
#
# Environment:
#   NAUTILUS_UPSTREAM  upstream URL (default: GNOME GitLab; the GitHub mirror
#                      https://github.com/GNOME/nautilus.git serves the same
#                      commit)
#   HOMEBREW_PREFIX    default /opt/homebrew
#   SZF_FRIENDS_ROOT   the Shenzhen Friends checkout, as tools/setup-friends.sh
#                      takes it (default <repo>/friends-src)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# Upstream main, "Post-release version bump" (2026-06-28), meson version
# 51.beta: the shallow root of the original working tree.
BASE_COMMIT="d95ce4060b39911fb68c0cb3626e47f52bd9d0b8"
# The local commit on top of it, reproduced bit-for-bit by step 1.
FIXUP_COMMIT="46d27d6d0c850836c9b44a6a10deea67885ce532"
UPSTREAM="${NAUTILUS_UPSTREAM:-https://gitlab.gnome.org/GNOME/nautilus.git}"
BREW="${HOMEBREW_PREFIX:-/opt/homebrew}"

TREE="$repo_root/nautilus"
BUILD="$repo_root/build"
PREFIX="$repo_root/install"
FIXUP_PATCH="$repo_root/patches/base-46d27d6-prioritize-copied-files.patch"
PORT_PATCH="$repo_root/patches/macos-port-full.patch"
# Applied after the port patch, so the port stays free of Friends and the two
# rebase independently. Optional: a checkout from before it still builds.
ADAPTER_PATCH="$repo_root/patches/friends-host-adapter.patch"
PATCHES=("$PORT_PATCH")
if [[ -f "$ADAPTER_PATCH" ]]; then
  PATCHES+=("$ADAPTER_PATCH")
fi

MESON_OPTIONS=(
  --prefix="$PREFIX"
  --buildtype=debugoptimized
  -Dmacos_port=true
  -Dextensions=false
  -Dselinux=disabled
  -Dcloudproviders=disabled
  -Dtests=none
  -Dintrospection=false
)

mode=all
allow_modified=0
for arg in "$@"; do
  case "$arg" in
    --check) mode=check ;;
    --tree-only) mode=tree ;;
    --allow-modified) allow_modified=1 ;;
    -h|--help) sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# Keg-only formulae the build finds through pkg-config (icu4c@78 for ICU,
# libarchive for gnome-autoar).
export PKG_CONFIG_PATH="$BREW/opt/icu4c@78/lib/pkgconfig:$BREW/opt/libarchive/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

log() { printf '==> %s\n' "$*"; }

# Prints one line per path in $1 that is not in the state the patches after it
# make, applied in order: a file a patch touches whose content is not the
# post-image of the last patch touching it (or that exists although that patch
# deletes it), and any other changed or untracked path. Silent and exit 0 when
# the tree is exactly that state.
verify_tree() {
  python3 - "$@" <<'PYEOF'
import os, re, subprocess, sys
tree, patches = sys.argv[1], sys.argv[2:]
bad, wants = [], {}
for patch in patches:
    current, checked = None, 0
    with open(patch, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.match(r"^diff --git a/(\S+) b/(\S+)$", line.rstrip("\n"))
            if m:
                current = m.group(2)
                continue
            m = re.match(r"^index ([0-9a-f]+)\.\.([0-9a-f]+)", line)
            if not (m and current):
                continue
            # A later patch's post-image replaces an earlier one's.
            wants[current] = m.group(2)
            checked += 1
            current = None
    if checked == 0:
        bad.append(f"no files found in {os.path.basename(patch)}")
for current, want in sorted(wants.items()):
    path = os.path.join(tree, current)
    if set(want) == {"0"}:
        if os.path.lexists(path):
            bad.append(f"{current}: should not exist")
    elif not os.path.isfile(path):
        bad.append(f"{current}: missing")
    else:
        got = subprocess.run(["git", "hash-object", path], check=True,
                             capture_output=True, text=True).stdout.strip()
        if not got.startswith(want):
            bad.append(f"{current}: blob {got[:7]}, patch expects {want}")
paths = set(wants)
# Anything else that differs from HEAD (an edited file the patch leaves alone,
# a new untracked file) is local work too.
status = subprocess.run(["git", "-C", tree, "status", "--porcelain=v1", "-z",
                         "--untracked-files=all"], check=True,
                        capture_output=True, text=True).stdout
for entry in filter(None, status.split("\0")):
    if entry[3:] not in paths:
        bad.append(f"{entry[3:]}: changed, but not part of the patches")
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PYEOF
}

# Applies the adapter patch to a tree in the port patch's state, then checks
# the result. Used for a new tree, and for one made before the patch existed.
apply_adapter() {
  local tree="$1" problems
  log "applying $(basename "$ADAPTER_PATCH")"
  git -C "$tree" apply --whitespace=nowarn "$ADAPTER_PATCH"
  if ! problems="$(verify_tree "$tree" "${PATCHES[@]}")"; then
    echo "error: patched tree does not match the patches' post-images:" >&2
    printf '  %s\n' "$problems" >&2
    exit 1
  fi
}

# A tree made by this script from an earlier committed revision of the patches, untouched since (the release's
# cached worktree after the patches changed): prints that revision's commit and exits 0, or exits 1. Only exact
# matches count, so local work is never mistaken for an old tree.
old_patch() { git -C "$repo_root" show "$1:./patches/$2" 2>/dev/null; }
find_older_patches() {
  local rev
  git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1 || return 1
  for rev in $(git -C "$repo_root" log --format=%H -n 40 -- patches/macos-port-full.patch patches/friends-host-adapter.patch); do
    old_patch "$rev" macos-port-full.patch >/dev/null || continue
    if old_patch "$rev" friends-host-adapter.patch >/dev/null; then
      verify_tree "$TREE" <(old_patch "$rev" macos-port-full.patch) <(old_patch "$rev" friends-host-adapter.patch) \
        >/dev/null || continue
    else
      verify_tree "$TREE" <(old_patch "$rev" macos-port-full.patch) >/dev/null || continue
    fi
    echo "$rev"
    return 0
  done
  return 1
}

# Takes a tree from find_older_patches back to the base commit by reversing that revision's patches, then applies
# today's, and checks the result.
update_older_tree() {
  local rev="$1" problems
  log "nautilus/ was made from the patches at ${rev:0:12}; bringing it to today's patches"
  if old_patch "$rev" friends-host-adapter.patch >/dev/null; then
    old_patch "$rev" friends-host-adapter.patch | git -C "$TREE" apply -R --whitespace=nowarn -
  fi
  old_patch "$rev" macos-port-full.patch | git -C "$TREE" apply -R --whitespace=nowarn -
  if [[ -n "$(git -C "$TREE" status --porcelain=v1 --untracked-files=all)" ]]; then
    echo "error: reversing the patches at ${rev:0:12} did not give the base commit back" >&2
    exit 1
  fi
  log "applying $(basename "$PORT_PATCH")"
  git -C "$TREE" apply --whitespace=nowarn "$PORT_PATCH"
  if [[ ${#PATCHES[@]} -gt 1 ]]; then
    apply_adapter "$TREE"
  elif ! problems="$(verify_tree "$TREE" "${PATCHES[@]}")"; then
    echo "error: patched tree does not match the patches' post-images:" >&2
    printf '  %s\n' "$problems" >&2
    exit 1
  fi
}

check_existing_tree() {
  local head problems
  head="$(git -C "$TREE" rev-parse HEAD 2>/dev/null || echo none)"
  if problems="$(verify_tree "$TREE" "${PATCHES[@]}")" && [[ "$head" == "$FIXUP_COMMIT" ]]; then
    log "nautilus/ matches the patches (HEAD $FIXUP_COMMIT)"
    return 0
  fi
  # Exactly the port patch's state: a tree from before the adapter patch.
  if [[ ${#PATCHES[@]} -gt 1 && "$head" == "$FIXUP_COMMIT" ]] && verify_tree "$TREE" "$PORT_PATCH" >/dev/null; then
    if [[ "$mode" == check ]]; then
      echo "nautilus/ has the port patch but not $(basename "$ADAPTER_PATCH");" \
           "run without --check to apply it" >&2
      return 1
    fi
    apply_adapter "$TREE"
    log "nautilus/ matches the patches (HEAD $FIXUP_COMMIT)"
    return 0
  fi
  # Exactly what an earlier revision of the patches made: brought up to date (the release's cached tree).
  local older
  if [[ "$head" == "$FIXUP_COMMIT" ]] && older="$(find_older_patches)"; then
    if [[ "$mode" == check ]]; then
      echo "nautilus/ was made from the patches at ${older:0:12}; run without --check to update it" >&2
      return 1
    fi
    update_older_tree "$older"
    log "nautilus/ matches the patches (HEAD $FIXUP_COMMIT)"
    return 0
  fi
  echo "nautilus/ differs from the patches:" >&2
  [[ "$head" == "$FIXUP_COMMIT" ]] || echo "  HEAD is $head, expected $FIXUP_COMMIT" >&2
  [[ -z "$problems" ]] || printf '  %s\n' "$problems" >&2
  return 1
}

# --- 1. tree -------------------------------------------------------------------
if [[ -e "$TREE" ]]; then
  if ! check_existing_tree; then
    if [[ "$mode" == check || "$allow_modified" != 1 ]]; then
      echo "Not touching it. Move nautilus/ aside to recreate it, or pass" >&2
      echo "--allow-modified to build it as it is." >&2
      exit 1
    fi
    log "continuing with the modified tree (--allow-modified)"
  fi
else
  if [[ "$mode" == check ]]; then
    echo "nautilus/ does not exist; run without --check to create it" >&2
    exit 1
  fi
  stage="$(mktemp -d "$repo_root/.nautilus-setup.XXXXXX")"
  trap 'rm -rf "$stage"' EXIT
  log "fetching $BASE_COMMIT from $UPSTREAM"
  git init -q "$stage/nautilus"
  git -C "$stage/nautilus" remote add origin "$UPSTREAM"
  git -C "$stage/nautilus" fetch -q --depth 1 origin "$BASE_COMMIT"
  git -C "$stage/nautilus" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
  # Track it as main, as the original clone did, so `git diff` in nautilus/
  # regenerates the port patch against the same base.
  git -C "$stage/nautilus" checkout -q -b main

  log "committing $(basename "$FIXUP_PATCH") with its original identity"
  GIT_COMMITTER_NAME="Raphaël Casimir" GIT_COMMITTER_EMAIL="mail@raph.io" \
    git -C "$stage/nautilus" -c user.name=setup -c user.email=setup@localhost \
      am -q --committer-date-is-author-date "$FIXUP_PATCH"
  got="$(git -C "$stage/nautilus" rev-parse HEAD)"
  if [[ "$got" != "$FIXUP_COMMIT" ]]; then
    echo "error: base commit is $got, expected $FIXUP_COMMIT" >&2
    exit 1
  fi

  log "applying $(basename "$PORT_PATCH")"
  git -C "$stage/nautilus" apply --whitespace=nowarn "$PORT_PATCH"
  if ! problems="$(verify_tree "$stage/nautilus" "$PORT_PATCH")"; then
    echo "error: patched tree does not match the patch's post-images:" >&2
    printf '  %s\n' "$problems" >&2
    exit 1
  fi
  if [[ ${#PATCHES[@]} -gt 1 ]]; then
    apply_adapter "$stage/nautilus"
  fi
  mv "$stage/nautilus" "$TREE"
  rm -rf "$stage"
  trap - EXIT
  log "nautilus/ created and verified ($(git -C "$TREE" status --porcelain | wc -l | tr -d ' ') patched paths)"
fi

[[ "$mode" == all ]] || exit 0

# --- 2. configure --------------------------------------------------------------
# Shenzhen Friends: with the adapter patch, nautilus links the views that
# tools/setup-friends.sh built from the checkout friends.lock pins, so that
# build is checked first and its checkout passed as friends_root.
friends_args=()
if [[ ${#PATCHES[@]} -gt 1 ]]; then
  # shellcheck source-path=SCRIPTDIR source=friends-lock.sh
  . "$script_dir/friends-lock.sh"
  friends_lock_read "$repo_root" || exit 1
  "$script_dir/setup-friends.sh" --check
  MESON_OPTIONS+=(-Dfriends_root="$FRIENDS_ROOT")
  friends_args=("$FRIENDS_ROOT")
fi

if [[ -f "$BUILD/build.ninja" ]]; then
  # A build dir configured with other options would silently produce a
  # different app; refuse rather than guess.
  # ${a[@]+"${a[@]}"}: macOS's bash 3.2 treats an empty array as unset under set -u.
  python3 - "$BUILD/meson-info/intro-buildoptions.json" "$PREFIX" ${friends_args[@]+"${friends_args[@]}"} <<'PYEOF'
import json, sys
opts = {o["name"]: o["value"] for o in json.load(open(sys.argv[1]))}
want = {"prefix": sys.argv[2], "buildtype": "debugoptimized", "macos_port": True,
        "extensions": False, "selinux": "disabled", "cloudproviders": "disabled",
        "tests": "none", "introspection": False}
if len(sys.argv) > 3:
    want["friends_root"] = sys.argv[3]
bad = [f"{k}={opts.get(k)!r} (want {v!r})" for k, v in want.items() if opts.get(k) != v]
if bad:
    print("error: build/ is configured differently: " + ", ".join(bad), file=sys.stderr)
    print("       remove build/ or reconfigure it with the options in this script", file=sys.stderr)
    if "friends_root" in want and opts.get("friends_root") != want["friends_root"]:
        print(f"       (meson configure build -Dfriends_root={want['friends_root']})", file=sys.stderr)
    sys.exit(1)
PYEOF
  log "build/ already configured with the release options"
else
  log "meson setup build nautilus ${MESON_OPTIONS[*]}"
  (cd "$repo_root" && meson setup build nautilus "${MESON_OPTIONS[@]}")
fi

# --- 3. build ------------------------------------------------------------------
log "ninja -C build"
ninja -C "$BUILD"

# --- 4. install ----------------------------------------------------------------
log "meson install -C build --no-rebuild"
meson install -C "$BUILD" --no-rebuild --quiet
log "done: $BUILD/src/nautilus, $PREFIX"
log "next: package/make-app.sh, then package/bundle-dylibs.sh"
