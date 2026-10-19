#import "SPDFMacUIHelpers.h"
#import "SPDFMacPaneDividerGeometry.h"

@implementation SPDFPaneDividerView {
    CGFloat _lastWindowX;
}
- (NSCursor*)spdf_cursorForTrackingOverlay { return NSCursor.resizeLeftRightCursor; }
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { (void)event; return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (NSView*)hitTest:(NSPoint)point {
    NSPoint local=[self convertPoint:point fromView:self.superview];
    return !self.hidden && NSPointInRect(local,SPDFPaneDividerResizeRect(self.bounds)) ? self : nil;
}
- (void)resetCursorRects {
    [self addCursorRect:SPDFPaneDividerResizeRect(self.bounds) cursor:NSCursor.resizeLeftRightCursor];
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect gutter=NSMakeRect(floor(NSMidX(self.bounds)-2.5),0,5,NSHeight(self.bounds));
    [NSColor.windowBackgroundColor setFill]; NSRectFill(gutter);
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(floor(NSMidX(self.bounds)),0,1,NSHeight(self.bounds)));
}
- (void)mouseDown:(NSEvent*)event {
    _lastWindowX=event.locationInWindow.x;
    [NSCursor.resizeLeftRightCursor set];
    [self.reader clearFindFieldFocus];
}
- (void)mouseDragged:(NSEvent*)event {
    CGFloat x=event.locationInWindow.x;
    [self draggedByDeltaX:x-_lastWindowX]; _lastWindowX=x;
    [NSCursor.resizeLeftRightCursor set];
}
- (void)mouseUp:(NSEvent*)event {
    (void)event; [self didFinishDragging];
    [self.window invalidateCursorRectsForView:self];
}
- (void)draggedByDeltaX:(CGFloat)delta { (void)delta; }
- (void)didFinishDragging {}
@end

@implementation SPDFMinimapDividerView
- (void)draggedByDeltaX:(CGFloat)delta { [self.reader minimapDividerDraggedByDeltaX:delta]; }
- (void)didFinishDragging { [self.reader minimapDividerDidFinishDragging]; }
@end
@implementation SPDFSidebarDividerView
- (void)draggedByDeltaX:(CGFloat)delta { [self.reader sidebarDividerDraggedByDeltaX:delta]; }
- (void)didFinishDragging { [self.reader sidebarDividerDidFinishDragging]; }
@end
