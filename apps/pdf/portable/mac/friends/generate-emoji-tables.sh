#!/bin/bash
# Writes SPDFMacFriendsEmojiTables.h, the Unicode data the send check reads (SPDFMacFriendsSendText.h), from Unicode's
# own files rather than guessed ranges: a guessed "U+203C to U+3299 is emoji" let a variation selector after kana, CJK
# punctuation or an arrow through unseen, and a guessed "the Arabic and Indic blocks join" let a non-joiner through
# between digits and letters it changes nothing about; and a mark of another script, such as U+3099 on a Hangul
# syllable, drew nothing at all, which Scripts.txt and ScriptExtensions.txt now decide. All eight files come from
# https://www.unicode.org/Public/<version>/ (ucd/emoji/ for the first two, ucd/extracted/ for DerivedJoiningType.txt,
# ucd/ for the others), of one version, which the header records. From portable/:
#
#   mac/friends/generate-emoji-tables.sh emoji-variation-sequences.txt emoji-data.txt DerivedJoiningType.txt \
#       IndicSyllabicCategory.txt Blocks.txt Scripts.txt ScriptExtensions.txt PropertyValueAliases.txt \
#       > mac/friends/SPDFMacFriendsEmojiTables.h
#
# Bash 3.2 and the BWK awk macOS ships (no strtonum, so hex is parsed by hand).

set -euo pipefail

if [ "$#" -ne 8 ]; then
    echo "usage: $0 emoji-variation-sequences.txt emoji-data.txt DerivedJoiningType.txt" \
        "IndicSyllabicCategory.txt Blocks.txt Scripts.txt ScriptExtensions.txt PropertyValueAliases.txt" >&2
    exit 2
fi
sequences=$1
data=$2
joining=$3
indic=$4
blocks=$5
scripts=$6
extensions=$7
aliases=$8

# The emoji files say "# Version: 18.0.0"; the others name it in their first line ("# Blocks-18.0.0.txt").
version_of() {
    {
        sed -n 's/^# Version: \([0-9.]*\).*/\1/p' "$1"
        sed -n '1s/^# [A-Za-z]*-\([0-9.]*\)\.txt.*/\1/p' "$1"
    } | head -n 1
}
version=$(version_of "$sequences")
for file in "$data" "$joining" "$indic" "$blocks" "$scripts" "$extensions" "$aliases"; do
    if [ -z "$version" ] || [ "$version" != "$(version_of "$file")" ]; then
        echo "$0: all eight files must name the same Unicode version ($file)" >&2
        exit 1
    fi
done

# A wrong file rather than a wrong version: each of these lines has been in its file since the property began.
expect() {
    if ! grep -Eq "$2" "$1"; then
        echo "$0: $1 does not look like the file it should be (no line matching $2)" >&2
        exit 1
    fi
}
expect "$joining" '^0628 +; D '
expect "$joining" '^0627 +; R '
expect "$indic" '^094D +; Virama '
expect "$indic" '^0915\.\.0939 +; Consonant '
expect "$blocks" '^0900\.\.097F; Devanagari'
expect "$scripts" '^0041\.\.005A +; Latin '
expect "$extensions" '^3099\.\.309A +; Hira Kana '
expect "$aliases" '^sc ; Latn +; Latin'

HEX_AWK='
    function hex(text,    value, index_, digit) {
        value = 0
        text = toupper(text)
        for (index_ = 1; index_ <= length(text); index_++) {
            digit = index("0123456789ABCDEF", substr(text, index_, 1)) - 1
            if (digit < 0) { print "bad code point " text > "/dev/stderr"; exit 1 }
            value = value * 16 + digit
        }
        return value
    }'

# Prints "name" then its merged ranges as C initialisers, five to a line. Input: one code point or low..high per line.
ranges() {
    awk -v name="$1" "$HEX_AWK"'
        {
            split($1, bounds, "\\.\\.")
            low = hex(bounds[1]); high = (2 in bounds) ? hex(bounds[2]) : low
            for (point = low; point <= high; point++) seen[point] = 1
            if (high > top) top = high
            delete bounds
        }
        END {
            printf "static const SPDFMacFriendsCodePointRange %s[] = {\n", name
            count = 0; line = ""
            for (point = 0; point <= top; point++) {
                if (!(point in seen) || ((point - 1) in seen)) continue
                end = point
                while ((end + 1) in seen) end++
                line = line sprintf("{0x%04X, 0x%04X}, ", point, end)
                if (++count % 5 == 0) { sub(/ $/, "", line); print "    " line; line = "" }
            }
            if (line != "") { sub(/ $/, "", line); print "    " line }
            print "};"
        }'
}

