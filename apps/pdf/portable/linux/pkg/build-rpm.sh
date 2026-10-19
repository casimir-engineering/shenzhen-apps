#!/usr/bin/env bash
# Build the ShenzhenPDF RPM for Fedora.
#
#   portable/linux/pkg/build-rpm.sh <version> [<outdir>]
#
# Unlike build-deb.sh (which expects to run INSIDE the shenzhen-build
# container with a prebuilt binary), this script drives docker itself: it
# builds the shenzhen-build-fedora image (portable/linux/pkg/fedora), compiles
# the GTK4 binary inside it, then runs rpmbuild against shenzhenpdf.spec.
#
# The mupdf static libs are rebuilt with Fedora's toolchain into
# mupdf/build/release-fedora (slow the first time, cached across runs) so the
# Ubuntu libs at mupdf/build/release — which the deb/tarball builds link —
# are never touched. Likewise the app binary goes to portable/build-fedora/.
#
# Produces <outdir>/shenzhenpdf-<version>-1.<arch>.rpm.
set -euo pipefail

VERSION=${1:?usage: build-rpm.sh <version> [outdir]}
OUT=${2:-dist}
IMAGE=shenzhen-build-fedora

cd "$(dirname "$0")/../../.."   # repo root
docker build -t "$IMAGE" portable/linux/pkg/fedora

mkdir -p "$OUT"
docker run --rm -i --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e VERSION="$VERSION" -e OUT="$OUT" \
    -v "$PWD:/work" -w /work "$IMAGE" bash -euo pipefail -s <<'EOF'
make -C portable linux-gtk4 BUILD=build-fedora MUPDF_OUT=build/release-fedora
rpmbuild -bb portable/linux/pkg/shenzhenpdf.spec \
    --define "_topdir /tmp/rpmbuild" \
    --define "spdf_version $VERSION" \
    --define "spdf_src /work" \
    --define "spdf_bin /work/portable/build-fedora/ShenzhenPDF-gtk4" \
    > /tmp/rpmbuild.log 2>&1 || { cat /tmp/rpmbuild.log >&2; exit 1; }
RPM=$(ls /tmp/rpmbuild/RPMS/*/shenzhenpdf-"$VERSION"-1.*.rpm)
cp "$RPM" "$OUT/"
echo "$OUT/$(basename "$RPM")"
EOF
