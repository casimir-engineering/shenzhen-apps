#import "SPDFMacTabStripViewPrivate.h"
#import "SPDFMacTabHoverPreview.h"
#import <QuartzCore/CALayer.h>

// The hover label: a 26 pt title bubble 5 pt under the tab, and for a document
// its page thumbnail in a card 6 pt under that.
static const CGFloat kHoverTitleHeight = 26.0;
static const CGFloat kHoverTitleGap = 5.0;
static const CGFloat kHoverCardGap = 6.0;
static const CGFloat kHoverCardInset = 6.0;

static NSVisualEffectView* SPDFHoverMaterialView(NSRect frame) {
    NSVisualEffectView* view = [[NSVisualEffectView alloc] initWithFrame:frame];
    view.material = NSVisualEffectMaterialPopover;
    view.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    view.state = NSVisualEffectStateActive;
    view.wantsLayer = YES;
    view.layer.cornerRadius = 8.0;
    view.layer.masksToBounds = YES;
    return view;
}

@implementation SPDFTabStripView (Hover)
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) [self removeTrackingArea:_trackingArea];
    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                 options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                                                         NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:_trackingArea];
    [self rebuildReadOnlyTooltips];
}

// Per-dot helper tooltip for read-only tabs. AppKit-managed (does not go through
// mouseMoved:), so it coexists with the full-title hover panel and never
// interferes with drag tracking. Rebuilt on any layout change.
- (void)rebuildReadOnlyTooltips {
    [self removeAllToolTips];
    for (id layout in [self groupLayouts]) {
        NSRect header=[[layout valueForKey:@"header"] rectValue];
        if (header.origin.x<[self leftInset] || NSMaxX(header)>[self tabAreaRightWithOverflow:YES]) continue;
        [self addToolTipRect:[self groupHideRect:header] owner:self userData:(void*)2];
    }
    for (NSNumber* left in @[@YES,@NO]) if ([self tabScrollHiddenCountOnLeft:left.boolValue]>0)
        [self addToolTipRect:[self tabScrollIndicatorRectOnLeft:left.boolValue] owner:self userData:(void*)(uintptr_t)(left.boolValue ? 3 : 4)];
    for (NSInteger i = 0; i < (NSInteger)self.tabs.count; ++i) {
        SPDFDocumentTab* tab = self.tabs[(NSUInteger)i];
        if ((!tab.readOnly && !tab.unsavedPastedImage) || tab.missingFile) continue;
        NSRect tabRect = [self rectForTabAtIndex:i];
        if (NSWidth(tabRect) < 40.0) continue;
        NSRect dotRect = [self readOnlyDotRectForTabRect:tabRect
                                                diameter:kReadOnlyDotDiameter
                                               leftInset:kReadOnlyDotLeftInset];
        // Pad the hit area so the small dot is easy to hover.
        [self addToolTipRect:NSInsetRect(dotRect, -3.0, -3.0) owner:self userData:NULL];
    }
}

- (NSString*)view:(NSView*)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void*)userData {
    (void)view;
    (void)tag;
    if (userData==(void*)2) return @"Hide group from tab bar. Show it again in All Groups.";
    if (userData==(void*)3 || userData==(void*)4) return @"Show hidden tabs on this side. Use a mouse wheel or two-finger swipe to scroll.";
    NSInteger index = [self tabIndexAtPoint:point];
    if (index >= 0 && index < (NSInteger)self.tabs.count && self.tabs[(NSUInteger)index].unsavedPastedImage)
        return @"Unsaved pasted image. Use Save As to choose an image or PDF file. This tab is kept between launches.";
    if (index >= 0 && index < (NSInteger)self.tabs.count && self.tabs[(NSUInteger)index].collectionVersionLabel.length)
        return [self.tabs[(NSUInteger)index].collectionVersionLabel stringByAppendingString:@". This protected snapshot never changes. Use Save a Copy to create an editable document."];
    return @"Read-only file. You're viewing a local copy, so opening it doesn't "
           @"prompt for access. Changes to the original are picked up automatically "
           @"(and on reopen). Editing will ask to save a copy.";
}

- (void)dismissHoverPanel {
    _hoverTabIndex = -1;
    _hoverGroup = nil;
    [self setNeedsDisplay:YES];
    _hasLastHoverPoint = NO;
    if (_hoverPanel.parentWindow) [_hoverPanel.parentWindow removeChildWindow:_hoverPanel];
    [_hoverPanel orderOut:nil];
}

