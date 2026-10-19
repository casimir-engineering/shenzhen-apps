#!/usr/bin/env bash
# The Direct2D compose comparison for portable/win/tests/run-tests.sh.
#
# WHY THIS FILE EXISTS (QC finding F3).
#
# The whole Direct2D-over-WIC technology choice was made so the render path
# could be verified with no window and no desktop session -- spdf_win_d2d.h says
# so in its first paragraph: "a compose path that needs a window is a compose
# path no agent can ever verify". The capability was then built, and nothing
# ever compared its output. The suite's byte-identical PNG came from
# spdf_win_probe.c, which contains zero references to Direct2D and writes its
# image with fz_save_pixmap_as_png. What that proved was that portable/core plus
# MuPDF agree across the two toolchains -- real and valuable, and silent about
# the RGBA->BGRA swap, the premultiply, the stride handling and the
# fit-to-target scaling in spdf_win_d2d.cpp.
#
# QC ran the missing comparison by hand once and it passed. A comparison run by
# hand once protects nothing. These cases run it on every invocation.
#
# TWO LEVELS, BECAUSE THEY PROVE DIFFERENT THINGS.
#
#   d2d.exact-*   `--render-png` -> SPDF_WIN_FIT_EXACT: the core's RGBA buffer
#                 through D2D into a WIC bitmap and out as a PNG, 1:1, no
#                 background and no chrome. The output must be the macOS
#                 reference render EXACTLY. Any difference here is the compose
#                 layer mangling pixels, and there is nothing else it could be.
#
#   d2d.window-*  `--render-window-png` -> SPDF_WIN_FIT_CANVAS: the real
#                 scrolling canvas -- surround, page separation shadow, paper
#                 placeholder, pages positioned by spdf_win_canvas.c. macOS has
#                 no equivalent scene, so the frame is cropped to the
#                 destination rectangle the app itself printed and THAT is
#                 compared against the macOS page. spdf_win_main.cpp's
#                 print_geometry() anticipates exactly this consumer: "the
#                 numbers here are the interface".
#
# Both run in plain and dark. Dark is not decoration: it is the only mode where
# scene->dark changes brush colours, and F15 already found a theming defect
# behind it (the 10%-black separation shadow drawn in both themes).
#
# TOLERANCE: `--strict` DECIDES THESE CASES, pinned at 0.0, exactly as it does
# for probe.png and alpha.png. The measurement behind that is in compare_png.py's
# header and it is byte identity, measured, not assumed -- confirmed again here
# across all four comparisons at the time these cases were written. A regression
# that stayed inside the loose diagnostic thresholds would otherwise pass a
# comparison that is known to be bit-exact. Do not widen it to make a failure go
# away; record a new measurement and the run that produced it.
#
# FRESHNESS: every guest-side PNG is deleted BEFORE the run that produces it,
# and the fetch is destructive. See the long note at the top of probe-cases.sh
# for the false-pass chain that discipline exists to prevent; this file is
# subject to exactly the same hazard.
#
# Sourced, never executed, and sourced AFTER probe-cases.sh: it reuses that
# file's probe_mac_build(), and harness-lib.sh's guest plumbing.

D2D_FIXTURE="portable/win/tests/fixtures/golden.pdf"
D2D_GUEST_FIXTURE="$GUEST_TREE"'\portable\win\tests\fixtures\golden.pdf'

# The exact-zoom cases render at the same zoom the probe uses, so a failure can
# be read against probe.png directly. The window cases render at zoom 1.0 into a
# 400x400 viewport because that is a geometry in which the canvas draws page 0
# unresampled at integer coordinates -- see d2d_page0_rect(), which refuses to
# compare anything else rather than quietly comparing resampled pixels.
D2D_EXACT_ZOOM=2.0
D2D_WINDOW_ZOOM=1.0
D2D_WINDOW_W=400
D2D_WINDOW_H=400

D2D_APP_BUILT=""
D2D_REF_STATE=""
D2D_REF_NOTE=""

# --- the app ----------------------------------------------------------------

