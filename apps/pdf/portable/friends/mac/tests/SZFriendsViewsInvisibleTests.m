// Shenzhen Friends views tests: characters that draw nothing, against the shared cases in
// friends/fixtures/text/invisible-cases.json. The host's send check and its card run the same file with their own code
// (one rule, two implementations), so a case either side gets wrong fails there or here.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsComposerInternal.h"

static NSString *SZFCodePointName(NSNumber *point) {
    return [NSString stringWithFormat:@"U+%04X", point.unsignedIntValue];
}

// The data the rule reads is Unicode's, with its version, not a guessed range of "emoji".
static void SZFTestEmojiTables(void) {
    SZFExpect(SZFriendsEmojiTablesUnicodeVersion.length > 0, @"the tables name their Unicode version");
    for (NSNumber *base in @[ @0x2764, @0x2194, @0x0031, @0x0023, @0x1F3F3, @0x3030 ])
        SZFExpect(SZFriendsIsEmojiVariationBase(base.unsignedIntValue), @"U+%04X takes a selector",
                  base.unsignedIntValue);
    for (NSNumber *other in @[ @0x3042, @0x3002, @0x2192, @0x2211, @0x1F600, @'a' ])
        SZFExpect(!SZFriendsIsEmojiVariationBase(other.unsignedIntValue), @"U+%04X takes none", other.unsignedIntValue);
    for (NSNumber *pictograph in @[ @0x1F468, @0x1F308, @0x2764, @0x00A9 ])
        SZFExpect(SZFriendsIsExtendedPictographic(pictograph.unsignedIntValue), @"U+%04X is a pictograph",
                  pictograph.unsignedIntValue);
    for (NSNumber *other in @[ @0x3042, @0x1F3FB, @'1', @0x20E3 ])
        SZFExpect(!SZFriendsIsExtendedPictographic(other.unsignedIntValue), @"U+%04X is not a pictograph",
                  other.unsignedIntValue);
    // One Unicode version with the host's send check and its tables, so both read the same rule.
    SZFExpect([SZFriendsEmojiTablesUnicodeVersion isEqualToString:@"18.0"], @"Unicode %@",
              SZFriendsEmojiTablesUnicodeVersion);
    // Joining data: beh and Persian yeh join both ways, alef and dal only back, digits and Latin not at all.
    SZFExpect(SZFriendsIsDualJoining(0x0628) && SZFriendsIsDualJoining(0x06CC) && SZFriendsIsDualJoining(0x0712) &&
                  !SZFriendsIsDualJoining(0x0627) && !SZFriendsIsDualJoining(0x0661) && !SZFriendsIsDualJoining('a'),
              @"dual-joining letters");
    SZFExpect(SZFriendsIsRightJoining(0x0627) && SZFriendsIsRightJoining(0x062F) && !SZFriendsIsRightJoining(0x0628) &&
                  !SZFriendsIsRightJoining(0x0661),
              @"right-joining letters");
    UTF32Char low = 0, high = 0;
    SZFExpect(SZFriendsViramaBlock(0x094D, &low, &high) && low == 0x0900 && high == 0x097F &&
                  SZFriendsViramaBlock(0x0DCA, &low, &high) && low == 0x0D80 && high == 0x0DFF &&
                  !SZFriendsViramaBlock(0x0915, &low, &high) && !SZFriendsViramaBlock(0x200C, &low, &high),
              @"viramas and their blocks");
    SZFExpect(SZFriendsIsIndicConsonant(0x0915) && SZFriendsIsIndicConsonant(0x0937) &&
                  !SZFriendsIsIndicConsonant(0x0905) && !SZFriendsIsIndicConsonant(0x094D) &&
                  !SZFriendsIsIndicConsonant(0x0966),
              @"consonants, not vowels, viramas or digits");
    // Private-use characters are marked: the send check refuses them, and many draw nothing.
    for (NSNumber *point in @[ @0xE000, @0xF850, @0xF8FF, @0xF0000, @0x10FFFD ])
        SZFExpect(SZFriendsCharacterDrawsNothing(point.unsignedIntValue), @"U+%04X is marked", point.unsignedIntValue);
}

