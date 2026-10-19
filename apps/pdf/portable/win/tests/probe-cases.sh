#!/usr/bin/env bash
# The cross-host probe pipeline for portable/win/tests/run-tests.sh: build
# spdf_win_probe.c on macOS, build the same source in the Windows guest, diff the
# two transcripts, and compare the two rendered PNGs.
#
# Split from run-tests.sh to keep both files under the repo's 500-line cap
# (tools/file-size-limits.md), and because these cases are one story: they are
# the only cases that answer "does the CORE behave the same on Windows?" rather
# than "does the harness work?". Sourced, never executed.
#
# Each case degrades into the next: the diff and png cases record BLOCKED rather
# than inventing a result when the transcript or PNG they need does not exist, so
# a Windows-side failure produces one honest failure instead of three confusing
# ones.
#
# ---------------------------------------------------------------------------
# FRESHNESS: WHY EVERY OUTPUT IS DELETED BEFORE IT IS PRODUCED
#
# This pipeline once contained a complete false-pass chain, and the shape of it
# is worth keeping in front of whoever edits this file next:
#
#   the Windows probe failed to write its PNG  ->  it exited 0 anyway
#   ->  probe.win recorded PASS  ->  fetch_probe_png.ps1 returned the PREVIOUS
#   run's image  ->  probe.png compared last run's Windows pixels against this
#   run's macOS reference and reported "byte-identical".
#
# Both halves are now closed. The probe reports a failed write in its exit status
# (portable/win/spdf_win_probe.c), and every artifact -- the two Mac-side copies,
# the staging-tree copy, AND the guest-side file that the fetch actually reads --
# is deleted BEFORE the run that produces it, never after. Deleting afterwards
# would close nothing: the hazard lives entirely in the window between a failed
# render and the next fetch.
#
# The guest-side delete needs its own `prlctl exec`, because the Mac cannot reach
# C:\ through the share, and it is verified rather than assumed -- see guest_rm()
# in harness-lib.sh. Stale artifacts are the quietest way for a test suite to
# start lying.
#
# ---------------------------------------------------------------------------
# THE TWO FIXTURES
#
# golden.pdf renders FULLY OPAQUE -- every pixel alpha 255. That is correct for
# what it tests, but it means the comparator's two alpha guards (premultiplied
# alpha, and the transparent-pixel halo) cannot fire on it: premultiplying a
# fully opaque image is the identity transform. The one bug class this repo has
# already shipped once was therefore guarded by two detectors that no real
# comparison could ever trigger.
#
# alpha.pdf exists to fix that. It has a transparent page background, constant
# alpha graphics states, and an SMask cut-out image, so its render carries tens
# of thousands of partially transparent pixels and a large fully transparent
# region. It is rendered in the probe's `alpha` mode, which preserves the alpha
# channel -- the shipping core entry point cannot, see spdf_win_probe.c -- and
# compared byte-for-byte across the two hosts like everything else.

ALPHA_FIXTURE="portable/win/tests/fixtures/alpha.pdf"

# The probe source is one binary serving every case; build it once per run.
PROBE_MAC_BUILT=""
PROBE_WIN_BUILT=""

# --- macOS side -------------------------------------------------------------

probe_mac_build() {
  [[ -n "$PROBE_MAC_BUILT" ]] && return "$PROBE_MAC_BUILT"
  local log="$OUT/probe-mac-build.log"
  cc -O2 -Wall -Wextra -I"$REPO_ROOT/portable/core" -I"$REPO_ROOT/mupdf/include" \
     -o "$OUT/spdf_win_probe_mac" \
     "$REPO_ROOT/portable/win/spdf_win_probe.c" \
     "$REPO_ROOT/portable/core/shenzhen_pdf_core.c" \
     "$REPO_ROOT/portable/core/spdf_recolor.c" \
     "$REPO_ROOT/portable/core/spdf_win_compat.c" \
     "$MAC_MUPDF/libmupdf.a" "$MAC_MUPDF/libmupdf-third.a" "$MAC_MUPDF/libmupdf-pkcs7.a" \
     -framework Foundation -lm > "$log" 2>&1
  PROBE_MAC_BUILT=$?
  return "$PROBE_MAC_BUILT"
}

