// Shenzhen Friends views tests: the dropdown's chrome matches the reader's. Default tokens are the reader's palette,
// waiting rows are marked by a bar that hover cannot imitate, hover is the host's hover colour, icon buttons are flat,
// the title navigates with a right chevron, Offline is a crossed dot, the badge clears the second figure, a disabled
// composer looks disabled, a changed key leads the details, copy buttons are 24 pt targets, and a message close to
// the one before it has no time line.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsConversationPage.h"
#import "mac/SZFriendsDetailsPage.h"

static SZFriendsContext *SZFChromeContext(void) {
    return SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
}

static void SZFTestDefaultTokens(void) {
    // The tokens ShenzhenPDF's adapter passes (its Collection palette), so renders made with the defaults show what
    // ships. Light, then dark.
    SZFriendsAppearance *defaults = [SZFriendsAppearance new];
    NSDictionary<NSString *, NSArray<NSNumber *> *> *expected = @{
        @"backgroundColor" : @[ @0xffffff, @0x181818 ], @"primaryTextColor" : @[ @0x0d0d0d, @0xffffff ],
        @"secondaryTextColor" : @[ @0x5d5d5d, @0xb4b4b4 ], @"separatorColor" : @[ @0xe3e3e3, @0x313131 ],
        @"selectionColor" : @[ @0xececec, @0x313131 ], @"accentColor" : @[ @0x1f62d6, @0x83c3ff ],
        @"controlColor" : @[ @0xebebeb, @0x303030 ], @"hoverColor" : @[ @0xf2f2f2, @0x292929 ],
        @"fieldBackgroundColor" : @[ @0xebebeb, @0x303030 ], @"controlBorderColor" : @[ @0xcfcfcf, @0x454545 ],
        @"primaryButtonColor" : @[ @0x1a6ae6, @0x1a6ae6 ], @"destructiveColor" : @[ @0xba2623, @0xff6b66 ],
    };
    for (NSString *key in expected) {
        NSColor *color = [defaults valueForKey:key];
        uint32_t light = SZFTestResolved(color, NSAppearanceNameAqua);
        uint32_t dark = SZFTestResolved(color, NSAppearanceNameDarkAqua);
        SZFExpect(light == expected[key][0].unsignedIntValue && dark == expected[key][1].unsignedIntValue,
                  @"%@ defaults to the reader's %06x / %06x, got %06x / %06x", key, expected[key][0].unsignedIntValue,
                  expected[key][1].unsignedIntValue, light, dark);
    }
}

// One list row in a window of its own, as the list draws it.
static SZFriendsRowView *SZFRow(SZFriendsContext *context, NSDictionary *row, NSAppearanceName name, NSWindow **out) {
    SZFriendsRowView *view = [[SZFriendsRowView alloc] initWithContext:context];
    view.frame = NSMakeRect(0, 0, 388, SZFriendsRowHeight);
    *out = SZFTestHostWindow(view, view.frame.size, name);
    [view configureWithListRow:row];
    [view layoutSubtreeIfNeeded];
    return view;
}

