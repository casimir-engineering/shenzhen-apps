#!/bin/sh
# Builds and runs the Windows-compatibility suites for portable/core.
#
# SPDFCoreCompatTests needs neither MuPDF nor a toolkit, so it is the one core
# suite that can run in the Windows guest before libmupdf links.
# SPDFCoreSaveTests links the core and MuPDF and drives the real save paths.
#
# Exits non-zero on the first failure; judge it by exit code, never by grep.
set -eu

repo_root="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
build_dir="${TMPDIR:-/tmp}/spdf-core-compat-tests.$$"
library_dir="mupdf/${MUPDF_OUT:-build/release}"
frameworks=""
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
mkdir -p "$build_dir"

cd "$repo_root"
if [ "$(uname -s)" = Darwin ]; then
    frameworks="-framework Foundation"
fi

"${CC:-cc}" -O2 -Wall -Wextra -Werror -Iportable/core \
    portable/core/tests/SPDFCoreCompatTests.c -o "$build_dir/SPDFCoreCompatTests"
"$build_dir/SPDFCoreCompatTests"

"${CC:-cc}" -O2 -Wall -Wextra -Werror -Iportable/core -Imupdf/include \
    portable/core/tests/SPDFCoreSaveTests.c \
    portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c \
    portable/core/spdf_selection_support.c portable/core/spdf_recolor.c \
    "$library_dir/libmupdf.a" "$library_dir/libmupdf-third.a" \
    "$library_dir/libmupdf-pkcs7.a" $frameworks -lm -o "$build_dir/SPDFCoreSaveTests"
# Run from a scratch directory so a temp file escaping into the CWD is visible
# to the suite's own working-directory check rather than landing in the repo.
cd "$build_dir"
./SPDFCoreSaveTests "$build_dir"
