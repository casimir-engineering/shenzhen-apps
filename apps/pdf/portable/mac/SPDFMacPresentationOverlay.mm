#import "SPDFMacUIHelpers.h"

// The full-window view presentation mode lays over the document. It takes every
// click and key so they turn pages, and hands wheel and pinch events to the
// document's own scroll view, so zooming and panning work as in the reader.
@implementation SPDFPresentationOverlayView

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    (void)event;
    return YES;
}

- (NSView*)hitTest:(NSPoint)point {
    (void)point;
    return self.hidden ? nil : self;
}

- (NSScrollView*)documentScrollView {
    id<SPDFMacUIReader> reader = self.reader;
    return [reader respondsToSelector:@selector(presentationEventTargetView)] ? [reader presentationEventTargetView] : nil;
}

- (void)mouseDown:(NSEvent*)event {
    if (self.reader && [self.reader handlePresentationEvent:event]) return;
    [super mouseDown:event];
}

- (void)rightMouseDown:(NSEvent*)event {
    if (self.reader && [self.reader handlePresentationEvent:event]) return;
    [super rightMouseDown:event];
}

- (void)otherMouseDown:(NSEvent*)event {
    if (self.reader && [self.reader handlePresentationEvent:event]) return;
    [super otherMouseDown:event];
}

- (void)mouseDragged:(NSEvent*)event {
    if (self.reader && [self.reader handlePresentationEvent:event]) return;
    [super mouseDragged:event];
}

- (void)mouseUp:(NSEvent*)event {
    if (self.reader && [self.reader handlePresentationEvent:event]) return;
    [super mouseUp:event];
}

- (void)keyDown:(NSEvent*)event {
    if (self.reader && [self.reader handlePresentationEvent:event]) return;
    [super keyDown:event];
}

- (void)scrollWheel:(NSEvent*)event {
    NSScrollView* target = [self documentScrollView];
    if (target) [target scrollWheel:event];
    else [super scrollWheel:event];
}

- (void)magnifyWithEvent:(NSEvent*)event {
    NSScrollView* target = [self documentScrollView];
    if (target) [target magnifyWithEvent:event];
    else [super magnifyWithEvent:event];
}

@end
