#!/usr/bin/env python3
"""Golden-image comparison for the Windows port.

    compare_png.py <reference.png> <candidate.png> [options]

Compares a page rendered by the Windows build against the same page rendered by
the macOS build. Exit 0 = match within tolerance, 1 = mismatch, 2 = usage or
decode error. The report is a numeric metric plus a plain-English diagnosis,
because "images differ" is useless to whoever has to fix it.

WHAT THIS IS ACTUALLY GUARDING AGAINST. A naive comparator sets one MAE
threshold and calls it done. That threshold has to be loose enough to tolerate
two rasterisers' anti-aliasing of the same glyph, and once it is that loose it
will happily pass a vertically flipped page, a BGR page, or a page rendered at
half scale, because all three have unremarkable global statistics. So the
structural checks below run FIRST and fail regardless of tolerance:

  * blank / fully transparent output
  * a vertical flip           (the y-up rasteriser into a y-down target bug)
  * an R/B channel swap       (RGBA core buffer into a BGRA Win32 surface)
  * premultiplied vs straight alpha, including the invisible-until-composited
    variant: a halo of wrong colour on pixels whose alpha is zero
  * wrong scale               (dimension ratio, or content drawn at the wrong DPI)
  * localised corruption      (a worst-block metric, so one destroyed region
                               cannot hide inside a good global average)

Only after all of those pass does the tolerance apply, and it applies to two
separate numbers: the mean absolute error of the image composited over white,
and the fraction of pixels whose per-channel delta exceeds --delta. Anti-aliasing
moves the second number a little; a real bug moves it a lot.

TOLERANCE PROVENANCE -- READ BEFORE CHANGING THE DEFAULTS.
The port plan (portable/docs/windows-port-plan.md, section 6) requires the
tolerance to be MEASURED against a real Windows render and then pinned, never
assumed. IT HAS NOW BEEN MEASURED, and the answer is zero:

    MEASURED_MAX_MAE      = 0.0    <- measured, not assumed
    MEASURED_MAX_BAD_PCT  = 0.0    <- measured, not assumed

macOS clang/arm64 and Windows MSVC/ARM64 render the harness fixtures
BYTE-IDENTICALLY -- same pixels, same sha256 -- on the opaque fixture in `plain`
mode and on the transparent one in `alpha` mode. This was predicted (MuPDF's
rasteriser is largely fixed-point, and portable/win/verify.sh already proved
byte-identity for pure integer C across these two toolchains) and it is now
observed rather than hoped for.

So probe-cases.sh passes --strict, and --strict DECIDES the case. It previously
ran "for the report only", with the case decided by the loose provisional
defaults below -- which meant a real regression that stayed inside mae 1.5 and 2%
bad pixels would have passed a comparison known to be bit-exact. The plan says:
if the delta is zero, pin it at zero. It is zero.

The loose DEFAULT_* values below are NOT the pass bar any more. They survive as
the diagnostic scale: once --strict has already failed a case, a second loose run
says whether the drift is subtle or gross and puts a named diagnosis (flip,
channel swap, premultiplied alpha, halo) in the report. If a rasteriser change
ever makes byte-identity genuinely unattainable, record the newly observed
numbers HERE, with the run that produced them, and set the bar just above them.
Do not widen a threshold to make a failing comparison pass.

WHAT THE DETECTORS ARE POINTED AT. The premultiplied-alpha and transparent-halo
checks below can only fire on an image that HAS alpha. golden.pdf renders fully
opaque, so for a long time neither could fire on any real comparison in this
suite -- premultiplying an opaque image is the identity transform. That is why
fixtures/alpha.pdf exists and why it is in the compared set; see
make_fixture_pdf.py's build_alpha().

No third-party dependency: PNG reading and writing live in png_io.py next door
and use nothing but stdlib zlib. Adding Pillow here would mean the test harness
could fail for a reason that has nothing to do with the port.
"""

import argparse
import json
import os
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from png_io import DecodeError, Image, decode_png, encode_png  # noqa: E402,F401

# Measured across hosts, not assumed. See TOLERANCE PROVENANCE above.
MEASURED_MAX_MAE = 0.0
MEASURED_MAX_BAD_PCT = 0.0

# Diagnostic scale only -- --strict is the pass bar. See above.
DEFAULT_MAX_MAE = 1.5
DEFAULT_DELTA = 40
DEFAULT_MAX_BAD_PCT = 2.0
DEFAULT_MAX_BLOCK_MAE = 12.0
BLOCK = 16


