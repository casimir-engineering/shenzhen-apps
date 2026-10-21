// Steps and cards in the real chat view at the dock's minimum width (320 pt): what a run printed and its note under
// its code, http results after the links, a stopped step's status on its own line, folds that say what stopped, a
// 32 KiB message on a Send card, and the heading while a tool runs. Included by SPDFMacAIChatViewTests.mm after
// SPDFMacAIChatActivityViewChecks.h.
#pragma once
#import "../SPDFMacAIChatViewParts.h"

@interface RunningToolChatFixture : ActivityChatFixture
@property(nonatomic, copy) NSString* runningTool;
@property(nonatomic, copy) NSString* runningToolProgress;
@end
@implementation RunningToolChatFixture
@end

// A transcript 320 pt wide showing `activity` after one question and answer, its steps listed in `expanded` open.
static SPDFMacAIChatView* StepChat(NSWindow* window, ActivityChatFixture* fixture, NSArray* activity,
                                   NSArray<NSString*>* expanded) {
    SPDFMacAIChatView* view = [[SPDFMacAIChatView alloc] initWithFrame:window.contentView.bounds];
    window.contentView = view;
    fixture.chat = @{@"id" : NSUUID.UUID.UUIDString, @"activity" : activity, @"messages" : @[
        @{@"role" : @"user", @"content" : @"When do the brackets arrive?"},
        @{@"role" : @"assistant", @"content" : @"Friday."}]};
    [view displaySession:(id)fixture];
    SettleActivity(view);
    for (NSString* key in expanded) {
        [(NSButton*)Find(view, [@"activityToggle:" stringByAppendingString:key]) performClick:nil];
        SettleActivity(view);
    }
    return view;
}

// The captions drawn in a view's code box headers, where a code box names its language ("python").
static NSArray<NSString*>* CodeBoxCaptions(NSTextView* view) {
    NSMutableArray* captions = [NSMutableArray array];
    [view.textStorage enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, view.textStorage.length)
                                 options:0 usingBlock:^(NSTextAttachment* attachment, NSRange range, BOOL* stop) {
        (void)range; (void)stop;
        id cell = attachment.attachmentCell;
        if ([cell respondsToSelector:NSSelectorFromString(@"block")])
            [captions addObject:[cell valueForKeyPath:@"block.language"] ?: @""];
    }];
    return captions;
}

// The colours a drawn code box paints its code in, and whether it offers Copy.
static NSSet<NSString*>* CodeBoxColors(NSTextView* view, BOOL* copy) {
    NSMutableSet* colors = [NSMutableSet set];
    [view.textStorage enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, view.textStorage.length)
                                 options:0 usingBlock:^(NSTextAttachment* attachment, NSRange range, BOOL* stop) {
        (void)range; (void)stop;
        id cell = attachment.attachmentCell;
        if (![cell respondsToSelector:NSSelectorFromString(@"block")]) return;
        NSAttributedString* code = [cell valueForKeyPath:@"block.rendered.attributedString"];
        [code enumerateAttribute:NSForegroundColorAttributeName inRange:NSMakeRange(0, code.length) options:0
                      usingBlock:^(NSColor* color, NSRange run, BOOL* inner) {
            (void)inner;
            NSString* words = [[code.string substringWithRange:run]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSColor* ink = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            if (words.length && ink) [colors addObject:[NSString stringWithFormat:@"%.3f %.3f %.3f", ink.redComponent,
                                                        ink.greenComponent, ink.blueComponent]];
        }];
        for (id control in [cell accessibilityChildren])
            if (copy && [[control accessibilityLabel] isEqual:@"Copy code"]) *copy = YES;
    }];
    return colors;
}

