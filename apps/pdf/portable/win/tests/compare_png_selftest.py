#!/usr/bin/env python3
"""Proof that compare_png.py detects what it claims to detect.

    compare_png_selftest.py [--keep DIR] [--decode PNG ...]

A golden-image comparator is the load-bearing part of a headless port: every
later track's "it renders correctly on Windows" rests on it. A comparator that
silently passes a flipped or BGR page would bless a broken port, so the
comparator itself needs a test, and this is it.

Method: synthesise a reference image, apply one known port bug at a time, and
assert both that the comparison fails AND that the diagnosis names the right
bug. A mutation that merely fails is not enough -- a comparator that fails
everything is as useless as one that passes everything, so the unmutated and
anti-aliasing-jitter cases must PASS.

Exit 0 = every detector behaved; 1 = at least one did not; 2 = harness error.
"""

import argparse
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compare_png as C  # noqa: E402


def lcg(seed):
    """Deterministic pseudo-randomness -- the same jitter on every machine, so a
    self-test failure is always a real failure and never a coin flip."""
    state = seed
    while True:
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        yield state


W, H = 96, 120


def base_image():
    """Structured bands, not noise: the flip and swap detectors work by comparing
    a transformed reference against the candidate, and a noise-dominated image
    would make every transform look equally wrong.

      rows   0- 39   red band with a horizontal ramp
      rows  40- 79   grey band plus a speckle, standing in for glyph edges
      rows  80-119   blue band
      (32,48)+24x24  straight-alpha region with an alpha ramp: where the
                     premultiplied-vs-straight detectors get their evidence
      ( 8, 8)+8x8    fully transparent, colour zeroed: the halo baseline
    """
    px = bytearray(W * H * 4)
    rnd = lcg(20260831)
    for y in range(H):
        for x in range(W):
            d = (y * W + x) * 4
            if y < 40:
                px[d], px[d + 1], px[d + 2] = 200 + x % 56, 20, 30
            elif y < 80:
                v = 90 if (next(rnd) >> 8) % 7 else 240
                px[d] = px[d + 1] = px[d + 2] = v
            else:
                px[d], px[d + 1], px[d + 2] = 25, 40, 210 + x % 46
            px[d + 3] = 255
    i = 0
    for y in range(48, 72):
        for x in range(32, 56):
            d = (y * W + x) * 4
            px[d], px[d + 1], px[d + 2] = 250, 200, 160
            px[d + 3] = 1 + i * 253 // 575
            i += 1
    for y in range(8, 16):
        for x in range(8, 16):
            d = (y * W + x) * 4
            px[d] = px[d + 1] = px[d + 2] = px[d + 3] = 0
    return C.Image(W, H, px)


def clone(img):
    return C.Image(img.width, img.height, bytearray(img.px))


def m_identical(img):
    return clone(img)


def m_aa_jitter(img):
    out, rnd = clone(img), lcg(7)
    for s in range(0, len(out.px), 4):
        # Fully transparent pixels are left alone on purpose. Real rasteriser
        # disagreement moves coverage at edges; it does not invent colour under
        # zero alpha. Jittering them here would (correctly) trip the halo check
        # and turn this "should pass" case into a false alarm.
        if out.px[s + 3] == 0 or (next(rnd) >> 9) % 20:
            continue
        for k in range(3):
            v = out.px[s + k] + ((next(rnd) >> 7) % 7) - 3
            out.px[s + k] = 0 if v < 0 else (255 if v > 255 else v)
    return out


def m_flipped(img):
    return C.flip_vertical(img)


def m_rb_swapped(img):
    return C.swap_rb(img)


def m_flipped_and_swapped(img):
    return C.swap_rb(C.flip_vertical(img))


def m_all_transparent(img):
    out = clone(img)
    for s in range(3, len(out.px), 4):
        out.px[s] = 0
    return out


def m_flat_white(img):
    return C.Image(img.width, img.height, bytearray(b"\xff\xff\xff\xff" * (img.width * img.height)))


def m_half_scale(img):
    w, h = img.width // 2, img.height // 2
    out = bytearray(w * h * 4)
    for y in range(h):
        for x in range(w):
            s, d = ((y * 2) * img.width + x * 2) * 4, (y * w + x) * 4
            out[d:d + 4] = img.px[s:s + 4]
    return C.Image(w, h, out)


def m_premultiplied(img):
    out = clone(img)
    for s in range(0, len(out.px), 4):
        a = out.px[s + 3]
        if 0 < a < 255:
            for k in range(3):
                out.px[s + k] = (out.px[s + k] * a + 127) // 255
    return out


