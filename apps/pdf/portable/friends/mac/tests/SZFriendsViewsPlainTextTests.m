// Shenzhen Friends views tests: messages shown as plain text. Plain text is what a hostile history falls back to once
// the host's Markdown allowance is spent, so it must be cheap itself: measured once per width and appearance by the
// text view that draws it, and laid out only to its first 4,096 characters until the person presses Show all.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsItemViewsInternal.h"

static const NSUInteger SZFLongCount = 50;

// About the protocol's largest message (32,768 bytes): small tables, the pattern that froze the window, here past the
// allowance so every one shows as plain text.
static NSString *SZFLongMessage(NSUInteger index) {
    NSMutableString *text = [NSMutableString stringWithFormat:@"Message %02lu\n\n", (unsigned long)index];
    while (text.length < 32 * 1024 - 64)
        [text appendFormat:@"| a%lu | b | c |\n|---|---|---|\n| 1 | 2 | 3 |\n\n", (unsigned long)text.length];
    return text;
}

static NSDictionary *SZFLongItem(NSUInteger index, NSDictionary *status) {
    NSString *text = SZFLongMessage(index);
    return @{@"kind" : @"message", @"item_id" : [NSString stringWithFormat:@"m_%02lu", (unsigned long)index],
             @"direction" : status ? @"out" : @"in", @"text" : text, @"text_format" : @"markdown",
             @"segments" : @[ @{@"text" : text} ], @"time_label" : NSNull.null, @"status" : status ?: NSNull.null,
             @"assistant_label" : NSNull.null, @"actions" : @[], @"highlighted" : @NO, @"accessibility_label" : text};
}

static NSDictionary *SZFConversationOf(NSArray *items) {
    NSMutableDictionary *data = [SZFTestSnapshot(@"conversation-mei") mutableCopy];
    data[@"items"] = items;
    data[@"has_earlier"] = @NO;
    data[@"highlight_item_id"] = NSNull.null;
    return data;
}

// A Ready link with the catalog's Show all, or without it (a helper from before the string).
static SZFriendsHelperLink *SZFLinkWithShowAll(NSString *_Nullable words) {
    SZFTestTransport *transport = nil;
    SZFriendsHelperLink *link = SZFTestReadyLink(&transport);
    NSMutableDictionary *welcome = [SZFTestFrame(@"frames/welcome") mutableCopy];
    NSMutableDictionary *strings = [welcome[@"strings"] mutableCopy];
    strings[@"show_all"] = words;
    welcome[@"strings"] = strings;
    [transport deliver:welcome];
    return link;
}

static SZFriendsMessageItemView *SZFItemAt(SZFriendsConversationPage *page, NSUInteger index) {
    NSString *itemID = [NSString stringWithFormat:@"m_%02lu", (unsigned long)index];
    for (SZFriendsItemView *view in page.itemViews)
        if ([view.itemID isEqualToString:itemID] && [view isKindOfClass:SZFriendsMessageItemView.class])
            return (SZFriendsMessageItemView *)view;
    return nil;
}

static SZFriendsConversationPage *SZFPlainPage(SZFriendsContext *context, NSWindow **window) {
    SZFriendsConversationPage *page = [[SZFriendsConversationPage alloc] initWithContext:context
                                                                          conversationID:@"c_mei"
                                                                        highlightMessage:nil];
    page.frame = NSMakeRect(0, 0, 400, 640);
    *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    return page;
}