// D1: the code in the code box, what it printed in a plain box of its own, and the note in text the width can wrap.
static void CheckStepOutputAndNote(void) {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 1200)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSString* printed = [@"for month in range(3): 0 1 2 if True else None\n"
        stringByAppendingString:[@"total " stringByPaddingToLength:160 withString:@"9" startingAtIndex:0]];
    NSString* note = @"Charts aren’t shown for requests that include your Friends chats.";
    NSDictionary* run = @{@"id" : @"P", @"kind" : @"step", @"after" : @1, @"title" : @"Ran Python", @"state" : @"done",
        @"status" : @"Finished in 1.2 s", @"detailStyle" : @"python",
        @"detail" : @"for month in range(3):\n    print(month, 'if True else None')", @"output" : printed,
        @"note" : note};
    SPDFMacAIChatView* view = StepChat(window, [ActivityChatFixture new], @[run], @[@"P"]);
    SPDFMacChatMarkdownView* code = (SPDFMacChatMarkdownView*)Find(view, @"activityDetail:P");
    SPDFMacChatMarkdownView* output = (SPDFMacChatMarkdownView*)Find(view, @"activityOutput:P");
    NSTextField* line = (NSTextField*)Find(view, @"activityNote:P");
    NSString* shown = [output isKindOfClass:SPDFMacChatMarkdownView.class] ?
        SPDFMacChatMarkdownCopyText(output.textStorage, NSMakeRange(0, output.textStorage.length)) : nil;
    NSString* source = [code isKindOfClass:SPDFMacChatMarkdownView.class] ?
        SPDFMacChatMarkdownCopyText(code.textStorage, NSMakeRange(0, code.textStorage.length)) : nil;
    BOOL copy = NO;
    NSSet* inks = output ? CodeBoxColors(output, &copy) : nil, *codeInks = code ? CodeBoxColors(code, NULL) : nil;
    Check([shown containsString:printed] && ![source containsString:@"total 999"] && ![source containsString:note] &&
          output.wideBlocks.count == 1 && copy,
          @"what a run printed has its own code box, unwrapped, with Copy, apart from the code");
    Check(codeInks.count > 1 && inks.count == 1,
          [NSString stringWithFormat:@"printed output is one colour (%lu), while the code above it is coloured as "
                                     "Python (%lu)", (unsigned long)inks.count, (unsigned long)codeInks.count]);
    Check([CodeBoxCaptions(output) isEqual:@[@"output"]] && [CodeBoxCaptions(code) isEqual:@[@"python"]],
          @"the output box is captioned output in its header, where the code box above it says python");
    NSView* transcript = [(NSScrollView*)[view valueForKey:@"scroll"] documentView];
    NSRect column = InTranscript([view valueForKey:@"messages"], transcript), placed = InTranscript(line, transcript);
    Check([line.stringValue isEqual:note] && line.maximumNumberOfLines == 0 && line.font.pointSize == 12 &&
          SameColor(line.textColor, SPDFCollectionColor(@"secondary")) && NSHeight(line.frame) > 20 &&
          NSMaxX(placed) <= NSMaxX(column) + .5 && NSMinY(placed) >= NSMaxY(InTranscript(output, transcript)) - 1 &&
          NSMinY(InTranscript(output, transcript)) >= NSMaxY(InTranscript(code, transcript)) - 1,
          @"a step's note wraps in 12 pt secondary text under what it printed, never inside the code box");
    // print() ends its output with a line break, which left an empty last line inside the box.
    CGFloat heights[2] = {0, 0};
    for (int ended = 0; ended < 2; ended++) {
        NSMutableDictionary* step = [run mutableCopy];
        step[@"output"] = ended ? @"Total: 42\n" : @"Total: 42";
        [step removeObjectForKey:@"note"];
        heights[ended] = NSHeight(Find(StepChat(window, [ActivityChatFixture new], @[step], @[@"P"]),
                                       @"activityOutput:P").frame);
    }
    Check(heights[0] > 0 && fabs(heights[1] - heights[0]) < .5,
          [NSString stringWithFormat:@"output ending in a line break is no taller than without it (%.1f, %.1f)",
                                     heights[1], heights[0]]);
    window.contentView = [NSView new];
}

