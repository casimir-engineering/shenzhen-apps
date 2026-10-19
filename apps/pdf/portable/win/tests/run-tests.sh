#!/usr/bin/env bash
# The Windows port's headless test runner. Runs from macOS; never opens the VM's
# desktop, never launches the macOS app.
#
#   portable/win/tests/run-tests.sh [--list] [--filter PAT] [--self-check]
#                                   [--wait-for-toolchain SECONDS] [--keep] [--quiet]
#
# ---------------------------------------------------------------------------
# THE ONE THING THIS SCRIPT MUST GET RIGHT
#
# It must exit non-zero when a Windows test fails. A harness that always exits 0
# does not merely fail to help -- it silently blesses every broken change made
# after it, and every later track's "green" becomes meaningless. Everything else
# here is secondary to that.
#
# Three habits protect it, and none of them may be "simplified" away:
#   1. No `set -e`: an early exit would skip the aggregation entirely.
#   2. NOTHING is piped through grep/tee/head to decide pass or fail. A pipeline
#      reports the LAST command's status, so `prog | grep -c ok` is green when
#      prog crashes. Output goes to a file with `> log 2>&1`; the very next
#      statement reads $?.
#   3. Every case's status is recorded and the exit status is computed from the
#      records at the end -- never from whatever ran last.
#
# The `harness.exit-code` case proves point 1-3 empirically by running a guest
# binary that deliberately exits 3 and 42, and `--self-check` proves the runner
# itself turns a failing case into a non-zero exit.
#
# ---------------------------------------------------------------------------
# HONEST DEGRADATION
#
# The guest toolchain is being built by another track while this runs. A case
# whose prerequisites are missing is recorded BLOCKED, printed with the exact
# thing that is missing, and still makes the run exit non-zero -- exit 2 rather
# than 1, so "waiting on the toolchain" is distinguishable from "the code is
# broken", but never zero. A harness that reports success because it could not
# run anything is the failure mode this whole file exists to prevent.
#
# GUEST NOTES: `prlctl exec` runs as nt authority\system, where the interactive
# user's Z: drive does not exist -- address the staging tree by UNC path. The
# guest has no head/grep/tail; use findstr if you must filter guest-side, but
# prefer bringing output back and deciding here. The macOS shell expands $ inside
# double quotes and cmd.exe uses %, so guest command lines are assembled from
# SINGLE-quoted fragments.
#
# NOT EVERY CASE RUNS IN THE GUEST. `layout.differential` and the D2D render
# comparisons are decided on the Mac. The differential links glib, which will
# never exist in the Windows guest; the D2D cases compare the guest's rendered
# PNGs against the macOS reference, which only the Mac has. Host-side cases are
# still cases: they are recorded, they gate, and a missing prerequisite is
# BLOCKED rather than skipped.
#
# ADDING A TEST: drop `portable/win/tests/<name>_test.c` here and it is
# discovered automatically. Declare extra translation units, runtime arguments
# and prerequisites in the file itself; paths are repo-relative and an argument
# naming a repo path is rewritten to the guest's copy:
#
#     /* spdf-test-sources: portable/core/spdf_win_compat.c */
#     /* spdf-test-args: portable/win/tests/fixtures/golden.pdf */
#     /* spdf-test-needs: mupdf */
#     /* spdf-test-host: mac */      <- never built in the guest
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TESTS_DIR="$REPO_ROOT/portable/win/tests"
OUT="$REPO_ROOT/portable/win/build/t4"
VM_NAME="${SPDF_VM_NAME:-Windows 11}"
STAGE="${SPDF_WIN_STAGE:-$HOME/Documents/spdf-win}"
VM_BUILD="$REPO_ROOT/portable/win/vm-build.sh"
FIXTURE="portable/win/tests/fixtures/golden.pdf"

