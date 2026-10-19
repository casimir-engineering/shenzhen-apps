// Shenzhen Friends views tests: Markdown bubbles (the host renders, the views fall back to plain segments, wide
// blocks scroll inside the bubble, copy keeps the source), "Via the assistant", and Cancel on a queued send.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsItemViewsInternal.h"

static NSString *const SZFRichSource = @"## Delivery\nUse **bold** text and $E=mc^2$ here, see "
                                       @"[the plan](https://example.com/plan) or [this](file:///etc/hosts).\n"
                                       @"| Item | Supplier | Delivery date | Status |\n|---|---|---|---|\n"
                                       @"| Brackets | Mei Lin Fabrication | Friday 16 October | Confirmed |\n"
                                       @"| Panels | Kenji Works | Monday 19 October | Waiting |";

// The conversation's scroll view, as far as a strip can tell: it counts the wheel events handed to it.
@interface SZFTestRecordingScrollView : NSScrollView
@property(nonatomic) NSUInteger wheels;
@end
@implementation SZFTestRecordingScrollView
- (void)scrollWheel:(NSEvent *)event {
    (void)event;
    self.wheels += 1;
}
@end

// Stands in for the dropdown, which takes Escape from whatever has focus inside it.
@interface SZFTestEscapeRecorder : NSView <SZFriendsEscapeHandling>
@property(nonatomic) NSUInteger escapes;
@end
@implementation SZFTestEscapeRecorder
- (void)friendsHandleEscape {
    self.escapes += 1;
}
@end

// A block drawn and clicked through its cell, with no image or bounds of its own, as a host may draw a table.
@interface SZFTestBlockCell : NSTextAttachmentCell
@property(nonatomic) NSUInteger clicks;
@property(nonatomic) NSUInteger clickedIndex;
@end
@implementation SZFTestBlockCell
- (NSSize)cellSize {
    return NSMakeSize(640, 40);
}
- (NSPoint)cellBaselineOffset {
    return NSZeroPoint;
}
- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view {
    (void)view;
    [[NSColor colorWithSRGBRed:0.8 green:0.1 blue:0.1 alpha:1] setFill];
    NSRectFill(frame);
}
- (BOOL)wantsToTrackMouse {
    return YES;
}
- (BOOL)wantsToTrackMouseForEvent:(NSEvent *)event inRect:(NSRect)frame ofView:(NSView *)view
                 atCharacterIndex:(NSUInteger)index {
    (void)event, (void)frame, (void)view, (void)index;
    return YES;
}
- (BOOL)trackMouse:(NSEvent *)event inRect:(NSRect)frame ofView:(NSView *)view atCharacterIndex:(NSUInteger)index
      untilMouseUp:(BOOL)flag {
    (void)event, (void)frame, (void)view, (void)flag;
    self.clicks += 1;
    self.clickedIndex = index;
    return YES;
}
@end

static NSDictionary *SZFMessage(NSString *itemID, NSString *direction, NSString *text, NSString *format) {
    NSMutableDictionary *item = [@{@"kind" : @"message", @"item_id" : itemID, @"direction" : direction,
                                   @"text" : text, @"segments" : @[ @{@"text" : text} ], @"time_label" : @"14:32",
                                   @"status" : NSNull.null, @"actions" : @[], @"highlighted" : @NO,
                                   @"accessibility_label" : text} mutableCopy];
    if (format) item[@"text_format"] = format;
    return item;
}

static SZFriendsMessageItemView *SZFBubble(SZFriendsContext *context, NSDictionary *item, NSWindow **window,
                                           NSAppearanceName appearance) {
    SZFriendsMessageItemView *view = (SZFriendsMessageItemView *)[SZFriendsItemView viewForItem:item context:context];
    CGFloat height = [view heightForWidth:372];
    *window = SZFTestHostWindow(view, NSMakeSize(372, height), appearance);
    [view layoutSubtreeIfNeeded];
    return view;
}

