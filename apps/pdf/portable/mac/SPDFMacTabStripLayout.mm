#import "SPDFMacTabStripViewPrivate.h"
#import "SPDFMacSupport.h"

@implementation SPDFTabStripView (Layout)
- (CGFloat)tabWidth {
    NSInteger count = MAX(1, (NSInteger)[self visibleTabIndexes].count);
    CGFloat available = [self tabAreaWidthWithOverflow:[self hasOverflowTabs]] - (count - 1) * kTabGap;
    if (available <= 0) return kTabMinVisibleWidth;
    return MAX(1.0, MIN(kTabMaxWidth, floor(available / count)));
}

- (CGFloat)leftInset {
    return MAX(16.0, self.reservedLeadingInset > 0 ? self.reservedLeadingInset : 138.0);
}

- (NSRect)plusRect {
    CGFloat end=[self leftInset];
    if ([self hasTabGroups]) {
        for (id layout in [self groupLayouts]) {
            NSRect frame=[[layout valueForKey:@"frame"] rectValue];
            if (!NSIsEmptyRect(frame)) end=MAX(end,NSMaxX(frame));
        }
    } else for (NSNumber* index in [self visibleTabIndexes]) end=MAX(end,NSMaxX([self rectForTabAtIndex:index.integerValue]));
    // Six points between 28pt controls keeps their expanded hit targets disjoint.
    CGFloat x=MIN(end+8,MAX([self leftInset],NSMinX([self overflowRectAssumingVisible])-34));
    return NSMakeRect(x,floor((NSHeight(self.bounds)-28)/2),28,28);
}
- (NSRect)overflowRectAssumingVisible {
    return NSMakeRect(MAX([self leftInset]+32,NSWidth(self.bounds)-36), floor((NSHeight(self.bounds)-28)/2),28,28);
}

- (CGFloat)tabAreaRightWithOverflow:(BOOL)overflow {
    (void)overflow;
    return MAX([self leftInset], NSMinX([self overflowRectAssumingVisible])-42);
}

- (CGFloat)tabAreaWidthWithOverflow:(BOOL)overflow {
    return MAX(0.0, [self tabAreaRightWithOverflow:overflow] - [self leftInset]);
}

- (NSInteger)selectedIndexForLayout {
    NSInteger count = (NSInteger)self.tabs.count;
    if (count <= 0) return -1;
    if (self.selectedIndex < 0) return 0;
    return MIN(self.selectedIndex, count - 1);
}

- (NSInteger)visibleTabCapacityWithOverflow:(BOOL)overflow {
    NSInteger count = (NSInteger)self.tabs.count;
    if (count <= 0) return 0;

    CGFloat areaWidth = [self tabAreaWidthWithOverflow:overflow];
    if (areaWidth <= 0) return 1;

    NSInteger capacity = (NSInteger)floor((areaWidth + kTabGap) / (kTabMinVisibleWidth + kTabGap));
    return MAX(1, MIN(count, capacity));
}

- (BOOL)hasOverflowTabs {
    if ([self hasTabGroups]) return [self groupedHasOverflow];
    return [self visibleTabIndexes].count < self.tabs.count;
}

- (NSArray<NSNumber*>*)visibleTabIndexes {
    if ([self hasTabGroups]) return [self groupedVisibleTabIndexes];
    CGFloat room = [self tabAreaWidthWithOverflow:YES];
    if (_ungroupedVisibleIndexes && _ungroupedLayoutWidth==room) return _ungroupedVisibleIndexes;
    _ungroupedLayoutWidth=room;
    NSInteger count = self.tabs.count, selected = [self selectedIndexForLayout];
    NSMutableArray<NSNumber*>* indexes = [NSMutableArray array];
    // Preserve the current tab and nearby siblings without stretching short names.
    for (NSInteger distance=0;distance<count;distance++) {
        for (NSNumber* value in distance ? @[@(selected-distance),@(selected+distance)] : @[@(selected)]) {
            NSInteger index=value.integerValue;
            if (index<0 || index>=count) continue;
            CGFloat width = [self preferredWidthForTabAtIndex:index] + (indexes.count ? kTabGap : 0);
            if (width>room && indexes.count) continue;
            [indexes addObject:value]; room -= width;
        }
    }
    _ungroupedVisibleIndexes=[indexes sortedArrayUsingSelector:@selector(compare:)];
    return _ungroupedVisibleIndexes;
}