# Guest-side constants. Single-quoted: backslashes and % must survive verbatim.
GUEST_TREE='C:\spdf'
GUEST_OUT='C:\spdf-build'
GUEST_SHARE='\\Mac\Home\Documents\spdf-win'
# The drop box the guest writes results into. portable/win/build/ is excluded
# from sync-to-vm.sh's rsync, so it is never deleted out from under a run.
GUEST_DROP="$GUEST_SHARE"'\portable\win\build\t4'

FILTER=""
LIST=0
KEEP=0
QUIET=0
SELF_CHECK=0
WAIT_SECS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) LIST=1; shift ;;
    --filter) FILTER="${2:-}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --self-check) SELF_CHECK=1; shift ;;
    --wait-for-toolchain) WAIT_SECS="${2:-0}"; shift 2 ;;
    -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "run-tests: unknown option $1" >&2; exit 64 ;;
  esac
done

mkdir -p "$OUT" "$STAGE/portable/win/build/t4"

# Guest plumbing, result recording and prerequisite discovery.
. "$TESTS_DIR/harness-lib.sh"

# --- cases -----------------------------------------------------------------

case_compare_png_selftest() {
  local log="$OUT/compare-png-selftest.log"
  # bash 3.2 (the macOS system bash) errors on "${arr[@]}" for an empty array
  # under `set -u`, so the decode argument is carried as a plain string.
  local extra=""
  [[ -f "$OUT/mac/probe-page.png" ]] && extra="--decode $OUT/mac/probe-page.png"
  # shellcheck disable=SC2086
  python3 "$TESTS_DIR/compare_png_selftest.py" $extra > "$log" 2>&1
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    record "selftest.compare-png" PASS "every golden-image detector fired correctly"
  else
    record "selftest.compare-png" FAIL "comparator self-test exited $rc"
    log_tail "$log" 14
  fi
}

# The layout port's differential against the GTK4 original it was transcribed
# from. macOS-side, glib-linked, and the single case that gates a layout edit.
. "$TESTS_DIR/differential-cases.sh"

# The proof that the whole chain is honest, run before anything that depends on
# it. Every assertion here is about an exit STATUS, never about output text.
case_exit_code() {
  if [[ -n "$GUEST_READY" ]]; then
    record "harness.exit-code" BLOCKED "$GUEST_READY"
    return
  fi

  guest "$OUT/exit0.log" 'exit /b 0'; local rc0=$?
  guest "$OUT/exit7.log" 'exit /b 7'; local rc7=$?
  if [[ $rc0 -ne 0 || $rc7 -ne 7 ]]; then
    record "harness.exit-code" FAIL "prlctl exec does not propagate guest exit codes (got $rc0 for 0, $rc7 for 7)"
    return
  fi

  vm_build "$OUT/never-compiles.log" spdf_never_compiles portable/win/tests/never_compiles.c
  local rcbad=$?
  if [[ $rcbad -eq 0 ]]; then
    record "harness.exit-code" FAIL "vm-build.sh returned 0 for a source that cannot compile -- a broken Windows build would look green"
    return
  fi

  vm_build "$OUT/exit-probe-build.log" spdf_exit_code_probe portable/win/tests/exit_code_probe.c
  local rcb=$?
  if [[ $rcb -ne 0 ]]; then
    record "harness.exit-code" FAIL "could not build the exit-code canary (vm-build exited $rcb)"
    log_tail "$OUT/exit-probe-build.log"
    return
  fi

  local want got
  for want in 0 3 42; do
    guest "$OUT/exit-probe-$want.log" "$GUEST_OUT"'\spdf_exit_code_probe.exe '"$want"
    got=$?
    if [[ $got -ne $want ]]; then
      record "harness.exit-code" FAIL "a guest binary exiting $want was seen as $got on the Mac"
      return
    fi
  done
  record "harness.exit-code" PASS "guest exit codes 0/3/42 and a failed compile all reach the Mac intact"
}