# The code points or ranges whose second field is exactly `value` in a UCD property file.
property() {
    awk -F';' -v value="$2" '{ sub(/#.*/, "") } { field = $2; gsub(/ /, "", field) }
        field == value { gsub(/ /, "", $1); print $1 }' "$1"
}

# Each virama with the block it is in: "{virama, low, high}", three to a line.
viramas() {
    property "$indic" Virama | awk -F';' "$HEX_AWK"'
        FNR == NR {
            sub(/#.*/, "")
            if (split($1, bounds, "\\.\\.") != 2) next
            count++; lows[count] = hex(bounds[1]); highs[count] = hex(bounds[2])
            next
        }
        {
            point = hex($1); found = 0
            for (block = 1; block <= count; block++)
                if (point >= lows[block] && point <= highs[block]) { found = block; break }
            if (!found) { print "U+" $1 " is in no block" > "/dev/stderr"; exit 1 }
            line = line sprintf("{0x%04X, 0x%04X, 0x%04X}, ", point, lows[found], highs[found])
            if (++printed % 3 == 0) { sub(/ $/, "", line); print "    " line; line = "" }
        }
        END { if (line != "") { sub(/ $/, "", line); print "    " line } }' "$blocks" -
}

# Each script's short name by its long one (PropertyValueAliases.txt), then each Scripts.txt range as
# "low high short-name" in decimal, unsorted.
script_ranges() {
    awk -F';' "$HEX_AWK"'
        FNR == NR {
            sub(/#.*/, ""); gsub(/ /, "", $1); gsub(/ /, "", $2); gsub(/^ +| +$/, "", $3)
            if ($1 == "sc") short[$3] = $2
            next
        }
        {
            sub(/#.*/, ""); if (NF < 2) next
            gsub(/ /, "", $1); gsub(/^ +| +$/, "", $2)
            if (!($2 in short)) { print "no short name for the script " $2 > "/dev/stderr"; exit 1 }
            split($1, bounds, "\\.\\.")
            low = hex(bounds[1]); high = (2 in bounds) ? hex(bounds[2]) : low
            print low, high, short[$2]
            delete bounds
        }' "$aliases" "$scripts"
}
script_names=$(script_ranges | awk '{ print $3 }' | sort -u | tr '\n' ' ')

# The script number of each short name: its place in name order, from 0; Unknown (Zzzz) is 0xFF.
NUMBER_AWK='
    BEGIN { count = split(names, ordered, " "); for (i = 1; i <= count; i++) number[ordered[i]] = i - 1
            number["Zzzz"] = 255 }'

# Where each script starts, six to a line, merged across code points Scripts.txt does not list (unassigned in this
# version) except surrogates and private use from U+D800 and U+F0000, which stay Unknown, as does all past the end.
script_starts() {
    script_ranges | sort -n -k1,1 | awk -v names="$script_names" "$NUMBER_AWK"'
        function cell(point, name) {
            line = line sprintf("{0x%04X, 0x%02X}, ", point, number[name])
            if (++cells % 6 == 0) { sub(/ $/, "", line); print "    " line; line = "" }
        }
        {
            if (NR > 1 && previous_high < 55296 && 55296 < $1) { cell(55296, "Zzzz"); current = "Zzzz" }
            if (NR > 1 && previous_high < 983040 && 983040 < $1) { cell(983040, "Zzzz"); current = "Zzzz" }
            if (NR == 1 || $3 != current) cell($1, $3)
            current = $3; previous_high = $2
        }
        END {
            cell(previous_high + 1, "Zzzz")
            if (line != "") { sub(/ $/, "", line); print "    " line }
        }'
}

# ScriptExtensions.txt as "{low, high, first, count}" into the lists of script numbers printed after, three to a line.
script_extensions() {
    awk -F';' "$HEX_AWK"'
        { sub(/#.*/, ""); if (NF < 2) next; gsub(/ /, "", $1); gsub(/^ +| +$/, "", $2)
          split($1, bounds, "\\.\\."); low = hex(bounds[1]); high = (2 in bounds) ? hex(bounds[2]) : low
          print low, high, $2; delete bounds }' "$extensions" | sort -n -k1,1 | awk -v names="$script_names" \
        "$NUMBER_AWK"'
        function flush() {
            if (!have) return
            if (!(list in first)) {
                first[list] = pooled
                count = split(list, items, " ")
                for (i = 1; i <= count; i++) {
                    if (!(items[i] in number) || items[i] == "Zzzz") {
                        print "ScriptExtensions.txt lists " items[i] ", which Scripts.txt never names" > "/dev/stderr"
                        exit 1
                    }
                    pool[pooled++] = number[items[i]]
                }
                lengths[list] = count
            }
            entry = entry sprintf("{0x%04X, 0x%04X, 0x%02X, 0x%02X}, ", low, high, first[list], lengths[list])
            if (++entries % 3 == 0) { sub(/ $/, "", entry); print "    " entry; entry = "" }
        }
        {
            names_here = $3; for (i = 4; i <= NF; i++) names_here = names_here " " $i
            if (have && names_here == list && $1 == high + 1) { high = $2; next }
            flush()
            low = $1; high = $2; list = names_here; have = 1
        }
        END {
            flush()
            if (entry != "") { sub(/ $/, "", entry); print "    " entry }
            print "};"
            print "static const unsigned char kSPDFMacFriendsScriptSets[] = {"
            line = ""
            for (i = 0; i < pooled; i++) {
                line = line sprintf("0x%02X, ", pool[i])
                if ((i + 1) % 18 == 0) { sub(/ $/, "", line); print "    " line; line = "" }
            }
            if (line != "") { sub(/ $/, "", line); print "    " line }
        }'
}

cat <<EOF
// Generated by mac/friends/generate-emoji-tables.sh from Unicode ${version}'s emoji-variation-sequences.txt,
// emoji-data.txt, DerivedJoiningType.txt, IndicSyllabicCategory.txt, Blocks.txt, Scripts.txt, ScriptExtensions.txt
// and PropertyValueAliases.txt. Do not edit by hand: run the script on a newer version's files instead.
//
// The send check (SPDFMacFriendsSendText.mm) and the AI chat card's markers (SPDFMacAIActivityVisibleText) read these
// tables. They accept a variation selector only after a base these sequences list, a zero-width joiner only between
// Extended_Pictographic code points or beside a virama in a conjunct of its block, and a zero-width non-joiner only
// where it changes a shape: between a dual-joining letter and a letter that joins to it, or after a virama before a
// consonant of its block. Anywhere else these characters draw nothing. A combining mark counts only on a letter of a
// script it is used with (SPDFMacFriendsMarkFitsLetter), since a font can draw a mark of another script as nothing.

#pragma once
#import <Foundation/Foundation.h>

typedef struct {
    UTF32Char low, high;
} SPDFMacFriendsCodePointRange;

typedef struct {
    UTF32Char virama, blockLow, blockHigh;
} SPDFMacFriendsViramaBlock;

typedef struct {
    UTF32Char first, script;
} SPDFMacFriendsScriptStart;

typedef struct {
    UTF32Char low, high, first, count;
} SPDFMacFriendsScriptExtension;

static NSString* const SPDFMacFriendsEmojiUnicodeVersion = @"${version}";

// Bases of emoji-variation-sequences.txt: a U+FE0E or U+FE0F after one of these picks how it draws.
EOF
grep -v '^#' "$sequences" | awk 'NF { print $1 }' | sort -u | ranges kSPDFMacFriendsEmojiVariationBases
echo
echo "// Extended_Pictographic in emoji-data.txt: what a zero-width joiner may join into one emoji."
awk -F';' '{ sub(/#.*/, "") } $2 ~ /^ *Extended_Pictographic *$/ { gsub(/ /, "", $1); print $1 }' "$data" |
    ranges kSPDFMacFriendsExtendedPictographic
echo
echo "// Joining_Type D in DerivedJoiningType.txt: letters that join to the letter after them (and before them)."
property "$joining" D | ranges kSPDFMacFriendsDualJoining
echo
echo "// Joining_Type R: letters that join only to the letter before them."
property "$joining" R | ranges kSPDFMacFriendsRightJoining
echo
echo "// Indic_Syllabic_Category Virama in IndicSyllabicCategory.txt, each with its block in Blocks.txt."
echo "static const SPDFMacFriendsViramaBlock kSPDFMacFriendsViramas[] = {"
viramas
echo "};"
echo
echo "// Indic_Syllabic_Category Consonant: what a virama before it joins into a conjunct or a half form."
property "$indic" Consonant | ranges kSPDFMacFriendsIndicConsonants
inherited=$(awk -v names="$script_names" "$NUMBER_AWK"' BEGIN { printf "0x%02X", number["Zinh"] }')
echo
echo "// Scripts by number, from 0x00 in this order (short names, PropertyValueAliases.txt); Unknown is 0xFF:"
echo "$script_names" | fold -s -w 111 | sed 's/ *$//; s/^/\/\/ /'
echo "static const UTF32Char kSPDFMacFriendsScriptInherited = $inherited;"
echo
echo "// Scripts.txt: the Script from each of these code points up to the next. A code point the file does not list"
echo "// counts as the script before it (it is unassigned in this version); surrogates and private use count as"
echo "// Unknown."
echo "static const SPDFMacFriendsScriptStart kSPDFMacFriendsScripts[] = {"
script_starts
echo "};"
echo
echo "// ScriptExtensions.txt: the scripts a code point is used with when there are several (U+3099: Hiragana and"
echo "// Katakana), as where their list starts in kSPDFMacFriendsScriptSets and how long it is."
echo "static const SPDFMacFriendsScriptExtension kSPDFMacFriendsScriptExtensions[] = {"
script_extensions
echo "};"
cat <<'LOOKUP'

// The scripts `point` is used with, into `scripts`: its Script_Extensions, or else its one Script, in `own`.
static inline size_t SPDFMacFriendsScriptsOf(UTF32Char point, const unsigned char** scripts, unsigned char* own) {
    size_t low = 0, high = sizeof kSPDFMacFriendsScriptExtensions / sizeof kSPDFMacFriendsScriptExtensions[0];
    while (low < high) {
        size_t middle = low + (high - low) / 2;
        if (point > kSPDFMacFriendsScriptExtensions[middle].high) low = middle + 1;
        else if (point < kSPDFMacFriendsScriptExtensions[middle].low) high = middle;
        else {
            *scripts = kSPDFMacFriendsScriptSets + kSPDFMacFriendsScriptExtensions[middle].first;
            return kSPDFMacFriendsScriptExtensions[middle].count;
        }
    }
    // The last start at or before `point`; the first is U+0000.
    for (low = 0, high = sizeof kSPDFMacFriendsScripts / sizeof kSPDFMacFriendsScripts[0]; high - low > 1;) {
        size_t middle = low + (high - low) / 2;
        if (kSPDFMacFriendsScripts[middle].first <= point) low = middle;
        else high = middle;
    }
    *own = (unsigned char)kSPDFMacFriendsScripts[low].script;
    *scripts = own;
    return 1;
}

// Whether a combining mark is drawn on a letter of its own script: the mark's Script_Extensions (else its Script)
// share a script with the letter's, or the mark belongs to no script in particular (Inherited with no extensions,
// such as U+0338 or U+20E3). A mark of another script can draw nothing: U+3099 on a Hangul syllable.
static inline BOOL SPDFMacFriendsMarkFitsLetter(UTF32Char mark, UTF32Char letter) {
    unsigned char markOwn = 0, letterOwn = 0;
    const unsigned char *markScripts = NULL, *letterScripts = NULL;
    size_t marks = SPDFMacFriendsScriptsOf(mark, &markScripts, &markOwn);
    size_t letters = SPDFMacFriendsScriptsOf(letter, &letterScripts, &letterOwn);
    if (markScripts == &markOwn && markOwn == kSPDFMacFriendsScriptInherited) return YES;
    for (size_t i = 0; i < marks; i++)
        for (size_t j = 0; j < letters; j++)
            if (markScripts[i] == letterScripts[j]) return YES;
    return NO;
}
LOOKUP
