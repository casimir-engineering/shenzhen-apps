// Annotate's tools on PDF pages (docs/plans/annotate.md § 1 "each page is its own canvas; the tools act on the page
// under the pointer"): the overlay stays the one view over the pages that takes the pointer, and hands every event of
// a tool Annotate draws with (pixel tools, shapes, text boxes, selections, the colour picker, the magnifier) to the
// canvas view kept just under it, which finds the page under the pointer itself (SPDFMacAnnotateCanvasView.h). Fill &
// Sign's own tools (form Text, marks, Signature, Pen, Arrow, whole-line Eraser, Select) keep the overlay's handling.
// The right button goes to the canvas view too while Annotate shows, so the context menu of an object (Bring to Front
// ... Send to Back) works on Fill & Sign's items as on every other object.
#import "SPDFMacFillOverlayViewPrivate.h"

#import "SPDFMacAnnotateCanvasView.h"
#import "SPDFMacAnnotateSession.h"
#import "SPDFMacFillController+Annotate.h"

#import <objc/runtime.h>

static char kSPDFAnnotateForwardingKey;  // the gesture in progress went to the canvas view

@implementation SPDFMacFillOverlayView (Annotate)

- (nullable SPDFMacAnnotateSession*)annotateSession {
    SPDFDocumentTab* tab = [self.controller.host fillTab];
    return tab ? [SPDFMacAnnotateSession existingSessionForTab:tab] : nil;
}

// The canvas view, when Annotate shows for this tab (it has a session); nil otherwise, so Fill & Sign alone is as before.
- (nullable SPDFMacAnnotateCanvasView*)annotateCanvas {
    SPDFMacAnnotateSession* session = [self annotateSession];
    if (!session || self.hidden) return nil;
    SPDFMacAnnotateCanvasView* view = self.controller.annotateCanvasView;
    return view.session == session ? view : nil;
}

- (void)annotateAttachCanvasView {
    SPDFMacAnnotateCanvasView* view = [self annotateSession] ? self.controller.annotateCanvasView : nil;
    if (view && view.overlay != self) [view attachBelowOverlay:self];
    else if (view && self.superview && view.superview != self.superview) [view attachBelowOverlay:self];
}

- (BOOL)annotateForwarding {
    return [objc_getAssociatedObject(self, &kSPDFAnnotateForwardingKey) boolValue];
}

- (void)setAnnotateForwarding:(BOOL)forwarding {
    objc_setAssociatedObject(self, &kSPDFAnnotateForwardingKey, forwarding ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// mouseDown: and rightMouseDown: ask first. YES: the canvas view took the event (and the gesture it starts).
- (BOOL)annotateTakeMouseDown:(NSEvent*)event {
    SPDFMacAnnotateCanvasView* view = [self annotateCanvas];
    SPDFMacAnnotateSession* session = view.session;
    BOOL right = event.type == NSEventTypeRightMouseDown ||
                 (event.type == NSEventTypeLeftMouseDown && (event.modifierFlags & NSEventModifierFlagControl));
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger page;
    [self.controller.annotateCanvasView commitTextEditor];  // a click anywhere else closes the text box, as on the canvas
    if (!view || ![self locateViewPoint:point page:&page pagePoint:NULL]) return NO;
    // Select pressed where none of Annotate's objects is (those go to the canvas view): Annotate's selection ends too.
    if (!right && session.tool == SPDFAnnotateToolSelect && session.selectedObjects.count) session.selectedObjects = @[];
    if (!right && ![view takesEventsForTool:session.tool]) return NO;
    if (right && (session.tool == SPDFAnnotateToolFormText || session.tool == SPDFAnnotateToolFormMark ||
                  session.tool == SPDFAnnotateToolFormSignature))
        return NO;  // Fill & Sign's form tools keep their own menu (Check, Cross, Remove)
    session.currentPage = page;  // the Layers panel and the status bar follow the page touched
    [self.controller flushPendingChanges];
    [self.window makeFirstResponder:self];
    [self setAnnotateForwarding:YES];
    if (event.type == NSEventTypeRightMouseDown) [view rightMouseDown:event];
    else [view mouseDown:event];
    return YES;
}

- (void)mouseDragged:(NSEvent*)event {
    if ([self annotateForwarding]) [[self annotateCanvas] mouseDragged:event];
}

- (void)mouseUp:(NSEvent*)event {
    if (![self annotateForwarding]) return;
    [self setAnnotateForwarding:NO];
    [[self annotateCanvas] mouseUp:event];
}

- (void)rightMouseDragged:(NSEvent*)event {
    if ([self annotateForwarding]) [[self annotateCanvas] rightMouseDragged:event];
}

- (void)rightMouseUp:(NSEvent*)event {
    if (![self annotateForwarding]) return;
    [self setAnnotateForwarding:NO];
    [[self annotateCanvas] rightMouseUp:event];
}

// Delete and the arrows act on Annotate's selected objects straight away, not after the page view, the window and
// every menu's key equivalents had their turn.
- (BOOL)annotateKeyDown:(NSEvent*)event {
    SPDFMacAnnotateCanvasView* view = [self annotateCanvas];
    if (!view.session.selectedObjects.count) return NO;
    unichar c = event.charactersIgnoringModifiers.length ? [event.charactersIgnoringModifiers characterAtIndex:0] : 0;
    if (c != NSDeleteCharacter && c != NSBackspaceCharacter && c != NSDeleteFunctionKey && c != NSLeftArrowFunctionKey &&
        c != NSRightArrowFunctionKey && c != NSUpArrowFunctionKey && c != NSDownArrowFunctionKey)
        return NO;
    [view keyDown:event];
    return YES;
}

// The page view under the overlay asks the topmost view for its cursor before setting one (SPDFApplyCursorOverlay): an
// Annotate tool's cursor comes from the canvas view, Fill & Sign's from its last hover, so neither fights the I-beam.
- (NSCursor*)spdf_cursorForTrackingOverlayAt:(NSPoint)windowPoint {
    SPDFMacAnnotateCanvasView* view = [self annotateCanvas];
    if (view && [view takesEventsForTool:view.session.tool]) return [view cursorAtWindowPoint:windowPoint];
    return self.hoverCursor;
}

// The pointer over a page with an Annotate tool: the canvas view sets the cursor and the live preview. YES: handled.
- (BOOL)annotateMouseMoved:(NSEvent*)event {
    SPDFMacAnnotateCanvasView* view = [self annotateCanvas];
    if (!view || ![view takesEventsForTool:view.session.tool]) return NO;
    [view mouseMoved:event];
    return YES;
}

@end
