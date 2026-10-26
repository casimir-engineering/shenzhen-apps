#import "SPDFMacTabStripViewPrivate.h"

#import "SPDFMacSupport.h"
#import "SPDFMacTabHoverPreview.h"
#import "SPDFMacTabStripGeometry.h"
#import "SPDFMacTabStripStyle.h"
#import "SPDFMacTabAccessibility.h"
#import "SPDFMacWindowChrome.h"

#include <math.h>

@implementation SPDFTabStripView

- (NSDragOperation)draggingSession:(NSDraggingSession*)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    (void)session;
    (void)context;
    return NSDragOperationMove;
}


- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _hoverTabIndex = -1;
        _draggedTabIndex = -1;
        _dragSessionTabIndex = -1;
        _dragSourceTabIndex = -1;
        _dragTargetTabIndex = -1;
        _middleClickTabIndex = -1;
        _dropIndicatorSlot = -1;
        _groupDropTabIndex = -1;
        _groupDropBoundaryX = NAN;
        _groupHoverIndex = -1;
        [self registerForDraggedTypes:@[ SPDFTabDragPasteboardType, NSPasteboardTypeFileURL ]];
    }
    return self;
}

- (void)dealloc {
    [self dismissHoverPanel];
}

- (void)viewWillMoveToWindow:(NSWindow*)newWindow {
    if (!newWindow) {
        [self restoreWindowMovementForTabGesture];
        [self dismissHoverPanel];
    }
    [super viewWillMoveToWindow:newWindow];
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    (void)event;
    return YES;
}

- (BOOL)mouseDownCanMoveWindow {
    return NO;
}

- (void)suppressWindowMovementForTabGesture {
    if (_suppressingWindowMovementForTabGesture || !self.window) return;
    _previousWindowMovableForTabGesture = self.window.movable;
    self.window.movable = NO;
    _suppressingWindowMovementForTabGesture = YES;
}

- (void)restoreWindowMovementForTabGesture {
    if (!_suppressingWindowMovementForTabGesture || !self.window) return;
    self.window.movable = _previousWindowMovableForTabGesture;
    _suppressingWindowMovementForTabGesture = NO;
}

- (void)setHidden:(BOOL)hidden {
    if (hidden) {
        [self dismissHoverPanel];
        [self clearDropIndicator];
    }
    [super setHidden:hidden];
}

- (CGFloat)tabScrollOffset { return _tabScrollOffset; }
- (void)setTabScrollOffset:(CGFloat)offset {
    _tabScrollOffset=isfinite(offset) ? MAX(0,offset) : 0;
    _groupLayout=nil; _revealSelectedTab=NO; [self setNeedsDisplay:YES];
}
- (void)setEmptyGroups:(NSArray<SPDFTabGroup*>*)groups {
    if (!_emptyGroups.count && !groups.count) return;
    _emptyGroups = [groups copy];
    _groupLayout = nil;
    _accessibilityChildrenSnapshot = nil;
    NSAccessibilityPostNotification(self, NSAccessibilityLayoutChangedNotification);
    [self setNeedsDisplay:YES];
}

- (void)setTabs:(NSArray<SPDFDocumentTab*>*)tabs {
    _groupLayout = nil;
    _preferredTabWidths = nil;
    _ungroupedVisibleIndexes = nil;
    _tabs = [tabs copy];
    _displayTitles = nil;
    _accessibilityChildrenSnapshot = nil;
    NSAccessibilityPostNotification(self, NSAccessibilityLayoutChangedNotification);
    [self setNeedsDisplay:YES];
    [self rebuildReadOnlyTooltips];
    if (_hasLastHoverPoint && NSPointInRect(_lastHoverPoint, self.bounds)) [self updateHoverForPoint:_lastHoverPoint];
    else [self dismissHoverPanel];
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    _groupLayout = nil;
    _revealSelectedTab = _selectedIndex != selectedIndex || !_tabs.count;
    _selectedIndex = selectedIndex;
    _preferredTabWidths = nil;
    _ungroupedVisibleIndexes = nil;
    _accessibilityChildrenSnapshot = nil;
    NSAccessibilityPostNotification(self, NSAccessibilitySelectedChildrenChangedNotification);
    [self setNeedsDisplay:YES];
    [self rebuildReadOnlyTooltips];
}

- (BOOL)isAccessibilityElement { return NO; }

- (NSArray*)accessibilityChildren {
    if (!_accessibilityChildrenSnapshot)
        _accessibilityChildrenSnapshot = SPDFMacTabAccessibilityChildren(self);
    return _accessibilityChildrenSnapshot;
}

