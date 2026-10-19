#!/usr/bin/env bash
# The launch budget: does the window still come up, and the first page still
# paint, inside a time a person would call instant?
#
# WHAT IT ASSERTS. portable/win/measure-launch.ps1 launches the freshly built
# ShenzhenPDF.exe on outline.pdf several times and takes medians of two numbers,
# both measured from the process's kernel creation time:
#
#   window visible   -- the host sees a visible top-level window (external);
#   first page       -- the app's own `first-compose-end` mark, i.e. the first
#                       EndDraw of the first WM_PAINT returned (in-process,
#                       spdf_win_launch_profile.h). When the exe carries no
#                       markers the sampler's first non-blank client frame
#                       stands in.
#
# THE BUDGETS ARE GENEROUS ON PURPOSE. This is a regression tripwire, not the
# target: the target (window < 100 ms, first page < 150 ms warm) and the
# measured state live in portable/docs/windows-launch-performance.md. Other
# tracks build on this machine while the suite runs and a median of five
# absorbs a few slow runs, but a budget tight enough to be the goal would fail
# on every busy afternoon and be ignored by the evening. Tighten them with a
# measurement, in the doc, never here first.
#
# BLOCKED, NOT FAILED, when the workstation is locked: the desktop is not
# composited then and the numbers describe nothing a person sees. The harness
# exits 68 for that; it is mapped to BLOCKED, so the suite exits 2, as it does
# for every other host-blocked case.
#
# The user's live session.yaml is backed up and restored by the harness around
# every launch; see its SESSION SAFETY note.
#
# Sourced by run-tests-native.sh, never executed. Needs harness-lib.sh and
# run-tests-native.lib.sh.

LAUNCH_NATIVE_CASES=(launch.budget launch.invariant launch.health window.stress dialog.open)
LAUNCH_WINDOW_BUDGET_MS=300
LAUNCH_FIRST_PAGE_BUDGET_MS=600
LAUNCH_RUNS=5
# window.stress: how long the flood runs, how often the UI thread must answer
# WM_NULL and within what time. 20 s is enough for nine reloads of the fixture
# under continuous input; 500 ms is a tenth of the time after which the shell
# ghosts a window, and ten times any pause a reader would forgive.
STRESS_DURATION_MS=20000
STRESS_PING_EVERY_MS=250
STRESS_PING_TIMEOUT_MS=500

# THE LAUNCH INVARIANT (portable/win/launch-invariant.ps1): after a launch,
# every window of the app is enabled, not hung and reachable -- its tab strip
# inside a work area it overlaps by 80 x 80 -- and the window the session left
# focused is the topmost of the app's windows. Four launches that broke it, each
# from a session.yaml written into a private --state-dir on the live display
# geometry: a late --behind sibling that came up OVER the focused window at its
# exact frame (z-index 0, the keyboard underneath it); a saved frame with a
# 60 x 28 corner on screen; one with its title bar 1100 px above the display;
# one on a display that is not attached. windows-native-observations.md,
# section 13, has the measurements. BLOCKED (68) on a locked workstation, as
# launch.budget is: a z-order and a work area describe a desktop somebody sees.
case_launch_invariant() {
  local case_name="launch.invariant"
  if [[ -n "$MUPDF_READY" ]]; then
    record "$case_name" BLOCKED "$MUPDF_READY"
    return
  fi
  if ! command -v powershell.exe > /dev/null 2>&1; then
    record "$case_name" BLOCKED "powershell.exe is not on PATH (launch-invariant.ps1 drives the launches)"
    return
  fi
  local fixture="$REPO_ROOT/portable/win/tests/fixtures/golden.pdf"
  local fixture2="$REPO_ROOT/portable/win/tests/fixtures/outline.pdf"
  if [[ ! -f "$fixture" || ! -f "$fixture2" ]]; then
    record "$case_name" BLOCKED "fixtures golden.pdf / outline.pdf are missing under portable/win/tests/fixtures"
    return
  fi
  native_app_build
  if [[ $? -ne 0 ]]; then
    record "$case_name" FAIL "ShenzhenPDF.exe does not build (see $OUT/app-build.log)"
    return
  fi
  local log="$OUT/launch-invariant.log"
  local out_dir="$SCRATCH/launch-invariant"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$REPO_ROOT/portable/win/launch-invariant.ps1")" \
      -Exe "$SPDF_OUT\\ShenzhenPDF.exe" -Pdf "$(cygpath -w "$fixture")" -Pdf2 "$(cygpath -w "$fixture2")" \
      -OutDir "$(cygpath -w "$out_dir")" > "$log" 2>&1
  local rc=$?
  case $rc in
    0)
      record "$case_name" PASS "behind, sliver, strip, gone: every window enabled, unhung, reachable; the focused window on top"
      ;;
    1)
      record "$case_name" FAIL "the launch invariant does not hold: $(grep -m 3 'FAIL' "$log" | tr '\n' ';')"
      log_tail "$log" 30
      ;;
    68)
      record "$case_name" BLOCKED "the workstation is locked; unlock and re-run (see $log)"
      ;;
    65)
      record "$case_name" FAIL "a launch produced no window (launch-invariant.ps1 exited 65)"
      log_tail "$log" 20
      ;;
    *)
      record "$case_name" FAIL "launch-invariant.ps1 exited $rc"
      log_tail "$log" 20
      ;;
  esac
}

