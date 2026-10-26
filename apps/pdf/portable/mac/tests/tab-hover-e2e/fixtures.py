"""PDFs for the tab hover test: pages that say which page they are and which way is up.

Each page has a coloured band along its top edge (page 5's is the only red one), its number in large type under the
band, and a dark square in its bottom-left corner. A thumbnail of page 5 turned 90 degrees clockwise therefore has
red down its right edge and the square in its top-left corner.
"""
import os

BANDS = [(0.20, 0.45, 0.85), (0.10, 0.60, 0.35), (0.55, 0.30, 0.75), (0.85, 0.60, 0.10),
         (0.90, 0.05, 0.05), (0.15, 0.65, 0.70), (0.45, 0.45, 0.45), (0.70, 0.40, 0.20)]


def write_pdf(path, pages, width=300, height=420, label=""):
    objects = []

    def add(body):
        objects.append(body)
        return len(objects)

    font = add(b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica-Bold>>")
    pages_id = len(objects) + 2 * pages + 1
    kids = []
    for index in range(pages):
        r, g, b = BANDS[index % len(BANDS)]
        text = f"{index + 1}"
        stream = (f"q {r} {g} {b} rg 0 {height - 60} {width} 60 re f Q\n"
                  f"q 0.1 0.1 0.1 rg 16 16 56 56 re f Q\n"
                  f"BT /F1 120 Tf 0.1 0.1 0.1 rg {width / 2 - 34 * len(text)} {height / 2 - 40} Td ({text}) Tj ET\n"
                  f"BT /F1 14 Tf 0.3 0.3 0.3 rg 90 30 Td ({label}) Tj ET\n").encode()
        content = add(b"<</Length %d>>stream\n" % len(stream) + stream + b"endstream")
        kids.append(add(b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 %d %d]/Contents %d 0 R"
                        b"/Resources<</Font<</F1 %d 0 R>>>>>>" % (pages_id, width, height, content, font)))
    assert add(b"<</Type/Pages/Kids[%s]/Count %d>>" % (b" ".join(b"%d 0 R" % k for k in kids), pages)) == pages_id
    catalog = add(b"<</Type/Catalog/Pages %d 0 R>>" % pages_id)
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj" % number + body + b"endobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    for offset in offsets:
        out += b"%010d 00000 n \n" % offset
    out += b"trailer<</Size %d/Root %d 0 R>>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, catalog, xref)
    with open(path, "wb") as f:
        f.write(out)


def make_documents(folder, count=30):
    """The rotation document, a document with a long name, and count - 2 more; returns their paths in that order."""
    os.makedirs(folder, exist_ok=True)
    paths = [os.path.join(folder, "Plates for rotation.pdf"),
             os.path.join(folder, "Interface specification for the camera flex and its connector, revision C.pdf")]
    write_pdf(paths[0], 8, label="rotation")
    write_pdf(paths[1], 3, width=420, height=300, label="specification")
    for n in range(count - 2):
        path = os.path.join(folder, f"Supplier sheet {n + 1:02d}.pdf")
        write_pdf(path, 2 + n % 3, label=f"sheet {n + 1}")
        paths.append(path)
    return paths
