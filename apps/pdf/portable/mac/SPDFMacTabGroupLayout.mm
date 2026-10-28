#import "SPDFMacCollectionStyle.h"
#import "SPDFMacTabTitleDrawing.h"
#import "SPDFMacIconGeometry.h"
#import "SPDFMacTabStripViewPrivate.h"

@interface SPDFTabGroupLayout : NSObject
@property(nonatomic, strong) SPDFTabGroup* group;
@property(nonatomic) NSRect frame;
@property(nonatomic) NSRect header;
@property(nonatomic) NSRect overflowFrame;
@property(nonatomic) NSInteger firstIndex;
@property(nonatomic) NSInteger capacity;
@property(nonatomic) BOOL visible;
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, NSValue*>* tabRects;
@property(nonatomic, strong) NSMutableArray<NSNumber*>* members;
@end
@implementation SPDFTabGroupLayout
@end

static SPDFTabGroupLayout* EmptyLayout(SPDFTabGroup* group, NSInteger firstIndex, CGFloat height) {
    SPDFTabGroupLayout* layout = [SPDFTabGroupLayout new];
    layout.group = group; layout.firstIndex = firstIndex;
    layout.tabRects = [NSMutableDictionary dictionary]; layout.members = [NSMutableArray array];
    CGFloat labelWidth = MAX(48.0, MIN(group.collectionBackups ? 196.0 : 160.0,
        ceil([group.displayName sizeWithAttributes:
            @{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]}].width)
            + (group.collectionBackups ? 34 : 14)));
    layout.header = NSMakeRect(0, floor((height-20)/2), labelWidth, 20);
    return layout;
}

