// SZFriendsLiteralText: a message exactly as Friends will deliver it, for the person to approve before it goes.
//
// WHY its own rule rather than plain -setString:: a proposal can come from a command that read a friend's messages,
// and a planted instruction could hide what goes inside characters that draw nothing (zero-width spaces and joiners,
// direction overrides that reorder what follows, tag characters, controls). Each such character is shown as its code
// point instead, so nothing the person approves is invisible to them. The exceptions are only where the character
// changes what its neighbours draw (ai-agent-capabilities.md § 1, one rule with the send check in the host, which
// may not share this code; both run friends/fixtures/text/invisible-cases.json):
//   - U+FE0E or U+FE0F after a base Unicode lists in emoji-variation-sequences.txt, and after a keycap base
//     (# * 0-9) only when U+20E3 follows, since "1" with a selector alone draws as "1";
//   - U+200D between Extended_Pictographic code points, the first one's own U+FE0F (not one marked itself) or skin
//     tone between them (UTS #51 emoji ZWJ elements: 👩🏽‍💻, 🏳️‍🌈), and in an Indic conjunct: right after a virama
//     before a consonant of the virama's block (Sinhala ශ්‍රී), or right after such a consonant before the virama
//     when a consonant of the block follows it (Bengali র‍্য);
//   - U+200C where it changes a shape: between a letter that joins to the letter after it (Joining_Type D) and one
//     that joins to the letter before it (D or R), as in Persian می‌خواهم, and right after a virama before a
//     consonant of the virama's block, where it shows the virama instead of a conjunct (क्‌ष).
// A combining mark that draws is shown as its code point too when its letter already carries it or already carries
// four, since repeats of some marks draw nothing more, and when it belongs to another script than its letter's, since
// a font can draw it as nothing there (SZFMarkedFlags); a Quranic pause or annotation mark may stand on a space, as
// Quran text writes them ("رَيْبَ ۛ فِيهِ"), where they draw. The text is composed (NFC) first, as the send check
// composes what Friends delivers, so "e" and U+0301 show as "é", and a letter starts out carrying the marks of
// its own decomposition (U+1EC7 carries U+0323 and U+0302).
// Residual, accepted (E1): after many bases that list both selectors, one selector or both draw the same as none, so
// each such base can carry one hidden choice of three (none, U+FE0E or U+FE0F), and so can the selector of an emoji
// inside a joiner sequence; a non-joiner between a D letter of one joining script and a letter of another draws the
// same as none, since fonts shape each script apart; and where a font has no conjunct for two consonants, a joiner or
// non-joiner beside their virama draws the same as none (measured, wave 6e: the host's send check gives the counts).

#import "mac/SZFriendsComposerInternal.h"

// Characters that draw nothing or change how neighbours draw: controls other than tab and line breaks, Unicode's
// default-ignorable code points (DerivedCoreProperties.txt), the interlinear annotation and object replacement
// characters, Egyptian hieroglyph format controls, and the braille blank, which reads as a space. Private-use
// characters too: what they draw depends on the font, many draw nothing, and the host's send check refuses them all,
// so one that reached a card shows as its code point.
BOOL SZFriendsCharacterDrawsNothing(UTF32Char c) {
    if (c == '\t' || c == '\n' || c == '\r') return NO;
    if (c < 0x20 || (c >= 0x7F && c <= 0x9F)) return YES;
    switch (c) {
    case 0x00AD: case 0x034F: case 0x061C: case 0x115F: case 0x1160: case 0x17B4: case 0x17B5: case 0x2800:
    case 0x3164: case 0xFEFF: case 0xFFA0:
        return YES;
    default:
        break;
    }
    return (c >= 0x180B && c <= 0x180F) || (c >= 0x200B && c <= 0x200F) || (c >= 0x202A && c <= 0x202E) ||
           (c >= 0x2060 && c <= 0x206F) || (c >= 0xFE00 && c <= 0xFE0F) || (c >= 0xFFF0 && c <= 0xFFFC) ||
           (c >= 0x13430 && c <= 0x1343F) || (c >= 0x1BCA0 && c <= 0x1BCA3) || (c >= 0x1D173 && c <= 0x1D17A) ||
           (c >= 0xE0000 && c <= 0xE0FFF) || (c >= 0xE000 && c <= 0xF8FF) || (c >= 0xF0000 && c <= 0xFFFFD) ||
           (c >= 0x100000 && c <= 0x10FFFD);
}

