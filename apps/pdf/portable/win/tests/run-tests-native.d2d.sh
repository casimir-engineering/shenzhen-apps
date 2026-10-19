#!/usr/bin/env bash
# The Direct2D compose comparison, run entirely on one Windows box.
#
# WHAT THIS IS, AND WHAT IT IS NOT.
#
# portable/win/tests/d2d-cases.sh runs four cases -- d2d.exact-plain,
# d2d.exact-dark, d2d.window-plain, d2d.window-dark -- that compare the app's
# Direct2D compose output against a macOS reference. That reference is NOT a
# committed PNG: d2d-cases.sh compiles portable/win/spdf_win_probe.c with `cc` on
# the Mac at test time and runs it. No reference image is committed anywhere
# under portable/win/tests, so on a Windows-only box those four cases are
# structurally impossible and run-tests-native.sh records them BLOCKED.
#
# The cases here are a DIFFERENT, WEAKER test that recovers most of the value.
# The reference's role in the d2d.* cases is only "a correct render of this page
# produced WITHOUT Direct2D", and spdf_win_probe.c is exactly that: portable C
# over MuPDF, writing its PNG with fz_save_pixmap_as_png, containing zero
# references to Direct2D (its own header says so). So the probe is compiled HERE,
# with MSVC, and compared against the app:
#
#     probe PNG   core -> fz_save_pixmap_as_png
#     app PNG     core -> Direct2D -> WIC -> PNG
#
# What survives: the RGBA->BGRA swap and the premultiply in
# spdf_win_d2d.cpp:166-187, the stride handling, the fit-to-target scaling, and
# the canvas geometry. The handoff records that substituting R for B in
# rgba_to_bgra() fails all four of the original cases; it fails these too.
#
# What does NOT survive: any claim about macOS. These cases cannot detect a
# difference that both the probe and the app share -- a MuPDF or portable/core
# divergence between the two platforms is exactly what the cross-host cases
# exist to catch, and they remain BLOCKED and visible in the report.
#
# THE NAMES ARE DELIBERATELY DIFFERENT. d2d.compose-*, never d2d.exact-* or
# d2d.window-*. A Windows-internal comparison must not inherit a cross-host
# case's name: that is how a weaker test silently claims a stronger test's
# evidence, and this repo has already been bitten by documents overstating what
# was proven.
#
# TOLERANCE: `--strict` DECIDES, pinned at 0.0, exactly as in d2d-cases.sh. The
# loose run afterwards exists only to name the failure. Do not widen it to make
# a failure go away; record a new measurement and the run that produced it.
#
# FRESHNESS: every PNG is deleted BEFORE the run that produces it, and its
# existence is checked afterwards, so "the file exists" means "THIS run wrote
# it". See the long note at the top of probe-cases.sh for the false-pass chain
# that discipline exists to prevent -- a stale PNG compared against a fresh
# reference reported byte-identical for as long as the stale file survived.
#
# Sourced, never executed. Needs harness-lib.sh and run-tests-native.lib.sh.

D2D_EXACT_ZOOM=2.0
D2D_WINDOW_ZOOM=1.0
D2D_WINDOW_W=400
D2D_WINDOW_H=400

# Everything that must be true before a comparison can mean anything. Records
# the case itself and returns non-zero when it is not.
d2d_native_ready() {
  local case_name="$1"
  if [[ -n "$MUPDF_READY" ]]; then
    record "$case_name" BLOCKED "$MUPDF_READY"
    return 1
  fi
  if ! command -v python3 > /dev/null 2>&1; then
    record "$case_name" BLOCKED "python3 is not on PATH (compare_png.py decides these cases)"
    return 1
  fi
  if [[ ! -f "$REPO_ROOT/$FIXTURE" ]]; then
    record "$case_name" BLOCKED "fixture $FIXTURE is missing (regenerate: portable/win/tests/make_fixture_pdf.py)"
    return 1
  fi
  native_app_build
  if [[ $? -ne 0 ]]; then
    record "$case_name" FAIL "ShenzhenPDF.exe does not build (see $OUT/app-build.log)"
    return 1
  fi
  native_probe_build
  if [[ $? -ne 0 ]]; then
    record "$case_name" FAIL "spdf_win_probe.exe does not build (see $OUT/probe-build.log)"
    return 1
  fi
  return 0
}

