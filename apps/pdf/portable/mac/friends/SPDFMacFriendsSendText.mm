#import "SPDFMacFriendsSendText.h"
#include <vector>
#import "SPDFMacFriendsEmojiTables.h"

typedef std::vector<UTF32Char> SPDFCodePoints;

static BOOL InRange(UTF32Char point, UTF32Char low, UTF32Char high) { return point >= low && point <= high; }

static SPDFCodePoints Decode(NSString* text, BOOL* broken) {
    NSUInteger length = text.length;
    std::vector<unichar> units(length);
    [text getCharacters:units.data() range:NSMakeRange(0, length)];
    SPDFCodePoints points;
    points.reserve(length);
    for (NSUInteger index = 0; index < length; index++) {
        unichar unit = units[index];
        if (CFStringIsSurrogateHighCharacter(unit) && index + 1 < length &&
            CFStringIsSurrogateLowCharacter(units[index + 1])) {
            points.push_back(CFStringGetLongCharacterForSurrogatePair(unit, units[index + 1]));
            index++;
        } else if (CFStringIsSurrogateHighCharacter(unit) || CFStringIsSurrogateLowCharacter(unit)) {
            *broken = YES; // half a character: no font draws it, and the friend's app may not read it the same way
            return points;
        } else {
            points.push_back(unit);
        }
    }
    return points;
}

static NSString* StringFromPoints(const SPDFCodePoints& points) {
    NSStringEncoding host = NSHostByteOrder() == NS_LittleEndian ? NSUTF32LittleEndianStringEncoding
                                                                 : NSUTF32BigEndianStringEncoding;
    return [[NSString alloc] initWithBytes:points.data() length:points.size() * sizeof(UTF32Char)
                                  encoding:host] ?: @"";
}

static BOOL IsVariationSelector(UTF32Char point) {
    return InRange(point, 0xFE00, 0xFE0F) || InRange(point, 0xE0100, 0xE01EF);
}

template <size_t count>
static BOOL InTable(UTF32Char point, const SPDFMacFriendsCodePointRange (&table)[count]) {
    size_t low = 0, high = count;
    while (low < high) {
        size_t middle = (low + high) / 2;
        if (point > table[middle].high) low = middle + 1;
        else if (point < table[middle].low) high = middle;
        else return YES;
    }
    return NO;
}

// What a presentation selector can follow and still be seen: Unicode's emoji variation sequence bases. After anything
// else, kana, CJK punctuation, an arrow without such a sequence, U+FE0E and U+FE0F draw exactly the text without them
// (security review, measured pixel for pixel). Residual of this rule, accepted (E1) and recorded in the plan: after
// many listed bases one selector or both draw the same as none (measured on macOS 26: U+FE0E after 309 of 359 bases,
// U+FE0F after 241), so each listed base can carry one hidden choice of three (none, U+FE0E or U+FE0F), and so can the
// selector of an emoji inside a joiner sequence. Closing it would mean removing selectors from what the model writes.
static BOOL IsVariationBase(UTF32Char point) { return InTable(point, kSPDFMacFriendsEmojiVariationBases); }

// Digits, # and *: Unicode lists them as bases too, but a selector there belongs to a keycap (1️⃣ is "1", U+FE0F,
// U+20E3), so it counts only right before the keycap's U+20E3. "1" with U+FE0E alone draws exactly "1".
static BOOL IsKeycapBase(UTF32Char point) { return InRange(point, '0', '9') || point == '#' || point == '*'; }

// What a zero-width joiner merges into one emoji (👩‍💻): Unicode's Extended_Pictographic. Between anything else it
// draws nothing.
static BOOL IsPictograph(UTF32Char point) { return InTable(point, kSPDFMacFriendsExtendedPictographic); }

// Skin tones, which sit between an emoji and its joiner (👩🏽‍💻) and draw themselves.
static BOOL IsEmojiModifier(UTF32Char point) { return InRange(point, 0x1F3FB, 0x1F3FF); }

