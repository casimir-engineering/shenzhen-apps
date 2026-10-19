#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

command -v magick >/dev/null 2>&1 || { echo "error: ImageMagick not found" >&2; exit 1; }

assert_png_size() {
    local path="$1"
    local expected="$2"
    local actual
    actual="$(magick identify -format '%wx%h' "$path")"
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
    actual_frames="$(magick identify -format '%wx%h\n' "$script_dir/$icon")"
    [[ "$actual_frames" == "$expected_frames" ]] || {
        echo "unexpected frame set in $script_dir/$icon" >&2
        printf 'expected:\n%s\nactual:\n%s\n' "$expected_frames" "$actual_frames" >&2
        exit 1
    }
done
cmp "$script_dir/SumatraPDF.ico" "$repo_root/docs/favicon.ico"

echo "Shenzhen PDF icon assets are complete and internally consistent."
