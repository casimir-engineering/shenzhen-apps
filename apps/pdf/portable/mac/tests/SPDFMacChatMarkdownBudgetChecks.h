// What a render may spend (SPDFMacChatMarkdownBudget.mm): each render's own 0.4 s, parsing and text fallbacks
// included; an allowance several renders share, as a Friends conversation's render pass does; and laid-out blocks
// reused when the same block is rendered again.
#pragma once
#import "SPDFMacChatMarkdownFixtures.h"

static NSString* const ChatBudgetMessage =
    @"| A |\n|---|\n| 1 |\n\n```c\nint volts = 5;\n```\n\n| B |\n|---|\n| 2 |\n\n"
     "```mermaid\nflowchart LR\n  X --> Y\n```\n\n- **End.**";

// A friend's 32 KB message of small tables, about 2,000 of them, tagged so no two messages share a table. `last` gets
// the last table's header.
static NSString* ChatSmallTables(NSString* tag, NSString* __autoreleasing* last) {
    NSMutableString* message = [NSMutableString string];
    NSUInteger index = 0;
    for (; message.length < 32 * 1024; index++)
        [message appendFormat:@"|%@%lu|\n|-|\n|y|\n\n", tag, (unsigned long)index];
    if (last) *last = [NSString stringWithFormat:@"%@%lu", tag, (unsigned long)index - 1];
    return message;
}

static NSTimeInterval ChatTimeRender(NSString* message, SPDFMacChatMarkdownOptions* options,
                                     NSAttributedString* __autoreleasing* rendered) {
    NSDate* start = [NSDate date];
    NSAttributedString* text = SPDFMacChatMarkdownRender(message, options);
    NSTimeInterval elapsed = -[start timeIntervalSinceNow];
    if (rendered) *rendered = text;
    return elapsed;
}

// Tables, code and diagrams are drawn while the render has time for them; later ones show as text after one note, and
// past the end of the walk the rest of the message is plain text. The test seam makes each layout count as taking
// longer than it did, so the time runs out at the first block on any machine. With a 1 s render, drawing stops at
// 0.55 s and the walk at 0.7 s.
static void RunChatLayoutTimeChecks(void) {
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    SPDFMacChatForgetKeptBlocks();
    SPDFMacChatSetLayoutTime(1.0);
    SPDFMacChatSetExtraLayoutTime(0.6);
    NSAttributedString* text = SPDFMacChatMarkdownRender(ChatBudgetMessage, ChatOptions(320, NO, recorder));
    SPDFMacChatSetExtraLayoutTime(0);
    NSArray<SPDFMacChatBlock*>* blocks = ChatBlocks(text);
    Check(blocks.count == 1 && blocks.firstObject.kind == SPDFMacChatBlockTable,
          @"only the first block is drawn once the drawing time is spent");
    NSString* note = @"This message is large, so from here on its tables, code and diagrams appear as plain text.";
    NSUInteger notes = [text.string componentsSeparatedByString:note].count - 1;
    Check(notes == 1, [NSString stringWithFormat:@"the first block shown as text says why, once (%lu)",
                                                 (unsigned long)notes]);
    NSFont* code = ChatFontAt(text, @"int volts = 5;");
    Check(code.fixedPitch && fabs(code.pointSize - 12) < .01, @"code past the drawing time is 12 pt monospaced text");
    Check([text.string containsString:@"| B |"] && [text.string containsString:@"X --> Y"] &&
              [text.string hasSuffix:@"End."] && ChatWeight(ChatFontAt(text, @"End.")) > NSFontWeightRegular,
          @"later tables and diagrams show their Markdown, and the message's text keeps its formatting");
    NSString* copied = SPDFMacChatMarkdownCopyText(text, NSMakeRange(0, text.length));
    Check([copied containsString:@"int volts = 5;"] && [copied containsString:@"| B |\n| --- |\n| 2 |"] &&
              [copied containsString:@"```mermaid\nflowchart LR\n  X --> Y\n```"] && ![copied containsString:note],
          [@"blocks shown as text copy as their Markdown: " stringByAppendingString:copied]);

    // Past the walk's end the rest of the message is plain text, after a note, and still copies as its Markdown.
    SPDFMacChatForgetKeptBlocks();
    SPDFMacChatSetExtraLayoutTime(0.75);
    text = SPDFMacChatMarkdownRender(ChatBudgetMessage, ChatOptions(320, NO, recorder));
    SPDFMacChatSetExtraLayoutTime(0);
    NSString* rest = @"This message is large, so from here on it appears as plain text.";
    Check(ChatBlocks(text).count == 1 && [text.string containsString:rest] && ![text.string containsString:note],
          [@"after the first block the rest is plain text, under one note: " stringByAppendingString:text.string]);
    Check([text.string containsString:@"int volts = 5;"] && [text.string containsString:@"| B |"] &&
              [text.string containsString:@"X --> Y"] && [text.string hasSuffix:@"- End."] &&
              ChatWeight(ChatFontAt(text, @"End.")) <= NSFontWeightRegular,
          @"the plain rest keeps every block's words, unformatted");
    copied = SPDFMacChatMarkdownCopyText(text, NSMakeRange(0, text.length));
    Check([copied containsString:@"| B |\n| --- |\n| 2 |"] && ![copied containsString:rest],
          [@"the plain rest copies tables as their Markdown, without the note: " stringByAppendingString:copied]);
    SPDFMacChatForgetKeptBlocks();
    SPDFMacChatSetExtraLayoutTime(0.75);
    text = SPDFMacChatMarkdownRender(@"| A |\n|---|\n| 1 |\n\n3. three\n4. four\n   - nested",
                                     ChatOptions(320, NO, recorder));
    SPDFMacChatSetExtraLayoutTime(0);
    Check([text.string hasSuffix:@"3. three\u20284. four\u2028  - nested"],
          [@"a list in the plain rest keeps its numbers, one item per line: " stringByAppendingString:text.string]);

    // Within its time the same message draws every block.
    SPDFMacChatSetLayoutTime(0);
    Check(SPDFMacChatLayoutTime() == 0.4, @"the default render time is restored");
    SPDFMacChatForgetKeptBlocks();
    blocks = ChatBlocks(SPDFMacChatMarkdownRender(ChatBudgetMessage, ChatOptions(320, NO, recorder)));
    Check(blocks.count == 4, @"a message within its time draws all its blocks");
}

