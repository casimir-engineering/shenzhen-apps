#import "SPDFMacWindowChrome.h"

#import <AppKit/AppKit.h>


SPDFWindowChromeAction spdf_window_chrome_action(NSUInteger clickCount, BOOL fullScreen, BOOL presentation,
                                                 BOOL onInteractiveControl) {
    // A click that lands on an interactive control belongs to that control:
    // never drag the window from it, and never let the second click of a
    // rapid double-click on it zoom the window. (Events still reach the
    // chrome layer from controls that decline them — a disabled control
    // forwards mouseDown up the responder chain, and a click inside a
    // segmented control's frame padding but off the visible bezel does too.)
    if (onInteractiveControl) return SPDFWindowChromeActionNone;
    if (clickCount < 2) return SPDFWindowChromeActionDrag;
    if (fullScreen || presentation) return SPDFWindowChromeActionNone;
    return SPDFWindowChromeActionZoom;
}

BOOL spdf_window_chrome_view_is_interactive(NSView* hitView) {
    // Resolved by name (not by symbol) so this file also links into the
    // Foundation-only window-chrome unit-test binary.
    Class controlClass = NSClassFromString(@"NSControl");
    Class textClass = NSClassFromString(@"NSText"); // field editors (NSTextView)
    for (NSView* view = hitView; view; view = view.superview) {
        BOOL interactiveKind =
            (controlClass && [view isKindOfClass:controlClass]) || (textClass && [view isKindOfClass:textClass]);
        if (!interactiveKind) continue;
        // Chrome drag surfaces (SPDFToolbarDragLabel is an NSTextField)
        // declare mouseDownCanMoveWindow=YES; genuine controls return NO.
        if (view.mouseDownCanMoveWindow) continue;
        return YES;
    }
    return NO;
}

BOOL spdf_scroll_is_zoom_wheel(NSUInteger modifierFlags, BOOL isMomentum) {
    // Momentum is the tail of a scroll the fingers already left; whatever the
    // user presses during the coast cannot retroactively make it a zoom.
    if (isMomentum) return NO;
    return (modifierFlags & (SPDFWindowModifierFlagCommand | SPDFWindowModifierFlagControl)) != 0;
}

// How long a tap zoom keeps ownership of the wheel. The tap runs on the same
// physical event a fraction of a millisecond before AppKit could deliver it, so
// this only has to outlast that hop; it is deliberately far shorter than the
// gap between two deliberate wheel gestures.
static const double kSPDFTapZoomWheelOwnershipSeconds = 0.02;

BOOL spdf_zoom_wheel_handled_by_tap(BOOL tapArmed, BOOL appActive, double eventTimestamp,
                                    double tapZoomEventTimestamp, double secondsSinceTapZoom) {
    // Focused, or with no tap armed, the responder chain is the only zoom path
    // and must always run.
    if (!tapArmed || appActive) return NO;
    if (tapZoomEventTimestamp > 0.0 && fabs(eventTimestamp - tapZoomEventTimestamp) < 0.0005) return YES;
    return secondsSinceTapZoom >= 0.0 && secondsSinceTapZoom < kSPDFTapZoomWheelOwnershipSeconds;
}

static_assert(SPDFWindowModifierFlagControl == NSEventModifierFlagControl, "control modifier bit drifted");
static_assert(SPDFWindowModifierFlagCommand == NSEventModifierFlagCommand, "command modifier bit drifted");
static_assert(SPDFWindowEventTypeLeftMouseDown == NSEventTypeLeftMouseDown, "left mouse down value drifted");
static_assert(SPDFWindowEventTypeRightMouseDown == NSEventTypeRightMouseDown, "right mouse down value drifted");
static_assert(SPDFWindowEventTypeOtherMouseDown == NSEventTypeOtherMouseDown, "other mouse down value drifted");

BOOL spdf_window_event_is_mouse_press(NSUInteger eventType) {
    return eventType == SPDFWindowEventTypeLeftMouseDown || eventType == SPDFWindowEventTypeRightMouseDown ||
           eventType == SPDFWindowEventTypeOtherMouseDown;
}

BOOL spdf_window_click_should_activate(NSUInteger eventType, BOOL appActive, BOOL windowIsKey,
                                       BOOL windowCanBecomeKey, BOOL windowHasAttachedSheet,
                                       BOOL anotherWindowIsModal) {
    if (!spdf_window_event_is_mouse_press(eventType)) return NO;
    // A sheet is modal for its parent, and an app-modal window is modal for
    // everything: clicks elsewhere must keep AppKit's native handling (bounce
    // the modal), never pull key away from it.
    if (windowHasAttachedSheet || anotherWindowIsModal) return NO;
    if (!windowCanBecomeKey) return NO;
    // Already focused: nothing to do, and re-ordering on every click would be
    // both wasteful and visible.
    if (appActive && windowIsKey) return NO;
    return YES;
}

