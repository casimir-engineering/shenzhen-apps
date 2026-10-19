#!/usr/bin/env bash
# QC canary for two proven defects in the Windows port's own test harness.
# Owned by the QC track. Exits 0 only when BOTH are fixed, so it goes green the
# day someone repairs them and stays red until then.
#
#   portable/win/tests/qc/probe-staleness-check.sh
#
# ---------------------------------------------------------------------------
# DEFECT 1 -- spdf_win_probe.c writes no PNG, says it did, and exits 0.
#
# portable/win/spdf_win_probe.c's write_png() is `void`. It catches the MuPDF
# exception, prints the failure to stderr, and returns; main() then
# unconditionally prints `png <basename>` -- a line that asserts the file
# exists -- followed by `ok`, and returns 0. A read-only output directory, a
# full disk, or any fz throw inside the encoder is therefore indistinguishable
# from a successful run by the only signal run-tests.sh consults: the exit code.
#
# DEFECT 2 -- the guest's PNG is never deleted before the run that produces it.
#
# probe-cases.sh's case_probe_win() deletes the two Mac-side copies and the
# staging-tree copy, and its header explains why ("Stale artifacts are the
# quietest way for a test suite to start lying"). It does not delete
# C:\spdf-build\probe-page.png -- which is the file the probe writes and the
# file fetch_probe_png.ps1 reads back.
#
# TOGETHER they are a complete false-pass chain: the Windows probe fails to
# render, exits 0, probe.win records PASS, fetch_probe_png.ps1 returns the
# PREVIOUS run's image, and probe.png compares last run's pixels to this run's
# macOS reference and reports "byte-identical". A real Windows render
# regression would be invisible for as long as the stale file survives.
#
# Neither defect is in the port's product code. Both are in the apparatus the
# port's correctness claims rest on, which is why they are worth pinning.
#
# Fixing defect 1: give write_png a return value and make main() print `png`
# and `ok` and return 0 only when it succeeded.
# Fixing defect 2: add a guest-side delete of C:\spdf-build\probe-page.png to
# case_probe_win()'s rm list -- it needs its own `prlctl exec ... del`, since
# the Mac cannot reach C:\ through the share.
set -uo pipefail

VM_NAME="${SPDF_VM_NAME:-Windows 11}"
GUEST_OUT='C:\spdf-build'
GUEST_PNG="$GUEST_OUT"'\probe-page.png'
FIXTURE='C:\spdf\portable\win\tests\fixtures\golden.pdf'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
note() { printf '  %s\n' "$*"; }

# The SHA256 of the guest PNG, or EMPTY when it is not there.
#
# `certutil -hashfile` prints its own error text on line 2 when the file is
# missing ("CertUtil: The system cannot find the file specified."), so taking
# line 2 unconditionally returned that sentence AS THE HASH. Two absent-file
# calls then compared equal, and this check reported "the file survived
# unchanged" about a file that did not exist. Exactly the failure mode this
# script was written to catch, one level up: a comparison that cannot tell
# missing data from unchanged data.
#
# Decided by exit code first, then by the shape of the line, and never by
# piping into grep.
guest_hash() {
  local out
  out="$(prlctl exec "$VM_NAME" cmd.exe /c "certutil -hashfile $GUEST_PNG SHA256" 2>/dev/null)"
  [[ $? -eq 0 ]] || return 0
  out="$(printf '%s' "$out" | tr -d '\r' | sed -n 2p)"
  case "$out" in
    [0-9a-fA-F][0-9a-fA-F]*) printf '%s' "$out" ;;
  esac
}

echo "== qc: probe staleness / silent-write check =="

if ! prlctl exec "$VM_NAME" cmd.exe /c 'exit /b 0' > /dev/null 2>&1; then
  echo "qc: cannot reach VM '$VM_NAME' -- BLOCKED, not a pass" >&2
  exit 2
fi
if ! prlctl exec "$VM_NAME" cmd.exe /c 'if exist "'"$GUEST_OUT"'\spdf_win_probe.exe" (exit /b 0) else (exit /b 1)' \
     > /dev/null 2>&1; then
  echo "qc: spdf_win_probe.exe is not built in the guest -- BLOCKED, not a pass" >&2
  echo "qc: run portable/win/tests/run-tests.sh --filter probe first" >&2
  exit 2
fi

before="$(guest_hash)"

# --- defect 1 ---------------------------------------------------------------
# Point the probe at a directory that cannot exist. Redirect to a file and read
# $? on the very next line: never judge this by piping into grep.
prlctl exec "$VM_NAME" cmd.exe /c \
  "$GUEST_OUT"'\spdf_win_probe.exe "'"$FIXTURE"'" 0 2.0 "C:\spdf-qc-no-such-dir\probe-page.png" plain' \
  > "$TMP/probe.log" 2>&1
rc=$?
tr -d '\r' < "$TMP/probe.log" > "$TMP/probe.txt"

if [[ $rc -eq 0 ]]; then
  note "FAIL  defect 1: the probe could not write its PNG yet exited 0."
  if grep -q '^ok$' "$TMP/probe.txt"; then
    note "      It printed 'ok' as well."
  fi
  if grep -q '^png ' "$TMP/probe.txt"; then
    note "      It printed '$(grep -m1 '^png ' "$TMP/probe.txt")' for a file it did not write."
  fi
  fail=1
else
  note "ok    defect 1 fixed: a failed PNG write exits $rc"
fi

# --- defect 2 ---------------------------------------------------------------
# The guest-side artifact from an earlier successful run must not survive a run
# that produced nothing, because fetch_probe_png.ps1 reads exactly that file.
after="$(guest_hash)"
if [[ -n "$before" && "$before" == "$after" ]]; then
  note "FAIL  defect 2: $GUEST_PNG survived a failed run unchanged"
  note "      ($before)"
  note "      fetch_probe_png.ps1 would return it as this run's Windows render."
  fail=1
elif [[ -z "$after" ]]; then
  note "ok    defect 2 fixed: the guest PNG is gone after a run that wrote none"
else
  note "ok    defect 2: the guest PNG changed across the failed run"
fi

echo
if [[ $fail -ne 0 ]]; then
  echo "qc: FAILED -- the probe pipeline can report a pass on stale pixels"
  exit 1
fi
echo "qc: OK"
exit 0