- (NSArray<NSNumber*>*)hiddenTabIndexes {
    if (![self hasOverflowTabs]) return @[];

    NSMutableIndexSet* visibleIndexes = [NSMutableIndexSet indexSet];
    for (NSNumber* index in [self visibleTabIndexes]) { [visibleIndexes addIndex:(NSUInteger)index.integerValue]; }

    NSMutableArray<NSNumber*>* hiddenIndexes = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)self.tabs.count; ++i) {
        if (!self.tabs[(NSUInteger)i].group.hidden && ![visibleIndexes containsIndex:(NSUInteger)i]) [hiddenIndexes addObject:@(i)];
    }
    return hiddenIndexes;
}

- (NSRect)overflowRect {
    return [self overflowRectAssumingVisible];
}

- (NSRect)rectForTabAtIndex:(NSInteger)index {
    if ([self hasTabGroups]) return [self groupedRectForTabAtIndex:index];
    NSArray<NSNumber*>* visibleIndexes = [self visibleTabIndexes];
    NSUInteger visiblePosition = [visibleIndexes indexOfObject:@(index)];
    if (visiblePosition == NSNotFound) return NSZeroRect;

    CGFloat x = [self leftInset];
    for (NSUInteger i=0;i<visiblePosition;i++) x += [self preferredWidthForTabAtIndex:visibleIndexes[i].integerValue]+kTabGap;
    CGFloat maxRight = [self tabAreaRightWithOverflow:YES];
    CGFloat width = MAX(0,MIN([self preferredWidthForTabAtIndex:index], maxRight-x));
    return NSMakeRect(x, floor((NSHeight(self.bounds) - 24) / 2), width, 24);
}

- (NSRect)interactionRectForTabRect:(NSRect)tabRect {
    if (NSIsEmptyRect(tabRect)) return NSZeroRect;
    NSRect rect = NSInsetRect(tabRect, -kTabGap/2, -10.0);
    rect.origin.y = NSMinY(self.bounds);
    rect.size.height = NSHeight(self.bounds);
    return rect;
}

- (NSInteger)tabIndexAtPoint:(NSPoint)point {
    if ([self isPointOnHiddenTabsIndicator:point]) return -1;
    if ([self hasTabGroups] && !NSPointInRect(point,[self tabViewportRect])) return -1;
    for (NSInteger i = 0; i < (NSInteger)self.tabs.count; ++i) {
        NSRect tabRect = [self rectForTabAtIndex:i];
        if (!NSIsEmptyRect(tabRect) && NSPointInRect(point, [self interactionRectForTabRect:tabRect])) return i;
    }
    return -1;
}

- (NSString*)fullTitleForTabAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.tabs.count) return @"";
    SPDFDocumentTab* tab = self.tabs[(NSUInteger)index];
    if (tab.collectionVersionLabel.length) return tab.collectionVersionLabel;
    return tab.path.length ? tab.path.lastPathComponent : tab.title ?: @"";
}

- (NSString*)titleForTabAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.tabs.count) return @"";
    SPDFDocumentTab* tab = self.tabs[(NSUInteger)index];
    if (tab.collectionVersionLabel.length) return tab.collectionVersionLabel;
    if (!tab.path.length) return spdf_display_label_without_extension(tab.title);
    if (!_displayTitles) {
        NSMutableArray<NSString*>* paths=[NSMutableArray arrayWithCapacity:self.tabs.count];
        for (SPDFDocumentTab* item in self.tabs) [paths addObject:item.path ?: @""];
        _displayTitles=spdf_disambiguated_display_names_for_paths(paths);
    }
    return index<(NSInteger)_displayTitles.count ? _displayTitles[(NSUInteger)index] : spdf_display_name_for_path(tab.path);
}
- (CGFloat)preferredWidthForTabAtIndex:(NSInteger)index {
    if (_preferredTabWidths[@(index)]) return _preferredTabWidths[@(index)].doubleValue;
    if (!_preferredTabWidths) _preferredTabWidths=[NSMutableDictionary dictionary];
    NSString* title = [self titleForTabAtIndex:index];
    NSFont* font = [NSFont systemFontOfSize:12 weight:index == self.selectedIndex ? NSFontWeightSemibold : NSFontWeightRegular];
    CGFloat width=MIN(kTabMaxWidth, MAX(kTabMinVisibleWidth, ceil([title sizeWithAttributes:@{NSFontAttributeName:font}].width) + 12));
    _preferredTabWidths[@(index)]=@(width);
    return width;
}
@end
