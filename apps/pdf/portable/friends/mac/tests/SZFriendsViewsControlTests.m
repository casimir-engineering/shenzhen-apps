// Shenzhen Friends views tests: back arrows below the list carry the list's waiting count, older history has a
// visible control, blocked rows are drawn muted, and the title-bar icon uses the host's icon color.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsConversationPage.h"
#import "mac/SZFriendsDetailsPage.h"

// `color` as 0xRRGGBB in sRGB under the named appearance.
static uint32_t SZFResolved(NSColor *color, NSAppearanceName name) {
    __block NSColor *srgb = nil;
    [[NSAppearance appearanceNamed:name] performAsCurrentDrawingAppearance:^{
        srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    }];
    return ((uint32_t)lround(srgb.redComponent * 255) << 16) | ((uint32_t)lround(srgb.greenComponent * 255) << 8) |
           (uint32_t)lround(srgb.blueComponent * 255);
}

// The view as drawn offscreen, for telling two looks of one view apart.
static NSData *SZFPixels(NSView *view) {
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    return [NSData dataWithBytes:rep.bitmapData length:(NSUInteger)(rep.bytesPerRow * rep.pixelsHigh)];
}

static void SZFTestBackArrows(void) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    SZFriendsDetailsPage *details = [[SZFriendsDetailsPage alloc] initWithContext:context conversationID:@"c_mei"];
    NSWindow *detailsWindow = SZFTestHostWindow(details, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [details applySnapshot:SZFTestSnapshot(@"details-mei")];
    SZFExpect([details.header.backButton.badgeLabel isEqualToString:@"2"] &&
                  [details.header.backButton.accessibilityLabel
                      isEqualToString:@"Back to the conversation with Mei, 2 waiting for you in Friends"],
              @"details carries the list's count: %@ / %@", details.header.backButton.badgeLabel,
              details.header.backButton.accessibilityLabel);
    SZFriendsProfilePage *profile = [[SZFriendsProfilePage alloc] initWithContext:context];
    NSWindow *profileWindow = SZFTestHostWindow(profile, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [profile applySnapshot:SZFTestSnapshot(@"profile-unreserved")];
    SZFExpect([profile.header.backButton.badgeLabel isEqualToString:@"2"] &&
                  [profile.header.backButton.accessibilityLabel isEqualToString:@"Back to Friends, 2 waiting"],
              @"profile carries the list's count: %@", profile.header.backButton.accessibilityLabel);
    (void)detailsWindow, (void)profileWindow;
}

static void SZFTestLoadEarlier(void) {
    SZFTestTransport *transport = nil;
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(&transport));
    SZFriendsConversationPage *kenji = [[SZFriendsConversationPage alloc] initWithContext:context
                                                                           conversationID:@"c_kenji"
                                                                         highlightMessage:nil];
    NSWindow *window = SZFTestHostWindow(kenji, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [kenji pageWillAppear];
    NSDictionary *open = transport.sent.lastObject;
    SZFExpect([open[@"type"] isEqualToString:@"open_conversation"], @"subscribed on appearing: %@", open);
    [transport deliver:@{@"type" : @"reply", @"re" : open[@"id"] ?: @"", @"ok" : @YES,
                         @"result" : @{@"subscription" : @"s_41", @"conversation_id" : @"c_kenji"}}];
    NSDictionary *data = SZFTestSnapshot(@"conversation-kenji-offer");
    [transport deliver:@{@"type" : @"snapshot", @"subscription" : @"s_41", @"view" : @"conversation", @"rev" : @1,
                         @"data" : data}];
    SZFriendsButton *earlier = kenji.loadEarlierButton;
    SZFExpect(!earlier.hidden && earlier.enabled && [earlier.title isEqualToString:@"Show earlier messages"],
              @"has_earlier shows the control with the helper's words: hidden %d, title %@", earlier.hidden,
              earlier.title);
    SZFExpect(SZFTestMissedHits(earlier, window.contentView) == 0, @"the control is one full hit target");
    SZFExpect(NSMaxY(earlier.frame) <= NSMinY(kenji.itemViews.firstObject.frame), @"above the oldest item");
    NSUInteger before = transport.sent.count;
    [earlier performClick:nil];
    [earlier performClick:nil];
    NSArray *asked = [transport.sent subarrayWithRange:NSMakeRange(before, transport.sent.count - before)];
    SZFExpect(asked.count == 1 && [asked[0][@"type"] isEqualToString:@"load_earlier"] &&
                  [asked[0][@"fields"][@"subscription"] isEqualToString:@"s_41"] && !earlier.enabled,
              @"one load_earlier for the conversation's subscription until the items arrive: %@", asked);
    NSMutableDictionary *all = [data mutableCopy];
    all[@"has_earlier"] = @NO;
    [transport deliver:@{@"type" : @"snapshot", @"subscription" : @"s_41", @"view" : @"conversation", @"rev" : @2,
                         @"data" : all}];
    SZFExpect(earlier.hidden, @"no earlier history, no control");

    // Without the helper's words for it the control stays hidden rather than inventing a label.
    SZFriendsHelperLink *bare = SZFTestReadyLink(&transport);
    [transport deliver:@{@"type" : @"welcome", @"re" : @"1", @"strings" : @{}, @"capabilities" : @[]}];
    SZFriendsConversationPage *quiet =
        [[SZFriendsConversationPage alloc] initWithContext:SZFTestContext([SZFTestHost new], bare)
                                            conversationID:@"c_kenji"
                                          highlightMessage:nil];
    [quiet applySnapshot:data];
    SZFExpect(quiet.loadEarlierButton.hidden, @"no load_earlier string, no control");
    [kenji pageDidDisappear];
    (void)window;
}

static void SZFTestMutedRows(void) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [page applySnapshot:SZFTestSnapshot(@"list")];
    [page layoutSubtreeIfNeeded];
    NSUInteger muted = 0;
    for (SZFriendsRowView *row in page.rows) muted += row.muted;
    SZFriendsRowView *jonas = page.rows.lastObject;
    SZFExpect(muted == 1 && jonas.muted && [jonas.conversationID isEqualToString:@"c_jonas"],
              @"only the blocked row is muted (%lu)", (unsigned long)muted);
    SZFExpect(jonas.enabled && jonas.dropLabel == nil, @"still opens its conversation, still refuses drops");

    // The same row with style normal draws differently, so the hint reaches the screen.
    NSMutableDictionary *row = [[SZFTestSnapshot(@"list")[@"rows"] lastObject] mutableCopy];
    SZFriendsRowView *probe = [[SZFriendsRowView alloc] initWithContext:context];
    probe.frame = NSMakeRect(0, 0, 380, SZFriendsRowHeight);
    NSWindow *probeWindow = SZFTestHostWindow(probe, probe.frame.size, NSAppearanceNameAqua);
    [probe configureWithListRow:row];
    NSData *mutedPixels = SZFPixels(probe);
    row[@"style"] = @"normal";
    [probe configureWithListRow:row];
    SZFExpect(!probe.muted && ![SZFPixels(probe) isEqualToData:mutedPixels], @"muted and normal rows look different");
    row[@"style"] = @"a_style_from_the_future";
    [probe configureWithListRow:row];
    SZFExpect(!probe.muted, @"an unknown style draws as normal");
    (void)window, (void)probeWindow;
}

