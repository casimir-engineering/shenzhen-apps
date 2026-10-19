#import "SPDFMacGroupManagementTable.h"
@implementation SPDFGroupManagementTable {
    NSTimer* _dragScrollTimer;
}
- (NSPoint)documentDragWindowPoint {
    return [self.window convertPointFromScreen:NSEvent.mouseLocation];
}
- (void)beginDocumentDragScrolling {
    [self endDocumentDragScrolling];
    __weak SPDFGroupManagementTable* weakSelf=self;
    _dragScrollTimer=[NSTimer timerWithTimeInterval:1.0/60 repeats:YES block:^(NSTimer* timer) {
        SPDFGroupManagementTable* table=weakSelf;
        if(!table || !table.window) { [timer invalidate]; return; }
        [table scrollDocumentDragAtWindowPoint:table.documentDragWindowPoint];
    }];
    [NSRunLoop.mainRunLoop addTimer:_dragScrollTimer forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:_dragScrollTimer forMode:NSEventTrackingRunLoopMode];
}
- (void)endDocumentDragScrolling { [_dragScrollTimer invalidate]; _dragScrollTimer=nil; }
- (void)dealloc { [_dragScrollTimer invalidate]; }
// NSTableView does not reliably request NSView autoscroll during a drag session.
// The source's explicit drag lifecycle drives a tracking-mode timer instead.
- (BOOL)autoscroll:(NSEvent*)event {
    if(_dragScrollTimer || !event) return NO;
    return [self scrollDocumentDragAtWindowPoint:event.locationInWindow];
}
- (BOOL)scrollDocumentDragAtWindowPoint:(NSPoint)point {
    NSScrollView* scroll=self.enclosingScrollView;
    if(!scroll) return NO;
    NSRect visible=self.visibleRect;
    NSPoint pointer=[self convertPoint:point fromView:nil];
    CGFloat zone=MIN(64,NSHeight(visible)/3);
    if(zone<=0 || pointer.x<NSMinX(visible) || pointer.x>NSMaxX(visible)) return NO;
    CGFloat top=pointer.y-NSMinY(visible), bottom=NSMaxY(visible)-pointer.y;
    CGFloat distance=MIN(top,bottom);
    if(distance>=zone) return NO;
    CGFloat depth=MIN(1,MAX(0,1-distance/zone));
    CGFloat step=(1+13*depth*depth)*(top<bottom ? -1 : 1);
    NSPoint origin=scroll.contentView.bounds.origin;
    CGFloat maximum=MAX(0,NSHeight(self.bounds)-NSHeight(scroll.contentView.bounds));
    CGFloat next=MIN(maximum,MAX(0,origin.y+step));
    if(next==origin.y) return NO;
    origin.y=next;
    [scroll.contentView scrollToPoint:origin];
    [scroll reflectScrolledClipView:scroll.contentView];
    return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent*)event { (void)event; return YES; }
- (void)mouseDown:(NSEvent*)event {
    NSInteger row=[self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if(row<0) { [super mouseDown:event]; return; }
    self.draggedDuringPress=NO;
    [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    [self displayIfNeeded];
    // Keep AppKit's drag tracking/autoscroll, but commit navigation on release.
    SEL action=self.action; self.action=NULL;
    [super mouseDown:event]; self.action=action;
    NSInteger released=[self rowAtPoint:[self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil]];
    if(!self.draggedDuringPress && released==row) [NSApp sendAction:@selector(activateSelectedRow:) to:self.target from:self];
}
- (void)keyDown:(NSEvent*)event {
    if(event.keyCode==36 || event.keyCode==76) {
        [NSApp sendAction:@selector(activateSelectedRow:) to:self.target from:self]; return;
    }
    [super keyDown:event];
}
@end
@interface SPDFGroupExtensionBadge : NSView
@property(nonatomic,copy) NSString* text;
@end
@implementation SPDFGroupExtensionBadge
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [[NSColor.labelColor colorWithAlphaComponent:.055] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:4 yRadius:4] fill];
    NSDictionary* attributes=@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName:NSColor.labelColor};
    NSSize size=[self.text sizeWithAttributes:attributes];
    [self.text drawAtPoint:NSMakePoint(floor((NSWidth(self.bounds)-size.width)/2),floor((NSHeight(self.bounds)-size.height)/2))
        withAttributes:attributes];
}
@end
NSView* SPDFGroupDocumentBadge(NSString* path) {
    SPDFGroupExtensionBadge* badge=[SPDFGroupExtensionBadge new];
    NSString* extension=path.pathExtension.lowercaseString;
    badge.text=extension.length ? [@"." stringByAppendingString:extension] : @"file";
    badge.accessibilityElement=YES; badge.accessibilityRole=NSAccessibilityStaticTextRole;
    badge.accessibilityLabel=[NSString stringWithFormat:@"File type: %@",badge.text];
    badge.toolTip=badge.text;
    CGFloat width=MAX(36,ceil([badge.text sizeWithAttributes:@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightMedium]}].width)+10);
    [badge.widthAnchor constraintEqualToConstant:width].active=YES;
    [badge.heightAnchor constraintEqualToConstant:18].active=YES;
    return badge;
}