# probe_mac_run <case> <fixture> <mode> <tag> <png-name>
#
# <png-name> is shared with the Windows side and is NOT decorative: the probe
# prints `png <basename>` into the transcript, so the two hosts writing to
# differently-named files makes the diff case fail on the file name rather than
# on anything about the render. (Asked for by this harness against itself the
# first time the two sides were given different names, which is the outcome the
# diff case is for.) The tag names the per-fixture log and transcript files; the
# png name names the image, identically on both hosts.
probe_mac_run() {
  local case_name="$1" fixture="$2" mode="$3" tag="$4" png="$5"
  rm -f "$OUT/probe-mac-$tag.txt" "$OUT/mac/$png"
  if ! find_mac_mupdf; then
    record "$case_name" BLOCKED "no macOS libmupdf.a under mupdf/build (run: make -C portable mupdf)"
    return
  fi
  if [[ ! -f "$REPO_ROOT/$fixture" ]]; then
    record "$case_name" BLOCKED "fixture $fixture is missing (regenerate: portable/win/tests/make_fixture_pdf.py)"
    return
  fi
  mkdir -p "$OUT/mac"
  probe_mac_build
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    record "$case_name" FAIL "the probe does not build on macOS (cc exited $rc)"
    log_tail "$OUT/probe-mac-build.log" 20
    return
  fi
  "$OUT/spdf_win_probe_mac" "$REPO_ROOT/$fixture" 0 2.0 "$OUT/mac/$png" "$mode" \
      > "$OUT/probe-mac-$tag.txt" 2> "$OUT/probe-mac-$tag.err"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    record "$case_name" FAIL "the macOS probe exited $rc"
    log_tail "$OUT/probe-mac-$tag.err"
    return
  fi
  # The probe now exits non-zero on a failed PNG write, so this is a second
  # opinion rather than the only one -- but a reference that silently does not
  # exist would block every downstream case with a misleading reason.
  if [[ ! -s "$OUT/mac/$png" ]]; then
    record "$case_name" FAIL "the macOS probe exited 0 without leaving a PNG at mac/$png"
    return
  fi
  record "$case_name" PASS "reference transcript and PNG written from $MAC_MUPDF ($mode)"
}

# --- Windows side -----------------------------------------------------------

probe_win_build() {
  [[ -n "$PROBE_WIN_BUILT" ]] && return "$PROBE_WIN_BUILT"
  vm_build "$OUT/probe-win-build.log" spdf_win_probe \
      portable/win/spdf_win_probe.c portable/core/shenzhen_pdf_core.c portable/core/spdf_recolor.c \
      portable/core/spdf_win_compat.c
  PROBE_WIN_BUILT=$?
  return "$PROBE_WIN_BUILT"
}

# probe_win_run <case> <fixture> <mode> <tag> <png-name>
probe_win_run() {
  local case_name="$1" fixture="$2" mode="$3" tag="$4" guest_png="$5"
  rm -f "$OUT/probe-win-$tag.txt" "$OUT/probe-win-$tag.raw" "$OUT/win/$guest_png" \
        "$STAGE/portable/win/build/t4/$guest_png"
  if [[ -n "$GUEST_MUPDF" ]]; then
    record "$case_name" BLOCKED "$GUEST_MUPDF"
    return
  fi
  # BEFORE the run that produces it. See the freshness note at the top.
  if ! guest_rm "$GUEST_OUT"'\'"$guest_png"; then
    record "$case_name" FAIL "could not clear the stale $GUEST_OUT\\$guest_png in the guest; refusing to run, because the fetch would return it as this run's render"
    return
  fi
  probe_win_build
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    if mupdf_link_defect "$OUT/probe-win-build.log"; then
      record "$case_name" BLOCKED "libmupdf.lib itself fails to link in the guest (LNK2048 in hyphen.obj) -- toolchain track"
    else
      record "$case_name" FAIL "the probe does not build in the guest (vm-build exited $rc)"
      log_tail "$OUT/probe-win-build.log" 20
    fi
    return
  fi
  guest "$OUT/probe-win-$tag.raw" \
      "$GUEST_OUT"'\spdf_win_probe.exe "'"$GUEST_TREE"'\'"${fixture//\//\\}"'" 0 2.0 "'"$GUEST_OUT"'\'"$guest_png"'" '"$mode"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    record "$case_name" FAIL "the Windows probe exited $rc"
    log_tail "$OUT/probe-win-$tag.raw"
    return
  fi
  mkdir -p "$OUT/win"
  tr -d '\r' < "$OUT/probe-win-$tag.raw" > "$OUT/probe-win-$tag.txt"
  # The rendered PNG comes back as base64 on stdout, not through the staging
  # tree: sync-to-vm.sh runs rsync with --delete-excluded, so the staging
  # build/ directory is deleted on every sync -- including the one vm-build.sh
  # performs moments before this runs. stdout does not depend on another
  # track's rsync flags.
  guest_ps "$OUT/probe-fetch-$tag.b64" fetch_probe_png.ps1 "$guest_png"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    record "$case_name" FAIL "could not read the rendered PNG back out of the guest (exit $rc)"
    log_tail "$OUT/probe-fetch-$tag.b64"
    return
  fi
  python3 -c 'import base64,re,sys
raw = re.sub(rb"[^A-Za-z0-9+/=]", b"", open(sys.argv[1], "rb").read())
data = base64.b64decode(raw, validate=True)
if data[:8] != b"\x89PNG\r\n\x1a\n":
    raise SystemExit("decoded %d bytes but they are not a PNG" % len(data))
open(sys.argv[2], "wb").write(data)' "$OUT/probe-fetch-$tag.b64" "$OUT/win/$guest_png"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    record "$case_name" FAIL "the guest returned something that is not a decodable PNG"
    log_tail "$OUT/probe-fetch-$tag.b64" 4
    return
  fi
  record "$case_name" PASS "transcript and PNG produced in the guest ($mode)"
}