# Only meaningful under --self-check, which re-runs this script with the env var
# set and asserts the outer exit status is non-zero. Without it, a runner bug
# that swallowed failures would be invisible to the runner's own suite.
case_forced_failure() {
  if [[ "${SPDF_FORCE_FAIL:-0}" != "1" ]]; then
    return
  fi
  record "harness.forced-failure" FAIL "deliberate failure injected by --self-check"
}

# The guest's ANSI code page is 1252, not UTF-8, and Windows narrows the real
# UTF-16 command line to it on the way into `char** argv`. A harness that assumed
# UTF-8 would hand the guest a path it cannot open and then blame the code under
# test -- which is how a real failure in this port was first mis-diagnosed. So
# the assumption is checked rather than believed, and the observed bytes are
# reported on every run.
case_non_ascii_path() {
  if [[ -n "$GUEST_READY" ]]; then
    record "harness.non-ascii-path" BLOCKED "$GUEST_READY"
    return
  fi
  vm_build "$OUT/narrow-path-build.log" narrow_path_probe portable/win/tests/narrow_path_probe.c
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    record "harness.non-ascii-path" FAIL "the narrow-path probe does not build in the guest (vm-build exited $rc)"
    log_tail "$OUT/narrow-path-build.log" 20
    return
  fi
  guest_ps "$OUT/narrow-path.log" non_ascii_path.ps1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    record "harness.non-ascii-path" FAIL "a path containing a non-ASCII character could not be opened in the guest (exit $rc)"
    log_tail "$OUT/narrow-path.log" 12
    return
  fi
  # Reporting the bytes, not asserting them: the code page is a property of the
  # guest, and pinning 0xE9 here would turn a differently configured Windows
  # into a spurious failure. Seeing C3 A9 instead would mean UTF-8 leaked in.
  local bytes
  bytes="$(declared_line 'argv1-bytes' "$OUT/narrow-path.log")"
  record "harness.non-ascii-path" PASS "narrow argv round-trips a non-ASCII path (${bytes:-bytes not captured})"
}

# The cross-host probe pipeline: probe.* over the opaque golden fixture, and
# alpha.* over the transparent one, which is the only comparison in the suite
# that can exercise the comparator's premultiplied-alpha and halo detectors.
. "$TESTS_DIR/probe-cases.sh"

# The Direct2D compose comparison (QC F3). Sourced after probe-cases.sh, whose
# probe_mac_build() produces the macOS reference these cases compare against.
. "$TESTS_DIR/d2d-cases.sh"

# Core suites that already exist as pure C over portable/core: free Windows
# conformance the moment the guest can compile them, and the reason this runner
# is worth having before any Windows UI exists at all.
#
# Fields are name|needs|extra sources|arguments, separated by `|` rather than
# `:` because guest arguments contain drive letters. `-` in the needs field
# means the suite links no MuPDF and can therefore run in the guest today.
# Everything runs with the working directory set to a scratch folder, so a suite
# that leaks a temp file into the CWD -- which is exactly what SPDFCoreSaveTests
# is checking for -- sees it where it expects to.
CORE_SUITES=(
  "SPDFCoreRecolorTests|-|portable/core/spdf_recolor.c|"
  "SPDFCoreCompatTests|-|portable/core/spdf_win_compat.c|"
  "SPDFCoreSaveTests|mupdf|portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c|%SCRATCH%"
)

field() { echo "$1" | cut -d'|' -f"$2"; }

