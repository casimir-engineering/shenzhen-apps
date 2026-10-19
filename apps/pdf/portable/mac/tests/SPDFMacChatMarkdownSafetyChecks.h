// What a hostile or careless message cannot do: open where it should not, run HTML, fetch an image by itself, or
// stall the chat with a diagram.
#pragma once
#import "SPDFMacChatMarkdownFixtures.h"

static NSDictionary<NSString*, NSString*>* ChatLinks(NSAttributedString* text) {
    NSMutableDictionary* links = [NSMutableDictionary dictionary];
    [text enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id value, NSRange range, BOOL* stop) {
                    (void)stop;
                    if (!value) return;
                    NSString* tip = [text attribute:NSToolTipAttributeName atIndex:range.location effectiveRange:NULL];
                    links[[value absoluteString]] = tip ?: @"";
                  }];
    return links;
}

static BOOL ChatIsPlaceholder(NSTextAttachment* attachment) {
    return [NSStringFromClass([attachment.attachmentCell class]) isEqualToString:@"SPDFMacChatImageCell"];
}

static NSString* const ChatLinkFixture =
    @"[site](https://example.com/a) [doc](spdf-ai://document?path=a.pdf&page=2) "
     "[friend](shenzhenpdf-friends://message?id=m1) [file](file:///etc/passwd) [plain](http://example.com/b) "
     "[creds](https://user:secret@example.com/c) [js](javascript:alert(1)) [[Wiki note]] "
     "<a href=\"https://html.example/x\">anchor</a> <a href=\"javascript:alert(2)\">bad anchor</a>";

static void RunChatLinkChecks(void) {
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    SPDFMacChatMarkdownOptions* options = ChatOptions(400, NO, recorder);
    NSDictionary* links = ChatLinks(SPDFMacChatMarkdownRender(ChatLinkFixture, options));
    NSSet* expected = [NSSet setWithArray:@[ @"https://example.com/a", @"spdf-ai://document?path=a.pdf&page=2",
                                             @"shenzhenpdf-friends://message?id=m1", @"https://html.example/x",
                                             @"http://example.com/b" ]];
    Check([[NSSet setWithArray:links.allKeys] isEqualToSet:expected],
          [@"AI chat keeps web links, document and Friends citations, nothing else: "
              stringByAppendingString:links.description]);
    Check([links[@"http://example.com/b"] isEqualToString:@"http://example.com/b"],
          @"a plain http link in an answer shows its destination too");
    Check([links[@"https://example.com/a"] isEqualToString:@"https://example.com/a"],
          @"a web link shows its destination when the pointer rests on it");
    options.links = SPDFMacChatMarkdownLinksFriends;
    links = ChatLinks(SPDFMacChatMarkdownRender(ChatLinkFixture, options));
    Check([[NSSet setWithArray:links.allKeys] isEqualToSet:[NSSet setWithArray:@[ @"https://example.com/a",
                                                                                 @"https://html.example/x" ]]],
          [@"a friend's message keeps https links only: " stringByAppendingString:links.description]);
    Check(!SPDFMacChatMarkdownLinkAllowed([NSURL URLWithString:@"https://user:secret@example.com"],
                                          SPDFMacChatMarkdownLinksAssistant),
          @"a link carrying credentials is never clickable");
}

static void RunChatHTMLChecks(void) {
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    NSAttributedString* text = SPDFMacChatMarkdownRender(
        @"<script>alert('owned')</script><style>body{display:none}</style>\n\n<iframe src=\"https://evil.example\">"
         "</iframe>\n\nSafe <b>bold</b> <img src=\"x\" onerror=\"alert(3)\">",
        ChatOptions(400, NO, recorder));
    Check(![text.string containsString:@"alert"] && ![text.string containsString:@"display:none"] &&
              ![text.string containsString:@"evil.example"],
          [@"raw HTML is never run or shown as code: " stringByAppendingString:text.string]);
    Check([text.string containsString:@"bold"] && ChatWeight(ChatFontAt(text, @"bold")) > NSFontWeightRegular,
          @"the safe HTML subset still renders");
    Check(recorder.count == 0, @"HTML fetches nothing");
}

