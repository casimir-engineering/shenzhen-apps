// Shenzhen Friends views tests: Markdown render passes. A conversation lays out its whole history as one pass of
// the host (SZFriendsHost.h § Optional Markdown rendering), newest first, so a host can bound a hostile history as a
// whole; what its allowance does not cover shows as plain text, and is not asked again on the next layout.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsItemViewsInternal.h"

static const NSUInteger SZFHostileCount = 50;

// A friend's message made of many small tables: each costs the host a layout, the pattern that froze the window.
static NSString *SZFHostileMessage(NSUInteger index) {
    NSMutableString *text = [NSMutableString stringWithFormat:@"Message %02lu\n\n", (unsigned long)index];
    for (NSUInteger table = 0; table < 8; table++)
        [text appendFormat:@"| a%lu | b | c |\n|---|---|---|\n| 1 | 2 | 3 |\n\n", (unsigned long)table];
    return text;
}

static NSDictionary *SZFHostileConversation(void) {
    NSMutableDictionary *data = [SZFTestSnapshot(@"conversation-mei") mutableCopy];
    NSMutableArray *items = [NSMutableArray array];
    for (NSUInteger index = 0; index < SZFHostileCount; index++) {
        NSString *text = SZFHostileMessage(index);
        NSString *itemID = [NSString stringWithFormat:@"m_%02lu", (unsigned long)index];
        [items addObject:@{@"kind" : @"message", @"item_id" : itemID, @"direction" : @"in", @"text" : text,
                           @"text_format" : @"markdown",
                           @"segments" : @[ @{@"text" : text} ], @"time_label" : NSNull.null, @"status" : NSNull.null,
                           @"assistant_label" : NSNull.null, @"actions" : @[], @"highlighted" : @NO,
                           @"accessibility_label" : text}];
    }
    data[@"items"] = items;
    data[@"has_earlier"] = @NO;
    data[@"highlight_item_id"] = NSNull.null;
    return data;
}

static SZFriendsMessageBody *SZFBodyAt(SZFriendsConversationPage *page, NSUInteger index) {
    for (SZFriendsItemView *view in page.itemViews)
        if ([view.itemID isEqualToString:[NSString stringWithFormat:@"m_%02lu", (unsigned long)index]] &&
            [view isKindOfClass:SZFriendsMessageItemView.class])
            return ((SZFriendsMessageItemView *)view).body;
    return nil;
}

static void SZFTestHostilePass(void) {
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    host.passBudget = 10; // the stand-in for a host's 1 s: ten renders, then nil
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(NULL));
    SZFriendsConversationPage *page = [[SZFriendsConversationPage alloc] initWithContext:context
                                                                          conversationID:@"c_mei"
                                                                        highlightMessage:nil];
    page.frame = NSMakeRect(0, 0, 400, 640);
    // On screen first, as the dropdown is when the snapshot arrives, so one appearance is asked for.
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    [page applySnapshot:SZFHostileConversation()];
    [page layoutSubtreeIfNeeded];
    NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - start;
    SZFExpect(host.passBegins >= 1 && host.passBegins == host.passEnds && !host.nestedPass,
              @"each layout is one pass, opened and closed: %lu begins, %lu ends", (unsigned long)host.passBegins,
              (unsigned long)host.passEnds);
    SZFExpect(host.rendersOutsidePass == 0, @"every render inside a pass: %lu outside",
              (unsigned long)host.rendersOutsidePass);
    SZFExpect(host.renders.count == SZFHostileCount, @"each message asked once: %lu",
              (unsigned long)host.renders.count);
    NSMutableArray *newest = [NSMutableArray array];
    for (NSUInteger index = SZFHostileCount; index > SZFHostileCount - 10; index--)
        [newest addObject:SZFHostileMessage(index - 1)];
    SZFExpect([host.renderedSources isEqualToArray:newest], @"the allowance goes to the newest messages: %@",
              [host.renderedSources valueForKey:@"length"]);
    SZFriendsMessageBody *latest = SZFBodyAt(page, SZFHostileCount - 1), *oldest = SZFBodyAt(page, 0);
    SZFExpect(latest.showsMarkdown && !oldest.showsMarkdown && !oldest.plainText.hidden &&
                  [oldest.plainText.string isEqualToString:SZFHostileMessage(0)],
              @"beyond the allowance, the oldest show their plain text");
    SZFExpect(elapsed < 5, @"the views add little of their own: %.2f s", elapsed);

    NSUInteger asked = host.renders.count, passes = host.passBegins;
    page.needsLayout = YES;
    [page layoutSubtreeIfNeeded];
    [page layout];
    SZFExpect(host.renders.count == asked && host.passBegins > passes,
              @"the next layouts ask nothing again: a spent pass is not paid twice (%lu renders)",
              (unsigned long)host.renders.count);

    passes = host.passBegins;
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [page layoutSubtreeIfNeeded];
    SZFExpect(host.passBegins > passes && host.passBegins == host.passEnds && host.rendersOutsidePass == 0 &&
                  host.renders.count == asked + SZFHostileCount,
              @"an appearance change is a new pass, every message asked once more inside it: %lu renders",
              (unsigned long)host.renders.count);
    SZFExpect(SZFBodyAt(page, SZFHostileCount - 1).showsMarkdown && !SZFBodyAt(page, 0).showsMarkdown,
              @"again the newest drawn, the oldest plain");
}