- (NSArray*)accessibilitySelectedChildren {
    for (NSAccessibilityElement* child in self.accessibilityChildren)
        if (child.isAccessibilitySelected) return @[ child ];
    return @[];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    _accessibilityChildrenSnapshot = nil;
}

- (NSRect)closeCircleRectForTabRect:(NSRect)tabRect {
    CGFloat diameter = 20.0;
    return NSMakeRect(floor(NSMaxX(tabRect) - 22.0), floor(NSMidY(tabRect) - diameter / 2.0), diameter, diameter);
}

// Read-only dot rect: inside the title's left inset, vertically centered. View
// is non-flipped (y grows up), so center via NSMidY like the close circle.
- (NSRect)readOnlyDotRectForTabRect:(NSRect)tabRect diameter:(CGFloat)diameter leftInset:(CGFloat)leftInset {
    return NSMakeRect(floor(NSMinX(tabRect) + leftInset), floor(NSMidY(tabRect) - diameter / 2.0), diameter, diameter);
}

- (void)beginTabTrackingAtIndex:(NSInteger)index point:(NSPoint)point tabRect:(NSRect)tabRect {
    [self suppressWindowMovementForTabGesture];
    _draggedTabIndex = index;
    _dragSourceTabIndex = index;
    _dragTargetTabIndex = index;
    _dragStartPoint = point;
    _dragPointerOffsetX = point.x - NSMinX(tabRect);
    _dragCurrentX = NSMinX(tabRect);
}

- (void)resetTabDragTracking {
    _groupDropBoundaryX = NAN;
    _groupDropTabIndex = -1;
    _groupDropGroup = nil;
    _groupPreviewColor = nil;
    _groupHoverIndex = -1;
    _draggedTabIndex = -1;
    _dragSourceTabIndex = -1;
    _dragTargetTabIndex = -1;
    _draggingTab = NO;
    _detachedTabDrag = NO;
    _mouseDownInsideTab = NO;
    _dragPointerOffsetX = 0;
    _dragCurrentX = 0;
    [self restoreWindowMovementForTabGesture];
    [self setNeedsDisplay:YES];
}

- (NSInteger)dragDestinationIndexForPoint:(NSPoint)point {
    NSArray<NSNumber*>* visibleIndexes = [self visibleTabIndexes];
    if (!visibleIndexes.count) return -1;

    NSInteger sourceIndex = _dragSourceTabIndex >= 0 ? _dragSourceTabIndex : _draggedTabIndex;
    NSInteger targetIndex = sourceIndex;
    SPDFTabGroup* sourceGroup = sourceIndex >= 0 && sourceIndex < (NSInteger)self.tabs.count
                                   ? self.tabs[(NSUInteger)sourceIndex].group : nil;
    BOOL withinGroup = sourceGroup && [self groupAtPoint:point headerOnly:NO] == sourceGroup;
    for (NSNumber* indexNumber in visibleIndexes) {
        NSInteger index = indexNumber.integerValue;
        if (index == sourceIndex || (withinGroup && self.tabs[(NSUInteger)index].group != sourceGroup)) continue;
        NSRect tabRect = [self rectForTabAtIndex:index];
        if (NSIsEmptyRect(tabRect)) continue;
        if (index < sourceIndex && point.x < NSMinX(tabRect) + NSWidth(tabRect)*0.20) {
            targetIndex = index;
            break;
        }
        if (index > sourceIndex && point.x > NSMaxX(tabRect) - NSWidth(tabRect)*0.20) targetIndex = index;
    }
    return targetIndex;
}

// Collects the frames of the visible, non-collapsed tabs (left to right) into
// the caller-provided arrays, each sized kMaxVisibleTabGeometry. arrayIndexes
// maps each geometry slot back to the tab's index in self.tabs. Returns the
// number of entries filled. Shared by the drop-index computation and the
// insertion-indicator drawing so both always agree.
- (NSInteger)collectVisibleTabGeometryMinXs:(CGFloat*)minXs
                                      midXs:(CGFloat*)midXs
                                      maxXs:(CGFloat*)maxXs
                               arrayIndexes:(NSInteger*)arrayIndexes {
    NSInteger filled = 0;
    for (NSNumber* indexNumber in [self visibleTabIndexes]) {
        if (filled >= kMaxVisibleTabGeometry) break;
        NSInteger index = indexNumber.integerValue;
        NSRect tabRect = [self rectForTabAtIndex:index];
        if (NSIsEmptyRect(tabRect)) continue;
        minXs[filled] = NSMinX(tabRect);
        midXs[filled] = NSMidX(tabRect);
        maxXs[filled] = NSMaxX(tabRect);
        arrayIndexes[filled] = index;
        ++filled;
    }
    return filled;
}

