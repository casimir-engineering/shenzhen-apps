#!/usr/bin/env bash
# Plumbing for portable/win/tests/run-tests.sh: how to talk to the Parallels
# guest, how to record a result, and how to work out what is missing.
#
# Split from run-tests.sh so that file can stay about WHAT is tested while this
# one stays about HOW the guest is driven, and so both remain under the repo's
# 500-line cap (tools/file-size-limits.md). Sourced, never executed.
#
# THE RULE THAT GOVERNS THIS FILE: nothing here may stand between a guest
# command and its exit status. guest() and vm_build() are deliberately as dumb
# as a function can be -- a redirect, then `return $?` -- because every piece of
# cleverness added here is a place a Windows failure could be swallowed, and a
# swallowed failure makes the entire port's test story a lie.

names=(); states=(); notes=()
record() { names+=("$1"); states+=("$2"); notes+=("$3"); }
say() { [[ $QUIET -eq 1 ]] || echo "$@"; }
selected() { [[ -z "$FILTER" ]] || [[ "$1" == *"$FILTER"* ]]; }

# Run one command line inside the guest, capturing everything to a log and
# returning the guest's own exit status. Deliberately trivial: any cleverness
# here is cleverness that could swallow a failure.
guest() {
  local log="$1"
  shift
  prlctl exec "$VM_NAME" cmd.exe /c "$1" > "$log" 2>&1
  return $?
}

# Build a target in the guest through T0's vm-build.sh, which owns the toolchain
# discovery and the exit-code contract. Not reimplemented here on purpose: a
# second cl.exe command line would drift from the real one.
vm_build() {
  local log="$1" target="$2"
  shift 2
  "$VM_BUILD" "$target" "$@" > "$log" 2>&1
  return $?
}

# Pull one `/* spdf-test-<key>: ... */` declaration out of a test source. This
# is a fact lookup, not a pass/fail decision, so sed is fine here.
declared() {
  sed -n "s|.*$1:[[:space:]]*\\(.*\\)\\*/.*|\\1|p" "$2" | sed -n 1p
}

# Run a built guest binary from a scratch working directory, with arguments.
#
# The working directory matters: a suite that checks nothing was leaked into the
# CWD has to be run somewhere it can see that, and never in the build output
# directory. `cd /d ... &&` is safe here -- the cmd parsing trap documented in
# guest_exists() is specific to `if`, and && propagates the last command's code
# through `cmd /c` intact.
#
# ARGUMENT SEPARATION IS THIS FUNCTION'S JOB, NOT THE CALLER'S. The argument
# string used to be concatenated straight onto the closing quote of the
# executable path, so a caller that passed `C:\spdf-build\scratch` produced
#
#     "C:\spdf-build\SPDFCoreSaveTests.exe"C:\spdf-build\scratch
#
# and cmd answered "The filename, directory name, or volume label syntax is
# incorrect" without ever launching the binary. The harness then reported
# `FAIL core.SPDFCoreSaveTests exited 1 in the guest`, which sent every reader
# to portable/core to look for a bug that was not there -- while the only suite
# that exercises the Windows save path silently never ran at all.
#
# Two callers passed arguments and only one of them led with a space, so the
# defect hid behind a convention instead of a rule. The separator is inserted
# here now, once, and leading whitespace in `args` is trimmed so a caller that
# still leads with a space cannot produce a double space either.
GUEST_SCRATCH='C:\spdf-build\scratch'
guest_run() {
  local log="$1" target="$2" args="${3:-}"
  args="${args#"${args%%[![:space:]]*}"}"
  local cmdline='cd /d "'"$GUEST_SCRATCH"'" && "'"$GUEST_OUT"'\'"$target"'.exe"'
  [[ -n "$args" ]] && cmdline="$cmdline $args"
  prlctl exec "$VM_NAME" cmd.exe /c 'if not exist "'"$GUEST_SCRATCH"'" mkdir "'"$GUEST_SCRATCH"'"' \
      > "$OUT/guest-scratch.log" 2>&1
  prlctl exec "$VM_NAME" cmd.exe /c "$cmdline" > "$log" 2>&1
  return $?
}

# Delete one guest-side file and PROVE it is gone. Returns 0 when the path does
# not exist afterwards, non-zero when it survived.
#
# `del` is not enough on its own to build a freshness guarantee on: it reports
# success for a file it never found, and it reports failure for a locked file in
# a way that is easy to ignore. Since the entire point of the call is the
# post-condition -- "nothing stale is sitting at this path" -- the post-condition
# is what gets checked, by exit code, in its own prlctl call.
guest_rm() {
  prlctl exec "$VM_NAME" cmd.exe /c 'if exist "'"$1"'" del /f /q "'"$1"'"' \
      > "$OUT/guest-rm.log" 2>&1
  guest_exists "$1" && return 1
  return 0
}

# Run a PowerShell script that lives in the staged tree, returning its exit code.
#
# -File, not -Command: prlctl exec strips quotes out of an inline -Command
# argument, so every string literal in the script vanishes and the failure looks
# like a PowerShell syntax error rather than the quoting problem it is.
guest_ps() {
  local log="$1" script="$2"
  shift 2
  prlctl exec "$VM_NAME" powershell.exe -NoProfile -ExecutionPolicy Bypass \
      -File "$GUEST_TREE"'\portable\win\tests\'"$script" "$@" > "$log" 2>&1
  return $?
}