// Who renders: the host for text_format markdown with Markdown in it; plain segments otherwise and as the fallback.
static void SZFTestWhoRenders(void) {
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(NULL));
    NSWindow *window = nil;
    SZFriendsMessageItemView *rich = SZFBubble(context, SZFMessage(@"m_1", @"in", SZFRichSource, @"markdown"), &window,
                                               NSAppearanceNameAqua);
    SZFExpect(rich.body.showsMarkdown && rich.body.markdownView && !rich.body.markdownView.hidden &&
                  rich.body.plainText.hidden,
              @"a Markdown message shows the host's rendering");
    SZFExpect([rich.body.markdownView.string rangeOfString:@"**"].location == NSNotFound &&
                  [rich.body.markdownView.string hasPrefix:@"Delivery"],
              @"rendered, not source: %@", rich.body.markdownView.string);
    NSUInteger before = host.renders.count;
    SZFriendsMessageItemView *plainText = SZFBubble(context, SZFMessage(@"m_2", @"in", @"On my way, see you at 3.",
                                                                        @"markdown"), &window, NSAppearanceNameAqua);
    SZFExpect(!plainText.body.showsMarkdown && host.renders.count == before,
              @"a line with nothing Markdown would change never reaches the host's engine");
    SZFriendsMessageItemView *untagged = SZFBubble(context, SZFMessage(@"m_3", @"in", @"**not** marked", nil), &window,
                                                   NSAppearanceNameAqua);
    SZFExpect(!untagged.body.showsMarkdown && [untagged.body.plainText.string isEqualToString:@"**not** marked"],
              @"no text_format: the segments as they are");
    host.refusesMarkdown = YES;
    SZFriendsMessageItemView *refused = SZFBubble(context, SZFMessage(@"m_4", @"in", @"*no renderer*", @"markdown"),
                                                  &window, NSAppearanceNameAqua);
    SZFExpect(!refused.body.showsMarkdown && !refused.body.plainText.hidden &&
                  [refused.body.plainText.string isEqualToString:@"*no renderer*"],
              @"a host that answers nil: plain segments");
    SZFTestHost *plainHost = [SZFTestHost new];
    SZFriendsContext *plainContext = SZFTestContext(plainHost, SZFTestReadyLink(NULL));
    SZFriendsMessageItemView *noMethod = SZFBubble(plainContext, SZFMessage(@"m_5", @"in", @"*x*", @"markdown"),
                                                   &window, NSAppearanceNameAqua);
    SZFExpect(!noMethod.body.showsMarkdown, @"a host without the method: plain segments");
    SZFExpect(SZFriendsTextMayBeMarkdown(@"1. first") && SZFriendsTextMayBeMarkdown(@"- item") &&
                  SZFriendsTextMayBeMarkdown(@"    code") && SZFriendsTextMayBeMarkdown(@"a `b`") &&
                  SZFriendsTextMayBeMarkdown(@"Fish &amp; chips") && SZFriendsTextMayBeMarkdown(@"> quoted") &&
                  !SZFriendsTextMayBeMarkdown(@"Pages 3-5 at 14:00, fine? 2.5 kg") &&
                  !SZFriendsTextMayBeMarkdown(@"A - B\nand C."),
              @"the plain-text test");
}