- (void)updateHoverForPoint:(NSPoint)point {
    if ([self isPointOnHiddenTabsIndicator:point]) { [self dismissHoverPanel]; return; }
    NSInteger hovered = -1;
    NSRect previousClose = _hoverTabIndex >= 0 ? [self closeCircleRectForTabRect:[self rectForTabAtIndex:_hoverTabIndex]] : NSZeroRect;
    BOOL wasOnClose = _hasLastHoverPoint && NSPointInRect(_lastHoverPoint,previousClose);
    _lastHoverPoint = point;
    _hasLastHoverPoint = YES;
    for (NSInteger i = 0; i < (NSInteger)self.tabs.count; ++i) {
        NSRect tabRect = [self rectForTabAtIndex:i];
        if (NSWidth(tabRect) < 40.0) continue;
        if (NSPointInRect(point, tabRect)) {
            hovered = i;
            break;
        }
    }
    // A group's title tab gets the same full-name label as a document tab.
    // Always repaint: the title tab draws its hide action on hover.
    SPDFTabGroup* group = [self groupAtPoint:point headerOnly:YES];
    if (group) {
        [self setNeedsDisplay:YES];
        if (group != _hoverGroup) [self showHoverPanelForGroup:group];
        return;
    }
    BOOL leavingGroup = _hoverGroup != nil;
    _hoverGroup = nil;
    if (hovered == _hoverTabIndex && !leavingGroup) {
        if (hovered >= 0 && wasOnClose != NSPointInRect(point,previousClose))
            [self setNeedsDisplayInRect:previousClose];
        return;
    }
    [self setNeedsDisplay:YES];
    if (hovered >= 0) [self showHoverPanelForTabAtIndex:hovered];
    else [self dismissHoverPanel];
}

- (void)showHoverPanelForTabAtIndex:(NSInteger)index {
    id<SPDFTabHoverPreview> preview = nil;
    id reader = self.reader;
    if (index >= 0 && index < (NSInteger)self.tabs.count && self.window &&
        [reader conformsToProtocol:@protocol(SPDFTabHoverPreviewSource)]) {
        SPDFDocumentTab* tab = self.tabs[(NSUInteger)index];
        __weak SPDFTabStripView* weakSelf = self;
        preview = [(id<SPDFTabHoverPreviewSource>)reader tabHoverPreviewForTab:tab
            backingScale:self.window.backingScaleFactor ready:^(id<SPDFTabHoverPreview> ready) {
                [weakSelf hoverPreviewReady:ready forTab:tab];
            }];
    }
    if (![self showHoverPanelWithTitle:[self fullTitleForTabAtIndex:index] belowRect:[self rectForTabAtIndex:index]
                               preview:preview fadeIn:NO])
        return;
    _hoverTabIndex = index;
}

// A thumbnail that was not ready on hover (a tab not shown since launch) fades
// in under the title it belongs to, if the pointer is still there.
- (void)hoverPreviewReady:(id<SPDFTabHoverPreview>)preview forTab:(SPDFDocumentTab*)tab {
    NSInteger index = _hoverTabIndex;
    if (!preview || index < 0 || index >= (NSInteger)self.tabs.count || self.tabs[(NSUInteger)index] != tab ||
        _hoverPanel.parentWindow != self.window)
        return;
    [self showHoverPanelWithTitle:[self fullTitleForTabAtIndex:index] belowRect:[self rectForTabAtIndex:index]
                          preview:preview fadeIn:_hoverCard.hidden];
}

- (void)showHoverPanelForGroup:(SPDFTabGroup*)group {
    NSRect header = NSZeroRect;
    for (id layout in [self groupLayouts])
        if ([layout valueForKey:@"group"] == group) header = [[layout valueForKey:@"header"] rectValue];
    // A group's title tab shows its name only: a group holds several documents,
    // and one page of one of them would say less about it than its name does.
    if (![self showHoverPanelWithTitle:group.displayName belowRect:header preview:nil fadeIn:NO]) return;
    _hoverTabIndex = -1;
    _hoverGroup = group;
}

- (BOOL)showHoverPanelWithTitle:(NSString*)title belowRect:(NSRect)tabRect {
    return [self showHoverPanelWithTitle:title belowRect:tabRect preview:nil fadeIn:NO];
}

- (void)buildHoverPanel {
    _hoverPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 240, 26)
                                             styleMask:NSWindowStyleMaskBorderless
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    _hoverPanel.releasedWhenClosed = NO;
    _hoverPanel.hidesOnDeactivate = YES;
    _hoverPanel.hasShadow = YES;
    _hoverPanel.opaque = NO;
    _hoverPanel.backgroundColor = NSColor.clearColor;
    // It hangs over the page under the tab: clicks and scrolls go to the page.
    _hoverPanel.ignoresMouseEvents = YES;
    _hoverPanel.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 26)];

    _hoverBubble = SPDFHoverMaterialView(NSMakeRect(0, 0, 240, 26));
    [_hoverPanel.contentView addSubview:_hoverBubble];
    _hoverLabel = [NSTextField labelWithString:@""];
    _hoverLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _hoverLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _hoverLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    [_hoverBubble addSubview:_hoverLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_hoverLabel.leadingAnchor constraintEqualToAnchor:_hoverBubble.leadingAnchor constant:10],
        [_hoverLabel.trailingAnchor constraintEqualToAnchor:_hoverBubble.trailingAnchor constant:-10],
        [_hoverLabel.centerYAnchor constraintEqualToAnchor:_hoverBubble.centerYAnchor]
    ]];
}

