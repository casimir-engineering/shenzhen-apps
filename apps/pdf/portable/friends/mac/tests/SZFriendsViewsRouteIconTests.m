// Shenzhen Friends views tests: the route icon says how a friend is connected (the owner's request: local Wi-Fi,
// direct Wi-Fi, Bluetooth, online peer to peer, the relay). One icon per method, drawn from the route's `method` and
// from its `kind` only when no method is named, in list rows and before the route line of the conversation header
// and the details page; the six differ at a glance and match the shapes GTK draws
// (gtk/tests/szfriends_gtk_route_cells.h, which the GTK probes check too). Renders of all six side by side, 1x and
// 2x, light and dark, land with the others for review.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsConversationPage.h"
#import "mac/SZFriendsDetailsPage.h"

#include "gtk/tests/szfriends_gtk_route_cells.h"

#define SZF_SIDE SZFRIENDS_ROUTE_CELLS_SIDE

static NSDictionary *SZFRoute(NSString *kind, id method) {
    return @{@"kind" : kind, @"method" : method ?: NSNull.null, @"label" : @"label"};
}

static void SZFTestGlyphChoice(void) {
    NSArray *cases = @[
        @[ SZFRoute(@"local", @"lan"), @"lan" ], @[ SZFRoute(@"local", @"p2p_wifi"), @"p2p_wifi" ],
        @[ SZFRoute(@"local", @"bluetooth"), @"bluetooth" ], @[ SZFRoute(@"online", @"internet"), @"internet" ],
        @[ SZFRoute(@"online", @"relay"), @"relay" ], @[ SZFRoute(@"local", nil), @"lan" ],
        @[ SZFRoute(@"online", nil), @"internet" ], @[ SZFRoute(@"local", @"carrier_pigeon"), @"lan" ],
        @[ SZFRoute(@"offline", nil), @"offline" ], @[ SZFRoute(@"offline", @"lan"), @"offline" ],
        @[ SZFRoute(@"none", nil), NSNull.null ], @[ SZFRoute(@"warp", @"relay"), NSNull.null ],
        @[ SZFRoute(@"connecting", nil), @"internet" ]
    ];
    for (NSArray *test in cases) {
        NSString *expected = test[1] == NSNull.null ? nil : test[1], *got = SZFriendsRouteGlyph(test[0]);
        SZFExpect(expected ? [got isEqualToString:expected] : got == nil, @"%@ draws %@, not %@", test[0], expected,
                  got);
    }
    SZFExpect(SZFriendsRouteGlyph(nil) == nil, @"no route, no icon");
}

// The glyph drawn black at 48 px (its 12 units at 4 px), as 12 x 12 cells of coverage, top row first.
static void SZFCoverage(NSString *glyph, double cells[SZF_SIDE][SZF_SIDE]) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:4 * SZF_SIDE pixelsHigh:4 * SZF_SIDE bitsPerSample:8
                 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0
                    bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    SZFriendsDrawRouteIcon(glyph, NSMakeRect(0, 0, 4 * SZF_SIDE, 4 * SZF_SIDE), NSColor.blackColor);
    [NSGraphicsContext restoreGraphicsState];
    for (int cy = 0; cy < SZF_SIDE; cy++)
        for (int cx = 0; cx < SZF_SIDE; cx++) {
            double sum = 0;
            for (int y = 0; y < 4; y++)
                for (int x = 0; x < 4; x++) sum += [rep colorAtX:cx * 4 + x y:cy * 4 + y].alphaComponent;
            cells[cy][cx] = sum / 16;
        }
}

