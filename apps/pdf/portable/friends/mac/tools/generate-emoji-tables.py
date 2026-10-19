#!/usr/bin/env python3
"""Writes SZFriendsEmojiTables.m, the Unicode data SZFriendsLiteralText.m reads, from Unicode's own lists.

WHY generated rather than written ranges: a guessed "U+203C to U+3299 is emoji" let a variation selector after kana,
CJK punctuation or an arrow through unmarked, and each drew exactly the text without it (security review, round 2); a
guessed "the Arabic and Indic blocks join" did the same for a non-joiner between digits or letters it changes nothing
about (round 3); and a mark from another script, such as U+3099 on a Hangul syllable, drew nothing at all (wave 6c).

Inputs, one Unicode version for all eight (https://www.unicode.org/Public/<version>/ucd/):
  bases    emoji/emoji-variation-sequences.txt, or any list whose lines start with a base code point ("0023 FE0E ; ...")
  pict     emoji/emoji-data.txt (its Extended_Pictographic lines), or a list of code points and ranges ("1F000..1F0FF")
  joining  extracted/DerivedJoiningType.txt (its D and R lines)
  indic    IndicSyllabicCategory.txt (its Virama and Consonant lines)
  blocks   Blocks.txt (to give each virama its block)
  scripts  Scripts.txt (each code point's Script, by long name)
  exts     ScriptExtensions.txt (Script_Extensions, by short name)
  aliases  PropertyValueAliases.txt (to give each Script its short name)
From portable/:
  python3 friends/mac/tools/generate-emoji-tables.py --unicode-version 18.0 \\
      --source "Unicode 18.0's emoji-variation-sequences.txt, emoji-data.txt, DerivedJoiningType.txt, \\
      IndicSyllabicCategory.txt, Blocks.txt, Scripts.txt, ScriptExtensions.txt and PropertyValueAliases.txt" \\
      emoji-variation-sequences.txt emoji-data.txt DerivedJoiningType.txt IndicSyllabicCategory.txt Blocks.txt \\
      Scripts.txt ScriptExtensions.txt PropertyValueAliases.txt > friends/mac/SZFriendsEmojiTables.m
Standard library only (the Python 3.9 macOS ships).
"""

import argparse
import re
import sys
import textwrap

MAX_CODE_POINT = 0x10FFFF


def fail(message):
    sys.stderr.write("generate-emoji-tables: %s\n" % message)
    sys.exit(1)


def check_version(path, lines, version):
    # The emoji files name their version on a "# Version:" line, the others in their first line ("# Blocks-18.0.0.txt");
    # a list made by hand need not, but must not contradict --unicode-version.
    named = None
    if lines:
        found = re.match(r"#\s*[A-Za-z]+-([0-9.]+)\.txt", lines[0])
        named = found.group(1) if found else None
    for line in lines:
        found = re.match(r"#\s*Version:\s*([0-9.]+)", line)
        if found:
            named = found.group(1).rstrip(".")
            break
    if named and named.split(".")[:2] != version.split(".")[:2]:
        fail("%s is Unicode %s, not %s" % (path, named, version))


def parse_point(text, path):
    if not re.fullmatch(r"[0-9A-Fa-f]{4,6}", text):
        fail("%s: %r is not a code point" % (path, text))
    point = int(text, 16)
    if point > MAX_CODE_POINT:
        fail("%s: %r is beyond Unicode" % (path, text))
    return point


def parse_range(text, path):
    bounds = re.split(r"\.\.|-", text.strip())
    if len(bounds) > 2:
        fail("%s: %r is not a code point or range" % (path, text))
    low = parse_point(bounds[0], path)
    high = parse_point(bounds[-1], path)
    if high < low:
        fail("%s: %r runs backwards" % (path, text))
    return low, high


def read_lines(path, version):
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    check_version(path, lines, version)
    return [line.split("#", 1)[0].strip() for line in lines]


def read_bases(path, version):
    points = set()
    for line in read_lines(path, version):
        if line:
            points.add(parse_point(line.split()[0], path))
    return points


