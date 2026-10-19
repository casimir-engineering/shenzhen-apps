#import <Foundation/Foundation.h>

#import "SPDFMacWindowChrome.h"
#import "SPDFMacWindowPlacement.h"

static void expect_action(NSString* label, SPDFWindowChromeAction actual, SPDFWindowChromeAction expected) {
    if (actual == expected) return;
    NSLog(@"FAIL %@: got %ld, expected %ld", label, (long)actual, (long)expected);
    exit(1);
}

static void expect_bool(NSString* label, BOOL actual, BOOL expected) {
    if (actual == expected) return;
    NSLog(@"FAIL %@: got %d, expected %d", label, (int)actual, (int)expected);
    exit(1);
}

// Restoring a window where it was left, including on a second display.
//
// The saved value is a WINDOW frame; -initWithContentRect: wants a CONTENT
// rect. Handing it the frame made the window a titlebar taller than it was
// saved, and AppKit then repositioned the oversized window -- a frame left on
// an external display came back on the main one (measured: saved AppKit y 1319,
// restored 487). The conversion has to be exact in both directions, and it must
// not care where the frame sits: a display above or left of the main one has
// negative origins, which is precisely the case that was broken.
static int gPlacementFailures;

static void ExpectFrameRoundTrips(const char* what, NSRect frame) {
    static const NSWindowStyleMask mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                          NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSRect content = spdf_window_content_rect_for_saved_frame(frame);
    NSRect back = [NSWindow frameRectForContentRect:content styleMask:mask];
    if (NSEqualRects(back, frame)) return;
    fprintf(stderr, "FAIL: %s -- %s became %s\n", what, NSStringFromRect(frame).UTF8String,
            NSStringFromRect(back).UTF8String);
    ++gPlacementFailures;
    // A content rect equal to the frame is the original bug: the window then
    // ends up a titlebar taller than it was saved.
    if (NSEqualRects(content, frame)) fprintf(stderr, "       (content rect was not converted at all)\n");
}

// A remembered frame must survive a launch that cannot show it.
//
// The defect: a window remembered on an external display, launched once while
// only the built-in screen was attached, was clamped onto the built-in screen
// -- and that clamp was then SAVED, so the remembered position was gone for
// good. Measured on the real session: 342,1307 (external) became 0,65, which is
// exactly the built-in screen's visible frame.
static void ExpectUsable(const char* what, NSRect frame, NSArray<NSValue*>* screens, BOOL expected) {
    if (spdf_window_frame_is_usable_on_screens(frame, screens) == expected) return;
    fprintf(stderr, "FAIL: %s\n", what);
    ++gPlacementFailures;
}

static int TestFrameUsability(void) {
    // The two screens this was found on: built-in, and a 3440x1440 above it.
    NSArray<NSValue*>* both = @[
        [NSValue valueWithRect:NSMakeRect(0, 65, 1800, 1065)],
        [NSValue valueWithRect:NSMakeRect(-898, 1169, 3440, 1440)]
    ];
    NSArray<NSValue*>* builtInOnly = @[ [NSValue valueWithRect:NSMakeRect(0, 65, 1800, 1065)] ];

    ExpectUsable("a frame on the external display is usable while it is attached",
                 NSMakeRect(342, 1307, 1800, 1065), both, YES);
    // The same frame with that display gone: NOT usable, so it must be shown
    // somewhere else -- and, per spdf_window_frame_to_persist, not saved over.
    ExpectUsable("the same frame is not usable once that display is gone", NSMakeRect(342, 1307, 1800, 1065),
                 builtInOnly, NO);
    ExpectUsable("a frame on the built-in screen is usable", NSMakeRect(0, 65, 1800, 1065), builtInOnly, YES);
    // A sliver hanging onto a screen edge is not somewhere a window can be
    // used. The bar is an AREA (80x80), matching what spdf_sane_window_frame
    // already treated as "not really on screen", so a 5pt-wide edge fails it
    // while a 50pt-wide strip -- 53,000 square points -- passes.
    ExpectUsable("a 5pt sliver is not usable", NSMakeRect(-1795, 65, 1800, 1065), builtInOnly, NO);
    // Mostly off-screen but with a real corner on it is fine: the reader can
    // still grab it, and moving windows there is their prerogative.
    ExpectUsable("a frame overlapping enough is usable", NSMakeRect(1600, 65, 1800, 1065), builtInOnly, YES);
    ExpectUsable("no screens at all means nothing is usable", NSMakeRect(0, 65, 800, 600), @[], NO);
    return gPlacementFailures == 0 ? 0 : 1;
}

