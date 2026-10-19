#!/usr/bin/env python3
"""Cut one rectangle out of a PNG.

    crop_png.py <in.png> <out.png> <x> <y> <w> <h>

Exists for exactly one caller: the D2D window comparison in d2d-cases.sh.

`ShenzhenPDF.exe --render-window-png` composes the whole scrolling canvas --
surround, page separation shadow, paper, and the page bitmap drawn into a
destination rectangle the canvas chose. macOS has no equivalent scene to
compare that against; what it has is the page, rendered by the same core at the
same zoom. So the comparison crops the window frame down to the destination
rectangle the app itself reported and compares THAT against the macOS page.

spdf_win_main.cpp's print_geometry() says the same thing from the other side:
"The consumer is a script that crops the macOS reference render to the same
source rectangle, so the numbers here are the interface." This is that consumer,
cropping the Windows frame rather than the macOS page -- same rectangle, and it
keeps the reference untouched so a crop bug cannot cancel itself out on both
sides.

Exit 0 on success, 2 on a usage or decode error, 1 when the rectangle does not
lie wholly inside the image -- which is the honest answer when the geometry the
app printed and the image it wrote disagree.
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from png_io import DecodeError, Image, decode_png, encode_png  # noqa: E402


def crop(img, x, y, w, h):
    out = bytearray(w * h * 4)
    for row in range(h):
        src = ((y + row) * img.width + x) * 4
        dst = row * w * 4
        out[dst:dst + w * 4] = img.px[src:src + w * 4]
    return Image(w, h, out)


def main(argv):
    if len(argv) != 7:
        sys.stderr.write("usage: crop_png.py <in.png> <out.png> <x> <y> <w> <h>\n")
        return 2
    src, dst = argv[1], argv[2]
    try:
        x, y, w, h = (int(v) for v in argv[3:7])
    except ValueError:
        sys.stderr.write("crop_png: x/y/w/h must be integers\n")
        return 2
    if w <= 0 or h <= 0:
        sys.stderr.write("crop_png: the rectangle must have a positive size\n")
        return 2
    try:
        img = decode_png(src)
    except (DecodeError, OSError) as exc:
        sys.stderr.write("crop_png: %s\n" % exc)
        return 2
    if x < 0 or y < 0 or x + w > img.width or y + h > img.height:
        sys.stderr.write("crop_png: %dx%d+%d+%d does not fit inside the %dx%d image %s\n"
                         % (w, h, x, y, img.width, img.height, src))
        return 1
    try:
        encode_png(dst, crop(img, x, y, w, h))
    except OSError as exc:
        sys.stderr.write("crop_png: %s\n" % exc)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