static void SZFTestWaitingAndHover(void) {
    for (NSAppearanceName name in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        SZFriendsContext *context = SZFChromeContext();
        SZFriendsAppearance *appearance = context.appearance;
        uint32_t background = SZFTestResolved(appearance.backgroundColor, name);
        uint32_t hover = SZFTestResolved(appearance.hoverColor, name);
        uint32_t accent = SZFTestResolved(appearance.accentColor, name);
        uint32_t selection = SZFTestResolved(appearance.selectionColor, name);
        NSArray *rows = SZFTestSnapshot(@"list")[@"rows"];
        NSWindow *kenjiWindow = nil, *meiWindow = nil;
        SZFriendsRowView *kenji = SZFRow(context, rows[2], name, &kenjiWindow); // waiting: an offer
        SZFriendsRowView *mei = SZFRow(context, rows[1], name, &meiWindow);     // not waiting
        // A spot inside the row with no text or icon: between the avatar and the title, above the text line.
        NSPoint empty = NSMakePoint(64, 4);
        NSPoint bar = NSMakePoint(NSMidX([kenji waitingBarRect]), NSMidY([kenji waitingBarRect]));
        SZFExpect(SZFTestSameColor(SZFTestPixelAt(kenji, empty), background, 3),
                  @"a waiting row keeps the plain background (%@): %06x", name, SZFTestPixelAt(kenji, empty));
        SZFExpect(SZFTestSameColor(SZFTestPixelAt(kenji, bar), accent, 6), @"its leading bar is the accent: %06x",
                  SZFTestPixelAt(kenji, bar));
        SZFExpect(SZFTestSameColor(SZFTestPixelAt(mei, bar), background, 3), @"a row not waiting has no bar");
        mei.hovered = YES;
        kenji.hovered = YES;
        SZFExpect(SZFTestSameColor(SZFTestPixelAt(mei, empty), hover, 3) &&
                      !SZFTestSameColor(SZFTestPixelAt(mei, empty), selection, 3),
                  @"hover is the host's hover colour, never the selection (%@): %06x", name,
                  SZFTestPixelAt(mei, empty));
        SZFExpect(SZFTestSameColor(SZFTestPixelAt(kenji, empty), hover, 3) &&
                      SZFTestSameColor(SZFTestPixelAt(kenji, bar), accent, 6),
                  @"a hovered waiting row: hover fill, bar kept");
        (void)kenjiWindow, (void)meiWindow;
    }
}

static void SZFTestFlatButtons(void) {
    SZFriendsContext *context = SZFChromeContext();
    SZFriendsHeaderView *header = [[SZFriendsHeaderView alloc] initWithAppearance:context.appearance];
    NSWindow *window = SZFTestHostWindow(header, NSMakeSize(400, SZFriendsHeaderHeight), NSAppearanceNameAqua);
    header.frame = NSMakeRect(0, 0, 400, SZFriendsHeaderHeight);
    [header layoutSubtreeIfNeeded];
    SZFriendsButton *back = header.backButton;
    uint32_t background = SZFTestResolved(context.appearance.backgroundColor, NSAppearanceNameAqua);
    // Near the chrome's corner, clear of the arrow glyph: what the button itself fills.
    NSPoint corner = NSMakePoint(3, 10);
    SZFExpect(SZFTestSameColor(SZFTestPixelAt(back, corner), background, 3), @"the back arrow is flat at rest: %06x",
              SZFTestPixelAt(back, corner));
    back.hovered = YES;
    SZFExpect(SZFTestSameColor(SZFTestPixelAt(back, corner),
                               SZFTestResolved(context.appearance.hoverColor, NSAppearanceNameAqua), 3),
              @"and fills with the hover colour under the pointer: %06x", SZFTestPixelAt(back, corner));

    // The title navigates to details: a chevron pointing right, taller than wide (a chevron down is wider).
    [header setTitle:@"" subtitle:nil subtitleColor:nil clickable:YES accessibilityLabel:@"Mei"];
    [header layoutSubtreeIfNeeded];
    SZFriendsButton *title = header.titleButton;
    NSBitmapImageRep *rep = SZFTestBitmap(title);
    NSInteger minX = NSIntegerMax, maxX = -1, minY = NSIntegerMax, maxY = -1;
    for (NSInteger y = 0; y < rep.pixelsHigh; y++)
        for (NSInteger x = 0; x < rep.pixelsWide; x++)
            if ([rep colorAtX:x y:y].alphaComponent > 0.3 &&
                !SZFTestSameColor(SZFTestBitmapPixel(rep, x, y), background, 40)) {
                minX = MIN(minX, x), maxX = MAX(maxX, x), minY = MIN(minY, y), maxY = MAX(maxY, y);
            }
    SZFExpect(maxX >= 0 && maxY - minY > maxX - minX, @"chevron right: ink %ld x %ld", (long)(maxX - minX + 1),
              (long)(maxY - minY + 1));
    // The title under the pointer takes the hover colour too.
    title.hovered = YES;
    SZFExpect(SZFTestSameColor(SZFTestPixelAt(title, NSMakePoint(3, 3)),
                               SZFTestResolved(context.appearance.hoverColor, NSAppearanceNameAqua), 3),
              @"the hovered title fills with the hover colour: %06x", SZFTestPixelAt(title, NSMakePoint(3, 3)));
    (void)window;
}

