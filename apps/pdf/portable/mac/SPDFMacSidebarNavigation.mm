#import "SPDFMacIconGeometry.h"
#import "SPDFMacChromeColors.h"
#import "SPDFMacSidebarModeControl.h"

static const CGFloat RowHeight = 28;
static NSString* Symbol(NSInteger mode) {
    switch (mode) {
        case -1: return @"sidebar.left";
        case -2: return @"bubble.left.and.bubble.right";
        case SPDFSidebarModeComments: return @"text.bubble";
        case SPDFSidebarModeSearch: return @"magnifyingglass";
        case SPDFSidebarModeHistory: return @"clock.arrow.circlepath";
        case SPDFSidebarModeGroups: return @"square.3.layers.3d";
        default: return @"list.bullet.indent";
    }
}
// Rows paint a full 28-point target, not an AppKit bezel. Native button cells
// otherwise hit-test an inset bezel/title rectangle, leaving painted edges out.
@interface SPDFSidebarNavigationCell : NSButtonCell
@end
@implementation SPDFSidebarNavigationCell
- (NSCellHitResult)hitTestForEvent:(NSEvent*)event inRect:(NSRect)frame ofView:(NSView*)view {
    (void)frame;
    NSPoint point = [view convertPoint:event.locationInWindow fromView:nil];
    return self.enabled && NSPointInRect(point,view.bounds)
        ? NSCellHitContentArea | NSCellHitTrackableArea : NSCellHitNone;
}
@end
@interface SPDFSidebarNavigationRow : NSButton
@property NSInteger mode;
@property BOOL navigationSelected;
@end
@implementation SPDFSidebarNavigationRow {
    NSTrackingArea* _hoverArea;
    BOOL _hovered;
}
+ (Class)cellClass { return SPDFSidebarNavigationCell.class; }
- (void)setBordered:(BOOL)bordered {
    [super setBordered:bordered]; SPDFConfigureIconButtonRendering(self);
}
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; self.needsDisplay=YES; }
- (void)viewDidEndLiveResize { [super viewDidEndLiveResize]; self.needsDisplay=YES; }
- (void)setFrameSize:(NSSize)size {
    BOOL changed=!NSEqualSizes(size,self.frame.size);
    [super setFrameSize:size]; if (changed) self.needsDisplay=YES;
}
- (void)mouseDown:(NSEvent*)event {
    if (self.mode >= 0) { [super mouseDown:event]; return; }
    [self highlight:NO]; self.state=NSControlStateValueOff;
    if (self.enabled) [self sendAction:self.action to:self.target];
    [self highlight:NO]; self.state=NSControlStateValueOff;
}
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    BOOL selected = self.navigationSelected;
    // The row is on device pixels, so its rounded rectangle has crisp edges at 1x and 2x.
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:7 yRadius:7];
    if (self.mode != -1 && (selected || self.highlighted || _hovered)) {
        NSColor* fill = selected ? SPDFCollectionColor(@"selected") : [SPDFCollectionColor(@"text") colorWithAlphaComponent:self.highlighted ? .065 : .035];
        [fill setFill]; [shape fill];
    }
    if (selected && self.window.firstResponder == self.superview) {
        [NSGraphicsContext saveGraphicsState]; NSSetFocusRingStyle(NSFocusRingOnly); [shape fill]; [NSGraphicsContext restoreGraphicsState];
    }
    NSColor* color = SPDFChromeIconColor(self.enabled);
    // Every icon in the row at the same point size, drawn at its natural size in the middle of the row.
    SPDFDrawVectorIcon(SPDFChromeSymbol(Symbol(self.mode),SPDFToolbarSymbolPointSize,NSFontWeightRegular,color),
                       NSInsetRect(self.bounds,1,1),YES);

}
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if (_hoverArea) [self removeTrackingArea:_hoverArea];
    _hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways|NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:_hoverArea];
}
- (void)mouseEntered:(NSEvent*)event { (void)event; _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent*)event { (void)event; _hovered = NO; self.needsDisplay = YES; }
- (void)keyDown:(NSEvent*)event {
    if (event.keyCode == 125 || event.keyCode == 126 || event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76) [self.superview keyDown:event]; else [super keyDown:event];
}
- (NSRect)focusRingMaskBounds { return NSInsetRect(self.bounds,.5,.5); }
- (void)drawFocusRingMask { [[NSBezierPath bezierPathWithRoundedRect:self.focusRingMaskBounds xRadius:7 yRadius:7] fill]; }
- (NSString*)accessibilityRole { return self.mode == -1 ? NSAccessibilityButtonRole : NSAccessibilityRadioButtonRole; }
- (id)accessibilityValue { return self.mode == -1 ? nil : @(self.navigationSelected); }
@end

