// The "<title> - comments.md" file and comment anchoring (SPDFMacMarkdownComments.h): the file must read well and
// parse back to the same comments, and a comment must find its words again after the document is edited.

#import <Foundation/Foundation.h>

#import "SPDFMacMarkdownComments.h"

static int gFailures;

static void Expect(BOOL condition, NSString* message) {
    if (condition) return;
    ++gFailures;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
}

// What the renderer makes of the source below: markup gone, list bullets as text, one block per line.
static NSString* const kSource = @"# Board\n\nIntro text.\n\n## Setup\n\n### Wiring\n\n"
                                 @"The board needs **two pull-ups on SDA** before power-on.\n\n"
                                 @"- Check the [pull-ups](http://x.test) twice\n\n## Power\n\n"
                                 @"Use two pull-ups on SDA here too.\n";
static NSString* const kRendered = @"Board\nIntro text.\nSetup\nWiring\n"
                                   @"The board needs two pull-ups on SDA before power-on.\n"
                                   @"• Check the pull-ups twice\nPower\nUse two pull-ups on SDA here too.\n";

static SPDFMarkdownComment* CommentOn(SPDFMarkdownCommentAnchors* anchors, NSString* rendered, NSString* words,
                                      NSUInteger occurrence) {
    NSRange range = NSMakeRange(0, 0);
    NSRange search = NSMakeRange(0, rendered.length);
    for (NSUInteger i = 0; i <= occurrence; i++) {
        range = [rendered rangeOfString:words options:0 range:search];
        search = NSMakeRange(NSMaxRange(range), rendered.length - NSMaxRange(range));
    }
    SPDFMarkdownComment* comment = [SPDFMarkdownComment new];
    comment.author = @"Raph *R* Casimir";
    comment.text = @"Check the value.\n\n---\n# not a heading";
    comment.date = [NSDate dateWithTimeIntervalSince1970:1761984000];
    Expect([anchors anchorComment:comment toRenderedRange:range], @"anchor a selection");
    return comment;
}

static void TestAnchorAndFile(void) {
    SPDFMarkdownCommentAnchors* anchors = [[SPDFMarkdownCommentAnchors alloc] initWithSource:kSource rendered:kRendered];
    SPDFMarkdownComment* wiring = CommentOn(anchors, kRendered, @"two pull-ups on SDA", 0);
    Expect(wiring.line == 9, [NSString stringWithFormat:@"line of first quote: %ld", (long)wiring.line]);
    Expect([wiring.headingPath isEqualToArray:(@[ @"# Board", @"## Setup", @"### Wiring" ])],
           [NSString stringWithFormat:@"heading path: %@", wiring.headingPath]);
    Expect([wiring.contextBefore isEqualToString:@"The board needs "], wiring.contextBefore);
    Expect([wiring.contextAfter isEqualToString:@" before power-on."], wiring.contextAfter);

    SPDFMarkdownComment* power = CommentOn(anchors, kRendered, @"two pull-ups on SDA", 1);
    Expect(power.line == 15, [NSString stringWithFormat:@"line of second quote: %ld", (long)power.line]);
    Expect([power.headingPath.lastObject isEqualToString:@"## Power"], @"second quote is under Power");
    SPDFMarkdownComment* link = CommentOn(anchors, kRendered, @"pull-ups twice", 0);
    Expect(link.line == 11, [NSString stringWithFormat:@"a quote across a link: %ld", (long)link.line]);
    Expect([link.contextBefore isEqualToString:@"Check the "], [@"no list bullet in the context: " stringByAppendingString:link.contextBefore]);

    NSString* file = SPDFMarkdownCommentsFileText(@"Board.md", @[ power, wiring ]);
    Expect([file hasPrefix:@"# Comments on Board.md\n"], @"one-line header naming the document");
    Expect([file containsString:@"**Line 9** · # Board › ## Setup › ### Wiring"], file);
    Expect([file containsString:@"> The board needs **two pull-ups on SDA** before power-on."], file);
    Expect([file containsString:@"**Raph \\*R\\* Casimir** · "], @"author escaped");
    Expect([file rangeOfString:@"Line 9"].location < [file rangeOfString:@"Line 15"].location, @"document order");
    Expect([file containsString:@"\n\\---\n"] && [file containsString:@"\n\\# not a heading\n"], @"body escapes");

    NSArray<SPDFMarkdownComment*>* parsed = SPDFMarkdownCommentsParseFile(file);
    Expect(parsed.count == 2, [NSString stringWithFormat:@"parsed %lu comments", (unsigned long)parsed.count]);
    if (parsed.count != 2) return;
    SPDFMarkdownComment* back = parsed[0];
    Expect([back.quote isEqualToString:@"two pull-ups on SDA"], back.quote);
    Expect([back.author isEqualToString:@"Raph *R* Casimir"], back.author);
    Expect([back.text isEqualToString:wiring.text], back.text);
    Expect(back.line == 9 && [back.headingPath isEqualToArray:wiring.headingPath], @"location round trip");
    Expect([back.date isEqualToDate:[NSDate dateWithTimeIntervalSince1970:1761984000]] ||
               fabs(back.date.timeIntervalSince1970 - 1761984000) < 60, @"date round trip");
    Expect(!back.placed, @"a parsed comment waits to be placed");

    // Placing the parsed comments picks the right occurrence of a repeated quote.
    for (SPDFMarkdownComment* comment in parsed) [anchors placeComment:comment];
    Expect(parsed[0].renderedRange.location == wiring.renderedRange.location, @"first occurrence placed");
    Expect(parsed[1].renderedRange.location == power.renderedRange.location, @"second occurrence placed");
    Expect([SPDFMarkdownCommentsFileText(@"Board.md", parsed) isEqualToString:file], @"write-parse-write is stable");
}

