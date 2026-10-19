"""Generates the two launch-timing fixtures portable/win/measure-launch.ps1 uses.

    python portable/win/tests/make_launch_fixtures.py <out-dir>

Writes <out-dir>/pages120.pdf and <out-dir>/images.pdf. NOT committed: the
image fixture is tens of megabytes, and both are regenerated in seconds by
this script, which is plain stdlib (zlib for the images) like the other
fixture generators beside it.

WHY TWO. The committed fixtures are 2-6 KB and open in a millisecond, which
tells the launch harness nothing about the costs that scale with a document:

  pages120.pdf -- 120 letter pages of Helvetica body text with a 1-level
                  outline every 10 pages. Exercises page-count-proportional
                  work (a spdf_page_size sweep, an outline with 12 entries,
                  the minimap's sizing thread) without any one page being
                  expensive to render.

  images.pdf   -- 6 pages, each ONE distinct 1700x2200 RGB image (letter at
                  200 dpi, 11 MB raw, FlateDecode). A different image object
                  per page, so MuPDF's decoded-image store cannot make page
                  two free. This is the shape of a scanned document: the first
                  page's cost is the inflate plus a 2:1 downscale, not text.

Deterministic output: the same bytes every run, so a timing series is never
comparing two different documents.
"""
import sys
import zlib
import os


def pdf_string(text):
    return "(" + text.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)") + ")"


class Pdf:
    def __init__(self):
        self.objects = []  # list of bytes, index+1 is the object number

    def add(self, body):
        if isinstance(body, str):
            body = body.encode("latin-1")
        self.objects.append(body)
        return len(self.objects)

    def reserve(self):
        self.objects.append(None)
        return len(self.objects)

    def set(self, num, body):
        if isinstance(body, str):
            body = body.encode("latin-1")
        self.objects[num - 1] = body

    def write(self, path, root):
        out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
        offsets = []
        for i, body in enumerate(self.objects):
            assert body is not None, "object %d never set" % (i + 1)
            offsets.append(len(out))
            out += ("%d 0 obj\n" % (i + 1)).encode()
            out += body
            out += b"\nendobj\n"
        xref = len(out)
        out += ("xref\n0 %d\n" % (len(self.objects) + 1)).encode()
        out += b"0000000000 65535 f \n"
        for off in offsets:
            out += ("%010d 00000 n \n" % off).encode()
        out += ("trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (
            len(self.objects) + 1, root, xref)).encode()
        with open(path, "wb") as f:
            f.write(out)


def stream(dictionary, data):
    return ("<< %s /Length %d >>\nstream\n" % (dictionary, len(data))).encode("latin-1") + data + b"\nendstream"


def build_pages(path, page_count=120):
    pdf = Pdf()
    catalog = pdf.reserve()
    pages = pdf.reserve()
    outlines = pdf.reserve()
    font = pdf.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    w, h = 612, 792
    page_nums = []
    for i in range(page_count):
        lines = ["BT /F1 24 Tf 72 %d Td (Chapter %d, page %d) Tj ET" % (h - 90, i // 10 + 1, i + 1)]
        for k in range(40):
            y = h - 130 - k * 15
            lines.append("BT /F1 10.5 Tf 72 %d Td %s Tj ET" % (
                y, pdf_string("Line %02d of page %03d: the quick brown fox jumps over the lazy dog, "
                              "0123456789, and again the quick brown fox." % (k + 1, i + 1))))
        lines.append("0.75 G 0.5 w 72 %d m 540 %d l S" % (h - 100, h - 100))
        content = pdf.add(stream("", "\n".join(lines).encode("latin-1")))
        page = pdf.add("<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %d %d] /Contents %d 0 R "
                       "/Resources << /Font << /F1 %d 0 R >> >> >>" % (pages, w, h, content, font))
        page_nums.append(page)
    pdf.set(pages, "<< /Type /Pages /Count %d /Kids [%s] >>" % (
        page_count, " ".join("%d 0 R" % n for n in page_nums)))
    # A flat outline, one entry per ten pages.
    chapters = list(range(0, page_count, 10))
    item_nums = [pdf.reserve() for _ in chapters]
    for k, first_page in enumerate(chapters):
        body = "<< /Title %s /Parent %d 0 R /Dest [%d 0 R /XYZ 0 %d 0]" % (
            pdf_string("Chapter %d" % (k + 1)), outlines, page_nums[first_page], h)
        if k > 0:
            body += " /Prev %d 0 R" % item_nums[k - 1]
        if k + 1 < len(item_nums):
            body += " /Next %d 0 R" % item_nums[k + 1]
        pdf.set(item_nums[k], body + " >>")
    pdf.set(outlines, "<< /Type /Outlines /First %d 0 R /Last %d 0 R /Count %d >>" % (
        item_nums[0], item_nums[-1], len(item_nums)))
    pdf.set(catalog, "<< /Type /Catalog /Pages %d 0 R /Outlines %d 0 R >>" % (pages, outlines))
    pdf.write(path, catalog)


def image_bytes(width, height, seed):
    """A page-like picture: light paper, a dark band of 'text' rows, a gradient
    margin, all shifted by `seed` so every page's bytes differ. Cheap to
    generate, moderately compressible, expensive enough to inflate."""
    rows = bytearray()
    paper = bytes((245, 243, 238)) * width
    for y in range(height):
        band = (y + seed * 37) % 24
        if 200 < y < height - 200 and band < 10:
            # a row of "text": alternating dark runs, phase-shifted per row/page
            row = bytearray(paper)
            x = 60 + (y * 7 + seed * 13) % 40
            while x < width - 60:
                run = 8 + (x * 31 + y) % 14
                dark = bytes((30 + (y % 7), 30, 34)) * run
                row[x * 3:(x + run) * 3] = dark[: (min(x + run, width) - x) * 3]
                x += run + 6 + (x % 5)
            rows += row
        else:
            shade = 235 + (y * (seed + 1)) % 20
            rows += bytes((shade, shade - 2, shade - 6)) * width
    return bytes(rows)


def build_images(path, page_count=6, width=1700, height=2200):
    pdf = Pdf()
    catalog = pdf.reserve()
    pages = pdf.reserve()
    page_nums = []
    for i in range(page_count):
        raw = image_bytes(width, height, i)
        data = zlib.compress(raw, 1)
        img = pdf.add(stream("/Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB "
                             "/BitsPerComponent 8 /Filter /FlateDecode" % (width, height), data))
        content = pdf.add(stream("", b"q 612 0 0 792 0 0 cm /Im0 Do Q"))
        page = pdf.add("<< /Type /Page /Parent %d 0 R /MediaBox [0 0 612 792] /Contents %d 0 R "
                       "/Resources << /XObject << /Im0 %d 0 R >> >> >>" % (pages, content, img))
        page_nums.append(page)
    pdf.set(pages, "<< /Type /Pages /Count %d /Kids [%s] >>" % (
        page_count, " ".join("%d 0 R" % n for n in page_nums)))
    pdf.set(catalog, "<< /Type /Catalog /Pages %d 0 R >>" % pages)
    pdf.write(path, catalog)


def main(argv):
    if len(argv) != 2:
        sys.exit(__doc__)
    out = argv[1]
    os.makedirs(out, exist_ok=True)
    build_pages(os.path.join(out, "pages120.pdf"))
    build_images(os.path.join(out, "images.pdf"))
    for name in ("pages120.pdf", "images.pdf"):
        print("%s %d bytes" % (os.path.join(out, name), os.path.getsize(os.path.join(out, name))))


if __name__ == "__main__":
    main(sys.argv)