# Build ShenzhenPDF.exe in the guest, once per run.
#
# The translation units are DISCOVERED from portable/win/src rather than listed.
# portable/win/README.md notes that no CMake project and no source manifest
# exists, so the app's link line is written out by hand at every call site --
# and a hand-written list in a gating test is a list that goes stale the first
# time another track adds a file, failing this case for a reason that has
# nothing to do with Direct2D. Every .c/.cpp in that directory is part of the
# app; spdf_win_probe.c deliberately lives one level up and is not swept in.
#
# portable/core/spdf_win_compat.c is in the list by policy: it belongs in EVERY
# Windows source list (portable/win/README.md gotcha 18). Note the path -- it is
# under portable/core, not portable/win.
d2d_app_build() {
  [[ -n "$D2D_APP_BUILT" ]] && return "$D2D_APP_BUILT"
  local abs rel=()
  for abs in "$REPO_ROOT"/portable/win/src/*.c "$REPO_ROOT"/portable/win/src/*.cpp; do
    [[ -e "$abs" ]] && rel+=("${abs#"$REPO_ROOT"/}")
  done
  if [[ ${#rel[@]} -eq 0 ]]; then
    D2D_APP_BUILT=90
    return 90
  fi
  vm_build "$OUT/d2d-app-build.log" ShenzhenPDF "${rel[@]}" \
      portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c \
      portable/core/spdf_selection_support.c portable/core/spdf_recolor.c \
      portable/core/spdf_yaml.c portable/core/spdf_win_compat.c
  D2D_APP_BUILT=$?
  return "$D2D_APP_BUILT"
}

# Everything that must be true before a comparison can mean anything. Records
# the case itself and returns non-zero when it is not.
d2d_ready() {
  local case_name="$1"
  if [[ -n "$GUEST_MUPDF" ]]; then
    record "$case_name" BLOCKED "$GUEST_MUPDF"
    return 1
  fi
  if [[ ! -f "$REPO_ROOT/$D2D_FIXTURE" ]]; then
    record "$case_name" BLOCKED "fixture $D2D_FIXTURE is missing (regenerate: portable/win/tests/make_fixture_pdf.py)"
    return 1
  fi
  d2d_app_build
  local rc=$?
  [[ $rc -eq 0 ]] && return 0
  if mupdf_link_defect "$OUT/d2d-app-build.log"; then
    record "$case_name" BLOCKED "libmupdf.lib itself fails to link in the guest (LNK2048 in hyphen.obj) -- toolchain track"
  else
    record "$case_name" FAIL "ShenzhenPDF.exe does not build in the guest (vm-build exited $rc)"
    log_tail "$OUT/d2d-app-build.log" 20
  fi
  return 1
}

# --- the macOS reference ----------------------------------------------------

# d2d_mac_ref <mode> <zoom> <png>  -> $OUT/mac/<png>
#
# The same core entry point the app calls, built by the same probe the rest of
# the suite uses, so the reference is not a second implementation of anything.
d2d_mac_ref() {
  local mode="$1" zoom="$2" png="$3"
  rm -f "$OUT/mac/$png"
  if ! find_mac_mupdf; then
    D2D_REF_STATE=BLOCKED
    D2D_REF_NOTE="no macOS libmupdf.a under mupdf/build (run: make -C portable mupdf)"
    return 1
  fi
  mkdir -p "$OUT/mac"
  probe_mac_build
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    D2D_REF_STATE=FAIL
    D2D_REF_NOTE="the macOS reference probe does not build (cc exited $rc)"
    return 1
  fi
  "$OUT/spdf_win_probe_mac" "$REPO_ROOT/$D2D_FIXTURE" 0 "$zoom" "$OUT/mac/$png" "$mode" \
      > "$OUT/d2d-ref-$mode-$zoom.txt" 2>&1
  rc=$?
  if [[ $rc -ne 0 || ! -s "$OUT/mac/$png" ]]; then
    D2D_REF_STATE=FAIL
    D2D_REF_NOTE="the macOS reference render exited $rc without a usable PNG"
    return 1
  fi
  return 0
}

# --- the guest render -------------------------------------------------------

# d2d_guest_png <tag> <png> <command-tail>
#
# Clears the guest-side path, runs ShenzhenPDF.exe, brings the PNG back over
# stdout as base64 and decodes it to $OUT/win/<png>. The transcript lands in
# $OUT/d2d-<tag>.txt with CRs stripped. Sets D2D_REF_NOTE on failure.
d2d_guest_png() {
  local tag="$1" png="$2" tail="$3"
  rm -f "$OUT/win/$png" "$OUT/d2d-$tag.txt" "$OUT/d2d-$tag.raw"
  mkdir -p "$OUT/win"
  if ! guest_rm "$GUEST_OUT"'\'"$png"; then
    D2D_REF_NOTE="could not clear the stale $GUEST_OUT\\$png in the guest; refusing to run, because the fetch would return it as this run's render"
    return 1
  fi
  guest "$OUT/d2d-$tag.raw" "$GUEST_OUT"'\ShenzhenPDF.exe '"$tail"
  local rc=$?
  tr -d '\r' < "$OUT/d2d-$tag.raw" > "$OUT/d2d-$tag.txt" 2>/dev/null
  if [[ $rc -ne 0 ]]; then
    D2D_REF_NOTE="ShenzhenPDF.exe exited $rc in the guest"
    return 1
  fi
  guest_ps "$OUT/d2d-$tag.b64" fetch_probe_png.ps1 "$png"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    D2D_REF_NOTE="could not read the composed PNG back out of the guest (exit $rc)"
    return 1
  fi
  python3 -c 'import base64,re,sys
raw = re.sub(rb"[^A-Za-z0-9+/=]", b"", open(sys.argv[1], "rb").read())
data = base64.b64decode(raw, validate=True)
if data[:8] != b"\x89PNG\r\n\x1a\n":
    raise SystemExit("decoded %d bytes but they are not a PNG" % len(data))
open(sys.argv[2], "wb").write(data)' "$OUT/d2d-$tag.b64" "$OUT/win/$png"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    D2D_REF_NOTE="the guest returned something that is not a decodable PNG"
    return 1
  fi
  return 0
}

# --- the comparison ---------------------------------------------------------

# d2d_compare <case> <tag> <reference-png> <candidate-png> <how>
#
# --strict decides. The loose run afterwards exists only to name the failure.
d2d_compare() {
  local case_name="$1" tag="$2" ref="$3" cand="$4" how="$5"
  python3 "$TESTS_DIR/compare_png.py" "$ref" "$cand" --strict --json "$OUT/d2d-$tag.json" \
      > "$OUT/d2d-$tag.cmp.txt" 2>&1
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    record "$case_name" PASS "the D2D compose output is BYTE-IDENTICAL to the macOS render ($how)"
    return
  fi
  python3 "$TESTS_DIR/compare_png.py" "$ref" "$cand" > "$OUT/d2d-$tag.loose.txt" 2>&1
  local loose_rc=$?
  local scale="within the old loose tolerance -- a subtle regression"
  [[ $loose_rc -ne 0 ]] && scale="outside tolerance as well"
  record "$case_name" FAIL "the Direct2D compose path no longer matches the macOS render ($how; $scale)"
  log_tail "$OUT/d2d-$tag.cmp.txt" 12
  [[ $loose_rc -ne 0 ]] && log_tail "$OUT/d2d-$tag.loose.txt" 12
}

# Page 0's destination rectangle from a --render-window-png transcript, as
# "x y w h", or a non-zero exit with the reason on stderr.
#
# It refuses anything but an unresampled, integer-aligned draw. A stretched or
# half-pixel-offset destination is not a bug on its own -- it is what the canvas
# does with a byte-capped render or an odd viewport -- but comparing it against
# an unresampled macOS page would be comparing two different things and calling
# the difference a Direct2D defect. If the geometry ever stops satisfying this,
# the case fails loudly and whoever changed it picks new parameters.
d2d_page0_rect() {
  python3 -c '
import re, sys
line = None
for text in open(sys.argv[1]):
    if text.startswith("frame draw page=0 "):
        line = text
if line is None:
    sys.exit("no `frame draw page=0` line in the transcript")
m = re.search(r"dest=([-\d.]+),([-\d.]+) size=([-\d.]+),([-\d.]+) bitmap=(\d+)x(\d+)", line)
if not m:
    sys.exit("could not read the geometry out of: " + line.strip())
x, y, w, h = (float(v) for v in m.group(1, 2, 3, 4))
bw, bh = (int(v) for v in m.group(5, 6))
for name, value in (("dest x", x), ("dest y", y), ("size w", w), ("size h", h)):
    if value != int(value):
        sys.exit("%s is %r, not an integer: the draw is not pixel-aligned" % (name, value))
if (int(w), int(h)) != (bw, bh):
    sys.exit("the page is drawn %dx%d from a %dx%d bitmap: D2D resampled it, so a strict "
             "comparison against an unresampled macOS render would be meaningless" % (w, h, bw, bh))
if bw == 0 or bh == 0:
    sys.exit("page 0 was not rendered (bitmap 0x0)")
print("%d %d %d %d" % (x, y, w, h))
' "$1"
}

# --- the cases --------------------------------------------------------------

# d2d_exact_case <case> <tag> <probe-mode> <app-flags>
d2d_exact_case() {
  local case_name="$1" tag="$2" mode="$3" flags="$4"
  local png="d2d-$tag.png"
  d2d_ready "$case_name" || return
  if ! d2d_mac_ref "$mode" "$D2D_EXACT_ZOOM" "$png"; then
    record "$case_name" "$D2D_REF_STATE" "$D2D_REF_NOTE"
    return
  fi
  if ! d2d_guest_png "$tag" "$png" \
      '--render-png '"$flags"' "'"$D2D_GUEST_FIXTURE"'" 0 '"$D2D_EXACT_ZOOM"' "'"$GUEST_OUT"'\'"$png"'"'; then
    record "$case_name" FAIL "$D2D_REF_NOTE"
    log_tail "$OUT/d2d-$tag.txt" 12
    return
  fi
  d2d_compare "$case_name" "$tag" "$OUT/mac/$png" "$OUT/win/$png" \
      "FIT_EXACT, $mode, zoom $D2D_EXACT_ZOOM"
}

# d2d_window_case <case> <tag> <probe-mode> <app-flags>
d2d_window_case() {
  local case_name="$1" tag="$2" mode="$3" flags="$4"
  local png="d2d-$tag.png"
  local crop="$OUT/win/d2d-$tag-crop.png"
  d2d_ready "$case_name" || return
  if ! d2d_mac_ref "$mode" "$D2D_WINDOW_ZOOM" "$png"; then
    record "$case_name" "$D2D_REF_STATE" "$D2D_REF_NOTE"
    return
  fi
  rm -f "$crop"
  if ! d2d_guest_png "$tag" "$png" \
      '--render-window-png '"$flags"' --zoom '"$D2D_WINDOW_ZOOM"' "'"$D2D_GUEST_FIXTURE"'" 0 '"$D2D_WINDOW_W"' '"$D2D_WINDOW_H"' "'"$GUEST_OUT"'\'"$png"'"'; then
    record "$case_name" FAIL "$D2D_REF_NOTE"
    log_tail "$OUT/d2d-$tag.txt" 12
    return
  fi
  local rect
  rect="$(d2d_page0_rect "$OUT/d2d-$tag.txt" 2> "$OUT/d2d-$tag.geom.err")"
  if [[ $? -ne 0 ]]; then
    record "$case_name" FAIL "the canvas geometry no longer supports a strict comparison"
    log_tail "$OUT/d2d-$tag.geom.err" 6
    return
  fi
  # shellcheck disable=SC2086
  python3 "$TESTS_DIR/crop_png.py" "$OUT/win/$png" "$crop" $rect > "$OUT/d2d-$tag.crop.txt" 2>&1
  if [[ $? -ne 0 ]]; then
    record "$case_name" FAIL "could not crop the window frame to page 0's destination rectangle ($rect)"
    log_tail "$OUT/d2d-$tag.crop.txt" 6
    return
  fi
  d2d_compare "$case_name" "$tag" "$OUT/mac/$png" "$crop" \
      "FIT_CANVAS, $mode, ${D2D_WINDOW_W}x${D2D_WINDOW_H} viewport, page 0 at $rect"
}

case_d2d_exact_plain() { d2d_exact_case "d2d.exact-plain" exact-plain plain ""; }
case_d2d_exact_dark() { d2d_exact_case "d2d.exact-dark" exact-dark dark "--dark"; }
case_d2d_window_plain() { d2d_window_case "d2d.window-plain" window-plain plain ""; }
case_d2d_window_dark() { d2d_window_case "d2d.window-dark" window-dark dark "--dark"; }
