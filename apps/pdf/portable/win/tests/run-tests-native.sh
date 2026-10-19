#!/usr/bin/env bash
# The Windows port's test runner for a NATIVE Windows checkout. Git Bash, one
# machine, no Parallels, no prlctl, no \\Mac share.
#
#   portable/win/tests/run-tests-native.sh [--list] [--filter PAT]
#                                          [--self-check] [--keep] [--quiet]
#
# The sibling of run-tests.sh, which is a macOS-side orchestrator: it drives a VM
# over prlctl and compares against macOS reference renders the Mac produces. On a
# Windows box roughly half of that is meaningless and the other half is the part
# you want. Everything here builds and runs locally through
# portable/win/build-native.cmd.
#
# ---------------------------------------------------------------------------
# THE ONE THING THIS SCRIPT MUST GET RIGHT
#
# It must exit non-zero when a test fails. A harness that always exits 0 does not
# merely fail to help -- it silently blesses every broken change made after it,
# and every later track's "green" becomes meaningless. Three habits protect that,
# and none of them may be "simplified" away (portable/docs/windows-port-handoff.md
# section 2.6):
#   1. No `set -e`: an early exit would skip the aggregation entirely.
#   2. NOTHING is piped through grep/tee/head to decide pass or fail. A pipeline
#      reports the LAST command's status, so `prog | grep -c ok` is green when
#      prog crashes. Output goes to a file with `> log 2>&1`; the very next
#      statement reads $?.
#   3. Every case's status is recorded and the exit status is computed from the
#      records at the end -- never from whatever ran last.
#
# `harness.exit-code` proves 1-3 empirically -- a native binary that exits 3 and
# 42, and a source that cannot compile -- and `--self-check` proves the runner
# itself turns a failing case into a non-zero exit.
#
# HONEST DEGRADATION. A case whose prerequisites are missing is recorded BLOCKED,
# printed with the exact thing that is missing, and still makes the run exit
# non-zero -- exit 2 rather than 1, so "waiting on MuPDF" stays distinguishable
# from "the code is broken", but never zero. A harness that reported success
# because it could not run anything is the failure mode this file exists to
# prevent. While libmupdf.lib does not exist, a correct run of this script exits
# 2. Use --filter to work on one area; do not teach it to exit 0.
#
# NOT EVERY CASE CAN RUN HERE, AND THE ONES THAT CANNOT ARE STILL LISTED. The
# cross-host comparisons need a macOS host to build their reference; they are
# recorded BLOCKED with the reason, never dropped, because they are the port's
# strongest evidence and quietly losing them is how a port stops being checked.
# run-tests-native.d2d.sh adds four Windows-internal substitutes under their own
# d2d.compose-* names -- read its header before treating them as equivalent.
#
# WINDOWS NOTES. cmd.exe is invoked with MSYS2_ARG_CONV_EXCL='*' so MSYS leaves
# `/c` alone instead of rewriting it to `C:\`. This box may have
# NoDefaultCurrentDirectoryInExePath=1, so build-native.cmd is always addressed
# by absolute path -- and so must this script be, or `./run-tests-native.sh`.
# Paths handed to a native .exe go through `cygpath -w`.
#
# ADDING A TEST: drop `portable/win/tests/<name>_test.c` in this directory and it
# is discovered automatically as case `win.<name>_test`. Declare extras in the
# file itself; paths are repo-relative:
#
#     /* spdf-test-sources: portable/core/spdf_win_compat.c */
#     /* spdf-test-args: portable/win/tests/fixtures/golden.pdf */
#     /* spdf-test-needs: mupdf */
#     /* spdf-test-host: mac */      <- never built here
#
# portable/core/spdf_win_compat.c belongs in EVERY Windows source list: it is the
# POSIX shim shenzhen_pdf_core.c:5, spdf_yaml.c:6 and six core suites #include,
# and omitting it produces a wall of
# `LNK2019: unresolved external symbol spdf_compat_*` rather than an error at the
# file that wanted it. Its path is portable/core/, NOT portable/win/src/;
# run-tests.sh's own header comment gets that wrong.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TESTS_DIR="$REPO_ROOT/portable/win/tests"
CORE_TESTS="$REPO_ROOT/portable/core/tests"
OUT="$REPO_ROOT/portable/win/build/native"
BUILD_CMD="$REPO_ROOT/portable/win/build-native.cmd"
FIXTURE="portable/win/tests/fixtures/golden.pdf"

