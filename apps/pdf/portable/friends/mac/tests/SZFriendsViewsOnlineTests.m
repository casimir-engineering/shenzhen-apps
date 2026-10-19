// Shenzhen Friends views tests: online friends as the helper describes them (PROTOCOL.md § Shared objects, Route,
// online). Rows draw the globe for a direct session and the server for the relay in the online colour, and the globe
// in the offline colour while an attempt connects; the header and details say the route's words; a transfer through
// the relay shows its estimate; an unreachable friend's composer says that everything waits. Renders of the online
// fixtures and a connecting header, light and dark at 2x and 1x, land under online/ for review.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsConversationPage.h"
#import "mac/SZFriendsDetailsPage.h"

// The strongest blue cast among the icon's pixels: the online colour is blue, the offline colour grey.
static NSInteger SZFBlueCast(NSView *view, NSRect rect) {
    NSBitmapImageRep *rep = SZFTestBitmap(view);
    NSInteger best = -255;
    for (NSInteger y = (NSInteger)NSMinY(rect); y < (NSInteger)NSMaxY(rect); y++)
        for (NSInteger x = (NSInteger)NSMinX(rect); x < (NSInteger)NSMaxX(rect); x++) {
            uint32_t pixel = SZFTestBitmapPixel(rep, x, y);
            best = MAX(best, (NSInteger)(pixel & 0xff) - (NSInteger)((pixel >> 16) & 0xff));
        }
    return best;
}

// Every visible label's words under `root`.
static NSArray<NSString *> *SZFVisibleWords(NSView *root) {
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSTextField *label in SZFTestSubviews(root, NSTextField.class)) {
        BOOL shown = label.stringValue.length > 0 && NSHeight(label.frame) > 0;
        for (NSView *view = label; shown && view; view = view.superview) shown = !view.hidden;
        if (shown) [words addObject:label.stringValue];
    }
    return words;
}

static SZFriendsConversationPage *SZFOnlineConversation(SZFriendsContext *context, NSDictionary *data) {
    SZFriendsConversationPage *page = [[SZFriendsConversationPage alloc] initWithContext:context
                                                                          conversationID:data[@"conversation_id"]
                                                                        highlightMessage:nil];
    page.frame = NSMakeRect(0, 0, 400, 640);
    [page applySnapshot:data];
    return page;
}

static void SZFTestGlyphs(void) {
    SZFriendsAppearance *appearance = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL)).appearance;
    NSDictionary *connecting = @{@"kind" : @"connecting", @"method" : NSNull.null, @"label" : @"Connecting to Mei…"};
    SZFExpect([SZFriendsRouteGlyph(connecting) isEqualToString:@"internet"], @"connecting draws the globe");
    SZFExpect(SZFriendsRouteColor(appearance, @"connecting") == appearance.offlineRouteColor,
              @"in the colour of a route that is not up");
}

// online-list.json: Mei direct and Daniel through the relay in the online colour, Priya connecting in grey.
static void SZFTestRows(void) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [page applySnapshot:SZFTestSnapshot(@"online-list")];
    [page layoutSubtreeIfNeeded];
    NSDictionary<NSString *, NSNumber *> *expected = @{@"c_mei" : @YES, @"c_daniel" : @YES, @"c_priya" : @NO};
    NSUInteger seen = 0;
    for (SZFriendsRowView *row in page.rows) {
        NSNumber *online = expected[row.conversationID ?: @""];
        if (!online) continue;
        seen++;
        NSInteger cast = SZFBlueCast(row, NSMakeRect(NSWidth(row.bounds) - 21, 27, 13, 13));
        SZFExpect(online.boolValue ? cast > 60 : cast < 30, @"%@'s route icon is %@ (blue cast %ld)",
                  row.conversationID, online.boolValue ? @"in the online colour" : @"grey", (long)cast);
    }
    SZFExpect(seen == expected.count, @"the online rows are listed (%lu)", (unsigned long)seen);
    (void)window;
}

