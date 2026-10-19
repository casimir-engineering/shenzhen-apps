#!/bin/bash

# Behavioral self-test for check-file-sizes.sh. Fixtures are generated in a
# temporary git repository so tracked, untracked, and ignored files are tested.

set -euo pipefail

script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
checker="$script_dir/check-file-sizes.sh"
fixture_limits="$script_dir/tests/file-size-ratchet-fixture/valid-limits.tsv"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/spdf-file-size-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
repo="$tmp_dir/repo"
mkdir -p "$repo/tools" "$repo/ext/vendor" "$repo/out" "$repo/src"

git -C "$repo" init -q
git -C "$repo" config user.email file-size-test@example.invalid
git -C "$repo" config user.name "File Size Ratchet Test"
cp "$checker" "$repo/tools/check-file-sizes.sh"
cp "$fixture_limits" "$repo/tools/file-size-limits.tsv"
printf 'out/\n' > "$repo/.gitignore"

write_lines() {
    count=$1
    path=$2
    awk -v count="$count" 'BEGIN { for (i = 1; i <= count; i++) print "int line_" i ";" }' > "$path"
}

write_lines_without_final_newline() {
    count=$1
    path=$2
    awk -v count="$count" 'BEGIN {
        for (i = 1; i <= count; i++) {
            printf "int line_%d;%s", i, (i < count ? "\n" : "")
        }
    }' > "$path"
}

write_lines 500 "$repo/default.c"
write_lines 501 "$repo/exception.c"
write_lines 1001 "$repo/legacy.c"
write_lines 2000 "$repo/ext/vendor/vendor.c"
write_lines 2000 "$repo/out/generated.c"
write_lines 2000 "$repo/src/Settings.h"
git -C "$repo" add .gitignore default.c exception.c legacy.c tools ext/vendor/vendor.c src/Settings.h
git -C "$repo" add -f out/generated.c
git -C "$repo" commit -qm baseline

passed=0
failed=0

expect_pass() {
    name=$1
    if "$checker" --root "$repo" > "$tmp_dir/stdout" 2> "$tmp_dir/stderr"; then
        echo "ok - $name"
        passed=$((passed + 1))
    else
        echo "not ok - $name" >&2
        cat "$tmp_dir/stdout" "$tmp_dir/stderr" >&2
        failed=$((failed + 1))
    fi
}

expect_fail() {
    name=$1
    expected=$2
    if "$checker" --root "$repo" > "$tmp_dir/stdout" 2> "$tmp_dir/stderr"; then
        echo "not ok - $name unexpectedly passed" >&2
        failed=$((failed + 1))
    elif grep -F "$expected" "$tmp_dir/stderr" >/dev/null 2>&1; then
        echo "ok - $name"
        passed=$((passed + 1))
    else
        echo "not ok - $name produced the wrong diagnostic" >&2
        cat "$tmp_dir/stdout" "$tmp_dir/stderr" >&2
        failed=$((failed + 1))
    fi
}

expect_pass "caps plus tracked vendor, generated, and build exclusions"

write_lines 501 "$repo/untracked.c"
expect_fail "untracked source uses the 500-line default" "untracked.c: 501 lines exceeds the unlisted 500-line default"
rm "$repo/untracked.c"

write_lines_without_final_newline 501 "$repo/unterminated.c"
expect_fail "unterminated final line still counts" "unterminated.c: 501 lines exceeds the unlisted 500-line default"
rm "$repo/unterminated.c"

write_lines 501 "$repo/source.lua"
expect_fail "maintained Lua source uses the 500-line default" "source.lua: 501 lines exceeds the unlisted 500-line default"
rm "$repo/source.lua"

write_lines 501 "$repo/source.LUA"
expect_fail "Lua extension matching is case-insensitive" "source.LUA: 501 lines exceeds the unlisted 500-line default"
rm "$repo/source.LUA"

write_lines 501 "$repo/uppercase.CPP"
expect_fail "compiled source extension matching is case-insensitive" "uppercase.CPP: 501 lines exceeds the unlisted 500-line default"
rm "$repo/uppercase.CPP"

write_lines 501 "$repo/src/Commands.cpp"
expect_fail "mixed generated source remains covered" "src/Commands.cpp: 501 lines exceeds the unlisted 500-line default"
rm "$repo/src/Commands.cpp"

write_lines 501 "$repo/src/Flags.h"
expect_fail "maintained header remains covered" "src/Flags.h: 501 lines exceeds the unlisted 500-line default"
rm "$repo/src/Flags.h"

write_lines 502 "$repo/exception.c"
expect_fail "listed file cannot grow" "exception.c: 502 lines exceeds its exact 501-line exception cap"
git -C "$repo" checkout -q -- exception.c

write_lines 500 "$repo/exception.c"
expect_fail "obsolete exception must be removed" "exception.c: reduced to 500 lines; remove its obsolete limits entry"
git -C "$repo" checkout -q -- exception.c

printf 'missing.c\t501\texception\tSynthetic stale entry.\n' >> "$repo/tools/file-size-limits.tsv"
expect_fail "stale limits entry is rejected" "missing.c: limits entry does not name a maintained source file"
git -C "$repo" checkout -q -- tools/file-size-limits.tsv

printf 'exception.c\t501\texception\tDuplicate synthetic entry.\n' >> "$repo/tools/file-size-limits.tsv"
expect_fail "duplicate limits entry is rejected" "duplicate limits entry for exception.c"
git -C "$repo" checkout -q -- tools/file-size-limits.tsv

printf 'bad.c\t700\texception\t\n' >> "$repo/tools/file-size-limits.tsv"
expect_fail "empty justification is rejected" "missing justification for bad.c"
git -C "$repo" checkout -q -- tools/file-size-limits.tsv

write_lines 900 "$repo/ext/vendor/untracked-vendor.c"
write_lines 900 "$repo/out/untracked-output.c"
expect_pass "vendor and ignored build outputs are excluded"

git -C "$repo" rm -q default.c
expect_pass "tracked files deleted in the working tree are ignored"

echo "$passed self-tests passed; $failed failed."
[ "$failed" -eq 0 ]