// Wide blocks scroll sideways inside the bubble; long text wraps at the bubble's width; the host renders once per
// width and appearance, and again when the appearance changes.
static void SZFTestLayoutAndCache(void) {
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(NULL));
    NSWindow *window = nil;
    SZFriendsMessageItemView *view = SZFBubble(context, SZFMessage(@"m_1", @"out", SZFRichSource, @"markdown"),
                                               &window, NSAppearanceNameAqua);
    SZFriendsMessageBody *body = view.body;
    SZFExpect(body.wideBlocks.count == 1, @"the table is one sideways strip: %lu",
              (unsigned long)body.wideBlocks.count);
    NSScrollView *strip = body.wideBlocks.firstObject;
    CGFloat content = NSWidth(strip.documentView.frame);
    SZFExpect(content > NSWidth(body.bounds) && NSMaxX(strip.frame) <= NSWidth(body.bounds) + 0.5 &&
                  NSWidth(strip.frame) >= NSWidth(body.bounds) - 1,
              @"the strip fills the bubble and its table is wider: strip %@, table %.0f, body %.0f",
              NSStringFromRect(strip.frame), content, NSWidth(body.bounds));
    SZFExpect(strip.hasHorizontalScroller && !strip.hasVerticalScroller, @"it scrolls sideways only");
    SZFExpect(NSMaxY(strip.frame) <= NSHeight(body.bounds) + 0.5 && NSHeight(strip.frame) >= 60,
              @"inside the bubble, at the table's height: %@ in %@", NSStringFromRect(strip.frame),
              NSStringFromRect(body.bounds));
    SZFExpect(NSWidth(body.frame) <= 372 - 40 - 22 + 0.5, @"within the Markdown width: %.0f", NSWidth(body.frame));
    // The bubble's colour fades in at the edge with more table beyond it, so a cut-off table never looks complete.
    NSArray<NSView *> *fades = SZFTestSubviews(strip, NSClassFromString(@"SZFriendsEdgeFade"));
    NSView *leading = fades.count == 2 ? fades[0] : nil, *trailing = fades.count == 2 ? fades[1] : nil;
    SZFExpect(leading.hidden && !trailing.hidden && NSMaxX(trailing.frame) >= NSWidth(strip.frame) - 0.5,
              @"at the start: a fade on the right only (%lu fades)", (unsigned long)fades.count);
    [strip.contentView scrollToPoint:NSMakePoint(content - NSWidth(strip.frame), 0)];
    [strip reflectScrolledClipView:strip.contentView];
    SZFExpect(NSMinX(strip.contentView.bounds) > 0, @"and scrolls to its last column");
    SZFExpect(!leading.hidden && trailing.hidden, @"at the end: a fade on the left only");

    NSUInteger light = host.renders.count;
    [view heightForWidth:372];
    [view layoutForWidth:372 apply:YES];
    SZFExpect(host.renders.count == light, @"laying out again renders nothing new: %@", host.renders);
    // Dark draws the dark rendering (asked for once per width and appearance, whichever came first), and light again
    // the light one, without asking the host a third time.
    for (NSAppearanceName name in @[ NSAppearanceNameDarkAqua, NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        window.appearance = [NSAppearance appearanceNamed:name];
        [window.contentView layoutSubtreeIfNeeded];
        NSColor *drawn = [view.body.markdownView.textStorage attribute:NSForegroundColorAttributeName atIndex:0
                                                        effectiveRange:NULL];
        uint32_t expected = [name isEqualToString:NSAppearanceNameDarkAqua] ? 0xeceef1 : 0x26282b;
        SZFExpect(SZFTestSameColor(SZFTestResolved(drawn, name), expected, 2), @"%@ draws its own colours", name);
    }
    SZFExpect([NSSet setWithArray:host.renders].count == host.renders.count && host.renders.count == 2,
              @"one rendering per width and appearance: %@", host.renders);
    strip = view.body.wideBlocks.firstObject;

    // Vertical wheel movement over the table belongs to the conversation; sideways movement to the table.
    CGEventRef vertical = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, -30, 0);
    CGEventRef sideways = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, 0, -30);
    SZFTestRecordingScrollView *conversation = [[SZFTestRecordingScrollView alloc]
        initWithFrame:NSMakeRect(0, 0, 372, 100)];
    conversation.documentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 372, 2000)];
    [view removeFromSuperview];
    [conversation.documentView addSubview:view];
    [strip scrollWheel:[NSEvent eventWithCGEvent:vertical]];
    SZFExpect(conversation.wheels == 1, @"vertical wheel over the table scrolls the history");
    [strip scrollWheel:[NSEvent eventWithCGEvent:sideways]];
    SZFExpect(conversation.wheels == 1, @"sideways wheel stays with the table");
    CFRelease(vertical);
    CFRelease(sideways);

    NSString *longText = [@"*Long* " stringByPaddingToLength:900 withString:@"words that wrap " startingAtIndex:0];
    SZFriendsMessageItemView *wrapped = SZFBubble(context, SZFMessage(@"m_2", @"in", longText, @"markdown"), &window,
                                                  NSAppearanceNameAqua);
    SZFExpect(NSWidth(wrapped.body.frame) <= 372 - 62 + 0.5 && NSHeight(wrapped.body.frame) > 80 &&
                  wrapped.body.wideBlocks.count == 0,
              @"long text wraps inside the bubble: %@", NSStringFromRect(wrapped.body.frame));
}