// `#` picker rows: the keyboard's choice in a wash of the accent, the pointer's in the hover colour.
static void SZFTestPickerHover(void) {
    SZFTestHost *host = [SZFTestHost new];
    SZFriendsAttachableItem *first = [SZFriendsAttachableItem new], *second = [SZFriendsAttachableItem new];
    first.title = @"Supplier contract v3.pdf";
    second.title = @"Supplier pricing.md";
    host.attachableItems = @[ first, second ];
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(NULL));
    SZFriendsAttachPicker *picker = [[SZFriendsAttachPicker alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(picker, NSMakeSize(380, 200), NSAppearanceNameAqua);
    [picker reloadForQuery:@""];
    SZFExpect(SZFTestWaitUntil(2, ^BOOL { return picker.itemButtons.count == 2; }), @"two picker rows");
    [picker layoutSubtreeIfNeeded];
    SZFriendsButton *chosen = picker.itemButtons.firstObject, *other = picker.itemButtons.lastObject;
    other.hovered = YES;
    NSPoint corner = NSMakePoint(NSWidth(other.bounds) - 6, 3);
    // The keyboard's choice in the accent's wash: neither the hover colour nor the panel's own.
    uint32_t panel = SZFTestResolved(context.appearance.controlColor, NSAppearanceNameAqua);
    SZFExpect(SZFTestSameColor(SZFTestPixelAt(other, corner),
                               SZFTestResolved(context.appearance.hoverColor, NSAppearanceNameAqua), 3) &&
                  !SZFTestSameColor(SZFTestPixelAt(chosen, corner), SZFTestPixelAt(other, corner), 6) &&
                  !SZFTestSameColor(SZFTestPixelAt(chosen, corner), panel, 6) &&
                  (SZFTestPixelAt(chosen, corner) & 0xff) > ((SZFTestPixelAt(chosen, corner) >> 16) & 0xff),
              @"hover %06x, choice %06x, panel %06x", SZFTestPixelAt(other, corner), SZFTestPixelAt(chosen, corner),
              panel);
    (void)window;
}

// A route icon drawn black in 48 x 48 px: its 12 units at 4 px each.
static NSBitmapImageRep *SZFRouteIconRep(NSString *kind) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:48 pixelsHigh:48 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
                        isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    SZFriendsDrawRouteIcon(kind, NSMakeRect(0, 0, 48, 48), NSColor.blackColor);
    [NSGraphicsContext restoreGraphicsState];
    return rep;
}

// Offline: a hollow dot crossed by a slash. Its centre is inked (the slash); a point inside the ring off the slash
// is not (hollow). The dashed ring it replaces left the centre empty.
static void SZFTestOfflineIcon(void) {
    NSBitmapImageRep *rep = SZFRouteIconRep(@"offline");
    // (6, 6) is the centre, on the slash; (4.5, 4.5) lies inside the ring, off the slash (along x + y = 12).
    CGFloat centre = [rep colorAtX:24 y:24].alphaComponent, inside = [rep colorAtX:18 y:18].alphaComponent;
    SZFExpect(centre > 0.5 && inside < 0.1, @"a crossed hollow dot: centre %.2f, inside %.2f", centre, inside);
}