case_core_suites() {
  local entry name need srcs args log rc
  for entry in "${CORE_SUITES[@]}"; do
    name="$(field "$entry" 1)"
    need="$(field "$entry" 2)"
    srcs="$(field "$entry" 3)"
    args="$(field "$entry" 4)"
    selected "core.$name" || continue
    if [[ -n "$GUEST_READY" ]]; then
      record "core.$name" BLOCKED "$GUEST_READY"
      continue
    fi
    if [[ "$need" == "mupdf" && -n "$GUEST_MUPDF" ]]; then
      record "core.$name" BLOCKED "$GUEST_MUPDF"
      continue
    fi
    log="$OUT/core-$name.log"
    # srcs is a deliberate space-separated list
    # shellcheck disable=SC2086
    vm_build "$log" "$name" "portable/core/tests/$name.c" $srcs
    rc=$?
    if [[ $rc -ne 0 ]]; then
      if mupdf_link_defect "$log"; then
        record "core.$name" BLOCKED "libmupdf.lib itself fails to link in the guest (LNK2048 in hyphen.obj) -- toolchain track"
      else
        record "core.$name" FAIL "does not build in the guest (vm-build exited $rc)"
        log_tail "$log" 20
      fi
      continue
    fi
    guest_run "$OUT/core-$name.run.log" "$name" "${args//%SCRATCH%/$GUEST_SCRATCH}"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      record "core.$name" PASS "passes in the guest"
    else
      record "core.$name" FAIL "exited $rc in the guest"
      log_tail "$OUT/core-$name.run.log" 20
    fi
  done
}

# Extra translation units for tests whose own header documents the link line in
# prose rather than in a machine-readable `spdf-test-sources` comment. The
# in-file declaration always wins; this table only fills the gap so a track's
# suite is registered here without anyone having to edit that track's files.
WIN_TEST_EXTRA=(
  "paths_test|portable/win/src/spdf_win_paths.c"
  "state_test|portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c portable/core/spdf_win_compat.c"
)

win_test_extra() {
  local entry
  for entry in "${WIN_TEST_EXTRA[@]}"; do
    if [[ "$(field "$entry" 1)" == "$1" ]]; then
      field "$entry" 2
      return
    fi
  done
}

# Auto-discovered per-track tests. See the ADDING A TEST note in the header.
case_win_tests() {
  local f stem extra args need log rc guest_args
  for f in "$TESTS_DIR"/*_test.c; do
    [[ -e "$f" ]] || continue
    stem="$(basename "$f" .c)"
    # A host-only source must never reach the guest compiler. Nothing declares
    # this today -- gtk_differential.c stays out by not being named *_test.c --
    # but the next host-only file that IS named *_test.c would otherwise be
    # handed to MSVC and fail for a reason that has nothing to do with the code.
    [[ "$(declared spdf-test-host "$f")" == mac ]] && continue
    selected "win.$stem" || continue
    extra="$(declared spdf-test-sources "$f")"
    [[ -n "$extra" ]] || extra="$(win_test_extra "$stem")"
    args="$(declared spdf-test-args "$f")"
    need="$(declared spdf-test-needs "$f")"
    if [[ -n "$GUEST_READY" ]]; then
      record "win.$stem" BLOCKED "$GUEST_READY"
      continue
    fi
    if [[ "$need" == *mupdf* && -n "$GUEST_MUPDF" ]]; then
      record "win.$stem" BLOCKED "$GUEST_MUPDF"
      continue
    fi
    log="$OUT/win-$stem.log"
    # extra is a deliberate space-separated list
    # shellcheck disable=SC2086
    vm_build "$log" "$stem" "portable/win/tests/$(basename "$f")" $extra
    rc=$?
    if [[ $rc -ne 0 ]]; then
      if mupdf_link_defect "$log"; then
        record "win.$stem" BLOCKED "libmupdf.lib itself fails to link in the guest (LNK2048 in hyphen.obj) -- toolchain track"
      else
        record "win.$stem" FAIL "does not build in the guest (vm-build exited $rc); if it needs extra translation units, declare them with /* spdf-test-sources: ... */"
        log_tail "$log" 20
      fi
      continue
    fi
    guest_args=""
    for a in $args; do
      if [[ -f "$REPO_ROOT/$a" ]]; then
        guest_args="$guest_args \"$GUEST_TREE\\${a//\//\\}\""
      else
        guest_args="$guest_args $a"
      fi
    done
    guest_run "$OUT/win-$stem.run.log" "$stem" "$guest_args"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      record "win.$stem" PASS "passes in the guest"
    else
      record "win.$stem" FAIL "exited $rc in the guest"
      log_tail "$OUT/win-$stem.run.log" 20
    fi
  done
}

