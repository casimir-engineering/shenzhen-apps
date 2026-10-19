#!/bin/sh
# Writes a C file holding a file's bytes, so the helper carries the Friends ID word list in its executable.
# WHY compiled in rather than read from the bundle: the updater can replace the bundle while the helper runs, and a
# list read later could then differ from the one the helper validated (ADR 0002 loads resources at start anyway).
# A byte array rather than a string literal: C99 compilers need only accept 4,095-character literals under
# -pedantic, and bytes need no escaping.
#
# Usage: embed.sh <input> <output.c> <symbol>
# Defines `const unsigned char <symbol>[]` and `const size_t <symbol>_length`. POSIX sh and od only.

set -eu

[ "$#" -eq 3 ] || { echo "usage: $0 <input> <output.c> <symbol>" >&2; exit 2; }
input=$1
output=$2
symbol=$3

{
    printf '/* Generated from %s by embed.sh. Do not edit. */\n' "$input"
    printf '#include <stddef.h>\n\n'
    printf 'extern const unsigned char %s[];\n' "$symbol"
    printf 'extern const size_t %s_length;\n\n' "$symbol"
    printf 'const unsigned char %s[] = {\n' "$symbol"
    od -An -v -tx1 "$input" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' \
        -e 's/[[:space:]][[:space:]]*/, 0x/g' -e 's/^/    0x/' -e 's/$/,/'
    printf '};\n\n'
    printf 'const size_t %s_length = sizeof %s;\n' "$symbol" "$symbol"
} > "$output.tmp"
mv "$output.tmp" "$output"
