"""Generates portable/win/tests/fixtures/selection.pdf.

    python portable/win/tests/make_selection_fixture.py portable/win/tests/fixtures/selection.pdf

WHY IT EXISTS. None of the three committed fixtures can test selection, copy or
links end to end:

  * golden.pdf is a single 200x260 page of graphics,
  * alpha.pdf exists for the premultiplied-alpha detectors,
  * outline.pdf has plenty of page text but all of it plain ASCII, and its
    accented and CJK strings are OUTLINE TITLES -- document metadata, not page
    content, so nothing in it is selectable non-ASCII text. It also has no link
    annotations at all, only outline destinations.

So this one carries, on page 1:

  * a plain ASCII line, for the ordinary range/word/block selection cases;
  * "Cafe resume naive" WITH its accents, drawn through /WinAnsiEncoding, which
    is what a real Western-European PDF does;
  * a CJK line, which is the case a narrow CP1252 clipboard format destroys
    silently on this machine (its ANSI code page is 1252);
  * an INTERNAL link annotation to page 3 and an EXTERNAL /URI one, which is
    what the cursor's hand and the click that follows a link need.

HOW THE CJK IS DONE WITHOUT EMBEDDING A FONT. The same trick
portable/core/tests/SPDFCoreCJKSelectionTests.c uses, and for the same reason
(plain stdlib, no PDF library, regenerable anywhere): an invisible (3 Tr)
glyphless Type3 font whose glyph outlines are empty, with a /ToUnicode CMap
carrying the real characters. MuPDF's structured text then reports the CJK
codepoints, which is exactly what an OCRmyPDF/Tesseract text layer looks like
and exactly what selection has to cope with in the field. The text draws
nothing, so page 1 renders as its Latin lines only -- deliberate: the CJK case
is about what COPIES, not about what a font renderer draws.

Same generator style as make_outline_fixture.py and make_fixture_pdf.py.
"""
import sys

PAGES = 3
SIZE = (612, 792)

# Type3 codes -> the characters their ToUnicode maps to.
CJK = [("A", 0x4E2D), ("B", 0x6587), ("C", 0x6D4B), ("D", 0x8BD5)]  # 中 文 测 试

ASCII_LINE = "Selection fixture alpha"
# WinAnsi octal escapes: e-acute is \351, i-diaeresis is \357.
LATIN_LINE = r"Caf\351 r\351sum\351 na\357ve"
LINK_LINE = "Jump to page three"
URI_LINE = "Visit the web"
URI = "https://example.invalid/shenzhen"

# Annotation rects in PDF USER SPACE (origin bottom-left, y up), each drawn a
# little larger than the 18 pt line it sits on.
LINK_RECT = (70, 552, 260, 578)
URI_RECT = (70, 512, 260, 538)

objects = {}


def page_content(index):
    if index == 0:
        codes = "".join(c for c, _ in CJK)
        return "\n".join([
            "BT /F1 18 Tf 72 700 Td (%s) Tj ET" % ASCII_LINE,
            "BT /F1 18 Tf 72 670 Td (%s) Tj ET" % LATIN_LINE,
            "BT /F2 18 Tf 3 Tr 72 630 Td (%s) Tj 0 Tr ET" % codes,
            "0 0 0.8 rg BT /F1 18 Tf 72 560 Td (%s) Tj ET" % LINK_LINE,
            "0 0 0.8 rg BT /F1 18 Tf 72 520 Td (%s) Tj ET" % URI_LINE,
            "0 0 0 rg BT /F1 12 Tf 72 460 Td (Body text below the links, for a range drag.) Tj ET",
        ])
    if index == 1:
        return "BT /F1 18 Tf 72 700 Td (Second page body) Tj ET"
    return "BT /F1 18 Tf 72 700 Td (Third page target) Tj ET"


def tounicode():
    entries = "".join("<%02X> <%04X>\n" % (ord(c), u) for c, u in CJK)
    return (
        "/CIDInit /ProcSet findresource begin\n"
        "12 dict begin\n"
        "begincmap\n"
        "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
        "/CMapName /Adobe-Identity-UCS def\n"
        "/CMapType 2 def\n"
        "1 begincodespacerange\n<00> <FF>\nendcodespacerange\n"
        "%d beginbfchar\n%sendbfchar\n"
        "endcmap\n"
        "CMapName currentdict /CMap defineresource pop\n"
        "end\nend\n" % (len(CJK), entries))


def stream(body):
    return "<< /Length %d >>\nstream\n%s\nendstream" % (len(body) + 1, body)


def build():
    # 1 catalog, 2 pages, 3..5 pages, 6..8 contents, 9 F1, 10 F2 (Type3),
    # 11 ToUnicode, 12 empty glyph, 13 internal link annot, 14 URI annot.
    n_page0, n_content0 = 3, 6
    n_f1, n_f2, n_tounicode, n_glyph, n_link, n_uri = 9, 10, 11, 12, 13, 14
    w, h = SIZE

    objects[1] = "<< /Type /Catalog /Pages 2 0 R >>"
    kids = " ".join("%d 0 R" % (n_page0 + i) for i in range(PAGES))
    objects[2] = "<< /Type /Pages /Count %d /Kids [%s] >>" % (PAGES, kids)

    for i in range(PAGES):
        annots = " /Annots [%d 0 R %d 0 R]" % (n_link, n_uri) if i == 0 else ""
        objects[n_page0 + i] = (
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] "
            "/Resources << /Font << /F1 %d 0 R /F2 %d 0 R >> >> /Contents %d 0 R%s >>"
            % (w, h, n_f1, n_f2, n_content0 + i, annots))
        objects[n_content0 + i] = stream(page_content(i))

    objects[n_f1] = ("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica "
                     "/Encoding /WinAnsiEncoding >>")

    first, last = ord(CJK[0][0]), ord(CJK[-1][0])
    differences = "[%d %s]" % (first, " ".join("/empty" for _ in CJK))
    widths = "[%s]" % " ".join("500" for _ in CJK)
    objects[n_f2] = (
        "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 500 1000] "
        "/FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /empty %d 0 R >> "
        "/Encoding << /Type /Encoding /Differences %s >> "
        "/FirstChar %d /LastChar %d /Widths %s /ToUnicode %d 0 R >>"
        % (n_glyph, differences, first, last, widths, n_tounicode))
    objects[n_tounicode] = stream(tounicode())
    objects[n_glyph] = stream("500 0 d0")

    objects[n_link] = (
        "<< /Type /Annot /Subtype /Link /Rect [%d %d %d %d] /Border [0 0 0] "
        "/A << /S /GoTo /D [%d 0 R /XYZ 60 700 0] >> >>"
        % (LINK_RECT + (n_page0 + 2,)))
    objects[n_uri] = (
        "<< /Type /Annot /Subtype /Link /Rect [%d %d %d %d] /Border [0 0 0] "
        "/A << /S /URI /URI (%s) >> >>" % (URI_RECT + (URI,)))

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
    buf += ("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"
            % (count, start)).encode()
    return bytes(buf)


open(sys.argv[1], "wb").write(build())
print("wrote", sys.argv[1])
