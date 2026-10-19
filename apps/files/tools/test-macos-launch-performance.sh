#!/usr/bin/env bash
#
# test-macos-launch-performance.sh — launch performance gate, no display.
#
# Launches a candidate app and a baseline app (by default the last release,
# built from its tag) alternately, measures each launch inside the real app
# code, and fails when the candidate is slower beyond the allowance
# tools/perf/launch_perf.py sets per metric. The baseline runs in the same
# minutes as the candidate, so other work on the machine slows both alike.
#
# Nothing appears on screen: tools/perf/szf_launch_probe.c, inserted into
# Contents/MacOS/nautilus, keeps the process out of the Dock, refuses window
# ordering and activation, and stops a run if any window of it is on screen.
# The person's own Shenzhen Files is never started, stopped or contacted, and
# its settings and update state are not read: each app runs as a copy with its
# own bundle id and its own XDG, GSettings and Friends state.
#
# What each launch reports (milliseconds from process creation, or CPU time):
#   map_ms               the first window would appear (GtkWindow "map")
#   map_main_cpu_ms      main-thread CPU time used by then
#   paint_ms             its first frame is painted
#   loaded_ms            the folder's files are all listed (files view
#                        end-loading with every file seen)
#   loaded_main_cpu_ms   main-thread CPU time used by then
#   loaded_footprint_mb  memory footprint at that point
# Every launch has the settings of a returning user, "folders first" on.
# A candidate that spawns a process (posix_spawn, posix_spawnp, fork) on its
# main thread before the first window maps fails outright, in any launch: the
# probe records every such call, so this is no sample.
#
#   1. tools     build the probe and szf_proc_stats into $BUILD_PERF/tools
#   2. baseline  --baseline APP; or --baseline-release TAG (or latest): the
#                app in that release's DMG, downloaded from
#                casimir-engineering/shenzhen-files; or build --baseline-ref
#                (default: the newest release tag before HEAD) in a worktree
#                under $BUILD_PERF, with this checkout's setup script when the
#                ref predates it, and with the edits in baseline_compat when a
#                newer Homebrew library no longer builds the ref's sources
#                (only ever in that worktree). The Shenzhen repository starts
#                from one commit, so until its first files/ release tag there
#                is no ref to build: use --baseline-release latest then.
#   3. launch    --rounds interleaved rounds (ABBA order, default 15) after one
#                warm-up launch each, on a 46-item folder (--folder to change)
#   4. folders   the same on a folder of 3000 subfolders (1500 plain, 1000
#                named like com.example.N, 500 .rtfd documents): what loading
#                costs per folder (--no-folders to skip)
# Allowances per metric and phase: GATES in tools/perf/launch_perf.py.
#
# --self-test checks the gate itself on the baseline, launch phase: against
# itself it must pass, and with 25 ms of main-thread work added to the
# candidate it must fail.
#
# Usage: tools/test-macos-launch-performance.sh [--candidate APP]
#          [--baseline APP | --baseline-release TAG | --baseline-ref REF]
#          [--rounds N] [--folder DIR]
#          [--no-folders] [--candidate-friends on|off] [--self-test]
#   --candidate  default <repo>/dist/Shenzhen Files.app (package/make-app.sh,
#                then package/bundle-dylibs.sh)
#
# Environment:
#   BUILD_PERF         scratch directory (default <repo>/build-perf, gitignored)
#   NAUTILUS_UPSTREAM  passed to tools/setup-nautilus-tree.sh for the baseline
#   SZF_FRIENDS_ROOT   passed to tools/setup-friends.sh when the baseline ref
#                      pins Shenzhen Friends
#
# Exit status: 0 pass, 1 slower than the baseline or a main-thread spawn
# before the first window, 2 a launch did not finish
# or the baseline or a probe copy could not be made,
# 3 a window reached the screen (the run stops at once).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# In the Shenzhen repository this tree is apps/files and its release tags read files/<version>.
prefix="$(git -C "$repo_root" rev-parse --show-prefix)"
release_tags="${prefix:+files/}[0-9][0-9].*-*"
BUILD="${BUILD_PERF:-$repo_root/build-perf}"
PERF="$script_dir/perf"