// Where a zero-width non-joiner changes a shape, and so is seen: between a letter that joins to the letter after it
// (Joining_Type D) and one that joins to the letter before it (D or R), which it keeps apart (Persian می‌خواهم); and
// right after a virama before a consonant of the virama's block, where it shows the virama instead of a conjunct or a
// half form (क्‌ष). Between other Arabic or Indic characters (digits, a letter that joins nothing, two consonants
// with no virama) it draws nothing, so a hidden bit per letter (security review, round 3). Residual, accepted: a D
// letter of one joining script before a D or R letter of another draws the same without it, since fonts shape each
// script apart; such text shows two scripts touching (ai-agent-capabilities.md § 1, one rule with the card's markers).
static BOOL NonJoinerSeen(UTF32Char before, UTF32Char after) {
    if (InTable(before, kSPDFMacFriendsDualJoining) &&
        (InTable(after, kSPDFMacFriendsDualJoining) || InTable(after, kSPDFMacFriendsRightJoining)))
        return YES;
    for (const SPDFMacFriendsViramaBlock& virama : kSPDFMacFriendsViramas)
        if (virama.virama == before)
            return InRange(after, virama.blockLow, virama.blockHigh) && InTable(after, kSPDFMacFriendsIndicConsonants);
    return NO;
}

// Where a zero-width joiner shapes an Indic conjunct, and so is seen: right after a virama before a consonant of the
// virama's block (Sinhala ශ්‍රී, Devanagari क्‍ष), or right after such a consonant before the virama when another
// consonant of the block follows it (Bengali র‍্য). At a word's end (क‍्) there is no conjunct, and fonts draw a
// Bengali or Malayalam consonant there the same without it (verify, wave 6e), so it is refused there.
// Residual, accepted and measured (wave 6e, AppKit and Pango, every consonant pair of the ten scripts from Devanagari
// to Sinhala): where a font has no conjunct for the pair, the joiner draws the same as none, after the virama in 8,379
// of 14,762 pairs and before it in 1,968, as a non-joiner after a virama does in 5,648; so a conjunct can carry a
// hidden choice of none, a non-joiner or a joiner, as an emoji base carries one of its selectors.
static BOOL JoinerInConjunct(UTF32Char before, UTF32Char after, UTF32Char afterNext) {
    for (const SPDFMacFriendsViramaBlock& virama : kSPDFMacFriendsViramas) {
        auto consonant = [&virama](UTF32Char point) {
            return InRange(point, virama.blockLow, virama.blockHigh) && InTable(point, kSPDFMacFriendsIndicConsonants);
        };
        if (virama.virama == before) return consonant(after);
        if (virama.virama == after) return consonant(before) && consonant(afterNext);
    }
    return NO;
}

// Draws nothing, or nothing a reader can tell from a space, whatever its neighbours: controls other than tab and
// line feed, format characters, Unicode's default-ignorable code points (fillers, invisible operators, tags,
// variation selectors), blank pictures, the attachment placeholder, private use and unassigned code points.
static BOOL IsInvisible(UTF32Char point) {
    static NSCharacterSet* controls, *unassigned;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        controls = NSCharacterSet.controlCharacterSet; // Cc and Cf
        unassigned = NSCharacterSet.illegalCharacterSet;
    });
    if (point == '\t' || point == '\n') return NO;
    return [controls longCharacterIsMember:point] || [unassigned longCharacterIsMember:point] || point == 0x00AD ||
        point == 0x034F || point == 0x061C || InRange(point, 0x115F, 0x1160) || InRange(point, 0x17B4, 0x17B5) ||
        InRange(point, 0x180B, 0x180F) || InRange(point, 0x200B, 0x200F) || InRange(point, 0x202A, 0x202E) ||
        InRange(point, 0x2060, 0x206F) || point == 0x2800 || point == 0x3164 || IsVariationSelector(point) ||
        point == 0xFEFF || point == 0xFFA0 || InRange(point, 0xFFF0, 0xFFF8) || point == 0xFFFC ||
        InRange(point, 0x1BCA0, 0x1BCA3) || InRange(point, 0x1D173, 0x1D17A) || InRange(point, 0xE0000, 0xE0FFF) ||
        InRange(point, 0xE000, 0xF8FF) || InRange(point, 0xF0000, 0xFFFFD) || InRange(point, 0x100000, 0x10FFFD);
}