// The security review timed a friend's 32 KB message of small tables at 0.46 s against a 0.4 s allowance, because
// parsing and the blocks shown as text after it were not counted. Now the whole render counts. Checked at the
// default 0.4 s and at a shorter 0.15 s, where the old accounting took 0.24 s on an idle machine. The margins leave
// room for a machine busy with other builds; the old code missed each by more.
static void RunChatRenderTimeChecks(void) {
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    SPDFMacChatForgetKeptBlocks();
    SPDFMacChatMarkdownOptions* options = ChatOptions(300, NO, recorder);
    options.links = SPDFMacChatMarkdownLinksFriends;
    NSString* tag = nil;
    NSString* message = ChatSmallTables(@"t", &tag);
    Check(message.length >= 32 * 1024 && message.length < 33 * 1024, @"the small tables fill a friend's 32 KB");
    NSAttributedString* text = nil;
    NSTimeInterval elapsed = ChatTimeRender(message, options, &text);
    Check(elapsed < 0.4 + 0.05, [NSString stringWithFormat:@"a 32 KB message of small tables renders within 0.4 s "
                                                            "and a small margin (%.3f s)", elapsed]);
    NSString* copied = SPDFMacChatMarkdownCopyText(text, NSMakeRange(0, text.length));
    Check(ChatBlocks(text).count > 10 && [copied hasPrefix:@"| t0 |"] &&
              [copied containsString:[NSString stringWithFormat:@"| %@ |", tag]],
          [@"its first tables are drawn and every table still shows, up to the last: " stringByAppendingString:tag]);
    SPDFMacChatSetLayoutTime(0.15);
    elapsed = ChatTimeRender(ChatSmallTables(@"s", nil), options, nil);
    SPDFMacChatSetLayoutTime(0);
    Check(elapsed < 0.15 + 0.06, [NSString stringWithFormat:@"with 0.15 s the same render stays within it and a "
                                                            "margin (%.3f s)", elapsed]);
    // A 128 KB answer of small tables, the most a chat shows, also stays within its time.
    NSMutableString* answer = [NSMutableString string];
    for (NSUInteger part = 0; answer.length < 128 * 1024; part++)
        [answer appendString:ChatSmallTables([NSString stringWithFormat:@"a%lu.", (unsigned long)part], nil)];
    elapsed = ChatTimeRender(answer, ChatOptions(320, NO, recorder), nil);
    Check(elapsed < 0.4 + 0.15, [NSString stringWithFormat:@"a 128 KB answer of small tables renders within 0.4 s "
                                                            "and a margin (%.3f s)", elapsed]);
    Check(recorder.count == 0, @"timed renders fetch nothing");
}