// Copy keeps what the friend typed: the whole message gives its source; a part, what it shows, with a formula
// whole as its source; links say where they go, and a click asks first (SZFriendsViewsLinkTests.m).
static void SZFTestCopyAndLinks(void) {
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(NULL));
    NSMutableArray<NSURL *> *opened = [NSMutableArray array];
    context.openURL = ^(NSURL *url) { [opened addObject:url]; };
    NSMutableArray<NSMenu *> *menus = [NSMutableArray array];
    context.presentMenu = ^(NSMenu *menu, NSView *in, NSPoint point) {
        (void)in, (void)point;
        [menus addObject:menu];
    };
    NSWindow *window = nil;
    SZFriendsMessageItemView *view = SZFBubble(context, SZFMessage(@"m_1", @"in", SZFRichSource, @"markdown"),
                                               &window, NSAppearanceNameAqua);
    NSTextView *text = view.body.markdownView;
    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
    [text setSelectedRange:NSMakeRange(0, text.string.length)];
    NSArray *types = @[ NSPasteboardTypeString, NSPasteboardTypeRTF ];
    SZFExpect([text writeSelectionToPasteboard:pasteboard types:types] &&
                  [[pasteboard stringForType:NSPasteboardTypeString] isEqualToString:SZFRichSource],
              @"the whole message copies its source: %@", [pasteboard stringForType:NSPasteboardTypeString]);
    NSRange bold = [text.string rangeOfString:@"bold"];
    [text setSelectedRange:bold];
    [text writeSelectionToPasteboard:pasteboard types:@[ NSPasteboardTypeString ]];
    SZFExpect([[pasteboard stringForType:NSPasteboardTypeString] isEqualToString:@"bold"], @"a word copies as shown");
    NSRange and = [text.string rangeOfString:@"and "];
    [text setSelectedRange:NSMakeRange(and.location, and.length + 1)];
    [text writeSelectionToPasteboard:pasteboard types:@[ NSPasteboardTypeString ]];
    SZFExpect([[pasteboard stringForType:NSPasteboardTypeString] isEqualToString:@"and $E=mc^2$"],
              @"a formula copies whole, as its source: %@", [pasteboard stringForType:NSPasteboardTypeString]);
    SZFExpect([SZFriendsMarkdownCopyText(text.textStorage, NSMakeRange(0, 0), @"x") isEqualToString:@""],
              @"nothing selected copies nothing");
    [pasteboard releaseGlobally];
    SZFTestEscapeRecorder *dropdown = [[SZFTestEscapeRecorder alloc] initWithFrame:view.frame];
    [view.superview addSubview:dropdown];
    [dropdown addSubview:view];
    [text cancelOperation:nil];
    SZFExpect(dropdown.escapes == 1, @"Escape in a selected message goes to the dropdown, as from anywhere else");

    NSUInteger web = [text.string rangeOfString:@"the plan"].location;
    NSUInteger file = [text.string rangeOfString:@"this"].location;
    SZFExpect([[text.textStorage attribute:NSToolTipAttributeName atIndex:web effectiveRange:NULL]
                  isEqualToString:@"https://example.com/plan"],
              @"a link shows its destination before it opens");
    id<NSTextViewDelegate> delegate = text.delegate;
    for (NSNumber *index in @[ @(web), @(file) ]) {
        id link = [text.textStorage attribute:NSLinkAttributeName atIndex:index.unsignedIntegerValue
                               effectiveRange:NULL];
        [delegate textView:text clickedOnLink:link atIndex:index.unsignedIntegerValue];
    }
    SZFExpect(opened.count == 0 && menus.count == 1 &&
                  [menus.firstObject.itemArray.firstObject.title isEqualToString:@"https://example.com/plan"],
              @"https asks first with its address, file: shows nothing, neither opens on a click: %@", opened);
}