// Whether the invisible character at `index` is part of what its neighbours draw, and so is seen through them
// (ai-agent-capabilities.md § 1): a non-joiner where it changes a shape, a joiner inside an emoji sequence or an Indic
// conjunct, or one presentation selector after a base Unicode lists for it. Anything looser lets text ride along
// unseen: one of 256 variation selectors after every letter is a byte per letter, a joiner between kana is a bit, and
// tag characters spell out ASCII (subdivision flags, which use tags, are refused with them).
static BOOL SeenThroughNeighbours(const SPDFCodePoints& points, size_t index) {
    UTF32Char point = points[index];
    UTF32Char before = index ? points[index - 1] : 0, after = index + 1 < points.size() ? points[index + 1] : 0;
    if (point == 0x200C) return NonJoinerSeen(before, after);
    if (point == 0x200D) {
        // The emoji's own presentation selector or skin tone may sit between it and the joiner (rainbow flag:
        // U+1F3F3 U+FE0F U+200D U+1F308; woman technologist, medium skin tone: U+1F469 U+1F3FD U+200D U+1F4BB). Only
        // its own: a selector that is not seen itself (U+1F469 U+FE0F) joins nothing a reader sees.
        if (JoinerInConjunct(before, after, index + 2 < points.size() ? points[index + 2] : 0)) return YES;
        size_t base = index;
        if (base > 0 && points[base - 1] == 0xFE0F) {
            if (!SeenThroughNeighbours(points, base - 1)) return NO;
            base--;
        } else if (base > 0 && IsEmojiModifier(points[base - 1])) {
            base--;
        }
        return base > 0 && IsPictograph(points[base - 1]) && IsPictograph(after);
    }
    if (point == 0xFE0E || point == 0xFE0F) return IsKeycapBase(before) ? after == 0x20E3 : IsVariationBase(before);
    return NO;
}

static BOOL IsCombiningMark(UTF32Char point) {
    static NSCharacterSet* marks;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ marks = NSCharacterSet.nonBaseCharacterSet; }); // Mn, Mc and Me
    return [marks longCharacterIsMember:point];
}

// The combining marks kept on one base so far. Some marks draw exactly the same picture once or sixty-four times
// (U+065E or U+0732 after a letter, U+0489 or the Syriac marks after an emoji: security review, measured pixel for
// pixel with TextKit as the card lays it out), so how many repeats there are would be a hidden number on every base
// that carries one; and on a pile of more than four, nobody can count what is there. So a base takes each mark once
// and at most four: Vietnamese, Arabic with full vowels, Devanagari and Thai need three at most, while pointed Hebrew
// with cantillation, which can need five, is refused and written again plainer. Residual, accepted: two different
// marks that draw the same glyph can still stand for one another, like the cross-script lookalikes below.
struct SPDFMarkStack {
    UTF32Char marks[4];
    size_t count = 0;
    bool Admits(UTF32Char mark) const {
        if (count == 4) return false;
        for (size_t index = 0; index < count; index++)
            if (marks[index] == mark) return false;
        return true;
    }
    void Add(UTF32Char mark) { marks[count++] = mark; }
};

// The marks a letter carries before any follow it: those of its own canonical decomposition (NFD). The text is
// composed first, so a typed "e", U+0323, U+0302 arrives as the one code point U+1EC7, and "=", U+0338 as U+2260;
// counting only the marks after them let six marks sit on one e, or U+0338 twice on "=" (security review, wave 6b).
// A mark counts as NFC writes it, even one that decomposes into two (Bengali U+09CB is U+09C7 and U+09BE): Unicode's
// Tulu-Tigalari U+113C5 is U+113C2 twice, so counting parts would refuse a plain vowel, and no such sign was measured
// drawing the same with one of its parts again. Nothing below U+00C0 decomposes.
static SPDFMarkStack LetterMarks(UTF32Char letter) {
    SPDFMarkStack stack;
    if (letter < 0xC0) return stack;
    BOOL broken = NO;
    NSString* decomposed = StringFromPoints(SPDFCodePoints{letter}).decomposedStringWithCanonicalMapping;
    SPDFCodePoints parts = Decode(decomposed, &broken);
    for (size_t index = 1; index < parts.size(); index++)
        if (IsCombiningMark(parts[index]) && stack.Admits(parts[index])) stack.Add(parts[index]);
    return stack;
}