# d2d_native_render <log> <target> <png> <args...>  -> 0 when the PNG is fresh
#
# Deletes the output first, runs, then requires BOTH exit 0 and a non-empty
# file. spdf_win_probe used to return void from write_png(): it caught the MuPDF
# throw, printed to stderr, and main() went on to print `ok` and exit 0. The
# exit code is the only signal a harness consults, so that failure never
# happened as far as the harness was concerned. Checking the file as well means
# neither half of that pair can hide the other.
D2D_NATIVE_NOTE=""
d2d_native_render() {
  local log="$1" target="$2" png="$3"
  shift 3
  rm -f "$png"
  native_run "$log" "$target" "$@"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    D2D_NATIVE_NOTE="$target exited $rc"
    return 1
  fi
  if [[ ! -s "$png" ]]; then
    D2D_NATIVE_NOTE="$target exited 0 but wrote no PNG to $png"
    return 1
  fi
  return 0
}

# d2d_native_compare <case> <tag> <reference-png> <candidate-png> <how>
d2d_native_compare() {
  local case_name="$1" tag="$2" ref="$3" cand="$4" how="$5"
  python3 "$TESTS_DIR/compare_png.py" "$ref" "$cand" --strict --json "$OUT/d2d-native-$tag.json" \
      > "$OUT/d2d-native-$tag.cmp.txt" 2>&1
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    record "$case_name" PASS "the D2D compose output is BYTE-IDENTICAL to the same page rendered without D2D ($how)"
    return
  fi
  python3 "$TESTS_DIR/compare_png.py" "$ref" "$cand" > "$OUT/d2d-native-$tag.loose.txt" 2>&1
  local loose_rc=$?
  local scale="within the loose diagnostic tolerance -- a subtle regression"
  [[ $loose_rc -ne 0 ]] && scale="outside tolerance as well"
  record "$case_name" FAIL "the Direct2D compose path no longer matches the non-D2D render of the same page ($how; $scale)"
  log_tail "$OUT/d2d-native-$tag.cmp.txt" 12
  [[ $loose_rc -ne 0 ]] && log_tail "$OUT/d2d-native-$tag.loose.txt" 12
}

# Page 0's destination rectangle from a --render-window-png transcript, as
# "x y w h", or a non-zero exit with the reason on stderr.
#
# It refuses anything but an unresampled, integer-aligned draw. A stretched or
# half-pixel-offset destination is not a bug on its own -- it is what the canvas
# does with a byte-capped render or an odd viewport -- but comparing it against
# an unresampled probe render would be comparing two different things and
# calling the difference a Direct2D defect. If the geometry ever stops
# satisfying this, the case fails loudly and whoever changed it picks new
# parameters.
#
# Duplicated from d2d-cases.sh:d2d_page0_rect rather than shared: that file
# assigns guest-only variables at source time and its messages name macOS, so
# sourcing it here would either break under `set -u` or attribute a native
# failure to a machine that was never involved.
d2d_native_page0_rect() {
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
             "comparison against an unresampled render would be meaningless" % (w, h, bw, bh))
if bw == 0 or bh == 0:
    sys.exit("page 0 was not rendered (bitmap 0x0)")
print("%d %d %d %d" % (x, y, w, h))
' "$1"
}

