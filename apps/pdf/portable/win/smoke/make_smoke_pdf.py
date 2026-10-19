#!/usr/bin/env python3
"""Write portable/win/smoke/smoke.pdf -- the fixture core_smoke renders on both hosts.

Generated rather than committed because the repo's root .gitignore excludes
`*.pdf`, and because a fixture whose recipe is readable is easier to extend than
1.8 KB of opaque bytes.

The content is chosen to put load on the parts of MuPDF most likely to diverge
between clang/arm64 and MSVC/ARM64:

  * text in two base-14 faces at several sizes -- FreeType hinting and the
    scan converter's anti-aliasing, i.e. the code with the most floating point
    per output pixel, plus the embedded URW CFF blobs from mupdf/generated/;
  * a bezier path and a stroked, dashed polyline -- flattening tolerance;
  * a rotated, scaled text matrix -- the full 6-value CTM path;
  * constant-alpha fills over other fills -- the blend/compositing path;
  * an inline RGB image scaled up -- the image sampler.

Byte-for-byte deterministic: no dates, no ids, no dict iteration order.
Owned by track T0 (portable/win/smoke/**).
"""
import os
import sys

PAGE_W, PAGE_H = 300, 400

CONTENT = b"""q
1 1 1 rg 0 0 300 400 re f
0.85 0.12 0.15 rg 20 330 120 50 re f
0.10 0.45 0.75 rg 160 330 120 50 re f
0.15 0.60 0.25 rg 20 270 260 40 re f
/GS1 gs 0.95 0.75 0.10 rg 60 290 180 70 re f
Q
q 0 0 0 RG 2 w [6 3] 0 d
30 250 m 90 265 l 150 235 l 210 265 l 270 245 l S
Q
q 0.35 0.15 0.60 rg
30 150 m 90 230 210 230 270 150 c 210 190 90 190 30 150 c f
Q
BT /F1 22 Tf 0 0 0 rg 24 120 Td (Shenzhen PDF Windows) Tj ET
BT /F1 11 Tf 0.2 0.2 0.2 rg 24 100 Td (mixed case gjpqy 0123456789 @#$%&) Tj ET
BT /F2 15 Tf 0 0 0.6 rg 24 78 Td (Times italic ligature: fi fl ffi) Tj ET
BT /F1 9 Tf 0 0 0 rg 24 60 Td 14 TL (kerning AV To Wa LTa) ' (hinting stress: iiimmm lll) ' ET
q 0.9659 0.2588 -0.2588 0.9659 200 40 cm
BT /F1 13 Tf 0.6 0 0.3 rg 0 0 Td (rotated 15 deg) Tj ET
Q
q 120 0 0 30 24 12 cm
BI /W 6 /H 2 /CS /RGB /BPC 8 /F /AHx ID
ff0000 00ff00 0000ff ffff00 00ffff ff00ff
202020 606060 a0a0a0 c0c0c0 e0e0e0 ffffff >
EI Q
"""

PAGE2 = b"""q 0.97 0.97 0.93 rg 0 0 300 400 re f Q
BT /F2 28 Tf 0.1 0.1 0.1 rg 30 330 Td (Page Two) Tj ET
q 0 0.4 0.4 RG 8 w 1 J 1 j
40 60 m 100 200 l 160 60 l 220 200 l S
Q
"""


def build():
    objs = [None]  # 1-based

    def add(body):
        objs.append(body)
        return len(objs) - 1

    content1 = add(b"<< /Length %d >>\nstream\n%s\nendstream" % (len(CONTENT), CONTENT))
    content2 = add(b"<< /Length %d >>\nstream\n%s\nendstream" % (len(PAGE2), PAGE2))
    f1 = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    f2 = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Times-Italic /Encoding /WinAnsiEncoding >>")
    gs1 = add(b"<< /Type /ExtGState /ca 0.45 /CA 0.45 >>")
    res = add(b"<< /Font << /F1 %d 0 R /F2 %d 0 R >> /ExtGState << /GS1 %d 0 R >> >>"
              % (f1, f2, gs1))
    pages = add(b"PLACEHOLDER")
    page1 = add(b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %d %d] /Resources %d 0 R /Contents %d 0 R >>"
                % (pages, PAGE_W, PAGE_H, res, content1))
    page2 = add(b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %d %d] /Resources %d 0 R /Contents %d 0 R >>"
                % (pages, PAGE_W, PAGE_H, res, content2))
    objs[pages] = b"<< /Type /Pages /Kids [%d 0 R %d 0 R] /Count 2 >>" % (page1, page2)
    catalog = add(b"<< /Type /Catalog /Pages %d 0 R >>" % pages)

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0] * len(objs)
    for i in range(1, len(objs)):
        offsets[i] = len(out)
        out += b"%d 0 obj\n" % i + objs[i] + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n" % len(objs)
    out += b"0000000000 65535 f \n"
    for i in range(1, len(objs)):
        out += b"%010d 00000 n \n" % offsets[i]
    out += b"trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs), catalog, xref)
    return bytes(out)


if __name__ == "__main__":
    dest = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "smoke.pdf")
    data = build()
    with open(dest, "wb") as fh:
        fh.write(data)
    print("wrote %s (%d bytes)" % (dest, len(data)))