// Fifty 32 KB messages past the allowance open, and take the next snapshot, each within a fixed total; a label
// measured twice per layout took about a minute for the same conversation.
static void SZFTestFallbackCost(void) {
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    host.passBudget = 0; // the host's allowance is spent: every render answers nil
    SZFriendsContext *context = SZFTestContext(host, SZFLinkWithShowAll(@"Show all"));
    NSWindow *window = nil;
    SZFriendsConversationPage *page = SZFPlainPage(context, &window);
    NSMutableArray *items = [NSMutableArray array];
    for (NSUInteger index = 0; index < SZFLongCount; index++) [items addObject:SZFLongItem(index, nil)];
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    [page applySnapshot:SZFConversationOf(items)];
    [page layoutSubtreeIfNeeded];
    (void)SZFTestBitmap(page); // and drawn, as opening shows the newest at once
    NSTimeInterval opened = NSProcessInfo.processInfo.systemUptime - start;
    SZFExpect(opened < 3, @"fifty 32 KB plain messages open within 3 s: %.2f s", opened);
    SZFriendsMessageBody *oldest = SZFItemAt(page, 0).body;
    NSString *shown = oldest.plainText.string;
    SZFExpect(!oldest.showsMarkdown && !oldest.plainText.hidden && shown.length <= 4096 && shown.length > 3800 &&
                  [SZFLongMessage(0) hasPrefix:shown],
              @"a long message shows its first 4,096 characters as written: %lu", (unsigned long)shown.length);
    SZFExpect(!oldest.showAllButton.hidden && [oldest.showAllButton.title isEqualToString:@"Show all"],
              @"with the catalog's Show all under them");

    items[SZFLongCount - 1] = SZFLongItem(SZFLongCount - 1, @{@"state" : @"delivered", @"label" : @"Delivered"});
    start = NSProcessInfo.processInfo.systemUptime;
    [page applySnapshot:SZFConversationOf(items)];
    [page layoutSubtreeIfNeeded];
    (void)SZFTestBitmap(page);
    NSTimeInterval next = NSProcessInfo.processInfo.systemUptime - start;
    SZFExpect(next < 3, @"the next snapshot, one status changed, within 3 s: %.2f s", next);
    SZFExpect(host.renders.count == SZFLongCount, @"the spent allowance is not asked again: %lu renders",
              (unsigned long)host.renders.count);
}

// Show all lays the rest out in place and the bubble grows; the next snapshot keeps it whole. Without the catalog's
// words nothing is cut, since the person would have no way to read on.
static void SZFTestShowAll(void) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFLinkWithShowAll(@"Show all"));
    NSWindow *window = nil;
    SZFriendsConversationPage *page = SZFPlainPage(context, &window);
    NSDictionary *snapshot = SZFConversationOf(@[ SZFLongItem(1, nil) ]);
    [page applySnapshot:snapshot];
    [page layoutSubtreeIfNeeded];
    SZFriendsMessageItemView *item = SZFItemAt(page, 1);
    SZFriendsMessageBody *body = item.body;
    NSString *message = SZFLongMessage(1), *shown = body.plainText.string;
    NSCharacterSet *spaces = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    SZFExpect(shown.length < message.length && [message hasPrefix:shown] &&
                  [spaces characterIsMember:[message characterAtIndex:shown.length]],
              @"cut where a word ends, at %lu", (unsigned long)shown.length);
    SZFriendsButton *button = body.showAllButton;
    SZFExpect(!button.hidden && NSMinY(button.frame) >= NSMaxY(body.plainText.frame) &&
                  NSMaxY(button.frame) <= NSHeight(body.bounds) + 0.5 &&
                  SZFTestMissedHits(button, window.contentView) == 0,
              @"Show all sits under the text, inside the bubble, and takes its clicks: %@",
              NSStringFromRect(button.frame));
    NSLayoutManager *layout = body.plainText.layoutManager;
    NSRect used = [layout usedRectForTextContainer:body.plainText.textContainer];
    SZFExpect(NSHeight(body.plainText.frame) >= ceil(NSHeight(used)) &&
                  NSWidth(body.plainText.frame) >= MIN(ceil(NSWidth(used)), body.plainText.textContainer.size.width),
              @"the text's frame holds what its own layout drew: %@ for %@", NSStringFromRect(body.plainText.frame),
              NSStringFromRect(used));
    // For the eye: the end of the cut text and Show all, as opening the conversation shows them.
    for (NSAppearanceName name in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        window.appearance = [NSAppearance appearanceNamed:name];
        [page layoutSubtreeIfNeeded];
        NSString *file = [name isEqualToString:NSAppearanceNameAqua] ? @"conversation-show-all-light"
                                                                     : @"conversation-show-all-dark";
        SZFExpect(SZFTestRender(window.contentView, file, 2) != nil, @"%@ rendered", file);
    }
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    CGFloat before = NSHeight(item.frame);
    [button performClick:nil];
    [page layoutSubtreeIfNeeded];
    SZFExpect([body.plainText.string isEqualToString:message] && body.showAllButton.hidden &&
                  NSHeight(item.frame) > before * 4,
              @"Show all shows the whole message and the bubble grows: %.0f -> %.0f", before, NSHeight(item.frame));
    [page applySnapshot:snapshot];
    [page layoutSubtreeIfNeeded];
    SZFExpect([body.plainText.string isEqualToString:message], @"the next snapshot keeps it whole");

    SZFriendsContext *older = SZFTestContext([SZFTestHost new], SZFLinkWithShowAll(nil));
    SZFriendsConversationPage *unworded = SZFPlainPage(older, &window);
    [unworded applySnapshot:snapshot];
    [unworded layoutSubtreeIfNeeded];
    SZFriendsMessageBody *whole = SZFItemAt(unworded, 1).body;
    SZFExpect([whole.plainText.string isEqualToString:message] && whole.showAllButton.hidden,
              @"without the catalog's words the whole message shows");
}

