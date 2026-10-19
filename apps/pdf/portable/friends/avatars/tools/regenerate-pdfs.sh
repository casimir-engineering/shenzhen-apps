#!/bin/bash
# Regenerates the animal set's derived files from its SVG sources: one PDF per animal for AppKit, the manifest,
# and the checksum list that lets friends-avatars-check notice an SVG edited without rerunning this script.
#
# WHY committed outputs: the build and the test suites must never need rsvg-convert (brief § Transfers: "a script
# regenerates the PDFs; the build never needs the converter"), so only whoever edits an SVG runs this.
#
# Usage: portable/friends/avatars/tools/regenerate-pdfs.sh        (any cwd)
# Needs: rsvg-convert (librsvg; Homebrew `brew install librsvg`). Set 1 was generated with rsvg-convert 2.62.3
# (cairo 1.18.4). Bash 3.2 compatible, like tools/check-file-sizes.sh.
#
# The SVG files are the single source of truth: an animal's index and name come from its file name
# (svg/07-fox.svg is index 7, "Fox"), its color from the fill of its background circle (id="bg"). Indexes are
# permanent once shipped: a friend on an older app draws the animal by index, so never renumber or reuse one;
# add new animals at the end and bump SET_VERSION.

set -euo pipefail

SET_VERSION=1
# A fixed creation date (2026-10-12, when set 1 was drawn) so cairo writes byte-identical PDFs on every run and
# a regeneration with unchanged sources shows no diff.
export SOURCE_DATE_EPOCH=1791763200

here=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
animals="$here/animals"

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "regenerate-pdfs: rsvg-convert not found (brew install librsvg)" >&2
    exit 2
fi
echo "Using $(rsvg-convert --version 2>/dev/null | sed -n 1p)"

work=$(mktemp -d "${TMPDIR:-/tmp}/szfriends-avatars.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/pdf"

manifest_rows="$work/rows"
checksums="$work/sources.sha256"
: > "$manifest_rows"
: > "$checksums"

expected=0
for svg in "$animals"/svg/*.svg; do
    file=$(basename "$svg")
    if ! printf '%s' "$file" | grep -Eq '^[0-9]{2}-[a-z]+\.svg$'; then
        echo "regenerate-pdfs: $file: name must be NN-animal.svg (two-digit index, lowercase name)" >&2
        exit 1
    fi
    stem=${file%.svg}
    index=$((10#${stem%%-*}))
    if [ "$index" -ne "$expected" ]; then
        echo "regenerate-pdfs: $file: expected index $expected; indexes must run 0, 1, 2... without gaps" >&2
        exit 1
    fi
    expected=$((expected + 1))

    word=${stem#*-}
    first=$(printf '%s' "$word" | cut -c1 | tr '[:lower:]' '[:upper:]')
    name="$first${word#?}"

    # The background circle is the one element whose color other code relies on (an animal avatar's `color` in
    # PROTOCOL.md is its manifest color), so it has a fixed, greppable form.
    color=$(grep -Eo '<circle id="bg" cx="32" cy="32" r="32" fill="#[0-9a-f]{6}"' "$svg" \
        | grep -Eo '#[0-9a-f]{6}' || true)
    if [ -z "$color" ]; then
        echo "regenerate-pdfs: $file: needs <circle id=\"bg\" cx=\"32\" cy=\"32\" r=\"32\" fill=\"#rrggbb\"/>" >&2
        exit 1
    fi
    if ! grep -q 'viewBox="0 0 64 64"' "$svg" || ! grep -q 'width="64" height="64"' "$svg"; then
        echo "regenerate-pdfs: $file: needs width=\"64\" height=\"64\" viewBox=\"0 0 64 64\"" >&2
        exit 1
    fi

    # 72 dpi maps the SVG's 64 px to a 64 x 64 pt page, the size the views and the tests expect.
    rsvg-convert --format=pdf --dpi-x=72 --dpi-y=72 --output="$work/pdf/$stem.pdf" "$svg"

    printf '    {"index": %d, "name": "%s", "color": "%s", "svg": "svg/%s", "pdf": "pdf/%s.pdf"}' \
        "$index" "$name" "$color" "$file" "$stem" >> "$manifest_rows"
    printf ',\n' >> "$manifest_rows"
    (cd "$animals" && shasum -a 256 "svg/$file") >> "$checksums"
done

if [ "$expected" -eq 0 ]; then
    echo "regenerate-pdfs: no SVG sources in $animals/svg" >&2
    exit 1
fi

# Drop the trailing comma of the last row.
sed -e '$ s/,$//' "$manifest_rows" > "$work/rows.json"
{
    printf '{\n  "set": %d,\n  "count": %d,\n  "animals": [\n' "$SET_VERSION" "$expected"
    cat "$work/rows.json"
    printf '\n  ]\n}\n'
} > "$work/manifest.json"

# Replace outputs only after every animal converted, so a failure never leaves a half-updated set behind.
rm -f "$animals"/pdf/*.pdf
cp "$work"/pdf/*.pdf "$animals/pdf/"
cp "$checksums" "$animals/pdf/sources.sha256"
cp "$work/manifest.json" "$animals/manifest.json"
echo "Regenerated $expected animals (set $SET_VERSION) in $animals"
