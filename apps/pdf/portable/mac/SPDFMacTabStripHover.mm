#import "SPDFMacTabStripViewPrivate.h"

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
    if ([self groupAtPoint:point headerOnly:YES]) {
        [_hoverPanel orderOut:nil]; _hoverTabIndex = -1; [self setNeedsDisplay:YES]; return;
    }
    if (hovered == _hoverTabIndex) {
        if (hovered >= 0 && wasOnClose != NSPointInRect(point,previousClose))
            [self setNeedsDisplayInRect:previousClose];
        return;
    }
    [self setNeedsDisplay:YES];
    if (hovered >= 0) [self showHoverPanelForTabAtIndex:hovered];
    else [self dismissHoverPanel];
}

- (void)showHoverPanelForTabAtIndex:(NSInteger)index {
    NSString* title = [self fullTitleForTabAtIndex:index];
    if (!title.length || !self.window) {
        [self dismissHoverPanel];
        return;
    }

    NSRect tabRect = [self rectForTabAtIndex:index];
    if (NSWidth(tabRect) <= 0) {
        [self dismissHoverPanel];
        return;
    }

    if (!_hoverPanel) {
        _hoverPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 240, 26)
                                                 styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
        _hoverPanel.releasedWhenClosed = NO;
        _hoverPanel.hidesOnDeactivate = YES;
        _hoverPanel.hasShadow = YES;
        _hoverPanel.opaque = NO;
        _hoverPanel.backgroundColor = NSColor.clearColor;

        NSVisualEffectView* bubble = [[NSVisualEffectView alloc] initWithFrame:_hoverPanel.contentView.bounds];
        bubble.translatesAutoresizingMaskIntoConstraints = NO;
        bubble.material = NSVisualEffectMaterialPopover;
        bubble.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        bubble.state = NSVisualEffectStateActive;
        bubble.wantsLayer = YES;
        bubble.layer.cornerRadius = 8.0;
        bubble.layer.masksToBounds = YES;
        _hoverPanel.contentView = bubble;

        _hoverLabel = [NSTextField labelWithString:@""];
        _hoverLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _hoverLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _hoverLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        [bubble addSubview:_hoverLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_hoverLabel.leadingAnchor constraintEqualToAnchor:bubble.leadingAnchor constant:10],
            [_hoverLabel.trailingAnchor constraintEqualToAnchor:bubble.trailingAnchor constant:-10],
            [_hoverLabel.centerYAnchor constraintEqualToAnchor:bubble.centerYAnchor]
        ]];
    }

    _hoverLabel.stringValue = title;
    CGFloat width =
        MIN(420.0, MAX(96.0, [title sizeWithAttributes:@{NSFontAttributeName : _hoverLabel.font}].width + 24));
    NSRect tabScreenRect = [self.window convertRectToScreen:[self convertRect:tabRect toView:nil]];
    NSRect frame =
        NSMakeRect(floor(NSMidX(tabScreenRect) - width / 2.0), floor(NSMinY(tabScreenRect) - 31.0), width, 26.0);
    [_hoverPanel setFrame:frame display:NO];
    if (_hoverPanel.parentWindow != self.window) [self.window addChildWindow:_hoverPanel ordered:NSWindowAbove];
    // orderFront: on a child window pulls the whole parent group to the front of
    // its level, so hovering a tab in an UNFOCUSED window (the tracking area is
    // NSTrackingActiveAlways) would re-stack this window above other windows
    // without a click. Order the bubble relative to its parent instead: it
    // becomes visible without moving the parent in the z-order.
    [_hoverPanel orderWindow:NSWindowAbove relativeTo:self.window.windowNumber];
    _hoverTabIndex = index;
}

- (void)updateHoverForEvent:(NSEvent*)event {
    [self updateHoverForPoint:[self convertPoint:event.locationInWindow fromView:nil]];
}

@end
