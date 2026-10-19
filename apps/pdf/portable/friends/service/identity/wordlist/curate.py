#!/usr/bin/env python3
"""Builds the Friends ID word list from the EFF Large Wordlist and the hand review (ADR 0006).

Run once per list version, by hand, on the maintainer's Mac; the build never runs it. It exists so the list can be
re-derived and audited: the EFF file is checked against its pinned SHA-256, the review names the accepted words
and their tiers, and the mechanical rules 1 to 5 are applied exactly as friends-identity-check enforces them.

    python3 -I curate.py --eff eff_large_wordlist.txt --review review-v1.txt \
        --out friends-id-words-v1.txt --sample sample-500.txt

Only the standard library, so the audit needs nothing installed.
"""

import argparse
import hashlib
import itertools
import random
import re
import sys

EFF_URL = "https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt"
# SHA-256 of the file EFF has served unchanged since 18 July 2016 (Last-Modified header), downloaded from the URL
# above on 2026-10-12. It matches the digest published widely for this file since 2016.
EFF_SHA256 = "addd35536511597a02fa0a9ff1e5284677b8883b83e986e43f15a3db996b903e"
TARGET = 2048
# Rule 2's prefix length. Four until 2026-10-12, when ADR 0006 moved it to five so compound and longer everyday words
# (backyard beside backpack, candy beside candle) could replace the last-resort words.
PREFIX_LETTERS = 5
# Tiers from this one on are taken strictly in the order written, best first. The list fills up inside them, so the
# reviewer's order decides which unusual words make it, not how many rivals each word happens to have.
IN_ORDER_FROM_TIER = 7
VERSION = 1

ATTRIBUTION = (
    "Friends ID words are a selection from the EFF Large Wordlist for Passphrases by the Electronic Frontier "
    "Foundation (https://www.eff.org/dice), used under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). "
    "Changes: 2,048 of its 7,776 words selected; none altered."
)

# Irregular past tenses, participles and plurals. Rule 4 bans a word that is such a form of another listed word;
# regular forms are derived below, these cannot be. The same table is in tests/SZFriendsWordListTests.m.
IRREGULAR = {
    "arise": "arose arisen", "awake": "awoke awoken", "bear": "bore born", "begin": "began begun",
    "bite": "bit bitten", "blow": "blew blown", "break": "broke broken", "bring": "brought", "build": "built",
    "buy": "bought", "catch": "caught", "choose": "chose chosen", "come": "came", "dig": "dug",
    "draw": "drew drawn", "drink": "drank drunk", "drive": "drove driven", "eat": "ate eaten", "fall": "fell fallen",
    "feel": "felt", "find": "found", "fly": "flew flown", "freeze": "froze frozen", "get": "got gotten",
    "give": "gave given", "grow": "grew grown", "hang": "hung", "have": "had", "hear": "heard",
    "hide": "hid hidden", "hold": "held", "keep": "kept", "know": "knew known", "lay": "laid", "lead": "led",
    "leave": "left", "lend": "lent", "light": "lit", "lose": "lost", "make": "made", "mean": "meant",
    "meet": "met", "pay": "paid", "prove": "proven", "ride": "rode ridden", "ring": "rang rung",
    "rise": "rose risen", "run": "ran", "say": "said", "see": "saw seen", "sell": "sold", "send": "sent",
    "shake": "shook shaken", "shine": "shone", "shrink": "shrank shrunk", "sing": "sang sung", "sink": "sank sunk",
    "sit": "sat", "sleep": "slept", "slide": "slid", "speak": "spoke spoken", "spend": "spent",
    "spring": "sprang sprung", "stand": "stood", "steal": "stole stolen", "stick": "stuck", "sting": "stung",
    "stride": "strode", "strike": "struck", "swear": "swore sworn", "sweep": "swept", "swim": "swam swum",
    "swing": "swung", "take": "took taken", "teach": "taught", "tear": "tore torn", "tell": "told",
    "think": "thought", "throw": "threw thrown", "wake": "woke woken", "wear": "wore worn", "weave": "wove woven",
    "win": "won", "wind": "wound", "write": "wrote written",
    "rebuild": "rebuilt", "remake": "remade", "retell": "retold", "rewind": "rewound", "rewrite": "rewrote rewritten",
    "unbend": "unbent", "undo": "undid undone", "unfreeze": "unfroze unfrozen", "unweave": "unwove unwoven",
    "unwind": "unwound", "outgrow": "outgrew outgrown", "undergo": "underwent undergone",
    "elf": "elves", "half": "halves", "leaf": "leaves", "loaf": "loaves", "knife": "knives", "wolf": "wolves",
    "mouse": "mice", "goose": "geese", "child": "children", "foot": "feet", "tooth": "teeth",
}