def read_pictographic(path, version):
    points = set()
    for line in read_lines(path, version):
        if not line:
            continue
        fields = [field.strip() for field in line.split(";")]
        # emoji-data.txt lists several properties; only Extended_Pictographic lines count. A bare list has no field.
        if len(fields) > 1 and fields[1] != "Extended_Pictographic":
            continue
        low, high = parse_range(fields[0], path)
        points.update(range(low, high + 1))
    return points


def read_property(path, version, value):
    """The code points whose second field is exactly `value` (DerivedJoiningType.txt, IndicSyllabicCategory.txt)."""
    points = set()
    for line in read_lines(path, version):
        fields = [field.strip() for field in line.split(";")]
        if len(fields) > 1 and fields[1] == value:
            low, high = parse_range(fields[0], path)
            points.update(range(low, high + 1))
    return points


def read_blocks(path, version):
    blocks = []
    for line in read_lines(path, version):
        fields = [field.strip() for field in line.split(";")]
        if len(fields) > 1:
            blocks.append(parse_range(fields[0], path))
    return blocks


def read_script_names(path, version):
    """Each Script's long name to its short one: "sc ; Latn ; Latin" lines."""
    names = {}
    for line in read_lines(path, version):
        fields = [field.strip() for field in line.split(";")]
        if len(fields) > 2 and fields[0] == "sc":
            names[fields[2]] = fields[1]
    return names


# Where Scripts.txt lists nothing and the code points are not merely unassigned: surrogates and private use from
# U+D800 to U+F8FF, private use in planes 15 and 16. These stay Unknown however their neighbours read.
NEVER_MERGED = (0xD800, 0xF0000)


def read_scripts(path, version, names):
    """Where each Script starts, as (first code point, short name) in order; Unknown is "Zzzz". A code point the file
    does not list counts as the script before it, being unassigned, except from NEVER_MERGED on."""
    entries = []
    for line in read_lines(path, version):
        fields = [field.strip() for field in line.split(";")]
        if len(fields) > 1:
            if fields[1] not in names:
                fail("%s: no short name for the script %r" % (path, fields[1]))
            entries.append(parse_range(fields[0], path) + (names[fields[1]],))
    entries.sort()
    starts = []
    for index, (low, high, script) in enumerate(entries):
        if not starts or starts[-1][1] != script:
            starts.append((low, script))
        following = entries[index + 1][0] if index + 1 < len(entries) else MAX_CODE_POINT + 1
        unknown = [point for point in NEVER_MERGED if high < point < following]
        if following > MAX_CODE_POINT:
            unknown.append(high + 1)
        if unknown:
            starts.append((min(unknown), "Zzzz"))
    return starts


def read_extensions(path, version):
    """Ranges of (low, high, short names in file order), merged where neighbours list the same scripts."""
    entries = []
    for line in read_lines(path, version):
        fields = [field.strip() for field in line.split(";")]
        if len(fields) > 1:
            entries.append(parse_range(fields[0], path) + (tuple(fields[1].split()),))
    ranges = []
    for low, high, scripts in sorted(entries):
        if ranges and ranges[-1][2] == scripts and ranges[-1][1] == low - 1:
            ranges[-1][1] = high
        else:
            ranges.append([low, high, scripts])
    return ranges


def rows(cells, width=116):
    """The cells as indented lines of at most `width` characters."""
    lines = [""]
    for cell in cells:
        if lines[-1] and len(lines[-1]) + 1 + len(cell) > width - 4:
            lines.append("")
        lines[-1] += (" " if lines[-1] else "") + cell
    return "\n".join("    " + line for line in lines)