static void RunChatImageChecks(void) {
    SPDFMacChatForgetLoadedImages();
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    NSString* source = @"Photos:\n\n![remote board](https://example.com/board.png)\n\n![local](/etc/hosts.png) "
                        "![data](data:image/png;base64,iVBORw0KGgo=) ![relative](pic.png) "
                        "<img src=\"https://example.com/html.png\" alt=\"html picture\">\n\n"
                        "| Cell |\n|---|\n| ![in table](https://example.com/table.png) |";
    SPDFMacChatMarkdownOptions* options = ChatOptions(400, NO, recorder);
    options.messageKey = @"message-one";
    NSAttributedString* text = SPDFMacChatMarkdownRender(source, options);
    NSUInteger placeholders = 0;
    for (NSTextAttachment* attachment in ChatAttachments(text))
        if (ChatIsPlaceholder(attachment)) placeholders++;
    Check(placeholders == 2, @"each https image is a placeholder until clicked");
    Check([text.string containsString:@"[Image: local]"] && [text.string containsString:@"[Image: data]"] &&
              [text.string containsString:@"[Image: relative]"],
          @"local, data and relative images are never read: their alt text stands in");
    Check([ChatBlocks(text).firstObject.rendered.attributedString.string containsString:@"[Image: in table]"],
          @"an image inside a drawn table shows its alt text");
    // Drawing the message, at both scales and in a window, still fetches nothing.
    NSWindow* window = ChatWindow(NSMakeRect(0, 0, 440, 700));
    SPDFMacChatMarkdownView* view = [[SPDFMacChatMarkdownView alloc] initWithMarkdown:source width:420 options:options];
    view.translatesAutoresizingMaskIntoConstraints = YES;
    view.frame = NSMakeRect(0, 0, 420, view.contentHeight.constant);
    [window.contentView addSubview:view];
    NSBitmapImageRep* rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    Check(recorder.count == 0, @"no remote image is fetched before a click");

    // A click on the placeholder loads that one image, for this message.
    NSTextAttachment* first = nil;
    for (NSTextAttachment* attachment in ChatAttachments(view.textStorage))
        if (!first && ChatIsPlaceholder(attachment))
            first = attachment;
    NSRect frame = ChatAttachmentFrame(view, ChatIndexOfAttachment(view.textStorage, first));
    ChatClick(view, NSMakePoint(NSMidX(frame), NSMidY(frame)));
    NSString* fetched = recorder.URLs.firstObject.absoluteString;
    Check(recorder.count == 1 && [fetched isEqualToString:@"https://example.com/board.png"],
          @"one click fetches exactly the image clicked");
    NSUInteger shown = 0;
    for (NSTextAttachment* attachment in ChatAttachments(view.textStorage))
        if (attachment.image && NSWidth(attachment.bounds) > 0) {
            shown++;
            CGFloat ratio = NSWidth(attachment.bounds) / NSHeight(attachment.bounds);
            Check(NSWidth(attachment.bounds) <= 400 && fabs(ratio - 1.6) < .02,
                  @"a loaded image fits the bubble and keeps its shape");
        }
    Check(shown >= 1, @"the message shows the loaded image in place of its placeholder");
    // The click held for this message only: the same address in another message waits for its own click.
    options.messageKey = @"message-two";
    NSAttributedString* other = SPDFMacChatMarkdownRender(@"![remote board](https://example.com/board.png)", options);
    Check(ChatAttachments(other).count == 1 && ChatAttachments(other).firstObject.attachmentCell != nil,
          @"another message's copy of the image stays a placeholder");
    options.messageKey = @"message-one";
    SPDFMacChatMarkdownRender(source, options);
    Check(recorder.count == 1, @"showing the loaded message again fetches nothing more");

    // A failed load says so and can be tried again.
    recorder.fails = YES;
    options.messageKey = @"message-three";
    NSAttributedString* failing = SPDFMacChatMarkdownRender(@"![x](https://example.com/broken.png)", options);
    NSTextView* plain = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 200)];
    plain.editable = NO;
    [window.contentView addSubview:plain];
    [plain.textStorage setAttributedString:failing];
    NSRect broken = ChatAttachmentFrame(plain, ChatIndexOfAttachment(failing, ChatAttachments(failing).firstObject));
    ChatClick(plain, NSMakePoint(NSMidX(broken), NSMidY(broken)));
    Check(SPDFMacChatImageFailed(@"message-three", [NSURL URLWithString:@"https://example.com/broken.png"]),
          @"a failed load is remembered so the placeholder can say so");
    ChatClick(plain, NSMakePoint(NSMidX(broken), NSMidY(broken)));
    Check(recorder.count == 3, @"Try again fetches once more");
    [window close];
    SPDFMacChatForgetLoadedImages();
}

