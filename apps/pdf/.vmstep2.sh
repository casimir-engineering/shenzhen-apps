#!/bin/sh
rsync -a --delete --exclude build /media/psf/Home/Projects/shenzhen-pdf/portable/ /root/shenzhen-pdf/portable/
cd /root/shenzhen-pdf/portable && make linux 2>&1 | tail -2 && ./build/ShenzhenPDF-gtk --version