def script_tables(starts, extensions):
    """The script numbers, where each script starts, the extensions and the lists of scripts they point into, as C."""
    numbers = {name: number for number, name in enumerate(sorted({name for _, name in starts} - {"Zzzz"}))}
    numbers["Zzzz"] = 0xFF
    for low, _, scripts in extensions:
        for name in scripts:
            if name not in numbers or name == "Zzzz":
                fail("U+%04X lists %s, which Scripts.txt never names" % (low, name))
    pool, offsets = [], {}
    for _, _, scripts in extensions:
        if scripts not in offsets:
            offsets[scripts] = len(pool)
            pool.extend(numbers[name] for name in scripts)
    legend = textwrap.wrap(" ".join(sorted(numbers, key=numbers.get)[:-1]), 114)
    return "".join([
        "\n// Scripts by number, from 0x00 in this order (short names, PropertyValueAliases.txt); Unknown is 0xFF:\n",
        "".join("// %s\n" % line for line in legend),
        "static const UTF32Char SZFScriptInherited = 0x%02X;\n" % numbers["Zinh"],
        "\n// Scripts.txt: the Script from each of these code points up to the next. A code point the file does not\n"
        "// list counts as the script before it (it is unassigned in this version); surrogates and private use count\n"
        "// as Unknown.\n",
        "static const SZFScriptStart SZFScripts[] = {\n%s\n};\n" % rows(
            ["{0x%04X, 0x%02X}," % (low, numbers[name]) for low, name in starts]),
        "\n// ScriptExtensions.txt: the scripts a code point is used with when there are several (U+3099: Hiragana\n"
        "// and Katakana), as where their list starts in SZFScriptSets and how long it is.\n",
        "static const SZFScriptExtension SZFScriptExtensions[] = {\n%s\n};\n" % rows(
            ["{0x%04X, 0x%04X, 0x%02X, 0x%02X}," % (low, high, offsets[scripts], len(scripts))
             for low, high, scripts in extensions]),
        "static const unsigned char SZFScriptSets[] = {\n%s\n};\n" % rows(["0x%02X," % n for n in pool]),
    ])


def merged(points):
    ranges = []
    for point in sorted(points):
        if ranges and ranges[-1][1] == point - 1:
            ranges[-1][1] = point
        else:
            ranges.append([point, point])
    return ranges


def table(name, points):
    cells = ["{0x%04X, 0x%04X}," % (low, high) for low, high in merged(points)]
    rows = [" ".join(cells[start:start + 5]) for start in range(0, len(cells), 5)]
    body = "\n".join("    " + row for row in rows)
    return "static const SZFCodePointRange %s[] = {\n%s\n};\n" % (name, body)


def virama_table(viramas, blocks):
    cells = []
    for virama in sorted(viramas):
        block = [(low, high) for low, high in blocks if low <= virama <= high]
        if not block:
            fail("U+%04X is in no block" % virama)
        cells.append("{0x%04X, 0x%04X, 0x%04X}," % (virama, block[0][0], block[0][1]))
    rows = [" ".join(cells[start:start + 3]) for start in range(0, len(cells), 3)]
    return "static const SZFViramaBlock SZFViramas[] = {\n%s\n};\n" % "\n".join("    " + row for row in rows)