// Nearby: a dot between two pairs of arcs, ((•)), as GTK draws it. The gap between the dot (radius 1.4) and the inner
// arcs (radius 3.4, stroke 1.2) stays clear all round; the arcs show left and right, never above or below. Drawn as
// one path, each arc began with a line from the last one's end, crossing the dot as a bowtie.
static void SZFTestLocalIcon(void) {
    NSBitmapImageRep *rep = SZFRouteIconRep(@"local");
    NSUInteger crossed = 0;
    for (int step = 0; step < 32; step++) {
        double angle = step * M_PI / 16, radius = 2.4 * 4; // units to pixels
        NSInteger x = (NSInteger)lround(24 + radius * cos(angle)), y = (NSInteger)lround(24 + radius * sin(angle));
        if ([rep colorAtX:x y:y].alphaComponent > 0.1) crossed++;
    }
    CGFloat dot = [rep colorAtX:24 y:24].alphaComponent, left = [rep colorAtX:24 - 14 y:24].alphaComponent;
    CGFloat right = [rep colorAtX:24 + 14 y:24].alphaComponent, top = [rep colorAtX:24 y:24 - 14].alphaComponent;
    SZFExpect(crossed == 0 && dot > 0.5 && left > 0.5 && right > 0.5 && top < 0.1,
              @"((•)): %lu inked points between dot and arcs, dot %.2f, left %.2f, right %.2f, top %.2f",
              (unsigned long)crossed, dot, left, right, top);
}

// The waiting count sits in the corner, clear of the second figure's head, so the icon still reads as two people.
static void SZFTestTitleBadge(void) {
    SZFriendsContext *context = SZFChromeContext();
    for (NSString *label in @[ @"2", @"12", @"99+" ]) {
        SZFriendsTitleButton *button = [[SZFriendsTitleButton alloc] initWithContext:context];
        NSWindow *window = SZFTestHostWindow(button, NSMakeSize(28, 28), NSAppearanceNameAqua);
        button.badgeLabel = label;
        NSRect head = SZFriendsPeopleIconSecondHeadRect([button iconRect]);
        SZFExpect(!NSIntersectsRect(head, [button badgeRect]) && NSContainsRect(button.bounds, [button badgeRect]) &&
                      NSContainsRect(button.bounds, [button iconRect]),
                  @"badge %@ %@ clears the head %@ inside the button", label, NSStringFromRect([button badgeRect]),
                  NSStringFromRect(head));
        (void)window;
    }
    // Drawn: the badge hides almost none of the icon (old corner badge hid the second head).
    NSUInteger (^inked)(SZFriendsTitleButton *) = ^NSUInteger(SZFriendsTitleButton *button) {
        NSString *path = SZFTestRender(button, @"title-button-badge-probe", 4);
        NSBitmapImageRep *rep = path ? (NSBitmapImageRep *)[NSBitmapImageRep imageRepWithContentsOfFile:path] : nil;
        NSUInteger count = 0;
        for (NSInteger y = 0; y < rep.pixelsHigh; y++)
            for (NSInteger x = 0; x < rep.pixelsWide; x++) {
                NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                if (c.alphaComponent > 0.5 && c.redComponent < 0.35 && c.greenComponent < 0.35) count++;
            }
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        return count;
    };
    SZFriendsTitleButton *plain = [[SZFriendsTitleButton alloc] initWithContext:context];
    SZFriendsTitleButton *badged = [[SZFriendsTitleButton alloc] initWithContext:context];
    NSWindow *plainWindow = SZFTestHostWindow(plain, NSMakeSize(28, 28), NSAppearanceNameAqua);
    NSWindow *badgedWindow = SZFTestHostWindow(badged, NSMakeSize(28, 28), NSAppearanceNameAqua);
    badged.badgeLabel = @"2";
    NSUInteger whole = inked(plain), shown = inked(badged);
    SZFExpect(whole > 0 && shown * 100 >= whole * 97, @"the icon stays whole beside the badge: %lu of %lu px",
              (unsigned long)shown, (unsigned long)whole);
    (void)plainWindow, (void)badgedWindow;
}