// The heaviest diagram the engine still draws: fourteen layers of five long-labelled nodes, every node joined to the
// next layer (400 edges, the engine's cap). It is several times wider than a chat at 11 pt, so the chat searches for
// its width as well. Each layout stops at the engine's 50 ms deadline; the chat bounds how many it starts.
static NSString* HostileDiagram(NSUInteger seed) {
    NSMutableString* fence = [NSMutableString stringWithString:@"```mermaid\nflowchart TD\n"];
    for (NSUInteger layer = 0; layer < 14; layer++)
        for (NSUInteger node = 0; node < 5; node++)
            [fence appendFormat:@"  L%lux%lu[Stage %lu step %lu of run %lu with a long label]\n", (unsigned long)layer,
                                (unsigned long)node, (unsigned long)layer, (unsigned long)node, (unsigned long)seed];
    NSUInteger edges = 0;
    for (NSUInteger layer = 0; layer + 1 < 14; layer++)
        for (NSUInteger from = 0; from < 5; from++)
            for (NSUInteger to = 0; to < 5 && edges < 400; to++, edges++)
                [fence appendFormat:@"  L%lux%lu --> L%lux%lu\n", (unsigned long)layer, (unsigned long)from,
                                    (unsigned long)layer + 1, (unsigned long)((to + seed) % 5)];
    [fence appendString:@"```\n\n"];
    return fence;
}

static void RunChatDeadlineChecks(void) {
    unsetenv("SPDF_DIAGRAM_LAYOUT_DEADLINE");
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    SPDFMarkdownDiagramResetWorkCount();
    NSDate* start = [NSDate date];
    NSAttributedString* text = SPDFMacChatMarkdownRender(HostileDiagram(0), ChatOptions(320, NO, recorder));
    NSTimeInterval one = -[start timeIntervalSinceNow];
    Check(one < 0.5, [NSString stringWithFormat:@"a hostile diagram renders within its deadline (%.3f s)", one]);
    Check(SPDFMarkdownDiagramWorkCount() <= 10,
          [NSString stringWithFormat:@"its width search stays a handful of layouts (%lu)",
                                     (unsigned long)SPDFMarkdownDiagramWorkCount()]);
    Check(ChatBlocks(text).firstObject.kind == SPDFMacChatBlockDiagram, @"and it is still drawn");
    NSMutableString* many = [NSMutableString string];
    for (NSUInteger index = 0; index < 8; index++) [many appendString:HostileDiagram(index + 1)];
    Check(many.length < 128 * 1024, @"the hostile message is within what a chat shows");
    start = [NSDate date];
    text = SPDFMacChatMarkdownRender(many, ChatOptions(320, NO, recorder));
    NSTimeInterval eight = -[start timeIntervalSinceNow];
    Check(eight < 1.5, [NSString stringWithFormat:@"eight hostile diagrams cannot hold the chat (%.3f s)", eight]);
    // Past the message's layout time the rest show their source as text (RunChatLayoutTimeChecks).
    NSString* sources = SPDFMacChatMarkdownCopyText(text, NSMakeRange(0, text.length));
    for (NSUInteger seed = 1; seed <= 8; seed++) {
        NSString* label = [NSString stringWithFormat:@"Stage 0 step 0 of run %lu with", (unsigned long)seed];
        BOOL drawn = NO;
        for (SPDFMacChatBlock* block in ChatBlocks(text)) drawn = drawn || [block.source containsString:label];
        Check(drawn || [text.string containsString:label] || [sources containsString:label],
              [NSString stringWithFormat:@"hostile diagram %lu still shows, drawn, as code or as text",
                                         (unsigned long)seed]);
    }
    // Past the engine's budgets (over 200 nodes) a diagram shows its source as code, at once.
    NSMutableString* huge = [NSMutableString stringWithString:@"```mermaid\nflowchart TD\n"];
    for (NSUInteger node = 0; node < 260; node++) [huge appendFormat:@"  N%lu --> N%lu\n", (unsigned long)node,
                                                                     (unsigned long)node + 1];
    [huge appendString:@"```"];
    start = [NSDate date];
    text = SPDFMacChatMarkdownRender(huge, ChatOptions(320, NO, recorder));
    Check(ChatBlocks(text).firstObject.kind == SPDFMacChatBlockCode && -[start timeIntervalSinceNow] < 0.5,
          @"an over-budget diagram shows as code, promptly");
    // A message far past the size a chat shows renders its start, says so, and returns promptly.
    NSString* oversized = [@"" stringByPaddingToLength:300 * 1024 withString:@"word " startingAtIndex:0];
    start = [NSDate date];
    text = SPDFMacChatMarkdownRender(oversized, ChatOptions(320, NO, recorder));
    Check(text.length < 140 * 1024 && [text.string containsString:@"Only the start of this message is shown."],
          @"an oversized message shows its first 128 KB and says so");
    Check(-[start timeIntervalSinceNow] < 2, @"an oversized message renders promptly");
}

