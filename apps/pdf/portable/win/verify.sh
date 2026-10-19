#!/usr/bin/env bash
# End-to-end proof that the macOS -> Windows-VM build chain works and is honest.
#
# Five things get proven, in order:
#   1. The same pure-C source produces BYTE-IDENTICAL output on macOS/clang/arm64
#      and Windows/MSVC/ARM64.
#   2. vm-build.sh exits non-zero when the guest compile fails.
#   3. vm-build.sh exits zero when it succeeds.
#   4. Every object in the built libmupdf.lib / libmupdf-third.lib is AA64, i.e.
#      native ARM64 rather than x64 under emulation.
#   5. A real PDF page rendered through portable/core + libmupdf is byte-identical
#      on both hosts.
#
# Steps 4 and 5 need libmupdf built in the guest (portable/win/mupdf-build.sh).
# They are skipped, loudly, when it is not -- but never silently, and never
# "passed".
#
# Run from anywhere:  portable/win/verify.sh
#   SPDF_VERIFY_SKIP_MUPDF=1  runs only steps 1-3 (seconds instead of a minute)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$REPO_ROOT/portable/win/build"
mkdir -p "$OUT"

fail() { echo "VERIFY FAILED: $*" >&2; exit 1; }

echo "== 1. native macOS reference =="
cc -std=c99 -O2 -Wall -I"$REPO_ROOT/portable/core" \
   -o "$OUT/recolor_smoke_mac" \
   "$REPO_ROOT/portable/win/smoke/recolor_smoke.c" \
   "$REPO_ROOT/portable/core/spdf_recolor.c" || fail "macOS compile failed"
"$OUT/recolor_smoke_mac" > "$OUT/mac.txt" || fail "macOS program exited non-zero"
echo "   wrote $OUT/mac.txt ($(wc -l < "$OUT/mac.txt" | tr -d ' ') lines)"

echo "== 2. guest build must FAIL on a broken source =="
# Expected: cl.exe exits 2. Anything zero here means the chain is lying.
"$REPO_ROOT/portable/win/vm-build.sh" spdf_broken \
    portable/win/smoke/broken.c > "$OUT/broken.log" 2>&1
broken_rc=$?
if [[ $broken_rc -eq 0 ]]; then
  fail "vm-build.sh returned 0 for a source that cannot compile -- exit code is NOT propagating"
fi
echo "   vm-build.sh exited $broken_rc as required (log: $OUT/broken.log)"

echo "== 3. guest build + run of the real smoke test =="
"$REPO_ROOT/portable/win/vm-build.sh" --run recolor_smoke \
    portable/win/smoke/recolor_smoke.c portable/core/spdf_recolor.c > "$OUT/win.raw" 2>&1
win_rc=$?
[[ $win_rc -eq 0 ]] || { cat "$OUT/win.raw"; fail "guest build/run exited $win_rc"; }

# Strip CRs (the guest emits CRLF) and the vm-build.sh progress chatter, leaving
# just the program's own stdout so the diff compares like with like.
tr -d '\r' < "$OUT/win.raw" \
  | sed -n '/^spdf recolor smoke test$/,/^ok$/p' > "$OUT/win.txt"
[[ -s "$OUT/win.txt" ]] || { cat "$OUT/win.raw"; fail "no program output captured from the guest"; }

echo "== 4. diff =="
if diff -u "$OUT/mac.txt" "$OUT/win.txt"; then
  echo "   IDENTICAL: macOS clang/arm64 == Windows MSVC/ARM64"
else
  fail "macOS and Windows output differ (see above)"
fi

if [[ "${SPDF_VERIFY_SKIP_MUPDF:-0}" == "1" ]]; then
  echo
  echo "VERIFY OK (steps 5-6 skipped: SPDF_VERIFY_SKIP_MUPDF=1)"
  exit 0
fi

echo "== 5. libmupdf is native ARM64 =="
"$REPO_ROOT/portable/win/mupdf-arch-check.sh"
arch_rc=$?
if [[ $arch_rc -eq 93 ]]; then
  echo "   SKIPPED: libmupdf has not been built. Run portable/win/mupdf-build.sh." >&2
  echo
  echo "VERIFY INCOMPLETE: steps 5-6 could not run" >&2
  exit 2
fi
[[ $arch_rc -eq 0 ]] || fail "libmupdf is not native ARM64 (exit $arch_rc)"

echo "== 6. a real page renders identically on both hosts =="
"$REPO_ROOT/portable/win/mupdf-render-check.sh" || fail "cross-host render check failed"

echo
echo "VERIFY OK"
