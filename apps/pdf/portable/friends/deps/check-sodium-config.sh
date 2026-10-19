#!/bin/bash
# Proves that deps.mk builds the vendored libsodium exactly as upstream's own configure would on this Mac.
#
# deps.mk compiles libsodium without running configure (see the WHY there), so its macro list is a claim
# about what configure would choose. This script checks the claim against a verified release tree:
#   1. the vendored ext/libsodium/src/libsodium matches the release's src/libsodium file for file (minus the
#      assembler and autotools files we leave out) and version.h matches what configure generates;
#   2. every vendored source compiled with deps.mk's flags is byte-identical to the same source compiled with
#      configure's compiler, CFLAGS and DEFS line.
# Run it on every libsodium upgrade, after verifying the tarball's signature (ext/libsodium/README.shenzhen.md).
#
# usage: portable/friends/deps/check-sodium-config.sh /path/to/extracted/libsodium-X.Y.Z
# Bash 3.2 compatible (macOS /bin/bash). Writes only to a temporary directory.

set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -x "$1/configure" ]; then
    echo "usage: $0 /path/to/extracted/libsodium-release" >&2
    exit 2
fi
release=$(CDPATH='' cd "$1" && pwd)
portable=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
vendored="$portable/../ext/libsodium/src/libsodium"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/szfriends-sodium-check.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

# 1. Vendored tree against the release.
if ! diff -r -q -x '*.S' -x 'Makefile.am' -x 'Makefile.in' -x 'version.h.in' -x 'version.h' \
        "$release/src/libsodium" "$vendored"; then
    echo "check-sodium-config: vendored sources differ from the release" >&2
    exit 1
fi

# deps.mk's flags, printed by make itself so this script cannot drift from the makefile.
printf 'szfriends-print-%%:\n\t@echo $($*)\n' > "$scratch/print.mk"
print_var() {
    make -s --no-print-directory -C "$portable" -f Makefile -f friends/deps/deps.mk -f "$scratch/print.mk" \
        "szfriends-print-$1"
}
mine=$(print_var FRIENDS_SODIUM_BUILD_FLAGS)
target=$(print_var MAC_TARGET_FLAGS)

mkdir -p "$scratch/configure"
(cd "$scratch/configure" && CC=clang CFLAGS="$target -O2" "$release/configure" --disable-shared --enable-static \
    > configure.log 2>&1) || { echo "check-sodium-config: configure failed" >&2; exit 1; }
generated="$scratch/configure/src/libsodium"
if ! cmp -s "$generated/include/sodium/version.h" "$vendored/include/sodium/version.h"; then
    echo "check-sodium-config: vendored version.h differs from the one configure generates" >&2
    exit 1
fi
conf_cc=$(sed -n 's/^CC = //p' "$generated/Makefile")
conf_cflags=$(sed -n 's/^CFLAGS = //p' "$generated/Makefile")
conf_defs=$(sed -n 's/^DEFS = //p' "$generated/Makefile")

# 2. Object equivalence. Both compiles run from portable/ with the same source path, so the __FILE__
# strings that libsodium's assertions embed are equal too. SODIUM_STATIC and the include paths are ours in
# both, so the comparison isolates configure's choices.
ours="-DSODIUM_STATIC=1 -I../ext/libsodium/src/libsodium/include -I../ext/libsodium/src/libsodium/include/sodium"
cd "$portable"
same=0
different=""
for src in $(find ../ext/libsodium/src/libsodium -name '*.c' | LC_ALL=C sort); do
    obj=$(echo "${src#../ext/libsodium/src/libsodium/}" | tr '/' '_')
    eval "clang $mine -c \"$src\" -o \"$scratch/mine-$obj.o\""
    eval "$conf_cc $conf_defs $conf_cflags $ours -c \"$src\" -o \"$scratch/conf-$obj.o\""
    if cmp -s "$scratch/mine-$obj.o" "$scratch/conf-$obj.o"; then
        same=$((same + 1))
    else
        different="$different $src"
    fi
done
if [ -n "$different" ]; then
    echo "check-sodium-config: objects differ from configure's build:$different" >&2
    echo "configure's DEFS: $conf_defs" >&2
    exit 1
fi
echo "check-sodium-config: $same objects identical to configure's build"
