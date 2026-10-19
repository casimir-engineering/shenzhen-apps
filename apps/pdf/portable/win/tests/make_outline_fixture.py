"""Generates portable/win/tests/fixtures/outline.pdf.

    python portable/win/tests/make_outline_fixture.py portable/win/tests/fixtures/outline.pdf

A tiny multi-page PDF with a two-level outline, for looking at the sidebar.

WHY IT EXISTS. Neither committed fixture has an outline (golden.pdf is a single
200x260 page), so before this there was no way to SEE the sidebar's chapter list
in a real window -- and the NASA scan the port has been using for screenshots
turns out to have no outline either, which is why it shows "No Chapters".

Four pages at three different sizes, including one 1224 pt foldout, so the
minimap's per-page aspect and its 2.5x-median clamp are both visible in one
screenshot. Same generator style as portable/win/tests/make_fixture_pdf.py:
plain stdlib, no PDF library, so it can be re-run anywhere.

Deliberately includes a UTF-16BE title with an umlaut and one with CJK
characters: those are written as PDF text strings with a BOM, which is what a
real document does, and they are the exact case a narrow conversion mangles.
"""
import sys

TITLES = [
    # (title, page index, level, has children)
    ("Introduction", 0, 0),
    ("Background", 0, 1),
    ("Uberblick mit Umlaut", 1, 1),
    ("Chapter Two", 1, 0),
    ("CJK section", 2, 1),
    ("Appendix", 3, 0),
]

# Titles that must be non-ASCII, by index into TITLES.
UNICODE_TITLES = {
    2: "Überblick mit Umlaut",
    4: "第一章 CJK section",
}

PAGES = 4
# Two page sizes so the minimap's per-page aspect shows, and one wide foldout so
# the 2.5x median cap has something to clamp.
SIZES = [(612, 792), (612, 792), (1224, 792), (612, 1008)]


def pdf_string(text):
    if all(ord(c) < 128 for c in text):
        return "(" + text.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)") + ")"
    data = b"\xfe\xff" + text.encode("utf-16-be")
    return "<" + data.hex().upper() + ">"


objects = {}


def content_for(i):
    w, h = SIZES[i]
    lines = [
        "BT /F1 36 Tf 60 %d Td (Page %d) Tj ET" % (h - 120, i + 1),
        "BT /F1 14 Tf 60 %d Td (ShenzhenPDF outline fixture) Tj ET" % (h - 170),
        "1 0 0 RG 4 w 40 40 %d %d re S" % (w - 80, h - 80),
    ]
    for k in range(12):
        y = h - 230 - k * 26
        lines.append("0.2 0.2 0.2 rg BT /F1 11 Tf 60 %d Td (Line %d of body text on page %d) Tj ET" % (y, k + 1, i + 1))
    return "\n".join(lines)


def build():
    out = []
    # 1 catalog, 2 pages, 3 outlines root, 4..4+PAGES-1 pages,
    # then contents, then outline items, then font.
    n_page0 = 4
    n_content0 = n_page0 + PAGES
    n_item0 = n_content0 + PAGES
    n_font = n_item0 + len(TITLES)

    objects[1] = "<< /Type /Catalog /Pages 2 0 R /Outlines 3 0 R /PageMode /UseOutlines >>"
    kids = " ".join("%d 0 R" % (n_page0 + i) for i in range(PAGES))
    objects[2] = "<< /Type /Pages /Count %d /Kids [%s] >>" % (PAGES, kids)

    tops = [i for i, t in enumerate(TITLES) if t[2] == 0]
    objects[3] = "<< /Type /Outlines /First %d 0 R /Last %d 0 R /Count %d >>" % (
        n_item0 + tops[0], n_item0 + tops[-1], len(TITLES))

    for i in range(PAGES):
        w, h = SIZES[i]
        objects[n_page0 + i] = (
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] "
            "/Resources << /Font << /F1 %d 0 R >> >> /Contents %d 0 R >>"
            % (w, h, n_font, n_content0 + i))

    for i in range(PAGES):
        body = content_for(i)
        objects[n_content0 + i] = "<< /Length %d >>\nstream\n%s\nendstream" % (len(body) + 1, body)

    for idx, (title, page, level) in enumerate(TITLES):
        text = UNICODE_TITLES.get(idx, title)
        parts = ["/Title %s" % pdf_string(text),
                 "/Dest [%d 0 R /XYZ 60 700 0]" % (n_page0 + page)]
        # Parent: the nearest preceding level-0 item, or the root.
        if level == 0:
            parts.append("/Parent 3 0 R")
        else:
            parent = max(j for j in range(idx) if TITLES[j][2] == 0)
            parts.append("/Parent %d 0 R" % (n_item0 + parent))
        siblings = [j for j, t in enumerate(TITLES) if t[2] == level and
                    (level == 0 or max(k for k in range(j) if TITLES[k][2] == 0) ==
                     max(k for k in range(idx) if TITLES[k][2] == 0))]
        pos = siblings.index(idx)
        if pos > 0:
            parts.append("/Prev %d 0 R" % (n_item0 + siblings[pos - 1]))
        if pos < len(siblings) - 1:
            parts.append("/Next %d 0 R" % (n_item0 + siblings[pos + 1]))
        children = [j for j, t in enumerate(TITLES) if t[2] == 1 and
                    max(k for k in range(j) if TITLES[k][2] == 0) == idx]
        if level == 0 and children:
            parts.append("/First %d 0 R /Last %d 0 R /Count %d" %
                         (n_item0 + children[0], n_item0 + children[-1], len(children)))
        objects[n_item0 + idx] = "<< %s >>" % " ".join(parts)

    objects[n_font] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"

    buf = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}
    for num in sorted(objects):
        offsets[num] = len(buf)
        buf += ("%d 0 obj\n%s\nendobj\n" % (num, objects[num])).encode("latin-1")
    start = len(buf)
    count = max(objects) + 1
    buf += ("xref\n0 %d\n" % count).encode()
    buf += b"0000000000 65535 f \n"
    for num in range(1, count):
        buf += ("%010d 00000 n \n" % offsets[num]).encode()
    buf += ("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (count, start)).encode()
    return bytes(buf)


open(sys.argv[1], "wb").write(build())
print("wrote", sys.argv[1])