def m_transparent_halo(img):
    """The premultiplied-alpha halo in its invisible form: fully transparent
    pixels carrying the wrong colour. Composited over anything this is a perfect
    match, which is precisely why it needs its own detector."""
    out = clone(img)
    for s in range(0, len(out.px), 4):
        if out.px[s + 3] == 0:
            out.px[s], out.px[s + 1], out.px[s + 2] = 0, 0, 90
    return out


def m_local_damage(img):
    """An 8x8 ruined patch, sized so it stays UNDER the global mae and bad-pixel
    thresholds. If the worst-block check were removed this mutation would pass,
    which is the whole argument for having it."""
    out = clone(img)
    for y in range(48, 56):
        for x in range(32, 40):
            d = (y * W + x) * 4
            out.px[d], out.px[d + 1], out.px[d + 2], out.px[d + 3] = 0, 255, 0, 255
    return out


# (name, mutation, expect_pass, substring the diagnosis must contain)
CASES = [
    ("identical", m_identical, True, None),
    ("aa_jitter", m_aa_jitter, True, None),
    ("flipped", m_flipped, False, "VERTICAL FLIP"),
    ("rb_swapped", m_rb_swapped, False, "R/B CHANNEL SWAP"),
    ("flipped_and_swapped", m_flipped_and_swapped, False, "VERTICAL FLIP + R/B SWAP"),
    ("all_transparent", m_all_transparent, False, "BLANK OUTPUT"),
    ("flat_white", m_flat_white, False, "BLANK OUTPUT"),
    ("half_scale", m_half_scale, False, "WRONG SCALE"),
    ("premultiplied", m_premultiplied, False, "PREMULTIPLIED ALPHA"),
    ("transparent_halo", m_transparent_halo, False, "TRANSPARENT-PIXEL HALO"),
    ("local_damage", m_local_damage, False, "LOCALISED DAMAGE"),
]


class Args:
    delta = C.DEFAULT_DELTA
    max_mae = C.DEFAULT_MAX_MAE
    max_bad_pct = C.DEFAULT_MAX_BAD_PCT
    max_block_mae = C.DEFAULT_MAX_BLOCK_MAE
    strict = False


def run(workdir, decode_paths):
    ref = base_image()
    ref_path = os.path.join(workdir, "reference.png")
    C.encode_png(ref_path, ref)

    failures = []

    # The decoder is the foundation everything else stands on: if it mis-reads a
    # file, every detector above it is reasoning about the wrong pixels.
    back = C.decode_png(ref_path)
    if (back.width, back.height, bytes(back.px)) != (W, H, bytes(ref.px)):
        failures.append("decoder: encode/decode round-trip is not lossless")
    else:
        print("  ok    decode round-trip is lossless")

    for path in decode_paths:
        try:
            img = C.decode_png(path)
            print("  ok    decoded %s (%dx%d)" % (os.path.basename(path), img.width, img.height))
        except Exception as exc:  # noqa: BLE001 - the point is to report anything
            failures.append("decoder: cannot read %s: %s" % (path, exc))

    for name, mutate, expect_pass, needle in CASES:
        cand_path = os.path.join(workdir, "%s.png" % name)
        C.encode_png(cand_path, mutate(ref))
        report, found = C.compare(ref_path, cand_path, Args())
        text = " | ".join(found)
        if expect_pass and found:
            failures.append("%s: expected PASS, got: %s" % (name, text))
        elif not expect_pass and not found:
            failures.append("%s: expected FAIL, comparator passed it" % name)
        elif needle and needle not in text:
            failures.append("%s: failed, but not for the right reason: %s" % (name, text))
        else:
            detail = "clean" if expect_pass else needle
            print("  ok    %-20s %s" % (name, detail))

    return failures


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("--keep", metavar="DIR", help="write the generated PNGs here and keep them")
    p.add_argument("--decode", metavar="PNG", nargs="*", default=[],
                   help="additionally prove the decoder can read these real PNGs")
    args = p.parse_args(argv)

    workdir = args.keep or tempfile.mkdtemp(prefix="compare_png_selftest.")
    os.makedirs(workdir, exist_ok=True)
    print("compare_png selftest (workdir %s)" % workdir)
    try:
        failures = run(workdir, args.decode)
    finally:
        if not args.keep:
            shutil.rmtree(workdir, ignore_errors=True)

    for f in failures:
        print("  FAIL  %s" % f)
    print("RESULT: %s (%d checks, %d failed)"
          % ("FAIL" if failures else "PASS", len(CASES) + 1 + len(args.decode), len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