// A two-column table of `rows` body rows, numbered so the first and last can be found.
static NSString* ChatTallTable(NSUInteger rows, NSString* tag) {
    NSMutableString* table = [NSMutableString stringWithString:@"| Name | Value |\n|---|---|\n"];
    for (NSUInteger row = 0; row < rows; row++)
        [table appendFormat:@"| %@ %lu | %lu |\n", tag, (unsigned long)row, (unsigned long)row * 7];
    return table;
}

static void RunChatTableLimitChecks(void) {
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    // A friend's 32 KB message: one table of about 2,000 rows. The chat draws its first 500 and shows the rest as
    // text, and copying gives the whole table.
    NSString* friendMessage = ChatTallTable(2000, @"row");
    Check(friendMessage.length > 30 * 1024 && friendMessage.length < 40 * 1024, @"the tall table is a friend's 32 KB");
    NSAttributedString* text = SPDFMacChatMarkdownRender(friendMessage, ChatOptions(320, NO, recorder));
    NSArray<SPDFMacChatBlock*>* blocks = ChatBlocks(text);
    Check(blocks.count == 1 && blocks.firstObject.kind == SPDFMacChatBlockTable, @"the tall table is still drawn");
    NSArray* drawnLines = [blocks.firstObject.source componentsSeparatedByString:@"\n"];
    Check(drawnLines.count == 502 && [drawnLines.lastObject hasPrefix:@"| row 499 |"],
          [NSString stringWithFormat:@"a drawn table stops at 500 rows (%lu lines)", (unsigned long)drawnLines.count]);
    Check([text.string containsString:@"Only the first 500 rows are shown as a table; the rest follow as text."],
          @"the bubble says why the table continues as text");
    Check([text.string containsString:@"| row 1999 | 13993 |"], @"the rows past the cap are shown as text");
    NSString* copied = SPDFMacChatMarkdownCopyText(text, NSMakeRange(0, text.length));
    Check([copied hasPrefix:@"| Name | Value |\n| --- | --- |\n| row 0 | 0 |"] &&
              [copied containsString:@"| row 499 | 3493 |\n| row 500 | 3500 |"] &&
              [copied hasSuffix:@"| row 1999 | 13993 |"] && ![copied containsString:@"Only the first"],
          @"copying the message gives the whole table's Markdown, without the note");
    // Cells count too: 128 columns, Markdown's widest, keep their header and 77 rows (10,000 cells).
    NSMutableString* wide = [NSMutableString string];
    for (NSUInteger row = 0; row < 102; row++) {
        for (NSUInteger column = 0; column < 128; column++) [wide appendFormat:@"| %lu ", (unsigned long)row];
        [wide appendString:@"|\n"];
        if (!row) [wide appendString:[[@"" stringByPaddingToLength:128 * 4 withString:@"|---" startingAtIndex:0]
                                         stringByAppendingString:@"|\n"]];
    }
    blocks = ChatBlocks(SPDFMacChatMarkdownRender(wide, ChatOptions(320, NO, recorder)));
    NSUInteger wideLines = [blocks.firstObject.source componentsSeparatedByString:@"\n"].count;
    Check(blocks.count == 1 && (wideLines - 1) * 128 <= 10000,
          [NSString stringWithFormat:@"a wide table draws at most 10,000 cells (%lu rows)", (unsigned long)wideLines]);

    // The security review timed a 128 KB answer of one tall table at 1.6 s and a friend's 32 KB one at 0.37 s; a
    // conversation lays out every message at once. Each now draws only its first 500 rows.
    NSString* answer = ChatTallTable(7000, @"line");
    Check(answer.length > 120 * 1024, @"the tall answer fills what a chat shows");
    NSDate* start = [NSDate date];
    text = SPDFMacChatMarkdownRender(answer, ChatOptions(320, NO, recorder));
    NSTimeInterval tall = -[start timeIntervalSinceNow];
    Check(tall < 0.5, [NSString stringWithFormat:@"a 128 KB tall table renders promptly (%.3f s)", tall]);
    start = [NSDate date];
    for (NSUInteger message = 0; message < 10; message++)
        SPDFMacChatMarkdownRender(ChatTallTable(2000, [NSString stringWithFormat:@"m%lu", (unsigned long)message]),
                                  ChatOptions(320, NO, recorder));
    NSTimeInterval ten = -[start timeIntervalSinceNow];
    // About 0.7 s on an idle machine, 2.1 s while other suites build; each render's own 0.4 s bounds it at 4 s.
    Check(ten < 3, [NSString stringWithFormat:@"ten friends' tall tables open together promptly (%.3f s)", ten]);
    Check(recorder.count == 0, @"tables fetch nothing");
}