- (NSInteger)dropIndexForPoint:(NSPoint)point {
    NSInteger gap=[self tabGroupGapInsertionIndexForPoint:point boundary:NULL];
    if (gap!=NSNotFound) return gap;
    // Collapsed groups have no document rectangles. Use their group boundary
    // for gap drops rather than accidentally inserting inside a visible group.
    if ([self hasTabGroups] && ![self groupAtPoint:point headerOnly:NO])
        return [self groupInsertionIndexForPoint:point];
    CGFloat minXs[kMaxVisibleTabGeometry], midXs[kMaxVisibleTabGeometry], maxXs[kMaxVisibleTabGeometry];
    NSInteger arrayIndexes[kMaxVisibleTabGeometry];
    NSInteger visibleCount = [self collectVisibleTabGeometryMinXs:minXs midXs:midXs maxXs:maxXs
                                                     arrayIndexes:arrayIndexes];
    if (visibleCount <= 0) return (NSInteger)self.tabs.count;

    NSInteger slot = spdf_tab_strip_drop_slot_for_x(point.x, midXs, visibleCount);
    if (slot < visibleCount) return arrayIndexes[slot];
    return MIN((NSInteger)self.tabs.count, arrayIndexes[visibleCount - 1] + 1);
}

- (void)updateDropIndicatorForPoint:(NSPoint)point {
    CGFloat minXs[kMaxVisibleTabGeometry], midXs[kMaxVisibleTabGeometry], maxXs[kMaxVisibleTabGeometry];
    NSInteger arrayIndexes[kMaxVisibleTabGeometry];
    NSInteger visibleCount = [self collectVisibleTabGeometryMinXs:minXs midXs:midXs maxXs:maxXs
                                                     arrayIndexes:arrayIndexes];
    NSInteger slot = visibleCount > 0 ? spdf_tab_strip_drop_slot_for_x(point.x, midXs, visibleCount) : -1;
    if (slot == _dropIndicatorSlot) return;
    _dropIndicatorSlot = slot;
    [self setNeedsDisplay:YES];
}

- (void)clearDropIndicator {
    _groupDropBoundaryX = NAN;
    _groupDropTabIndex = -1;
    _groupDropGroup = nil;
    _groupHoverIndex = -1;
    [self setNeedsDisplay:YES];
    if (_dropIndicatorSlot < 0) return;
    _dropIndicatorSlot = -1;
    [self setNeedsDisplay:YES];
}

- (BOOL)containsTabOrControlAtPoint:(NSPoint)point {
    if ([self groupAtPoint:point headerOnly:NO]) return YES;
    if (NSPointInRect(point, spdf_tab_strip_control_interaction_rect([self plusRect]))) return YES;
    NSRect overflowRect = [self overflowRect];
    if (NSPointInRect(point, spdf_tab_strip_control_interaction_rect(overflowRect))) return YES;
    for (NSInteger i = 0; i < (NSInteger)self.tabs.count; ++i) {
        NSRect tabRect = [self rectForTabAtIndex:i];
        if (!NSIsEmptyRect(tabRect) && NSPointInRect(point, [self interactionRectForTabRect:tabRect])) return YES;
    }
    return NO;
}

- (BOOL)isVisuallyReorderingTabs {
    return _draggingTab && !_detachedTabDrag && _dragSourceTabIndex >= 0 &&
           _dragSourceTabIndex < (NSInteger)self.tabs.count && _dragTargetTabIndex >= 0 &&
           _dragTargetTabIndex < (NSInteger)self.tabs.count;
}