static void SZFTestDisabledComposer(void) {
    SZFriendsContext *context = SZFChromeContext();
    SZFriendsComposerView *composer = [[SZFriendsComposerView alloc] initWithContext:context conversationID:@"c_mei"];
    NSWindow *window = SZFTestHostWindow(composer, NSMakeSize(400, 140), NSAppearanceNameAqua);
    NSMutableDictionary *data = [SZFTestSnapshot(@"conversation-mei")[@"composer"] mutableCopy];
    [composer applyComposer:data];
    [composer layoutSubtreeIfNeeded];
    NSString *hint = SZFriendsRichText(data[@"hint"], [NSFont systemFontOfSize:11], NSColor.textColor,
                                       context.appearance).string;
    NSTextField *hintLabel = nil;
    for (NSTextField *field in SZFTestSubviews(composer, NSTextField.class))
        if (hint.length && [field.stringValue isEqualToString:hint]) hintLabel = field;
    SZFExpect(hintLabel && !hintLabel.hidden, @"enabled: the attach hint shows");
    NSPoint inBox = NSMakePoint(NSMaxX(composer.inputBox.frame) - 8, NSMidY(composer.inputBox.frame));
    uint32_t enabledFill = SZFTestPixelAt(composer, inBox);
    data[@"enabled"] = @NO;
    [composer applyComposer:data];
    [composer layoutSubtreeIfNeeded];
    SZFExpect(hintLabel.hidden, @"disabled: the attach and drop hint goes");
    SZFExpect(!SZFTestSameColor(SZFTestPixelAt(composer, inBox), enabledFill, 2),
              @"disabled: the field's fill dims (%06x, was %06x)", SZFTestPixelAt(composer, inBox), enabledFill);
    SZFExpect(!composer.textView.editable && !composer.sendButton.enabled, @"and takes no text");
    // Send fades as a whole, not grey text on full blue.
    SZFriendsButton *send = composer.sendButton;
    uint32_t primary = SZFTestResolved(context.appearance.primaryButtonColor, NSAppearanceNameAqua);
    uint32_t sendFill = SZFTestPixelAt(send, NSMakePoint(4, NSMidY(send.bounds)));
    SZFExpect(!SZFTestSameColor(sendFill, primary, 8), @"a disabled Send is faded: %06x vs %06x", sendFill, primary);
    (void)window;
}

static NSView *SZFLabelWithText(NSView *root, NSString *text) {
    for (NSTextField *field in SZFTestSubviews(root, NSTextField.class))
        if ([field.stringValue isEqualToString:text]) return field;
    return nil;
}