// Short messages keep the size the label gave them: one line's height, and a narrow bubble for a short line.
static void SZFTestPlainSize(void) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    NSDictionary *item = @{@"kind" : @"message", @"item_id" : @"m_short", @"direction" : @"in", @"text" : @"Hi",
                           @"segments" : @[ @{@"text" : @"Hi"} ], @"time_label" : NSNull.null,
                           @"status" : NSNull.null, @"actions" : @[], @"highlighted" : @NO,
                           @"accessibility_label" : @"Hi"};
    SZFriendsMessageItemView *view = (SZFriendsMessageItemView *)[SZFriendsItemView viewForItem:item context:context];
    NSSize size = [view.body sizeForPlainWidth:258 markdownWidth:310];
    NSTextField *label = [NSTextField wrappingLabelWithString:@"Hi"];
    label.font = context.appearance.bodyFont;
    NSSize cell = [label.cell cellSizeForBounds:NSMakeRect(0, 0, 258, CGFLOAT_MAX)];
    SZFExpect(fabs(size.width - ceil(cell.width)) < 0.5 && fabs(size.height - ceil(cell.height)) < 0.5,
              @"\"Hi\" measures as the label did: %@ vs %@", NSStringFromSize(size), NSStringFromSize(cell));
}

static NSDictionary *SZFPlainItem(NSString *itemID, NSString *text) {
    return @{@"kind" : @"message", @"item_id" : itemID, @"direction" : @"in", @"text" : text,
             @"segments" : @[ @{@"text" : text} ], @"time_label" : NSNull.null, @"status" : NSNull.null,
             @"actions" : @[], @"highlighted" : @NO, @"accessibility_label" : text};
}

static NSSize SZFPlainBodySize(SZFriendsContext *context, NSString *text) {
    SZFriendsMessageItemView *view =
        (SZFriendsMessageItemView *)[SZFriendsItemView viewForItem:SZFPlainItem(@"m_size", text) context:context];
    return [view.body sizeForPlainWidth:258 markdownWidth:310];
}

// A final line break draws nothing: the bubble keeps the width and height of the text without it, and so does a
// long message of short lines once Show all shows it whole, line break and all.
static void SZFTestTrailingLineBreak(void) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFLinkWithShowAll(@"Show all"));
    NSSize plain = SZFPlainBodySize(context, @"See you Friday.");
    NSSize broken = SZFPlainBodySize(context, @"See you Friday.\n");
    SZFExpect(NSEqualSizes(plain, broken) && plain.width < 200,
              @"'See you Friday.' with a final line break is as wide and tall as without: %@ vs %@",
              NSStringFromSize(broken), NSStringFromSize(plain));
    NSMutableString *lines = [NSMutableString string];
    while (lines.length < 6000) [lines appendString:@"Short line\n"];
    NSWindow *window = nil;
    SZFriendsConversationPage *page = SZFPlainPage(context, &window);
    [page applySnapshot:SZFConversationOf(@[ SZFPlainItem(@"m_07", lines) ])];
    [page layoutSubtreeIfNeeded];
    SZFriendsMessageBody *body = SZFItemAt(page, 7).body;
    CGFloat cutWidth = NSWidth(body.frame);
    [body.showAllButton performClick:nil];
    [page layoutSubtreeIfNeeded];
    NSSize whole = SZFPlainBodySize(context, [lines substringToIndex:lines.length - 1]);
    SZFExpect([body.plainText.string isEqualToString:lines] && fabs(NSWidth(body.frame) - whole.width) < 0.5 &&
                  NSWidth(body.frame) <= cutWidth + 0.5 && NSWidth(body.frame) < 200,
              @"Show all keeps the bubble as narrow as its lines: %.0f, cut %.0f, without the line break %.0f",
              NSWidth(body.frame), cutWidth, whole.width);
}

void SZFTestPlainText(void) {
    SZFTestPlainSize();
    SZFTestTrailingLineBreak();
    SZFTestShowAll();
    SZFTestFallbackCost();
}