// An http search result is listed after the links, never as one, and says why on a line of its own: beside the
// title and host, "not a secure page" squeezed both to a few letters at 320 pt. A short host stays whole.
static void CheckInsecureResults(void) {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 700)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSString* old = @"Old supplier delivery dates for every bracket order";
    NSDictionary* search = @{@"id" : @"W", @"kind" : @"step", @"after" : @1, @"title" : @"Searched the web",
        @"state" : @"done", @"status" : @"2 results", @"detail" : @"“bracket supplier dates”", @"links" : @[
            @{@"url" : @"http://old-supplier.example/dates", @"title" : old, @"host" : @"old-supplier.example"},
            @{@"url" : @"https://meilin.example/schedule", @"title" : @"Delivery schedule",
              @"host" : @"meilin.example"}]};
    SPDFMacAIChatView* view = StepChat(window, [ActivityChatFixture new], @[search], @[@"W"]);
    NSStackView* links = (NSStackView*)Find(view, @"activityLinks:W");
    NSArray<NSStackView*>* lines = [links isKindOfClass:NSStackView.class] ? (id)links.arrangedSubviews : nil;
    NSArray* both = lines.count == 2 ? lines[1].arrangedSubviews : nil;
    NSStackView* row = both.count == 2 && [both[0] isKindOfClass:NSStackView.class] ? both[0] : nil;
    NSArray* parts = row.arrangedSubviews;
    NSTextView* secure = lines.count == 2 ? (NSTextView*)lines[0].arrangedSubviews[0] : nil;
    NSTextView* title = parts.count == 3 ? parts[0] : nil;
    NSTextField* host = parts.count == 3 ? parts[1] : nil, *warning = both.count == 2 ? both[1] : nil;
    __block BOOL linked = NO;
    [title.textStorage enumerateAttributesInRange:NSMakeRange(0, title.textStorage.length) options:0
                                       usingBlock:^(NSDictionary* attributes, NSRange range, BOOL* stop) {
        (void)range; (void)stop;
        linked |= attributes[NSLinkAttributeName] || attributes[NSToolTipAttributeName];
    }];
    Check([secure.string isEqual:@"Delivery schedule"] && [title.string isEqual:old] && !linked &&
          [host.stringValue isEqual:@"old-supplier.example"] && [warning.stringValue isEqual:@"Not a secure page"] &&
          SameColor(host.textColor, SPDFCollectionColor(@"secondary")) &&
          SameColor(warning.textColor, SPDFCollectionColor(@"secondary")) &&
          SameColor([title.textStorage attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:nil],
                    SPDFCollectionColor(@"text")),
          @"an http result follows the https links as plain text, its title and host, then not a secure page");
    NSView* transcript = [(NSScrollView*)[view valueForKey:@"scroll"] documentView];
    NSRect list = InTranscript(links, transcript), said = InTranscript(warning, transcript);
    NSRect named = InTranscript(title, transcript), site = InTranscript(host, transcript);
    Check(warning && NSWidth(warning.frame) >= warning.intrinsicContentSize.width - .5 &&
          NSMinY(said) >= NSMaxY(named) - .5 && NSMinY(said) >= NSMaxY(site) - .5 && NSMaxX(said) <= NSMaxX(list) + .5,
          @"at 320 pt \"Not a secure page\" is whole, on its own line under the title and host");
    Check(host && NSWidth(host.frame) >= host.intrinsicContentSize.width - .5 && NSMaxX(site) <= NSMaxX(list) + .5 &&
          NSMaxX(named) <= NSMinX(site) && NSWidth(title.frame) >= 59 &&
          NSWidth(title.frame) < [title.textStorage size].width,
          @"at 320 pt a short host keeps its natural width, and the long title truncates before it");
    window.contentView = [NSView new];
}