case_launch_budget() {
  local case_name="launch.budget"
  if [[ -n "$MUPDF_READY" ]]; then
    record "$case_name" BLOCKED "$MUPDF_READY"
    return
  fi
  if ! command -v powershell.exe > /dev/null 2>&1; then
    record "$case_name" BLOCKED "powershell.exe is not on PATH (measure-launch.ps1 drives the launch)"
    return
  fi
  local fixture="$REPO_ROOT/portable/win/tests/fixtures/outline.pdf"
  if [[ ! -f "$fixture" ]]; then
    record "$case_name" BLOCKED "fixture portable/win/tests/fixtures/outline.pdf is missing (regenerate: make_outline_fixture.py)"
    return
  fi
  native_app_build
  if [[ $? -ne 0 ]]; then
    record "$case_name" FAIL "ShenzhenPDF.exe does not build (see $OUT/app-build.log)"
    return
  fi
  local log="$OUT/launch-budget.log"
  local out_dir="$SCRATCH/launch-budget"
  # Nothing between powershell's exit status and $?: the harness's exit code is
  # the whole verdict (0 within budget, 1 over, 68 blocked, other = broken).
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$REPO_ROOT/portable/win/measure-launch.ps1")" \
      -Exe "$SPDF_OUT\\ShenzhenPDF.exe" -Pdf "$(cygpath -w "$fixture")" -Runs "$LAUNCH_RUNS" \
      -OutDir "$(cygpath -w "$out_dir")" -Label launch.budget \
      -WindowBudgetMs "$LAUNCH_WINDOW_BUDGET_MS" -FirstPageBudgetMs "$LAUNCH_FIRST_PAGE_BUDGET_MS" > "$log" 2>&1
  local rc=$?
  case $rc in
    0)
      record "$case_name" PASS "median launch: window < ${LAUNCH_WINDOW_BUDGET_MS} ms, first page < ${LAUNCH_FIRST_PAGE_BUDGET_MS} ms over $LAUNCH_RUNS runs ($(launch_summary_line "$log"))"
      ;;
    1)
      record "$case_name" FAIL "launch is over budget: $(launch_summary_line "$log")"
      log_tail "$log" 30
      ;;
    68)
      record "$case_name" BLOCKED "$(desktop_block_reason "$log")"
      ;;
    65|66)
      record "$case_name" FAIL "no window appeared (measure-launch.ps1 exited $rc)"
      log_tail "$log" 20
      ;;
    *)
      record "$case_name" FAIL "measure-launch.ps1 exited $rc"
      log_tail "$log" 20
      ;;
  esac
}

