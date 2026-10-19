#!/bin/bash

# Enforce exact, reviewable line-count caps for maintained first-party source.
# This intentionally stays compatible with the Bash 3.2 shipped by macOS.

set -euo pipefail

usage() {
    echo "usage: $0 [--root PATH] [--limits PATH]" >&2
    exit 2
}

script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
root=""
limits=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --root)
            [ "$#" -ge 2 ] || usage
            root=$2
            shift 2
            ;;
        --limits)
            [ "$#" -ge 2 ] || usage
            limits=$2
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

if [ -z "$root" ]; then
    root=$(git -C "$script_dir" rev-parse --show-toplevel)
fi
root=$(CDPATH='' cd "$root" && pwd)

if [ -z "$limits" ]; then
    limits="$root/tools/file-size-limits.tsv"
elif [ "${limits#/}" = "$limits" ]; then
    limits="$root/$limits"
fi

if [ ! -f "$limits" ]; then
    echo "file-size ratchet: missing limits file: $limits" >&2
    exit 2
fi
if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "file-size ratchet: not a git worktree: $root" >&2
    exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/spdf-file-sizes.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
entries="$tmp_dir/entries.tsv"
files="$tmp_dir/files.zlist"
seen="$tmp_dir/seen.txt"
violations="$tmp_dir/violations.txt"
: > "$seen"
: > "$violations"

# Normalize and validate the policy file before examining source files.
awk -F '\t' '
    function fail(message) {
        print "file-size ratchet: " message > "/dev/stderr"
        bad = 1
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
        if (NF != 4) {
            fail("limits line " NR " must have four tab-separated fields")
            next
        }
        path = $1
        cap = $2
        kind = $3
        reason = $4
        if (path == "" || path ~ /^\// || path ~ /(^|\/)\.\.($|\/)/) {
            fail("invalid repository-relative path on limits line " NR)
        }
        if (seen[path]++) {
            fail("duplicate limits entry for " path)
        }
        if (cap !~ /^[0-9]+$/) {
            fail("non-numeric cap for " path)
        } else if (kind == "legacy") {
            if (cap <= 1000) fail("legacy cap must exceed 1000 for " path)
        } else if (kind == "exception") {
            if (cap < 501 || cap > 1000) fail("exception cap must be 501-1000 for " path)
        } else {
            fail("kind must be legacy or exception for " path)
        }
        if (reason !~ /[^[:space:]]/) {
            fail("missing justification for " path)
        }
        print path "\t" cap "\t" kind "\t" reason
    }
    END { if (bad) exit 1 }
' "$limits" > "$entries"

is_source_file() {
    local extension
    extension=${1##*.}
    [ "$extension" != "$1" ] || return 1

    # Bracketed characters keep matching case-insensitive on macOS Bash 3.2
    # without changing shell options for the exclusion rules below.
    case "$extension" in
        [cC]|[cC][cC]|[cC][pP][pP]|[cC][xX][xX]|\
        [hH]|[hH][hH]|[hH][pP][pP]|[hH][xX][xX]|[iI][nN][lL]|[iI][nN][cC]|\
        [mM]|[mM][mM]|[sS][wW][iI][fF][tT]|[mM][eE][tT][aA][lL]|\
        [gG][lL][sS][lL]|[vV][eE][rR][tT]|[fF][rR][aA][gG]|\
        [tT][sS]|[tT][sS][xX]|[jJ][sS]|[jJ][sS][xX]|[pP][yY]|[sS][hH]|\
        [gG][oO]|[rR][sS]|[lL][uU][aA]|[jJ][aA][vV][aA]|\
        [kK][tT]|[kK][tT][sS]|[cC][sS]|[rR][bB]|[pP][hH][pP]|[pP][lL])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_excluded_file() {
    case "$1" in
        # Vendored dependency trees and third-party sources kept outside them.
        ext/*|mupdf/*|packages/*|node_modules/*|\
        cmd/markdown-it.min.js|tools/sizer/parg.c|tools/sizer/parg.h)
            return 0
            ;;
        # Build, packaging, coverage, and generated output trees.
        out/*|artifacts/*|dist/*|portable/build/*|portable/build-*/*|docs-www/*)
            return 0
            ;;
        # Checked-in generated code and machine-like regression data.
        src/Commands.h|src/Settings.h|src/TranslationLangs.cpp|src/resource.h|\
        src/utils/HtmlParserLookup.cpp|src/utils/HtmlParserLookup.h|\
        src/regress/Regress03.h)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

find_entry() {
    awk -F '\t' -v wanted="$1" '$1 == wanted { print $2 "\t" $3 "\t" $4; exit }' "$entries"
}

git -C "$root" ls-files -co --exclude-standard -z > "$files"

checked=0
capped=0
while IFS= read -r -d '' file; do
    # `git ls-files -c` includes tracked paths removed in the working tree.
    # Their deletion is intentional work, not a source file to measure.
    [ -f "$root/$file" ] || continue
    is_source_file "$file" || continue
    is_excluded_file "$file" && continue

    case "$file" in
        *$'\t'*|*$'\n'*)
            echo "$file: tabs and newlines are unsupported in ratcheted paths" >> "$violations"
            continue
            ;;
    esac

    checked=$((checked + 1))
    # `wc -l` counts newline bytes, so a final unterminated source line could
    # otherwise evade the cap. awk's NR counts logical records correctly.
    lines=$(awk 'END { print NR + 0 }' "$root/$file")
    entry=$(find_entry "$file")

    if [ -z "$entry" ]; then
        if [ "$lines" -gt 500 ]; then
            echo "$file: $lines lines exceeds the unlisted 500-line default" >> "$violations"
        fi
        continue
    fi

    printf '%s\n' "$file" >> "$seen"
    capped=$((capped + 1))
    IFS=$'\t' read -r cap kind _ <<< "$entry"

    if [ "$lines" -gt "$cap" ]; then
        echo "$file: $lines lines exceeds its exact $cap-line $kind cap" >> "$violations"
    elif [ "$lines" -lt "$cap" ]; then
        if [ "$lines" -le 500 ]; then
            echo "$file: reduced to $lines lines; remove its obsolete limits entry" >> "$violations"
        else
            echo "$file: reduced to $lines lines; lower its ratchet cap from $cap" >> "$violations"
        fi
    fi
done < "$files"

while IFS=$'\t' read -r path _; do
    if ! grep -F -x -- "$path" "$seen" >/dev/null 2>&1; then
        echo "$path: limits entry does not name a maintained source file" >> "$violations"
    fi
done < "$entries"

if [ -s "$violations" ]; then
    echo "File-size ratchet failed:" >&2
    sed 's/^/  /' "$violations" >&2
    exit 1
fi

echo "File-size ratchet passed: $checked maintained source files, $capped exact caps."
