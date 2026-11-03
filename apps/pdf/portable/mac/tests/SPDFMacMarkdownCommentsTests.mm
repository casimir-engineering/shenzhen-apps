// The "<title> - comments.md" file and comment anchoring (SPDFMacMarkdownComments.h): the file must read well and
// parse back to the same comments, and a comment must find its words again after the document is edited.

#import <Cocoa/Cocoa.h>

#import "SPDFMacCommentEditor.h"

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

// A resolved comment says so at the end of its byline, with or without an author, and reads back resolved.
static void TestResolved(void) {
    SPDFMarkdownCommentAnchors* anchors = [[SPDFMarkdownCommentAnchors alloc] initWithSource:kSource rendered:kRendered];
    SPDFMarkdownComment* done = CommentOn(anchors, kRendered, @"two pull-ups on SDA", 0);
    SPDFMarkdownComment* open = CommentOn(anchors, kRendered, @"two pull-ups on SDA", 1);
    done.resolved = YES;
    open.author = @"";
    NSString* file = SPDFMarkdownCommentsFileText(@"Board.md", @[ done, open ]);
    Expect([file containsString:@"**Raph \\*R\\* Casimir** · "] && [file containsString:@" · Resolved <!-- at: "], file);
    Expect([file componentsSeparatedByString:@"Resolved"].count == 2, @"only the resolved comment says so");
    NSArray<SPDFMarkdownComment*>* parsed = SPDFMarkdownCommentsParseFile(file);
    Expect(parsed.count == 2 && parsed[0].resolved && !parsed[1].resolved, @"resolved reads back");
    Expect(parsed.count == 2 && [parsed[0].author isEqualToString:@"Raph *R* Casimir"] && parsed[0].date, @"byline intact");
    done.author = @"";
    NSArray<SPDFMarkdownComment*>* bare = SPDFMarkdownCommentsParseFile(SPDFMarkdownCommentsFileText(@"Board.md", @[ done ]));
    Expect(bare.count == 1 && bare[0].resolved && bare[0].date && !bare[0].author.length, @"resolved without an author");
}