LOOKUP = """
static BOOL SZFInRanges(UTF32Char point, const SZFCodePointRange *ranges, size_t count) {
    size_t low = 0, high = count;
    while (low < high) {
        size_t middle = low + (high - low) / 2;
        if (point > ranges[middle].high) low = middle + 1;
        else if (point < ranges[middle].low) high = middle;
        else return YES;
    }
    return NO;
}

#define SZFIn(point, table) SZFInRanges(point, table, sizeof table / sizeof table[0])

BOOL SZFriendsIsEmojiVariationBase(UTF32Char point) {
    return SZFIn(point, SZFVariationBases);
}

BOOL SZFriendsIsExtendedPictographic(UTF32Char point) {
    return SZFIn(point, SZFExtendedPictographic);
}

BOOL SZFriendsIsDualJoining(UTF32Char point) {
    return SZFIn(point, SZFDualJoining);
}

BOOL SZFriendsIsRightJoining(UTF32Char point) {
    return SZFIn(point, SZFRightJoining);
}

BOOL SZFriendsIsIndicConsonant(UTF32Char point) {
    return SZFIn(point, SZFIndicConsonants);
}

BOOL SZFriendsViramaBlock(UTF32Char point, UTF32Char *low, UTF32Char *high) {
    for (size_t index = 0; index < sizeof SZFViramas / sizeof SZFViramas[0]; index++) {
        if (SZFViramas[index].virama != point) continue;
        *low = SZFViramas[index].blockLow;
        *high = SZFViramas[index].blockHigh;
        return YES;
    }
    return NO;
}

// The scripts `point` is used with, into `scripts`: its Script_Extensions, or else its one Script, in `own`.
static size_t SZFScriptsOf(UTF32Char point, const unsigned char **scripts, unsigned char *own) {
    size_t low = 0, high = sizeof SZFScriptExtensions / sizeof SZFScriptExtensions[0];
    while (low < high) {
        size_t middle = low + (high - low) / 2;
        if (point > SZFScriptExtensions[middle].high) low = middle + 1;
        else if (point < SZFScriptExtensions[middle].low) high = middle;
        else {
            *scripts = SZFScriptSets + SZFScriptExtensions[middle].first;
            return SZFScriptExtensions[middle].count;
        }
    }
    // The last start at or before `point`; the first entry starts at U+0000.
    for (low = 0, high = sizeof SZFScripts / sizeof SZFScripts[0]; high - low > 1;) {
        size_t middle = low + (high - low) / 2;
        if (SZFScripts[middle].first <= point) low = middle;
        else high = middle;
    }
    *own = (unsigned char)SZFScripts[low].script;
    *scripts = own;
    return 1;
}

BOOL SZFriendsMarkFitsLetter(UTF32Char mark, UTF32Char letter) {
    unsigned char markOwn = 0, letterOwn = 0;
    const unsigned char *markScripts = NULL, *letterScripts = NULL;
    size_t marks = SZFScriptsOf(mark, &markScripts, &markOwn);
    size_t letters = SZFScriptsOf(letter, &letterScripts, &letterOwn);
    if (markScripts == &markOwn && markOwn == SZFScriptInherited) return YES; // no script of its own: U+0338, U+20E3
    for (size_t i = 0; i < marks; i++)
        for (size_t j = 0; j < letters; j++)
            if (markScripts[i] == letterScripts[j]) return YES;
    return NO;
}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--unicode-version", required=True, help="the version all inputs come from, as 18.0")
    parser.add_argument("--source", required=True, help="where the inputs came from, recorded in the output")
    for name in ("bases", "pict", "joining", "indic", "blocks", "scripts", "exts", "aliases"):
        parser.add_argument(name)
    arguments = parser.parse_args()
    version = arguments.unicode_version
    if not re.fullmatch(r"[0-9]+\.[0-9]+(\.[0-9]+)?", version):
        fail("--unicode-version must look like 18.0")
    bases = read_bases(arguments.bases, version)
    pictographic = read_pictographic(arguments.pict, version)
    dual = read_property(arguments.joining, version, "D")
    right = read_property(arguments.joining, version, "R")
    viramas = read_property(arguments.indic, version, "Virama")
    consonants = read_property(arguments.indic, version, "Consonant")
    blocks = read_blocks(arguments.blocks, version)
    starts = read_scripts(arguments.scripts, version, read_script_names(arguments.aliases, version))
    extensions = read_extensions(arguments.exts, version)
    # Sanity checks that catch a wrong file rather than a wrong version: each of these has been in its file since the
    # property began (the keycap bases and U+2764 since emoji-variation-sequences.txt 6.0, and so on).
    for point in [0x23, 0x2A] + list(range(0x30, 0x3A)) + [0x2764]:
        if point not in bases:
            fail("U+%04X is missing from %s" % (point, arguments.bases))
    if 0x1F600 not in pictographic or 0x41 in pictographic:
        fail("%s does not look like Extended_Pictographic" % arguments.pict)
    if 0x0628 not in dual or 0x0627 not in right or 0x0627 in dual:
        fail("%s does not look like DerivedJoiningType.txt" % arguments.joining)
    if 0x094D not in viramas or 0x0915 not in consonants or 0x0915 in viramas:
        fail("%s does not look like IndicSyllabicCategory.txt" % arguments.indic)
    if (0x0900, 0x097F) not in blocks:
        fail("%s does not look like Blocks.txt" % arguments.blocks)
    def script_of(point):
        return [name for first, name in starts if first <= point][-1]
    if starts[0][0] != 0 or script_of(0x41) != "Latn" or script_of(0xAC00) != "Hang" or script_of(0x301) != "Zinh":
        fail("%s or %s does not look like Scripts.txt and its aliases" % (arguments.scripts, arguments.aliases))
    if [script_of(point) for point in (0xD800, 0xE000, 0xF8FF, 0xF0000, 0x10FFFD)] != ["Zzzz"] * 5:
        fail("surrogates and private use must stay Unknown in %s" % arguments.scripts)
    if not any(low <= 0x3099 <= high and set(names) == {"Hira", "Kana"} for low, high, names in extensions):
        fail("%s does not look like ScriptExtensions.txt" % arguments.exts)
    source = re.sub(r"\s+", " ", arguments.source.strip())
    if "\n" in source or "*/" in source:
        fail("--source must be one plain line")
    header = "".join("// %s\n" % line for line in textwrap.wrap("Unicode %s. Source: %s." % (version, source), 114))
    sys.stdout.write("".join([
        "// Generated by friends/mac/tools/generate-emoji-tables.py; do not edit by hand, run it on newer files.\n",
        header,
        "//\n"
        "// The literal text a person approves (SZFriendsLiteralText.m) shows U+FE0E and U+FE0F as part of the\n"
        "// character before only after a base these sequences list, U+200D only between Extended_Pictographic\n"
        "// code points or beside a virama in a conjunct of its block, and U+200C only where it changes a shape:\n"
        "// between a dual-joining letter and a letter that joins to it, or after a virama before a consonant of its\n"
        "// block. Anywhere else they draw nothing, so they are marked. A combining mark is shown as itself only on a\n"
        "// letter of a script it is used with (Script_Extensions, else Script), or when it belongs to no script\n"
        "// (Inherited with no extensions).\n"
        "\n"
        "#import \"mac/SZFriendsComposerInternal.h\"\n"
        "\n",
        "NSString *const SZFriendsEmojiTablesUnicodeVersion = @\"%s\";\n" % version,
        "\n"
        "typedef struct {\n"
        "    UTF32Char low, high;\n"
        "} SZFCodePointRange;\n"
        "\n"
        "typedef struct {\n"
        "    UTF32Char virama, blockLow, blockHigh;\n"
        "} SZFViramaBlock;\n"
        "\n"
        "typedef struct {\n"
        "    UTF32Char first, script;\n"
        "} SZFScriptStart;\n"
        "\n"
        "typedef struct {\n"
        "    UTF32Char low, high, first, count;\n"
        "} SZFScriptExtension;\n"
        "\n"
        "// Bases of emoji-variation-sequences.txt: a U+FE0E or U+FE0F after one of these picks how it draws.\n",
        table("SZFVariationBases", bases),
        "\n// Extended_Pictographic: what a zero-width joiner may join into one emoji.\n",
        table("SZFExtendedPictographic", pictographic),
        "\n// Joining_Type D in DerivedJoiningType.txt: letters that join to the letter after them (and before).\n",
        table("SZFDualJoining", dual),
        "\n// Joining_Type R: letters that join only to the letter before them.\n",
        table("SZFRightJoining", right),
        "\n// Indic_Syllabic_Category Virama in IndicSyllabicCategory.txt, each with its block in Blocks.txt.\n",
        virama_table(viramas, blocks),
        "\n// Indic_Syllabic_Category Consonant: what a virama before it joins into a conjunct or a half form.\n",
        table("SZFIndicConsonants", consonants),
        script_tables(starts, extensions),
        LOOKUP,
    ]))


if __name__ == "__main__":
    main()
