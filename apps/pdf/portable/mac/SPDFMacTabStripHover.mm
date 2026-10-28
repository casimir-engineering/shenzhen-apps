#import "SPDFMacCollectionStyle.h"
#import "SPDFMacTabStripViewPrivate.h"
#import "SPDFMacTabHoverPreview.h"
#import <QuartzCore/CALayer.h>

// The hover label: a 26 pt title bubble 5 pt under the tab, and for a document
// its page thumbnail in a card 6 pt under that.
static const CGFloat kHoverTitleHeight = 26.0;
static const CGFloat kHoverTitleGap = 5.0;
static const CGFloat kHoverCardGap = 6.0;
static const CGFloat kHoverCardInset = 6.0;

// The label's surface: the chrome palette's solid popover colour with a hairline edge, as Codex draws its menus and
// tooltips, rather than a translucent material that takes its colour from whatever is behind the window.
@interface SPDFHoverSurfaceView : NSView
@end
@implementation SPDFHoverSurfaceView
- (BOOL)isOpaque { return NO; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    CGFloat hairline = 1.0 / (self.window.backingScaleFactor ?: 2.0);
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, hairline / 2, hairline / 2)
                                                          xRadius:8.0 yRadius:8.0];
    [SPDFCollectionColor(@"popover") setFill];
    [shape fill];
    [SPDFCollectionColor(@"lineStrong") setStroke];
    shape.lineWidth = hairline;
    [shape stroke];
}
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
@end

static NSView* SPDFHoverMaterialView(NSRect frame) {
    NSView* view = [[SPDFHoverSurfaceView alloc] initWithFrame:frame];
    view.wantsLayer = YES;
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
        // A dot scrolled under a "+N" badge or out of the tab bar is not there to hover.
        if (!NSContainsRect([self visibleRectForTabAtIndex:i], dotRect)) continue;
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
    _hoverTab = nil;
    _hoverAnchorRect = NSZeroRect;
    _hoverGroup = nil;
    [self setNeedsDisplay:YES];
    _hasLastHoverPoint = NO;
    if (_hoverPanel.parentWindow) [_hoverPanel.parentWindow removeChildWindow:_hoverPanel];
    [_hoverPanel orderOut:nil];
}

// The part of a tab that is drawn: its pill, cut to the lane tabs show in and
// never under a "+N" badge, which is drawn over the tabs it stands for. A tab
// scrolled half out of view is only hoverable where it can be seen.
- (NSRect)visibleRectForTabAtIndex:(NSInteger)index {
    NSRect rect = [self rectForTabAtIndex:index];
    if (NSIsEmptyRect(rect)) return NSZeroRect;
    CGFloat left = [self leftInset], right = [self tabAreaRightWithOverflow:YES];
    if ([self hasTabGroups]) {
        NSRect viewport = [self tabViewportRect];
        left = NSMinX(viewport);
        right = NSMaxX(viewport);
        if ([self tabScrollHiddenCountOnLeft:YES] > 0) left = MAX(left, NSMaxX([self tabScrollIndicatorRectOnLeft:YES]));
        if ([self tabScrollHiddenCountOnLeft:NO] > 0) right = MIN(right, NSMinX([self tabScrollIndicatorRectOnLeft:NO]));
    }
    if (right <= left) return NSZeroRect;
    return NSIntersectionRect(rect, NSMakeRect(left, NSMinY(rect), right - left, NSHeight(rect)));
}

// The document tab under the pointer: on its visible pill, never in the gaps
// around and between tabs and groups, the strip above and below them, or the
// part of a tab hidden under a badge or past the tab bar's ends.
- (NSInteger)hoverTabIndexAtPoint:(NSPoint)point {
    if ([self isPointOnHiddenTabsIndicator:point]) return -1;
    for (NSInteger i = 0; i < (NSInteger)self.tabs.count; ++i) {
        NSRect visible = [self visibleRectForTabAtIndex:i];
        if (NSWidth(visible) >= 40.0 && NSPointInRect(point, visible)) return i;
    }
    return -1;
}

- (NSRect)headerRectForGroup:(SPDFTabGroup*)group {
    for (id layout in [self groupLayouts])
        if ([layout valueForKey:@"group"] == group) return [[layout valueForKey:@"header"] rectValue];
    return NSZeroRect;
}

