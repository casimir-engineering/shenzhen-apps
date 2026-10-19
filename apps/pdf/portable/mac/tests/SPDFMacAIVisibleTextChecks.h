// What a person approving a message sees (SPDFMacAIActivityVisibleText): characters that draw nothing become markers,
// unless they change what is drawn. The rule is the send check's (ai-agent-capabilities.md § 1), so besides the cases
// below, every case in friends/fixtures/text/invisible-cases.json runs here as the Friends suites run it. Included by
// SPDFMacAIToolSeamTests.mm.
#pragma once
#import "../friends/SPDFMacFriendsEmojiTables.h"

static BOOL SeamShows(NSString* text, NSString* expected, NSUInteger markers) {
    NSArray<NSValue*>* ranges = nil;
    NSString* shown = SPDFMacAIActivityVisibleText(text, &ranges);
    BOOL placed = YES;
    for (NSValue* range in ranges) placed &= [[shown substringWithRange:range.rangeValue] hasPrefix:@"‹U+"];
    return [shown isEqual:expected] && ranges.count == markers && placed;
}

static NSString* SeamScalar(UTF32Char point) {
    UTF32Char little = OSSwapHostToLittleInt32(point);
    return [[NSString alloc] initWithBytes:&little length:4 encoding:NSUTF32LittleEndianStringEncoding] ?: @"";
}