static int TestWindowPlacement(void) {
    ExpectFrameRoundTrips("a frame on the main display", NSMakeRect(220, 230, 1300, 900));
    // AppKit y 1319 on a display mounted above the main one.
    ExpectFrameRoundTrips("a frame on a display above the main one", NSMakeRect(220, 1319, 1300, 900));
    // A display to the LEFT has negative x.
    ExpectFrameRoundTrips("a frame on a display left of the main one", NSMakeRect(-898, 1169, 3440, 1440));
    ExpectFrameRoundTrips("a minimum-size frame", NSMakeRect(0, 0, 480, 320));
    return gPlacementFailures == 0 ? 0 : 1;
}

int main(void) {
    if (TestWindowPlacement()) return 1;
    if (TestFrameUsability()) return 1;
    @autoreleasepool {
        expect_action(@"single click drags", spdf_window_chrome_action(1, NO, NO, NO), SPDFWindowChromeActionDrag);
        expect_action(@"double click zooms", spdf_window_chrome_action(2, NO, NO, NO), SPDFWindowChromeActionZoom);
        expect_action(@"later click count zooms", spdf_window_chrome_action(3, NO, NO, NO),
                      SPDFWindowChromeActionZoom);
        expect_action(@"full screen ignores double click", spdf_window_chrome_action(2, YES, NO, NO),
                      SPDFWindowChromeActionNone);
        expect_action(@"presentation ignores double click", spdf_window_chrome_action(2, NO, YES, NO),
                      SPDFWindowChromeActionNone);

        // Clicks that land on an interactive control belong to the control:
        // no drag on single click, no zoom on double click, in any mode.
        expect_action(@"control single click never drags", spdf_window_chrome_action(1, NO, NO, YES),
                      SPDFWindowChromeActionNone);
        expect_action(@"control double click never zooms", spdf_window_chrome_action(2, NO, NO, YES),
                      SPDFWindowChromeActionNone);
        expect_action(@"control triple click never zooms", spdf_window_chrome_action(3, NO, NO, YES),
                      SPDFWindowChromeActionNone);
        expect_action(@"control click inert in full screen", spdf_window_chrome_action(2, YES, NO, YES),
                      SPDFWindowChromeActionNone);
        expect_action(@"control click inert in presentation", spdf_window_chrome_action(2, NO, YES, YES),
                      SPDFWindowChromeActionNone);

        // The hit-view classifier tolerates a missed hit-test (nil view):
        // empty chrome background keeps its native drag/zoom behavior.
        expect_bool(@"nil hit view is not interactive", spdf_window_chrome_view_is_interactive(nil), NO);

        // Click-to-focus: any press of any mouse button counts, nothing else does.
        expect_bool(@"left mouse down is a press", spdf_window_event_is_mouse_press(SPDFWindowEventTypeLeftMouseDown),
                    YES);
        expect_bool(@"right mouse down is a press",
                    spdf_window_event_is_mouse_press(SPDFWindowEventTypeRightMouseDown), YES);
        expect_bool(@"middle mouse down is a press",
                    spdf_window_event_is_mouse_press(SPDFWindowEventTypeOtherMouseDown), YES);
        expect_bool(@"left mouse up is not a press", spdf_window_event_is_mouse_press(2), NO);
        expect_bool(@"left mouse dragged is not a press", spdf_window_event_is_mouse_press(6), NO);
        expect_bool(@"key down is not a press", spdf_window_event_is_mouse_press(10), NO);
        expect_bool(@"scroll wheel is not a press", spdf_window_event_is_mouse_press(22), NO);
        expect_bool(@"magnify is not a press", spdf_window_event_is_mouse_press(30), NO);

        // The window is unfocused in any of these three ways; a click fixes all
        // of them. The middle-click case is the tab close the user reported:
        // macOS never activates an app on a middle-click, so we must.
        expect_bool(@"click activates an inactive app",
                    spdf_window_click_should_activate(SPDFWindowEventTypeLeftMouseDown, NO, NO, YES, NO, NO), YES);
        expect_bool(@"click focuses a non-key window of the active app",
                    spdf_window_click_should_activate(SPDFWindowEventTypeLeftMouseDown, YES, NO, YES, NO, NO), YES);
        expect_bool(@"click activates the app for its own key window",
                    spdf_window_click_should_activate(SPDFWindowEventTypeLeftMouseDown, NO, YES, YES, NO, NO), YES);
        expect_bool(@"middle click focuses too",
                    spdf_window_click_should_activate(SPDFWindowEventTypeOtherMouseDown, NO, NO, YES, NO, NO), YES);
        expect_bool(@"right click focuses too",
                    spdf_window_click_should_activate(SPDFWindowEventTypeRightMouseDown, NO, NO, YES, NO, NO), YES);

        // Nothing to do, or not ours to do.
        expect_bool(@"already focused window is left alone",
                    spdf_window_click_should_activate(SPDFWindowEventTypeLeftMouseDown, YES, YES, YES, NO, NO), NO);
        expect_bool(@"scroll never activates", spdf_window_click_should_activate(22, NO, NO, YES, NO, NO), NO);
        expect_bool(@"magnify never activates", spdf_window_click_should_activate(30, NO, NO, YES, NO, NO), NO);
        expect_bool(@"mouse up never activates", spdf_window_click_should_activate(2, NO, NO, YES, NO, NO), NO);
        expect_bool(@"a window that cannot take key is left alone",
                    spdf_window_click_should_activate(SPDFWindowEventTypeLeftMouseDown, NO, NO, NO, NO, NO), NO);
        expect_bool(@"an attached sheet keeps focus",
                    spdf_window_click_should_activate(SPDFWindowEventTypeLeftMouseDown, NO, NO, YES, YES, NO), NO);
        expect_bool(@"an app-modal window keeps focus",
                    spdf_window_click_should_activate(SPDFWindowEventTypeLeftMouseDown, NO, NO, YES, NO, YES), NO);

        // Nil arguments are inert: the imperative wrapper must never crash on a
        // window or event that is gone.
        spdf_window_activate_for_click_event(nil, nil);

        // Key handshake. AppKit hands over key and main status only while super
        // processes the press that arrived at a non-key window, so that press
        // must reach super before any -sendEvent: handler can swallow it. Miss
        // it and the window stays keyless for good: grey traffic lights on a
        // window the window server considers main, and -makeKeyWindow refused.
        expect_bool(@"a press at a non-key window needs the handshake",
                    spdf_window_click_needs_key_handshake(SPDFWindowEventTypeLeftMouseDown, NO, YES, NO, NO), YES);
        expect_bool(@"a middle-click press needs it too",
                    spdf_window_click_needs_key_handshake(SPDFWindowEventTypeOtherMouseDown, NO, YES, NO, NO), YES);
        expect_bool(@"a right-click press needs it too",
                    spdf_window_click_needs_key_handshake(SPDFWindowEventTypeRightMouseDown, NO, YES, NO, NO), YES);
        // Already key: nothing to hand over, so the handler order is untouched
        // and every focused interaction keeps its existing behaviour exactly.
        expect_bool(@"a press at the key window needs no handshake",
                    spdf_window_click_needs_key_handshake(SPDFWindowEventTypeLeftMouseDown, YES, YES, NO, NO), NO);
        expect_bool(@"scroll never needs the handshake", spdf_window_click_needs_key_handshake(22, NO, YES, NO, NO),
                    NO);
        expect_bool(@"magnify never needs the handshake", spdf_window_click_needs_key_handshake(30, NO, YES, NO, NO),
                    NO);
        expect_bool(@"mouse up never needs the handshake", spdf_window_click_needs_key_handshake(2, NO, YES, NO, NO),
                    NO);
        expect_bool(@"a window that cannot take key needs no handshake",
                    spdf_window_click_needs_key_handshake(SPDFWindowEventTypeLeftMouseDown, NO, NO, NO, NO), NO);
        expect_bool(@"an attached sheet suppresses the handshake",
                    spdf_window_click_needs_key_handshake(SPDFWindowEventTypeLeftMouseDown, NO, YES, YES, NO), NO);
        expect_bool(@"an app-modal window suppresses the handshake",
                    spdf_window_click_needs_key_handshake(SPDFWindowEventTypeLeftMouseDown, NO, YES, NO, YES), NO);
        expect_bool(@"nil window and event need no handshake", spdf_window_event_needs_key_handshake(nil, nil), NO);

        // Zoom wheel: Cmd or Ctrl on an actively scrolling wheel, never on the
        // inertial tail. Both the focused responder chain and the out-of-focus
        // event tap ask this, so an unfocused Cmd+wheel zooms exactly like a
        // focused one.
        const NSUInteger cmd = SPDFWindowModifierFlagCommand;
        const NSUInteger ctrl = SPDFWindowModifierFlagControl;
        const NSUInteger shift = 1 << 17;  // NSEventModifierFlagShift
        expect_bool(@"command wheel zooms", spdf_scroll_is_zoom_wheel(cmd, NO), YES);
        expect_bool(@"control wheel zooms", spdf_scroll_is_zoom_wheel(ctrl, NO), YES);
        expect_bool(@"command with other modifiers still zooms", spdf_scroll_is_zoom_wheel(cmd | shift, NO), YES);
        expect_bool(@"plain wheel scrolls", spdf_scroll_is_zoom_wheel(0, NO), NO);
        expect_bool(@"shift wheel scrolls sideways, never zooms", spdf_scroll_is_zoom_wheel(shift, NO), NO);
        expect_bool(@"command held during momentum never zooms", spdf_scroll_is_zoom_wheel(cmd, YES), NO);
        expect_bool(@"plain momentum never zooms", spdf_scroll_is_zoom_wheel(0, YES), NO);

        // Tap ownership. Out of focus the tap sees the scroll first; if the
        // window server hands the very same event to the window as well, the
        // responder chain must stand down instead of zooming twice.
        expect_bool(@"tap owns the event it just zoomed",
                    spdf_zoom_wheel_handled_by_tap(YES, NO, 100.0, 100.0, 0.5), YES);
        expect_bool(@"tap owns a rebuilt event within the hop window",
                    spdf_zoom_wheel_handled_by_tap(YES, NO, 100.5, 100.0, 0.001), YES);
        expect_bool(@"a later scroll the tap declined still zooms",
                    spdf_zoom_wheel_handled_by_tap(YES, NO, 100.5, 100.0, 0.5), NO);
        expect_bool(@"no tap zoom yet leaves the responder chain in charge",
                    spdf_zoom_wheel_handled_by_tap(YES, NO, 100.0, 0.0, 1.0e6), NO);
        expect_bool(@"focused app always zooms through the responder chain",
                    spdf_zoom_wheel_handled_by_tap(YES, YES, 100.0, 100.0, 0.0), NO);
        expect_bool(@"without a tap the responder chain is the only path",
                    spdf_zoom_wheel_handled_by_tap(NO, NO, 100.0, 100.0, 0.0), NO);
        expect_bool(@"a clock that ran backwards does not silence the wheel",
                    spdf_zoom_wheel_handled_by_tap(YES, NO, 100.5, 100.0, -1.0), NO);
    }
    return 0;
}
