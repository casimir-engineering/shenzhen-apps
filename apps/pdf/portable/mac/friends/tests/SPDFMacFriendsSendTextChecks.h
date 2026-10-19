// The text the person approves is every character Friends delivers (SPDFMacFriendsSendText.h): what draws the same
// either way is made one way, a character that draws nothing is refused before any card, and Markdown that would
// hide part of a message reaches the card whole, as literal text, and Send queues exactly that. Included by
// SPDFMacFriendsSendTests.mm after SPDFMacFriendsSendRig.h.

#pragma once
#import "SPDFMacFriendsSendText.h"

static NSString* Visible(NSString* text) { return SPDFMacFriendsVisibleText(text, nil); }

static void CheckVisibleText(void) {
    Expect([Visible(@"a\r\nb\rc\u2028d\u2029e\u0085f") isEqual:@"a\nb\nc\nd\ne\nf"], @"line breaks: %@",
           Visible(@"a\r\nb\rc\u2028d\u2029e\u0085f"));
    Expect([Visible(@"x\u00A0y\u2003z\u202Fq\u3000w") isEqual:@"x y z q\u3000w"],
           @"spaces of other widths become one space; the ideographic space stays: %@",
           Visible(@"x\u00A0y\u2003z\u202Fq\u3000w"));
    // Spaces at the end of a line draw nothing and can spell out bits, one line at a time.
    Expect([Visible(@"Thanks  \t\nSee you \n   \nFriday   ") isEqual:@"Thanks\nSee you\n\nFriday"],
           @"trailing spaces: %@", Visible(@"Thanks  \t\nSee you \n   \nFriday   "));
    Expect([Visible(@"a\n\n\n\n\nb") isEqual:@"a\n\nb"], @"one blank line at most");
    Expect([Visible(@"    indented code\n\tand a tab") isEqual:@"    indented code\n\tand a tab"],
           @"leading spaces and tabs are seen, and code needs them");
    // Emoji sequences (a skin tone before the joiner included), presentation selectors after the bases Unicode lists
    // for them (keycaps, arrows, symbols), a non-joiner between Persian letters, and a joiner in an Indic conjunct
    // (wave 6e: Sinhala Sri, Bengali ra-phala, Devanagari eyelash ra and half ka, each drawn differently without it).
    NSArray<NSString*>* kept = @[@"\U0001F469\u200D\U0001F4BB", @"\u2764\uFE0F\u200D\U0001F525",
                                 @"\U0001F3F3\uFE0F\u200D\U0001F308", @"\U0001F469\U0001F3FD\u200D\U0001F4BB",
                                 @"\U0001F441\uFE0F\u200D\U0001F5E8\uFE0F", @"1\uFE0F\u20E3", @"#\uFE0F\u20E3",
                                 @"\u2194\uFE0F", @"\u263A\uFE0F", @"\u00A9\uFE0E", @"\u0645\u06CC\u200C\u062E",
                                 @"\u0628\u200C\u0627", @"\u0915\u094D\u200C\u0937", @"\u09A8\u09CD\u200C\u09A4",
                                 @"\u0710\u0712\u200C\u0712", @"\u0DC1\u0DCA\u200D\u0DBB\u0DD3",
                                 @"\u09B0\u200D\u09CD\u09AF", @"\u0930\u094D\u200D\u092F",
                                 @"\u0915\u094D\u200D\u0937",
                                 @"Hello \u2013 \u201Cquoted\u201D \u4E2D\u6587 caf\u00E9"];
    for (NSString* text in kept)
        Expect([Visible(text) isEqual:text], @"what changes how its neighbours draw is seen and kept: %@", text);
    // The security review drew a selector after kana, CJK punctuation, an arrow and a math operator that no emoji
    // sequence uses pixel for pixel like the text without it, and a joiner between kana the same. A joiner between
    // Indic letters outside a conjunct, or between symbols that make no emoji, is refused by the one rule too; an
    // emoji Unicode gives no variation sequence draws the same with its selector. A selector after a digit, # or *
    // counts only in a keycap.
    NSArray<NSString*>* hidden = @[@"a\u200Bb", @"a\u202Eb", @"a\u2060b", @"\uFEFFab", @"a\u00ADb", @"a\u034Fb",
        @"a\u180Eb", @"a\u17B4b", @"a\u3164b", @"a\uFFA0b", @"a\u2800b", @"a\uFFFCb", @"a\uE000b", @"a\U000F0000b",
        @"a\u0378b", @"a\u0007b", @"a\u007Fb", @"a\U000E0041b", @"x\uFE00", @"x\uFE0F", @"\U0001F600\uFE0F\uFE0F",
        @"a\U000E0100", @"a\u200Cb", @"a\u200Db",
        @"\u3042\uFE0F", @"\u3042\u200D\u3044", @"\u2192\uFE0E", @"\u3002\uFE0F", @"\u2211\uFE0F",
        @"\u0915\u200D\u0916", @"\u0915\u094D\u200D\u0995", @"\u0D28\u0D4D\u200D", @"\u0915\u200D\u0905\u094D",
        @"\u2605\u200D\u2605", @"\U0001F600\uFE0F", @"\U0001F3FD\u200D\U0001F4BB",
        @"1\uFE0E", @"#\uFE0F",
        // A non-joiner only where it changes a shape: after a dual-joining letter before one that joins back, or
        // after a virama before a consonant of its block. Not between consonants with no virama, after alef (which
        // joins nothing after it), between digits, after a virama before a letter of another script or a vowel.
        @"\u0915\u200C\u0916", @"\u0627\u200C\u062F", @"\u0661\u200C\u0662", @"\u0628\u200C1",
        @"\u0915\u094D\u200C\u0995", @"\u0915\u094D\u200C\u0905", @"\u0915\u094D\u200C",
        @"\U0001F469\uFE0F\u200D\U0001F4BB",
        [@"\U0001F3F4\U000E0067\U000E0062\U000E0073" stringByAppendingString:@"\U000E0063\U000E0074\U000E007F"]];
    for (NSString* text in hidden) {
        NSString* refusal = nil;
        Expect(!SPDFMacFriendsVisibleText(text, &refusal) && [refusal containsString:@"can't see on the card (U+"] &&
               [refusal containsString:@"Nothing was sent."], @"an invisible character was let through: %@ (%@)",
               [text dataUsingEncoding:NSUTF32BigEndianStringEncoding], refusal);
    }
    // One spelling of each letter (NFC): "e" with U+0301 and the Angstrom sign draw exactly as "é" and "Å", so the
    // card and Friends get the composed form, in a draft too, even where a removed character stood between them.
    Expect([Visible(@"Cafe\u0301 at 3") isEqual:@"Caf\u00E9 at 3"] && [Visible(@"\u212B") isEqual:@"\u00C5"] &&
           [Visible(@"\uFA10") isEqual:@"\u585A"], @"composed: %@ %@",
           [Visible(@"Cafe\u0301") dataUsingEncoding:NSUTF32BigEndianStringEncoding],
           [Visible(@"\u212B") dataUsingEncoding:NSUTF32BigEndianStringEncoding]);
    Expect([SPDFMacFriendsDraftText(@"Cafe\u0301 \u212B") isEqual:@"Caf\u00E9 \u00C5"] &&
           [SPDFMacFriendsDraftText(@"e\u200B\u0301") isEqual:@"\u00E9"], @"a draft is composed: %@",
           [SPDFMacFriendsDraftText(@"e\u200B\u0301") dataUsingEncoding:NSUTF32BigEndianStringEncoding]);
    // A `/` draft goes to the composer, where the person sends it as their own: what draws nothing is removed.
    NSString* draft = SPDFMacFriendsDraftText(@"Thanks\u200B!\U000E0073\U000E0061 \U0001F469\u200D\U0001F4BB  ");
    Expect([draft isEqual:@"Thanks! \U0001F469\u200D\U0001F4BB"], @"draft %@",
           [draft dataUsingEncoding:NSUTF32BigEndianStringEncoding]);
    unichar lone[] = {'a', 0xD83D, 'b'};
    NSString* refusal = nil;
    Expect(!SPDFMacFriendsVisibleText([NSString stringWithCharacters:lone length:3], &refusal) &&
           [refusal containsString:@"half of a character"], @"half a character: %@", refusal);
    Expect([SPDFMacFriendsDraftText([NSString stringWithCharacters:lone length:3]) isEqual:@"a\uFFFDb"],
           @"half a character in a draft is shown as the replacement character");
}