# THE FLOOD: does the UI thread keep answering while a person hammers the
# window and the file under it changes? portable/win/tests/stress-window.ps1
# drives the built exe through SendInput for STRESS_DURATION_MS -- wheel,
# paging, zoom, find, the sidebar toggle, resizes -- rewriting the open
# document every two seconds so the watcher reloads it under load, and asserts
# every STRESS_PING_EVERY_MS that SendMessageTimeout(WM_NULL) answers within
# STRESS_PING_TIMEOUT_MS, that no window of the process is hung, that a
# PageDown still repaints at the end, and that WM_CLOSE ends the process.
#
# WHY IT EXISTS. "The app was never responsive to any user input" was reported
# twice with every test green: nothing in the suite had ever driven the window
# for longer than a launch, and a UI thread that waits on a worker or on another
# process (windows-native-observations.md section 13) looks fine for the two
# seconds a launch check watches it. BLOCKED, like launch.budget, when the
# workstation is locked (68) -- and when the desktop refuses the launched window
# the foreground (69), because SendInput then reaches nothing.
case_window_stress() {
  local case_name="window.stress"
  if [[ -n "$MUPDF_READY" ]]; then
    record "$case_name" BLOCKED "$MUPDF_READY"
    return
  fi
  if ! command -v powershell.exe > /dev/null 2>&1; then
    record "$case_name" BLOCKED "powershell.exe is not on PATH (stress-window.ps1 drives the window)"
    return
  fi
  local fixture="$REPO_ROOT/portable/win/tests/fixtures/outline.pdf"
  if [[ ! -f "$fixture" ]]; then
    record "$case_name" BLOCKED "fixture portable/win/tests/fixtures/outline.pdf is missing (regenerate: make_outline_fixture.py)"
    return
  fi
  native_app_build
  if [[ $? -ne 0 ]]; then
    record "$case_name" FAIL "ShenzhenPDF.exe does not build (see $OUT/app-build.log)"
    return
  fi
  local log="$OUT/window-stress.log"
  local out_dir="$SCRATCH/window-stress"
  # Nothing between powershell's exit status and $?: the harness's exit code is
  # the whole verdict (0 alive throughout, 1 a stall or a dead window, 68/69
  # blocked, other = broken).
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$REPO_ROOT/portable/win/tests/stress-window.ps1")" \
      -Exe "$SPDF_OUT\\ShenzhenPDF.exe" -Pdf "$(cygpath -w "$fixture")" -OutDir "$(cygpath -w "$out_dir")" \
      -DurationMs "$STRESS_DURATION_MS" -PingEveryMs "$STRESS_PING_EVERY_MS" -PingTimeoutMs "$STRESS_PING_TIMEOUT_MS" > "$log" 2>&1
  local rc=$?
  case $rc in
    0)
      record "$case_name" PASS "the window answered every WM_NULL within ${STRESS_PING_TIMEOUT_MS} ms through ${STRESS_DURATION_MS} ms of input and reloads ($(stress_summary_line "$log"))"
      ;;
    1)
      record "$case_name" FAIL "the window stopped answering, or stopped turning pages: $(stress_summary_line "$log")"
      log_tail "$log" 30
      ;;
    68)
      record "$case_name" BLOCKED "$(desktop_block_reason "$log")"
      ;;
    69)
      record "$case_name" BLOCKED "the desktop refused the launched window the foreground, so SendInput could reach nothing (see $log)"
      ;;
    65|66)
      record "$case_name" FAIL "no window, or the process died (stress-window.ps1 exited $rc)"
      log_tail "$log" 20
      ;;
    *)
      record "$case_name" FAIL "stress-window.ps1 exited $rc"
      log_tail "$log" 20
      ;;
  esac
}

# The script's own reason for blocking, which names the state it found (the
# lock screen, the screen saver's desktop, a session with no input desktop).
# The generic sentence is only the fallback for a log that lacks the line.
desktop_block_reason() {
  local detail
  detail=$(sed -n 's/^error=desktop-unavailable detail=//p' "$1" 2>/dev/null | tail -1)
  if [ -n "$detail" ]; then
    printf '%s (see %s)' "$detail" "$1"
  else
    printf 'the desktop cannot take synthetic input; unlock the session and re-run (see %s)' "$1"
  fi
}

# The ping line and the final repaint, for the record.
stress_summary_line() {
  local pings final
  pings="$(sed -n 's/^  pings=\(.*\) hung_samples=\([0-9]*\).*/pings \1, hung samples \2/p' "$1" | sed -n 1p)"
  final="$(sed -n 's/^  final: home->pagedown changed \([0-9-]*\) px.*/final PageDown changed \1 px/p' "$1" | sed -n 1p)"
  echo "${pings:-?}; ${final:-?}"
}

