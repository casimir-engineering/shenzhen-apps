#!/usr/bin/env bash
# Plumbing for portable/win/tests/run-tests-native.sh: how a target is built and
# run on a native Windows box, how prerequisites are discovered, and the three
# cases that prove the harness itself is honest.
#
# Split from run-tests-native.sh so that file can stay about WHAT is tested while
# this one stays about HOW the toolchain is driven, and so both remain under the
# repo's 500-line cap (tools/file-size-limits.md). Sourced, never executed. The
# same division as run-tests.sh / harness-lib.sh, whose record(), say(),
# selected(), declared(), declared_line(), log_tail() and mupdf_link_defect()
# this file also relies on -- harness-lib.sh must be sourced first.
#
# THE RULE THAT GOVERNS THIS FILE: nothing here may stand between a build or a
# binary and its exit status. native_build() and native_run() are deliberately
# as dumb as a function can be -- a redirect, then `return $?` -- because every
# piece of cleverness added here is a place a Windows failure could be
# swallowed, and a swallowed failure makes the entire port's test story a lie.
#
# Unlike harness-lib.sh, this file may use bash 4 features: it runs on Git Bash
# (bash 5), never on the macOS system bash 3.2.

# --- native plumbing -------------------------------------------------------

# Build output lives outside the checkout, matching build-native.cmd and
# guest-build.cmd, so a clean or a sync can never delete it. Normalised to a
# Windows path because that is what the .cmd consumes, and mirrored as a POSIX
# path because that is what bash consumes.
SPDF_OUT="$(cygpath -w "${SPDF_OUT:-C:\\spdf-build}" 2>/dev/null || echo 'C:\spdf-build')"
export SPDF_OUT
BUILD_DIR="$(cygpath -u "$SPDF_OUT")"

# Where libmupdf lives. Derived from SPDF_OUT by default -- the two normally sit
# side by side -- but overridable, because SPDF_OUT is ALSO where this run writes
# its own binaries. Isolating a run from a concurrent build means pointing
# SPDF_OUT somewhere private, and without this override that would also hide
# MuPDF and BLOCK every case that links it. Measured: two agents building into
# the same C:\spdf-build at once produced five spurious "does not build"
# failures, because the exe under test was replaced mid-run.
SPDF_MUPDF_LIBDIR="${SPDF_MUPDF_LIBDIR:-$SPDF_OUT\\mupdf}"
export SPDF_MUPDF_LIBDIR
MUPDF_LIB_DIR="$(cygpath -u "$SPDF_MUPDF_LIBDIR" 2>/dev/null || echo "$BUILD_DIR/mupdf")"

SCRATCH="$BUILD_DIR/scratch-native"
SCRATCH_WIN="$SPDF_OUT\\scratch-native"
BUILD_CMD_WIN="$(cygpath -w "$BUILD_CMD" 2>/dev/null || echo "$BUILD_CMD")"

# Build one target through build-native.cmd, whose exit code IS cl.exe's.
#
# MSYS2_ARG_CONV_EXCL='*' is load-bearing: without it MSYS rewrites the `/c`
# argument to `C:\` on its way into cmd.exe, and the failure looks like a broken
# batch script rather than the argument mangling it is. Source paths stay
# repo-relative, which MSYS leaves alone.
native_build() {
  local log="$1" target="$2"
  shift 2
  MSYS2_ARG_CONV_EXCL='*' cmd.exe /c "$BUILD_CMD_WIN" "$target" "$@" > "$log" 2>&1
  return $?
}

# Run a built target from a scratch working directory, with arguments.
#
# The working directory matters: a suite that checks nothing was leaked into the
# CWD -- which is exactly what SPDFCoreSaveTests is checking for -- has to run
# somewhere it can see that, and never in the build output directory.
native_run() {
  local log="$1" target="$2"
  shift 2
  mkdir -p "$SCRATCH"
  ( cd "$SCRATCH" && "$BUILD_DIR/$target.exe" "$@" ) > "$log" 2>&1
  return $?
}

# Rewrite one declared argument for a native binary: a repo-relative path
# becomes an absolute WINDOWS path, anything else passes through untouched. A
# POSIX path would reach the CRT as a filename that does not exist, and the
# resulting failure would be blamed on the code under test.
native_arg() {
  case "$1" in
    '%SCRATCH%') echo "$SCRATCH_WIN" ;;
    *) if [[ -e "$REPO_ROOT/$1" ]]; then cygpath -w "$REPO_ROOT/$1"; else echo "$1"; fi ;;
  esac
}

# --- prerequisites ---------------------------------------------------------

NATIVE_READY=""   # empty = usable; otherwise the reason it is not
MUPDF_READY=""
QPDF_READY=""