@implementation SPDFTabStripView (GroupLayout)
- (BOOL)hasTabGroups { return self.tabs.firstObject.group != nil || self.emptyGroups.count > 0; }
- (NSArray<SPDFTabGroup*>*)orderedTabGroups {
    NSMutableArray* groups = [NSMutableArray array]; NSMutableSet* seen = [NSMutableSet set];
    for (SPDFDocumentTab* tab in self.tabs) if (tab.group && ![seen containsObject:tab.group.identifier]) {
        [groups addObject:tab.group]; [seen addObject:tab.group.identifier];
    }
    for (SPDFTabGroup* group in self.emptyGroups) if (![seen containsObject:group.identifier]) {
        [groups addObject:group]; [seen addObject:group.identifier];
    }
    return groups;
}
- (NSArray*)groupLayouts {
    if (![self hasTabGroups]) return nil;
    if (_groupLayout && NSEqualRects(_groupLayoutBounds, self.bounds) && _groupLayoutInset == [self leftInset])
        return _groupLayout;
    _groupLayoutBounds = self.bounds;
    _groupLayoutInset = [self leftInset];
    NSMutableArray<SPDFTabGroupLayout*>* groups = [NSMutableArray array];
    SPDFTabGroupLayout* current = nil;
    for (NSUInteger i = 0; i < self.tabs.count; ++i) {
        SPDFDocumentTab* tab = self.tabs[i];
        if (tab.group.hidden) continue;
        if (current.group != tab.group) {
            current = EmptyLayout(tab.group, i, NSHeight(self.bounds));
            [groups addObject:current];
        }
        if (!tab.group.collapsed) [current.members addObject:@(i)];
    }
    if (self.emptyGroups.count) {
        NSMutableSet* populated = [NSMutableSet set];
        for (SPDFDocumentTab* tab in self.tabs) if (tab.group) [populated addObject:tab.group.identifier];
        for (SPDFTabGroup* group in self.emptyGroups) {
            if (group.hidden || [populated containsObject:group.identifier]) continue;
            [groups addObject:EmptyLayout(group,self.tabs.count,NSHeight(self.bounds))];
            [populated addObject:group.identifier];
        }
    }
    // Keep every non-hidden group in document order. Clipping belongs to the
    // viewport, not admission: scrolling must never silently remove a group.
    CGFloat x = [self leftInset];
    for (SPDFTabGroupLayout* layout in groups) {
        CGFloat start = x;
        layout.visible = YES;
        layout.header = NSOffsetRect(layout.header,x,0);
        x += NSWidth(layout.header);
        BOOL first = YES;
        for (NSNumber* index in layout.members) {
            x += first ? 12 : kTabGap; first = NO;
            CGFloat width = [self preferredWidthForTabAtIndex:index.integerValue];
            layout.tabRects[index] = [NSValue valueWithRect:NSMakeRect(x,
                floor((NSHeight(self.bounds)-24)/2),width,24)];
            x += width;
            ++layout.capacity;
        }
        layout.frame = NSMakeRect(start,4,x-start,NSHeight(self.bounds)-8);
        x += 8;
    }
    CGFloat available = MAX(0,[self tabAreaRightWithOverflow:YES]-[self leftInset]);
    CGFloat collapsedWidth = 0; NSInteger expandedCount=0; SPDFTabGroupLayout* expanded = nil;
    for (SPDFTabGroupLayout* layout in groups) {
        if (layout.group.collapsed || !layout.members.count) collapsedWidth += NSWidth(layout.frame)+8;
        else { expanded = layout; ++expandedCount; }
    }
    _tabPinnedViewport = NSZeroRect;
    BOOL pinned = expandedCount==1 && expanded && available-collapsedWidth-NSWidth(expanded.header)>=180
        && x-[self leftInset]-8>available;
    if (pinned) {
        // Other groups remain discoverable even beside hundreds of documents.
        // Only the expanded group's document lane scrolls; headers keep order.
        CGFloat lane = available-collapsedWidth;
        CGFloat position = [self leftInset];
        for (SPDFTabGroupLayout* layout in groups) {
            CGFloat shift = position-NSMinX(layout.frame);
            layout.header = NSOffsetRect(layout.header,shift,0);
            layout.frame = NSOffsetRect(layout.frame,shift,0);
            for (NSNumber* index in layout.tabRects.allKeys)
                layout.tabRects[index] = [NSValue valueWithRect:NSOffsetRect(layout.tabRects[index].rectValue,shift,0)];
            if (layout==expanded) {
                _tabContentWidth = MAX(0,NSMaxX(layout.frame)-NSMaxX(layout.header)-12);
                NSRect frame=layout.frame; frame.size.width=lane; layout.frame=frame;
                _tabPinnedViewport=NSMakeRect(NSMaxX(layout.header)+12,0,
                    MAX(0,NSMaxX(layout.frame)-NSMaxX(layout.header)-12),NSHeight(self.bounds));
                position += lane+8;
            } else position += NSWidth(layout.frame)+8;
        }
    } else _tabContentWidth = MAX(0,x-[self leftInset]-8);
    NSRect viewport = [self tabViewportRect];
    CGFloat contentStart = pinned ? NSMinX(_tabPinnedViewport) : [self leftInset];
    CGFloat previousOffset=_tabScrollOffset;
    _tabScrollOffset = MIN(MAX(0,_tabScrollOffset),MAX(0,_tabContentWidth-NSWidth(viewport)));
    if (_revealSelectedTab) {
        for (SPDFTabGroupLayout* layout in groups) {
            NSValue* selected = layout.tabRects[@(self.selectedIndex)];
            if (!selected) continue;
            NSRect rect = selected.rectValue;
            // The whole tab, clear of the "+N" badge on either side of it.
            _tabScrollOffset = [self tabScrollOffsetRevealingStart:NSMinX(rect)-contentStart end:NSMaxX(rect)-contentStart
                offset:_tabScrollOffset viewportWidth:NSWidth(viewport) contentWidth:_tabContentWidth];
        }
        _revealSelectedTab = NO;
    }
    CGFloat translation = NSMinX(viewport)-contentStart-_tabScrollOffset;
    for (SPDFTabGroupLayout* layout in groups) {
        if (!pinned) {
            layout.header = NSOffsetRect(layout.header,translation,0);
            layout.frame = NSOffsetRect(layout.frame,translation,0);
        }
        for (NSNumber* index in layout.tabRects.allKeys)
            layout.tabRects[index] = [NSValue valueWithRect:NSOffsetRect(layout.tabRects[index].rectValue,translation,0)];
    }
    _groupLayout = groups;
    if (fabs(previousOffset-_tabScrollOffset)>.01 && self.tabScrollDidChange)
        self.tabScrollDidChange(_tabScrollOffset);
    return groups;
}
- (NSRect)groupedRectForTabAtIndex:(NSInteger)index {
    for (SPDFTabGroupLayout* layout in [self groupLayouts]) {
        NSValue* value = layout.tabRects[@(index)];
        if (value && NSIntersectsRect(value.rectValue,[self tabViewportRect])) return value.rectValue;
    }
    return NSZeroRect;
}
- (NSArray<NSNumber*>*)groupedVisibleTabIndexes {
    NSMutableArray* result = [NSMutableArray array];
    for (SPDFTabGroupLayout* layout in [self groupLayouts])
        for (NSNumber* index in [[layout.tabRects allKeys] sortedArrayUsingSelector:@selector(compare:)])
            if (NSIntersectsRect(layout.tabRects[index].rectValue,[self tabViewportRect])) [result addObject:index];
    return result;
}
- (BOOL)groupedHasOverflow {
    [self groupLayouts];
    return _tabContentWidth > NSWidth([self tabViewportRect])+.5;
}
- (NSInteger)groupInsertionIndexForPoint:(NSPoint)point {
    for (SPDFTabGroupLayout* layout in [self groupLayouts]) {
        if (!NSIsEmptyRect(layout.frame) && point.x < NSMidX(layout.frame)) return layout.firstIndex;
    }
    return self.tabs.count;
}
- (CGFloat)groupInsertionBoundaryForPoint:(NSPoint)point {
    CGFloat last = [self leftInset];
    for (SPDFTabGroupLayout* layout in [self groupLayouts]) {
        if (NSIsEmptyRect(layout.frame)) continue;
        if (point.x < NSMidX(layout.frame)) return NSMinX(layout.frame) - 5;
        last = NSMaxX(layout.frame) + 5;
    }
    return last;
}
- (SPDFTabGroup*)groupAtPoint:(NSPoint)point headerOnly:(BOOL)headerOnly {
    if ([self isPointOnHiddenTabsIndicator:point]) return nil;
    if (point.x<[self leftInset] || point.x>[self tabAreaRightWithOverflow:YES]) return nil;
    for (SPDFTabGroupLayout* layout in [self groupLayouts])
        if (NSPointInRect(point, headerOnly ? layout.header : layout.frame)) return layout.group;
    return nil;
}
- (NSInteger)tabGroupGapInsertionIndexForPoint:(NSPoint)point boundary:(CGFloat*)boundary {
    if (![self hasTabGroups] || !NSPointInRect(point,self.bounds) ||
        point.x<[self leftInset] || point.x>[self tabAreaRightWithOverflow:YES]) return NSNotFound;
    CGFloat previousEnd=NAN;
    for (SPDFTabGroupLayout* layout in [self groupLayouts]) {
        NSRect frame=layout.frame;
        if (NSIsEmptyRect(frame)) continue;
        // Four points into each neighboring edge makes the 8pt visual gap a
        // usable drop target without changing click targets or layout spacing.
        CGFloat left=isnan(previousEnd) ? [self leftInset] : previousEnd-4;
        CGFloat right=NSMinX(frame)+4;
        if (point.x>=left && point.x<=right) {
            if (boundary) *boundary=isnan(previousEnd) ? NSMinX(frame) : (previousEnd+NSMinX(frame))/2;
            return layout.firstIndex;
        }
        previousEnd=NSMaxX(frame);
    }
    if (!isnan(previousEnd) && point.x>=previousEnd-4) {
        if (boundary) *boundary=MIN(previousEnd+4,[self tabAreaRightWithOverflow:YES]);
        return self.tabs.count;
    }
    return NSNotFound;
}
- (SPDFTabGroup*)tabDropGroupAtPoint:(NSPoint)point {
    return [self tabGroupGapInsertionIndexForPoint:point boundary:NULL]!=NSNotFound
        ? nil : [self groupAtPoint:point headerOnly:NO];
}
- (void)drawTabGroups {
    for (SPDFTabGroupLayout* layout in [self groupLayouts]) {
        if (NSIsEmptyRect(layout.frame)) continue;
        NSColor* accent = spdf_tab_group_accent(layout.group.colorName);
        NSColor* label = spdf_tab_group_label(layout.group.colorName);
        // The title tab is a solid chip of the group's colour with a label that keeps 4.5:1 on it; the outline
        // keeps a pale chip (Amber in light) 3:1 apart from the tab bar.
        [accent setFill];
        [[NSBezierPath bezierPathWithRoundedRect:layout.header xRadius:4 yRadius:4] fill];
        [spdf_tab_group_edge(layout.group.colorName) setStroke];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(layout.header, 0.5, 0.5) xRadius:3.5 yRadius:3.5] stroke];
        if (!layout.group.collapsed) {
            [accent setFill];
            [[NSBezierPath bezierPathWithRoundedRect:
                NSMakeRect(NSMinX(layout.frame),4,NSWidth(layout.frame),2) xRadius:1 yRadius:1] fill];
        }
        NSMutableParagraphStyle* style = [[NSMutableParagraphStyle alloc] init];
        style.alignment = NSTextAlignmentCenter;
        style.lineBreakMode = NSLineBreakByTruncatingTail;
        NSDictionary* attributes = @{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName:label, NSParagraphStyleAttributeName:style};
        if (!NSIsEmptyRect(layout.overflowFrame)) {
            // The "+N" badge sits on the tab bar, not on the chip.
            NSMutableDictionary* badge = [attributes mutableCopy];
            badge[NSForegroundColorAttributeName] = SPDFCollectionColor(@"text");
            NSString* remaining = [NSString stringWithFormat:@"+%lu",(unsigned long)(layout.members.count-layout.capacity)];
            [remaining drawInRect:NSInsetRect(layout.overflowFrame,0,4) withAttributes:badge];
        }
        CGFloat iconSpace=layout.group.collectionBackups ? 20 : 0;
        if (iconSpace) {
            SPDFDrawVectorIcon(SPDFChromeSymbol(@"books.vertical",9,NSFontWeightMedium,label),
                               NSMakeRect(NSMinX(layout.header)+5,NSMidY(layout.header)-7,14,14),YES);
        }
        BOOL hovered=_hasLastHoverPoint && NSPointInRect(_lastHoverPoint,layout.header);
        NSRect titleRect=SPDFTabTitleRect(layout.header,7+iconSpace,7,layout.group.displayName,attributes);
        [NSGraphicsContext saveGraphicsState]; NSRectClip(titleRect);
        CGContextRef graphics=NSGraphicsContext.currentContext.CGContext;
        if (hovered) CGContextBeginTransparencyLayer(graphics,NULL);
        SPDFDrawTabTitle(layout.group.displayName,titleRect,attributes);
        // Like tab close buttons: keep the full title geometry and fade beneath
        // overlay actions, without reserving empty space or changing pill width.
        if (hovered) {
            CGFloat edge=NSMaxX(layout.header)-20;
            CGContextSetBlendMode(graphics,kCGBlendModeDestinationOut);
            CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
            CGFloat colors[]={0,0,0,0,0,0,0,1}, stops[]={0,1};
            CGGradientRef fade=CGGradientCreateWithColorComponents(space,colors,stops,2);
            CGContextDrawLinearGradient(graphics,fade,CGPointMake(edge-8,NSMidY(titleRect)),
                CGPointMake(edge,NSMidY(titleRect)),0);
            CGContextSetRGBFillColor(graphics,0,0,0,1);
            CGContextFillRect(graphics,CGRectMake(edge,NSMinY(titleRect),20,NSHeight(titleRect)));
            CGGradientRelease(fade); CGColorSpaceRelease(space); CGContextEndTransparencyLayer(graphics);
        }
        [NSGraphicsContext restoreGraphicsState];
        if (hovered) {
            [NSGraphicsContext saveGraphicsState];
            [[NSBezierPath bezierPathWithRoundedRect:layout.header xRadius:4 yRadius:4] addClip];
            {
                NSRect action = [self groupHideRect:layout.header];
                if (NSPointInRect(_lastHoverPoint,action)) {
                    [[label colorWithAlphaComponent:.18] setFill];
                    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(action,1,1) xRadius:3 yRadius:3] fill];
                }
                SPDFDrawVectorIcon(SPDFChromeSymbol(@"eye.slash",9,NSFontWeightMedium,label),NSInsetRect(action,2,2),YES);
            }
            [NSGraphicsContext restoreGraphicsState];
        }
    }
}
- (void)drawGroupDropPreview {
    if (!isnan(_groupDropBoundaryX)) {
        [spdf_tab_group_accent(_groupPreviewColor) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(_groupDropBoundaryX - 1.5, 5, 3, 32)
            xRadius:1.5 yRadius:1.5] fill];
    }
    NSRect target = NSZeroRect;
    if (_groupDropGroup) {
        for (SPDFTabGroupLayout* layout in [self groupLayouts])
            if (layout.group == _groupDropGroup) target = layout.frame;
    } else if (_groupDropTabIndex >= 0) {
        target = NSInsetRect([self rectForTabAtIndex:_groupDropTabIndex], -3, -3);
    }
    if (NSIsEmptyRect(target)) return;
    NSColor* accent = spdf_tab_group_accent(_groupDropGroup.colorName ?: _groupPreviewColor);
    [[accent colorWithAlphaComponent:0.20] setFill];
    NSBezierPath* outline = [NSBezierPath bezierPathWithRoundedRect:target xRadius:14 yRadius:14];
    [outline fill];
    [accent setStroke];
    outline.lineWidth = 3;
    [outline stroke];
}
@end