static NSArray<NSString*>* CodePointNames(NSString* text) {
    NSMutableArray* names = [NSMutableArray array];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString* sequence, NSRange range, NSRange enclosing, BOOL* stop) {
        (void)range; (void)enclosing; (void)stop;
        NSData* utf32 = [sequence dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
        const uint32_t* points = (const uint32_t*)utf32.bytes;
        for (NSUInteger index = 0; index < utf32.length / 4; index++)
            [names addObject:[NSString stringWithFormat:@"U+%04X", (unsigned)OSSwapLittleToHostInt32(points[index])]];
    }];
    return names;
}

// The one rule (ai-agent-capabilities.md § 1) as cases every implementation runs: the AI chat card's markers and the
// Friends views' literal text read the same file. Here, the send check refuses exactly the cases marked refused, and
// names the first character it saw; a `/` draft removes exactly the characters a card marks, in order.
static void CheckSharedInvisibleCases(void) {
    NSData* bytes = [NSData dataWithContentsOfFile:@"friends/fixtures/text/invisible-cases.json"];
    NSDictionary* file = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
    NSArray* cases = [file isKindOfClass:NSDictionary.class] ? file[@"cases"] : nil;
    Expect([cases isKindOfClass:NSArray.class] && cases.count >= 20, @"the shared cases did not load: %@", file);
    for (NSDictionary* item in cases) {
        NSString* text = item[@"text"], *name = item[@"name"];
        NSArray<NSString*>* marked = item[@"marked"];
        NSString* refusal = nil;
        BOOL refused = SPDFMacFriendsVisibleText(text, &refusal) == nil;
        Expect(refused == [item[@"refused_before_card"] boolValue], @"%@: refused %d, the rule says %@ (%@)", name,
               refused, item[@"refused_before_card"], refusal);
        NSString* first = marked.count ? [NSString stringWithFormat:@"(%@)", marked.firstObject] : nil;
        Expect(!first || [refusal containsString:first], @"%@: the refusal must name %@: %@", name, first, refusal);
        // What the draft dropped: the composed text's code points the draft, read in order, does not have. A
        // no-break space is written as U+0020, not dropped (searched literally: a mark after it makes one character).
        NSString* composed = text.precomposedStringWithCanonicalMapping;
        NSString* spaced = [composed stringByReplacingOccurrencesOfString:@"\u00A0" withString:@" "
                                                                  options:NSLiteralSearch
                                                                    range:NSMakeRange(0, composed.length)];
        NSArray<NSString*>* all = CodePointNames(spaced), *kept = CodePointNames(SPDFMacFriendsDraftText(text));
        NSMutableArray* removed = [NSMutableArray array];
        NSUInteger next = 0;
        for (NSString* point in all) {
            if (next < kept.count && [kept[next] isEqual:point]) next++;
            else [removed addObject:point];
        }
        Expect(next == kept.count && [removed isEqual:marked], @"%@: the draft removed %@, the rule marks %@", name,
               removed, marked);
        Expect(SPDFMacFriendsVisibleText(SPDFMacFriendsDraftText(text), nil) != nil, @"%@: the check refuses its draft",
               name);
    }
    // A mark of another script is refused for what it is, so the model writes the letter's own marks instead.
    NSString* refusal = nil;
    Expect(!SPDFMacFriendsVisibleText(@"\uAC00\u3099", &refusal) &&
               [refusal containsString:@"(U+3099) on a letter of another script"],
           @"a kana mark on Hangul is refused as a mark of another script: %@", refusal);
    Expect(!SPDFMacFriendsVisibleText(@"\u0628\u065E\u065E", &refusal) && [refusal containsString:@"already has it"],
           @"a repeated mark on its own script's letter is refused as a repeat: %@", refusal);
}