static void TestEditsKeepAnchors(void) {
    SPDFMarkdownCommentAnchors* anchors = [[SPDFMarkdownCommentAnchors alloc] initWithSource:kSource rendered:kRendered];
    SPDFMarkdownComment* power = CommentOn(anchors, kRendered, @"two pull-ups on SDA", 1);
    SPDFMarkdownComment* wiring = CommentOn(anchors, kRendered, @"two pull-ups on SDA", 0);
    // Lines added above both, and words changed around them.
    NSString* source = [@"# Board\n\nA new first paragraph.\n\nAnd another.\n"
        stringByAppendingString:[[kSource substringFromIndex:9] stringByReplacingOccurrencesOfString:@"before power-on"
                                                                                           withString:@"first"]];
    NSString* rendered = [@"Board\nA new first paragraph.\nAnd another.\n"
        stringByAppendingString:[[kRendered substringFromIndex:6] stringByReplacingOccurrencesOfString:@"before power-on"
                                                                                             withString:@"first"]];
    SPDFMarkdownCommentAnchors* edited = [[SPDFMarkdownCommentAnchors alloc] initWithSource:source rendered:rendered];
    Expect([edited placeComment:power], @"a moved comment reports a change");
    [edited placeComment:wiring];
    Expect(power.placed && power.line == 18, [NSString stringWithFormat:@"power moved to %ld", (long)power.line]);
    Expect(wiring.placed && wiring.line == 12, [NSString stringWithFormat:@"wiring moved to %ld", (long)wiring.line]);
    Expect([[rendered substringWithRange:power.renderedRange] isEqualToString:@"two pull-ups on SDA"], @"range text");
    Expect([wiring.contextAfter isEqualToString:@" first."], wiring.contextAfter);

    // The passage removed: the comment stays, unplaced, and is listed under "Unplaced".
    NSString* gone = [rendered stringByReplacingOccurrencesOfString:@"two pull-ups on SDA" withString:@"a resistor"];
    SPDFMarkdownCommentAnchors* removed = [[SPDFMarkdownCommentAnchors alloc] initWithSource:gone rendered:gone];
    Expect([removed placeComment:power] && !power.placed, @"a vanished passage unplaces the comment");
    [removed placeComment:wiring];
    NSString* file = SPDFMarkdownCommentsFileText(@"Board.md", @[ power, wiring ]);
    Expect([file containsString:@"## Unplaced"], @"Unplaced heading");
    NSArray* parsed = SPDFMarkdownCommentsParseFile(file);
    Expect(parsed.count == 2 && [[parsed[1] quote] isEqualToString:@"two pull-ups on SDA"], @"unplaced parse back");
}

static void TestNames(void) {
    Expect([SPDFMarkdownCommentsFilePath(@"/a/Setup Guide.md") isEqualToString:@"/a/Setup Guide - comments.md"],
           @"comments file name");
    Expect(SPDFMarkdownIsCommentsFilePath(@"/a/Setup Guide - comments.md"), @"recognises a comments file");
    Expect(!SPDFMarkdownIsCommentsFilePath(@"/a/Setup Guide.md"), @"a document is not a comments file");
    SPDFMarkdownCommentAnchors* anchors = [[SPDFMarkdownCommentAnchors alloc] initWithSource:kSource rendered:kRendered];
    NSRange block = [anchors blockRangeAtRenderedLocation:[kRendered rangeOfString:@"needs"].location];
    Expect([[kRendered substringWithRange:block] hasPrefix:@"The board needs"], @"block under a click");
}

int main(void) {
    @autoreleasepool {
        TestAnchorAndFile();
        TestEditsKeepAnchors();
        TestNames();
    }
    if (gFailures) {
        fprintf(stderr, "SPDFMacMarkdownCommentsTests failed: %d\n", gFailures);
        return 1;
    }
    printf("SPDFMacMarkdownCommentsTests passed\n");
    return 0;
}