// A live resize of 1 pt steps over the hostile history: each step lays the last renderings out again at the new width
// and asks the host nothing (each used to be a whole pass, about 1.5 s with ShenzhenPDF's renderer); once the width
// settles, one pass renders every message at it.
static void SZFTestResizeKeepsRenders(void) {
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    host.passBudget = 10;
    host.renderCost = 0.03; // ten renders: 0.3 s a pass
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(NULL));
    SZFTestClock *clock = [SZFTestClock new];
    SZFTestInstallClock(context, clock);
    SZFriendsConversationPage *page = [[SZFriendsConversationPage alloc] initWithContext:context
                                                                          conversationID:@"c_mei"
                                                                        highlightMessage:nil];
    page.frame = NSMakeRect(0, 0, 400, 640);
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [page applySnapshot:SZFHostileConversation()];
    [page layoutSubtreeIfNeeded];
    NSUInteger asked = host.renders.count, scheduled = clock.blocks.count;
    SZFriendsMessageBody *latest = SZFBodyAt(page, SZFHostileCount - 1);
    CGFloat wide = NSWidth(latest.frame);
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    for (CGFloat width = 399; width >= 390; width--) {
        page.frame = NSMakeRect(0, 0, width, 640);
        [page layoutSubtreeIfNeeded];
    }
    NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - start;
    SZFExpect(host.renders.count == asked && host.rendersOutsidePass == 0,
              @"ten 1 pt resizes ask the host nothing: %lu renders", (unsigned long)(host.renders.count - asked));
    SZFExpect(elapsed < 1, @"ten 1 pt resizes take %.2f s (a pass each would be 3 s)", elapsed);
    SZFExpect(latest.showsMarkdown && !SZFBodyAt(page, 0).showsMarkdown && NSWidth(latest.frame) <= wide,
              @"the newest keep their rendering, laid out again at the new width (%.0f, was %.0f)",
              NSWidth(latest.frame), wide);
    SZFExpect(clock.blocks.count > scheduled, @"the width settling is waited for");
    clock.blocks.lastObject();
    [page layoutSubtreeIfNeeded];
    NSString *settled = [NSString stringWithFormat:@"%.0f|0", 390.0 - 28 - 40 - 22];
    NSArray *since = [host.renders subarrayWithRange:NSMakeRange(asked, host.renders.count - asked)];
    SZFExpect(since.count == SZFHostileCount && [[NSSet setWithArray:since] isEqual:[NSSet setWithObject:settled]],
              @"once settled, one pass asks each message once, at the final width: %@", [NSSet setWithArray:since]);
    SZFExpect(SZFBodyAt(page, SZFHostileCount - 1).showsMarkdown && !SZFBodyAt(page, 0).showsMarkdown,
              @"again the newest drawn, the oldest plain");
    (void)window;
}

// A host without passes renders as before, and the views never call what it lacks.
static void SZFTestNoPassHost(void) {
    SZFTestHost *plain = [SZFTestHost new];
    SZFriendsContext *context = SZFTestContext(plain, SZFTestReadyLink(NULL));
    __block NSUInteger runs = 0;
    [context markdownPass:^{
        runs++;
        [context markdownPass:^{ runs++; }];
    }];
    SZFExpect(runs == 2, @"a pass runs its layout, nested or not, with or without the host's methods");
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    SZFriendsContext *passing = SZFTestContext(host, SZFTestReadyLink(NULL));
    [passing markdownPass:^{ [passing markdownPass:^{}]; }];
    SZFExpect(host.passBegins == 1 && host.passEnds == 1 && !host.nestedPass, @"a pass inside a pass stays one");
}

void SZFTestMarkdownPasses(void) {
    SZFTestHostilePass();
    SZFTestResizeKeepsRenders();
    SZFTestNoPassHost();
}