static void SZFTestTitleBarIconColor(void) {
    SZFriendsAppearance *defaults = [SZFriendsAppearance new];
    SZFExpect(SZFResolved(defaults.titleBarIconColor, NSAppearanceNameAqua) == 0x26282b &&
                  SZFResolved(defaults.titleBarIconColor, NSAppearanceNameDarkAqua) == 0xeceef1,
              @"defaults to ShenzhenPDF's chrome icon color: %06x / %06x",
              SZFResolved(defaults.titleBarIconColor, NSAppearanceNameAqua),
              SZFResolved(defaults.titleBarIconColor, NSAppearanceNameDarkAqua));
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    context.appearance.titleBarIconColor = SZFriendsDynamicColor(0x123456, 0x654321);
    SZFriendsTitleButton *button = [[SZFriendsTitleButton alloc] initWithContext:context];
    SZFExpect(SZFResolved(button.iconColor, NSAppearanceNameAqua) == 0x123456, @"idle icon uses the host's token");
    button.selectedLook = YES;
    SZFExpect(SZFResolved(button.iconColor, NSAppearanceNameDarkAqua) == 0x654321, @"so does the open state");

    // Drawn: the darkest opaque pixel of the idle icon in light mode is the token's color, not the dropdown's grey
    // secondary text. At 4x the 1.4 pt strokes have fully covered pixels to sample.
    SZFriendsContext *plain = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    SZFriendsTitleButton *idle = [[SZFriendsTitleButton alloc] initWithContext:plain];
    NSWindow *window = SZFTestHostWindow(idle, NSMakeSize(28, 28), NSAppearanceNameAqua);
    NSString *path = SZFTestRender(idle, @"title-button-idle-icon-light", 4);
    NSBitmapImageRep *rep = path ? (NSBitmapImageRep *)[NSBitmapImageRep imageRepWithContentsOfFile:path] : nil;
    SZFExpect([rep isKindOfClass:NSBitmapImageRep.class], @"title button rendered");
    uint32_t darkest = 0xffffff;
    NSUInteger darkestSum = 3 * 255;
    for (NSInteger y = 0; y < rep.pixelsHigh; y++)
        for (NSInteger x = 0; x < rep.pixelsWide; x++) {
            NSColor *pixel = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            NSUInteger r = (NSUInteger)lround(pixel.redComponent * 255);
            NSUInteger g = (NSUInteger)lround(pixel.greenComponent * 255);
            NSUInteger b = (NSUInteger)lround(pixel.blueComponent * 255);
            if (pixel.alphaComponent > 0.99 && r + g + b < darkestSum) {
                darkestSum = r + g + b;
                darkest = (uint32_t)((r << 16) | (g << 8) | b);
            }
        }
    int dr = (int)(darkest >> 16) - 0x26, dg = (int)((darkest >> 8) & 255) - 0x28, db = (int)(darkest & 255) - 0x2b;
    SZFExpect(abs(dr) <= 6 && abs(dg) <= 6 && abs(db) <= 6, @"idle icon drawn in #26282b, darkest pixel %06x", darkest);
    (void)window;
}

void SZFTestControls(void) {
    SZFTestBackArrows();
    SZFTestLoadEarlier();
    SZFTestMutedRows();
    SZFTestTitleBarIconColor();
}