// A Ready link whose helper announces messages.cancel, or one from before it.
static SZFriendsHelperLink *SZFLinkCancelling(BOOL cancels, SZFTestTransport **transportOut) {
    SZFriendsHelperLink *link = SZFTestReadyLink(transportOut);
    NSMutableDictionary *welcome = [SZFTestFrame(@"frames/welcome") mutableCopy];
    NSMutableArray *capabilities = [welcome[@"capabilities"] mutableCopy];
    [capabilities removeObject:@"messages.cancel"];
    if (cancels) [capabilities addObject:@"messages.cancel"];
    welcome[@"capabilities"] = capabilities;
    [*transportOut deliver:welcome];
    return link;
}

// "Via the assistant" leads the time line under a bubble or a card, on its side, so it sits in one place for messages
// and files alike; a time line too long for one line continues with the status and Cancel under it. Cancel on a
// queued send asks the helper to withdraw that message, only from a helper that announces messages.cancel.
static void SZFTestAssistantLabelAndCancel(void) {
    SZFTestTransport *transport = nil;
    SZFTestHost *host = [SZFTestHost new];
    SZFriendsContext *context = SZFTestContext(host, SZFLinkCancelling(YES, &transport));
    NSMutableDictionary *item = [SZFMessage(@"m_9", @"out", @"Here is the summary.", @"markdown") mutableCopy];
    NSDictionary *plain = [item copy];
    item[@"assistant_label"] = @"Via the assistant";
    item[@"status"] = @{@"state" : @"queued", @"label" : @"Sends when Priya is nearby"};
    item[@"actions"] = @[ @{@"action" : @"cancel_message", @"label" : @"Cancel", @"style" : @"link"} ];
    // At 300 pt the label, the time, the status and Cancel do not fit on one line.
    SZFriendsMessageItemView *sent = (SZFriendsMessageItemView *)[SZFriendsItemView viewForItem:item context:context];
    NSWindow *window = SZFTestHostWindow(sent, NSMakeSize(300, [sent heightForWidth:300]), NSAppearanceNameAqua);
    [sent layoutSubtreeIfNeeded];
    SZFriendsAssistantLabelView *label = sent.assistantLabel;
    NSRect bubble = sent.body.superview.frame, time = sent.timeLabel.frame;
    SZFExpect(!label.hidden && [label.text isEqualToString:@"Via the assistant"] &&
                  NSMinY(label.frame) >= NSMaxY(bubble) && fabs(NSMinY(label.frame) - NSMinY(time)) < 0.5 &&
                  NSMaxX(label.frame) < NSMinX(time) && NSMaxX(time) >= 300 - 5,
              @"the label leads the time on its line, on the bubble's side: %@ then %@", NSStringFromRect(label.frame),
              NSStringFromRect(time));
    SZFriendsButton *cancel = sent.actionButtons.firstObject;
    SZFExpect([cancel.title isEqualToString:@"Cancel"] && SZFTestMissedHits(cancel, window.contentView) == 0 &&
                  NSMinY(cancel.frame) > NSMaxY(label.frame) - 1 && NSMaxX(cancel.frame) <= 300 - 4 + 0.5 &&
                  NSMaxY(cancel.frame) <= [sent heightForWidth:300] + 0.5,
              @"a long line: the status and Cancel continue under the label and time: %@",
              NSStringFromRect(cancel.frame));
    [cancel performClick:nil];
    NSDictionary *intent = transport.sent.lastObject;
    SZFExpect([intent[@"type"] isEqualToString:@"cancel_message"] &&
                  [intent[@"fields"] isEqual:@{@"message_id" : @"m_9"}],
              @"Cancel withdraws that message by its message_id: %@", intent);
    SZFTestTransport *olderTransport = nil;
    SZFriendsContext *older = SZFTestContext(host, SZFLinkCancelling(NO, &olderTransport));
    SZFriendsItemView *unannounced = [SZFriendsItemView viewForItem:item context:older];
    SZFExpect(unannounced.actionButtons.count == 0,
              @"a helper without messages.cancel would refuse the intent: no Cancel, whatever the item carries");
    NSMutableDictionary *delivered = [plain mutableCopy];
    delivered[@"assistant_label"] = @"Via the assistant";
    delivered[@"status"] = @{@"state" : @"delivered", @"label" : @"Delivered"};
    NSMutableDictionary *deliveredPlain = [plain mutableCopy];
    deliveredPlain[@"status"] = delivered[@"status"];
    SZFriendsMessageItemView *short_ = SZFBubble(context, delivered, &window, NSAppearanceNameAqua);
    SZFriendsItemView *shortPlain = [SZFriendsItemView viewForItem:deliveredPlain context:context];
    SZFExpect(fabs([short_ heightForWidth:372] - [shortPlain heightForWidth:372]) < 0.5 &&
                  fabs(NSMinY(short_.assistantLabel.frame) - NSMinY(short_.timeLabel.frame)) < 0.5 &&
                  NSMinY(short_.assistantLabel.frame) > NSMaxY(short_.body.superview.frame),
              @"a short line: label, time and status share it, and the label costs no height: %@",
              NSStringFromRect(short_.assistantLabel.frame));
    NSMutableDictionary *incoming = [SZFMessage(@"m_10", @"in", @"Photos from the site.", @"markdown") mutableCopy];
    incoming[@"assistant_label"] = @"Via Mei’s assistant";
    SZFriendsMessageItemView *received = SZFBubble(context, incoming, &window, NSAppearanceNameAqua);
    SZFExpect(fabs(NSMinX(received.assistantLabel.frame) - 4) < 0.5 &&
                  fabs(NSMinY(received.assistantLabel.frame) - NSMinY(received.timeLabel.frame)) < 0.5 &&
                  NSMinX(received.timeLabel.frame) > NSMaxX(received.assistantLabel.frame),
              @"a friend's assistant: on the left, before the time: %@",
              NSStringFromRect(received.assistantLabel.frame));
    NSMutableDictionary *transfer = [[SZFTestSnapshot(@"conversation-priya-queued")[@"items"] lastObject] mutableCopy];
    transfer[@"assistant_label"] = @"Via the assistant";
    SZFriendsTransferItemView *card = (SZFriendsTransferItemView *)[SZFriendsItemView viewForItem:transfer
                                                                                          context:context];
    SZFTestHostWindow(card, NSMakeSize(372, [card heightForWidth:372]), NSAppearanceNameAqua);
    [card layoutSubtreeIfNeeded];
    NSMutableDictionary *unlabelled = [transfer mutableCopy];
    unlabelled[@"assistant_label"] = NSNull.null;
    SZFriendsItemView *plainCard = [SZFriendsItemView viewForItem:unlabelled context:context];
    SZFExpect(!card.assistantLabel.hidden && NSMaxX(card.assistantLabel.frame) < 372 - 30 &&
                  NSMaxX(card.assistantLabel.frame) > 200 &&
                  fabs(NSMinY(card.assistantLabel.frame) - NSMinY(card.timeLabel.frame)) < 0.5 &&
                  fabs([card heightForWidth:372] - [plainCard heightForWidth:372]) < 0.5,
              @"a file the assistant sent: the same place, before its time: %@",
              NSStringFromRect(card.assistantLabel.frame));
}

