#import <Cocoa/Cocoa.h>

#import "SPDFMacUIHelpers.h"

// Out-of-focus zoom: everything that lets a trackpad pinch, or a Cmd/Ctrl +
// scroll, zoom the ShenzhenPDF window under the cursor while some other app is
// active. macOS hands a PLAIN scroll to the window under the cursor whatever
// app is frontmost, which is why unfocused scrolling has always worked; it
// keeps gesture events and modifier-carrying scrolls for the active app
// instead. The only dependable observer of those is a kCGHIDEventTap sitting at
// the head of the event chain, so the tap, its NSEvent-monitor fallback, and
// the routing from a tapped event to the view under the cursor all live here.

@interface SPDFScrollView (SPDFInactiveZoomRouting)
- (void)spdf_magnifyWithEvent:(NSEvent*)event
                magnification:(CGFloat)magnification
        centeredAtWindowPoint:(NSPoint)windowPoint;
- (BOOL)spdf_zoomWithScrollWheelEvent:(NSEvent*)event centeredAtWindowPoint:(NSPoint)windowPoint;
@end

@interface SPDFWindow (SPDFInactiveZoomRouting)
// Applies one magnify event AppKit delivered to this unfocused window itself
// (scroll-focus delivery). Declines, leaving the event to super, whenever the
// tap is armed and has therefore already applied it.
- (BOOL)routeInactiveMagnifyEvent:(NSEvent*)event;
@end

// Start tracking / stop tracking a document window as a target for out-of-focus
// zoom. Registration also installs the NSEvent monitors, once per process.
void spdf_inactive_zoom_register_window(SPDFWindow* window);
void spdf_inactive_zoom_forget_window(SPDFWindow* window);

// YES when the event tap has already turned this very scroll into a zoom, so
// the responder chain must let it pass instead of zooming a second time.
BOOL spdf_inactive_zoom_wheel_already_applied(NSEvent* event);
