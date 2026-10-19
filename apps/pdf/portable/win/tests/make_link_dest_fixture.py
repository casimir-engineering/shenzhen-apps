"""Generates portable/win/tests/fixtures/link_dest.pdf.

    python portable/win/tests/make_link_dest_fixture.py portable/win/tests/fixtures/link_dest.pdf

WHY IT EXISTS. selection.pdf already carries one internal /GoTo, but its
destination is written as a direct array on the last of three pages, so at any
viewport big enough to be interesting the scroll to it CLAMPS at the document's
end -- which makes "landed at the destination's y" and "landed at the page's
top" the same number, and therefore unprovable. This fixture is built so the
difference is always visible:

  * EIGHT pages of 612x792, so a destination partway down page 4 leaves four
    more pages of travel below it and nothing clamps;
  * link A resolves a NAMED destination -- /A << /S /GoTo /D (chapter-two) >>,
    looked up through BOTH the catalog's /Dests dictionary and its /Names /Dests
    name tree, which is what a real authoring tool writes -- to page 4 at
    /XYZ 72 560, i.e. 792 - 560 = 232 pt DOWN that page;
  * link B resolves a direct-array destination to page 6 at /XYZ 72 150, 642 pt
    down, which is far enough to prove the offset is scaled by the zoom rather
    than added as points;
  * link C is /Fit-style -- /D [<page 8> /Fit] -- which carries NO point at all,
    the case that must fall back to the page's start;
  * link D is an external /URI, which is the one kind of link that must NOT be
    followed the instant the button comes up.

Deliberately no outline: destinations reached from an outline entry arrive in
PDF user space (spdf_outline_item.dest_y, y UP) and destinations reached from a
link annotation arrive in page space (y DOWN). Mixing the two in one fixture
invites a test that passes for the wrong reason.

Same generator style as make_outline_fixture.py and make_selection_fixture.py:
plain stdlib, no PDF library, so it can be re-run anywhere.
"""
import sys

PAGES = 8
SIZE = (612, 792)

# Annotation rects in PDF USER SPACE (origin bottom-left, y up), each a little
# larger than the 18 pt line it sits on.
RECTS = {
    "A": (70, 672, 380, 698),
    "B": (70, 632, 380, 658),
    "C": (70, 592, 380, 618),
    "D": (70, 552, 380, 578),
}
LABELS = {
    "A": "Named destination on page four",
    "B": "Array destination on page six",
    "C": "Fit destination on page eight",
    "D": "External link",
}

DEST_NAME = "chapter-two"
# (page index, PDF user-space y). The page-space offset a resolver reports is
# 792 - y, which is what the tests compute rather than hard-code.
NAMED_DEST = (3, 560)
ARRAY_DEST = (5, 150)
FIT_DEST = 7
URI = "https://example.invalid/shenzhen-links"

objects = {}


def page_content(index):
    w, h = SIZE
    lines = [
        "BT /F1 30 Tf 72 %d Td (Page %d) Tj ET" % (h - 90, index + 1),
        "BT /F1 12 Tf 72 %d Td (ShenzhenPDF link-destination fixture) Tj ET" % (h - 120),
    ]
    if index == 0:
        for key in ("A", "B", "C", "D"):
            lines.append("0 0 0.8 rg BT /F1 18 Tf 72 %d Td (%s) Tj ET 0 0 0 rg"
                         % (RECTS[key][1] + 6, LABELS[key]))
    # A ruled body so a screenshot shows WHERE on the page the viewport starts.
    for k in range(20):
        y = h - 200 - k * 28
        if y < 60:
            break
        lines.append("0.2 0.2 0.2 rg BT /F1 11 Tf 72 %d Td "
                     "(Page %d line %d at user-space y %d) Tj ET" % (y, index + 1, k + 1, y))
    return "\n".join(lines)


def stream(body):
    return "<< /Length %d >>\nstream\n%s\nendstream" % (len(body) + 1, body)


def build():
    n_page0 = 4                      # 1 catalog, 2 pages, 3 font
    n_content0 = n_page0 + PAGES
    n_annot0 = n_content0 + PAGES    # A, B, C, D
    n_dest = n_annot0 + 4            # the named destination's own array
    n_names = n_dest + 1             # the /Names /Dests name tree node
    n_dests_dict = n_names + 1       # the catalog's /Dests dictionary
    w, h = SIZE

    objects[1] = ("<< /Type /Catalog /Pages 2 0 R /Dests %d 0 R "
                  "/Names << /Dests %d 0 R >> >>" % (n_dests_dict, n_names))
    kids = " ".join("%d 0 R" % (n_page0 + i) for i in range(PAGES))
    objects[2] = "<< /Type /Pages /Count %d /Kids [%s] >>" % (PAGES, kids)
    objects[3] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"

    for i in range(PAGES):
        annots = ""
        if i == 0:
            annots = " /Annots [%s]" % " ".join("%d 0 R" % (n_annot0 + k) for k in range(4))
        objects[n_page0 + i] = (
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] "
            "/Resources << /Font << /F1 3 0 R >> >> /Contents %d 0 R%s >>"
            % (w, h, n_content0 + i, annots))
        objects[n_content0 + i] = stream(page_content(i))

    # The named destination, referenced by name from link A and by the two
    # lookup tables below -- one object, so the two tables cannot disagree.
    objects[n_dest] = "[%d 0 R /XYZ 72 %d 0]" % (n_page0 + NAMED_DEST[0], NAMED_DEST[1])
    objects[n_names] = "<< /Names [(%s) %d 0 R] >>" % (DEST_NAME, n_dest)
    objects[n_dests_dict] = "<< /%s %d 0 R >>" % (DEST_NAME, n_dest)

    def annot(rect, action):
        return ("<< /Type /Annot /Subtype /Link /Rect [%d %d %d %d] /Border [0 0 0] "
                "/A << %s >> >>" % (rect + (action,)))

    objects[n_annot0 + 0] = annot(RECTS["A"], "/S /GoTo /D (%s)" % DEST_NAME)
    objects[n_annot0 + 1] = annot(RECTS["B"], "/S /GoTo /D [%d 0 R /XYZ 72 %d 0]"
                                  % (n_page0 + ARRAY_DEST[0], ARRAY_DEST[1]))
    objects[n_annot0 + 2] = annot(RECTS["C"], "/S /GoTo /D [%d 0 R /Fit]" % (n_page0 + FIT_DEST))
    objects[n_annot0 + 3] = annot(RECTS["D"], "/S /URI /URI (%s)" % URI)

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