probe_native() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) NATIVE_READY="this runner needs a native Windows shell (Git Bash); uname reports $(uname -s). Use portable/win/tests/run-tests.sh from macOS." ;;
  esac
  if [[ -z "$NATIVE_READY" && ! -f "$BUILD_CMD" ]]; then
    NATIVE_READY="portable/win/build-native.cmd is missing"
  fi
  if [[ -z "$NATIVE_READY" ]] && ! command -v cmd.exe > /dev/null 2>&1; then
    NATIVE_READY="cmd.exe is not on PATH"
  fi
  if [[ -z "$NATIVE_READY" ]]; then
    # One real compile answers "is there a toolchain?" better than any amount of
    # directory probing. build-native.cmd reports 91/92 for a missing or broken
    # vcvarsall and cl.exe's own code for anything else.
    native_build "$OUT/toolchain-probe.log" spdf_native_toolchain_probe portable/win/tests/exit_code_probe.c
    local rc=$?
    case $rc in
      0) ;;
      91|92) NATIVE_READY="no usable MSVC toolchain (build-native.cmd exited $rc; see $OUT/toolchain-probe.log). Install the VS 2022 C++ build tools, or set SPDF_VCVARS." ;;
      *) NATIVE_READY="the toolchain probe does not build (build-native.cmd exited $rc; see $OUT/toolchain-probe.log)" ;;
    esac
  fi

  MUPDF_READY="$NATIVE_READY"
  QPDF_READY="$NATIVE_READY"
  [[ -n "$MUPDF_READY" ]] && return
  # Headers and libraries arrive from two different steps of the toolchain
  # track's work, so they are reported separately: the difference between "wait"
  # and "go and fix something" is worth naming.
  if [[ ! -f "$REPO_ROOT/mupdf/include/mupdf/fitz.h" ]]; then
    MUPDF_READY="the mupdf sources are not checked out (no mupdf/include/mupdf/fitz.h)"
  elif [[ ! -f "$MUPDF_LIB_DIR/libmupdf.lib" || ! -f "$MUPDF_LIB_DIR/libmupdf-third.lib" ]]; then
    MUPDF_READY="libmupdf.lib and libmupdf-third.lib are not built yet (expected in $SPDF_MUPDF_LIBDIR; set SPDF_MUPDF_LIBDIR to point elsewhere, or run portable/win/mupdf-native-build.cmd)"
  fi
  QPDF_READY="$MUPDF_READY"
  # winget installs qpdf under Program Files without touching PATH; the docs
  # track found it there on this machine. Prefer PATH, then that directory.
  if ! command -v qpdf >/dev/null 2>&1; then
    for d in "/c/Program Files/qpdf"*/bin "$PROGRAMFILES"/qpdf*/bin; do
      [[ -x "$d/qpdf.exe" ]] && { PATH="$d:$PATH"; export PATH; break; }
    done
  fi
  [[ -n "$QPDF_READY" ]] && return
  command -v qpdf > /dev/null 2>&1 || QPDF_READY="qpdf is required to generate the encrypted PDF fixtures (winget install qpdf.qpdf)"
}

# --- shared targets --------------------------------------------------------

# ShenzhenPDF.exe, built once per run and reused by app.build and every
# d2d.compose-* case. The translation units are DISCOVERED by build-native.cmd
# from portable/win/src, so a track adding a file is covered without anyone
# editing a source list here.
NATIVE_APP_BUILT=""
native_app_build() {
  [[ -n "$NATIVE_APP_BUILT" ]] && return "$NATIVE_APP_BUILT"
  native_build "$OUT/app-build.log" --app
  NATIVE_APP_BUILT=$?
  return "$NATIVE_APP_BUILT"
}

# spdf_win_probe.exe: the core plus MuPDF straight out to a PNG with
# fz_save_pixmap_as_png, containing zero references to Direct2D. Built once per
# run. It deliberately lives in portable/win/ rather than portable/win/src/ so
# the app's source discovery does not sweep it in.
NATIVE_PROBE_BUILT=""
native_probe_build() {
  [[ -n "$NATIVE_PROBE_BUILT" ]] && return "$NATIVE_PROBE_BUILT"
  # shellcheck disable=SC2086
  native_build "$OUT/probe-build.log" spdf_win_probe portable/win/spdf_win_probe.c $CORE_SET
  NATIVE_PROBE_BUILT=$?
  return "$NATIVE_PROBE_BUILT"
}

# --- harness self-proof ----------------------------------------------------