candidate="$repo_root/dist/Shenzhen Files.app"
baseline=""
baseline_ref=""
baseline_release=""
release_repo="casimir-engineering/shenzhen-files"
release_asset="ShenzhenFiles-mac-arm64.dmg"
rounds=15
folder=""
folders_phase=1
candidate_friends=default
self_test=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --candidate) candidate="$2"; shift 2 ;;
    --baseline) baseline="$2"; shift 2 ;;
    --baseline-ref) baseline_ref="$2"; shift 2 ;;
    --baseline-release) baseline_release="$2"; shift 2 ;;
    --rounds) rounds="$2"; shift 2 ;;
    --folder) folder="$2"; shift 2 ;;
    --no-folders) folders_phase=0; shift ;;
    --candidate-friends) candidate_friends="$2"; shift 2 ;;
    --self-test) self_test=1; shift ;;
    -h|--help) sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '==> %s\n' "$*"; }

mkdir -p "$BUILD/tools" "$BUILD/data"

# --- 1. tools --------------------------------------------------------------------
probe="$BUILD/tools/libszf_launch_probe.dylib"
stats="$BUILD/tools/szf_proc_stats"
if [[ ! -f "$probe" || "$PERF/szf_launch_probe.c" -nt "$probe" ]]; then
  log "building the launch probe"
  clang -arch arm64 -mmacosx-version-min=12.0 -O2 -Wall -Wextra -Werror -dynamiclib \
    -o "$probe" "$PERF/szf_launch_probe.c" -framework ApplicationServices -framework CoreFoundation -lobjc
fi
if [[ ! -f "$stats" || "$PERF/szf_proc_stats.c" -nt "$stats" ]]; then
  clang -O2 -Wall -Werror -o "$stats" "$PERF/szf_proc_stats.c" -framework CoreGraphics -framework CoreFoundation
fi
export SZF_PERF_TOOLS="$BUILD/tools"

# --- 2. baseline -----------------------------------------------------------------
# Homebrew moves on after a release, and an older release's sources may no longer build against what it installs
# now. Each edit here applies to the baseline's worktree only, only when the installed library needs it, and marks
# the file it changes; it never changes what the release does. Prints the edited paths, if any.
#   glib 2.90 declares g_set_date_time, which nautilus defined itself until then: the copy is skipped where glib
#   has one.
COMPAT_MARK="szf-baseline-compat"
baseline_compat() {
  local header="$1/nautilus/src/nautilus-date-utilities.h"
  if [[ -f "$header" ]] && ! grep -q "$COMPAT_MARK" "$header" && grep -q '^g_set_date_time (' "$header" &&
     pkg-config --atleast-version=2.90 glib-2.0; then
    python3 - "$header" "$COMPAT_MARK" <<'PYEOF'
import re, sys
path, mark = sys.argv[1], sys.argv[2]
text = open(path).read()
match = re.search(r"static inline gboolean\ng_set_date_time \(.*?\n}\n", text, re.S)
if not match:
    sys.exit("baseline_compat: g_set_date_time not found in " + path)
guarded = ("#if !GLIB_CHECK_VERSION (2, 90, 0) /* " + mark + ": glib has its own */\n" + match.group(0)
           + "#endif\n")
open(path, "w").write(text[:match.start()] + guarded + text[match.end():])
PYEOF
    printf '%s\n' "$header"
  fi
}