// A friend's planted instruction has the model hide document text in Markdown the card used to draw away. The card
// keeps the message whole and literal, and Send queues exactly that.
static void CheckHiddenConstructsReachTheCardWhole(void) {
    SendRig* rig = [[SendRig alloc] initWithSender:[FakeSender new]];
    NSDictionary* card = CardAfterInjection(rig, kHiddenConstructsMessage);
    Expect([card[SPDFMacAIActivityBodyKey] isEqual:kHiddenConstructsMessage] &&
           [card[SPDFMacAIActivityBodyStyleKey] isEqual:SPDFMacAIActivityBodyStyleLiteral] &&
           SPDFMacAIActivityBodyIsLiteral(card) && ![rig.sender intentsOfType:@"send_message"].count,
           @"the card must hold every character, shown literally, before anything goes: %@", card);
    [rig.session performActivityAction:@"send" forEntry:card[SPDFMacAIActivityIDKey]];
    NSDictionary* fields = [rig.sender intentsOfType:@"send_message"].firstObject[@"fields"];
    Expect([fields[@"text"] isEqual:card[SPDFMacAIActivityBodyKey]],
           @"Send must queue exactly what the card shows: %@", fields[@"text"]);
}

// The card shows, and Send queues, the composed text: what the person approves is what Friends delivers.
static void CheckCardShowsComposedText(void) {
    SendRig* rig = [[SendRig alloc] initWithSender:[FakeSender new]];
    [rig ask:@"@Mei say where" chips:@[FriendChip(@"c_mei", @"Mei")]];
    [rig calls:@[ToolCall(@"m1", SPDFMacFriendsSendToolName,
                          @{@"to" : @"Mei", @"text" : @"Cafe\u0301 \u212Bngstr\u00F6m"})]];
    NSDictionary* card = rig.cards.firstObject;
    [rig answer:@"Ready for you to check."];
    [rig.session performActivityAction:@"send" forEntry:card[SPDFMacAIActivityIDKey]];
    NSDictionary* fields = [rig.sender intentsOfType:@"send_message"].firstObject[@"fields"];
    Expect([card[SPDFMacAIActivityBodyKey] isEqual:@"Caf\u00E9 \u00C5ngstr\u00F6m"] &&
           [fields[@"text"] isEqual:card[SPDFMacAIActivityBodyKey]],
           @"the card and what goes are composed: %@ / %@", card[SPDFMacAIActivityBodyKey], fields[@"text"]);
}