FILTER=""
LIST=0
KEEP=0
QUIET=0
SELF_CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) LIST=1; shift ;;
    --filter) FILTER="${2:-}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --self-check) SELF_CHECK=1; shift ;;
    -h|--help) sed -n '2,70p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "run-tests-native: unknown option $1" >&2; exit 64 ;;
  esac
done

mkdir -p "$OUT"

# record(), say(), selected(), declared(), declared_line(), log_tail() and
# mupdf_link_defect(). Its prlctl helpers are simply never called from here.
. "$TESTS_DIR/harness-lib.sh"

# --- the source lists ------------------------------------------------------

# Every core suite that touches a document pulls in shenzhen_pdf_core.h, which
# means shenzhen_pdf_core.c, which in turn needs spdf_selection.c,
# spdf_selection_support.c and spdf_recolor.c -- plus spdf_win_compat.c for the
# POSIX shim. Named once because eight call sites would otherwise drift.
CORE_SET="portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c"

# native_build(), native_run(), native_arg(), probe_native(), the shared
# ShenzhenPDF/spdf_win_probe targets, and the harness self-proof cases. Sourced
# after CORE_SET, which native_probe_build() uses.
. "$TESTS_DIR/run-tests-native.lib.sh"
# The Windows-internal Direct2D compose comparison.
. "$TESTS_DIR/run-tests-native.d2d.sh"
# The launch budget: window visible and first page painted inside a generous
# time, measured by portable/win/measure-launch.ps1 on the built exe. Beside
# it, launch.invariant (every launch leaves one usable window), launch.health
# (real input, checked against the launch-health.log the app writes about
# itself), window.stress (the UI thread still answering after twenty
# seconds of input and reloads) and dialog.open (the shell's Open dialog
# actually has pixels in it, and the process is not spinning while it is up).
. "$TESTS_DIR/run-tests-native.launch.sh"

# --- the app itself --------------------------------------------------------

# Not a unit test: the answer to "does the port still build?", which is the
# question every other track asks first.
case_app_build() {
  if [[ -n "$MUPDF_READY" ]]; then
    record "app.build" BLOCKED "$MUPDF_READY"
    return
  fi
  native_app_build
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    record "app.build" FAIL "ShenzhenPDF.exe does not build (build-native.cmd exited $rc)"
    log_tail "$OUT/app-build.log" 20
    return
  fi
  if [[ ! -s "$BUILD_DIR/ShenzhenPDF.exe" ]]; then
    record "app.build" FAIL "build-native.cmd returned 0 but $SPDF_OUT\\ShenzhenPDF.exe is missing"
    return
  fi
  record "app.build" PASS "ShenzhenPDF.exe links"
}

# --- core suites -----------------------------------------------------------

# Pure C over portable/core: free Windows conformance, and the reason this runner
# is worth having before any Windows UI is finished.
#
# Fields are name|needs|extra sources|arguments, separated by `|` rather than `:`
# because arguments contain drive letters. `-` in the needs field means the suite
# links no MuPDF and can run today.
#
# The first three mirror CORE_SUITES in run-tests.sh. The last five were written,
# are pure C over MuPDF, and were registered nowhere -- the handoff calls wiring
# them up the cheapest outstanding win in the port. (windows-port-qc.md 6.3 and
# portable/win/README.md both say "four" while listing five. It is five.)
CORE_SUITES=(
  "SPDFCoreRecolorTests|-|portable/core/spdf_recolor.c|"
  "SPDFCoreCompatTests|-|portable/core/spdf_win_compat.c|"
  "SPDFCoreSaveTests|mupdf|$CORE_SET|%SCRATCH%"
  "SPDFCoreOutlineTests|mupdf|$CORE_SET|"
  "SPDFCoreRenderThemeTests|mupdf|$CORE_SET|"
  "SPDFCoreSelectionTests|mupdf|$CORE_SET|"
  "SPDFCoreCJKSelectionTests|mupdf|$CORE_SET|"
  "SPDFCorePasswordTests|qpdf|$CORE_SET|%PASSWORD_FIXTURES%"
  "SPDFCoreMarkdownTests|-|portable/core/spdf_markdown.c portable/core/spdf_markdown_support.c portable/core/spdf_markdown_html.c portable/core/spdf_markdown_lang.c portable/core/spdf_markdown_lex.c portable/core/spdf_markdown_math.c portable/core/spdf_markdown_fences.c ext/md4c/md4c.c|"
  "SPDFCoreMarkdownCodeTests|-|portable/core/spdf_markdown.c portable/core/spdf_markdown_support.c portable/core/spdf_markdown_html.c portable/core/spdf_markdown_lang.c portable/core/spdf_markdown_lex.c portable/core/spdf_markdown_math.c portable/core/spdf_markdown_fences.c ext/md4c/md4c.c|"
)