def fail(message):
    print("curate: " + message, file=sys.stderr)
    sys.exit(1)


def read_eff(path):
    data = open(path, "rb").read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != EFF_SHA256:
        fail("%s has SHA-256 %s, expected %s" % (path, digest, EFF_SHA256))
    # Structure as published: 7,776 lines "<five dice digits>\t<word>", dice in order, words sorted and unique.
    lines = data.decode("ascii").split("\n")
    if lines[-1] != "":
        fail("EFF file does not end with a newline")
    dice = ["".join(p) for p in itertools.product("123456", repeat=5)]
    words = []
    for index, line in enumerate(lines[:-1]):
        roll, word = line.split("\t")
        if roll != dice[index]:
            fail("unexpected dice number on line %d" % (index + 1))
        words.append(word)
    if len(words) != 7776 or words != sorted(set(words)):
        fail("EFF file is not 7,776 sorted unique words")
    return words


def read_review(path, eff):
    eff_set = set(eff)
    tiers = {}
    order = []
    for number, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"T([1-8]):(.*)", line)
        if not match:
            fail("%s:%d: expected 'T<tier>: words'" % (path, number))
        for word in match.group(2).split():
            if word not in eff_set:
                fail("%s:%d: %s is not in the EFF list" % (path, number, word))
            if word in tiers:
                fail("%s:%d: %s is reviewed twice" % (path, number, word))
            tiers[word] = int(match.group(1))
            order.append(word)
    return tiers, order


def prefix_key(word):
    # Rule 2: the first five letters, or the whole word for shorter words.
    return word[:PREFIX_LETTERS]


def within_one_edit(a, b):
    # Rule 3 fails for Levenshtein distance 0 or 1: one substitution, insertion or deletion.
    if abs(len(a) - len(b)) > 1:
        return False
    if len(a) == len(b):
        return sum(x != y for x, y in zip(a, b)) <= 1
    if len(a) > len(b):
        a, b = b, a
    i = 0
    while i < len(a) and a[i] == b[i]:
        i += 1
    return a[i:] == b[i + 1:]


def lrn_confusable(a, b):
    # Rule 5: same length, and every differing position is an l/r or n/l swap.
    if len(a) != len(b) or a == b:
        return False
    return all(x == y or {x, y} in ({"l", "r"}, {"n", "l"}) for x, y in zip(a, b))


def inflections(base):
    # Rule 4's regular forms of `base`: plural, past tense, -ing and -er, with the usual spelling changes.
    forms = {base + s for s in ("s", "es", "ed", "d", "ing", "er", "r")}
    if base.endswith("e"):
        forms |= {base[:-1] + "ing", base[:-1] + "er"}
    if len(base) >= 2 and base.endswith("y") and base[-2] not in "aeiou":
        forms |= {base[:-1] + s for s in ("ies", "ied", "ier")}
    if len(base) >= 3 and base[-1] not in "aeiouwxy" and base[-2] in "aeiou" and base[-3] not in "aeiou":
        forms |= {base + base[-1] + s for s in ("ed", "ing", "er")}
    forms |= set(IRREGULAR.get(base, "").split())
    return forms


def conflict(a, b):
    # A word that begins another (oat, oatmeal) would leave its whole spelling ambiguous to someone typing, so it
    # counts as sharing a prefix. The EFF list has no such pair; this keeps rule 2's promise if a source ever does.
    if prefix_key(a) == prefix_key(b) or a.startswith(b) or b.startswith(a):
        return "rule 2 (first five letters)"
    if within_one_edit(a, b):
        return "rule 3 (edit distance)"
    if a in inflections(b) or b in inflections(a):
        return "rule 4 (inflection)"
    if lrn_confusable(a, b):
        return "rule 5 (l/r, n/l)"
    return None