- (NSRect)visualRectForTabAtIndex:(NSInteger)index {
    NSRect baseRect = [self rectForTabAtIndex:index];
    if (NSIsEmptyRect(baseRect) || ![self isVisuallyReorderingTabs]) return baseRect;

    NSInteger source = _dragSourceTabIndex;
    NSInteger target = _dragTargetTabIndex;
    if (index == source) {
        CGFloat width = NSWidth(baseRect);
        CGFloat minX = [self leftInset];
        CGFloat maxX = MAX(minX, [self tabAreaRightWithOverflow:[self hasOverflowTabs]] - width);
        return NSMakeRect(floor(MAX(minX, MIN(_dragCurrentX, maxX))), NSMinY(baseRect), width, NSHeight(baseRect));
    }

    // Group contours and headers stay anchored. Only siblings exchange slots;
    // joining another group retains its existing drop outline while the tab
    // itself continues to follow the pointer above the strip.
    SPDFTabGroup* sourceGroup = self.tabs[(NSUInteger)source].group;
    if (_groupDropGroup || _groupDropTabIndex >= 0 ||
        self.tabs[(NSUInteger)target].group != sourceGroup || self.tabs[(NSUInteger)index].group != sourceGroup)
        return baseRect;

    CGFloat pitch = NSWidth([self rectForTabAtIndex:source]) + kTabGap;
    if (source < target && index > source && index <= target) baseRect.origin.x -= pitch;
    else if (target < source && index >= target && index < source) baseRect.origin.x += pitch;
    return baseRect;
}

- (void)mouseDown:(NSEvent*)event {
    if ([self handleTabScrollMouseDown:event]) return;
    if ([self handleGroupMouseDown:event]) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    _draggedTabIndex = -1;
    _dragSourceTabIndex = -1;
    _dragTargetTabIndex = -1;
    _draggingTab = NO;
    _detachedTabDrag = NO;
    _mouseDownInsideTab = NO;

    if (NSPointInRect(point, spdf_tab_strip_control_interaction_rect([self plusRect]))) {
        [self showNewTabOrGroupMenu];
        return;
    }
    if (NSPointInRect(point, spdf_tab_strip_control_interaction_rect([self overflowRect]))) {
        [self showOverflowMenuWithEvent:event];
        return;
    }
    for (NSInteger i = 0; i < (NSInteger)self.tabs.count; ++i) {
        NSRect tabRect = [self rectForTabAtIndex:i];
        if (NSIsEmptyRect(tabRect)) continue;
        if (!NSPointInRect(point, [self interactionRectForTabRect:tabRect])) continue;
        _mouseDownInsideTab = YES;
        NSRect closeRect = NSInsetRect([self closeCircleRectForTabRect:tabRect], -5.0, -5.0);
        if (NSPointInRect(point, closeRect)) {
            [self.reader closeTabAtIndex:i];
        } else {
            [self.reader selectTabAtIndex:i];
            [self beginTabTrackingAtIndex:i point:point tabRect:tabRect];
        }
        return;
    }

    [self dismissHoverPanel];
    id<SPDFWindowChromeHandling> chromeWindow = (id<SPDFWindowChromeHandling>)self.window;
    if ([chromeWindow respondsToSelector:@selector(handleChromeMouseDown:)]) [chromeWindow handleChromeMouseDown:event];
}

- (void)mouseDragged:(NSEvent*)event {
    if ([self handleGroupMouseDragged:event]) return;
    if (_draggedTabIndex < 0) { return; }

    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat dx = point.x - _dragStartPoint.x;
    CGFloat dy = point.y - _dragStartPoint.y;
    if (!_draggingTab && hypot(dx, dy) < 3.0) return;
    _draggingTab = YES;
    [self dismissHoverPanel];

    BOOL outsideTabStrip = point.y < -24.0 || point.y > NSHeight(self.bounds) + 24.0 ||
                           point.x < [self leftInset] - 18.0 || point.x > NSWidth(self.bounds) + 18.0;
    if (!_detachedTabDrag && (outsideTabStrip || fabs(dy) > 48.0)) {
        [self startTabDragSessionWithEvent:event];
        return;
    }
    if (_detachedTabDrag) return;

    _dragCurrentX = point.x - _dragPointerOffsetX;
    [self updateGroupDropForPoint:point sourceIndex:_dragSourceTabIndex];
    NSInteger targetIndex = [self dragDestinationIndexForPoint:point];
    if (targetIndex >= 0) _dragTargetTabIndex = targetIndex;
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent*)event {
    if ([self handleGroupMouseUp:event]) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (_draggingTab && !_detachedTabDrag && [self performGroupDropWithTab:nil
            sourceIndex:_dragSourceTabIndex atPoint:point]) {
        [self resetTabDragTracking];
        return;
    }
    // The middle three fifths are a grouping dead zone. Releasing before
    // its preview is armed leaves the order untouched, just as the preview did.
    if (_draggingTab && !_detachedTabDrag && _groupHoverIndex >= 0) {
        [self resetTabDragTracking]; return;
    }
    if (_draggingTab && !_detachedTabDrag && [self hasTabGroups] && _dragSourceTabIndex >= 0) {
        SPDFTabGroup* destination = [self tabDropGroupAtPoint:point];
        [self.groupReader moveTabAtIndex:_dragSourceTabIndex toGroup:destination atIndex:[self dropIndexForPoint:point]];
        [self resetTabDragTracking];
        return;
    }
    NSInteger clickedTabIndex = _dragSourceTabIndex >= 0 ? _dragSourceTabIndex : _draggedTabIndex;
    NSInteger targetIndex = _dragTargetTabIndex;
    BOOL dragged = _draggingTab;
    BOOL detached = _detachedTabDrag;
    [self resetTabDragTracking];
    if (detached) return;
    if (dragged && clickedTabIndex >= 0 && targetIndex >= 0 && clickedTabIndex != targetIndex) {
        [self.reader moveTabFromIndex:clickedTabIndex toIndex:targetIndex];
        [self.reader selectTabAtIndex:targetIndex];
    } else if (!dragged && clickedTabIndex >= 0) {
        [self.reader selectTabAtIndex:clickedTabIndex];
    }
}