// Tabs were added, closed, moved, scrolled or resized under a pointer that has
// not moved: the label shows for what is under it now, or goes. Once the
// reader's update is done (it sets the tabs and the selection one after the
// other), so the layout is worked out once, for both.
- (void)refreshHoverAfterLayoutChange {
    if (_hoverRefreshScheduled || (!_hasLastHoverPoint && !_hoverPanel.parentWindow && _hoverTabIndex < 0 && !_hoverGroup))
        return;
    _hoverRefreshScheduled = YES;
    __weak SPDFTabStripView* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SPDFTabStripView* strip = weakSelf;
        if (!strip) return;
        strip->_hoverRefreshScheduled = NO;
        if (strip->_hasLastHoverPoint && NSPointInRect(strip->_lastHoverPoint, strip.bounds) && !strip.hidden)
            [strip updateHoverForPoint:strip->_lastHoverPoint];
        else
            [strip dismissHoverPanel];
    });
}

- (void)updateHoverForPoint:(NSPoint)point {
    NSRect previousClose = _hoverTabIndex >= 0 ? [self closeCircleRectForTabRect:[self rectForTabAtIndex:_hoverTabIndex]] : NSZeroRect;
    BOOL wasOnClose = _hasLastHoverPoint && NSPointInRect(_lastHoverPoint,previousClose);
    if ([self isPointOnHiddenTabsIndicator:point]) { [self dismissHoverPanel]; return; }
    _lastHoverPoint = point;
    _hasLastHoverPoint = YES;
    BOOL shown = _hoverPanel.parentWindow == self.window && self.window;
    // A group's title tab gets the same full-name label as a document tab.
    // Always repaint: the title tab draws its hide action on hover.
    SPDFTabGroup* group = [self groupAtPoint:point headerOnly:YES];
    if (group) {
        [self setNeedsDisplay:YES];
        if (group != _hoverGroup || !shown || !NSEqualRects([self headerRectForGroup:group], _hoverAnchorRect))
            [self showHoverPanelForGroup:group];
        return;
    }
    NSInteger hovered = [self hoverTabIndexAtPoint:point];
    SPDFDocumentTab* tab = hovered >= 0 ? self.tabs[(NSUInteger)hovered] : nil;
    BOOL leavingGroup = _hoverGroup != nil;
    _hoverGroup = nil;
    // The same tab, in the same place, still showing: only the close button's hover state can change.
    if (!leavingGroup && hovered == _hoverTabIndex && tab == _hoverTab &&
        (hovered < 0 || (shown && NSEqualRects([self visibleRectForTabAtIndex:hovered], _hoverAnchorRect)))) {
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
    // Under the part of the tab that can be seen: all of it, unless it is scrolled half under a badge.
    NSRect anchor = [self visibleRectForTabAtIndex:index];
    if (![self showHoverPanelWithTitle:[self fullTitleForTabAtIndex:index] belowRect:anchor preview:preview fadeIn:NO])
        return;
    _hoverTabIndex = index;
    _hoverTab = index >= 0 && index < (NSInteger)self.tabs.count ? self.tabs[(NSUInteger)index] : nil;
    _hoverAnchorRect = anchor;
}

// A thumbnail that was not ready on hover (a tab not shown since launch) fades
// in under the title it belongs to, if the pointer is still there.
- (void)hoverPreviewReady:(id<SPDFTabHoverPreview>)preview forTab:(SPDFDocumentTab*)tab {
    NSInteger index = _hoverTabIndex;
    if (!preview || index < 0 || index >= (NSInteger)self.tabs.count || self.tabs[(NSUInteger)index] != tab ||
        _hoverPanel.parentWindow != self.window)
        return;
    [self showHoverPanelWithTitle:[self fullTitleForTabAtIndex:index] belowRect:_hoverAnchorRect
                          preview:preview fadeIn:_hoverCard.hidden];
}

- (void)showHoverPanelForGroup:(SPDFTabGroup*)group {
    NSRect header = [self headerRectForGroup:group];
    // A group's title tab shows its name only: a group holds several documents,
    // and one page of one of them would say less about it than its name does.
    if (![self showHoverPanelWithTitle:group.displayName belowRect:header preview:nil fadeIn:NO]) return;
    _hoverTabIndex = -1;
    _hoverTab = nil;
    _hoverAnchorRect = header;
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
    _hoverLabel.textColor = SPDFCollectionColor(@"text");
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
        [_hoverPanel.appearance performAsCurrentDrawingAppearance:^{ edge = SPDFCollectionColor(@"line").CGColor; }];
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