static BOOL SZFIsKeycapBase(UTF32Char c) {
    return (c >= '0' && c <= '9') || c == '#' || c == '*';
}

static BOOL SZFIsSkinTone(UTF32Char c) {
    return c >= 0x1F3FB && c <= 0x1F3FF;
}

// Whether a zero-width non-joiner between `before` and `after` changes a shape (the rule above). Between other Arabic
// or Indic characters (digits, a letter that joins nothing, two consonants with no virama) it draws nothing.
static BOOL SZFNonJoinerSeen(UTF32Char before, UTF32Char after) {
    if (SZFriendsIsDualJoining(before) && (SZFriendsIsDualJoining(after) || SZFriendsIsRightJoining(after)))
        return YES;
    UTF32Char low = 0, high = 0;
    return SZFriendsViramaBlock(before, &low, &high) && after >= low && after <= high &&
           SZFriendsIsIndicConsonant(after);
}

// Whether a zero-width joiner between `before` and `after` shapes an Indic conjunct (the rule above): before the
// virama, only when a consonant of its block follows the virama (`afterNext`); at a word's end there is no conjunct.
static BOOL SZFJoinerInConjunct(UTF32Char before, UTF32Char after, UTF32Char afterNext) {
    UTF32Char low = 0, high = 0;
    if (SZFriendsViramaBlock(before, &low, &high))
        return after >= low && after <= high && SZFriendsIsIndicConsonant(after);
    return SZFriendsViramaBlock(after, &low, &high) && before >= low && before <= high &&
           SZFriendsIsIndicConsonant(before) && afterNext >= low && afterNext <= high &&
           SZFriendsIsIndicConsonant(afterNext);
}

typedef struct {
    UTF32Char character;
    NSRange range; // in UTF-16 units
} SZFCodePoint;

static NSArray<NSValue *> *SZFCodePoints(NSString *text) {
    NSMutableArray *points = [NSMutableArray arrayWithCapacity:text.length];
    NSUInteger length = text.length;
    for (NSUInteger index = 0; index < length;) {
        unichar unit = [text characterAtIndex:index];
        SZFCodePoint point = {unit, NSMakeRange(index, 1)};
        if (CFStringIsSurrogateHighCharacter(unit) && index + 1 < length &&
            CFStringIsSurrogateLowCharacter([text characterAtIndex:index + 1])) {
            point.character = CFStringGetLongCharacterForSurrogatePair(unit, [text characterAtIndex:index + 1]);
            point.range.length = 2;
        }
        [points addObject:[NSValue valueWithBytes:&point objCType:@encode(SZFCodePoint)]];
        index = NSMaxRange(point.range);
    }
    return points;
}

static SZFCodePoint SZFPointAt(NSArray<NSValue *> *points, NSInteger index) {
    SZFCodePoint point = {0, NSMakeRange(NSNotFound, 0)};
    if (index >= 0 && index < (NSInteger)points.count) [points[index] getValue:&point];
    return point;
}

// Whether the character at `index` is shown as its code point: it draws nothing, and it is not one of the exceptions
// above.
static BOOL SZFMarked(NSArray<NSValue *> *points, NSInteger index) {
    UTF32Char c = SZFPointAt(points, index).character;
    if (!SZFriendsCharacterDrawsNothing(c)) return NO;
    UTF32Char before = index > 0 ? SZFPointAt(points, index - 1).character : 0;
    UTF32Char after = SZFPointAt(points, index + 1).character;
    if (c == 0xFE0F || c == 0xFE0E) {
        if (SZFIsKeycapBase(before)) return after != 0x20E3;
        return !SZFriendsIsEmojiVariationBase(before);
    }
    if (c == 0x200D) {
        if (SZFJoinerInConjunct(before, after, SZFPointAt(points, index + 2).character)) return NO;
        NSInteger base = index - 1;
        if (base >= 0 && SZFPointAt(points, base).character == 0xFE0F) {
            // A marked selector draws nothing, so the joiner after it joins nothing the person sees.
            if (SZFMarked(points, base)) return YES;
            base--;
        } else if (base >= 0 && SZFIsSkinTone(SZFPointAt(points, base).character)) {
            base--;
        }
        return !(base >= 0 && SZFriendsIsExtendedPictographic(SZFPointAt(points, base).character) &&
                 SZFriendsIsExtendedPictographic(after));
    }
    if (c == 0x200C) return !SZFNonJoinerSeen(before, after);
    return YES;
}