// A PDF the assistant downloaded is a second row under its page, "Open in ShenzhenPDF", a link to the app's own copy
// (SPDFMacAIWebPDF.h): no host beside it, no address as its tooltip, and a click goes to the chat's link handler.
static void CheckDownloadedPDFRow(void) {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 600)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSString* app = @"spdf-ai://web-document?id=42439C23-F36B-46D3-9AC7-9110B46AB1A8&"
                     "web=https://datasheet.example/ds.pdf";
    NSDictionary* opened = @{@"id" : @"D", @"kind" : @"step", @"after" : @1, @"title" : @"Opened datasheet.example",
        @"state" : @"done", @"detail" : @"A PDF of 8 pages.", @"links" : @[
            @{@"url" : @"https://datasheet.example/ds.pdf", @"title" : @"BM28 Series Catalog",
              @"host" : @"datasheet.example"},
            @{@"url" : app, @"title" : @"Open in ShenzhenPDF", @"host" : @""}]};
    SPDFMacAIChatView* view = StepChat(window, [ActivityChatFixture new], @[opened], @[@"D"]);
    __block NSURL* clicked = nil;
    view.openLink = ^(NSURL* URL) { clicked = URL; };
    NSStackView* links = (NSStackView*)Find(view, @"activityLinks:D");
    NSArray<NSStackView*>* lines = [links isKindOfClass:NSStackView.class] ? (id)links.arrangedSubviews : nil;
    NSTextView* open = lines.count == 2 ? (NSTextView*)lines[1].arrangedSubviews[0] : nil;
    NSURL* target = open.string.length ? [open.textStorage attribute:NSLinkAttributeName atIndex:0 effectiveRange:nil]
                                       : nil;
    Check([open.string isEqual:@"Open in ShenzhenPDF"] && [target.absoluteString isEqual:app] &&
          lines[1].arrangedSubviews.count == 2 &&
          [[open.textStorage attribute:NSToolTipAttributeName atIndex:0 effectiveRange:nil]
              isEqual:@"Open in ShenzhenPDF"],
          @"a downloaded PDF's step offers Open in ShenzhenPDF as a link, without a host or an app address");
    if (target) [(id<NSTextViewDelegate>)open.delegate textView:open clickedOnLink:target atIndex:0];
    Check([clicked.absoluteString isEqual:app], @"and a click on it reaches the chat's link handler");
    window.contentView = [NSView new];
}

// A step that stopped or ran out of time says so whole, under its title, as a failure does: beside the title its
// status shrank to a few letters at 320 pt.
static void CheckStoppedStatusLine(void) {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 600)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSDictionary* stopped = @{@"id" : @"X", @"kind" : @"step", @"after" : @1, @"state" : @"stopped",
        @"title" : @"Page on supplier-portal.example", @"status" : @"Stopped before the page finished loading"};
    SPDFMacAIChatView* view = StepChat(window, [ActivityChatFixture new], @[stopped], @[]);
    NSView* transcript = [(NSScrollView*)[view valueForKey:@"scroll"] documentView];
    NSTextField* status = (NSTextField*)Find(view, @"activityStatus:X");
    NSRect title = InTranscript(Find(view, @"activityTitle:X"), transcript);
    NSRect column = InTranscript([view valueForKey:@"messages"], transcript);
    Check(status && status.maximumNumberOfLines == 0 && NSMinY(InTranscript(status, transcript)) >= NSMaxY(title) - 1 &&
          NSHeight(status.frame) >= status.intrinsicContentSize.height - .5 &&
          NSMaxX(InTranscript(status, transcript)) <= NSMaxX(column) + .5 &&
          SameColor(status.textColor, SPDFCollectionColor(@"secondary")),
          @"a stopped step's status wraps whole under its title, in the secondary colour");
    NSDictionary* python = @{@"id" : @"Y", @"kind" : @"step", @"after" : @1, @"state" : @"stopped",
        @"title" : @"Python run stopped", @"status" : @"Stopped", @"detailStyle" : @"python", @"detail" : @"print(1)"};
    view = StepChat(window, [ActivityChatFixture new], @[python], @[]);
    Check(Find(view, @"activityTitle:Y") && !Find(view, @"activityStatus:Y"),
          @"a status the title already ends with (\"Stopped\" under \"Python run stopped\") isn't repeated");
    window.contentView = [NSView new];
}