// Whether `mark` is drawn on `letter` as its own: SPDFMacFriendsMarkFitsLetter, or a Quranic pause or annotation mark
// after a space, where standard Quran text (Tanzil Uthmani: "لَا رَيْبَ ۛ فِيهِ ۛ") writes them as words of their own
// and they draw there (wave 6e: each of the 19 drew after U+0020 and U+00A0 in AppKit and Pango, pixel for pixel).
// The spaces are those Normalized writes as U+0020, so the cards, which see them unchanged, agree.
static BOOL MarkFits(UTF32Char mark, UTF32Char letter) {
    BOOL quranic = InRange(mark, 0x06D6, 0x06DC) || InRange(mark, 0x06DF, 0x06E4) || InRange(mark, 0x06E7, 0x06E8) ||
        InRange(mark, 0x06EA, 0x06ED);
    BOOL space = letter == ' ' || letter == 0x00A0 || letter == 0x1680 || InRange(letter, 0x2000, 0x200A) ||
        letter == 0x202F || letter == 0x205F;
    return (quranic && space) || SPDFMacFriendsMarkFitsLetter(mark, letter);
}

// Which code points of `points` (composed) a reader cannot see: an invisible character its neighbours do not show; a
// mark of another script than its base's, which a font can draw as nothing (U+3099 on a Hangul syllable, a Bassa Vah
// tone on Cyrillic: wave 6c, pixel for pixel), so a mark must fit its base (MarkFits); and a mark its base already
// carries, its own decomposition's included, or has no room for. The base is the last code point kept that is not a
// mark (U+0000 before the first) nor a joiner, so a refused character between a letter and its marks hides nothing
// (the card marks it, a draft drops it, and the marks still count on that letter), and the virama after a conjunct's
// joiner (Bengali র‍্য) counts on the consonant before it. One rule with the card's markers
// (SPDFMacAIActivityVisibleText) and the Friends views. `foreign`, when given, holds the base where a mark is refused
// for its script, and kNotForeign elsewhere.
static const UTF32Char kNotForeign = 0xFFFFFFFF;
static std::vector<bool> UnseenPoints(const SPDFCodePoints& points, std::vector<UTF32Char>* foreign = nullptr) {
    std::vector<bool> unseen(points.size(), false);
    if (foreign) foreign->assign(points.size(), kNotForeign);
    SPDFMarkStack stack;
    UTF32Char base = 0;
    for (size_t index = 0; index < points.size(); index++) {
        UTF32Char point = points[index];
        if (IsInvisible(point) && !SeenThroughNeighbours(points, index)) unseen[index] = true;
        else if (point == 0x200D) continue;
        else if (!IsCombiningMark(point)) stack = LetterMarks(base = point);
        else if (!MarkFits(point, base)) {
            unseen[index] = true;
            if (foreign) (*foreign)[index] = base;
        } else if (stack.Admits(point)) {
            stack.Add(point);
        } else {
            unseen[index] = true;
        }
    }
    return unseen;
}

// Line breaks one way, spaces one width, no trailing spaces, at most one blank line in a row.
static SPDFCodePoints Normalized(const SPDFCodePoints& points) {
    SPDFCodePoints out;
    out.reserve(points.size());
    auto trimLine = [&out] { while (!out.empty() && (out.back() == ' ' || out.back() == '\t')) out.pop_back(); };
    for (size_t index = 0; index < points.size(); index++) {
        UTF32Char point = points[index];
        if (point == '\r' && index + 1 < points.size() && points[index + 1] == '\n') continue;
        if (point == '\r' || point == 0x0085 || point == 0x2028 || point == 0x2029) point = '\n';
        if (point == 0x00A0 || point == 0x1680 || InRange(point, 0x2000, 0x200A) || point == 0x202F || point == 0x205F)
            point = ' ';
        if (point == '\n') {
            trimLine();
            size_t breaks = 0;
            for (size_t back = out.size(); back > 0 && out[back - 1] == '\n'; back--) breaks++;
            if (breaks >= 2) continue;
        }
        out.push_back(point);
    }
    trimLine();
    return out;
}

