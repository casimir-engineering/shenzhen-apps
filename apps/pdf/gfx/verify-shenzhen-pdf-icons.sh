#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# Sizes read straight from the files (PNG header, ICO directory), so nothing beyond python3 is needed.
image_sizes() {
    python3 -I -c '
import struct, sys
data = open(sys.argv[1], "rb").read()
if data[:8] == b"\x89PNG\r\n\x1a\n":
    print("%dx%d" % struct.unpack(">II", data[16:24]))
else:
    for i in range(struct.unpack("<H", data[4:6])[0]):
        w, h = data[6 + 16 * i], data[7 + 16 * i]
        print("%dx%d" % (w or 256, h or 256))
' "$1"
}

assert_png_size() {
    local path="$1"
    local expected="$2"
    local actual
    actual="$(image_sizes "$path")"
    [[ "$actual" == "$expected" ]] || {
        echo "wrong dimensions for $path: expected $expected, got $actual" >&2
        exit 1
    }
}

for size in 16 32 48 64 128 256 512 1024; do
    assert_png_size "$script_dir/ShenzhenPDF-${size}x${size}x32.png" "${size}x${size}"
done

for size in 16 32 48 128 256; do
    cmp "$script_dir/ShenzhenPDF-${size}x${size}x32.png" \
        "$script_dir/SumatraPDF-${size}x${size}x32.png"
done

expected_frames=$'16x16\n32x32\n48x48\n64x64\n128x128\n256x256'
for icon in SumatraPDF.ico SumatraPDF-smaller.ico PdfDoc.ico pdf-32bit.ico; do
    actual_frames="$(image_sizes "$script_dir/$icon")"
    [[ "$actual_frames" == "$expected_frames" ]] || {
        echo "unexpected frame set in $script_dir/$icon" >&2
        printf 'expected:\n%s\nactual:\n%s\n' "$expected_frames" "$actual_frames" >&2
        exit 1
    }
done
cmp "$script_dir/SumatraPDF.ico" "$repo_root/docs/favicon.ico"

echo "Shenzhen PDF icon assets are complete and internally consistent."
