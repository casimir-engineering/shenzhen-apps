#!/usr/bin/env python3
"""Generate a synthetic multi-chapter PDF for GUI capture tests.

    make-test-pdf.py [out.pdf]

12 pages, 3 outline chapters, searchable text (repeating and unique tokens,
including one regex-friendly serial per page like SZP-0007), one landscape
page to exercise mixed-size layout. No dependencies beyond Python 3.
"""
import sys, zlib

def obj(n, body):
    return n, f"{n} 0 obj\n{body}\nendobj\n".encode()

CHAPTERS = [("Introduction", 0), ("Measurements", 4), ("Conclusions", 9)]
PAGES = 12

objs = []
page_ids = [10 + i for i in range(PAGES)]
content_ids = [10 + PAGES + i for i in range(PAGES)]

kids = " ".join(f"{p} 0 R" for p in page_ids)
objs.append(obj(1, "<< /Type /Catalog /Pages 2 0 R /Outlines 3 0 R /PageMode /UseOutlines >>"))
objs.append(obj(2, f"<< /Type /Pages /Kids [{kids}] /Count {PAGES} >>"))

first_out, last_out = 4, 4 + len(CHAPTERS) - 1
outline_children = []
for idx, (title, page_idx) in enumerate(CHAPTERS):
    n = 4 + idx
    prev = f" /Prev {n-1} 0 R" if idx > 0 else ""
    nxt = f" /Next {n+1} 0 R" if idx < len(CHAPTERS) - 1 else ""
    outline_children.append(obj(n, f"<< /Title ({title}) /Parent 3 0 R{prev}{nxt} "
                                   f"/Dest [{page_ids[page_idx]} 0 R /XYZ null null null] >>"))
objs.append(obj(3, f"<< /Type /Outlines /First {first_out} 0 R /Last {last_out} 0 R /Count {len(CHAPTERS)} >>"))
objs.extend(outline_children)
objs.append(obj(7, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"))

def chapter_of(i):
    name = CHAPTERS[0][0]
    for title, start in CHAPTERS:
        if i >= start:
            name = title
    return name

for i in range(PAGES):
    landscape = (i == 6)
    w, h = (1190, 420) if landscape else (612, 792)
    lines = [f"BT /F1 24 Tf 72 {h-90} Td ({chapter_of(i)} - page {i+1}) Tj ET",
             f"BT /F1 12 Tf 72 {h-130} Td (Serial SZP-{i+1:04d} calibration gasket rev C) Tj ET"]
    for j in range(12):
        y = h - 170 - 18 * j
        if y < 60:
            break
        lines.append(f"BT /F1 11 Tf 72 {y} Td (Line {j+1}: the quick brown fox inspects "
                     f"connector J{j+1} on page {i+1}.) Tj ET")
    if i == 10:
        lines.append(f"BT /F1 14 Tf 72 72 Td (needle-in-haystack: zhengzhou) Tj ET")
    stream = zlib.compress("\n".join(lines).encode())
    objs.append(obj(page_ids[i], f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {w} {h}] "
                                 f"/Resources << /Font << /F1 7 0 R >> >> /Contents {content_ids[i]} 0 R >>"))
    objs.append((content_ids[i], f"{content_ids[i]} 0 obj\n<< /Length {len(stream)} /Filter /FlateDecode >>\nstream\n".encode()
                 + stream + b"\nendstream\nendobj\n"))

out = bytearray(b"%PDF-1.5\n%\xe2\xe3\xcf\xd3\n")
offsets = {}
for n, data in sorted(objs):
    offsets[n] = len(out)
    out += data
maxn = max(offsets)
xref_at = len(out)
out += f"xref\n0 {maxn+1}\n0000000000 65535 f \n".encode()
for n in range(1, maxn + 1):
    out += (f"{offsets[n]:010d} 00000 n \n" if n in offsets else "0000000000 65535 f \n").encode()
out += (f"trailer\n<< /Size {maxn+1} /Root 1 0 R >>\nstartxref\n{xref_at}\n%%EOF\n").encode()

path = sys.argv[1] if len(sys.argv) > 1 else "test-chapters.pdf"
with open(path, "wb") as f:
    f.write(bytes(out))
print(path)