// Security review, wave 6b: the card composes first, so a precomposed letter's own marks went uncounted (six marks on
// U+1EC7, U+0338 twice on U+2260). A letter carries the marks of its canonical decomposition, so every composed letter
// whose decomposition has marks, followed by one of them again, shows that copy as its code point.
static void CheckPrecomposedLettersOnTheCard(void) {
    NSCharacterSet* marks = NSCharacterSet.nonBaseCharacterSet;
    NSUInteger letters = 0, wrong = 0;
    for (UTF32Char point = 0xC0; point < 0x30000; point++) {
        NSString* letter = SeamScalar(point);
        if (!letter.length || [marks longCharacterIsMember:point] ||
            ![letter.precomposedStringWithCanonicalMapping isEqual:letter])
            continue;
        NSData* utf32 = [letter.decomposedStringWithCanonicalMapping
            dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
        const UTF32Char* parts = (const UTF32Char*)utf32.bytes;
        BOOL counted = NO;
        for (NSUInteger index = 1; index < utf32.length / 4; index++) {
            UTF32Char part = OSSwapLittleToHostInt32(parts[index]);
            if (![marks longCharacterIsMember:part]) continue;
            counted = YES;
            NSString* marker = [NSString stringWithFormat:@"‹U+%04X›", (unsigned)part];
            if (!SeamShows([letter stringByAppendingString:SeamScalar(part)],
                           [letter stringByAppendingString:marker], 1) && wrong++ < 5)
                fprintf(stderr, "  U+%04X followed by its own U+%04X is not marked\n", (unsigned)point, (unsigned)part);
        }
        letters += counted;
    }
    CHECK(letters > 500 && !wrong, "a precomposed letter's own marks count: a copy of one is marked");
    CHECK(SeamShows(@"ệ́̀̃̄", @"ệ́̀‹U+0303›‹U+0304›", 2) &&
          SeamShows(@"ệ́̀̃̄", @"ệ́̀‹U+0303›‹U+0304›", 2) &&
          SeamShows(@"≠̸", @"≠‹U+0338›", 1) && SeamShows(@"≠̸", @"≠‹U+0338›", 1) &&
          SeamShows(@"ǖ́̂̃", @"ǖ́̂‹U+0303›", 1) &&
          SeamShows(@"é​́", @"é‹U+200B›‹U+0301›", 2),
          "a letter's own marks count toward the repeat rule and the four-mark cap, composed or not");
    CHECK(SeamShows(@"ệ́̀", @"ệ́̀", 0) &&
          SeamShows(@"ǖ́̂", @"ǖ́̂", 0) && SeamShows(@"が", @"が", 0) &&
          SeamShows(@"কো", @"কো", 0),
          "four marks counting the letter's own, and a two-part vowel sign as one mark, are shown as written");
}

static void CheckVisibleText(void) {
    unichar lone = 0xD800;
    NSString* bell = [NSString stringWithFormat:@"a%Cb", (unichar)0x07];
    CHECK(SeamShows(@"Plain\ttext\nwith lines", @"Plain\ttext\nwith lines", 0) &&
          SeamShows(@"a​b", @"a‹U+200B›b", 1) && SeamShows(@"x\U000E0041\U000E007F", @"x‹U+E0041›‹U+E007F›", 2) &&
          SeamShows(@"turn‮ed", @"turn‹U+202E›ed", 1) && SeamShows(bell, @"a‹U+0007›b", 1) &&
          SeamShows(@"soft­hyㅤ", @"soft‹U+00AD›hy‹U+3164›", 2) &&
          SeamShows([NSString stringWithCharacters:&lone length:1], @"‹U+D800›", 1),
          "zero-width, tag, direction, control, soft hyphen, filler and lone surrogate characters are marked");
    CHECK(SeamShows(@"👨‍👩‍👧", @"👨‍👩‍👧", 0) && SeamShows(@"a‍b", @"a‹U+200D›b", 1) &&
          SeamShows(@"می‌خواهم", @"می‌خواهم", 0) && SeamShows(@"a‌b", @"a‹U+200C›b", 1),
          "a joiner stays inside an emoji sequence, a non-joiner between joining letters; between Latin letters both "
          "are marked");
    // The old shortcut took U+203C to U+3299 for emoji: a joiner between arrows, and any joiner between letters,
    // passed unmarked.
    CHECK(SeamShows(@"→‍→", @"→‹U+200D›→", 1) && SeamShows(@"\u0915\u200D\u0916", @"\u0915‹U+200D›\u0916", 1) &&
          SeamShows(@"🏽‍💻", @"🏽‹U+200D›💻", 1) && SeamShows(@"👩🏽‍💻", @"👩🏽‍💻", 0) &&
          SeamShows(@"🏳️‍🌈", @"🏳️‍🌈", 0),
          "a joiner counts between Extended_Pictographic characters, past the first one's selector or skin tone");
    // Wave 6e, ordinary text (pixel scans: each joiner below changes the conjunct in AppKit and Pango): a joiner beside
    // a virama in a conjunct of its own block stays, and the virama after it counts on the consonant before it.
    CHECK(SeamShows(@"\u0DC1\u0DCA\u200D\u0DBB\u0DD3", @"\u0DC1\u0DCA\u200D\u0DBB\u0DD3", 0) &&
          SeamShows(@"\u09B0\u200D\u09CD\u09AF", @"\u09B0\u200D\u09CD\u09AF", 0) &&
          SeamShows(@"\u0915\u094D\u200D\u0937", @"\u0915\u094D\u200D\u0937", 0) &&
          SeamShows(@"\u09B0\u200D\u09CD\u09CD", @"\u09B0‹U+200D›\u09CD‹U+09CD›", 2) &&
          SeamShows(@"\u0915\u094D\u200D\u0995", @"\u0915\u094D‹U+200D›\u0995", 1) &&
          SeamShows(@"\u0DC1\u0DCA\u200D\u200D\u0DBB", @"\u0DC1\u0DCA‹U+200D›‹U+200D›\u0DBB", 2) &&
          SeamShows(@"\u0915\u200D\u094D \u0916", @"\u0915‹U+200D›\u094D \u0916", 1),
          "a joiner in a Sinhala, Bengali or Devanagari conjunct stays; beside another script, twice, or before a "
          "virama with no consonant after it (a word's end) it is marked");
    // Wave 6e: Quran text writes pause marks as words of their own, after a space, where they draw.
    CHECK(SeamShows(@"\u0631\u064E\u064A\u0652\u0628\u064E \u06DB \u0641\u0650\u064A\u0647\u0650\u00A0\u06D6",
                    @"\u0631\u064E\u064A\u0652\u0628\u064E \u06DB \u0641\u0650\u064A\u0647\u0650\u00A0\u06D6", 0) &&
          SeamShows(@"\u0628 \u06DB\u06DB", @"\u0628 \u06DB‹U+06DB›", 1) && SeamShows(@"a\u06DB", @"a‹U+06DB›", 1) &&
          SeamShows(@"\u0628 \u064E", @"\u0628 ‹U+064E›", 1),
          "a Quranic pause mark after a space stays, once; on a Latin letter, or a vowel after a space, is marked");
    CHECK(SeamShows(@"❤️", @"❤️", 0) && SeamShows(@"1️⃣", @"1️⃣", 0) &&
          SeamShows(@"#︎⃣", @"#︎⃣", 0) && SeamShows(@"©︎", @"©︎", 0) &&
          SeamShows(@"a️b", @"a‹U+FE0F›b", 1) && SeamShows(@"❤️️", @"❤️‹U+FE0F›", 1) &&
          SeamShows(@"️⃣", @"‹U+FE0F›⃣", 1) && SeamShows(@"a︁b", @"a‹U+FE01›b", 1) &&
          SeamShows(@"中\U000E0100", @"中‹U+E0100›", 1),
          "one presentation selector after a variation base or in a keycap stays; any other variation selector is "
          "marked");
    // The security review's measured cases: each drew pixel for pixel like the text without its selector.
    CHECK(SeamShows(@"あ️", @"あ‹U+FE0F›", 1) && SeamShows(@"→︎", @"→‹U+FE0E›", 1) &&
          SeamShows(@"。️", @"。‹U+FE0F›", 1) && SeamShows(@"∑︎", @"∑‹U+FE0E›", 1) &&
          SeamShows(@"1︎", @"1‹U+FE0E›", 1) && SeamShows(@"↔️", @"↔️", 0),
          "a selector after kana, CJK punctuation, an arrow or operator without a sequence, or a bare digit is marked");
    // E1 decisions, so this card marks what the Friends views' literal text marks.
    CHECK(SeamShows(@"a⠀b", @"a‹U+2800›b", 1) && SeamShows(@"a\U00013430b", @"a‹U+13430›b", 1) &&
          SeamShows(@"ab", @"a‹U+F850›b", 1) && SeamShows(@"\U000F0000\U0010FFFD",
                                                                    @"‹U+E000›‹U+F0000›‹U+10FFFD›", 3),
          "the braille blank, Egyptian format controls and private-use characters are marked");
    CHECK(SeamShows(@"\U0001F469️‍\U0001F4BB", @"\U0001F469‹U+FE0F›‹U+200D›\U0001F4BB", 2) &&
          SeamShows(@"\U0001F3F3️‍\U0001F308", @"\U0001F3F3️‍\U0001F308", 0),
          "a joiner after a stray selector is marked with it; after a valid one it stays");
    CHECK(SeamShows(@"Café", @"Café", 0) && SeamShows(@"Å", @"Å", 0) &&
          SeamShows(@"é​!", @"é‹U+200B›!", 1),
          "the card shows the text composed (NFC), as the send side composes it, and marks within that");
    // Security review, wave 6a: U+065E drew the same once or twice, so the repeat count was hidden; U+0000 slipped
    // through the send check. A mark a letter already carries, a fifth mark, and U+0000 are marked.
    CHECK(SeamShows(@"\u0628\u065E\u065E", @"\u0628\u065E‹U+065E›", 1) &&
          SeamShows(@"x\u0301\u0302\u0303\u0304\u0306", @"x\u0301\u0302\u0303\u0304‹U+0306›", 1) &&
          SeamShows(@"\u0628\u065E\u200B\u065E", @"\u0628\u065E‹U+200B›‹U+065E›", 2) &&
          SeamShows(@"\u0628\u065E\u062A\u065E 1\uFE0F\u20E3", @"\u0628\u065E\u062A\u065E 1\uFE0F\u20E3", 0) &&
          SeamShows(@"a\u0000b", @"a‹U+0000›b", 1),
          "a repeated mark, a fifth mark on one letter and U+0000 are marked; one mark per letter is not");
    // Security review, wave 6c: U+3099 on a Hangul syllable and a Bassa Vah tone on Cyrillic drew nothing at all. A
    // mark of another script than its letter's is marked; a mark of no script (U+20D2) fits any letter.
    CHECK(SeamShows(@"\uAC00\u3099", @"\uAC00‹U+3099›", 1) && SeamShows(@"\u0416\U00016AF0", @"\u0416‹U+16AF0›", 1) &&
          SeamShows(@"a\u20D2\u3099", @"a\u20D2‹U+3099›", 1) && SeamShows(@"\u304B\u309A", @"\u304B\u309A", 0) &&
          SeamShows(@"\u0640\u064E \u0915\u093F", @"\u0640\u064E \u0915\u093F", 0),
          "marks of another script are marked; kana, Arabic and Devanagari marks on their own letters are not");
    CheckPrecomposedLettersOnTheCard();
}

template <size_t count>
static BOOL SeamTableOrdered(const SPDFMacFriendsCodePointRange (&table)[count]) {
    for (size_t index = 0; index < count; index++)
        if (table[index].low > table[index].high || (index && table[index].low <= table[index - 1].high)) return NO;
    return count > 0;
}

// Every implementation runs every shared case; the Friends views and the send check read the same file.
static void CheckSharedInvisibleCases(void) {
    // Beside this header in the tree: mac/tests/ → friends/fixtures/text/.
    NSString* here = [@(__FILE__) stringByDeletingLastPathComponent];
    NSString* path = [here stringByAppendingPathComponent:@"../../friends/fixtures/text/invisible-cases.json"];
    NSData* data = [NSData dataWithContentsOfFile:path];
    NSDictionary* file = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray* cases = [file isKindOfClass:NSDictionary.class] ? file[@"cases"] : nil;
    CHECK([cases isKindOfClass:NSArray.class] && cases.count >= 20, "the shared invisible-character cases are read");
    NSUInteger agreed = 0;
    for (NSDictionary* item in [cases isKindOfClass:NSArray.class] ? cases : @[]) {
        NSString* text = item[@"text"];
        NSArray* expected = item[@"marked"];
        if (![text isKindOfClass:NSString.class] || ![expected isKindOfClass:NSArray.class]) continue;
        NSArray<NSValue*>* ranges = nil;
        NSString* shown = SPDFMacAIActivityVisibleText(text, &ranges);
        NSMutableArray* marked = [NSMutableArray array];
        for (NSValue* range in ranges) {
            NSString* marker = [shown substringWithRange:range.rangeValue];  // "‹U+FE0F›"
            [marked addObject:[marker substringWithRange:NSMakeRange(1, marker.length - 2)]];
        }
        // An accepted message must never show a marker on its card.
        BOOL consistent = !expected.count || [item[@"refused_before_card"] isEqual:@YES];
        if ([marked isEqual:expected] && consistent) agreed++;
        else fprintf(stderr, "  case \"%s\": marked %s, expected %s\n", [item[@"name"] description].UTF8String,
                     [marked componentsJoinedByString:@" "].UTF8String,
                     [expected componentsJoinedByString:@" "].UTF8String);
    }
    CHECK(cases.count && agreed == cases.count, "the card marks exactly what each shared case expects");
    CHECK(SeamTableOrdered(kSPDFMacFriendsEmojiVariationBases) && SeamTableOrdered(kSPDFMacFriendsExtendedPictographic),
          "the generated tables are sorted and disjoint, as their binary search needs");
    BOOL scriptsOrdered = kSPDFMacFriendsScripts[0].first == 0;
    for (size_t index = 1; index < sizeof kSPDFMacFriendsScripts / sizeof kSPDFMacFriendsScripts[0]; index++)
        scriptsOrdered &= kSPDFMacFriendsScripts[index].first > kSPDFMacFriendsScripts[index - 1].first;
    for (size_t index = 1; index < sizeof kSPDFMacFriendsScriptExtensions / sizeof kSPDFMacFriendsScriptExtensions[0];
         index++)
        scriptsOrdered &= kSPDFMacFriendsScriptExtensions[index].low > kSPDFMacFriendsScriptExtensions[index - 1].high;
    CHECK(scriptsOrdered, "the script starts and extensions are in order, from U+0000, as their searches need");
}