// Compatibility spellings that draw exactly like the plain letters they stand for, measured in the card's font: the
// ligatures ﬁ and ﬂ, the micro sign µ beside Greek μ, Latin digraphs such as ǆ and ĳ, Tibetan's deprecated vowel
// signs, and Arabic and Hebrew presentation forms beside the letters they show (an isolated form draws the letter on
// its own, a contextual one the letter where it stands), and the radical ⺟ beside 母 in macOS 15's fonts. Each
// would be a hidden bit, so they become their compatibility decomposition (NFKC), which shaping draws the same. Not
// all of NFKC: x², ½, ①, ™ and fullwidth letters look different from what they fold to, and folding them would
// change what the message says.
static BOOL FoldsToCompatibility(UTF32Char point) {
    return point == 0x00B5 || InRange(point, 0x0132, 0x0133) || InRange(point, 0x013F, 0x0140) || point == 0x0149 ||
        InRange(point, 0x01C4, 0x01CC) || InRange(point, 0x01F1, 0x01F3) || point == 0x0F77 || point == 0x0F79 ||
        point == 0x2E9F || InRange(point, 0xFB00, 0xFDFF) || InRange(point, 0xFE70, 0xFEFE);
}

// One spelling where two draw the same and say the same: the folds above; the hyphen U+2010 and the non-breaking
// hyphen U+2011 as "-", which draws the same; and Thai and Lao sara am written as its two parts (nikhahit and sara aa)
// as the one character every keyboard types. Residual, accepted (E1): letters of different scripts that look alike
// (Latin K and Greek Κ, Latin o and Greek ο) stay as written, since folding one script into another would change
// the text; so does a Hangul letter written as a conjoining jamo standing alone, which draws like the compatibility
// jamo (ㄱ) but which folding would join into the syllables around it.
static NSString* Folded(NSString* text) {
    BOOL broken = NO;
    SPDFCodePoints points = Decode(text, &broken);
    if (broken) return text; // the caller refuses it, or a draft has already replaced the half character
    NSMutableString* folded = [NSMutableString stringWithCapacity:text.length];
    for (size_t index = 0; index < points.size(); index++) {
        UTF32Char point = points[index], next = index + 1 < points.size() ? points[index + 1] : 0;
        if ((point == 0x0E4D && next == 0x0E32) || (point == 0x0ECD && next == 0x0EB2)) {
            point = point == 0x0E4D ? 0x0E33 : 0x0EB3;
            index++;
        }
        NSString* one = StringFromPoints(SPDFCodePoints{point == 0x2010 || point == 0x2011 ? (UTF32Char)'-' : point});
        [folded appendString:FoldsToCompatibility(point) ? one.precomposedStringWithCompatibilityMapping : one];
    }
    return folded;
}

// Composed (NFC): "e" with U+0301 and "é" draw the same, as do singletons such as the Angstrom sign and "Å", so the
// spelling would be a hidden bit per letter; composed, what the card shows and Friends delivers is one spelling.
static NSString* Composed(NSString* text) { return text.precomposedStringWithCanonicalMapping ?: text; }

