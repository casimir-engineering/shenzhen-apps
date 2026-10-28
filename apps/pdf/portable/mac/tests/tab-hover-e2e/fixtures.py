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


def write_png(path, width, height, pixel):
    """An RGB PNG; pixel(x, y) gives (r, g, b) 0..255 with y counted from the top."""
    import struct
    import zlib
    rows = b"".join(b"\x00" + bytes(c for x in range(width) for c in pixel(x, y)) for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) +
                chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


MARKDOWN = """# Camera flex bring-up notes

The flex carries the sensor's four data lanes and its clock. **Every lane** is routed as a
100 ohm pair, matched to within 0.1 mm, over a solid ground on the next layer.

## Checks before power

1. Continuity of every lane pair, end to end.
2. No short between the 1.8 V and 2.8 V rails and ground.
3. The connector latch closes on both ends.

```c
static int sensor_power_on(void) {
    regulator_enable(avdd);   /* 2.8 V first */
    regulator_enable(dovdd);  /* then 1.8 V */
    return clock_enable(mclk, 24000000);
}
```

| Rail  | Volts | Current |
|-------|-------|---------|
| AVDD  | 2.8   | 60 mA   |
| DOVDD | 1.8   | 20 mA   |
| DVDD  | 1.1   | 180 mA  |

> Measure the rails at the connector, not at the regulator.
"""


def make_text_documents(folder):
    """A Markdown file, a landscape image (red band along its top, dark square bottom-left) and a plain text file;
    returns their paths in that order."""
    os.makedirs(folder, exist_ok=True)
    md, png, txt = (os.path.join(folder, name) for name in
                    ("Camera flex bring-up notes.md", "Flex photo, top side.png", "Sensor register dump.txt"))
    with open(md, "w") as f:
        f.write(MARKDOWN * 3)
    write_png(png, 400, 250, lambda x, y: (230, 20, 20) if y < 40 else (20, 20, 20) if x < 60 and y > 190
              else (200, 205, 215))
    with open(txt, "w") as f:
        for n in range(160):
            f.write(f"0x{0x3000 + n * 2:04x}  0x{(n * 37) & 0xFF:02x}  register {n:3d}  {'ok' if n % 7 else 'changed'}\n")
    return [md, png, txt]