// Each glyph against the shared table (inked where it says '#', clear where it says '.'), and every pair told apart
// clearly in at least eight cells. On a mismatch, prints the cells drawn, to compare or to regenerate the table.
static void SZFTestShapes(void) {
    static double cells[SZFRIENDS_ROUTE_CELLS_COUNT][SZF_SIDE][SZF_SIDE];
    for (int i = 0; i < SZFRIENDS_ROUTE_CELLS_COUNT; i++) {
        const SZFriendsRouteCells *shape = &szfriends_route_cells[i];
        SZFCoverage(@(shape->glyph), cells[i]);
        int wrong = 0;
        for (int y = 0; y < SZF_SIDE; y++)
            for (int x = 0; x < SZF_SIDE; x++) {
                char expected = shape->rows[y][x];
                wrong += (expected == '#' && cells[i][y][x] < 0.25) || (expected == '.' && cells[i][y][x] > 0.1);
            }
        SZFExpect(wrong == 0, @"%s: the table's shape (%d cells differ)", shape->glyph, wrong);
        for (int y = 0; wrong && y < SZF_SIDE; y++) {
            fprintf(stderr, "      \"");
            for (int x = 0; x < SZF_SIDE; x++)
                fputc(cells[i][y][x] >= 0.45 ? '#' : cells[i][y][x] <= 0.02 ? '.' : '+', stderr);
            fprintf(stderr, "\"\n");
        }
    }
    for (int a = 0; a < SZFRIENDS_ROUTE_CELLS_COUNT; a++)
        for (int b = a + 1; b < SZFRIENDS_ROUTE_CELLS_COUNT; b++) {
            int differing = 0;
            for (int y = 0; y < SZF_SIDE; y++)
                for (int x = 0; x < SZF_SIDE; x++) differing += fabs(cells[a][y][x] - cells[b][y][x]) > 0.4;
            SZFExpect(differing >= 8, @"%s and %s differ in %d cells", szfriends_route_cells[a].glyph,
                      szfriends_route_cells[b].glyph, differing);
        }
}

// The darkness of each pixel of `rect` (view points) in a 2x render of `view`, as one signature.
static NSArray<NSNumber *> *SZFSignature(NSView *view, NSRect rect, NSString *name) {
    NSString *path = SZFTestRender(view, name, 2);
    NSBitmapImageRep *rep = path ? (NSBitmapImageRep *)[NSBitmapImageRep imageRepWithContentsOfFile:path] : nil;
    NSMutableArray *signature = [NSMutableArray array];
    BOOL flipped = view.isFlipped;
    for (NSInteger y = 0; rep && y < 2 * NSHeight(rect); y++)
        for (NSInteger x = 0; x < 2 * NSWidth(rect); x++) {
            NSInteger top = (NSInteger)(flipped ? 2 * NSMinY(rect) : 2 * (NSHeight(view.bounds) - NSMaxY(rect)));
            NSColor *color = [[rep colorAtX:(NSInteger)(2 * NSMinX(rect)) + x y:top + y]
                colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            [signature addObject:@(1 - (color.redComponent + color.greenComponent + color.blueComponent) / 3)];
        }
    return signature;
}

static NSUInteger SZFDiffering(NSArray<NSNumber *> *a, NSArray<NSNumber *> *b) {
    NSUInteger differing = 0;
    for (NSUInteger i = 0; i < MIN(a.count, b.count); i++) differing += fabs(a[i].doubleValue - b[i].doubleValue) > 0.3;
    return differing + (a.count > b.count ? a.count - b.count : b.count - a.count);
}

// Each route with the words the helper gives it (SZFriendsCatalog route.*), so a render shows icon and line agreeing.
static NSArray<NSDictionary *> *SZFAllRoutes(void) {
    NSArray *routes = @[
        @[ @"local", @"lan", @"Nearby, on your network" ], @[ @"local", @"p2p_wifi", @"Nearby, over direct Wi-Fi" ],
        @[ @"local", @"bluetooth", @"Nearby, over Bluetooth" ], @[ @"online", @"internet", @"Online, direct" ],
        @[ @"online", @"relay", @"Online, through the Friends relay" ],
        @[ @"offline", NSNull.null, @"Not nearby right now" ]
    ];
    NSMutableArray *all = [NSMutableArray array];
    for (NSArray *route in routes) [all addObject:@{@"kind" : route[0], @"method" : route[1], @"label" : route[2]}];
    return all;
}

// Mei's row carries each route in turn: each draws its own icon where the route icon goes.
static void SZFTestRows(void) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    NSMutableArray<NSArray *> *signatures = [NSMutableArray array];
    for (NSDictionary *route in SZFAllRoutes()) {
        SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
        NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
        NSMutableDictionary *data = [SZFTestSnapshot(@"list") mutableCopy];
        NSMutableArray *rows = [data[@"rows"] mutableCopy];
        NSMutableDictionary *mei = [rows[1] mutableCopy];
        mei[@"route"] = route;
        rows[1] = mei;
        data[@"rows"] = rows;
        [page applySnapshot:data];
        [page layoutSubtreeIfNeeded];
        SZFriendsRowView *row = page.rows[1];
        NSString *name = [NSString stringWithFormat:@"route-row-%@", SZFriendsRouteGlyph(route)];
        [signatures addObject:SZFSignature(row, NSMakeRect(NSWidth(row.bounds) - 21, 27, 13, 13), name)];
        (void)window;
    }
    for (NSUInteger a = 0; a < signatures.count; a++)
        for (NSUInteger b = a + 1; b < signatures.count; b++)
            SZFExpect(SZFDiffering(signatures[a], signatures[b]) >= 20, @"rows: %@ and %@ draw different icons (%lu)",
                      SZFriendsRouteGlyph(SZFAllRoutes()[a]), SZFriendsRouteGlyph(SZFAllRoutes()[b]),
                      (unsigned long)SZFDiffering(signatures[a], signatures[b]));
}