static void SZFTestDetailsOrderAndTargets(void) {
    SZFriendsContext *context = SZFChromeContext();
    SZFriendsDetailsPage *details = [[SZFriendsDetailsPage alloc] initWithContext:context conversationID:@"c_mei"];
    NSWindow *window = SZFTestHostWindow(details, NSMakeSize(400, 640), NSAppearanceNameAqua);
    NSMutableDictionary *data = [SZFTestSnapshot(@"details-mei") mutableCopy];
    data[@"key_change"] = @{@"title" : @"Mei’s key changed", @"body" : @"Compare codes with Mei before you go on.",
                            @"actions" : @[ @{@"action" : @"accept_key_change", @"label" : @"Codes match",
                                              @"style" : @"primary"} ]};
    [details applySnapshot:data];
    [details layoutSubtreeIfNeeded];
    NSView *keyTitle = SZFLabelWithText(details, @"Mei’s key changed");
    NSView *verify = SZFLabelWithText(details, data[@"verification"][@"label"]);
    NSRect key = [keyTitle convertRect:keyTitle.bounds toView:details];
    NSRect code = [verify convertRect:verify.bounds toView:details];
    NSRect idLine = [details.cpyButton convertRect:details.cpyButton.bounds toView:details];
    SZFExpect(keyTitle && verify && NSMinY(key) < NSMinY(code) && NSMinY(key) > NSMaxY(idLine),
              @"the key-change card leads, under the ID and before verification: %@ / %@", NSStringFromRect(key),
              NSStringFromRect(code));
    SZFExpect(NSEqualSizes(details.cpyButton.frame.size, NSMakeSize(24, 24)), @"details Copy is a 24 pt target: %@",
              NSStringFromSize(details.cpyButton.frame.size));
    SZFExpect(SZFTestMissedHits(details.cpyButton, window.contentView) == 0, @"with full-bounds hits");

    SZFriendsListPage *list = [[SZFriendsListPage alloc] initWithContext:context];
    NSWindow *listWindow = SZFTestHostWindow(list, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [list applySnapshot:SZFTestSnapshot(@"list")];
    [list layoutSubtreeIfNeeded];
    SZFExpect(NSEqualSizes(list.footer.cpyButton.frame.size, NSMakeSize(24, 24)),
              @"footer Copy is a 24 pt target: %@", NSStringFromSize(list.footer.cpyButton.frame.size));
    SZFExpect(SZFTestMissedHits(list.footer.cpyButton, listWindow.contentView) == 0 &&
                  SZFTestMissedHits(list.footer.nameButton, listWindow.contentView) == 0,
              @"Copy and the name keep separate full-bounds targets");
    (void)window;
}

// A message within minutes of the one before it carries no time (time_label null); with no status or action
// either, it has no line under its bubble, so more of the conversation fits.
static void SZFTestGroupedMessages(void) {
    SZFriendsContext *context = SZFChromeContext();
    NSDictionary *timed = @{@"kind" : @"message", @"item_id" : @"m_1", @"direction" : @"in", @"text" : @"On my way",
                            @"segments" : @[ @{@"text" : @"On my way"} ], @"time_label" : @"14:32",
                            @"status" : NSNull.null, @"actions" : @[], @"highlighted" : @NO,
                            @"accessibility_label" : @"Mei, 14:32: On my way"};
    NSMutableDictionary *grouped = [timed mutableCopy];
    grouped[@"item_id"] = @"m_2";
    grouped[@"time_label"] = NSNull.null;
    SZFriendsItemView *first = [SZFriendsItemView viewForItem:timed context:context];
    SZFriendsItemView *second = [SZFriendsItemView viewForItem:grouped context:context];
    CGFloat withTime = [first heightForWidth:372], without = [second heightForWidth:372];
    SZFExpect(without + 15 <= withTime, @"no time line under a grouped message: %.0f vs %.0f", without, withTime);
}

static void SZFTestProfileWithoutQR(void) {
    SZFriendsContext *context = SZFChromeContext();
    SZFriendsProfilePage *profile = [[SZFriendsProfilePage alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(profile, NSMakeSize(400, 640), NSAppearanceNameAqua);
    NSMutableDictionary *data = [SZFTestSnapshot(@"profile-unreserved") mutableCopy];
    NSMutableDictionary *identifier = [data[@"id"] mutableCopy];
    identifier[@"qr_label"] = NSNull.null;
    identifier[@"qr_payload"] = NSNull.null;
    data[@"id"] = identifier;
    [profile applySnapshot:data];
    [profile layoutSubtreeIfNeeded];
    SZFExpect(profile.qrButton.hidden, @"no QR button without a QR");
    for (NSView *view in SZFTestSubviews(profile, NSView.class))
        if ([view.className isEqualToString:@"SZFriendsQRView"])
            SZFExpect(view.hidden || NSIsEmptyRect(view.frame), @"no QR drawn");
    (void)window;
}

void SZFTestChrome(void) {
    SZFTestDefaultTokens();
    SZFTestWaitingAndHover();
    SZFTestFlatButtons();
    SZFTestPickerHover();
    SZFTestOfflineIcon();
    SZFTestLocalIcon();
    SZFTestTitleBadge();
    SZFTestDisabledComposer();
    SZFTestDetailsOrderAndTargets();
    SZFTestGroupedMessages();
    SZFTestProfileWithoutQR();
}
