#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
renderer="$script_dir/make-shenzhen-pdf-logo.swift"

command -v swift >/dev/null 2>&1 || { echo "error: swift not found" >&2; exit 1; }
command -v magick >/dev/null 2>&1 || { echo "error: ImageMagick not found" >&2; exit 1; }

declare -a sizes=(16 32 48 64 128 256 512 1024)
for size in "${sizes[@]}"; do
    swift "$renderer" "$script_dir/ShenzhenPDF-${size}x${size}x32.png" "$size"
done

# Legacy Windows and installer consumers still use the SumatraPDF filenames.
for size in 16 32 48 128 256; do
    cp "$script_dir/ShenzhenPDF-${size}x${size}x32.png" \
        "$script_dir/SumatraPDF-${size}x${size}x32.png"
done

ico_sources=()
for size in 16 32 48 64 128 256; do
    ico_sources+=("$script_dir/ShenzhenPDF-${size}x${size}x32.png")
done
magick "${ico_sources[@]}" "$script_dir/SumatraPDF.ico"
cp "$script_dir/SumatraPDF.ico" "$script_dir/SumatraPDF-smaller.ico"
cp "$script_dir/SumatraPDF.ico" "$script_dir/PdfDoc.ico"
cp "$script_dir/SumatraPDF.ico" "$script_dir/pdf-32bit.ico"
cp "$script_dir/SumatraPDF.ico" "$repo_root/docs/favicon.ico"

# Windows AppX/Store surfaces.
swift "$renderer" "$repo_root/appx/SumatraPDF_44x44.png" 44
swift "$renderer" "$repo_root/appx/SumatraPDF_StoreLogo_150x150.png" 150
swift "$renderer" "$repo_root/appx/SumatraLogo310x310.png" 310
cp "$script_dir/ShenzhenPDF-256x256x32.png" "$repo_root/appx/fileicon.png"
tmp_tile="$(mktemp "${TMPDIR:-/tmp}/spdf-wide-tile.XXXXXX.png")"
trap 'rm -f "$tmp_tile"' EXIT
swift "$renderer" "$tmp_tile" 150
magick -size 310x150 xc:transparent "$tmp_tile" -gravity center -composite -strip \
    "$repo_root/appx/SumatraLogo310x150.png"

echo "Regenerated Shenzhen PDF application icons for macOS, Windows, and Linux."
