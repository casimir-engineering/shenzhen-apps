#!/usr/bin/env bash
# Build the ShenzhenPDF .deb from an already-built GTK4 binary.
#
#   portable/linux/pkg/build-deb.sh <version> [<binary>] [<outdir>]
#
# Produces <outdir>/shenzhenpdf_<version>_amd64.deb (artifact name used by the
# in-app updater: ShenzhenPDF-linux-amd64.deb when uploaded to a release —
# see pkg/README.md). Run inside the shenzhen-build container or any system
# with dpkg-deb.
set -euo pipefail

VERSION=${1:?usage: build-deb.sh <version> [binary] [outdir]}
BIN=${2:-portable/build/ShenzhenPDF-gtk4}
OUT=${3:-dist}
ARCH=amd64

[ -f "$BIN" ] || { echo "binary not found: $BIN (build with make -C portable linux-gtk4)" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

install -Dm755 "$BIN" "$STAGE/usr/bin/shenzhenpdf"
install -Dm644 portable/linux/pkg/shenzhenpdf.desktop \
    "$STAGE/usr/share/applications/shenzhenpdf.desktop"
for size in 16 32 48 128 256; do
    src="gfx/ShenzhenPDF-${size}x${size}x32.png"
    [ -f "$src" ] && install -Dm644 "$src" \
        "$STAGE/usr/share/icons/hicolor/${size}x${size}/apps/shenzhenpdf.png"
done
install -Dm644 portable/linux/pkg/minisign.pub \
    "$STAGE/usr/share/shenzhenpdf/minisign.pub"

mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: shenzhenpdf
Version: $VERSION
Section: text
Priority: optional
Architecture: $ARCH
Depends: libgtk-4-1 (>= 4.14), libadwaita-1-0 (>= 1.4), libssl3t64 | libssl3, libc6 (>= 2.38)
Recommends: xdg-utils
Suggests: ocrmypdf, tesseract-ocr
Maintainer: Casimir Engineering <releases@casimir.engineering>
Homepage: https://github.com/casimir-engineering/shenzhen-pdf
Description: Fast, tabbed PDF reader with on-device OCR and translation
 ShenzhenPDF opens PDFs (and XPS, EPUB, CBZ, images) instantly, keeps
 documents in tidy tabs, and does OCR and translation entirely on-device.
 GTK4 frontend sharing its core with the macOS app.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
EOF
chmod 755 "$STAGE/DEBIAN/postinst"
cp "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"

mkdir -p "$OUT"
DEB="$OUT/shenzhenpdf_${VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB" >/dev/null
echo "$DEB"