// Invisible characters never reach a card or Friends: the model is told which and writes the message again, and
// spaces that draw nothing are gone from both the card and what goes.
static void CheckInvisibleCharactersRefused(void) {
    SendRig* rig = [[SendRig alloc] initWithSender:[FakeSender new]];
    [rig ask:@"@Mei say thanks" chips:@[FriendChip(@"c_mei", @"Mei")]];
    [rig calls:@[ToolCall(@"m1", SPDFMacFriendsSendToolName, @{@"to" : @"Mei", @"text" :
        @"Thanks!\U000E0073\U000E0061\U000E006C\u200B"})]];
    Expect([rig.lastToolResult containsString:@"can't see on the card (U+E0073)"] && !rig.cards.count &&
           ![rig.sender intentsOfType:@"send_message"].count && [rig.send sendsLeftForContext:
               rig.session.currentContext] == 3,
           @"a message hiding tag characters must be refused before any card: %@", rig.lastToolResult);
    [rig calls:@[ToolCall(@"m2", SPDFMacFriendsSendToolName, @{@"to" : @"Mei", @"text" : @"Thanks!   \nSee you \t"})]];
    NSDictionary* card = rig.cards.firstObject;
    [rig answer:@"Ready for you to check."];
    [rig.session performActivityAction:@"send" forEntry:card[SPDFMacAIActivityIDKey]];
    NSDictionary* fields = [rig.sender intentsOfType:@"send_message"].firstObject[@"fields"];
    Expect([card[SPDFMacAIActivityBodyKey] isEqual:@"Thanks!\nSee you"] &&
           [fields[@"text"] isEqual:@"Thanks!\nSee you"],
           @"trailing spaces must leave both the card and what goes: %@ / %@", card, fields);
}