static BOOL SZFIsCombiningMark(UTF32Char c) {
    static NSCharacterSet *marks;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      marks = NSCharacterSet.nonBaseCharacterSet; // Mn, Mc and Me
    });
    return [marks longCharacterIsMember:c];
}

// Whether `mark` is drawn on `letter` as its own: SZFriendsMarkFitsLetter, or a Quranic pause or annotation mark
// (U+06D6-06DC, U+06DF-06E4, U+06E7-06E8, U+06EA-06ED) on a space the send check writes as U+0020.
static BOOL SZFMarkFits(UTF32Char mark, UTF32Char letter) {
    BOOL quranic = (mark >= 0x06D6 && mark <= 0x06DC) || (mark >= 0x06DF && mark <= 0x06E4) || mark == 0x06E7 ||
                   mark == 0x06E8 || (mark >= 0x06EA && mark <= 0x06ED);
    BOOL space = letter == ' ' || letter == 0x00A0 || letter == 0x1680 || (letter >= 0x2000 && letter <= 0x200A) ||
                 letter == 0x202F || letter == 0x205F;
    return (quranic && space) || SZFriendsMarkFitsLetter(mark, letter);
}

// Whether `mark` cannot go on a letter that carries `count` marks `onBase`: it has it already, or has four.
static BOOL SZFStacked(const UTF32Char onBase[4], NSUInteger count, UTF32Char mark) {
    BOOL stacked = count == 4;
    for (NSUInteger seen = 0; seen < count && !stacked; seen++) stacked = onBase[seen] == mark;
    return stacked;
}

// The marks `letter` carries before any follow it, into `onBase`: those of its own canonical decomposition (NFD), as
// the host's send check counts them. The text is composed first, so "e", U+0323, U+0302 arrives as U+1EC7 and "=",
// U+0338 as U+2260; counting only the marks after them let six marks sit on one e, or U+0338 twice on "=" (security
// review, wave 6b). A mark counts as NFC writes it, even one that decomposes into two, as in the send check: Tulu-
// Tigalari U+113C5 is U+113C2 twice, so counting parts would refuse a plain vowel. Nothing below U+00C0 decomposes.
static NSUInteger SZFLetterMarks(UTF32Char letter, UTF32Char onBase[4]) {
    if (letter < 0xC0) return 0;
    UniChar units[2] = {(UniChar)letter, 0};
    BOOL pair = CFStringGetSurrogatePairForLongCharacter(letter, units);
    NSString *parts = [NSString stringWithCharacters:units length:pair ? 2 : 1].decomposedStringWithCanonicalMapping;
    NSArray<NSValue *> *points = SZFCodePoints(parts);
    NSUInteger count = 0;
    for (NSInteger index = 1; index < (NSInteger)points.count; index++) {
        UTF32Char part = SZFPointAt(points, index).character;
        if (SZFIsCombiningMark(part) && !SZFStacked(onBase, count, part)) onBase[count++] = part;
    }
    return count;
}

// For each code point of the composed text, whether it is shown as its code point: SZFMarked, or a combining mark its
// letter already carries (its own decomposition's included), that would be a fifth on it, or that does not fit it.
// Some marks draw the same picture once or sixty-four times (U+065E after a letter, U+0489 after an emoji: security
// review, measured with TextKit), so a repeat count would be hidden, and a pile of more than four cannot be counted.
// A mark of another script can draw nothing at all: U+3099 on a Hangul syllable, a Bassa Vah tone on Cyrillic
// (wave 6c, pixel for pixel), so a mark must fit its letter (SZFMarkFits, Script_Extensions). The letter is the last
// code point shown as itself that is not a mark nor a joiner (U+0000 before the first): a marked character between a
// letter and its marks leaves them counting on that letter, as the host's send check and a draft count them, and the
// virama after a conjunct's joiner (র‍্য) counts on the consonant. One pass, so a hostile run of marks costs one step
// each.
static NSData *SZFMarkedFlags(NSArray<NSValue *> *points) {
    NSMutableData *flags = [NSMutableData dataWithLength:points.count * sizeof(BOOL)];
    BOOL *marked = flags.mutableBytes;
    UTF32Char onBase[4] = {0, 0, 0, 0}, letter = 0;
    NSUInteger count = 0;
    for (NSInteger index = 0; index < (NSInteger)points.count; index++) {
        UTF32Char c = SZFPointAt(points, index).character;
        if (SZFMarked(points, index)) {
            marked[index] = YES;
            continue;
        }
        if (c == 0x200D) continue;
        if (!SZFIsCombiningMark(c)) {
            count = SZFLetterMarks(letter = c, onBase);
            continue;
        }
        if (!SZFMarkFits(c, letter) || SZFStacked(onBase, count, c)) marked[index] = YES;
        else onBase[count++] = c;
    }
    return flags;
}