# The two medians from the harness's table, on one line, for the record.
launch_summary_line() {
  local w p
  w="$(sed -n 's/^  window visible  *\([0-9.]*\).*/\1/p' "$1" | sed -n 1p)"
  p="$(sed -n 's/^  first-compose-end  *\([0-9.]*\).*/\1/p' "$1" | sed -n 1p)"
  [[ -n "$p" ]] || p="$(sed -n 's/^  first client pixels (sampler)  *\([0-9.]*\).*/\1/p' "$1" | sed -n 1p)"
  echo "window ${w:-?} ms, first page ${p:-?} ms"
}

# --- launch.health ---------------------------------------------------------
#
# DOES THE WINDOW ANSWER? launch.budget proves a window appeared and painted;
# it cannot prove the window reacts to anything, because it never touches it.
# That gap is exactly where the report of 2026-09-05 lived -- "the app was
# never responsive to any user input and not even focusable" with every test
# green -- so this case sends REAL input and then asks the app what it saw.
#
# WHAT IT ASSERTS (portable/win/tests/launch-health.ps1):
#
#   1. a click on the toolbar's next-page button, a PageDown, and Ctrl+F with a
#      query typed into it each change the window's PrintWindow capture. The
#      click coordinate comes from `ShenzhenPDF.exe --print-layout`, i.e. from
#      the same layout the painter and the input router share, so the test
#      clicks the BUTTON rather than a coordinate someone measured once;
#   2. the app's OWN launch-health.log, written into the private --state-dir
#      this case hands it, says at 1 s: foreground, enabled, visible, not
#      iconic, not hung, z-index 0, a monitor found, on screen, not modal;
#   3. its input counters and paint total have moved by the 5 s line -- the app
#      agreeing, from the inside, that the input arrived;
#   4. the watchdog recorded no `stall`, i.e. the UI thread never stopped
#      pumping for three seconds.
#
# BLOCKED, NOT FAILED, in the two states where the question cannot be asked: a
# locked workstation (nothing is composited, so no capture can differ) and a
# desktop where the app cannot be brought to the front (real input goes to
# whoever is in FRONT, and typing into somebody else's window is worse than not
# testing). Both are 68. The harness runs under a shell under an editor, which
# Windows does not grant the foreground, so the script asks for it through the
# foreground thread's input queue and reports BLOCKED when the system still
# refuses -- see launch-health.ps1's Raise().
case_launch_health() {
  local case_name="launch.health"
  if [[ -n "$MUPDF_READY" ]]; then
    record "$case_name" BLOCKED "$MUPDF_READY"
    return
  fi
  if ! command -v powershell.exe > /dev/null 2>&1; then
    record "$case_name" BLOCKED "powershell.exe is not on PATH (launch-health.ps1 drives the window)"
    return
  fi
  local fixture="$REPO_ROOT/portable/win/tests/fixtures/golden.pdf"
  if [[ ! -f "$fixture" ]]; then
    record "$case_name" BLOCKED "fixture portable/win/tests/fixtures/golden.pdf is missing"
    return
  fi
  native_app_build
  if [[ $? -ne 0 ]]; then
    record "$case_name" FAIL "ShenzhenPDF.exe does not build (see $OUT/app-build.log)"
    return
  fi
  local log="$OUT/launch-health.log"
  # A PRIVATE state directory, always: the app writes its health log, its
  # settings and its session there, and the reader's %APPDATA%\ShenzhenPDF must
  # never be what a test drives. The script refuses that path outright.
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$REPO_ROOT/portable/win/tests/launch-health.ps1")" \
      -Exe "$SPDF_OUT\\ShenzhenPDF.exe" -Pdf "$(cygpath -w "$fixture")" \
      -StateDir "$SCRATCH_WIN\\launch-health-state" -OutDir "$SCRATCH_WIN\\launch-health" > "$log" 2>&1
  local rc=$?
  case $rc in
    0)
      record "$case_name" PASS "the window answered click, PageDown and Ctrl+F, and its own log agrees ($(health_summary_line "$log"))"
      ;;
    1)
      record "$case_name" FAIL "the window did not answer, or its own launch-health.log disagrees"
      log_tail "$log" 30
      ;;
    68)
      record "$case_name" BLOCKED "$(desktop_block_reason "$log")"
      ;;
    65|66)
      record "$case_name" FAIL "no window appeared (launch-health.ps1 exited $rc)"
      log_tail "$log" 20
      ;;
    *)
      record "$case_name" FAIL "launch-health.ps1 exited $rc"
      log_tail "$log" 20
      ;;
  esac
}

