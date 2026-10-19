// Shenzhen Friends views tests: links in a friend's message. A click shows where the link goes, in a menu, and never
// opens it; a link whose words show another site says so first; only the menu opens the link.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsItemViewsInternal.h"

static NSString *const SZFDeceptive = @"https://appleid-verify.example.net/login";

// The menus a context was asked to show, and what it opened.
@interface SZFTestMenuRecorder : NSObject
@property(nonatomic, strong) NSMutableArray<NSMenu *> *menus;
@property(nonatomic, strong) NSMutableArray<NSView *> *views;
@property(nonatomic, strong) NSMutableArray<NSValue *> *points;
@property(nonatomic, strong) NSMutableArray<NSURL *> *opened;
@end
@implementation SZFTestMenuRecorder
@end

static SZFTestMenuRecorder *SZFRecordMenus(SZFriendsContext *context) {
    SZFTestMenuRecorder *recorder = [SZFTestMenuRecorder new];
    recorder.menus = [NSMutableArray array];
    recorder.views = [NSMutableArray array];
    recorder.points = [NSMutableArray array];
    recorder.opened = [NSMutableArray array];
    __weak SZFTestMenuRecorder *weak = recorder;
    context.openURL = ^(NSURL *url) { [weak.opened addObject:url]; };
    context.presentMenu = ^(NSMenu *menu, NSView *view, NSPoint point) {
        [weak.menus addObject:menu];
        [weak.views addObject:view];
        [weak.points addObject:[NSValue valueWithPoint:point]];
    };
    return recorder;
}

static NSArray<NSString *> *SZFTitles(NSMenu *menu) {
    NSMutableArray *titles = [NSMutableArray array];
    for (NSMenuItem *item in menu.itemArray) [titles addObject:item.title];
    return titles;
}

static NSArray<NSString *> *SZFMenuKeys(void) {
    return @[ @"link_open", @"link_open_email", @"link_elsewhere" ];
}

// A Ready link whose welcome strings are changed by `change`: the menu's words set by the test (as the catalog
// sets them, PROTOCOL.md § Static strings), or taken out (a helper from before they existed).
static SZFriendsHelperLink *SZFLinkWithStrings(void (^change)(NSMutableDictionary *strings)) {
    SZFTestTransport *transport = nil;
    SZFriendsHelperLink *link = SZFTestReadyLink(&transport);
    NSMutableDictionary *welcome = [SZFTestFrame(@"frames/welcome") mutableCopy];
    NSMutableDictionary *strings = [welcome[@"strings"] mutableCopy];
    change(strings);
    welcome[@"strings"] = strings;
    [transport deliver:welcome];
    return link;
}

static SZFriendsHelperLink *SZFLinkWithMenuWords(void) {
    return SZFLinkWithStrings(^(NSMutableDictionary *strings) {
        [strings addEntriesFromDictionary:@{@"link_open" : @"Open in Browser", @"link_open_email" : @"New Email",
                                            @"link_elsewhere" : @"Goes to {host}, not {shown}"}];
    });
}

static SZFriendsHelperLink *SZFLinkWithoutMenuWords(void) {
    return SZFLinkWithStrings(^(NSMutableDictionary *strings) { [strings removeObjectsForKeys:SZFMenuKeys()]; });
}

static SZFriendsMessageItemView *SZFLinkBubble(SZFriendsContext *context, NSString *text, NSArray *segments,
                                               NSString *format, NSWindow **window) {
    NSMutableDictionary *item = [@{@"kind" : @"message", @"item_id" : @"m_link", @"direction" : @"in",
                                   @"text" : text, @"segments" : segments ?: @[ @{@"text" : text} ],
                                   @"time_label" : @"14:32", @"status" : NSNull.null, @"actions" : @[],
                                   @"highlighted" : @NO, @"accessibility_label" : text} mutableCopy];
    if (format) item[@"text_format"] = format;
    SZFriendsMessageItemView *view = (SZFriendsMessageItemView *)[SZFriendsItemView viewForItem:item context:context];
    *window = SZFTestHostWindow(view, NSMakeSize(372, [view heightForWidth:372]), NSAppearanceNameAqua);
    [view layoutSubtreeIfNeeded];
    return view;
}

// Clicks the link whose words start with `words`, as the text view does: through its delegate.
static BOOL SZFClickLink(NSTextView *text, NSString *words) {
    NSUInteger at = [text.string rangeOfString:words].location;
    if (at == NSNotFound) return NO;
    id link = [text.textStorage attribute:NSLinkAttributeName atIndex:at effectiveRange:NULL];
    return link && [(id<NSTextViewDelegate>)text.delegate textView:text clickedOnLink:link atIndex:at];
}

