#!/usr/bin/env bash
# Proof for the silent-failure remediation: QC's F5, F6 and F7.
#
#   portable/win/tests/t7-verify.sh [--no-vm]
#
# Two claims, and the second is the one that matters:
#
#   1. portable/win/tests/silent_failure_test.c passes against the CURRENT
#      sources, natively on macOS (clang/arm64) and in the Windows guest
#      (MSVC/ARM64).
#   2. The same test, compiled against the sources as they were at HEAD~ for
#      this track, FAILS. A regression test that was never seen to fail is a
#      regression test that might assert nothing; this script demonstrates the
#      failure rather than asserting it happened once, offscreen, in a report.
#
# Claim 2 works because silent_failure_test.c compiles against both the pre-fix
# and post-fix spdf_win_state.h — the read-status assertions sit behind
# SPDF_WIN_STATE_HAS_READ_STATUS, and everything else uses API that predates the
# fix. The pre-fix tree comes from `git show`, so nothing in the working tree is
# disturbed and the comparison cannot be fooled by an uncommitted edit.
#
# WHAT CLAIM 2 DOES NOT COVER, stated rather than glossed: it runs on macOS
# only. portable/win/guest-build.cmd hardcodes its source share, so a second,
# pre-fix tree cannot be staged for the guest without editing a file this track
# does not own. On macOS only F7 has a POSIX branch to regress, so claim 2 here
# demonstrates F7's data loss and nothing else. The Windows halves of all three
# were measured by hand, once, by checking out the parent revision into the
# staging tree and running the same binary in the guest:
#
#   pre-fix, guest:  exit 1 — 6 failures
#     F7  a save refuses to run while the existing state is unreadable
#     F7  the user's recent files survived the save attempt
#     F7  the settings file is byte-for-byte what it was
#     F6  ensure_dir fails when a FILE occupies the directory name
#     F6  state_dir fails rather than returning a path that is not a directory
#     F5  mkstemp succeeds in a directory outside the ANSI code page
#   post-fix, guest: exit 0
#
# Reproduce with: git stash push -- portable/core/spdf_win_compat.c \
#   portable/win/src/spdf_win_state.{c,h} portable/win/src/spdf_win_paths.c
# then portable/win/sync-to-vm.sh and the vm-build.sh line below, then pop.
#
# THE RULE, inherited from t3-verify.sh and run-tests.sh: every verdict comes
# from an exit status recorded immediately after the command that produced it.
# No `set -e`, nothing piped into grep to decide pass or fail, and the exit
# status is computed from the records at the end.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="$REPO_ROOT/portable/win/build/t7"
VM_BUILD="$REPO_ROOT/portable/win/vm-build.sh"
SYNC="$REPO_ROOT/portable/win/sync-to-vm.sh"

# The revision to treat as "before". Defaults to the parent of HEAD, which is
# where the three fixes land; override to check against any other point.
BASE_REV="${SPDF_T7_BASE_REV:-HEAD~1}"

USE_VM=1
[[ "${1:-}" == "--no-vm" ]] && USE_VM=0

mkdir -p "$OUT/log" "$OUT/pre"

names=(); states=(); notes=()
record() { names+=("$1"); states+=("$2"); notes+=("$3"); }

TEST_SRC=portable/win/tests/silent_failure_test.c
TEST_HDR=portable/win/tests/silent_failure_support.h
MODULES=(portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c)
MAC_CFLAGS=(-std=c99 -O2 -Wall -Wextra -Werror "-I$REPO_ROOT/portable/core")

# --- 1. the current tree, natively -----------------------------------------

log="$OUT/log/mac-post.log"
( cd "$REPO_ROOT" && cc "${MAC_CFLAGS[@]}" -o "$OUT/silent_failure_test" \
    "$TEST_SRC" "${MODULES[@]}" ) > "$log" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
  record "mac.build" FAIL "cc exited $rc; see $log"