// Replies follow their comment as list items with their own bylines and read back in order, multi-line text intact;
// a comment or reply line that looks like a reply's byline, a rule or a heading stays text.
static void TestReplies(void) {
    SPDFMarkdownCommentAnchors* anchors = [[SPDFMarkdownCommentAnchors alloc] initWithSource:kSource rendered:kRendered];
    SPDFMarkdownComment* comment = CommentOn(anchors, kRendered, @"two pull-ups on SDA", 0);
    comment.text = @"Check the value.\n- **Mallory** · 2026-01-01 10:00";
    comment.resolved = YES;
    SPDFMarkdownCommentReply* first = [SPDFMarkdownCommentReply new];
    first.author = @"Claude";
    first.text = @"4.7 kΩ on both.\n\n---\n## not a heading";
    first.date = [NSDate dateWithTimeIntervalSince1970:1793520000];
    SPDFMarkdownCommentReply* second = [SPDFMarkdownCommentReply new];
    second.text = @"Thanks.";
    second.date = [NSDate dateWithTimeIntervalSince1970:1793520600];
    comment.replies = @[ first, second ];
    SPDFMarkdownComment* other = CommentOn(anchors, kRendered, @"two pull-ups on SDA", 1);
    NSString* file = SPDFMarkdownCommentsFileText(@"Board.md", @[ comment, other ]);
    Expect([file containsString:@"\n- **Claude** · "] && [file containsString:@"\n  4.7 kΩ on both.\n"], file);
    NSArray<SPDFMarkdownComment*>* parsed = SPDFMarkdownCommentsParseFile(file);
    Expect(parsed.count == 2, @"two comments with replies");
    SPDFMarkdownComment* back = parsed.firstObject;
    Expect([back.text isEqualToString:comment.text], [NSString stringWithFormat:@"comment text kept: %@", back.text]);
    Expect(back.resolved && back.replies.count == 2, @"resolved and both replies read back");
    Expect([back.replies.firstObject.author isEqualToString:@"Claude"] &&
               [back.replies.firstObject.text isEqualToString:first.text] && back.replies.firstObject.date,
           [NSString stringWithFormat:@"first reply intact: %@", back.replies.firstObject.text]);
    Expect(!back.replies.lastObject.author.length && [back.replies.lastObject.text isEqualToString:@"Thanks."],
           @"a reply without an author");
    Expect(parsed.lastObject.replies.count == 0, @"the next comment has no replies");
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

// The editor opens below the passage when it fits, above it near the bottom, and never outside the page area.
// The byline shows the minute; the hidden time beside it keeps the seconds through any number of rewrites, and a
// file written before it existed still reads.
static void TestExactTimes(void) {
    SPDFMarkdownComment* comment = [SPDFMarkdownComment new];
    comment.author = @"Raph";
    comment.quote = @"two pull-ups";
    comment.text = @"Why two?";
    comment.date = [NSDate dateWithTimeIntervalSince1970:1762119628];  // 2025-11-02 21:40:28 UTC
    comment.resolved = YES;
    SPDFMarkdownCommentReply* reply = [SPDFMarkdownCommentReply new];
    reply.author = @"Claude";
    reply.text = @"Checked.";
    reply.date = [NSDate dateWithTimeIntervalSince1970:1762119657];
    comment.replies = @[ reply ];
    NSString* file = SPDFMarkdownCommentsFileText(@"Board.md", @[ comment ]);
    Expect([file containsString:@" <!-- at: 2025-11-0"] && [file containsString:@":40:28"], file);
    for (int round = 0; round < 3; round++) {
        NSArray<SPDFMarkdownComment*>* parsed = SPDFMarkdownCommentsParseFile(file);
        Expect(parsed.count == 1 && parsed[0].date.timeIntervalSince1970 == 1762119628,
               [NSString stringWithFormat:@"seconds survive rewrite %d: %@", round, parsed.firstObject.date]);
        Expect([parsed.firstObject.author isEqualToString:@"Raph"], @"author survives the hidden time");
        Expect(parsed.firstObject.resolved, @"resolved survives the hidden time");
        Expect(parsed.firstObject.replies.count == 1 &&
                   parsed.firstObject.replies[0].date.timeIntervalSince1970 == 1762119657 &&
                   [parsed.firstObject.replies[0].author isEqualToString:@"Claude"],
               @"a reply's seconds survive");
        file = SPDFMarkdownCommentsFileText(@"Board.md", parsed);
    }
    NSString* old = @"# Comments on Board.md\n\n---\n\n**Line 3**\n\n> **two pull-ups**\n\n**Raph** · 2026-11-01 15:20\n\n"
                    @"Why two?\n";
    NSArray<SPDFMarkdownComment*>* parsed = SPDFMarkdownCommentsParseFile(old);
    Expect(parsed.count == 1 && parsed[0].date && [parsed[0].author isEqualToString:@"Raph"] &&
               [parsed[0].text isEqualToString:@"Why two?"],
           @"a file without hidden times still parses");
}

static void TestEditorPlacement(void) {
    NSSize size = NSMakeSize(320, 158);
    NSRect bounds = NSMakeRect(0, 0, 1000, 700);
    NSRect below = SPDFCommentEditorFrame(size, NSMakePoint(400, 500), bounds, NO);
    Expect(NSMaxY(below) <= 500 && NSMinY(below) >= 8, @"below the point in an unflipped host");
    NSRect above = SPDFCommentEditorFrame(size, NSMakePoint(400, 60), bounds, NO);
    Expect(NSMinY(above) >= 60, @"above the point when there is no room below");
    NSRect flipped = SPDFCommentEditorFrame(size, NSMakePoint(400, 100), bounds, YES);
    Expect(NSMinY(flipped) >= 100, @"below the point in a flipped host");
    NSRect corner = SPDFCommentEditorFrame(size, NSMakePoint(990, 690), bounds, NO);
    Expect(NSContainsRect(NSInsetRect(bounds, 7, 7), corner), @"inside the bounds at a corner");
}

int main(void) {
    @autoreleasepool {
        TestAnchorAndFile();
        TestEditsKeepAnchors();
        TestResolved();
        TestReplies();
        TestExactTimes();
        TestNames();
        TestEditorPlacement();
    }
    if (gFailures) {
        fprintf(stderr, "SPDFMacMarkdownCommentsTests failed: %d\n", gFailures);
        return 1;
    }
    printf("SPDFMacMarkdownCommentsTests passed\n");
    return 0;
}