void spdf_window_activate_for_click_event(NSWindow* window, NSEvent* event) {
    if (!window || !event) return;
    // Resolved by name (not by symbol) so this file keeps linking into the
    // Foundation-only window-chrome unit-test binary.
    id app = [NSClassFromString(@"NSApplication") sharedApplication];
    BOOL appActive = app ? [app isActive] : YES;
    id modalWindow = [app modalWindow];
    if (!spdf_window_click_should_activate(event.type, appActive, window.keyWindow, window.canBecomeKeyWindow,
                                           window.attachedSheet != nil, modalWindow && modalWindow != window))
        return;
    // Order matters: focus the window BEFORE the event is dispatched, so AppKit
    // sees a key window and delivers the click normally instead of consuming it
    // as the click that activates.
    // -activateIgnoringOtherApps: is deprecated and, under the cooperative
    // activation macOS 14 introduced, is largely ignored: an app may no longer
    // simply promote itself. It left the window taking KEY (the keyboard went
    // to it) while the app stayed INACTIVE -- which is exactly the reported
    // symptom, a focused-feeling window whose traffic lights stay grey.
    // -[NSApplication activate] is the supported replacement.
    if (!appActive) {
        if ([app respondsToSelector:@selector(activate)]) [app activate];
        else [app activateIgnoringOtherApps:YES];
    }
    if (!window.keyWindow) [window makeKeyAndOrderFront:nil];
}

BOOL spdf_window_click_needs_key_handshake(NSUInteger eventType, BOOL windowIsKey, BOOL windowCanBecomeKey,
                                           BOOL windowHasAttachedSheet, BOOL anotherWindowIsModal) {
    if (!spdf_window_event_is_mouse_press(eventType)) return NO;
    if (windowHasAttachedSheet || anotherWindowIsModal) return NO;
    if (!windowCanBecomeKey) return NO;
    // Already key: AppKit has already handed this window key and main status,
    // and there is nothing for super to complete.
    return !windowIsKey;
}

BOOL spdf_window_event_needs_key_handshake(NSWindow* window, NSEvent* event) {
    if (!window || !event) return NO;
    // Resolved by name (not by symbol) so this file keeps linking into the
    // Foundation-only window-chrome unit-test binary.
    id app = [NSClassFromString(@"NSApplication") sharedApplication];
    id modalWindow = [app modalWindow];
    return spdf_window_click_needs_key_handshake(event.type, window.keyWindow, window.canBecomeKeyWindow,
                                                 window.attachedSheet != nil, modalWindow && modalWindow != window);
}

SPDFWindowChromeAction spdf_window_chrome_action_for_event(NSWindow* window, NSEvent* event, BOOL fullScreen,
                                                           BOOL presentation) {
    if (!event) return SPDFWindowChromeActionNone;
    NSView* contentView = window.contentView;
    // hitTest: expects the point in the receiver's superview coordinate space.
    NSView* hitReference = contentView.superview ?: contentView;
    NSView* hitView =
        contentView ? [contentView hitTest:[hitReference convertPoint:event.locationInWindow fromView:nil]] : nil;
    return spdf_window_chrome_action(event.clickCount, fullScreen, presentation,
                                     spdf_window_chrome_view_is_interactive(hitView));
}

NSEvent* spdf_window_button_press_event(NSWindow* window, NSEvent* event) {
    if(event.type!=NSEventTypeLeftMouseDown || event.clickCount<2) return event;
    NSView* content=window.contentView;
    NSView* reference=content.superview ?: content;
    NSView* hit=[content hitTest:[reference convertPoint:event.locationInWindow fromView:nil]];
    Class button=NSClassFromString(@"NSButton"), segments=NSClassFromString(@"NSSegmentedControl");
    for(NSView* view=hit;view;view=view.superview) {
        if(![view isKindOfClass:button] && ![view isKindOfClass:segments]) continue;
        // AppKit otherwise reuses the previous multi-click target, which may be
        // the titlebar drag surface. Text fields retain native word selection.
        return [NSEvent mouseEventWithType:event.type location:event.locationInWindow
            modifierFlags:event.modifierFlags timestamp:event.timestamp windowNumber:event.windowNumber
            context:nil eventNumber:event.eventNumber clickCount:1 pressure:event.pressure];
    }
    return event;
}

BOOL spdf_window_route_button_press(NSWindow* window, NSEvent* event) {
    if(event.type!=NSEventTypeLeftMouseDown || window.attachedSheet) return NO;
    id app=[NSClassFromString(@"NSApplication") sharedApplication];
    if([app modalWindow] && [app modalWindow]!=window) return NO;
    NSView* content=window.contentView;
    NSView* reference=content.superview ?: content;
    NSView* hit=[content hitTest:[reference convertPoint:event.locationInWindow fromView:nil]];
    Class button=NSClassFromString(@"NSButton"), segments=NSClassFromString(@"NSSegmentedControl");
    for(NSView* view=hit;view;view=view.superview) {
        if(![view isKindOfClass:button] && ![view isKindOfClass:segments]) continue;
        [view mouseDown:event]; return YES;
    }
    return NO;
}
