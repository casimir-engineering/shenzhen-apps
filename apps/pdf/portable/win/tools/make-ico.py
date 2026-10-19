#!/usr/bin/env python3
"""Pack the committed Shenzhen PDF icon renders into portable/win/spdf_win.ico.

    python3 portable/win/tools/make-ico.py            # writes portable/win/spdf_win.ico
    python3 portable/win/tools/make-ico.py --check    # exit 1 if the .ico is stale

THE ARTWORK IS NOT DRAWN HERE. gfx/make-shenzhen-pdf-logo.swift is the one
drawing of the icon (the 26.8.27-1 mark: a blue document with 深圳 / PDF on a
warm white-to-orange backdrop), and gfx/ShenzhenPDF-<n>x<n>x32.png are its
committed renders at 16..1024 px. This script only packs those renders into
the container Windows wants, so a change to the icon is a change to the Swift
file and its PNGs, and this runs again.

WHAT GOES IN THE .ICO. The standard set Explorer, the taskbar and the Alt+Tab
switcher pick from: 16, 32, 48, 64, 128, 256. Sizes up to 48 are stored as
uncompressed 32-bit BGRA DIBs (with the 1-bit AND mask Windows still expects),
because a handful of shell surfaces decode small PNG entries poorly; 64 and
above are stored as PNG, which every Windows since Vista reads and which keeps
the 256 px entry from costing 256 KB. No PIL, no ImageMagick: the PNG decoder
below handles exactly the files the Swift renderer writes (8-bit RGBA,
non-interlaced) and refuses anything else rather than guess.
"""
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
OUT = os.path.join(REPO, "portable", "win", "spdf_win.ico")
SIZES = [16, 32, 48, 64, 128, 256]
DIB_MAX = 48  # stored as DIB; larger sizes stay PNG


def png_path(size):
    return os.path.join(REPO, "gfx", f"ShenzhenPDF-{size}x{size}x32.png")


def decode_png_rgba(data):
    """Return (width, height, rows) for an 8-bit RGBA non-interlaced PNG."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos = 8
    width = height = None
    idat = b""
    while pos < len(data):
        length, ctype = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            width, height, depth, color, _comp, _filt, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or color != 6 or interlace != 0:
                raise ValueError("expected 8-bit RGBA non-interlaced; got depth %d color %d interlace %d"
                                 % (depth, color, interlace))
        elif ctype == b"IDAT":
            idat += body
        elif ctype == b"IEND":
            break
    raw = zlib.decompress(idat)
    stride = width * 4
    rows = []
    prev = bytearray(stride)
    p = 0
    for _ in range(height):
        ftype = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if ftype == 1:  # Sub
            for i in range(4, stride):
                line[i] = (line[i] + line[i - 4]) & 0xFF
        elif ftype == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:  # Average
            for i in range(stride):
                left = line[i - 4] if i >= 4 else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:  # Paeth
            for i in range(stride):
                a = line[i - 4] if i >= 4 else 0
                b = prev[i]
                c = prev[i - 4] if i >= 4 else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        elif ftype != 0:
            raise ValueError("bad filter type %d" % ftype)
        rows.append(bytes(line))
        prev = line
    return width, height, rows


def rgba_to_dib(width, height, rows):
    """A BITMAPINFOHEADER + bottom-up BGRA pixels + a 1-bit AND mask."""
    header = struct.pack("<IiiHHIIiiII", 40, width, height * 2, 1, 32, 0, width * height * 4, 0, 0, 0, 0)
    pixels = bytearray()
    for row in reversed(rows):
        for x in range(width):
            r, g, b, a = row[x * 4:x * 4 + 4]
            pixels += bytes((b, g, r, a))
    mask_stride = ((width + 31) // 32) * 4
    mask = bytearray()
    for row in reversed(rows):
        bits = bytearray(mask_stride)
        for x in range(width):
            if row[x * 4 + 3] == 0:
                bits[x // 8] |= 0x80 >> (x % 8)
        mask += bits
    return bytes(header) + bytes(pixels) + bytes(mask)


def build_ico():
    entries = []
    for size in SIZES:
        with open(png_path(size), "rb") as f:
            data = f.read()
        width, height, rows = decode_png_rgba(data)
        if (width, height) != (size, size):
            raise ValueError("%s is %dx%d, not %dx%d" % (png_path(size), width, height, size, size))
        payload = rgba_to_dib(width, height, rows) if size <= DIB_MAX else data
        entries.append((size, payload))
    out = bytearray(struct.pack("<HHH", 0, 1, len(entries)))
    offset = 6 + 16 * len(entries)
    for size, payload in entries:
        dim = 0 if size >= 256 else size  # 0 means 256 in the directory
        out += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(payload), offset)
        offset += len(payload)
    for _, payload in entries:
        out += payload
    return bytes(out)


def main(argv):
    ico = build_ico()
    if "--check" in argv:
        try:
            with open(OUT, "rb") as f:
                current = f.read()
        except FileNotFoundError:
            current = b""
        if current != ico:
            print("make-ico: %s is stale; run %s" % (OUT, os.path.relpath(__file__, REPO)), file=sys.stderr)
            return 1
        print("make-ico: %s is up to date (%d bytes, %d images)" % (OUT, len(ico), len(SIZES)))
        return 0
    with open(OUT, "wb") as f:
        f.write(ico)
    print("make-ico: wrote %s (%d bytes, %d images)" % (OUT, len(ico), len(SIZES)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