static void RunChatBlockClickChecks(void) {
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    NSWindow* window = ChatWindow(NSMakeRect(0, 0, 500, 600));
    // Copy on a code block writes its code, and only to the pasteboard it was given.
    NSPasteboard* pasteboard = [NSPasteboard pasteboardWithUniqueName];
    SPDFMacChatMarkdownOptions* options = ChatOptions(400, NO, recorder);
    options.pasteboard = pasteboard;
    NSAttributedString* text = SPDFMacChatMarkdownRender(@"```c\nint volts = 5;\n```", options);
    NSTextView* view = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 300)];
    view.editable = NO;
    view.textContainer.lineFragmentPadding = 0;
    [window.contentView addSubview:view];
    [view.textStorage setAttributedString:text];
    NSTextAttachment* attachment = ChatAttachments(text).firstObject;
    NSRect frame = ChatAttachmentFrame(view, ChatIndexOfAttachment(text, attachment));
    NSRect copy = SPDFMacChatBlockCopyRect(ChatBlockOf(attachment));
    ChatClick(view, NSMakePoint(NSMinX(frame) + NSMidX(copy), NSMinY(frame) + NSMidY(copy)));
    Check([[pasteboard stringForType:NSPasteboardTypeString] isEqualToString:@"int volts = 5;"],
          @"Copy on a code block puts its code on the pasteboard");
    [pasteboard releaseGlobally];

    // A citation inside a table opens like one in the text.
    __block NSURL* opened = nil;
    options.openLink = ^(NSURL* URL) { opened = URL; };
    text = SPDFMacChatMarkdownRender(@"| Source |\n|---|\n| [page 2](spdf-ai://document?path=a.pdf&page=2) |", options);
    [view.textStorage setAttributedString:text];
    attachment = ChatAttachments(text).firstObject;
    SPDFMacChatBlock* block = ChatBlockOf(attachment);
    NSRange link = [block.rendered.attributedString.string rangeOfString:@"page 2"];
    NSPoint target = NSZeroPoint;
    for (CGFloat y = 1; y < NSHeight(block.contentRect) && NSEqualPoints(target, NSZeroPoint); y += 1)
        for (CGFloat x = 1; x < NSWidth(block.contentRect); x += 2) {
            NSUInteger index = SPDFMacChatBlockCharacterAtPoint(block, NSMakePoint(x, y));
            if (index != NSNotFound && NSLocationInRange(index, link)) {
                target = NSMakePoint(x, y);
                break;
            }
        }
    Check(!NSEqualPoints(target, NSZeroPoint), @"the table's citation is under some point of the block");
    frame = ChatAttachmentFrame(view, ChatIndexOfAttachment(text, attachment));
    ChatClick(view, NSMakePoint(NSMinX(frame) + target.x, NSMinY(frame) + target.y));
    Check([opened.absoluteString isEqualToString:@"spdf-ai://document?path=a.pdf&page=2"],
          @"a citation in a table opens its exact document link");
    [window close];
}