def over_white(px):
    """Composite straight-alpha RGBA over opaque white. This is what a reader
    actually sees, so it is the right basis for the visual tolerance -- but note
    it is deliberately blind to the colour of fully transparent pixels, which is
    why the transparent-halo check is scored on the raw buffers instead."""
    out = bytearray(len(px) // 4 * 3)
    d = 0
    for s in range(0, len(px), 4):
        a = px[s + 3]
        if a == 255:
            out[d] = px[s]
            out[d + 1] = px[s + 1]
            out[d + 2] = px[s + 2]
        else:
            inv = 255 - a
            out[d] = (px[s] * a + 255 * inv + 127) // 255
            out[d + 1] = (px[s + 1] * a + 255 * inv + 127) // 255
            out[d + 2] = (px[s + 2] * a + 255 * inv + 127) // 255
        d += 3
    return out


def mae(a, b):
    if not a:
        return 0.0
    total = 0
    for x, y in zip(a, b):
        total += x - y if x > y else y - x
    return total / len(a)


def flip_vertical(img):
    out = bytearray(len(img.px))
    rb = img.width * 4
    for y in range(img.height):
        out[y * rb:(y + 1) * rb] = img.row(img.height - 1 - y)
    return Image(img.width, img.height, out)


def swap_rb(img):
    out = bytearray(img.px)
    for s in range(0, len(out), 4):
        out[s], out[s + 2] = out[s + 2], out[s]
    return Image(img.width, img.height, out)


def alpha_stats(img):
    partial = straight_evidence = transparent_colored = 0
    amin, amax = 255, 0
    for s in range(0, len(img.px), 4):
        a = img.px[s + 3]
        if a < amin:
            amin = a
        if a > amax:
            amax = a
        if a == 0:
            if img.px[s] or img.px[s + 1] or img.px[s + 2]:
                transparent_colored += 1
        elif a < 255:
            partial += 1
            # A premultiplied buffer can never have a channel above its alpha.
            if img.px[s] > a or img.px[s + 1] > a or img.px[s + 2] > a:
                straight_evidence += 1
    return {
        "alpha_min": amin,
        "alpha_max": amax,
        "partial_px": partial,
        "straight_alpha_evidence": straight_evidence,
        "transparent_colored_px": transparent_colored,
    }


def premultiply_fit(ref, cand):
    """Over the pixels both images agree are partially transparent, does the
    candidate look like the reference's colours multiplied by alpha? Returns
    (mae_as_is, mae_if_premultiplied, n). A much smaller second number is the
    signature of a straight-alpha buffer being treated as premultiplied -- the
    halo bug this repo has already shipped once."""
    direct = premul = n = 0
    for s in range(0, len(ref.px), 4):
        a = ref.px[s + 3]
        if a == 0 or a == 255 or cand.px[s + 3] != a:
            continue
        n += 1
        for k in range(3):
            rv, cv = ref.px[s + k], cand.px[s + k]
            pv = (rv * a + 127) // 255
            direct += abs(cv - rv)
            premul += abs(cv - pv)
    if n == 0:
        return (0.0, 0.0, 0)
    return (direct / (n * 3), premul / (n * 3), n)


def worst_block(ref, cand):
    """Worst BLOCK x BLOCK tile by MAE, over the composited images. A single
    ruined region -- a missing glyph run, one corrupt tile -- barely moves a
    whole-image average; it dominates its own tile."""
    w, h = ref.width, ref.height
    worst, at = 0.0, (0, 0)
    for by in range(0, h, BLOCK):
        for bx in range(0, w, BLOCK):
            total = count = 0
            for y in range(by, min(by + BLOCK, h)):
                s = (y * w + bx) * 3
                e = s + min(BLOCK, w - bx) * 3
                for i in range(s, e):
                    total += abs(ref.px[i] - cand.px[i])
                    count += 1
            if count:
                m = total / count
                if m > worst:
                    worst, at = m, (bx, by)
    return worst, at


def _flat_colour(img):
    """The image's single colour, or None if it has more than one."""
    first = bytes(img.px[0:4])
    for s in range(0, len(img.px), 4):
        if img.px[s:s + 4] != first:
            return None
    return first


def compare(ref_path, cand_path, args):
    ref = decode_png(ref_path)
    cand = decode_png(cand_path)
    failures, notes = [], []
    report = {
        "reference": ref_path,
        "candidate": cand_path,
        "reference_size": [ref.width, ref.height],
        "candidate_size": [cand.width, cand.height],
    }

    # --- structural: size ---------------------------------------------------
    if (ref.width, ref.height) != (cand.width, cand.height):
        sx = cand.width / ref.width if ref.width else 0.0
        sy = cand.height / ref.height if ref.height else 0.0
        if sx > 0 and abs(sx - sy) <= 0.02 * max(sx, 1.0):
            failures.append("WRONG SCALE: candidate is %.4gx the reference (%dx%d vs %dx%d). "
                            "Check the zoom argument and the DPI / device-pixel-ratio path."
                            % (sx, cand.width, cand.height, ref.width, ref.height))
        else:
            failures.append("DIMENSION MISMATCH: candidate %dx%d, reference %dx%d"
                            % (cand.width, cand.height, ref.width, ref.height))
        report["failures"] = failures
        return report, failures

    # --- structural: blank --------------------------------------------------
    ref_stats, cand_stats = alpha_stats(ref), alpha_stats(cand)
    report["reference_alpha"] = ref_stats
    report["candidate_alpha"] = cand_stats
    if cand_stats["alpha_max"] == 0:
        failures.append("BLANK OUTPUT: every candidate pixel is fully transparent. "
                        "The render target was never painted, or alpha was cleared to 0.")
    ref_flat, cand_flat = _flat_colour(ref), _flat_colour(cand)
    if ref_flat is not None:
        failures.append("BLANK REFERENCE: the reference is a single flat colour #%s. "
                        "The test itself is broken -- fix the reference before trusting any result."
                        % ref_flat.hex().upper())
    if cand_flat is not None and ref_flat is None:
        failures.append("BLANK OUTPUT: the candidate is a single flat colour #%s while the "
                        "reference has content." % cand_flat.hex().upper())

    # --- structural: alpha convention --------------------------------------
    direct_fit, premul_fit, fit_n = premultiply_fit(ref, cand)
    report["premultiply_fit"] = {"as_is": direct_fit, "if_premultiplied": premul_fit, "pixels": fit_n}
    if fit_n >= 64 and premul_fit * 4 < direct_fit and direct_fit > 1.0:
        failures.append("PREMULTIPLIED ALPHA: over %d partially transparent pixels the candidate "
                        "matches reference*alpha (mae %.2f) far better than reference as-is "
                        "(mae %.2f). Straight-alpha data is being treated as premultiplied -- "
                        "this is the dark halo bug." % (fit_n, premul_fit, direct_fit))
    if (cand_stats["partial_px"] >= 64 and cand_stats["straight_alpha_evidence"] == 0
            and ref_stats["straight_alpha_evidence"] > 0):
        failures.append("PREMULTIPLIED ALPHA: none of the candidate's %d partially transparent "
                        "pixels has a channel above its alpha, while the reference has %d such "
                        "pixels. The candidate buffer is premultiplied; the reference is straight."
                        % (cand_stats["partial_px"], ref_stats["straight_alpha_evidence"]))
    halo = 0
    for s in range(0, len(ref.px), 4):
        if ref.px[s + 3] == 0 and cand.px[s + 3] == 0 and ref.px[s:s + 3] != cand.px[s:s + 3]:
            halo += 1
    report["transparent_halo_px"] = halo
    if halo:
        # Invisible once composited, which is exactly why it has to be its own
        # check: an MAE over the composited image would score this a perfect 0.
        failures.append("TRANSPARENT-PIXEL HALO: %d fully transparent pixels carry a different "
                        "colour than the reference. Composited output looks fine today and will "
                        "fringe the moment anything blends or filters this buffer." % halo)

    # --- metric -------------------------------------------------------------
    rc, cc = over_white(ref.px), over_white(cand.px)
    ref_c, cand_c = Image(ref.width, ref.height, rc), Image(cand.width, cand.height, cc)
    m_direct = mae(rc, cc)
    m_flip = mae(over_white(flip_vertical(ref).px), cc)
    m_swap = mae(over_white(swap_rb(ref).px), cc)
    m_both = mae(over_white(swap_rb(flip_vertical(ref)).px), cc)
    report["mae"] = m_direct
    report["mae_if_flipped"] = m_flip
    report["mae_if_rb_swapped"] = m_swap

    def better(alt):
        return m_direct > 2.0 and alt * 4 < m_direct

    if better(m_both) and m_both < m_flip and m_both < m_swap:
        failures.append("VERTICAL FLIP + R/B SWAP: mae %.2f as-is, %.2f after flipping and "
                        "swapping R/B. The buffer is being handed over upside down and as BGRA."
                        % (m_direct, m_both))
    elif better(m_flip):
        failures.append("VERTICAL FLIP: mae %.2f as-is, %.2f when the reference is flipped "
                        "top-to-bottom. Row 0 of the source is landing at the bottom of the target."
                        % (m_direct, m_flip))
    elif better(m_swap):
        failures.append("R/B CHANNEL SWAP: mae %.2f as-is, %.2f with R and B exchanged. An RGBA "
                        "core buffer is being read as BGRA (or vice versa)."
                        % (m_direct, m_swap))

    bad = maxdelta = 0
    for x, y in zip(rc, cc):
        d = x - y if x > y else y - x
        if d > maxdelta:
            maxdelta = d
    for i in range(0, len(rc), 3):
        if (abs(rc[i] - cc[i]) > args.delta or abs(rc[i + 1] - cc[i + 1]) > args.delta
                or abs(rc[i + 2] - cc[i + 2]) > args.delta):
            bad += 1
    total_px = ref.width * ref.height
    bad_pct = 100.0 * bad / total_px if total_px else 0.0
    wb, wb_at = worst_block(ref_c, cand_c)
    report.update({"max_channel_delta": maxdelta, "bad_pixels": bad, "bad_pixel_pct": bad_pct,
                   "worst_block_mae": wb, "worst_block_at": list(wb_at)})

    if args.strict:
        if ref.px != cand.px:
            failures.append("STRICT: images are not byte-identical (mae %.4f, max channel delta %d, "
                            "%d differing pixels)." % (m_direct, maxdelta, bad))
    else:
        if m_direct > args.max_mae:
            failures.append("TOLERANCE: mean absolute error %.3f exceeds %.3f" % (m_direct, args.max_mae))
        if bad_pct > args.max_bad_pct:
            failures.append("TOLERANCE: %.3f%% of pixels differ by more than %d per channel "
                            "(limit %.3f%%)" % (bad_pct, args.delta, args.max_bad_pct))
        if wb > args.max_block_mae:
            failures.append("LOCALISED DAMAGE: the %dx%d block at (%d,%d) has mae %.2f (limit %.2f). "
                            "A small ruined region can hide inside a good whole-image average."
                            % (BLOCK, BLOCK, wb_at[0], wb_at[1], wb, args.max_block_mae))

    if not failures and m_direct > 0:
        notes.append("differences are consistent with anti-aliasing/hinting only")
    elif not failures:
        notes.append("byte-identical")
    report["failures"] = failures
    report["notes"] = notes
    return report, failures


def main(argv):
    p = argparse.ArgumentParser(description="Golden-image comparison for the Windows port.")
    p.add_argument("reference")
    p.add_argument("candidate")
    p.add_argument("--max-mae", type=float, default=DEFAULT_MAX_MAE)
    p.add_argument("--delta", type=int, default=DEFAULT_DELTA,
                   help="per-channel difference counted as a bad pixel")
    p.add_argument("--max-bad-pct", type=float, default=DEFAULT_MAX_BAD_PCT)
    p.add_argument("--max-block-mae", type=float, default=DEFAULT_MAX_BLOCK_MAE)
    p.add_argument("--strict", action="store_true", help="require byte identity")
    p.add_argument("--json", metavar="PATH", help="also write the full report as JSON")
    p.add_argument("--quiet", action="store_true")
    args = p.parse_args(argv)

    try:
        report, failures = compare(args.reference, args.candidate, args)
    except (DecodeError, OSError, zlib.error) as exc:
        print("compare_png: %s" % exc, file=sys.stderr)
        return 2

    if args.json:
        with open(args.json, "w") as fh:
            json.dump(report, fh, indent=2, sort_keys=True)

    if not args.quiet:
        print("compare_png: %s  vs  %s" % (args.reference, args.candidate))
        print("  reference   %dx%d" % tuple(report["reference_size"]))
        print("  candidate   %dx%d" % tuple(report["candidate_size"]))
        if "mae" in report:
            print("  mean abs error (over white)   %.4f" % report["mae"])
            print("  max channel delta             %d" % report["max_channel_delta"])
            print("  pixels differing by > %-3d     %d (%.4f%%)"
                  % (args.delta, report["bad_pixels"], report["bad_pixel_pct"]))
            print("  worst %dx%d block mae          %.3f at (%d,%d)"
                  % (BLOCK, BLOCK, report["worst_block_mae"], *report["worst_block_at"]))
            print("  transparent-pixel halo        %d px" % report["transparent_halo_px"])
        for f in failures:
            print("  FAIL  %s" % f)
        for n in report.get("notes", []):
            print("  note: %s" % n)
        print("RESULT: %s" % ("FAIL" if failures else "PASS"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