static void SZFTestConversations(void) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    SZFriendsConversationPage *kenji =
        SZFOnlineConversation(context, SZFTestSnapshot(@"online-conversation-kenji-relay"));
    NSWindow *window = SZFTestHostWindow(kenji, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [kenji layoutSubtreeIfNeeded];
    (void)SZFTestBitmap(kenji.header); // draws once, which places the icon
    NSArray<NSString *> *words = SZFVisibleWords(kenji);
    SZFExpect([words containsObject:@"Through the Friends relay, about 1 min"], @"the relay estimate shows: %@", words);
    SZFExpect([kenji.header.titleButton.accessibilityLabel containsString:@"online, through the Friends relay"] &&
                  !NSIsEmptyRect(kenji.header.routeIconRect),
              @"the header says the relay, after its icon: %@", kenji.header.titleButton.accessibilityLabel);

    SZFriendsConversationPage *priya =
        SZFOnlineConversation(context, SZFTestSnapshot(@"online-conversation-priya-unreachable"));
    NSWindow *second = SZFTestHostWindow(priya, NSMakeSize(400, 640), NSAppearanceNameAqua);
    words = SZFVisibleWords(priya.composer);
    SZFExpect([words containsObject:@"Couldn’t connect to Priya just now. Friends keeps trying, and sends "
                                    @"what’s waiting as soon as it can."],
              @"the composer says everything waits: %@", words);

    SZFriendsConversationPage *connecting =
        SZFOnlineConversation(context, SZFTestSnapshot(@"online-conversation-priya-connecting"));
    NSWindow *third = SZFTestHostWindow(connecting, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [connecting layoutSubtreeIfNeeded];
    (void)SZFTestBitmap(connecting.header); // draws once, which places the icon
    NSRect icon = connecting.header.routeIconRect;
    SZFExpect(NSWidth(icon) == 11 && SZFBlueCast(connecting.header, icon) < 30,
              @"a connecting header draws a grey icon before its words (%@)", NSStringFromRect(icon));
    (void)window, (void)second, (void)third;
}

static void SZFRenderOnline(NSString *name, NSView *_Nonnull (^build)(SZFriendsContext *context)) {
    for (NSAppearanceName look in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
        NSView *view = build(context);
        NSWindow *window = SZFTestHostWindow(view, NSMakeSize(400, 640), look);
        SZFExpect(SZFTestWaitForPreviews(window.contentView), @"previews loaded for %@", name);
        [window.contentView layoutSubtreeIfNeeded];
        NSString *file = [NSString stringWithFormat:@"online/%@-%@", name,
                                                    [look isEqualToString:NSAppearanceNameAqua] ? @"light" : @"dark"];
        SZFExpect(SZFTestRender(window.contentView, file, 2) != nil &&
                      SZFTestRender(window.contentView, [file stringByAppendingString:@"@1x"], 1) != nil,
                  @"render %@ written", file);
    }
}

static void SZFTestOnlineRenders(void) {
    [NSFileManager.defaultManager createDirectoryAtPath:[SZFTestRendersDir stringByAppendingPathComponent:@"online"]
                            withIntermediateDirectories:YES attributes:nil error:NULL];
    SZFRenderOnline(@"online-list", ^NSView *(SZFriendsContext *context) {
        SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
        [page applySnapshot:SZFTestSnapshot(@"online-list")];
        return page;
    });
    for (NSString *fixture in
         @[ @"online-conversation-kenji-relay", @"online-conversation-priya-connecting",
            @"online-conversation-priya-unreachable" ])
        SZFRenderOnline(fixture, ^NSView *(SZFriendsContext *context) {
            return SZFOnlineConversation(context, SZFTestSnapshot(fixture));
        });
}

void SZFTestOnlineStates(void) {
    SZFTestGlyphs();
    SZFTestRows();
    SZFTestConversations();
    SZFTestOnlineRenders();
}