static NSString *const SZFLinkSource = @"Please confirm: "
                                       @"[https://www.apple.com/account](https://appleid-verify.example.net/login), "
                                       @"[the plan](https://example.com/plan), [Mei](mailto:mei@example.com) or "
                                       @"[hosts](file:///etc/hosts).";

// The words of a Markdown link show one site and it goes to another: one click opens nothing, and the menu names
// where it really goes (with the catalog's words, that it is not the site shown); only the menu then opens it.
static void SZFTestMarkdownLinkMenus(void) {
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    SZFriendsContext *bare = SZFTestContext(host, SZFLinkWithoutMenuWords());
    SZFTestMenuRecorder *recorder = SZFRecordMenus(bare);
    NSWindow *window = nil;
    SZFriendsMessageItemView *view = SZFLinkBubble(bare, SZFLinkSource, nil, @"markdown", &window);
    NSTextView *text = view.body.markdownView;
    SZFExpect(view.body.showsMarkdown && text, @"the host renders the message");
    SZFExpect(SZFClickLink(text, @"https://www.apple.com/account"), @"the bubble answers the click itself");
    SZFExpect(recorder.opened.count == 0, @"one click opens nothing: %@", recorder.opened);
    NSMenu *menu = recorder.menus.lastObject;
    NSArray *alone = @[ SZFDeceptive ];
    SZFExpect(recorder.menus.count == 1 && [SZFTitles(menu) isEqualToArray:alone],
              @"without the catalog's words the menu is the real address alone: %@", SZFTitles(menu));
    NSPoint point = recorder.points.lastObject.pointValue;
    SZFExpect(recorder.views.lastObject == text && point.y > 0 && point.y <= NSHeight(text.bounds) + 1,
              @"shown under the link, in its text: %@", NSStringFromPoint(point));
    [menu performActionForItemAtIndex:0];
    SZFExpect(recorder.opened.count == 1 && [recorder.opened.firstObject.absoluteString isEqualToString:SZFDeceptive],
              @"choosing the address opens it: %@", recorder.opened);

    SZFriendsContext *worded = SZFTestContext(host, SZFLinkWithMenuWords());
    recorder = SZFRecordMenus(worded);
    view = SZFLinkBubble(worded, SZFLinkSource, nil, @"markdown", &window);
    text = view.body.markdownView;
    SZFClickLink(text, @"https://www.apple.com/account");
    menu = recorder.menus.lastObject;
    NSArray *expected = @[ @"Goes to appleid-verify.example.net, not www.apple.com", SZFDeceptive, @"Open in Browser" ];
    SZFExpect([SZFTitles(menu) isEqualToArray:expected], @"the warning first, then the address: %@", SZFTitles(menu));
    SZFExpect(menu.numberOfItems == 3 && ![menu itemAtIndex:0].enabled && ![menu itemAtIndex:1].enabled &&
                  [menu itemAtIndex:2].enabled && [menu itemAtIndex:0].image,
              @"only Open in Browser acts; the warning carries a caution mark");
    SZFExpect(recorder.opened.count == 0, @"still nothing opened before the menu's choice");
    [menu performActionForItemAtIndex:2];
    SZFExpect(recorder.opened.count == 1 && [recorder.opened.firstObject.absoluteString isEqualToString:SZFDeceptive],
              @"Open in Browser opens the real address: %@", recorder.opened);

    SZFClickLink(text, @"the plan");
    expected = @[ @"https://example.com/plan", @"Open in Browser" ];
    SZFExpect([SZFTitles(recorder.menus.lastObject) isEqualToArray:expected],
              @"ordinary words: the address and Open in Browser, no warning: %@", SZFTitles(recorder.menus.lastObject));
    SZFClickLink(text, @"Mei");
    expected = @[ @"mailto:mei@example.com", @"New Email" ];
    SZFExpect([SZFTitles(recorder.menus.lastObject) isEqualToArray:expected],
              @"an email link names the address: %@", SZFTitles(recorder.menus.lastObject));
    NSUInteger menus = recorder.menus.count;
    SZFClickLink(text, @"hosts");
    SZFExpect(recorder.menus.count == menus && recorder.opened.count == 1, @"a file: link shows and opens nothing");
}