// A fold of finished steps says how many of them stopped, whole, before its titles give way: folded, they read as
// done work.
static void CheckFoldSaysStopped(void) {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 600)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSMutableArray* steps = [NSMutableArray array];
    for (NSString* key in @[@"A", @"B", @"C"])
        [steps addObject:@{@"id" : key, @"kind" : @"step", @"after" : @1, @"state" : @"stopped",
                           @"title" : @"Check the bracket drawing against the supplier’s dates",
                           @"status" : @"Stopped"}];
    SPDFMacAIChatView* view = StepChat(window, [ActivityChatFixture new], steps, @[]);
    NSTextField* count = (NSTextField*)Find(view, @"activityTitle:fold:A");
    Check([count.stringValue isEqual:@"3 steps · 3 stopped"] &&
          NSWidth(count.frame) >= count.intrinsicContentSize.width - .5,
          @"a fold of stopped steps says so, whole, at 320 pt");
    NSMutableDictionary* done = [steps[0] mutableCopy];
    done[@"state"] = @"done";
    done[@"status"] = @"3 results";
    view = StepChat(window, [ActivityChatFixture new], @[done, steps[1]], @[]);
    count = (NSTextField*)Find(view, @"activityTitle:fold:A");
    Check([count.stringValue isEqual:@"2 steps · 1 stopped"], @"a fold counts only the steps that stopped");
    window.contentView = [NSView new];
}

// E2: a Send card holds Friends' whole 32 KiB, and the person sees it quickly at the dock's narrowest.
static void CheckLongLiteralCard(void) {
    NSMutableString* message = [NSMutableString string];
    NSString* line = @"Delivery for order 4471 moves to Friday; 交货日期改到星期五，请确认。\n";
    while ([message lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + [line lengthOfBytesUsingEncoding:
               NSUTF8StringEncoding] <= 32768) [message appendString:line];
    while ([message lengthOfBytesUsingEncoding:NSUTF8StringEncoding] < 32768) [message appendString:@"a"];
    NSDictionary* entry = SPDFMacAIActivitySanitizedEntry(@{@"id" : @"L", @"kind" : @"card", @"after" : @0,
        @"title" : @"Message for Mei", @"cardKind" : @"friends.send", @"state" : @"running", @"body" : message,
        @"status" : @"Not sent yet. Check it, then press Send."});
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 900)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSView* host = [[SPDFChatFlippedView alloc] initWithFrame:window.contentView.bounds];
    window.contentView = host;
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    SPDFMacAIChatActivityRow* row = [[SPDFMacAIChatActivityRow alloc]
        initWithUnit:@{@"entry" : entry ?: @{}, @"actions" : @[]} expanded:[NSSet set] width:280];
    [host addSubview:row];
    [row.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:16].active = YES;
    [row.topAnchor constraintEqualToAnchor:host.topAnchor].active = YES;
    [row.widthAnchor constraintEqualToConstant:280].active = YES;
    [host layoutSubtreeIfNeeded];
    // The text measures itself again once laid out at its width (SPDFChatMessageView), on the next turn.
    for (int turn = 0; turn < 2; turn++)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.001]];
    [host layoutSubtreeIfNeeded];
    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - start;
    NSTextView* body = (NSTextView*)Find(row, @"activityBody:L");
    NSRect used = [body.layoutManager usedRectForTextContainer:body.textContainer];
    Check(entry && [body.string isEqual:message] && body.layoutManager.firstUnlaidCharacterIndex == message.length &&
          NSMaxY(used) + 2 * body.textContainerInset.height <= NSHeight(body.bounds) + .5,
          @"a 32 KiB message shows whole on its Send card");
    fprintf(stderr, "32 KiB Send card laid out at 320 pt in %.3f s\n", elapsed);
    Check(elapsed < .3, [NSString stringWithFormat:@"a 32 KiB Send card lays out at 320 pt in %.3f s (at most 0.3)",
                                                   elapsed]);
    window.contentView = [NSView new];
}