else
  record "mac.build" PASS "builds clean under -Werror"
  "$OUT/silent_failure_test" > "$OUT/log/mac-post.run.log" 2>&1
  rc=$?
  if [[ $rc -eq 0 ]]; then
    record "mac.current" PASS "the fixed sources pass natively"
  else
    record "mac.current" FAIL "exited $rc; see $OUT/log/mac-post.run.log"
  fi
fi

# --- 2. the pre-fix tree, natively: this MUST fail --------------------------
#
# Reconstructed with `git show` into a scratch tree that mirrors the repo layout
# the test's relative includes expect (../src/...).

pre="$OUT/pre"
rm -rf "$pre" && mkdir -p "$pre/portable/win/src" "$pre/portable/win/tests" "$pre/portable/core"
pre_ok=1
for f in portable/win/src/spdf_win_state.c portable/win/src/spdf_win_state.h \
         portable/win/src/spdf_win_paths.c portable/win/src/spdf_win_paths.h \
         portable/core/spdf_yaml.c portable/core/spdf_yaml.h \
         portable/core/spdf_win_compat.c portable/core/spdf_win_compat.h; do
  ( cd "$REPO_ROOT" && git show "$BASE_REV:$f" ) > "$pre/$f" 2>"$OUT/log/git-show.log"
  [[ $? -eq 0 ]] || pre_ok=0
done
# The test itself is the NEW one in both halves -- that is the whole point.
cp "$REPO_ROOT/$TEST_SRC" "$pre/portable/win/tests/"
cp "$REPO_ROOT/$TEST_HDR" "$pre/portable/win/tests/"

if [[ $pre_ok -ne 1 ]]; then
  record "mac.prefix" FAIL "could not reconstruct $BASE_REV; see $OUT/log/git-show.log"
else
  # No -Werror here: the point is to run the old code, not to grade it.
  ( cd "$pre" && cc -std=c99 -O2 -Wall -Wextra "-I$pre/portable/core" \
      -o "$pre/silent_failure_test_prefix" \
      portable/win/tests/silent_failure_test.c "${MODULES[@]}" ) \
      > "$OUT/log/mac-pre.log" 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    record "mac.prefix" FAIL "the pre-fix tree does not build the test; see $OUT/log/mac-pre.log"
  else
    "$pre/silent_failure_test_prefix" > "$OUT/log/mac-pre.run.log" 2>&1
    rc=$?
    if [[ $rc -ne 0 ]]; then
      record "mac.prefix" PASS "pre-fix sources FAIL the test (exit $rc), as they must"
    else
      record "mac.prefix" FAIL "pre-fix sources PASSED -- the test proves nothing"
    fi
  fi
fi

# --- 3. the guest ------------------------------------------------------------

if [[ $USE_VM -eq 0 ]]; then
  record "guest.current" BLOCKED "--no-vm"
else
  "$SYNC" > "$OUT/log/sync.log" 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    record "guest.current" BLOCKED "sync-to-vm.sh exited $rc; see $OUT/log/sync.log"
  else
    "$VM_BUILD" --run silent_failure_test "$TEST_SRC" "${MODULES[@]}" \
        portable/core/spdf_win_compat.c > "$OUT/log/guest.log" 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then
      record "guest.current" PASS "the fixed sources pass in the Windows guest"
    else
      record "guest.current" FAIL "exited $rc; see $OUT/log/guest.log"
    fi
  fi
fi

# --- report -----------------------------------------------------------------

printf '\n'
fail=0
blocked=0
for i in "${!names[@]}"; do
  printf '%-7s %-15s %s\n' "${states[$i]}" "${names[$i]}" "${notes[$i]}"
  [[ "${states[$i]}" == FAIL ]] && fail=1
  [[ "${states[$i]}" == BLOCKED ]] && blocked=1
done
printf '\n'
if [[ $fail -eq 1 ]]; then
  echo "t7-verify: FAILED"
  exit 1
fi
if [[ $blocked -eq 1 ]]; then
  echo "t7-verify: incomplete -- something could not run. This is NOT a pass."
  exit 2
fi
echo "t7-verify: all checks passed"
exit 0