// The plain bubble (no Markdown to draw): a detected link answers through the same menu, from the text view that
// shows the words.
static void SZFTestPlainLinkMenus(void) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFLinkWithMenuWords());
    SZFTestMenuRecorder *recorder = SZFRecordMenus(context);
    NSString *address = @"https://parcel.example/t/1";
    NSArray *segments = @[ @{@"text" : @"Track it at "}, @{@"text" : address, @"url" : address} ];
    NSWindow *window = nil;
    SZFriendsMessageItemView *view = SZFLinkBubble(context, [@"Track it at " stringByAppendingString:address],
                                                   segments, nil, &window);
    NSTextView *text = view.body.plainText;
    NSFont *font = [text.textStorage attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
    SZFExpect(!view.body.showsMarkdown && !text.hidden && text.selectable && !text.editable &&
                  fabs(font.pointSize - 13) < 0.01,
              @"plain text is selectable 13 pt text");
    SZFExpect(SZFClickLink(text, address), @"the bubble answers the click");
    NSArray *expected = @[ address, @"Open in Browser" ];
    SZFExpect(recorder.opened.count == 0 && [SZFTitles(recorder.menus.lastObject) isEqualToArray:expected] &&
                  recorder.views.lastObject == text,
              @"one click opens nothing; the menu names the address: %@", SZFTitles(recorder.menus.lastObject));
}

// A link the host draws itself (in a table, an attachment the views do not lay out) reaches the same menu through
// SZFriendsShowLinkMenuInView, from the strip the click landed in or the bubble's text; nothing outside a bubble.
static void SZFTestHostDrawnLinkMenus(void) {
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    host.renderer = ^NSAttributedString *(NSString *markdown, CGFloat width) {
        (void)markdown, (void)width;
        NSTextAttachment *table = [NSTextAttachment new];
        table.image = [NSImage imageWithSize:NSMakeSize(640, 40) flipped:NO drawingHandler:^BOOL(NSRect rect) {
            (void)rect;
            return YES;
        }];
        table.bounds = NSMakeRect(0, 0, 640, 40);
        NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:@"Dates:\n"];
        [text appendAttributedString:[NSAttributedString attributedStringWithAttachment:table]];
        return text;
    };
    SZFriendsContext *context = SZFTestContext(host, SZFLinkWithMenuWords());
    SZFTestMenuRecorder *recorder = SZFRecordMenus(context);
    NSWindow *window = nil;
    SZFriendsMessageItemView *view = SZFLinkBubble(context, @"| a | b |\n|---|---|\n| 1 | 2 |", nil, @"markdown",
                                                   &window);
    NSView *block = view.body.wideBlocks.firstObject.documentView;
    NSURL *deceptive = [NSURL URLWithString:SZFDeceptive];
    SZFriendsShowLinkMenuInView(block, deceptive, @"https://www.apple.com/account", NSMakePoint(12, 30));
    NSArray *expected = @[ @"Goes to appleid-verify.example.net, not www.apple.com", SZFDeceptive, @"Open in Browser" ];
    SZFExpect(block && [SZFTitles(recorder.menus.lastObject) isEqualToArray:expected] &&
                  recorder.views.lastObject == block &&
                  NSEqualPoints(recorder.points.lastObject.pointValue, NSMakePoint(12, 30)),
              @"a table link in a strip: the warning, the address and Open, at the click: %@",
              SZFTitles(recorder.menus.lastObject));
    SZFExpect(recorder.opened.count == 0, @"showing the menu opens nothing");
    [recorder.menus.lastObject performActionForItemAtIndex:2];
    SZFExpect(recorder.opened.count == 1 && [recorder.opened.firstObject isEqual:deceptive],
              @"only the menu's Open opens it: %@", recorder.opened);
    SZFriendsShowLinkMenuInView(view.body.markdownView, [NSURL URLWithString:@"https://example.com/plan"], @"the plan",
                                NSZeroPoint);
    expected = @[ @"https://example.com/plan", @"Open in Browser" ];
    SZFExpect([SZFTitles(recorder.menus.lastObject) isEqualToArray:expected] &&
                  recorder.views.lastObject == view.body.markdownView,
              @"from the bubble's text too: %@", SZFTitles(recorder.menus.lastObject));
    NSUInteger shown = recorder.menus.count;
    SZFriendsShowLinkMenuInView([NSView new], deceptive, @"elsewhere", NSZeroPoint);
    SZFriendsShowLinkMenuInView(block, [NSURL URLWithString:@"file:///etc/hosts"], @"hosts", NSZeroPoint);
    SZFriendsShowLinkMenuInView(block, [NSURL URLWithString:@"javascript:alert(1)"], @"run", NSZeroPoint);
    SZFExpect(recorder.menus.count == shown && recorder.opened.count == 1,
              @"no menu outside a bubble or for a link Friends never opens");
}

