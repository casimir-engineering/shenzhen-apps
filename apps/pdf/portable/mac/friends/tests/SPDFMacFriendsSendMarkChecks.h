// What the card shows is what goes, for the cases the security review found by drawing text (wave 6a): combining
// marks that draw the same picture once or many times, compatibility spellings that draw exactly like their letters,
// and U+0000, which the send check took for "nothing found". The pixel checks lay text out with TextKit the way
// SPDFChatLiteralTextView does (the system font, 13 pt on the card, 20 pt as a second size), offscreen, so they
// adapt to the fonts of the Mac that runs them. Included by SPDFMacFriendsSendTests.mm after
// SPDFMacFriendsSendTextChecks.h.

#pragma once
#include <vector>
#import <AppKit/AppKit.h>
#import "SPDFMacFriendsSendText.h"
#import "SPDFMacAIChatActivity.h"

// `text` drawn black on white in the system font at `size`, as RGBA bytes; two texts that compare equal draw the
// same picture.
static NSData* DrawnText(NSString* text, CGFloat size) {
    NSTextStorage* storage = [[NSTextStorage alloc] initWithString:text attributes:@{
        NSFontAttributeName : [NSFont systemFontOfSize:size], NSForegroundColorAttributeName : NSColor.blackColor}];
    NSLayoutManager* layout = [NSLayoutManager new];
    NSTextContainer* container = [[NSTextContainer alloc] initWithSize:NSMakeSize(300, 200)];
    container.lineFragmentPadding = 0;
    [layout addTextContainer:container];
    [storage addLayoutManager:layout];
    const NSInteger width = 300, height = 100;
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width
        pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:width * 4 bitsPerPixel:32];
    NSGraphicsContext* context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = context;
    [NSColor.whiteColor setFill];
    NSRectFill(NSMakeRect(0, 0, width, height));
    // Room around the text: marks above, below and beside their letter stay inside the picture.
    [layout drawGlyphsForGlyphRange:[layout glyphRangeForTextContainer:container] atPoint:NSMakePoint(20, 20)];
    [context flushGraphics];
    [NSGraphicsContext restoreGraphicsState];
    return [NSData dataWithBytes:bitmap.bitmapData length:(NSUInteger)(width * height * 4)];
}

static BOOL DrawsAlike(NSString* one, NSString* other) {
    return [DrawnText(one, 13) isEqual:DrawnText(other, 13)] && [DrawnText(one, 20) isEqual:DrawnText(other, 20)];
}

static NSString* Scalar(UTF32Char point) {
    UTF32Char little = OSSwapHostToLittleInt32(point);
    return [[NSString alloc] initWithBytes:&little length:4 encoding:NSUTF32LittleEndianStringEncoding] ?: @"";
}

static NSUInteger CardMarkers(NSString* text) {
    NSArray<NSValue*>* markers = nil;
    SPDFMacAIActivityVisibleText(text, &markers);
    return markers.count;
}

