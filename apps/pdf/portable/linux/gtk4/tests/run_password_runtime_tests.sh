#!/bin/sh
# The GTK4 password flow (spdf_password*.c) linked against the real core, run through the core's password fixtures.
# make -C portable linux-password-tests builds the core objects in its BUILD first and passes that directory and the
# MuPDF library directory, so a scratch BUILD gets a clean build of its own instead of whatever portable/build holds.
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 BUILD_DIR MUPDF_BUILD_DIR (run it with: make -C portable linux-password-tests)" >&2
    exit 2
fi
build=$1
mupdf_build=$2

root=$(CDPATH='' cd -- "$(dirname "$0")/../../.." && pwd)
cd "$root"

case "$(uname -s)" in
    Darwin) platform_libs="-framework Foundation" ;;
    *) platform_libs="" ;;
esac

binary="$build/password_runtime_test"
# Removed first, so a failed link can never leave an older binary to pass in its place.
rm -f "$binary"
# pkg-config and platform_libs intentionally expand into compiler arguments.
# shellcheck disable=SC2046,SC2086
${CC:-cc} -O2 -Wall -Wextra -Icore -Ilinux/gtk4 -I../mupdf/include \
    linux/gtk4/tests/password_runtime_case.c linux/gtk4/spdf_password.c linux/gtk4/spdf_password_controller.c \
    linux/gtk4/spdf_password_lifecycle.c "$build/shenzhen_pdf_core.o" "$build/spdf_recolor.o" \
    "$mupdf_build/libmupdf.a" "$mupdf_build/libmupdf-third.a" "$mupdf_build/libmupdf-pkcs7.a" \
    $(pkg-config --cflags --libs glib-2.0 gio-2.0) $platform_libs -lm -o "$binary"

core/tests/run_password_tests.sh "$binary"