field() { echo "$1" | cut -d'|' -f"$2"; }

# SPDFCorePasswordTests takes four fixtures that its own repository script builds
# with qpdf. Page 1 of the committed golden fixture is extracted as the plain
# source -- the suite requires a single-page document and golden.pdf has two --
# and the three encrypted variants are qpdf encryptions of exactly that file,
# which is what makes the suite's "renders identically to the plain source"
# assertions mean anything. Mirrors portable/core/tests/run_password_tests.sh.
PASSWORD_ARGS=""
password_fixtures() {
  local d="$BUILD_DIR/password-fixtures" f
  rm -rf "$d"
  mkdir -p "$d" || return 1
  qpdf --empty --pages "$REPO_ROOT/$FIXTURE" 1 -- "$d/plain.pdf" || return 1
  qpdf --encrypt user-secret owner-secret 256 -- "$d/plain.pdf" "$d/locked.pdf" || return 1
  qpdf --encrypt '' owner-secret 256 -- "$d/plain.pdf" "$d/owner-only.pdf" || return 1
  qpdf --encrypt view-secret owner-secret 256 --print=low --extract=n --modify=none -- \
      "$d/plain.pdf" "$d/restricted.pdf" || return 1
  PASSWORD_ARGS=""
  for f in plain locked owner-only restricted; do
    [[ -s "$d/$f.pdf" ]] || return 1
    PASSWORD_ARGS="$PASSWORD_ARGS $(cygpath -w "$d/$f.pdf")"
  done
  return 0
}

core_blocker() {
  case "$1" in
    -) echo "$NATIVE_READY" ;;
    mupdf) echo "$MUPDF_READY" ;;
    qpdf) echo "$QPDF_READY" ;;
  esac
}

case_core_suites() {
  local entry name need srcs args log rc blocker a
  for entry in "${CORE_SUITES[@]}"; do
    name="$(field "$entry" 1)"
    selected "core.$name" || continue
    need="$(field "$entry" 2)"
    srcs="$(field "$entry" 3)"
    args="$(field "$entry" 4)"
    blocker="$(core_blocker "$need")"
    if [[ -n "$blocker" ]]; then
      record "core.$name" BLOCKED "$blocker"
      continue
    fi
    if [[ ! -f "$CORE_TESTS/$name.c" ]]; then
      record "core.$name" BLOCKED "portable/core/tests/$name.c does not exist"
      continue
    fi
    if [[ "$args" == '%PASSWORD_FIXTURES%' ]]; then
      password_fixtures
      if [[ $? -ne 0 ]]; then
        record "core.$name" BLOCKED "qpdf could not build the encrypted fixtures"
        continue
      fi
      args="$PASSWORD_ARGS"
    fi
    log="$OUT/core-$name.log"
    # srcs is a deliberate space-separated list
    # shellcheck disable=SC2086
    native_build "$log" "$name" "portable/core/tests/$name.c" $srcs
    rc=$?
    if [[ $rc -ne 0 ]]; then
      if mupdf_link_defect "$log"; then
        record "core.$name" BLOCKED "libmupdf.lib itself fails to link -- toolchain track"
      else
        record "core.$name" FAIL "does not build (build-native.cmd exited $rc)"
        log_tail "$log" 20
      fi
      continue
    fi
    local -a run_args=()
    for a in $args; do run_args+=("$(native_arg "$a")"); done
    native_run "$OUT/core-$name.run.log" "$name" "${run_args[@]+"${run_args[@]}"}"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      record "core.$name" PASS "passes natively"
    else
      record "core.$name" FAIL "exited $rc"
      log_tail "$OUT/core-$name.run.log" 20
    fi
  done
}