NSString* SPDFMacFriendsVisibleText(NSString* text, NSString** refusal) {
    if (![text isKindOfClass:NSString.class]) text = @"";
    text = Composed(Folded(text));
    BOOL broken = NO;
    SPDFCodePoints points = Normalized(Decode(text, &broken));
    // A flag, not the code point itself: U+0000 is a character to refuse, not "nothing found".
    BOOL found = broken;
    UTF32Char hidden = 0xFFFD, base = kNotForeign;
    std::vector<UTF32Char> foreign;
    std::vector<bool> unseen = broken ? std::vector<bool>() : UnseenPoints(points, &foreign);
    for (size_t index = 0; !found && index < points.size(); index++)
        if (unseen[index]) {
            found = YES;
            hidden = points[index];
            base = foreign[index];
        }
    if (found) {
        if (refusal) {
            if (broken)
                *refusal = @"The message holds half of a character, which the user can't see on the card. Write it "
                            "again. Nothing was sent.";
            else if (base == 0 || [NSCharacterSet.whitespaceAndNewlineCharacterSet longCharacterIsMember:base])
                *refusal = [NSString stringWithFormat:@"The message puts a mark (U+%04X) on a space or the start of a "
                               "line rather than on a letter, so the user might not see it on the card. Write it again "
                               "with each mark right after its letter. Nothing was sent.", (unsigned)hidden];
            else if (base != kNotForeign)
                *refusal = [NSString stringWithFormat:@"The message puts a mark (U+%04X) on a letter of another "
                               "script, where it can draw nothing, so the user might not see it on the card. Write it "
                               "again with each letter's marks from its own script. Nothing was sent.",
                               (unsigned)hidden];
            else if (IsCombiningMark(hidden) && !IsInvisible(hidden))
                *refusal = [NSString stringWithFormat:@"The message puts a mark (U+%04X) on a letter that already has "
                               "it, or a fifth mark on one letter, so the user can't count them on the card. A "
                               "precomposed letter counts its own marks (\u1EC7 is e with two marks). Write it again "
                               "with each mark once and at most four on a letter. Nothing was sent.", (unsigned)hidden];
            else
                *refusal = [NSString stringWithFormat:@"The message holds a character the user can't see on the card "
                               "(U+%04X). Write it again without invisible characters. Nothing was sent.",
                               (unsigned)hidden];
        }
        return nil;
    }
    return StringFromPoints(points);
}

NSString* SPDFMacFriendsDraftText(NSString* text) {
    if (![text isKindOfClass:NSString.class]) return @"";
    NSMutableString* whole = [text mutableCopy];
    // Half a character becomes the replacement character, which is seen.
    for (NSUInteger index = 0; index < whole.length; index++) {
        unichar unit = [whole characterAtIndex:index];
        BOOL pair = CFStringIsSurrogateHighCharacter(unit) && index + 1 < whole.length &&
            CFStringIsSurrogateLowCharacter([whole characterAtIndex:index + 1]);
        if (pair) index++;
        else if (CFStringIsSurrogateHighCharacter(unit) || CFStringIsSurrogateLowCharacter(unit))
            [whole replaceCharactersInRange:NSMakeRange(index, 1) withString:@"\uFFFD"];
    }
    BOOL broken = NO;
    SPDFCodePoints points = Normalized(Decode(Composed(Folded(whole)), &broken));
    // Composed and made one way again after each removal, until nothing goes: a removed character can leave a letter
    // and its accent side by side, or a space at a line's end; and two parts can compose into a sign the letter already
    // carries (U+09C7 and U+09BE become U+09CB), which goes in the next round. Each round removes one or more.
    for (;;) {
        std::vector<bool> unseen = UnseenPoints(points);
        SPDFCodePoints kept;
        kept.reserve(points.size());
        for (size_t index = 0; index < points.size(); index++)
            if (!unseen[index]) kept.push_back(points[index]);
        if (kept.size() == points.size()) return StringFromPoints(points);
        points = Normalized(Decode(Composed(StringFromPoints(kept)), &broken));
    }
}

NSString* SPDFMacFriendsTextForFriend(NSString* text) {
    static NSRegularExpression* links;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // [label](target) where the target is not a web or mail link: the reader's document citations, Friends
        // message citations, file URLs.
        links = [NSRegularExpression regularExpressionWithPattern:
            @"\\[([^\\]\\n]*)\\]\\((?!\\s*(?:https?|mailto):)[^)\\n]*\\)" options:NSRegularExpressionCaseInsensitive
                                                                   error:nil];
    });
    if (![text isKindOfClass:NSString.class]) return @"";
    return [links stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                                      withTemplate:@"$1"];
}