// Which words count as showing another place, and how a long address keeps its host.
static void SZFTestShownElsewhere(void) {
    NSURL * (^url)(NSString *) = ^NSURL *(NSString *string) { return [NSURL URLWithString:string]; };
    NSDictionary<NSString *, NSArray *> *elsewhere = @{
        @"www.apple.com" : @[ @"https://www.apple.com/account", SZFDeceptive ],
        @"paypal.com" : @[ @"paypal.com", @"https://paypal.com.example.net/" ],
        @"apple.com" : @[ @"apple.com", @"https://example.net/" ],
        @"support@apple.com" : @[ @"support@apple.com", @"https://example.net/" ],
        @"mei@example.com" : @[ @"mei@example.com", @"mailto:boss@example.net" ],
    };
    for (NSString *shown in elsewhere) {
        NSString *found = SZFriendsLinkShownElsewhere(elsewhere[shown][0], url(elsewhere[shown][1]));
        SZFExpect([found isEqualToString:shown], @"%@ -> %@ shows %@, not %@", elsewhere[shown][0],
                  elsewhere[shown][1], shown, found);
    }
    NSArray<NSArray *> *same = @[
        @[ @"apple.com", @"https://www.apple.com/iphone" ], @[ @"www.apple.com", @"https://support.apple.com/" ],
        @[ @"<https://example.com/plan>", @"https://example.com/plan" ], @[ @"the plan", @"https://example.net/" ],
        @[ @"report.pdf", @"https://files.example.net/report.pdf" ], @[ @"Pages 3-5", @"https://example.net/" ],
        @[ @"mei@example.com", @"mailto:Mei@Example.com?subject=Hi" ], @[ @"2.5", @"https://example.net/" ],
    ];
    for (NSArray *pair in same)
        SZFExpect(!SZFriendsLinkShownElsewhere(pair[0], url(pair[1])), @"%@ -> %@ is not elsewhere", pair[0], pair[1]);
    NSString *host = @"www.apple.com.account-verify.secure-login.session-update.billing-center.example.net";
    NSString *title = SZFriendsLinkAddressTitle(url([NSString stringWithFormat:@"https://%@/%@", host,
                                                                              [@"" stringByPaddingToLength:120
                                                                                                withString:@"path/"
                                                                                           startingAtIndex:0]]));
    SZFExpect([title hasPrefix:[@"https://" stringByAppendingString:host]] && [title hasSuffix:@"…"] &&
                  title.length < 100,
              @"a long address is cut in its path, never in its host: %@", title);
    SZFExpect([SZFriendsLinkAddressTitle(url(@"https://example.com/plan")) isEqualToString:@"https://example.com/plan"],
              @"a short address shows whole");
}

// The helper's real welcome frame (fixtures/frames/welcome.json, which the protocol check holds to the catalog) gives
// the menu its words: the warning, the address, then Open in Browser.
static void SZFTestRealWelcomeMenu(void) {
    NSDictionary *strings = SZFTestFrame(@"frames/welcome")[@"strings"];
    for (NSString *key in SZFMenuKeys())
        SZFExpect([strings[key] isKindOfClass:NSString.class] && [strings[key] length], @"welcome.json has %@", key);
    SZFTestAssistantHost *host = [SZFTestAssistantHost new]; // the context holds its host weakly
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(NULL));
    SZFTestMenuRecorder *recorder = SZFRecordMenus(context);
    NSWindow *window = nil;
    SZFriendsMessageItemView *view = SZFLinkBubble(context, SZFLinkSource, nil, @"markdown", &window);
    SZFClickLink(view.body.markdownView, @"https://www.apple.com/account");
    NSArray *expected = @[ @"Goes to appleid-verify.example.net, not www.apple.com", SZFDeceptive, @"Open in Browser" ];
    SZFExpect([SZFTitles(recorder.menus.lastObject) isEqualToArray:expected],
              @"the real welcome strings word the menu: %@", SZFTitles(recorder.menus.lastObject));
    SZFClickLink(view.body.markdownView, @"Mei");
    SZFExpect([SZFTitles(recorder.menus.lastObject) isEqualToArray:(@[ @"mailto:mei@example.com", @"New Email" ])],
              @"and an email link's: %@", SZFTitles(recorder.menus.lastObject));
    SZFExpect(recorder.opened.count == 0, @"nothing opened without the menu's choice");
}

void SZFTestLinkMenus(void) {
    SZFTestShownElsewhere();
    SZFTestMarkdownLinkMenus();
    SZFTestPlainLinkMenus();
    SZFTestHostDrawnLinkMenus();
    SZFTestRealWelcomeMenu();
}