// A block a host draws through its cell is drawn in its strip and gets its clicks there (Copy, a link in a table);
// a rendering that changes later (an image loaded on request) is asked for again when the host says so.
static void SZFTestCellBlocksAndChanges(void) {
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    SZFTestBlockCell *cell = [SZFTestBlockCell new];
    __block NSUInteger version = 0;
    host.renderer = ^NSAttributedString *(NSString *markdown, CGFloat width) {
        (void)markdown, (void)width;
        NSTextAttachment *attachment = [NSTextAttachment new];
        attachment.attachmentCell = cell;
        NSMutableAttributedString *text = [[NSMutableAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"Version %lu\n", (unsigned long)++version]];
        [text appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
        return text;
    };
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(NULL));
    NSWindow *window = nil;
    SZFriendsMessageItemView *view = SZFBubble(context, SZFMessage(@"m_1", @"in", @"| a | b |", @"markdown"), &window,
                                               NSAppearanceNameAqua);
    NSScrollView *strip = view.body.wideBlocks.firstObject;
    NSView *block = strip.documentView;
    SZFExpect(strip && NSWidth(block.frame) == 640, @"a cell's size makes it a wide block");
    NSPoint centre = NSMakePoint(NSMidX(strip.bounds), NSMidY(strip.bounds));
    SZFExpect(SZFTestSameColor(SZFTestPixelAt(strip, centre), 0xcc1a1a, 8), @"drawn by its cell");
    NSPoint inWindow = [block convertPoint:NSMakePoint(20, 20) toView:nil];
    NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:inWindow modifierFlags:0 timestamp:0
                                   windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1
                                       pressure:1];
    [block mouseDown:down];
    SZFExpect(cell.clicks == 1 && cell.clickedIndex == [view.body.markdownView.string length] - 1,
              @"clicked through its cell, at its character: %lu at %lu", (unsigned long)cell.clicks,
              (unsigned long)cell.clickedIndex);
    NSUInteger asked = host.renders.count;
    NSString *shown = [view.body.markdownView.string copy];
    [NSNotificationCenter.defaultCenter postNotificationName:SZFriendsMarkdownDidChangeNotification
                                                      object:@"another message"];
    [window.contentView layoutSubtreeIfNeeded];
    SZFExpect(host.renders.count == asked, @"another message's change asks nothing");
    [NSNotificationCenter.defaultCenter postNotificationName:SZFriendsMarkdownDidChangeNotification
                                                      object:@"| a | b |"];
    [window.contentView layoutSubtreeIfNeeded];
    NSString *latest = [NSString stringWithFormat:@"Version %lu", (unsigned long)version];
    SZFExpect(host.renders.count == asked + 1 && ![view.body.markdownView.string isEqualToString:shown] &&
                  [view.body.markdownView.string hasPrefix:latest],
              @"this message's change: asked again and shown: %@", view.body.markdownView.string);
}