// The page thumbnail's card: the title bubble's material and corners, the page
// inset in it with a hairline edge. Made on the first hover that has a page.
- (void)buildHoverCard {
    _hoverCard = SPDFHoverMaterialView(NSMakeRect(0, 0, 100, 100));
    _hoverThumbnail = [[NSView alloc] initWithFrame:NSInsetRect(_hoverCard.bounds, kHoverCardInset, kHoverCardInset)];
    _hoverThumbnail.wantsLayer = YES;
    CALayer* layer = _hoverThumbnail.layer;
    layer.contentsGravity = @"resize"; // kCAGravityResize, without linking QuartzCore into the strip tests
    layer.cornerRadius = 3.0;
    layer.masksToBounds = YES;
    layer.actions = @{@"contents" : NSNull.null, @"bounds" : NSNull.null, @"position" : NSNull.null};
    [_hoverCard addSubview:_hoverThumbnail];
    [_hoverPanel.contentView addSubview:_hoverCard];
}

- (BOOL)showHoverPanelWithTitle:(NSString*)title belowRect:(NSRect)tabRect
                        preview:(id<SPDFTabHoverPreview>)preview fadeIn:(BOOL)fadeIn {
    if (!title.length || !self.window || NSWidth(tabRect) <= 0) {
        [self dismissHoverPanel];
        return NO;
    }
    if (!_hoverPanel) [self buildHoverPanel];
    if (preview && !_hoverCard) [self buildHoverCard];

    _hoverPanel.appearance = self.window.effectiveAppearance;
    _hoverLabel.stringValue = title;
    // Wide enough for the whole name: it is what the label is for. A 75-character group or file name needs about
    // 470 pt; past the window's width it truncates in the middle.
    CGFloat widest = MAX(96.0, MIN(720.0, NSWidth(self.window.frame) - 24.0));
    CGFloat titleWidth =
        MIN(widest, MAX(96.0, ceil([title sizeWithAttributes:@{NSFontAttributeName : _hoverLabel.font}].width) + 24));
    NSSize card = preview ? NSMakeSize(preview.pointSize.width + 2 * kHoverCardInset,
                                       preview.pointSize.height + 2 * kHoverCardInset) : NSZeroSize;
    CGFloat width = MAX(titleWidth, card.width);
    CGFloat height = kHoverTitleHeight + (preview ? kHoverCardGap + card.height : 0);
    // The title sits where it always has, 5 pt under the tab; the page hangs
    // under the title.
    NSRect tabScreenRect = [self.window convertRectToScreen:[self convertRect:tabRect toView:nil]];
    NSRect frame = NSMakeRect(floor(NSMidX(tabScreenRect) - width / 2.0),
                              floor(NSMinY(tabScreenRect) - kHoverTitleGap) - height, width, height);
    // A wide label under a tab near the screen's edge stays on the screen.
    NSRect screen = self.window.screen.visibleFrame;
    if (!NSIsEmptyRect(screen) && width < NSWidth(screen))
        frame.origin.x = MAX(NSMinX(screen) + 4, MIN(NSMinX(frame), NSMaxX(screen) - width - 4));
    _hoverBubble.frame = NSMakeRect(floor((width - titleWidth) / 2.0), height - kHoverTitleHeight, titleWidth,
                                    kHoverTitleHeight);
    _hoverCard.hidden = preview == nil;
    if (preview) {
        _hoverCard.frame = NSMakeRect(floor((width - card.width) / 2.0), 0, card.width, card.height);
        _hoverThumbnail.frame = NSInsetRect(_hoverCard.bounds, kHoverCardInset, kHoverCardInset);
        CALayer* layer = _hoverThumbnail.layer;
        CGFloat scale = self.window.backingScaleFactor ?: 2.0;
        layer.contentsScale = scale;
        layer.contents = (__bridge id)preview.image;
        layer.borderWidth = 1.0 / scale;
        __block CGColorRef edge = NULL;
        [_hoverPanel.appearance performAsCurrentDrawingAppearance:^{ edge = NSColor.separatorColor.CGColor; }];
        layer.borderColor = edge;
    }
    [_hoverPanel setFrame:frame display:NO];
    if (fadeIn && preview) {
        _hoverCard.alphaValue = 0;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
            context.duration = 0.12;
            self->_hoverCard.animator.alphaValue = 1;
        }];
    } else {
        _hoverCard.alphaValue = 1;
    }
    [_hoverPanel invalidateShadow];
    if (_hoverPanel.parentWindow != self.window) [self.window addChildWindow:_hoverPanel ordered:NSWindowAbove];
    // orderFront: on a child window pulls the whole parent group to the front of
    // its level, so hovering a tab in an UNFOCUSED window (the tracking area is
    // NSTrackingActiveAlways) would re-stack this window above other windows
    // without a click. Order the bubble relative to its parent instead: it
    // becomes visible without moving the parent in the z-order.
    [_hoverPanel orderWindow:NSWindowAbove relativeTo:self.window.windowNumber];
    return YES;
}

- (void)updateHoverForEvent:(NSEvent*)event {
    [self updateHoverForPoint:[self convertPoint:event.locationInWindow fromView:nil]];
}

@end