# The tail of the first line of a guest transcript that starts with a marker.
# Facts for a report, never a pass/fail decision.
declared_line() {
  tr -d '\r' < "$2" | sed -n "s|^$1 ||p" | sed -n 1p
}

# Did a guest build fail INSIDE libmupdf.lib rather than in the code under test?
#
# This does NOT decide pass/fail -- the exit code already did that, and the case
# still counts against the run. It only re-labels an already-failed build as
# BLOCKED so the report points at the party who can fix it. A defect in a
# prebuilt library is not evidence that the port's own code is wrong, and saying
# it is would send whoever reads the report looking in the wrong file.
#
# Deliberately narrow: it matches a linker error attributed to an object inside
# libmupdf.lib and nothing else. Widening this to "link errors are infra" would
# hide exactly the unresolved-symbol failures the harness exists to surface.
mupdf_link_defect() {
  [[ -f "$1" ]] || return 1
  case "$(tr -d '\r' < "$1")" in
    *'libmupdf.lib('*'error LNK'*) return 0 ;;
  esac
  return 1
}

log_tail() {
  [[ -f "$1" ]] || return 0
  echo "        --- last lines of $(basename "$1") ---"
  tail -n "${2:-8}" "$1" | sed 's/^/        /'
}

# --- prerequisites ---------------------------------------------------------

wait_for_toolchain() {
  local deadline=$((SECONDS + WAIT_SECS))
  while [[ ! -x "$VM_BUILD" ]] && [[ $SECONDS -lt $deadline ]]; do
    say "run-tests: waiting for $VM_BUILD ($((deadline - SECONDS))s left)"
    sleep 5
  done
}

MAC_MUPDF=""
find_mac_mupdf() {
  local d
  for d in "$REPO_ROOT/mupdf/build/release-macos-$(uname -m)-"* "$REPO_ROOT/mupdf/build/release"; do
    if [[ -f "$d/libmupdf.a" && -f "$d/libmupdf-third.a" ]]; then
      MAC_MUPDF="$d"
      return 0
    fi
  done
  return 1
}

# Does one path exist in the guest? Answered by EXIT CODE, not by parsing echoed
# text, and in its own prlctl call.
#
# The tempting one-liner -- chaining several `if exist X (echo A) else (echo B)`
# with `&` -- is silently wrong: cmd.exe parses the `& next-command` as part of
# the ELSE branch, so when the first test succeeds every later test is skipped
# and the probe cheerfully reports that nothing else exists. That cost an hour;
# it is the same parsing trap guest-build.cmd warns about. One call per question.
guest_exists() {
  prlctl exec "$VM_NAME" cmd.exe /c 'if exist "'"$1"'" (exit /b 0) else (exit /b 1)' \
      > "$OUT/guest-exists.log" 2>&1
  return $?
}

GUEST_READY=""      # empty = usable; otherwise the reason it is not
GUEST_MUPDF=""      # empty = usable; otherwise the reason it is not
probe_guest() {
  if ! command -v prlctl > /dev/null 2>&1; then
    GUEST_READY="prlctl is not installed on this Mac"
    GUEST_MUPDF="$GUEST_READY"
    return
  fi
  if [[ ! -x "$VM_BUILD" ]]; then
    GUEST_READY="portable/win/vm-build.sh is missing (owned by the toolchain track)"
    GUEST_MUPDF="$GUEST_READY"
    return
  fi
  prlctl exec "$VM_NAME" cmd.exe /c 'exit /b 0' > "$OUT/guest-probe.log" 2>&1
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    GUEST_READY="cannot reach VM '$VM_NAME' (prlctl exec exited $rc)"
    GUEST_MUPDF="$GUEST_READY"
    return
  fi
  if ! guest_exists 'C:\BuildTools\VC\Auxiliary\Build\vcvarsall.bat'; then
    GUEST_READY="no MSVC toolchain in the guest (vcvarsall.bat not found)"
  elif ! guest_exists "$GUEST_SHARE"'\portable\core\shenzhen_pdf_core.h'; then
    GUEST_READY="the repo is not staged into $STAGE yet"
  fi
  GUEST_MUPDF="$GUEST_READY"
  [[ -n "$GUEST_MUPDF" ]] && return
  # Headers and library arrive from two different steps of the toolchain track's
  # work, so they are reported separately: the difference between "wait" and "go
  # and fix something" is worth one extra round trip.
  if ! guest_exists "$GUEST_SHARE"'\mupdf\include\mupdf\fitz.h'; then
    GUEST_MUPDF="mupdf sources are not staged into the guest yet (toolchain track: add mupdf to SUBTREES in sync-to-vm.sh)"
  elif ! guest_exists "$GUEST_OUT"'\mupdf\libmupdf.lib'; then
    GUEST_MUPDF="libmupdf.lib is not built in the guest yet (toolchain track: run portable/win/mupdf-build.sh)"
  fi
}