static void SZFTestSharedCases(void) {
    NSString *path = [SZFTestFixturesDir stringByAppendingPathComponent:@"text/invisible-cases.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *file = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *cases = [file isKindOfClass:NSDictionary.class] ? file[@"cases"] : nil;
    SZFExpect(cases.count >= 20, @"the shared cases load from %@: %lu", path, (unsigned long)cases.count);
    SZFriendsAppearance *appearance = [SZFriendsAppearance new];
    NSUInteger refused = 0, accepted = 0;
    for (NSDictionary *entry in cases) {
        NSString *name = entry[@"name"], *text = entry[@"text"];
        NSArray<NSString *> *expected = entry[@"marked"];
        BOOL refusedBeforeCard = [entry[@"refused_before_card"] boolValue];
        if (![text isKindOfClass:NSString.class] || ![expected isKindOfClass:NSArray.class]) {
            SZFExpect(NO, @"case %@ has text and marked", name);
            continue;
        }
        refusedBeforeCard ? refused++ : accepted++;
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSNumber *point in SZFriendsLiteralMarkedCodePoints(text)) [names addObject:SZFCodePointName(point)];
        SZFExpect([names isEqualToArray:expected], @"%@: marks %@, expected %@", name, names, expected);
        // Whatever a card would mark must never reach a card: the send check refuses it first.
        SZFExpect(refusedBeforeCard || expected.count == 0, @"%@: marked yet accepted", name);
        NSString *shown =
            SZFriendsLiteralText(text, appearance.bodyFont, NSColor.textColor, NSColor.orangeColor).string;
        if (!expected.count) {
            SZFExpect([shown isEqualToString:text.precomposedStringWithCanonicalMapping],
                      @"%@: shown exactly as written, composed", name);
        } else {
            for (NSString *mark in expected)
                SZFExpect([shown containsString:mark], @"%@: %@ shows on the card: %@", name, mark, shown);
        }
    }
    SZFExpect(refused > 0 && accepted > 0, @"the cases cover both outcomes: %lu refused, %lu accepted",
              (unsigned long)refused, (unsigned long)accepted);
}

// The card shows the text composed (NFC), as the send check composes what Friends delivers: one spelling per letter,
// and the marks counted in the order NFC puts them, a letter carrying those of its own decomposition.
static void SZFTestComposedFirst(void) {
    SZFriendsAppearance *appearance = [SZFriendsAppearance new];
    NSString *shown = SZFriendsLiteralText(@"Cafe\u0301", appearance.bodyFont, NSColor.textColor,
                                           NSColor.orangeColor).string;
    SZFExpect([shown isEqualToString:@"Caf\u00E9"], @"e and U+0301 show as the one letter é: %@", shown);
    NSDictionary<NSString *, NSArray<NSString *> *> *cases = @{
        // NFC moves U+0323 (below) before the marks above, so the fifth is U+0304.
        @"x\u0301\u0302\u0303\u0304\u0323" : @[ @"U+0304" ],
        // Typed apart, six marks on one e: composed, U+1EC7 carries two of them, and the last two are too many.
        @"e\u0302\u0323\u0301\u0300\u0303\u0304" : @[ @"U+0303", @"U+0304" ],
        // "=" with U+0338 twice: composed, U+2260 already carries one.
        @"=\u0338\u0338" : @[ @"U+0338" ],
        // Bengali o (U+09CB) is one mark as NFC writes it, though it decomposes into U+09C7 and U+09BE.
        @"\u0995\u09CB\u09C7" : @[],
    };
    for (NSString *text in cases) {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSNumber *point in SZFriendsLiteralMarkedCodePoints(text)) [names addObject:SZFCodePointName(point)];
        SZFExpect([names isEqualToArray:cases[text]], @"%@: marks %@, expected %@", text, names, cases[text]);
    }
}

void SZFTestInvisibleCharacters(void) {
    SZFTestEmojiTables();
    SZFTestSharedCases();
    SZFTestComposedFirst();
}
