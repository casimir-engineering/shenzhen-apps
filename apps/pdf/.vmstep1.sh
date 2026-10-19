#!/bin/sh
cd /root/shenzhen-pdf/mupdf || exit 1
make -j2 build=release USE_SYSTEM_GLUT=yes brotli=no build/release/libmupdf-pkcs7.a >> /root/mupdf-build.log 2>&1
rsync -a --delete --exclude build /media/psf/Home/Projects/shenzhen-pdf/portable/ /root/shenzhen-pdf/portable/
ls build/release/libmupdf-pkcs7.a && grep -c MINIMAP_THUMB_MAX_BYTES /root/shenzhen-pdf/portable/linux/ShenzhenPDFGtk.c