// The conversation header as the helper sends it for each route: the route's words as the line, its icon before
// them, inside the line's centred run, one per method, and the words in the button's accessible name. A blocked
// friend's line, "Blocked", comes with a route of kind none and draws no icon.
static void SZFTestHeader(void) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    NSMutableArray<NSArray *> *signatures = [NSMutableArray array];
    NSMutableArray *routes = [SZFAllRoutes() mutableCopy];
    [routes addObject:@{@"kind" : @"none", @"method" : NSNull.null, @"label" : NSNull.null}];
    for (NSDictionary *route in routes) {
        SZFriendsDropdownContent *content = [[SZFriendsDropdownContent alloc] initWithContext:context];
        NSWindow *window = SZFTestHostWindow(content, NSMakeSize(400, 640), NSAppearanceNameAqua);
        [content openConversation:@"c_mei" highlightMessage:nil];
        SZFriendsConversationPage *page = (SZFriendsConversationPage *)content.topPage;
        NSMutableDictionary *data = [SZFTestSnapshot(@"conversation-mei") mutableCopy];
        NSMutableDictionary *header = [data[@"header"] mutableCopy];
        NSString *line = route[@"label"] == NSNull.null ? @"Blocked" : route[@"label"];
        NSString *spoken = [NSString stringWithFormat:@"Mei Lin, %@%@, show details",
                                                      [line substringToIndex:1].lowercaseString,
                                                      [line substringFromIndex:1]];
        header[@"route"] = route;
        header[@"subtitle"] = line;
        header[@"accessibility_label"] = spoken;
        data[@"header"] = header;
        [page applySnapshot:data];
        [content layoutSubtreeIfNeeded];
        SZFExpect([page.header.titleButton.accessibilityLabel isEqualToString:spoken] &&
                      [page.header.titleButton.accessibilityLabel.lowercaseString
                          containsString:line.lowercaseString],
                  @"VoiceOver hears the line: %@", page.header.titleButton.accessibilityLabel);
        NSString *glyph = SZFriendsRouteGlyph(route);
        NSString *name = [NSString stringWithFormat:@"route-header-%@", glyph ?: @"none"];
        (void)SZFTestBitmap(page.header); // draws once, which places the icon
        NSRect icon = page.header.routeIconRect;
        if (!glyph) {
            SZFExpect(NSIsEmptyRect(icon), @"kind none (\"Blocked\"): no icon (%@)", NSStringFromRect(icon));
            (void)SZFTestRender(page.header, @"route-header-blocked", 2);
            continue;
        }
        SZFExpect(NSWidth(icon) == 11 && NSMinY(icon) > NSHeight(page.header.bounds) / 2 - 4 &&
                      NSMaxX(icon) < NSMidX(page.header.bounds),
                  @"%@: an 11 pt icon on the route line, left of the centre: %@", glyph, NSStringFromRect(icon));
        [signatures addObject:SZFSignature(page.header, icon, name)];
        (void)window;
    }
    for (NSUInteger a = 0; a < signatures.count; a++)
        for (NSUInteger b = a + 1; b < signatures.count; b++)
            SZFExpect(SZFDiffering(signatures[a], signatures[b]) >= 20, @"header: icons %lu and %lu differ (%lu)",
                      (unsigned long)a, (unsigned long)b, (unsigned long)SZFDiffering(signatures[a], signatures[b]));
}