# --- per-track Windows tests -----------------------------------------------

# Extra translation units for tests whose own header documents the link line in
# prose rather than in a machine-readable `spdf-test-sources` comment. The
# in-file declaration always wins; this table only fills the gap, so a track's
# suite is registered without anyone editing that track's files. Kept identical
# to WIN_TEST_EXTRA in run-tests.sh -- change one, change both.
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

case_win_tests() {
  local f stem extra args need log rc a
  for f in "$TESTS_DIR"/*_test.c; do
    [[ -e "$f" ]] || continue
    stem="$(basename "$f" .c)"
    # A host-only source must never reach MSVC: it would fail for a reason that
    # has nothing to do with the code under test.
    [[ "$(declared spdf-test-host "$f")" == mac ]] && continue
    selected "win.$stem" || continue
    extra="$(declared spdf-test-sources "$f")"
    [[ -n "$extra" ]] || extra="$(win_test_extra "$stem")"
    args="$(declared spdf-test-args "$f")"
    need="$(declared spdf-test-needs "$f")"
    if [[ -n "$NATIVE_READY" ]]; then
      record "win.$stem" BLOCKED "$NATIVE_READY"
      continue
    fi
    if [[ "$need" == *mupdf* && -n "$MUPDF_READY" ]]; then
      record "win.$stem" BLOCKED "$MUPDF_READY"
      continue
    fi
    log="$OUT/win-$stem.log"
    # extra is a deliberate space-separated list
    # shellcheck disable=SC2086
    native_build "$log" "$stem" "portable/win/tests/$(basename "$f")" $extra
    rc=$?
    if [[ $rc -ne 0 ]]; then
      if mupdf_link_defect "$log"; then
        record "win.$stem" BLOCKED "libmupdf.lib itself fails to link -- toolchain track"
      else
        record "win.$stem" FAIL "does not build (build-native.cmd exited $rc); if it needs extra translation units, declare them with /* spdf-test-sources: ... */"
        log_tail "$log" 20
      fi
      continue
    fi
    local -a run_args=()
    for a in $args; do run_args+=("$(native_arg "$a")"); done
    native_run "$OUT/win-$stem.run.log" "$stem" "${run_args[@]+"${run_args[@]}"}"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      record "win.$stem" PASS "passes natively"
    elif [[ $rc -eq 68 ]]; then
      # 68 is the desktop tests' "I could not run here at all" -- a locked
      # workstation, no window station. The same code run-tests-native.launch.sh
      # already uses. BLOCKED, so the suite still exits non-zero: a case that
      # could not open a window has proved nothing.
      record "win.$stem" BLOCKED "the test needs an interactive desktop and exited 68; unlock the workstation and re-run"
      log_tail "$OUT/win-$stem.run.log" 5
    else
      record "win.$stem" FAIL "exited $rc"
      log_tail "$OUT/win-$stem.run.log" 20
    fi
  done
}

# --- cases this host cannot decide -----------------------------------------

# Recorded, not dropped. These compare the two platforms against each other, and
# the reference side is not a committed image: d2d-cases.sh and probe-cases.sh
# compile portable/win/spdf_win_probe.c with `cc` on the Mac at test time. So
# every one of them needs a macOS host, and each note says so rather than
# implying an image went missing.
CROSS_HOST=(
  "layout.differential|needs glib and the GTK4 headers to build portable/win/tests/gtk_differential.c against the original it was transcribed from; macOS or Linux host"
  "probe.png|needs a macOS host to build and run the reference probe over $FIXTURE; no reference image is committed"
  "alpha.png|needs a macOS host to build and run the reference probe over portable/win/tests/fixtures/alpha.pdf -- the only fixture that can fire the premultiplied-alpha and halo detectors, since an ordinary PDF render is fully opaque (QC F8)"
  "d2d.exact-plain|needs a macOS host to build the reference probe; d2d.compose-plain is the Windows-internal substitute and proves strictly less"
  "d2d.exact-dark|needs a macOS host to build the reference probe; d2d.compose-dark is the Windows-internal substitute and proves strictly less"
  "d2d.window-plain|needs a macOS host to build the reference probe; d2d.compose-window-plain is the Windows-internal substitute and proves strictly less"
  "d2d.window-dark|needs a macOS host to build the reference probe; d2d.compose-window-dark is the Windows-internal substitute and proves strictly less"
)