build_baseline() {
  local ref="$1" sha top src app
  sha="$(git -C "$repo_root" rev-parse --verify "$ref^{commit}")"
  top="$BUILD/baseline-src-${sha:0:12}"
  src="$top${prefix:+/${prefix%/}}"
  app="$BUILD/baseline-${sha:0:12}/Shenzhen Files.app"
  if [[ -x "$app/Contents/MacOS/nautilus" ]]; then
    log "baseline: $ref (${sha:0:12}), built earlier: $app" >&2
    printf '%s\n' "$app"
    return
  fi
  log "baseline: building $ref (${sha:0:12}) in $src" >&2
  if [[ ! -d "$top" ]]; then
    git -C "$repo_root" worktree add --detach "$top" "$sha" >&2
  fi
  # Releases before 26.10 had no setup script; this checkout's reproduces their tree, and is copied again on every
  # run so a fix to it reaches a worktree made earlier.
  if ! git -C "$src" ls-files --error-unmatch tools/setup-nautilus-tree.sh >/dev/null 2>&1; then
    cp "$repo_root/tools/setup-nautilus-tree.sh" "$src/tools/"
  fi
  if [[ ! -f "$src/patches/base-46d27d6-prioritize-copied-files.patch" ]]; then
    cp "$repo_root/patches/base-46d27d6-prioritize-copied-files.patch" "$src/patches/"
  fi
  if [[ -f "$src/friends.lock" ]]; then
    (cd "$src" && ./tools/setup-friends.sh) >&2
  fi
  # The tree first, then any compatibility edit, then the build; a tree edited on an earlier run is built as is.
  local allow=""
  if grep -rqs "$COMPAT_MARK" "$src/nautilus/src"; then allow="--allow-modified"; fi
  (cd "$src" && ./tools/setup-nautilus-tree.sh --tree-only $allow) >&2
  if [[ -n "$(baseline_compat "$src")" ]]; then
    log "baseline: compatibility edits for this machine's Homebrew libraries ($COMPAT_MARK)" >&2
    allow="--allow-modified"
  fi
  (cd "$src" && ./tools/setup-nautilus-tree.sh $allow) >&2
  mkdir -p "$(dirname "$app")"
  (cd "$src" && env -u MAC_SIGN_IDENTITY ./package/make-app.sh "$app" &&
     env -u MAC_SIGN_IDENTITY ./package/bundle-dylibs.sh "$app") >&2
  printf '%s\n' "$app"
}