// A friend's details page: the same icon before the route's words, as in the header one step before it.
static void SZFTestDetails(void) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    NSMutableArray<NSArray *> *signatures = [NSMutableArray array];
    NSMutableArray *routes = [SZFAllRoutes() mutableCopy];
    [routes addObject:@{@"kind" : @"none", @"method" : NSNull.null, @"label" : NSNull.null}];
    for (NSDictionary *route in routes) {
        SZFriendsDetailsPage *page = [[SZFriendsDetailsPage alloc] initWithContext:context conversationID:@"c_mei"];
        NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 560), NSAppearanceNameAqua);
        NSMutableDictionary *data = [SZFTestSnapshot(@"details-mei") mutableCopy];
        data[@"route"] = route;
        [page applySnapshot:data];
        [page layoutSubtreeIfNeeded];
        NSString *glyph = SZFriendsRouteGlyph(route);
        NSView *icon = page.routeIconView;
        if (!glyph) {
            SZFExpect(icon.hidden, @"kind none: no icon on the details page");
            continue;
        }
        NSRect iconRect = icon.frame, words = page.routeLabel.frame;
        SZFExpect(!icon.hidden && NSWidth(iconRect) == 11 && NSMaxX(iconRect) <= NSMinX(words) &&
                      fabs(NSMidY(iconRect) - NSMidY(words)) <= 1.5 &&
                      [page.routeLabel.stringValue isEqualToString:route[@"label"]],
                  @"%@: an 11 pt icon before the route's words: %@ %@", glyph, NSStringFromRect(iconRect),
                  NSStringFromRect(words));
        NSString *name = [NSString stringWithFormat:@"route-details-%@", glyph];
        [signatures addObject:SZFSignature(icon.superview, iconRect, name)];
        (void)window;
    }
    for (NSUInteger a = 0; a < signatures.count; a++)
        for (NSUInteger b = a + 1; b < signatures.count; b++)
            SZFExpect(SZFDiffering(signatures[a], signatures[b]) >= 20, @"details: icons %lu and %lu differ (%lu)",
                      (unsigned long)a, (unsigned long)b, (unsigned long)SZFDiffering(signatures[a], signatures[b]));
}

// All six in their route colours on the dropdown's background, as rows draw them, 12 pt apart by 10, then the globe
// of an online attempt still connecting, in the offline colour.
static void SZFRenderIcons(void) {
    SZFriendsAppearance *appearance = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL)).appearance;
    for (NSAppearanceName look in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        SZFriendsFlippedView *strip = [[SZFriendsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 160, 24)];
        strip.fillColor = appearance.backgroundColor;
        strip.drawContents = ^(SZFriendsFlippedView *view) {
            (void)view;
            CGFloat x = 8;
            NSMutableArray *routes = [SZFAllRoutes() mutableCopy];
            [routes addObject:@{@"kind" : @"connecting", @"method" : NSNull.null, @"label" : @"Connecting to Mei…"}];
            for (NSDictionary *route in routes) {
                SZFriendsDrawRouteIcon(SZFriendsRouteGlyph(route), NSMakeRect(x, 6, 12, 12),
                                       SZFriendsRouteColor(appearance, route[@"kind"]));
                x += 22;
            }
        };
        NSWindow *window = SZFTestHostWindow(strip, strip.frame.size, look);
        NSString *name = [look isEqualToString:NSAppearanceNameAqua] ? @"route-icons-light" : @"route-icons-dark";
        SZFExpect(SZFTestRender(strip, name, 2) && SZFTestRender(strip, [name stringByAppendingString:@"@1x"], 1),
                  @"%@ written", name);
        (void)window;
    }
}

void SZFTestRouteIcons(void) {
    SZFTestGlyphChoice();
    SZFTestShapes();
    SZFTestRows();
    SZFTestHeader();
    SZFTestDetails();
    SZFRenderIcons();
}
