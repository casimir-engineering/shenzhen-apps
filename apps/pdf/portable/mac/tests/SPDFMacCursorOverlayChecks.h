#import <objc/runtime.h>
#import "SPDFMacCursorOverlay.h"
#include <assert.h>
@interface NSView (SPDFCursorOverlayTestCanvas)
- (void)updateCursorForPointInWindow:(NSPoint)point;
- (void)refreshCursorForMouseLocation;
@end
@interface SPDFCursorOverlayTestWindow : NSWindow
@property NSPoint fixturePoint;
@end
@implementation SPDFCursorOverlayTestWindow
- (BOOL)isKeyWindow { return YES; }
- (NSPoint)mouseLocationOutsideOfEventStream { return self.fixturePoint; }
@end
@interface SPDFCursorOverlayTestHandle : NSView <SPDFCursorOverlay>
@end
@implementation SPDFCursorOverlayTestHandle
- (NSCursor*)spdf_cursorForTrackingOverlay { return NSCursor.resizeLeftRightCursor; }
@end
@interface SPDFCursorOverlayTestReader : NSObject
@end
@implementation SPDFCursorOverlayTestReader
- (BOOL)documentViewInPresentationMode { return NO; }
- (void)documentViewEndHoverComment {}
@end
static NSCursor* SPDFLastTestCursor;
static void SPDFCaptureCursor(id cursor, SEL selector) { (void)selector; SPDFLastTestCursor=cursor; }
static void SPDFCheckCanvasOverlayCursor(NSView* canvas) {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    SPDFCursorOverlayTestWindow* window = [[SPDFCursorOverlayTestWindow alloc] initWithContentRect:NSMakeRect(0,0,400,300)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    canvas.frame=window.contentView.bounds; [window.contentView addSubview:canvas];
    SPDFCursorOverlayTestHandle* overlay = [[SPDFCursorOverlayTestHandle alloc] initWithFrame:NSMakeRect(290,0,13,300)];
    [window.contentView addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
    Method set = class_getInstanceMethod(NSCursor.class,@selector(set));
    IMP previous = method_setImplementation(set,(IMP)SPDFCaptureCursor);
    @try {
        // Both transparent margins and the central 5pt gutter own one cursor.
        for (NSNumber* x in @[@290.5,@293,@296.5,@300,@302.5]) {
            NSPoint point=NSMakePoint(x.doubleValue,150); window.fixturePoint=point;
            [NSCursor.resizeLeftRightCursor set];
            [canvas updateCursorForPointInWindow:point];
            assert(SPDFLastTestCursor==NSCursor.resizeLeftRightCursor);
            [NSCursor.arrowCursor set]; [canvas refreshCursorForMouseLocation];
            assert(SPDFLastTestCursor==NSCursor.resizeLeftRightCursor);
            NSEvent* exit = [NSEvent enterExitEventWithType:NSEventTypeMouseExited location:point modifierFlags:0 timestamp:0
                windowNumber:window.windowNumber context:nil eventNumber:0 trackingNumber:0 userData:NULL];
            [canvas mouseExited:exit];
            assert(SPDFLastTestCursor==NSCursor.resizeLeftRightCursor);
        }
        BOOL markdown = [canvas respondsToSelector:NSSelectorFromString(@"spdf_panController")];
        id panOwner = markdown ? [canvas valueForKey:@"spdf_panController"] : canvas;
        NSString* panKey = markdown ? @"panning" : @"isPanning";
        [panOwner setValue:@YES forKey:panKey]; [NSCursor.closedHandCursor set];
        [canvas updateCursorForPointInWindow:window.fixturePoint]; [canvas refreshCursorForMouseLocation];
        NSEvent* exit = [NSEvent enterExitEventWithType:NSEventTypeMouseExited location:window.fixturePoint modifierFlags:0 timestamp:0
            windowNumber:window.windowNumber context:nil eventNumber:0 trackingNumber:0 userData:NULL];
        [canvas mouseExited:exit]; assert(SPDFLastTestCursor==NSCursor.closedHandCursor);
        [panOwner setValue:@NO forKey:panKey];
        if (markdown) {
            [canvas setValue:@YES forKey:@"draggingSelection"]; [NSCursor.IBeamCursor set];
            [canvas updateCursorForPointInWindow:window.fixturePoint]; [canvas mouseExited:exit];
            assert(SPDFLastTestCursor==NSCursor.IBeamCursor);
            [canvas setValue:@NO forKey:@"draggingSelection"];
        }
        // An unrelated topmost view or hidden handle must not retain its cursor.
        NSView* blocker = [[NSView alloc] initWithFrame:overlay.frame];
        [window.contentView addSubview:blocker positioned:NSWindowAbove relativeTo:nil];
        assert(!SPDFApplyCursorOverlay(canvas,window.fixturePoint)); [blocker removeFromSuperview];
        overlay.hidden=YES;
        assert(!SPDFApplyCursorOverlay(canvas,window.fixturePoint));
        [canvas updateCursorForPointInWindow:window.fixturePoint];
        assert(SPDFLastTestCursor!=NSCursor.resizeLeftRightCursor);
        assert(!window.visible);
    } @finally {
        method_setImplementation(set,previous); [canvas removeFromSuperview];
    }
}