# --- comparisons ------------------------------------------------------------

# probe_diff_case <case> <tag>
probe_diff_case() {
  local case_name="$1" tag="$2"
  if [[ ! -s "$OUT/probe-mac-$tag.txt" || ! -s "$OUT/probe-win-$tag.txt" ]]; then
    record "$case_name" BLOCKED "needs both host probes to have produced a transcript"
    return
  fi
  diff -u "$OUT/probe-mac-$tag.txt" "$OUT/probe-win-$tag.txt" > "$OUT/probe-diff-$tag.txt" 2>&1
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    local lines
    lines="$(wc -l < "$OUT/probe-mac-$tag.txt" | tr -d ' ')"
    record "$case_name" PASS "the core produces an identical $lines-line transcript on macOS/clang and Windows/MSVC"
  else
    record "$case_name" FAIL "the macOS and Windows core transcripts differ"
    log_tail "$OUT/probe-diff-$tag.txt" 30
  fi
}

# probe_png_case <case> <tag> <png-name>
#
# TOLERANCE: --strict DECIDES THE CASE. It used to be run "for the report only",
# with the case decided by compare_png.py's loose provisional defaults (mae 1.5,
# 2% bad pixels). Section 6 of the port plan says the tolerance must be set from
# a measurement and then pinned, and the measurement has now been taken from both
# hosts many times over: the delta is exactly zero, on both fixtures, in every
# mode. A regression that stayed inside 1.5 MAE would have passed a comparison
# that is known to be bit-exact, so the loose defaults are demoted to what they
# are good for -- describing HOW FAR OFF a failure is, once strict has already
# failed it.
probe_png_case() {
  local case_name="$1" tag="$2" png="$3"
  if [[ ! -f "$OUT/mac/$png" || ! -f "$OUT/win/$png" ]]; then
    record "$case_name" BLOCKED "needs a rendered PNG from both hosts"
    return
  fi
  python3 "$TESTS_DIR/compare_png.py" "$OUT/mac/$png" "$OUT/win/$png" \
      --strict --json "$OUT/probe-png-$tag.json" > "$OUT/probe-png-$tag.txt" 2>&1
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    record "$case_name" PASS "BYTE-IDENTICAL across hosts ($(alpha_note "$OUT/probe-png-$tag.json"))"
    return
  fi
  # Strict has already failed the case. The loose run exists to say by how much,
  # and to put a named diagnosis (flip, channel swap, premultiplied alpha, halo)
  # in the report instead of a bare "not identical".
  python3 "$TESTS_DIR/compare_png.py" "$OUT/mac/$png" "$OUT/win/$png" \
      > "$OUT/probe-png-$tag.loose.txt" 2>&1
  local loose_rc=$?
  local scale="within the old loose tolerance -- a subtle regression"
  [[ $loose_rc -ne 0 ]] && scale="outside tolerance as well"
  record "$case_name" FAIL "the two hosts no longer render identically ($scale)"
  log_tail "$OUT/probe-png-$tag.txt" 12
  [[ $loose_rc -ne 0 ]] && log_tail "$OUT/probe-png-$tag.loose.txt" 12
}

# How much alpha the compared images actually carried. Reported on every pass so
# that the day someone replaces a fixture with an opaque one, the report says so
# out loud rather than quietly retiring two detectors -- which is exactly how the
# alpha guards came to be inert in the first place.
alpha_note() {
  python3 -c 'import json,sys
r = json.load(open(sys.argv[1]))
a = r.get("reference_alpha", {})
p = a.get("partial_px", 0)
if p == 0:
    print("fully opaque: the alpha detectors cannot fire on this fixture")
else:
    print("%d partially transparent px, alpha %d..%d -- alpha detectors live"
          % (p, a.get("alpha_min", 255), a.get("alpha_max", 255)))' "$1" 2>/dev/null \
    || echo "alpha stats unavailable"
}

# --- the cases --------------------------------------------------------------

case_probe_mac() { probe_mac_run "probe.mac" "$FIXTURE" plain golden probe-page.png; }
case_probe_win() { probe_win_run "probe.win" "$FIXTURE" plain golden probe-page.png; }
case_probe_diff() { probe_diff_case "probe.diff" golden; }
case_probe_png() { probe_png_case "probe.png" golden probe-page.png; }

case_alpha_mac() { probe_mac_run "alpha.mac" "$ALPHA_FIXTURE" alpha alpha probe-alpha.png; }
case_alpha_win() { probe_win_run "alpha.win" "$ALPHA_FIXTURE" alpha alpha probe-alpha.png; }
case_alpha_diff() { probe_diff_case "alpha.diff" alpha; }
case_alpha_png() { probe_png_case "alpha.png" alpha probe-alpha.png; }