# d2d_native_inset_border <candidate> <reference> <rrggbb> <out-candidate> <out-reference>
#
# THE DARK THEME DRAWS CHROME INSIDE THE PAGE RECTANGLE, so the window
# comparison cannot be a whole-rectangle byte match in dark mode.
# spdf_win_theme_for() sets draws_page_border only when dark
# (spdf_win_d2d.h:104-106) and draw_canvas_page() strokes a 1 px #333333 frame
# inset half a stroke, AFTER the page content (spdf_win_d2d.cpp:266-279), so the
# page's outermost row and column are border, not document. A probe render has
# no chrome at all: comparing the two full rectangles reports a difference on
# exactly 916 pixels -- row 0, row h-1, column 0, column w-1 -- of #1E1E1E page
# white against the #333333 frame. That is the feature working, not a compose
# defect. (The same latent problem sits in d2d-cases.sh's cross-host
# d2d.window-dark, which compares this rectangle against a bare macOS page.)
#
# The frame is therefore ASSERTED, not excused. Every frame pixel must be
# exactly the colour the theme declares -- a positive check on the chrome that a
# widened tolerance would not give -- and only then is the page INTERIOR handed
# to the strict comparison. Nothing is quietly dropped: a border that stops
# being uniform, moves, or changes colour fails here, and the interior stays
# byte-exact.
d2d_native_inset_border() {
  python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from png_io import decode_png, encode_png, Image
cand_path, ref_path, want, out_cand, out_ref = sys.argv[2:7]
c = decode_png(cand_path)
r = decode_png(ref_path)
if (c.width, c.height) != (r.width, r.height):
    sys.exit("candidate %dx%d and reference %dx%d differ in size"
             % (c.width, c.height, r.width, r.height))
w, h = c.width, c.height
if w < 3 or h < 3:
    sys.exit("page rectangle %dx%d is too small to inset" % (w, h))
target = tuple(int(want[i:i + 2], 16) for i in (0, 2, 4))
def px(img, x, y):
    o = (y * w + x) * 4
    return tuple(img.px[o:o + 3])
ring = [(x, 0) for x in range(w)] + [(x, h - 1) for x in range(w)]
ring += [(0, y) for y in range(1, h - 1)] + [(w - 1, y) for y in range(1, h - 1)]
bad = [(x, y, px(c, x, y)) for (x, y) in ring if px(c, x, y) != target]
if bad:
    sys.exit("the page border is not a uniform #%s: %d of %d frame pixels differ, "
             "first at (%d,%d) = %s" % (want, len(bad), len(ring), bad[0][0], bad[0][1], bad[0][2]))
def inset(img):
    out = bytearray()
    for y in range(1, h - 1):
        s = (y * w + 1) * 4
        out += img.px[s:s + (w - 2) * 4]
    return Image(w - 2, h - 2, out)
encode_png(out_cand, inset(c))
encode_png(out_ref, inset(r))
' "$TESTS_DIR" "$1" "$2" "$3" "$4" "$5"
}

# --- the cases -------------------------------------------------------------

# d2d_native_exact_case <case> <tag> <probe-mode> <app-flag>
#
# --render-png -> SPDF_WIN_FIT_EXACT: the core's RGBA buffer through D2D into a
# WIC bitmap and out as a PNG, 1:1, no background and no chrome. Any difference
# here is the compose layer mangling pixels, and there is nothing else it could
# be. Rendered at the same zoom the probe uses so a failure reads directly
# against the probe's own output.
d2d_native_exact_case() {
  local case_name="$1" tag="$2" mode="$3" flag="$4"
  d2d_native_ready "$case_name" || return
  local fixture ref cand
  fixture="$(cygpath -w "$REPO_ROOT/$FIXTURE")"
  ref="$OUT/probe-$tag.png"
  cand="$OUT/d2d-native-$tag.png"
  if ! d2d_native_render "$OUT/probe-$tag.txt" spdf_win_probe "$ref" \
      "$fixture" 0 "$D2D_EXACT_ZOOM" "$(cygpath -w "$ref")" "$mode"; then
    record "$case_name" FAIL "the non-D2D reference render failed: $D2D_NATIVE_NOTE"
    log_tail "$OUT/probe-$tag.txt" 12
    return
  fi
  # An empty flag must not become an empty argv element, which the app would
  # read as the document path.
  local -a app_args=(--render-png)
  [[ -n "$flag" ]] && app_args+=("$flag")
  app_args+=("$fixture" 0 "$D2D_EXACT_ZOOM" "$(cygpath -w "$cand")")
  if ! d2d_native_render "$OUT/d2d-native-$tag.txt" ShenzhenPDF "$cand" "${app_args[@]}"; then
    record "$case_name" FAIL "the Direct2D render failed: $D2D_NATIVE_NOTE"
    log_tail "$OUT/d2d-native-$tag.txt" 12
    return
  fi
  d2d_native_compare "$case_name" "$tag" "$ref" "$cand" \
      "FIT_EXACT, $mode, zoom $D2D_EXACT_ZOOM"
}