case_cross_host() {
  local entry name
  for entry in "${CROSS_HOST[@]}"; do
    name="$(field "$entry" 1)"
    selected "$name" || continue
    record "$name" BLOCKED "$(field "$entry" 2). Run it from macOS with portable/win/tests/run-tests.sh, or commit the references."
  done
}

# --- drive -----------------------------------------------------------------

if [[ $LIST -eq 1 ]]; then
  printf '%s\n' harness.exit-code harness.non-ascii-path selftest.compare-png app.build
  for e in "${CORE_SUITES[@]}"; do echo "core.$(field "$e" 1)"; done
  for f in "$TESTS_DIR"/*_test.c; do
    [[ -e "$f" ]] || continue
    [[ "$(declared spdf-test-host "$f")" == mac ]] && continue
    echo "win.$(basename "$f" .c)"
  done
  printf '%s\n' "${D2D_NATIVE_CASES[@]}"
  [[ ${#LAUNCH_NATIVE_CASES[@]} -gt 0 ]] && printf '%s\n' "${LAUNCH_NATIVE_CASES[@]}"
  for e in "${CROSS_HOST[@]}"; do field "$e" 1; done
  exit 0
fi

if [[ $SELF_CHECK -eq 1 ]]; then
  echo "== run-tests-native self-check: a failing case must produce a non-zero exit =="
  SPDF_FORCE_FAIL=1 "${BASH_SOURCE[0]}" --filter harness.forced-failure --quiet > "$OUT/self-check.log" 2>&1
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "SELF-CHECK FAILED: the runner exited 0 with a failing case. Do not trust any result from it." >&2
    exit 1
  fi
  echo "   ok: injected failure produced exit $rc"
  echo
fi

probe_native

say "run-tests-native: repo $REPO_ROOT"
say "run-tests-native: build output $SPDF_OUT, results $OUT"
[[ -n "$NATIVE_READY" ]] && say "run-tests-native: TOOLCHAIN UNAVAILABLE -- $NATIVE_READY"
[[ -z "$NATIVE_READY" && -n "$MUPDF_READY" ]] && say "run-tests-native: no MuPDF -- $MUPDF_READY"
say

selected harness.exit-code && case_exit_code
selected harness.forced-failure && case_forced_failure
selected harness.non-ascii-path && case_non_ascii_path
selected selftest.compare-png && case_compare_png_selftest
selected app.build && case_app_build
case_core_suites
case_win_tests
selected d2d.compose-plain && case_d2d_compose_plain
selected d2d.compose-dark && case_d2d_compose_dark
selected d2d.compose-window-plain && case_d2d_compose_window_plain
selected d2d.compose-window-dark && case_d2d_compose_window_dark
selected launch.budget && case_launch_budget
selected window.stress && case_window_stress
selected launch.invariant && case_launch_invariant
selected launch.health && case_launch_health
selected dialog.open && case_dialog_open
case_cross_host

if [[ ${#names[@]} -eq 0 ]]; then
  # A filter that matches nothing must never look like a clean run.
  echo "run-tests-native: NOTHING RAN (filter '$FILTER') -- refusing to report success"
  exit 3
fi

fails=0
blocked=0
passes=0
echo "== results =="
for i in "${!names[@]}"; do
  printf '  %-8s %-34s %s\n' "${states[$i]}" "${names[$i]}" "${notes[$i]}"
  case "${states[$i]}" in
    FAIL) fails=$((fails + 1)) ;;
    BLOCKED) blocked=$((blocked + 1)) ;;
    PASS) passes=$((passes + 1)) ;;
  esac
done

echo
echo "run-tests-native: ${#names[@]} cases, $passes passed, $fails failed, $blocked blocked"
[[ $KEEP -eq 1 ]] || rm -f "$OUT"/exit-probe-*.log "$OUT"/toolchain-probe.log
if [[ $fails -gt 0 ]]; then
  echo "run-tests-native: FAILED"
  exit 1
fi
if [[ $blocked -gt 0 ]]; then
  echo "run-tests-native: BLOCKED -- $blocked case(s) could not run. This is NOT a pass."
  exit 2
fi
echo "run-tests-native: OK"
exit 0
