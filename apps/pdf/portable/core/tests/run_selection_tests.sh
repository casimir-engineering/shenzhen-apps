#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
output="${TMPDIR:-/tmp}/spdf-core-selection-tests.$$"
library_dir="mupdf/${MUPDF_OUT:-build/release}"
frameworks=""
trap 'rm -f "$output"' EXIT HUP INT TERM

cd "$repo_root"
if [ "$(uname -s)" = Darwin ]; then
    frameworks="-framework Foundation"
fi
for test_source in SPDFCoreSelectionTests.c SPDFCoreCJKSelectionTests.c; do
    "${CC:-cc}" -O2 -Wall -Wextra -Iportable/core -Imupdf/include \
        "portable/core/tests/$test_source" \
        portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c \
        portable/core/spdf_selection_support.c portable/core/spdf_recolor.c \
        "$library_dir/libmupdf.a" "$library_dir/libmupdf-third.a" \
        "$library_dir/libmupdf-pkcs7.a" $frameworks -lm -o "$output"
    "$output"
done