def select(tiers, order):
    words = list(order)
    neighbours = {w: set() for w in words}
    for i, a in enumerate(words):
        for b in words[i + 1:]:
            if conflict(a, b):
                neighbours[a].add(b)
                neighbours[b].add(a)
    position = {w: i for i, w in enumerate(order)}
    # Simplest tier first. Within tiers 1 to 6, words that block fewer others go first, which keeps the most words;
    # ties fall back to review order. Tiers 7 and 8 are taken strictly in the order written, best first, and selection
    # stops at exactly TARGET, so their tail is what the list does without.
    def rank(w):
        return (tiers[w], 0 if tiers[w] >= IN_ORDER_FROM_TIER else len(neighbours[w]), position[w])

    ranked = sorted(words, key=rank)
    chosen = set()
    for word in ranked:
        if len(chosen) == TARGET:
            break
        if not neighbours[word] & chosen:
            chosen.add(word)
    if len(chosen) != TARGET:
        fail("only %d words survive rules 1 to 5; review more words" % len(chosen))
    return sorted(chosen)


def check(words):
    # Rules 1 to 5 once more on the result, independently of the selection logic.
    if len(words) != TARGET or words != sorted(set(words)):
        fail("result is not %d sorted unique words" % TARGET)
    for word in words:
        if not re.fullmatch(r"[a-z]{3,8}", word):
            fail("rule 1: %s" % word)
    for i, a in enumerate(words):
        for b in words[i + 1:]:
            reason = conflict(a, b)
            if reason:
                fail("%s: %s and %s" % (reason, a, b))


def word_lines_digest(words):
    return hashlib.sha256("".join(w + "\n" for w in words).encode("ascii")).hexdigest()


def write_list(path, words):
    header = [
        "Shenzhen Friends ID words, version %d. One word per line after these header lines." % VERSION,
        "version: %d" % VERSION,
        "count: %d" % len(words),
    ]
    attribution, line = [], ""
    for token in ATTRIBUTION.split(" "):
        if line and len(line) + 1 + len(token) > 110:
            attribution.append(line)
            line = token
        else:
            line = token if not line else line + " " + token
    attribution.append(line)
    header += attribution
    header += [
        "source: %s" % EFF_URL,
        "source-sha256: %s" % EFF_SHA256,
        "source-retrieved: 2026-10-12, from eff.org",
        "license: CC BY 4.0, https://creativecommons.org/licenses/by/4.0/ (EFF: https://www.eff.org/copyright)",
        "selection: ADR 0006 rules 1 to 5 checked by friends-identity-check, rules 6 to 9 by hand; see WORDLIST.md",
        "words-sha256: %s (pinned in SZFriendsWordList.m)" % word_lines_digest(words),
    ]
    with open(path, "w", encoding="ascii", newline="\n") as out:
        for line in header:
            out.write("# " + line + "\n")
        for word in words:
            out.write(word + "\n")


def write_sample(path, words):
    # ADR 0006: reviewers read 500 random IDs for unfortunate combinations. A fixed seed keeps the sample stable
    # between runs, so the owner reviews the same IDs the maintainer did.
    rng = random.Random("SZFriends ID sample v%d" % VERSION)
    with open(path, "w", encoding="ascii", newline="\n") as out:
        out.write("# 500 random two-word Friends IDs from version %d, for the owner's review (ADR 0006).\n" % VERSION)
        for _ in range(500):
            out.write("%s-%s\n" % (rng.choice(words), rng.choice(words)))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--eff", required=True)
    parser.add_argument("--review", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--sample")
    args = parser.parse_args()
    eff = read_eff(args.eff)
    tiers, order = read_review(args.review, eff)
    words = select(tiers, order)
    check(words)
    write_list(args.out, words)
    if args.sample:
        write_sample(args.sample, words)
    counts = {t: sum(1 for w in words if tiers[w] == t) for t in sorted(set(tiers.values()))}
    print("curate: %d words, by tier %s, words-sha256 %s" % (len(words), counts, word_lines_digest(words)))


if __name__ == "__main__":
    main()