# --- drive -----------------------------------------------------------------

if [[ $LIST -eq 1 ]]; then
  printf '%s\n' selftest.compare-png layout.differential harness.exit-code harness.non-ascii-path \
      probe.mac probe.win probe.diff probe.png \
      alpha.mac alpha.win alpha.diff alpha.png \
      d2d.exact-plain d2d.exact-dark d2d.window-plain d2d.window-dark \
      'core.<suite>' 'win.<name>_test'
  exit 0
fi

if [[ $SELF_CHECK -eq 1 ]]; then
  echo "== run-tests self-check: a failing case must produce a non-zero exit =="
  SPDF_FORCE_FAIL=1 "${BASH_SOURCE[0]}" --filter harness.forced-failure --quiet > "$OUT/self-check.log" 2>&1
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "SELF-CHECK FAILED: the runner exited 0 with a failing case. Do not trust any result from it." >&2
    exit 1
  fi
  echo "   ok: injected failure produced exit $rc"
  echo
fi

[[ "$WAIT_SECS" -gt 0 ]] && wait_for_toolchain
probe_guest

say "run-tests: repo $REPO_ROOT"
say "run-tests: vm '$VM_NAME', stage $STAGE, results $OUT"
[[ -n "$GUEST_READY" ]] && say "run-tests: GUEST UNAVAILABLE -- $GUEST_READY"
[[ -z "$GUEST_READY" && -n "$GUEST_MUPDF" ]] && say "run-tests: no guest MuPDF -- $GUEST_MUPDF"
say

selected selftest.compare-png && case_compare_png_selftest
selected layout.differential && case_layout_differential
selected harness.exit-code && case_exit_code
selected harness.forced-failure && case_forced_failure
selected harness.non-ascii-path && case_non_ascii_path
selected probe.mac && case_probe_mac
selected probe.win && case_probe_win
selected probe.diff && case_probe_diff
selected probe.png && case_probe_png
selected alpha.mac && case_alpha_mac
selected alpha.win && case_alpha_win
selected alpha.diff && case_alpha_diff
selected alpha.png && case_alpha_png
selected d2d.exact-plain && case_d2d_exact_plain
selected d2d.exact-dark && case_d2d_exact_dark
selected d2d.window-plain && case_d2d_window_plain
selected d2d.window-dark && case_d2d_window_dark
case_core_suites
case_win_tests

if [[ ${#names[@]} -eq 0 ]]; then
  # A filter that matches nothing must never look like a clean run.
  echo "run-tests: NOTHING RAN (filter '$FILTER') -- refusing to report success"
  exit 3
fi

fails=0
blocked=0
echo "== results =="
for i in "${!names[@]}"; do
  printf '  %-8s %-28s %s\n' "${states[$i]}" "${names[$i]}" "${notes[$i]}"
  case "${states[$i]}" in
    FAIL) fails=$((fails + 1)) ;;
    BLOCKED) blocked=$((blocked + 1)) ;;
  esac
done

echo
echo "run-tests: ${#names[@]} cases, $fails failed, $blocked blocked"
[[ $KEEP -eq 1 ]] || rm -f "$OUT"/exit*.log "$OUT"/guest-probe.log
if [[ $fails -gt 0 ]]; then
  echo "run-tests: FAILED"
  exit 1
fi
if [[ $blocked -gt 0 ]]; then
  echo "run-tests: BLOCKED -- $blocked case(s) could not run. This is NOT a pass."
  exit 2
fi
echo "run-tests: OK"
exit 0