# The per-step repaint percentages on one line, for the record.
health_summary_line() {
  sed -n 's/^[0-9][0-9] \([a-z-]*\) .*changed=\([0-9.]*\)%.*/\1 \2%/p' "$1" | tr '\n' ' ' | sed 's/ *$//'
}

# --- dialog.open -----------------------------------------------------------
#
# DOES THE OPEN DIALOG HAVE ANYTHING IN IT? "When you click open pdf, then
# everything freezes": the shell's Open dialog came up with its file list, its
# File name box and its two buttons as blank white rectangles and stood there.
# Not a hang -- the window answered SendMessageTimeout in 0 ms and
# IsHungAppWindow was false -- so nothing already in this suite could see it.
# The cause was a WM_MOUSELEAVE loop in the port's own window proc that pinned
# the UI thread and starved WM_PAINT (windows-native-observations.md 20).
#
# portable/win/tests/open-dialog.ps1 launches the built exe bare, finds the
# empty state's accent button BY COLOUR, clicks it, and then measures the
# DIALOG'S OWN client pixels -- distinct colours and flat white, over the whole
# client and over the bottom band alone -- plus the CPU the process burns while
# the dialog just sits there, which is the cause measured rather than the
# symptom. Then it types a real path in, presses Enter and asserts the document
# opened. It also reads the app's launch-health.log back: a modal dialog must be
# recorded as phase=modal, never as a false phase=stall.
#
# BLOCKED (68) on a locked workstation, the screen saver's desktop, or a desktop
# that refuses the launched window the foreground: this drives real SendInput and
# captures the screen, so none of those can answer the question.
case_dialog_open() {
  local case_name="dialog.open"
  if [[ -n "$MUPDF_READY" ]]; then
    record "$case_name" BLOCKED "$MUPDF_READY"
    return
  fi
  if ! command -v powershell.exe > /dev/null 2>&1; then
    record "$case_name" BLOCKED "powershell.exe is not on PATH (open-dialog.ps1 drives the dialog)"
    return
  fi
  local fixture="$REPO_ROOT/portable/win/tests/fixtures/golden.pdf"
  if [[ ! -f "$fixture" ]]; then
    record "$case_name" BLOCKED "fixture portable/win/tests/fixtures/golden.pdf is missing"
    return
  fi
  native_app_build
  if [[ $? -ne 0 ]]; then
    record "$case_name" FAIL "ShenzhenPDF.exe does not build (see $OUT/app-build.log)"
    return
  fi
  local log="$OUT/dialog-open.log"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$REPO_ROOT/portable/win/tests/open-dialog.ps1")" \
      -Exe "$SPDF_OUT\\ShenzhenPDF.exe" -StateDir "$SCRATCH_WIN\\dialog-open-state" \
      -OutDir "$SCRATCH_WIN\\dialog-open" -Pdf "$(cygpath -w "$fixture")" > "$log" 2>&1
  local rc=$?
  case $rc in
    0)
      record "$case_name" PASS "the Open dialog renders, does not spin, and opens the document ($(dialog_open_summary_line "$log"))"
      ;;
    1)
      record "$case_name" FAIL "the Open dialog is not usable: $(grep -m 3 '^FAIL' "$log" | tr '\n' ';')"
      log_tail "$log" 30
      ;;
    68)
      record "$case_name" BLOCKED "$(desktop_block_reason "$log")"
      ;;
    65 | 66 | 67)
      record "$case_name" FAIL "no window, no accent button, or no dialog (open-dialog.ps1 exited $rc)"
      log_tail "$log" 20
      ;;
    *)
      record "$case_name" FAIL "open-dialog.ps1 exited $rc"
      log_tail "$log" 20
      ;;
  esac
}

# The dialog's own numbers, for the record.
dialog_open_summary_line() {
  sed -n 's/^02 .*client \(distinct=[0-9]*\) \(near_white=[0-9]*%\).*/\1 \2/p' "$1" | sed -n 1p
}