// Friends gives one allowance to every message of a conversation render pass: 50 hostile messages together cost
// about its 1 s, and those past it come back as plain text at once.
static void RunChatAllowanceChecks(void) {
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    SPDFMacChatForgetKeptBlocks();
    SPDFMacChatMarkdownAllowance* none = [[SPDFMacChatMarkdownAllowance alloc] initWithTotal:0];
    SPDFMacChatMarkdownOptions* options = ChatOptions(300, NO, recorder);
    options.links = SPDFMacChatMarkdownLinksFriends;
    options.allowance = none;
    NSAttributedString* text = SPDFMacChatMarkdownRender(ChatBudgetMessage, options);
    Check(none.spent && [text.string isEqualToString:ChatBudgetMessage] && ChatAttachments(text).count == 0,
          @"with nothing left a render returns the message's own words as plain text");

    SPDFMacChatMarkdownAllowance* pass = [[SPDFMacChatMarkdownAllowance alloc] initWithTotal:1.0];
    options.allowance = pass;
    NSTimeInterval one = ChatTimeRender(ChatSmallTables(@"first", nil), options, nil);
    Check(pass.total - pass.remaining >= one * 0.9 - 0.002 && pass.total - pass.remaining <= one + 0.002,
          [NSString stringWithFormat:@"a render spends from the allowance the whole time it took, parsing included "
                                     "(%.3f of %.3f s)", pass.total - pass.remaining, one]);
    pass = [[SPDFMacChatMarkdownAllowance alloc] initWithTotal:SPDFMacChatMarkdownPassTotal];
    options.allowance = pass;
    NSMutableArray<NSString*>* messages = [NSMutableArray array];
    for (NSUInteger index = 0; index < 50; index++)
        [messages addObject:ChatSmallTables([NSString stringWithFormat:@"m%lu.", (unsigned long)index], nil)];
    NSDate* start = [NSDate date];
    NSUInteger plain = 0;
    for (NSString* message in messages) {
        NSAttributedString* rendered = SPDFMacChatMarkdownRender(message, options);
        if (!ChatAttachments(rendered).count && [rendered.string isEqualToString:message]) plain++;
    }
    NSTimeInterval fifty = -[start timeIntervalSinceNow];
    Check(fifty < SPDFMacChatMarkdownPassTotal + 0.4 + 0.15,
          [NSString stringWithFormat:@"50 hostile messages sharing a 1 s allowance render within it, plus one "
                                     "message's 0.4 s and a margin (%.3f s)", fifty]);
    Check(pass.spent && plain >= 40,
          [NSString stringWithFormat:@"messages past the allowance come back as plain text (%lu)",
                                     (unsigned long)plain]);

    // A host that cannot tell where a pass ends gets one allowance until the main queue next runs.
    SPDFMacChatMarkdownAllowance* current = SPDFMacChatMarkdownCurrentPassAllowance(SPDFMacChatMarkdownPassTotal);
    Check(current == SPDFMacChatMarkdownCurrentPassAllowance(SPDFMacChatMarkdownPassTotal) &&
              current.total == SPDFMacChatMarkdownPassTotal,
          @"renders in one pass share its allowance");
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    Check(SPDFMacChatMarkdownCurrentPassAllowance(SPDFMacChatMarkdownPassTotal) != current,
          @"the next pass gets a fresh allowance");
    Check(recorder.count == 0, @"allowance renders fetch nothing");
}

// Rendering the same block again at the same width and colours reuses its layout, as reopening a conversation does;
// another width or appearance lays it out afresh.
static void RunChatKeptBlockChecks(void) {
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    SPDFMacChatForgetKeptBlocks();
    NSString* message = @"| Item | Qty |\n|---|---|\n| [Boards](https://parcel.example/b) | 5 |\n\n"
                         "```c\nint a;\n```\n\n```mermaid\nflowchart LR\n  A --> B\n```";
    NSArray<SPDFMacChatBlock*>* first = ChatBlocks(SPDFMacChatMarkdownRender(message, ChatOptions(320, NO, recorder)));
    NSArray<SPDFMacChatBlock*>* again = ChatBlocks(SPDFMacChatMarkdownRender(message, ChatOptions(320, NO, recorder)));
    Check(first.count == 3 && again.count == 3, @"the table, code and diagram are drawn");
    for (NSUInteger index = 0; index < 3; index++)
        Check(first[index] == again[index], @"rendering the message again reuses each block's layout");
    NSArray<SPDFMacChatBlock*>* wider = ChatBlocks(SPDFMacChatMarkdownRender(message, ChatOptions(360, NO, recorder)));
    NSArray<SPDFMacChatBlock*>* dark = ChatBlocks(SPDFMacChatMarkdownRender(message, ChatOptions(320, YES, recorder)));
    Check(wider.firstObject != first.firstObject && dark.firstObject != first.firstObject &&
              dark.firstObject.variant == SPDFMarkdownThemeVariantDark,
          @"another width or appearance lays the blocks out afresh");
    NSString* edited = [message stringByReplacingOccurrencesOfString:@"parcel.example/b" withString:@"evil.example/b"];
    NSArray<SPDFMacChatBlock*>* other = ChatBlocks(SPDFMacChatMarkdownRender(edited, ChatOptions(320, NO, recorder)));
    Check(other.firstObject != first.firstObject && other[1] == first[1],
          @"a table whose link goes elsewhere is not the same table; the unchanged code block is");
    // A citation travels under an alias that is new each render, so a table holding one is never kept.
    NSString* cited = @"| Source |\n|---|\n| [page 2](spdf-ai://document?path=a.pdf&page=2) |";
    Check(ChatBlocks(SPDFMacChatMarkdownRender(cited, ChatOptions(320, NO, recorder))).firstObject !=
              ChatBlocks(SPDFMacChatMarkdownRender(cited, ChatOptions(320, NO, recorder))).firstObject,
          @"a table with a citation is laid out each render");
    SPDFMacChatForgetKeptBlocks();
}