// The code points of `text`, in order.
static std::vector<UTF32Char> MarkCheckPoints(NSString* text) {
    NSData* utf32 = [text dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const UTF32Char* points = (const UTF32Char*)utf32.bytes;
    std::vector<UTF32Char> out;
    for (NSUInteger index = 0; index < utf32.length / 4; index++) out.push_back(OSSwapLittleToHostInt32(points[index]));
    return out;
}

// A precomposed letter already carries the marks of its canonical decomposition (NFD): ệ is e with U+0323 and U+0302,
// ≠ is = with U+0338. Composing folds typed marks into their letter, so counting only the marks left after it let six
// marks sit on one e, or U+0338 twice on =, past the repeat rule and the cap (security review, wave 6b). So every
// composed letter whose decomposition carries marks, followed by one of them again, is refused naming it; the card
// marks it and a draft drops it.
static void CheckPrecomposedLettersCarryTheirMarks(void) {
    NSCharacterSet* marks = NSCharacterSet.nonBaseCharacterSet;
    NSUInteger letters = 0;
    for (UTF32Char point = 0xC0; point < 0x30000; point++) {
        NSString* letter = Scalar(point);
        if (!letter.length || [marks longCharacterIsMember:point] ||
            ![letter.precomposedStringWithCanonicalMapping isEqual:letter])
            continue;
        std::vector<UTF32Char> parts = MarkCheckPoints(letter.decomposedStringWithCanonicalMapping);
        BOOL counted = NO;
        for (size_t index = 1; index < parts.size(); index++) {
            if (![marks longCharacterIsMember:parts[index]]) continue;
            counted = YES;
            NSString* again = [letter stringByAppendingString:Scalar(parts[index])], *refusal = nil;
            NSString* named = [NSString stringWithFormat:@"(U+%04X)", (unsigned)parts[index]];
            Expect(!SPDFMacFriendsVisibleText(again, &refusal) && [refusal containsString:named] &&
                   CardMarkers(again) == 1 && [SPDFMacFriendsDraftText(again) isEqual:letter],
                   @"U+%04X already carries U+%04X, yet it went again: %@ (card %lu, draft %@)", (unsigned)point,
                   (unsigned)parts[index], refusal, (unsigned long)CardMarkers(again), SPDFMacFriendsDraftText(again));
        }
        letters += counted;
    }
    Expect(letters > 500, @"the composed letters with marks were found: %lu", (unsigned long)letters);
    // The review's measured spellings, composed or not, and a letter's own marks toward the cap of four.
    NSArray<NSArray*>* refused = @[ @[ @"\u1EC7\u0301\u0300\u0303\u0304", @"(U+0303)", @"\u1EC7\u0301\u0300" ],
        @[ @"e\u0302\u0323\u0301\u0300\u0303\u0304", @"(U+0303)", @"\u1EC7\u0301\u0300" ],
        @[ @"\u2260\u0338", @"(U+0338)", @"\u2260" ], @[ @"=\u0338\u0338", @"(U+0338)", @"\u2260" ],
        @[ @"\u01D6\u0301\u0302\u0303", @"(U+0303)", @"\u01D6\u0301\u0302" ],
        @[ @"\u00E9\u200B\u0301", @"(U+200B)", @"\u00E9" ],
        // The draft composes again once the space goes, and U+09C7 with U+09BE becomes a second U+09CB on the letter,
        // which goes too; a space left at a line's end goes as on the card.
        @[ @"\u0995\u09CB\u09C7\u200B\u09BE", @"(U+200B)", @"\u0995\u09CB" ],
        @[ @"Thanks \u200B\nSee you", @"(U+200B)", @"Thanks\nSee you" ] ];
    for (NSArray* item in refused) {
        NSString* refusal = nil;
        Expect(!SPDFMacFriendsVisibleText(item[0], &refusal) && [refusal containsString:item[1]] &&
               [SPDFMacFriendsDraftText(item[0]) isEqual:item[2]],
               @"%@ must be refused naming %@, its draft %@: %@ / %@", item[0], item[1], item[2], refusal,
               SPDFMacFriendsDraftText(item[0]));
    }
    // The model is told why a letter it did not stack can be full.
    NSString* refusal = nil;
    SPDFMacFriendsVisibleText(@"\u2260\u0338", &refusal);
    Expect([refusal containsString:@"A precomposed letter counts its own marks (\u1EC7 is e with two marks)."],
           @"the refusal must say a precomposed letter's marks count: %@", refusal);
    // Four marks counting the letter's own, and letters with no marks added, stay as written.
    for (NSString* kept in @[ @"\u1EC7\u0301\u0300", @"\u01D6\u0301\u0302", @"\u1F8F\u0301", @"\u304C", @"\u2260" ])
        Expect([Visible(kept) isEqual:kept], @"%@ must stay as written: %@", kept, Visible(kept));
}

// A vowel sign that is two in its decomposition (Bengali U+09CB is U+09C7 and U+09BE) counts as one mark, as NFC writes
// it: Tulu-Tigalari U+113C5 decomposes to U+113C2 twice, so counting its parts would refuse a plain vowel. That is safe
// only while no such sign draws the same with one of its parts again (none did when measured, 99 pairs); where one
// does on the fonts of the Mac that runs this, the text must be refused.
static void CheckTwoPartVowelSigns(void) {
    NSCharacterSet* marks = NSCharacterSet.nonBaseCharacterSet, *letters = NSCharacterSet.letterCharacterSet;
    NSUInteger signs = 0;
    for (UTF32Char point = 0x300; point < 0x20000; point++) {
        NSString* sign = Scalar(point);
        if (![marks longCharacterIsMember:point] || ![sign.precomposedStringWithCanonicalMapping isEqual:sign])
            continue;
        std::vector<UTF32Char> parts = MarkCheckPoints(sign.decomposedStringWithCanonicalMapping);
        if (parts.size() < 2) continue;
        UTF32Char base = point; // a letter of the sign's own script: the nearest one before it
        while (base > 0 && ![letters longCharacterIsMember:base]) base--;
        NSString* once = [Scalar(base) stringByAppendingString:sign];
        signs++;
        for (UTF32Char part : parts) {
            NSString* again = [once stringByAppendingString:Scalar(part)];
            Expect(!DrawsAlike(once, again) || !SPDFMacFriendsVisibleText(again, nil),
                   @"U+%04X with its part U+%04X again draws as without it, yet goes", (unsigned)point, (unsigned)part);
        }
    }
    Expect(signs > 20, @"the two-part vowel signs were found: %lu", (unsigned long)signs);
}

// Every combining mark after a Latin letter and after an emoji: wherever a second copy draws nothing more, the send
// check refuses the text, naming the mark, the card marks the copy and a draft drops it. Before this rule, U+065E,
// U+0732, U+1ACC and U+A806 after "a" and some eighty marks after an emoji went through with any repeat count. Runs
// the decomposition checks above too, since they are the same rule.
static void CheckRepeatedMarksDrawnAlike(void) {
    CheckPrecomposedLettersCarryTheirMarks();
    CheckTwoPartVowelSigns();
    NSCharacterSet* marks = NSCharacterSet.nonBaseCharacterSet;
    NSUInteger alike = 0;
    for (NSString* base in @[ @"a", @"\U0001F600" ]) {
        for (UTF32Char point = 0x300; point < 0x20000; point++) {
            if (![marks longCharacterIsMember:point]) continue;
            NSString* mark = Scalar(point), *once = [base stringByAppendingString:mark];
            NSString* twice = [once stringByAppendingString:mark];
            if (!DrawsAlike(once, twice)) continue;
            alike++;
            NSString* refusal = nil, *named = [NSString stringWithFormat:@"(U+%04X)", (unsigned)point];
            Expect(!SPDFMacFriendsVisibleText(twice, &refusal) && [refusal containsString:named],
                   @"%@ followed by U+%04X twice draws as once, yet was accepted (%@)", base, (unsigned)point,
                   refusal);
            Expect(CardMarkers(twice) > CardMarkers(once), @"the card must mark the second U+%04X after %@",
                   (unsigned)point, base);
            Expect(SPDFMacFriendsDraftText(twice).length < twice.length, @"a draft must drop the second U+%04X",
                   (unsigned)point);
        }
    }
    fprintf(stderr, "  %lu marks draw the same twice as once on this Mac; each refused\n", (unsigned long)alike);
    NSString* refusal = nil;
    Expect(!SPDFMacFriendsVisibleText(@"\u0628\u065E\u065E", &refusal) &&
           [refusal containsString:@"(U+065E)"] && [refusal containsString:@"Nothing was sent."],
           @"a repeated mark is refused, and the model is told which: %@", refusal);
    // A fifth mark on one letter, however different, is a pile nobody can count; four stay.
    Expect(!SPDFMacFriendsVisibleText(@"x\u0301\u0302\u0303\u0304\u0306", &refusal) &&
           [refusal containsString:@"(U+0306)"], @"a fifth mark: %@", refusal);
    NSString* stacked = @"x\u0301\u0302\u0303\u0304 \u0915\u093C\u093F \u0E01\u0E34\u0E48 \u1EC7 1\uFE0F\u20E3";
    Expect([Visible(stacked) isEqual:stacked], @"four marks, and the marks real writing stacks, are kept: %@",
           Visible(stacked));
    NSString* draft = SPDFMacFriendsDraftText(@"\u0628\u065E\u065E\u065E b\u0301\u0302\u0303\u0304\u0306");
    Expect([draft isEqual:@"\u0628\u065E b\u0301\u0302\u0303\u0304"],
           @"a draft keeps each mark once and four to a letter: %@", draft);
    // A refused character between a letter and its marks hides nothing: the marks still count on the letter.
    draft = SPDFMacFriendsDraftText(@"\u0628\u065E\u200B\u065E");
    Expect([draft isEqual:@"\u0628\u065E"], @"the draft must not bring a repeated mark together: %@", draft);
    // Marks of another script go from a draft, whatever they sit on (wave 6c: U+3099 on Hangul draws nothing).
    draft = SPDFMacFriendsDraftText(@"\uAC00\u3099\u309A a\u065E \u304B\u309A");
    Expect([draft isEqual:@"\uAC00 a \u304B\u309A"], @"a draft drops marks of another script only: %@", draft);
    // Wave 6e: Quran text writes pause and annotation marks after a space, where each draws (pixel scans, AppKit and
    // Pango); only those, once, and the model is told what a mark on a space or at a line's start is.
    NSString* verse = @"\u0644\u064E\u0627 \u0631\u064E\u064A\u0652\u0628\u064E \u06DB \u0641\u0650\u064A\u0647";
    NSString* sent = Visible([verse stringByAppendingString:@"\u00A0\u06DB"]);
    Expect([sent isEqual:[verse stringByAppendingString:@" \u06DB"]],
           @"Quranic pause marks after spaces go as written, a no-break space as U+0020: %@", sent);
    Expect(!SPDFMacFriendsVisibleText(@"\u0628 \u064E", &refusal) &&
               [refusal containsString:@"(U+064E) on a space or the start of a line"],
           @"a vowel on a space is refused as a mark on no letter: %@", refusal);
    Expect(!SPDFMacFriendsVisibleText(@"\u06DB\u0628", &refusal) && [refusal containsString:@"start of a line"],
           @"a pause mark before any letter is refused: %@", refusal);
    // Verify, wave 6e: after a blank the check does not write as U+0020 (the ideographic space, a line feed or a tab),
    // there is no letter of another script, so the model is told the mark stands on a space.
    for (NSString* blank in @[ @"\u3000", @"\t", @"\n" ])
        Expect(!SPDFMacFriendsVisibleText([NSString stringWithFormat:@"\u0628%@\u06DB", blank], &refusal) &&
                   [refusal containsString:@"(U+06DB) on a space or the start of a line"],
               @"a pause mark after U+%04X is refused as a mark on a space: %@", (unsigned)[blank characterAtIndex:0],
               refusal);
    draft = SPDFMacFriendsDraftText(@"\u0628 \u06DB\u06DB a\u06DB \u09B0\u200D\u09CD\u09AF\u09CD\u09CD");
    Expect([draft isEqual:@"\u0628 \u06DB a \u09B0\u200D\u09CD\u09AF\u09CD"],
           @"a draft keeps one pause mark on a space and a conjunct's joiner, a virama counted once: %@", draft);
    // Verify, wave 6e: a joiner between a consonant and a virama that ends a word joins nothing (a Bengali or
    // Malayalam font draws it the same without), so it goes; before a virama and a consonant it stays.
    Expect(!SPDFMacFriendsVisibleText(@"\u09B0\u200D\u09CD", &refusal) && [refusal containsString:@"(U+200D)"],
           @"a joiner before a word-final virama is refused: %@", refusal);
    draft = SPDFMacFriendsDraftText(@"\u0D28\u200D\u0D4D \u09B0\u200D\u09CD\u09AF");
    Expect([draft isEqual:@"\u0D28\u0D4D \u09B0\u200D\u09CD\u09AF"], @"a draft drops only the word-final joiner: %@",
           draft);
    // U+0000 was the "nothing found" value: "a", NUL, "b" passed while both cards marked it, and the store kept "a".
    Expect(!SPDFMacFriendsVisibleText(@"a\u0000b", &refusal) && [refusal containsString:@"(U+0000)"],
           @"U+0000 must be refused: %@", refusal);
    Expect([SPDFMacFriendsDraftText(@"a\u0000b") isEqual:@"ab"], @"a draft drops U+0000");
}

// Compatibility characters that draw exactly like their compatibility decomposition (NFKC) are delivered in one
// spelling, so which one the model chose is not a hidden bit. Hangul compatibility jamo are the recorded exception
// (SPDFMacFriendsSendText.mm): they draw like conjoining jamo only on their own, and folding would join them.
static void CheckCompatibilitySpellings(void) {
    NSCharacterSet* unassigned = NSCharacterSet.illegalCharacterSet;
    NSUInteger alike = 0;
    for (UTF32Char point = 0xA0; point < 0x30000; point++) {
        if ((point >= 0xD800 && point <= 0xDFFF) || (point >= 0x3131 && point <= 0x318E) ||
            [unassigned longCharacterIsMember:point])
            continue;
        NSString* written = Scalar(point).precomposedStringWithCanonicalMapping;
        NSString* folded = Scalar(point).precomposedStringWithCompatibilityMapping;
        if ([written isEqual:folded]) continue;
        NSString* one = [NSString stringWithFormat:@"x%@x", written];
        NSString* other = [NSString stringWithFormat:@"x%@x", folded];
        if (!DrawsAlike(one, other)) continue;
        alike++;
        NSString* sent = Visible(one), *sentOther = Visible(other);
        Expect((!sent && !sentOther) || [sent isEqual:sentOther], @"U+%04X draws like %@ yet goes as itself: %@",
               (unsigned)point, folded, sent);
    }
    fprintf(stderr, "  %lu compatibility characters draw like their folding on this Mac; each goes folded\n",
            (unsigned long)alike);
    // The review's pairs, and the ones outside NFKC: U+2010 and U+2011 draw as "-", and Thai sara am in two parts as
    // the one character.
    NSArray<NSArray<NSString*>*>* pairs = @[ @[ @"\uFB01le", @"file" ], @[ @"5 \u00B5m", @"5 \u03BCm" ],
        @[ @"e\u2010mail", @"e-mail" ], @[ @"e\u2011mail", @"e-mail" ], @[ @"\uFEFB", @"\u0644\u0627" ],
        @[ @"\u0133s", @"ijs" ], @[ @"\u0E01\u0E4D\u0E32", @"\u0E01\u0E33" ] ];
    for (NSArray<NSString*>* pair in pairs)
        Expect([Visible(pair[0]) isEqual:pair[1]] && [SPDFMacFriendsDraftText(pair[0]) isEqual:pair[1]],
               @"%@ must go as %@: %@ / %@", pair[0], pair[1], Visible(pair[0]), SPDFMacFriendsDraftText(pair[0]));
    // What looks different from its folding keeps its meaning: x² is not x2, nor ½ "1⁄2", nor ① "1", nor ™ "TM".
    for (NSString* kept in @[ @"x\u00B2", @"\u00BD", @"\u2460", @"\u2122", @"\uFF21", @"\u3131\u314F", @"\u2026",
                              @"a\u3000b" ])
        Expect([Visible(kept) isEqual:kept], @"%@ must stay as written: %@", kept, Visible(kept));
}