@implementation SPDFSidebarNavigationControl {
    NSMutableArray<SPDFSidebarNavigationRow*>* _rows;
    NSButton* _collapse;
    NSButton* _chats;
    NSMutableArray<NSString*>* _labels;
    NSMutableArray<NSNumber*>* _tags;
    NSMutableArray<NSNumber*>* _enabled;
    NSInteger _selectedSegment;
}
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _rows = [NSMutableArray array]; _labels = [NSMutableArray array];
        _tags = [NSMutableArray array]; _enabled = [NSMutableArray array]; _selectedSegment = -1;
        self.focusRingType = NSFocusRingTypeNone; [self rebuildRows];
    }
    return self;
}
- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric,self.spdf_selectedSidebarMode >= SPDFSidebarModeGroups ? 36 : 64);
}
- (void)setDocumentTitle:(NSString*)title {
    if ([_documentTitle isEqualToString:title]) return;
    _documentTitle = [title copy]; self.needsDisplay = YES;
}
- (void)setCollapseTarget:(id)target action:(SEL)action {
    if (!_chats) {
        SPDFSidebarNavigationRow* chats=[SPDFSidebarNavigationRow new]; chats.mode=-2;
        chats.ignoresMultiClick=NO; [chats setButtonType:NSButtonTypeMomentaryChange];
        chats.target=target; chats.action=NSSelectorFromString(@"showAIChats:"); chats.bordered=NO;
        chats.toolTip=@"Chats"; chats.accessibilityLabel=@"Chats"; _chats=chats; [self addSubview:chats]; [self syncRows];
    }

    if (!_collapse) {
        SPDFSidebarNavigationRow* collapse = [SPDFSidebarNavigationRow new]; collapse.mode = -1;
        collapse.ignoresMultiClick=NO; [collapse setButtonType:NSButtonTypeMomentaryChange];
        collapse.target = target; collapse.action = action; collapse.bordered = NO;
        _collapse = collapse; _collapse.toolTip = @"Hide side panel";
        _collapse.accessibilityLabel = @"Hide side panel"; [self addSubview:_collapse]; self.needsLayout = YES;
    }
}
- (NSArray<SPDFSidebarNavigationRow*>*)visualRows {
    NSMutableArray* result = [NSMutableArray array];
    for (NSNumber* mode in @[@(SPDFSidebarModeGroups),@(SPDFSidebarModeChapters),@(SPDFSidebarModeSearch),
                             @(SPDFSidebarModeComments),@(SPDFSidebarModeHistory)])
        for (SPDFSidebarNavigationRow* row in _rows) if (row.mode == mode.integerValue) [result addObject:row];
    return result;
}
- (void)rebuildRows {
    if (!_rows) return;
    NSResponder* focused = self.window.firstResponder;
    BOOL retainedFocus = [focused isKindOfClass:NSView.class] && [(NSView*)focused isDescendantOf:self];
    for (NSView* row in _rows) [row removeFromSuperview]; [_rows removeAllObjects];
    for (NSInteger i=0;i<self.segmentCount;i++) {
        SPDFSidebarNavigationRow* row = [SPDFSidebarNavigationRow new]; row.bordered = NO;
        row.ignoresMultiClick = NO;
        row.tag = i; row.target = self; row.action = @selector(chooseRow:);
        [self addSubview:row]; [_rows addObject:row];
    }
    [self syncRows]; [self invalidateIntrinsicContentSize]; self.needsLayout = YES;
    if (retainedFocus) [self.window makeFirstResponder:self];
}
- (void)syncRows {
    ((SPDFSidebarNavigationRow*)_chats).navigationSelected=self.spdf_selectedSidebarMode==SPDFSidebarModeChats;
    _chats.needsDisplay=YES;
    for (NSUInteger i=0;i<_rows.count;i++) {
        SPDFSidebarNavigationRow* row = _rows[i];
        row.hidden=[self tagForSegment:i]==SPDFSidebarModeChats;
        row.title = [self labelForSegment:i] ?: @""; row.mode = [self tagForSegment:i];
        row.accessibilityLabel = row.title; row.toolTip = row.mode == SPDFSidebarModeHistory ? @"History (⌘H)" : row.title;
        row.enabled = [self isEnabledForSegment:i];
        row.state = self.selectedSegment == (NSInteger)i ? NSControlStateValueOn : NSControlStateValueOff;
        row.navigationSelected=self.selectedSegment == (NSInteger)i; row.needsDisplay = YES;
    }
}
// The container deliberately has no NSSegmentedCell: AppKit's segmented hit
// routing can consume child-button clicks below its own invisible native bezel.
- (NSInteger)segmentCount { return _labels.count; }
- (void)setSegmentCount:(NSInteger)count {
    count = MAX(0,count);
    while (_labels.count < (NSUInteger)count) { [_labels addObject:@""]; [_tags addObject:@0]; [_enabled addObject:@YES]; }
    while (_labels.count > (NSUInteger)count) { [_labels removeLastObject]; [_tags removeLastObject]; [_enabled removeLastObject]; }
    if (_selectedSegment >= count) _selectedSegment = -1;
    [self rebuildRows];
}
- (NSInteger)selectedSegment { return _selectedSegment; }
- (void)setSelectedSegment:(NSInteger)index {
    _selectedSegment = index >= 0 && index < self.segmentCount ? index : -1;
    [self syncRows]; [self invalidateIntrinsicContentSize]; self.needsDisplay = YES;
}
- (NSString*)labelForSegment:(NSInteger)segment { return _labels[(NSUInteger)segment]; }
- (NSInteger)tagForSegment:(NSInteger)segment { return _tags[(NSUInteger)segment].integerValue; }
- (BOOL)isEnabledForSegment:(NSInteger)segment { return _enabled[(NSUInteger)segment].boolValue; }
- (void)setTag:(NSInteger)tag forSegment:(NSInteger)segment { _tags[(NSUInteger)segment] = @(tag); [self syncRows]; }
- (void)setLabel:(NSString*)label forSegment:(NSInteger)segment { _labels[(NSUInteger)segment] = label ?: @""; [self syncRows]; }
- (void)setEnabled:(BOOL)enabled forSegment:(NSInteger)segment { _enabled[(NSUInteger)segment] = @(enabled); [self syncRows]; }
- (void)setWidth:(CGFloat)width forSegment:(NSInteger)segment { (void)width; (void)segment; }
- (void)layout {
    [super layout];
    NSArray* rows = [self visualRows];
    NSUInteger toolCount = rows.count ? rows.count - 1 : 0; // Groups stays anchored at the trailing edge.
    CGFloat left = _collapse ? 36 : 0;
    CGFloat right = NSWidth(self.bounds)-(_chats ? 68 : 36);
    CGFloat width = MIN(28, floor(MAX(0,right-left)/MAX(1,toolCount)));
    CGFloat x = left + (right-left-width*toolCount)/2;
    _collapse.frame = [self backingAlignedRect:NSMakeRect(0,4,28,RowHeight) options:NSAlignAllEdgesNearest];
    _chats.frame=[self backingAlignedRect:NSMakeRect(NSWidth(self.bounds)-60,4,28,RowHeight) options:NSAlignAllEdgesNearest];
    for (SPDFSidebarNavigationRow* row in rows) {
        NSRect frame;
        if (row.mode == SPDFSidebarModeGroups) {
            frame = NSMakeRect(NSWidth(self.bounds)-28,4,28,RowHeight);
        } else {
            frame = NSMakeRect(x,4,width,RowHeight); x += width;
        }
        // Keep the complete target on device pixels. Fractional panel widths
        // otherwise place cached glyphs between pixels (especially at 1x).
        // At 1x, rounding Groups' trailing edge to the nearest pixel can put it
        // half a point past the strip; such an edge moves in to the pixel inside.
        NSRect aligned = [self backingAlignedRect:frame options:NSAlignAllEdgesNearest];
        row.frame = NSContainsRect(self.bounds, aligned) ? aligned
            : [self backingAlignedRect:NSIntersectionRect(aligned, self.bounds) options:NSAlignAllEdgesInward];
    }
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty; [[SPDFCollectionColor(@"text") colorWithAlphaComponent:.13] setFill];
    NSRectFill(NSMakeRect(-8,35,NSWidth(self.bounds)+16,.5));
    SPDFSidebarNavigationRow* group = [self visualRows].firstObject;
    NSRectFill(NSMakeRect((_chats ? NSMinX(_chats.frame) : NSMinX(group.frame))-8,10,.5,16));
    if (_collapse) NSRectFill(NSMakeRect(NSMaxX(_collapse.frame)+8,10,.5,16));
    if (self.spdf_selectedSidebarMode < SPDFSidebarModeGroups) {
        NSMutableParagraphStyle* style = [NSMutableParagraphStyle new]; style.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [_documentTitle ?: @"No document" drawInRect:NSMakeRect(4,45,MAX(0,NSWidth(self.bounds)-8),16)
            withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:11],
                NSForegroundColorAttributeName:SPDFCollectionColor(@"secondary"),NSParagraphStyleAttributeName:style}];
    }
}