// Middle-click closes a tab with browser semantics: the close fires on
// middle-button RELEASE over the same tab that was pressed (middle-dragging
// off the tab cancels). Goes through the same -closeTabAtIndex: path as the
// tab's close button, so reopen-last-closed bookkeeping applies. The pressed
// tab is never selected first. Presses on the "+" / "…" controls or empty
// strip space hit no tab and do nothing.
- (void)otherMouseDown:(NSEvent*)event {
    if (event.buttonNumber != 2) {
        [super otherMouseDown:event];
        return;
    }
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger index = [self tabIndexAtPoint:point];
    _middleClickTabIndex = index;
    _middleClickTabPath = index >= 0 ? [self.tabs[(NSUInteger)index].path copy] : nil;
}

- (void)otherMouseUp:(NSEvent*)event {
    if (event.buttonNumber != 2) {
        [super otherMouseUp:event];
        return;
    }
    NSInteger pressedIndex = _middleClickTabIndex;
    NSString* pressedPath = _middleClickTabPath;
    _middleClickTabIndex = -1;
    _middleClickTabPath = nil;
    if (pressedIndex < 0 || pressedIndex >= (NSInteger)self.tabs.count) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if ([self tabIndexAtPoint:point] != pressedIndex) return;
    // Guard against the tabs array having changed between press and release
    // (async tab-strip refreshes): only close if the same document is still at
    // the pressed index.
    NSString* currentPath = self.tabs[(NSUInteger)pressedIndex].path ?: @"";
    if (![currentPath isEqualToString:pressedPath ?: @""]) return;
    [self dismissHoverPanel];
    [self.reader closeTabAtIndex:pressedIndex];
}

- (void)mouseMoved:(NSEvent*)event {
    [self updateHoverForEvent:event];
}

- (void)mouseEntered:(NSEvent*)event {
    // The pointer is on its way to a tab: have every tab's thumbnail ready.
    if ([self.reader respondsToSelector:@selector(tabHoverPreviewsWillBeNeeded)])
        [(id)self.reader tabHoverPreviewsWillBeNeeded];
    [self updateHoverForEvent:event];
}

- (void)mouseExited:(NSEvent*)event {
    (void)event;
    [self dismissHoverPanel];
}

// Belt-and-braces for unforeseen focus states: if a keyDown lands on the strip,
// printable keys start the same type-to-search the document views run
// (SPDFScrollView keyDown parity). The reader rejects modified / control /
// function keys itself, so Escape and Cmd shortcuts keep their behavior.
- (void)keyDown:(NSEvent*)event {
    if ([self.reader respondsToSelector:@selector(documentTypeToSearchKeyDown:)] &&
        [self.reader documentTypeToSearchKeyDown:event])
        return;
    [super keyDown:event];
}

// See SPDFMacTabStripView.h. Class-level so the reader's tab-selection
// chokepoint and the focused interaction tests share one guard.
+ (BOOL)claimFocusOnDocumentKeyView:(NSView*)documentKeyView
                             window:(NSWindow*)window
                           tabStrip:(NSView*)tabStrip
                   parkedResponders:(NSArray<NSResponder*>*)parkedResponders {
    if (!window || !documentKeyView) return NO;
    NSResponder* current = window.firstResponder;
    BOOL passive = !current || current == window || (tabStrip && current == tabStrip);
    for (NSResponder* parked in parkedResponders)
        if (current == parked) passive = YES;
    if (!passive) return NO;
    return [window makeFirstResponder:documentKeyView];
}

@end