// D6: while a tool runs the heading is "Working…" and says what the tool does in the person's words, never its name.
static void CheckRunningToolHeading(void) {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 600)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    SPDFMacAIChatView* view = [[SPDFMacAIChatView alloc] initWithFrame:window.contentView.bounds];
    window.contentView = view;
    RunningToolChatFixture* fixture = [RunningToolChatFixture new];
    fixture.chat = @{@"id" : @"working", @"messages" : @[@{@"role" : @"user", @"content" : @"Compare suppliers"}]};
    fixture.running = YES;
    fixture.activityState = SPDFMacAIChatActivityWorking;
    NSDictionary* words = @{@"web_search" : @"Searching the web…", @"open_page" : @"Reading a page…",
        @"run_python" : @"Running Python…", @"run_subagents" : @"Working on parts…",
        @"friends_send_message" : @"Preparing a message…", @"friends_read_messages" : @"Reading your Friends chat…"};
    NSString* (^heading)(NSString*) = ^NSString*(NSString* tool) {
        fixture.runningTool = tool;
        fixture.status = @"Working…";  // as SPDFMacAIChatSession says while a tool runs
        fixture.activityDetail = fixture.status;
        [view refreshActivityFromSession:(id)fixture];
        return [(NSTextField*)Find(view, @"chatActivityDetail") stringValue];
    };
    BOOL worded = YES;
    for (NSString* tool in words) worded &= [heading(tool) isEqual:words[tool]];
    Check(worded && [[(NSTextField*)Find(view, @"chatStatus") stringValue] isEqual:@"Working…"],
          @"while a tool runs the heading says Working… and what it does, as the person would say it");
    NSString* unknown = heading(@"mystery_tool");
    BOOL plain = YES;
    for (NSString* tool in @[@"search_documents", @"read_pages", @"render_page", @"list_chats", @"web_search"])
        plain &= [SPDFChatRunningToolText(tool) hasSuffix:@"…"] && ![SPDFChatRunningToolText(tool) containsString:@"_"];
    Check(!unknown.length && plain, @"a tool without words shows none, never its name; every wording ends in …");
    // A run of parts says how many there are and how many have ended, in place of its usual words.
    fixture.runningToolProgress = @"Working on 3 parts, 1 finished…";
    NSString* parts = heading(@"run_subagents");
    fixture.runningToolProgress = nil;
    Check([parts isEqual:@"Working on 3 parts, 1 finished…"] &&
          [heading(@"run_subagents") isEqual:@"Working on parts…"],
          @"while parts work the heading says how many and how many have finished; without that, its usual words");
    fixture.runningTool = nil;
    fixture.activityDetail = @"Undoing…";
    [view refreshActivityFromSession:(id)fixture];
    Check([[(NSTextField*)Find(view, @"chatActivityDetail") stringValue] isEqual:@"Undoing…"],
          @"work that is no tool (Undo) keeps its own words");
    window.contentView = [NSView new];
}

static void RunChatActivityStepChecks(void) {
    CheckStepOutputAndNote();
    CheckInsecureResults();
    CheckDownloadedPDFRow();
    CheckStoppedStatusLine();
    CheckFoldSaysStopped();
    CheckLongLiteralCard();
    CheckRunningToolHeading();
}
