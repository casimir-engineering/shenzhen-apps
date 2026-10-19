#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 path/to/SPDFCorePasswordTests" >&2
    exit 2
fi
if ! command -v qpdf >/dev/null 2>&1; then
    echo "qpdf is required to generate encrypted PDF fixtures" >&2
    exit 2
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/spdf-password-tests.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

python3 - "$tmp_dir/plain.pdf" <<'PY'
import sys

path = sys.argv[1]
objects = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
stream = b"BT /F1 24 Tf 36 110 Td (Encrypted fixture) Tj ET\n0 0 1 rg 36 40 180 30 re f\n"
objects.append(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"endstream")

pdf = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
offsets = [0]
for number, body in enumerate(objects, 1):
    offsets.append(len(pdf))
    pdf.extend(f"{number} 0 obj\n".encode())
    pdf.extend(body)
    pdf.extend(b"\nendobj\n")
xref = len(pdf)
pdf.extend(f"xref\n0 {len(objects) + 1}\n".encode())
pdf.extend(b"0000000000 65535 f \n")
for offset in offsets[1:]:
    pdf.extend(f"{offset:010d} 00000 n \n".encode())
pdf.extend(f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
with open(path, "wb") as output:
    output.write(pdf)
PY

qpdf --encrypt user-secret owner-secret 256 -- "$tmp_dir/plain.pdf" "$tmp_dir/locked.pdf"
qpdf --encrypt '' owner-secret 256 -- "$tmp_dir/plain.pdf" "$tmp_dir/owner-only.pdf"
qpdf --encrypt view-secret owner-secret 256 --print=low --extract=n --modify=none -- \
    "$tmp_dir/plain.pdf" "$tmp_dir/restricted.pdf"

"$1" "$tmp_dir/plain.pdf" "$tmp_dir/locked.pdf" "$tmp_dir/owner-only.pdf" "$tmp_dir/restricted.pdf"
