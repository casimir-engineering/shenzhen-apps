#!/usr/bin/env bash
# Proof for portable/win/src/spdf_win_layout.h and spdf_win_lru.{h,c}.
#
#   portable/win/tests/t3-verify.sh [--no-vm]
#
# Three claims, in increasing order of strength:
#
#   1. The port passes its own assertions, natively on macOS (clang/arm64) and
#      in the Windows guest (MSVC/ARM64). Exit codes only.
#   2. The two builds produce a BYTE-IDENTICAL transcript of every number they
#      compute. This is the bar portable/win/verify.sh already set for
#      spdf_recolor.c; here the subject is floating point, so it is a real
#      claim about the arithmetic and not just about the toolchain.
#   3. DIFFERENTIAL: the port and the GTK4 original -- the implementation it was
#      transcribed from -- are compiled into one binary and compared for EXACT
#      equality over a large input matrix. Layout, visible range, fit modes,
#      zoom anchoring, scroll clamping, the render byte cap, and the cache's
#      eviction policy. glib-only, so macOS-side.
#
# THE RULE: every verdict here comes from an exit status recorded immediately
# after the command that produced it. Nothing is piped through grep to decide
# pass or fail -- a pipeline reports the last command's status, which is how a
# crashed program comes out green. `diff` is the one exception and it is used
# exactly as intended: it IS an exit-code test.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="$REPO_ROOT/portable/win/build/t3"
VM_NAME="${SPDF_VM_NAME:-Windows 11}"
VM_BUILD="$REPO_ROOT/portable/win/vm-build.sh"
GUEST_OUT='C:\spdf-build'

USE_VM=1
[[ "${1:-}" == "--no-vm" ]] && USE_VM=0

mkdir -p "$OUT/mac" "$OUT/win" "$OUT/log"

names=(); states=(); notes=()
record() { names+=("$1"); states+=("$2"); notes+=("$3"); }

# clang, arm64, -ffp-contract=off. The contraction flag is not a workaround, it
# is the point: MSVC under /fp:precise (what portable/win/guest-build.cmd uses)
# does not fuse a*b+c into an FMA, and clang does by default. Turning it off
# makes both compilers evaluate the operations the source actually writes, which
# is the only way "byte-identical across hosts" can mean anything for floating
# point. If the transcripts ever diverge, this is the first thing to suspect.
MAC_CFLAGS=(-std=c99 -O2 -Wall -Wextra -Werror -ffp-contract=off
            "-I$REPO_ROOT/portable/win/src" "-I$REPO_ROOT/portable/core")

mac_build() {
  local target="$1"; shift
  cc "${MAC_CFLAGS[@]}" -o "$OUT/mac/$target" "$@" > "$OUT/log/mac-$target.build.log" 2>&1
  return $?
}

# Build in the guest, then run it in a SEPARATE prlctl call so the captured
# stdout is the program's alone -- vm-build.sh --run interleaves its own
# progress lines, which would poison the transcript diff.
win_build_and_run() {
  local target="$1"; shift
  local sources=("$@")
  "$VM_BUILD" "$target" "${sources[@]}" > "$OUT/log/win-$target.build.log" 2>&1
  local rc=$?
  [[ $rc -ne 0 ]] && return $rc
  prlctl exec "$VM_NAME" cmd.exe /c "$GUEST_OUT\\$target.exe" > "$OUT/win/$target.raw" 2>&1
  rc=$?
  tr -d '\r' < "$OUT/win/$target.raw" > "$OUT/win/$target.txt"
  return $rc
}

log_tail() {
  [[ -f "$1" ]] || return 0
  echo "        --- last lines of $(basename "$1") ---"
  tail -n "${2:-12}" "$1" | sed 's/^/        /'
}

# --- 1. macOS -------------------------------------------------------------

run_mac_case() {
  local case_name="$1" target="$2"; shift 2
  mac_build "$target" "$@"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    record "$case_name" FAIL "does not compile on macOS (cc exited $rc)"
    log_tail "$OUT/log/mac-$target.build.log" 20
    return
  fi
  "$OUT/mac/$target" > "$OUT/mac/$target.txt" 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    record "$case_name" FAIL "assertions failed on macOS (exit $rc)"
    log_tail "$OUT/mac/$target.txt" 20
    return
  fi
  record "$case_name" PASS "$(wc -l < "$OUT/mac/$target.txt" | tr -d ' ') transcript lines, exit 0"
}

echo "== 1. macOS, clang/arm64 =="
run_mac_case "mac.layout" layout_geometry_test "$REPO_ROOT/portable/win/tests/layout_geometry_test.c"
run_mac_case "mac.lru" lru_cache_test "$REPO_ROOT/portable/win/tests/lru_cache_test.c" \
    "$REPO_ROOT/portable/win/src/spdf_win_lru.c"

