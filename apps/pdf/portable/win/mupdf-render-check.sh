#!/usr/bin/env bash
# Render the same PDF page through the same core on both hosts and compare.
#
#   portable/win/mupdf-render-check.sh [pdf] [page] [zoom]
#
# This is the check the whole Windows port is measured against. Everything else
# -- the window, the layout maths, the tab strip -- can be argued about. Whether
# Windows and macOS produce the same pixels from the same document cannot.
#
# It builds portable/win/smoke/core_smoke.c twice:
#   * on macOS with clang/arm64 against mupdf/build/release-macos-arm64-12.0
#   * in the guest with MSVC/ARM64 against C:\spdf-build\mupdf
# runs both on the same fixture, and compares BOTH the printed report (page
# count, page size, pixel digest, nine sampled pixels) AND the raw RGBA dumps
# byte for byte. The guest writes its dump onto the Parallels share, so it
# arrives on the Mac with no copy step.
#
# Exits non-zero on any difference. There is deliberately no tolerance knob: the
# measured result is byte-identical, so anything else is a regression to
# investigate, not a threshold to widen. If a future MuPDF or toolchain really
# does introduce unavoidable drift, add the tolerance THEN, with the measurement
# that justifies it recorded next to it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="${SPDF_WIN_STAGE:-$HOME/Documents/spdf-win}"
OUT="$REPO_ROOT/portable/win/build"
MUPDF_MAC="$REPO_ROOT/mupdf/build/release-macos-arm64-12.0"

PDF_REL="${1:-portable/win/smoke/smoke.pdf}"
PAGE="${2:-0}"
ZOOM="${3:-2.0}"

fail() { echo "RENDER CHECK FAILED: $*" >&2; exit 1; }

mkdir -p "$OUT" "$STAGE/out"

# The fixture is generated, not committed: the repo's root .gitignore excludes
# *.pdf. Regenerating it every run also proves the generator is deterministic.
if [[ "$PDF_REL" == "portable/win/smoke/smoke.pdf" ]]; then
  python3 "$REPO_ROOT/portable/win/smoke/make_smoke_pdf.py" >/dev/null \
    || fail "could not generate the fixture PDF"
fi
[[ -f "$REPO_ROOT/$PDF_REL" ]] || fail "no such fixture: $PDF_REL"

CORE_SRCS=(
  portable/win/smoke/core_smoke.c
  portable/core/shenzhen_pdf_core.c
  portable/core/spdf_recolor.c
  portable/core/spdf_selection.c
  portable/core/spdf_selection_support.c
  portable/core/spdf_win_compat.c
)

echo "== 1. macOS reference (clang/arm64) =="
[[ -f "$MUPDF_MAC/libmupdf.a" ]] || fail "$MUPDF_MAC/libmupdf.a missing -- run: make -C portable mupdf-libs"
mac_srcs=()
for s in "${CORE_SRCS[@]}"; do mac_srcs+=("$REPO_ROOT/$s"); done
clang -O2 -DNDEBUG -arch arm64 -mmacosx-version-min=12.0 \
  -I"$REPO_ROOT/portable/core" -I"$REPO_ROOT/mupdf/include" \
  "${mac_srcs[@]}" "$MUPDF_MAC/libmupdf.a" "$MUPDF_MAC/libmupdf-third.a" \
  -framework Foundation -lm -o "$OUT/core_smoke_mac" || fail "macOS build failed"

"$OUT/core_smoke_mac" "$REPO_ROOT/$PDF_REL" "$PAGE" "$ZOOM" "$OUT/page_mac.rgba" \
  > "$OUT/render_mac.txt" 2>"$OUT/render_mac.err"
mac_rc=$?
[[ $mac_rc -eq 0 ]] || { cat "$OUT/render_mac.err"; fail "macOS core_smoke exited $mac_rc"; }
sed 's/^/   /' "$OUT/render_mac.txt"

echo "== 2. Windows guest (MSVC/ARM64) =="
guest_pdf="C:\\spdf\\${PDF_REL//\//\\}"
guest_out='\\Mac\Home\Documents\'"$(basename "$STAGE")"'\out\page_win.rgba'
rm -f "$STAGE/out/page_win.rgba"

"$REPO_ROOT/portable/win/vm-build.sh" --run core_smoke "${CORE_SRCS[@]}" \
  -- "$guest_pdf" "$PAGE" "$ZOOM" "$guest_out" > "$OUT/render_win.raw" 2>&1
win_rc=$?
[[ $win_rc -eq 0 ]] || { cat "$OUT/render_win.raw"; fail "guest build/run exited $win_rc"; }

# Strip CRs and vm-build.sh's own chatter, leaving just the program's stdout.
tr -d '\r' < "$OUT/render_win.raw" | sed -n '/^pages=/,/^ok$/p' > "$OUT/render_win.txt"
[[ -s "$OUT/render_win.txt" ]] || { cat "$OUT/render_win.raw"; fail "no program output from the guest"; }
sed 's/^/   /' "$OUT/render_win.txt"

echo "== 3. report diff =="
diff -u "$OUT/render_mac.txt" "$OUT/render_win.txt" || fail "the two hosts report different geometry or pixels"
echo "   identical"

echo "== 4. raw RGBA diff =="
[[ -f "$STAGE/out/page_win.rgba" ]] || fail "the guest wrote no RGBA dump to $STAGE/out"
mac_bytes=$(wc -c < "$OUT/page_mac.rgba" | tr -d ' ')
win_bytes=$(wc -c < "$STAGE/out/page_win.rgba" | tr -d ' ')
[[ "$mac_bytes" == "$win_bytes" ]] || fail "dump sizes differ: macOS $mac_bytes, Windows $win_bytes"

if cmp -s "$OUT/page_mac.rgba" "$STAGE/out/page_win.rgba"; then
  echo "   BYTE-IDENTICAL: $mac_bytes bytes of RGBA, macOS clang/arm64 == Windows MSVC/ARM64"
else
  # Do not just say "they differ". Say by how much, per channel, so the next
  # person can tell a rounding difference from a broken build.
  python3 - "$OUT/page_mac.rgba" "$STAGE/out/page_win.rgba" <<'PY'
import sys
a = open(sys.argv[1], 'rb').read()
b = open(sys.argv[2], 'rb').read()
diff = [(i, x, y) for i, (x, y) in enumerate(zip(a, b)) if x != y]
worst = max(abs(x - y) for _, x, y in diff)
total = sum(abs(x - y) for _, x, y in diff)
print("   %d of %d bytes differ (%.4f%%)" % (len(diff), len(a), 100.0 * len(diff) / len(a)))
print("   max per-channel delta %d, mean absolute error over all bytes %.6f"
      % (worst, total / float(len(a))))
print("   first 5 differing byte offsets: %s" % [i for i, _, _ in diff[:5]])
PY
  fail "the two hosts produced different pixels (detail above)"
fi

echo
echo "RENDER CHECK OK"
