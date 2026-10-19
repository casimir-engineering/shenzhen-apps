#import <Foundation/Foundation.h>

@class NSEvent;
@class NSView;
@class NSWindow;

// Implemented by SPDFWindow. Views embedded in the transparent title bar use
// this narrow protocol to preserve one native drag/zoom policy without knowing
// about the concrete application window class.
@protocol SPDFWindowChromeHandling <NSObject>
- (void)handleChromeMouseDown:(NSEvent*)event;
@end

typedef NS_ENUM(NSInteger, SPDFWindowChromeAction) {
    SPDFWindowChromeActionNone = 0,
    SPDFWindowChromeActionDrag,
    SPDFWindowChromeActionZoom,
};

SPDFWindowChromeAction spdf_window_chrome_action(NSUInteger clickCount, BOOL fullScreen, BOOL presentation,
                                                 BOOL onInteractiveControl);

// YES when the deepest hit view under a chrome click is (a descendant of) an
// interactive control — button, segmented control, popup, checkbox, text
// field, or a field editor — so the click must never be treated as titlebar
// chrome (drag / double-click zoom). Chrome-owned drag surfaces that happen
// to be controls (e.g. SPDFToolbarDragLabel) opt back in by overriding
// -mouseDownCanMoveWindow to return YES.
BOOL spdf_window_chrome_view_is_interactive(NSView* hitView);

// Raw NSEventType values for the three mouse-button presses, spelled out so the
// Foundation-only unit test can exercise the activation policy below without
// linking AppKit. Static-asserted against the AppKit constants in the .mm.
enum {
    SPDFWindowEventTypeLeftMouseDown = 1,    // NSEventTypeLeftMouseDown
    SPDFWindowEventTypeRightMouseDown = 3,   // NSEventTypeRightMouseDown
    SPDFWindowEventTypeOtherMouseDown = 25,  // NSEventTypeOtherMouseDown
};

// Raw NSEvent modifier bits for the two zoom modifiers, spelled out so the
// Foundation-only unit test can exercise the wheel-zoom policy below without
// linking AppKit. Static-asserted against the AppKit constants in the .mm.
enum {
    SPDFWindowModifierFlagControl = 1 << 18,  // NSEventModifierFlagControl
    SPDFWindowModifierFlagCommand = 1 << 20,  // NSEventModifierFlagCommand
};

// YES when a scroll wheel is the zoom gesture: Command or Control held while
// the wheel is still actively scrolling. Inertial momentum is a scroll coasting
// to a stop, so a modifier pressed during the coast (the Command held through
// Cmd+Tab, say) must never turn it into a zoom. Shared by the focused
// responder-chain path and by the out-of-focus event tap, so the two can never
// disagree about what counts as a zoom wheel.
BOOL spdf_scroll_is_zoom_wheel(NSUInteger modifierFlags, BOOL isMomentum);

// Out of focus, the event tap sees a zoom wheel at the head of the HID chain —
// before the window server decides whether to hand it to this app at all — so
// once armed the tap owns the unfocused zoom. Should the window server ALSO
// deliver that same scroll to the unfocused window, the responder chain must
// not zoom a second time. YES exactly while the tap has already zoomed for this
// event: matched on the event's own timestamp, and (because an event rebuilt
// from a CGEvent can carry a slightly different one) for a few milliseconds
// after any tap zoom. Both windows lapse the moment the tap stops zooming, so a
// point the tap declines — over a detached minimap window, say — still zooms
// through the responder chain.
BOOL spdf_zoom_wheel_handled_by_tap(BOOL tapArmed, BOOL appActive, double eventTimestamp,
                                    double tapZoomEventTimestamp, double secondsSinceTapZoom);

// YES for a press of any mouse button (left / right / middle / extra). Releases,
// drags, scrolls, gestures and key events are not presses.
BOOL spdf_window_event_is_mouse_press(NSUInteger eventType);

// Should this event focus the document window it was delivered to? Any press of
// any mouse button anywhere inside a ShenzhenPDF window focuses that window —
// AppKit only does this for clicks it dispatches itself, and the tab strip's
// clicks (tab select, close box, middle-click close) are intercepted in
// -sendEvent: before AppKit ever sees them, while macOS never activates an app
// on a middle-click at all. Declines when there is nothing to do (already the
// key window of the active app), when the window cannot take key, when a sheet
// is attached, and while some other window is running app-modal — in all three
// of those cases another window owns focus and AppKit's own handling is right.
BOOL spdf_window_click_should_activate(NSUInteger eventType, BOOL appActive, BOOL windowIsKey,
                                       BOOL windowCanBecomeKey, BOOL windowHasAttachedSheet,
                                       BOOL anotherWindowIsModal);

// Applies the policy above to one event: activates the app and makes `window`
// key before the event is dispatched further, so the focusing click still does
// its own job (select text, follow a link, close the tab) instead of being
// swallowed as a first click. No-op when the policy declines.
void spdf_window_activate_for_click_event(NSWindow* window, NSEvent* event);

// YES when this press is the one AppKit needs in order to hand the window key
// and main status, and that handover has not happened yet.
//
// AppKit performs the handover while it processes the activating mouse-down
// inside -[NSWindow sendEvent:] — not when the app is told to activate. So a
// -sendEvent: override that consumes a press before super (the tab strip's
// clicks, the presentation and arrangement handlers) leaves the handover
// undone, and it cannot be repaired afterwards: a later -makeKeyWindow /
// -makeMainWindow / -makeKeyAndOrderFront: is refused outright, because AppKit
// is still waiting for a mouse-down it will never see. The window server, which
// tracks the front window independently, does consider the window main — so the
// keyboard keeps working (key events route by window number, not by key status)
// while everything drawn from key state, the traffic lights above all, stays
// grey. A press matching this predicate must therefore reach super BEFORE any
// handler can swallow it.
//
// Declines exactly where -spdf_window_click_should_activate does — window
// cannot take key, a sheet is attached, another window is app-modal — plus the
// case where the window is already key and there is nothing to hand over.
BOOL spdf_window_click_needs_key_handshake(NSUInteger eventType, BOOL windowIsKey, BOOL windowCanBecomeKey,
                                           BOOL windowHasAttachedSheet, BOOL anotherWindowIsModal);

// Applies the predicate above to one live event and window.
BOOL spdf_window_event_needs_key_handshake(NSWindow* window, NSEvent* event);

// Full decision for one chrome mouse-down: re-hit-tests the event against the
// window's content view and refuses drag/zoom for clicks that land on an
// interactive control (chrome views also receive mouseDown via the responder
// chain from descendant controls that decline the event — a disabled control,
// or a click inside a segmented pill's frame padding off the visible bezel).
SPDFWindowChromeAction spdf_window_chrome_action_for_event(NSWindow* window, NSEvent* event, BOOL fullScreen,
                                                           BOOL presentation);

// Treat button presses independently of a preceding titlebar drag/double click.
NSEvent* spdf_window_button_press_event(NSWindow* window, NSEvent* event);
BOOL spdf_window_route_button_press(NSWindow* window, NSEvent* event);