# The app of a published release, from its DMG: TAG, or latest for the newest release. Cached per release.
download_baseline() {
  local tag="$1" dir dmg mnt found
  if [[ "$tag" == latest ]]; then
    tag="$(curl -fsSL "https://api.github.com/repos/$release_repo/releases/latest" |
      python3 -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])')" || return 1
  fi
  [[ "$tag" =~ ^[0-9A-Za-z._-]+$ ]] || { echo "error: not a release tag: $tag" >&2; return 1; }
  dir="$BUILD/baseline-release-$tag"
  if [[ -x "$dir/Shenzhen Files.app/Contents/MacOS/nautilus" ]]; then
    log "baseline: release $tag, downloaded earlier: $dir/Shenzhen Files.app" >&2
    printf '%s\n' "$dir/Shenzhen Files.app"
    return
  fi
  log "baseline: downloading release $tag of $release_repo" >&2
  rm -rf "$dir"
  mkdir -p "$dir"
  dmg="$dir/$release_asset"
  mnt="$dir/mnt"
  curl -fsSL -o "$dmg" "https://github.com/$release_repo/releases/download/$tag/$release_asset" || return 1
  mkdir -p "$mnt"
  hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$dmg" >/dev/null || return 1
  found=""
  for found in "$mnt"/*.app; do break; done
  if [[ -d "$found" ]]; then ditto "$found" "$dir/Shenzhen Files.app"; fi
  hdiutil detach "$mnt" >/dev/null
  rmdir "$mnt"
  rm -f "$dmg"
  [[ -x "$dir/Shenzhen Files.app/Contents/MacOS/nautilus" ]] ||
    { echo "error: no Shenzhen Files.app in the $tag DMG" >&2; return 1; }
  printf '%s\n' "$dir/Shenzhen Files.app"
}

if [[ -z "$baseline" && -n "$baseline_release" ]]; then
  baseline="$(download_baseline "$baseline_release")" ||
    { echo "error: could not download the baseline release $baseline_release" >&2; exit 2; }
fi
if [[ -z "$baseline" ]]; then
  if [[ -z "$baseline_ref" ]]; then
    # The newest release before this checkout: a release commit compares with the one before it.
    no_release_tag() {
      echo "error: no release tag ($release_tags) before HEAD to compare with. The Shenzhen repository starts" \
        "from one commit; until its first files/ release, name the baseline: --baseline-release latest" \
        "(the newest release on $release_repo), --baseline APP or --baseline-ref REF" >&2
      exit 2
    }
    baseline_ref="$(git -C "$repo_root" describe --tags --abbrev=0 --match "$release_tags" HEAD 2>/dev/null)" ||
      no_release_tag
    if [[ "$(git -C "$repo_root" rev-parse "$baseline_ref^{commit}")" == "$(git -C "$repo_root" rev-parse HEAD)" ]]; then
      baseline_ref="$(git -C "$repo_root" describe --tags --abbrev=0 --match "$release_tags" HEAD^ 2>/dev/null)" ||
        no_release_tag
    fi
  fi
  baseline="$(build_baseline "$baseline_ref")" || { echo "error: could not build the baseline $baseline_ref" >&2; exit 2; }
fi

# --- 3. and 4. compare -------------------------------------------------------------
if [[ -z "$folder" ]]; then
  folder="$BUILD/data/launch-folder"
  if [[ ! -d "$folder" ]]; then
    mkdir -p "$folder.tmp"
    for i in $(seq -w 1 40); do printf '%*s' "$((10#$i))" '' > "$folder.tmp/file-$i.txt"; done
    for i in $(seq 1 6); do mkdir -p "$folder.tmp/folder-$i"; touch "$folder.tmp/folder-$i/inner.txt"; done
    mv "$folder.tmp" "$folder"
  fi
fi
folders="$BUILD/data/folders-3000"
if [[ "$folders_phase" == 1 && ! -d "$folders" ]]; then
  rm -rf "$folders.tmp"
  mkdir -p "$folders.tmp"
  (cd "$folders.tmp" &&
     for i in $(seq -w 1 1500); do mkdir "Folder $i"; done &&
     for i in $(seq -w 1 1000); do mkdir "com.example.project-$i"; done &&
     for i in $(seq -w 1 500); do mkdir "Notes $i.rtfd"; done)
  mv "$folders.tmp" "$folders"
fi

python3 "$PERF/launch_perf.py" prepare "$baseline" "$BUILD/probe/baseline.probe" >/dev/null || exit 2

compare() {
  python3 "$PERF/launch_perf.py" compare --baseline "$BUILD/probe/baseline.probe" \
    --rounds "$rounds" --workdir "$BUILD/runs" "$@"
}

if [[ "$self_test" == 1 ]]; then
  log "self-test 1/2: the baseline against itself must pass"
  status=0
  compare --folder "$folder" --candidate "$BUILD/probe/baseline.probe" \
    --report "$BUILD/self-test-same.json" || status=$?
  if [[ "$status" != 0 ]]; then
    echo "error: the gate failed a build against itself (exit $status)" >&2
    exit 1
  fi
  log "self-test 2/2: with 25 ms more main-thread work the candidate must fail"
  status=0
  compare --folder "$folder" --candidate "$BUILD/probe/baseline.probe" --inject-delay-ms 25 \
    --report "$BUILD/self-test-slower.json" || status=$?
  if [[ "$status" != 1 ]]; then
    echo "error: the gate did not catch a 25 ms regression (exit $status)" >&2
    exit 1
  fi
  log "self-test passed"
  exit 0
fi

if [[ ! -x "$candidate/Contents/MacOS/nautilus" ]]; then
  echo "error: no app at $candidate; run package/make-app.sh and package/bundle-dylibs.sh" >&2
  exit 2
fi
python3 "$PERF/launch_perf.py" prepare "$candidate" "$BUILD/probe/candidate.probe" >/dev/null || exit 2
log "candidate: $candidate"
log "baseline:  $baseline"
status=0
compare --gate launch --folder "$folder" --candidate "$BUILD/probe/candidate.probe" \
  --candidate-friends "$candidate_friends" --report "$BUILD/launch-performance.json" || status=$?
if [[ "$status" == 3 ]]; then
  exit 3
fi
if [[ "$folders_phase" == 1 ]]; then
  folders_status=0
  compare --gate folders --folder "$folders" --candidate "$BUILD/probe/candidate.probe" \
    --candidate-friends "$candidate_friends" --report "$BUILD/folders-performance.json" || folders_status=$?
  if [[ "$folders_status" == 3 ]]; then
    exit 3
  fi
  # A launch that did not finish (2) outranks a slower candidate (1).
  if (( folders_status > status )); then
    status=$folders_status
  fi
fi
exit "$status"