# --- 2. the differential against GTK4 -------------------------------------

echo "== 2. differential against portable/linux/gtk4 =="
pkg-config --exists glib-2.0
rc=$?
if [[ $rc -ne 0 ]]; then
  record "differential.gtk4" BLOCKED "glib-2.0 is not installed on this Mac (brew install glib); the differential is the strongest evidence available and skipping it is not a pass"
else
  # -Wno-unused-parameter etc: the GTK header is another track's code and is not
  # this script's to keep warning-clean. The port's own sources still build
  # under -Werror above.
  cc -std=gnu99 -O2 -ffp-contract=off \
     "-I$REPO_ROOT/portable/win/src" "-I$REPO_ROOT/portable/core" "-I$REPO_ROOT/portable/linux/gtk4" \
     $(pkg-config --cflags glib-2.0) \
     -o "$OUT/mac/gtk_differential" \
     "$REPO_ROOT/portable/win/tests/gtk_differential.c" \
     "$REPO_ROOT/portable/win/tests/gtk_differential_cache.c" \
     "$REPO_ROOT/portable/win/src/spdf_win_lru.c" \
     $(pkg-config --libs glib-2.0) > "$OUT/log/mac-differential.build.log" 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    record "differential.gtk4" FAIL "the differential does not compile (cc exited $rc)"
    log_tail "$OUT/log/mac-differential.build.log" 25
  else
    "$OUT/mac/gtk_differential" > "$OUT/mac/gtk_differential.txt" 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then
      record "differential.gtk4" PASS "$(tail -n 1 "$OUT/mac/gtk_differential.txt")"
    else
      record "differential.gtk4" FAIL "the port and the GTK4 original disagree (exit $rc)"
      log_tail "$OUT/mac/gtk_differential.txt" 25
    fi
  fi
fi

# --- 3. the Windows guest -------------------------------------------------

echo "== 3. Windows guest, MSVC/ARM64 =="
if [[ $USE_VM -eq 0 ]]; then
  record "win.layout" BLOCKED "--no-vm"
  record "win.lru" BLOCKED "--no-vm"
  record "transcript.layout" BLOCKED "--no-vm"
  record "transcript.lru" BLOCKED "--no-vm"
else
  # spdf_win_compat.c is in every Windows source list by policy, even for a
  # target that calls none of it: the link is what proves the policy holds.
  COMPAT=portable/core/spdf_win_compat.c
  for pair in "layout:layout_geometry_test:" "lru:lru_cache_test:portable/win/src/spdf_win_lru.c"; do
    tag="${pair%%:*}"; rest="${pair#*:}"
    target="${rest%%:*}"; extra="${rest#*:}"
    srcs=("portable/win/tests/$target.c" "$COMPAT")
    [[ -n "$extra" ]] && srcs=("portable/win/tests/$target.c" "$extra" "$COMPAT")
    win_build_and_run "$target" "${srcs[@]}"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      record "win.$tag" FAIL "guest build or run exited $rc"
      log_tail "$OUT/log/win-$target.build.log" 20
      log_tail "$OUT/win/$target.txt" 20
      record "transcript.$tag" BLOCKED "the guest side did not produce a transcript"
      continue
    fi
    record "win.$tag" PASS "assertions pass in the guest, exit 0"

    if [[ ! -s "$OUT/mac/$target.txt" ]]; then
      record "transcript.$tag" BLOCKED "no macOS transcript to compare against"
      continue
    fi
    diff -u "$OUT/mac/$target.txt" "$OUT/win/$target.txt" > "$OUT/log/diff-$target.txt" 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then
      record "transcript.$tag" PASS "byte-identical across clang/arm64 and MSVC/ARM64 ($(wc -l < "$OUT/mac/$target.txt" | tr -d ' ') lines)"
    else
      record "transcript.$tag" FAIL "the two hosts compute different numbers"
      log_tail "$OUT/log/diff-$target.txt" 30
    fi
  done
fi

# --- results --------------------------------------------------------------

echo
echo "== results =="
fails=0
blocked=0
for i in "${!names[@]}"; do
  printf '  %-8s %-22s %s\n' "${states[$i]}" "${names[$i]}" "${notes[$i]}"
  case "${states[$i]}" in
    FAIL) fails=$((fails + 1)) ;;
    BLOCKED) blocked=$((blocked + 1)) ;;
  esac
done
echo
echo "t3-verify: ${#names[@]} cases, $fails failed, $blocked blocked"
if [[ $fails -gt 0 ]]; then
  echo "t3-verify: FAILED"
  exit 1
fi
if [[ $blocked -gt 0 ]]; then
  echo "t3-verify: BLOCKED -- $blocked case(s) could not run. This is NOT a pass."
  exit 2
fi
echo "t3-verify: OK"
exit 0
