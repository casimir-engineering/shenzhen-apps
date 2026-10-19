#import "SPDFMacTabStripViewPrivate.h"

@implementation SPDFTabStripView (Scrolling)
- (NSRect)tabViewportRect {
    CGFloat left = NSIsEmptyRect(_tabPinnedViewport) ? [self leftInset] : NSMinX(_tabPinnedViewport);
    CGFloat right = NSIsEmptyRect(_tabPinnedViewport) ? [self tabAreaRightWithOverflow:YES] : NSMaxX(_tabPinnedViewport);
    return NSMakeRect(left,0,MAX(0,right-left),NSHeight(self.bounds));
}
- (NSRect)tabScrollIndicatorRectOnLeft:(BOOL)left {
    NSRect viewport = [self tabViewportRect];
    NSString* label=[NSString stringWithFormat:@"+%ld",(long)[self tabScrollHiddenCountOnLeft:left]];
    CGFloat width=MAX(36,ceil([label sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12]}].width)+12);
    return NSMakeRect(left ? NSMinX(viewport) : NSMaxX(viewport)-width,
        floor((NSHeight(self.bounds)-24)/2),width,24);
}
- (NSInteger)tabScrollHiddenCountOnLeft:(BOOL)left {
    if (![self hasTabGroups]) return 0;
    NSInteger count = 0; NSRect viewport = [self tabViewportRect];
    for (id layout in [self groupLayouts]) {
        NSRect header = [[layout valueForKey:@"header"] rectValue];
        SPDFTabGroup* group = [layout valueForKey:@"group"];
        if (NSIsEmptyRect(_tabPinnedViewport) && (group.collapsed || ![[layout valueForKey:@"tabRects"] count]) && (left ? NSMinX(header)<NSMinX(viewport)-.5 : NSMaxX(header)>NSMaxX(viewport)+.5)) ++count;
        NSDictionary* rects = [layout valueForKey:@"tabRects"];
        for (NSValue* value in rects.allValues) {
            NSRect rect = value.rectValue;
            if (left ? NSMinX(rect)<NSMinX(viewport)-.5 : NSMaxX(rect)>NSMaxX(viewport)+.5) ++count;
        }
    }
    return count;
}
- (void)scrollTabStripBy:(CGFloat)delta {
    if (![self hasTabGroups] || fabs(delta)<.01) return;
    [self groupLayouts];
    CGFloat next = MIN(MAX(0,_tabScrollOffset+delta),MAX(0,_tabContentWidth-NSWidth([self tabViewportRect])));
    if (fabs(next-_tabScrollOffset)<.01) return;
    _tabScrollOffset = next; _groupLayout = nil; _revealSelectedTab = NO;
    if (self.tabScrollDidChange) self.tabScrollDidChange(next);
    _accessibilityChildrenSnapshot = nil;
    [self dismissHoverPanel]; [self rebuildReadOnlyTooltips]; [self setNeedsDisplay:YES];
}
- (void)scrollWheel:(NSEvent*)event {
    // Trackpads supply pixel deltas and momentum; a vertical mouse wheel is
    // equally useful over this horizontal-only surface. Never select a tab.
    CGFloat delta = fabs(event.scrollingDeltaX)>fabs(event.scrollingDeltaY)
        ? event.scrollingDeltaX : event.scrollingDeltaY;
    [self scrollTabStripBy:-delta*(event.hasPreciseScrollingDeltas ? 1 : 20)];
}
- (BOOL)isPointOnHiddenTabsIndicator:(NSPoint)point {
    for (NSNumber* left in @[@YES,@NO])
        if ([self tabScrollHiddenCountOnLeft:left.boolValue]>0 &&
            NSPointInRect(point,[self tabScrollIndicatorRectOnLeft:left.boolValue])) return YES;
    return NO;
}
- (BOOL)handleTabScrollMouseDown:(NSEvent*)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    for (NSNumber* left in @[@YES,@NO]) {
        if ([self tabScrollHiddenCountOnLeft:left.boolValue] > 0 &&
            NSPointInRect(point,[self tabScrollIndicatorRectOnLeft:left.boolValue])) {
            [self showHiddenTabsOnLeft:left.boolValue];
            return YES;
        }
    }
    return NO;
}
- (NSMenu*)hiddenTabsMenuOnLeft:(BOOL)left {
    NSMenu* menu=[[NSMenu alloc] initWithTitle:left ? @"Tabs to the left" : @"Tabs to the right"];
    NSRect viewport=[self tabViewportRect];
    for (id layout in [self groupLayouts]) {
        SPDFTabGroup* group=[layout valueForKey:@"group"];
        NSRect header=[[layout valueForKey:@"header"] rectValue];
        BOOL hiddenGroup=NSIsEmptyRect(_tabPinnedViewport) && (group.collapsed || ![[layout valueForKey:@"tabRects"] count]) &&
            (left ? NSMinX(header)<NSMinX(viewport)-.5 : NSMaxX(header)>NSMaxX(viewport)+.5);
        NSDictionary* rects=[layout valueForKey:@"tabRects"];
        BOOL headingAdded=NO;
        if (hiddenGroup && !spdf_tab_group_members(self.tabs,group).count) {
            NSMenuItem* heading=[menu addItemWithTitle:group.displayName
                action:@selector(browseGroupFromMenu:) keyEquivalent:@""];
            heading.target=self; heading.representedObject=group;
            heading.image=spdf_tab_group_swatch_image(group.colorName);
        }
        for (NSUInteger index=0;index<self.tabs.count;index++) {
            if (self.tabs[index].group!=group) continue;
            NSValue* value=rects[@(index)]; NSRect rect=value.rectValue;
            if (!hiddenGroup && (!value || !(left ? NSMinX(rect)<NSMinX(viewport)-.5 : NSMaxX(rect)>NSMaxX(viewport)+.5))) continue;
            if (!headingAdded) {
                if (menu.numberOfItems) [menu addItem:NSMenuItem.separatorItem];
                NSMenuItem* heading=[menu addItemWithTitle:group.displayName action:nil keyEquivalent:@""];
                heading.image=spdf_tab_group_swatch_image(group.colorName); headingAdded=YES;
            }
            NSMenuItem* item=[menu addItemWithTitle:[self fullTitleForTabAtIndex:index]
                action:@selector(overflowTabMenuItemSelected:) keyEquivalent:@""];
            item.target=self; item.representedObject=@(index); item.indentationLevel=1;
            item.state=index==(NSUInteger)self.selectedIndex ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
    return menu;
}
- (void)showHiddenTabsOnLeft:(BOOL)left {
    NSMenu* menu=[self hiddenTabsMenuOnLeft:left];
    if (!menu.numberOfItems) return;
    [self dismissHoverPanel];
    NSRect rect=[self tabScrollIndicatorRectOnLeft:left];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSMinX(rect),NSMaxY(rect)) inView:self];
}
- (void)fadeTabScrollEdges {
    CGContextRef graphics=NSGraphicsContext.currentContext.CGContext;
    // Fade tab content only: group underlines at y=4..6 must remain continuous
    // beneath both overflow badges, including the gradient beside each badge.
    NSRect fadeViewport = [self tabViewportRect];
    fadeViewport.origin.y = 6; fadeViewport.size.height = MAX(0,NSHeight(self.bounds)-6);
    [NSGraphicsContext saveGraphicsState]; NSRectClip(fadeViewport);
    CGContextSetBlendMode(graphics,kCGBlendModeDestinationOut);
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGFloat colors[]={0,0,0,1,0,0,0,0}, stops[]={0,1};
    CGGradientRef fade=CGGradientCreateWithColorComponents(space,colors,stops,2);
    for (NSNumber* left in @[@YES,@NO]) if ([self tabScrollHiddenCountOnLeft:left.boolValue]>0) {
        NSRect rect=[self tabScrollIndicatorRectOnLeft:left.boolValue];
        CGFloat edge=left.boolValue ? NSMaxX(rect) : NSMinX(rect), direction=left.boolValue ? 1 : -1;
        CGContextSetRGBFillColor(graphics,0,0,0,1);
        CGContextFillRect(graphics,CGRectMake(NSMinX(rect),0,NSWidth(rect),NSHeight(self.bounds)));
        CGContextDrawLinearGradient(graphics,fade,CGPointMake(edge,NSMidY(rect)),
            CGPointMake(edge+direction*12,NSMidY(rect)),0);
    }
    CGGradientRelease(fade); CGColorSpaceRelease(space); [NSGraphicsContext restoreGraphicsState];
}
- (NSRect)groupHideRect:(NSRect)header {
    return NSMakeRect(NSMaxX(header)-20,NSMidY(header)-10,20,20);
}
@end
