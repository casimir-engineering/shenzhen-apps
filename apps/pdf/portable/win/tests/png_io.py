#!/usr/bin/env python3
"""Dependency-free PNG reading and writing for the Windows headless harness.

Split out of compare_png.py so the comparison logic stays readable and both
files stay under the repo's 500-line cap (tools/file-size-limits.md).

WHY NOT PILLOW. This codec is the floor the entire Windows port's visual
verification stands on. A third-party imaging library would mean the port's
tests could fail -- or, far worse, silently change what "the same image" means --
for reasons having nothing to do with the port. zlib is in the stdlib; PNG's
filter set is five cases; the whole thing is under 150 lines. That is a better
trade than a dependency.

The decoder is deliberately strict: it refuses formats it does not fully
understand rather than approximating them, because a comparator reasoning about
mis-decoded pixels would report confident nonsense.

Everything is normalised to one representation -- 8-bit straight-alpha RGBA,
tightly packed, top-down -- so no caller has to care what the file said.
"""

import struct
import zlib


class DecodeError(Exception):
    pass


class Image:
    __slots__ = ("width", "height", "px")

    def __init__(self, width, height, px):
        self.width = width
        self.height = height
        self.px = px  # bytearray, len == width * height * 4 (or *3 when composited)

    def row(self, y):
        s = y * self.width * 4
        return self.px[s:s + self.width * 4]


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def decode_png(path):
    """8- or 16-bit greyscale, RGB, greyscale+alpha, RGBA or palette;
    non-interlaced. Raises DecodeError on anything else."""
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise DecodeError("%s: not a PNG" % path)

    pos, idat, hdr, palette, trns = 8, [], None, None, None
    while pos + 8 <= len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            hdr = struct.unpack(">IIBBBBB", body)
        elif ctype == b"IDAT":
            idat.append(body)
        elif ctype == b"PLTE":
            palette = body
        elif ctype == b"tRNS":
            trns = body
        elif ctype == b"IEND":
            break
    if hdr is None:
        raise DecodeError("%s: no IHDR" % path)

    w, h, depth, color, comp, filt, interlace = hdr
    if interlace:
        raise DecodeError("%s: interlaced PNG is not supported" % path)
    if comp != 0 or filt != 0:
        raise DecodeError("%s: unsupported compression/filter method" % path)
    if depth not in (8, 16):
        raise DecodeError("%s: unsupported bit depth %d" % (path, depth))
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color)
    if channels is None:
        raise DecodeError("%s: unsupported colour type %d" % (path, color))
    if color == 3 and (palette is None or depth != 8):
        raise DecodeError("%s: unsupported palette image" % path)

    bpp = max(1, channels * depth // 8)
    stride = (w * channels * depth + 7) // 8
    raw = zlib.decompress(b"".join(idat))
    if len(raw) < (stride + 1) * h:
        raise DecodeError("%s: truncated image data" % path)

    out = bytearray(stride * h)
    prev = bytearray(stride)
    src = 0
    for y in range(h):
        ftype = raw[src]
        line = bytearray(raw[src + 1:src + 1 + stride])
        src += 1 + stride
        if ftype == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ftype == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                upleft = prev[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + _paeth(left, prev[i], upleft)) & 0xFF
        elif ftype != 0:
            raise DecodeError("%s: bad filter type %d on row %d" % (path, ftype, y))
        out[y * stride:(y + 1) * stride] = line
        prev = line

    return _to_rgba(out, w, h, stride, depth, color, channels, palette, trns, path)


def _to_rgba(raw, w, h, stride, depth, color, channels, palette, trns, path):
    px = bytearray(w * h * 4)
    step = channels * (depth // 8)
    hi = depth == 16  # keep the high byte: 16-bit goldens are not expected
    d = 0
    for y in range(h):
        base = y * stride
        for x in range(w):
            s = base + x * step
            if color == 3:
                idx = raw[s]
                if palette is None or idx * 3 + 2 >= len(palette):
                    raise DecodeError("%s: palette index out of range" % path)
                r, g, b = palette[idx * 3], palette[idx * 3 + 1], palette[idx * 3 + 2]
                a = trns[idx] if trns is not None and idx < len(trns) else 255
            elif channels == 1:
                r = g = b = raw[s]
                a = 255
            elif channels == 2:
                r = g = b = raw[s]
                a = raw[s + (2 if hi else 1)]
            elif channels == 3:
                r, g, b = (raw[s], raw[s + 2], raw[s + 4]) if hi else (raw[s], raw[s + 1], raw[s + 2])
                a = 255
            elif hi:
                r, g, b, a = raw[s], raw[s + 2], raw[s + 4], raw[s + 6]
            else:
                r, g, b, a = raw[s], raw[s + 1], raw[s + 2], raw[s + 3]
            px[d] = r
            px[d + 1] = g
            px[d + 2] = b
            px[d + 3] = a
            d += 4
    return Image(w, h, px)


def encode_png(path, img):
    """Filter-0 RGBA writer, used by the self-test to build the mutated images
    the detectors are proven against."""
    raw = bytearray()
    for y in range(img.height):
        raw.append(0)
        raw += img.row(y)
    out = bytearray(b"\x89PNG\r\n\x1a\n")
    for ctype, body in (
        (b"IHDR", struct.pack(">IIBBBBB", img.width, img.height, 8, 6, 0, 0, 0)),
        (b"IDAT", zlib.compress(bytes(raw), 6)),
        (b"IEND", b""),
    ):
        out += struct.pack(">I", len(body)) + ctype + body
        out += struct.pack(">I", zlib.crc32(ctype + body) & 0xFFFFFFFF)
    with open(path, "wb") as fh:
        fh.write(out)
