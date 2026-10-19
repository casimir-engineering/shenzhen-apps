#import "SPDFMacGroupActionButton.h"
#import "SPDFMacIconGeometry.h"
@implementation SPDFGroupActionButton
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self=[super initWithFrame:frame])) SPDFConfigureIconButtonRendering(self);
    return self;
}
- (void)setBordered:(BOOL)bordered {
    [super setBordered:bordered]; SPDFConfigureIconButtonRendering(self);
}
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; self.needsDisplay=YES; }
- (void)setImage:(NSImage*)image { [super setImage:SPDFUncachedVectorIcon(image)]; }
- (NSEdgeInsets)alignmentRectInsets { return NSEdgeInsetsZero; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { (void)event; return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (NSView*)hitTest:(NSPoint)point {
    return !self.hidden && NSPointInRect([self convertPoint:point fromView:self.superview],self.bounds) ? self : nil;
}
- (void)mouseDown:(NSEvent*)event {
    if (!self.enabled || event.type!=NSEventTypeLeftMouseDown) return;
    // Native cell tracking works in an isolated panel but swallows these
    // routed presses in the reader. Track the full target, not the image cell.
    NSRect pressTarget=[self convertRect:self.bounds toView:nil];
    [self highlight:YES];
    while (self.window) {
        NSEvent* next=[self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp];
        if (!next) break;
        if (next.windowNumber != event.windowNumber || next.timestamp < event.timestamp) continue;
        BOOL inside=NSPointInRect(next.locationInWindow,pressTarget);
        [self highlight:inside];
        if (next.type!=NSEventTypeLeftMouseUp) continue;
        [self highlight:NO];
        if (inside && self.enabled) [self sendAction:self.action to:self.target];
        return;
    }
    [self highlight:NO];
}
@end