// A centred line (display math) keeps the bubble at its full width, so it stays centred in the bubble.
static void SZFTestCentredLines(void) {
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    __block BOOL centred = YES;
    host.renderer = ^NSAttributedString *(NSString *markdown, CGFloat width) {
        (void)markdown, (void)width;
        NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
        style.alignment = centred ? NSTextAlignmentCenter : NSTextAlignmentLeft;
        NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:@"So:\n"];
        NSDictionary *attributes = @{NSParagraphStyleAttributeName : style};
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"E = mc²" attributes:attributes]];
        return text;
    };
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(NULL));
    NSWindow *window = nil;
    SZFriendsMessageItemView *view = SZFBubble(context, SZFMessage(@"m_1", @"in", @"So: $$E=mc^2$$", @"markdown"),
                                               &window, NSAppearanceNameAqua);
    SZFExpect(fabs(NSWidth(view.body.frame) - (372 - 62)) < 0.5, @"a centred line keeps the full width: %.0f",
              NSWidth(view.body.frame));
    centred = NO;
    SZFriendsMessageItemView *left = SZFBubble(context, SZFMessage(@"m_2", @"in", @"So: $$E=mc^3$$", @"markdown"),
                                               &window, NSAppearanceNameAqua);
    SZFExpect(NSWidth(left.body.frame) < 120, @"left-aligned short text shrinks to fit: %.0f",
              NSWidth(left.body.frame));
}

void SZFTestMarkdownBubbles(void) {
    SZFTestCentredLines();
    SZFTestCellBlocksAndChanges();
    SZFTestWhoRenders();
    SZFTestLayoutAndCache();
    SZFTestCopyAndLinks();
    SZFTestAssistantLabelAndCancel();
}