# Everything else in the suite rests on two claims: a failed compile is visible,
# and a native binary's exit code reaches bash intact. Both are asserted, never
# assumed, and asserted about exit STATUS only -- never about output text.
case_exit_code() {
  if [[ -n "$NATIVE_READY" ]]; then
    record "harness.exit-code" BLOCKED "$NATIVE_READY"
    return
  fi
  native_build "$OUT/never-compiles.log" spdf_never_compiles portable/win/tests/never_compiles.c
  if [[ $? -eq 0 ]]; then
    record "harness.exit-code" FAIL "build-native.cmd returned 0 for a source that cannot compile -- a broken Windows build would look green"
    return
  fi
  native_build "$OUT/exit-probe-build.log" spdf_exit_code_probe portable/win/tests/exit_code_probe.c
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    record "harness.exit-code" FAIL "could not build the exit-code canary (build-native.cmd exited $rc)"
    log_tail "$OUT/exit-probe-build.log"
    return
  fi
  local want got
  for want in 0 3 42; do
    native_run "$OUT/exit-probe-$want.log" spdf_exit_code_probe "$want"
    got=$?
    if [[ $got -ne $want ]]; then
      record "harness.exit-code" FAIL "a native binary exiting $want was seen as $got in bash"
      return
    fi
  done
  record "harness.exit-code" PASS "exit codes 0/3/42 and a failed compile all reach the harness intact"
}

# Only meaningful under --self-check, which re-runs the script with this env var
# set and asserts the outer exit status is non-zero. Without it, a runner bug
# that swallowed failures would be invisible to the runner's own suite.
case_forced_failure() {
  [[ "${SPDF_FORCE_FAIL:-0}" == "1" ]] || return
  record "harness.forced-failure" FAIL "deliberate failure injected by --self-check"
}

# Windows narrows the real UTF-16 command line to the machine's ANSI code page
# on the way into `char** argv`, and fopen widens it back the same way. The code
# page is a property of the machine, not of the code, so the assumption is
# checked rather than believed -- and the observed bytes are REPORTED rather
# than asserted. Pinning 0xE9 here would turn a differently configured Windows
# into a spurious failure, while seeing C3 A9 would mean UTF-8 leaked in. A
# harness that assumed UTF-8 would hand over a path the CRT cannot open and then
# blame the code under test; that is how a real failure in this port was first
# mis-diagnosed.
case_non_ascii_path() {
  if [[ -n "$NATIVE_READY" ]]; then
    record "harness.non-ascii-path" BLOCKED "$NATIVE_READY"
    return
  fi
  if [[ ! -f "$REPO_ROOT/$FIXTURE" ]]; then
    record "harness.non-ascii-path" BLOCKED "fixture $FIXTURE is missing (regenerate: portable/win/tests/make_fixture_pdf.py)"
    return
  fi
  native_build "$OUT/narrow-path-build.log" narrow_path_probe portable/win/tests/narrow_path_probe.c
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    record "harness.non-ascii-path" FAIL "the narrow-path probe does not build (build-native.cmd exited $rc)"
    log_tail "$OUT/narrow-path-build.log" 20
    return
  fi
  # The character is assembled with printf rather than written literally so THIS
  # file stays pure ASCII -- the same reason non_ascii_path.ps1 spells it
  # [char]0xE9. A literal would additionally be at risk of NFC/NFD
  # normalisation on macOS, making the test's own input depend on which machine
  # checked the repo out.
  local dir
  dir="$BUILD_DIR/native-$(printf '\xc3\xa9')dir"
  rm -rf "$dir"
  mkdir -p "$dir" && cp "$REPO_ROOT/$FIXTURE" "$dir/golden.pdf"
  if [[ ! -f "$dir/golden.pdf" ]]; then
    record "harness.non-ascii-path" FAIL "could not stage a fixture under a non-ASCII directory name"
    return
  fi
  native_run "$OUT/narrow-path.log" narrow_path_probe "$(cygpath -w "$dir/golden.pdf")"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    record "harness.non-ascii-path" FAIL "a path containing a non-ASCII character could not be opened (exit $rc)"
    log_tail "$OUT/narrow-path.log" 12
    return
  fi
  local bytes
  bytes="$(declared_line 'argv1-bytes' "$OUT/narrow-path.log")"
  record "harness.non-ascii-path" PASS "narrow argv round-trips a non-ASCII path (${bytes:-bytes not captured})"
}

# The golden-image comparator's own self-test. Pure Python and host-independent,
# so unlike every comparison that USES the comparator, this one runs natively.
# It is what makes a PASS from compare_png.py mean something.
case_compare_png_selftest() {
  if ! command -v python3 > /dev/null 2>&1; then
    record "selftest.compare-png" BLOCKED "python3 is not on PATH"
    return
  fi
  python3 "$TESTS_DIR/compare_png_selftest.py" > "$OUT/compare-png-selftest.log" 2>&1
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    record "selftest.compare-png" PASS "every golden-image detector fired correctly"
  else
    record "selftest.compare-png" FAIL "comparator self-test exited $rc"
    log_tail "$OUT/compare-png-selftest.log" 14
  fi
}