// What the card shows and Friends delivers: the composed text (the send check composes it), one spelling per letter.
static NSString *SZFComposed(NSString *text) {
    return text.precomposedStringWithCanonicalMapping ?: @"";
}

NSArray<NSNumber *> *SZFriendsLiteralMarkedCodePoints(NSString *text) {
    NSArray<NSValue *> *points = SZFCodePoints(SZFComposed(text));
    NSData *flagData = SZFMarkedFlags(points); // kept alive while `flags` points into it
    const BOOL *flags = flagData.bytes;
    NSMutableArray<NSNumber *> *marked = [NSMutableArray array];
    for (NSInteger index = 0; index < (NSInteger)points.count; index++)
        if (flags[index]) [marked addObject:@(SZFPointAt(points, index).character)];
    return marked;
}

NSAttributedString *SZFriendsLiteralText(NSString *text, NSFont *font, NSColor *color, NSColor *markColor) {
    NSDictionary *plain = @{NSFontAttributeName : font, NSForegroundColorAttributeName : color};
    NSFont *markFont = [NSFont monospacedSystemFontOfSize:MAX(9, font.pointSize - 2) weight:NSFontWeightMedium];
    NSDictionary *mark = @{NSFontAttributeName : markFont, NSForegroundColorAttributeName : markColor,
                           NSBackgroundColorAttributeName : [markColor colorWithAlphaComponent:0.14]};
    NSMutableAttributedString *shown = [[NSMutableAttributedString alloc] init];
    text = SZFComposed(text);
    NSArray<NSValue *> *points = SZFCodePoints(text);
    NSData *flagData = SZFMarkedFlags(points); // kept alive while `flags` points into it
    const BOOL *flags = flagData.bytes;
    NSInteger count = (NSInteger)points.count;
    NSUInteger plainStart = 0;
    for (NSInteger index = 0; index < count;) {
        if (!flags[index]) {
            index++;
            continue;
        }
        NSUInteger start = SZFPointAt(points, index).range.location;
        if (start > plainStart)
            [shown appendAttributedString:[[NSAttributedString alloc]
                                              initWithString:[text substringWithRange:NSMakeRange(plainStart,
                                                                                                  start - plainStart)]
                                                  attributes:plain]];
        // One mark for a run of hidden characters, each code point once with its repeat count: forty zero-width
        // spaces read as "U+200B ×40", not as a wall of marks.
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        while (index < count && flags[index]) {
            UTF32Char c = SZFPointAt(points, index).character;
            NSUInteger repeats = 0;
            while (index < count && flags[index] && SZFPointAt(points, index).character == c) {
                repeats++;
                index++;
            }
            NSString *name = [NSString stringWithFormat:@"U+%04X", (unsigned)c];
            if (repeats > 1) name = [NSString stringWithFormat:@"%@ ×%lu", name, (unsigned long)repeats];
            [names addObject:name];
        }
        NSString *label = [NSString stringWithFormat:@" %@ ", [names componentsJoinedByString:@" "]];
        [shown appendAttributedString:[[NSAttributedString alloc] initWithString:label attributes:mark]];
        plainStart = index < count ? SZFPointAt(points, index).range.location : text.length;
    }
    if (plainStart < text.length)
        [shown appendAttributedString:[[NSAttributedString alloc] initWithString:[text substringFromIndex:plainStart]
                                                                      attributes:plain]];
    return shown;
}