- (NSView*)hitTest:(NSPoint)point {
    NSPoint local = [self convertPoint:point fromView:self.superview];
    if (self.hidden || !NSPointInRect(local,self.bounds)) return nil;
    if (_collapse && NSPointInRect(local,_collapse.frame)) return _collapse;
    if (_chats && NSPointInRect(local,_chats.frame)) return _chats;
    for (NSView* row in _rows) if (!row.hidden && NSPointInRect(local,row.frame)) return row;
    return nil; // Empty header space belongs to the dedicated drag surface below.
}
- (void)chooseRow:(NSButton*)row {
    if (!row.enabled) return;
    self.selectedSegment = row.tag;
    NSResponder* focused = self.window.firstResponder;
    if (focused != self && [focused isKindOfClass:NSView.class] && [(NSView*)focused isDescendantOf:self])
        [self.window makeFirstResponder:row];
    [self sendAction:self.action to:self.target];
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { [self syncRows]; return YES; }
- (BOOL)resignFirstResponder { [self syncRows]; return YES; }
- (void)keyDown:(NSEvent*)event {
    if (event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76) {
        NSInteger selected = self.selectedSegment;
        if (selected >= 0 && selected < (NSInteger)_rows.count) [self chooseRow:_rows[selected]];
        return;
    }
    NSInteger direction = (event.keyCode == 125 || event.keyCode == 124) ? 1 : (event.keyCode == 126 || event.keyCode == 123) ? -1 : 0;
    if (!direction) { [super keyDown:event]; return; }
    NSArray* ordered = [self visualRows];
    if (self.selectedSegment < 0 || self.selectedSegment >= (NSInteger)_rows.count) return;
    NSInteger current = [ordered indexOfObject:_rows[self.selectedSegment]];
    for (NSInteger i=current+direction;i>=0 && i<(NSInteger)ordered.count;i+=direction)
        if ([ordered[i] isEnabled]) { [self chooseRow:ordered[i]]; return; }
}
- (NSArray*)accessibilityChildren {
    NSMutableArray* items=[[self visualRows] mutableCopy];
    if (_chats) [items addObject:_chats]; if (_collapse) [items addObject:_collapse]; return items;
}
- (NSString*)accessibilityRole { return NSAccessibilityTabGroupRole; }
@end