# d2d_native_window_case <case> <tag> <probe-mode> <app-flag> <page-border-rrggbb|->
#
# --render-window-png -> SPDF_WIN_FIT_CANVAS: the real scrolling canvas --
# surround, page separation shadow, paper placeholder, pages positioned by
# spdf_win_canvas.cpp. The probe has no equivalent scene, so the frame is
# cropped to the destination rectangle the app itself printed and THAT is
# compared. spdf_win_main.cpp's print_geometry() anticipates exactly this
# consumer: the numbers it prints are the interface.
d2d_native_window_case() {
  local case_name="$1" tag="$2" mode="$3" flag="$4" border="$5"
  d2d_native_ready "$case_name" || return
  local fixture ref cand crop
  fixture="$(cygpath -w "$REPO_ROOT/$FIXTURE")"
  ref="$OUT/probe-$tag.png"
  cand="$OUT/d2d-native-$tag.png"
  crop="$OUT/d2d-native-$tag-crop.png"
  if ! d2d_native_render "$OUT/probe-$tag.txt" spdf_win_probe "$ref" \
      "$fixture" 0 "$D2D_WINDOW_ZOOM" "$(cygpath -w "$ref")" "$mode"; then
    record "$case_name" FAIL "the non-D2D reference render failed: $D2D_NATIVE_NOTE"
    log_tail "$OUT/probe-$tag.txt" 12
    return
  fi
  local -a app_args=(--render-window-png)
  [[ -n "$flag" ]] && app_args+=("$flag")
  app_args+=(--zoom "$D2D_WINDOW_ZOOM" "$fixture" 0 "$D2D_WINDOW_W" "$D2D_WINDOW_H" "$(cygpath -w "$cand")")
  rm -f "$crop"
  if ! d2d_native_render "$OUT/d2d-native-$tag.txt" ShenzhenPDF "$cand" "${app_args[@]}"; then
    record "$case_name" FAIL "the Direct2D window compose failed: $D2D_NATIVE_NOTE"
    log_tail "$OUT/d2d-native-$tag.txt" 12
    return
  fi
  local rect
  rect="$(d2d_native_page0_rect "$OUT/d2d-native-$tag.txt" 2> "$OUT/d2d-native-$tag.geom.err")"
  if [[ $? -ne 0 ]]; then
    record "$case_name" FAIL "the canvas geometry no longer supports a strict comparison"
    log_tail "$OUT/d2d-native-$tag.geom.err" 6
    return
  fi
  # shellcheck disable=SC2086
  python3 "$TESTS_DIR/crop_png.py" "$cand" "$crop" $rect > "$OUT/d2d-native-$tag.crop.txt" 2>&1
  if [[ $? -ne 0 ]]; then
    record "$case_name" FAIL "could not crop the window frame to page 0's destination rectangle ($rect)"
    log_tail "$OUT/d2d-native-$tag.crop.txt" 6
    return
  fi
  local how="FIT_CANVAS, $mode, ${D2D_WINDOW_W}x${D2D_WINDOW_H} viewport, page 0 at $rect"
  if [[ "$border" != "-" ]]; then
    d2d_native_inset_border "$crop" "$ref" "$border" \
        "$OUT/d2d-native-$tag-inside.png" "$OUT/probe-$tag-inside.png" \
        > "$OUT/d2d-native-$tag.border.txt" 2>&1
    if [[ $? -ne 0 ]]; then
      record "$case_name" FAIL "the 1 px page-border chrome is not the uniform #$border that spdf_win_d2d.h declares for this theme"
      log_tail "$OUT/d2d-native-$tag.border.txt" 6
      return
    fi
    crop="$OUT/d2d-native-$tag-inside.png"
    ref="$OUT/probe-$tag-inside.png"
    how="$how, 1 px #$border border asserted uniform then excluded"
  fi
  d2d_native_compare "$case_name" "$tag" "$ref" "$crop" "$how"
}

# Dark is not decoration: it is the only mode where scene->dark changes brush
# colours, and QC F15 already found a theming defect behind it (the 10%-black
# separation shadow drawn in both themes).
case_d2d_compose_plain() { d2d_native_exact_case "d2d.compose-plain" compose-plain plain ""; }
case_d2d_compose_dark() { d2d_native_exact_case "d2d.compose-dark" compose-dark dark "--dark"; }
# The border argument mirrors spdf_win_theme_for(): light draws a soft drop
# shadow OUTSIDE the page and no border, so its whole rectangle is compared;
# dark swaps the shadow for a 1 px #333333 frame drawn inside it, which is
# asserted and then excluded. Read d2d_native_inset_border's header before
# changing either value.
case_d2d_compose_window_plain() { d2d_native_window_case "d2d.compose-window-plain" compose-window-plain plain "" -; }
case_d2d_compose_window_dark() { d2d_native_window_case "d2d.compose-window-dark" compose-window-dark dark "--dark" 333333; }

D2D_NATIVE_CASES=(d2d.compose-plain d2d.compose-dark d2d.compose-window-plain d2d.compose-window-dark)
