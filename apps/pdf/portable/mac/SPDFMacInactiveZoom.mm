#import "SPDFMacInactiveZoom.h"

#import "SPDFMacSupport.h"
#import "SPDFMacWindowChrome.h"
#import <ApplicationServices/ApplicationServices.h>  // AXIsProcessTrusted (Accessibility trust check)

@interface NSView (SPDFInactiveZoomMinimapRouting)
- (BOOL)layoutScale:(CGFloat*)scaleOut
                gap:(CGFloat*)gapOut
         contentTop:(CGFloat*)contentTopOut
      contentHeight:(CGFloat*)contentHeightOut
        visibleRect:(NSRect*)visibleRectOut;
- (NSPoint)documentPointForMinimapCenterPoint:(NSPoint)point
                                        scale:(CGFloat)scale
                                          gap:(CGFloat)gap
                                contentHeight:(CGFloat)contentHeight
                                   contentTop:(CGFloat)contentTop;
@end

@interface SPDFWindow (SPDFInactiveZoomPrivate)
- (BOOL)routeInactiveMagnifyEvent:(NSEvent*)event windowPoint:(NSPoint)windowPoint magnification:(CGFloat)magnification;
- (BOOL)routeInactiveMagnifyEvent:(NSEvent*)event screenPoint:(NSPoint)screenPoint magnification:(CGFloat)magnification;
- (BOOL)routeInactiveZoomWheelEvent:(NSEvent*)event screenPoint:(NSPoint)screenPoint;
@end

static NSHashTable<SPDFWindow*>* spdf_inactive_magnify_windows(void) {
    static NSHashTable<SPDFWindow*>* windows = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ windows = [NSHashTable weakObjectsHashTable]; });
    return windows;
}

static SPDFWindow* spdf_magnify_window_under_screen_point(NSPoint screenPoint) {
    NSInteger hitWindowNumber = [NSWindow windowNumberAtPoint:screenPoint belowWindowWithWindowNumber:0];
    if (hitWindowNumber <= 0) return nil;
    for (SPDFWindow* window in spdf_inactive_magnify_windows()) {
        if (window.windowNumber != hitWindowNumber) continue;
        if (!window.visible || window.miniaturized) return nil;
        return window;
    }
    return nil;
}

// Magnify NSEvents observed through a global monitor are rebuilt by AppKit from the other app's gesture
// CGEvents: `magnification` is filled with the gesture's CUMULATIVE zoom (CGEvent gesture field 113) and
// `phase` is left at NSEventPhaseNone, unlike responder-chain events which carry per-event deltas. This
// converts consecutive cumulative values back into the per-event deltas the zoom code expects. Gesture
// boundaries are detected via phase when present, otherwise via the gap between event timestamps; the
// first event after a boundary only establishes the baseline (its own delta is unknown and tiny).
static const NSTimeInterval kSPDFInactiveMagnifyGestureGapSeconds = 0.3;

static CGFloat spdf_global_magnify_delta(NSEvent* event) {
    static BOOL gestureActive = NO;
    static CGFloat lastCumulative = 0.0;
    static NSTimeInterval lastTimestamp = 0.0;

    CGFloat cumulative = event.magnification;
    NSEventPhase phase = event.phase;

    if (phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) {
        CGFloat delta = gestureActive ? cumulative - lastCumulative : 0.0;
        gestureActive = NO;
        lastCumulative = 0.0;
        return delta;
    }
    // The other app's stream also contains legacy magnify CGEvents whose gesture payload does not survive
    // the monitor conversion (magnification reads 0); ignore them so they cannot corrupt the baseline.
    if (cumulative == 0.0 && phase == NSEventPhaseNone) return 0.0;

    BOOL gestureBreak = (phase & NSEventPhaseBegan) || !gestureActive ||
                        event.timestamp - lastTimestamp > kSPDFInactiveMagnifyGestureGapSeconds;
    // A new gesture's cumulative value restarts from zero, so the first
    // observed value IS the delta from rest — swallowing it as a baseline
    // loses the start of the pinch. Phase Began events genuinely carry zero.
    CGFloat delta;
    if (gestureBreak) delta = (phase & NSEventPhaseBegan) ? 0.0 : cumulative;
    else delta = cumulative - lastCumulative;
    gestureActive = YES;
    lastCumulative = cumulative;
    lastTimestamp = event.timestamp;
    return delta;
}

// Magnify events from a live AppKit gesture session always carry a phase and a
// per-event delta. Events rebuilt raw from gesture CGEvents (global monitor
// observation, or native scroll-focus delivery to an INACTIVE app) carry no
// phase and a CUMULATIVE magnification — AppKit's CGEvent conversion never
// reads the gesture phase field. Discriminate on the phase, not on the path.
static CGFloat spdf_normalized_magnify_delta(NSEvent* event) {
    if (event.phase != NSEventPhaseNone || event.momentumPhase != NSEventPhaseNone) return event.magnification;
    return spdf_global_magnify_delta(event);
}

// Cheap in-process check for the overwhelmingly common case: the cursor is
// over the key ShenzhenPDF window, so the responder chain is authoritative and
// no window-server hit test (windowNumberAtPoint IPC) is needed per event.
static BOOL spdf_point_in_key_spdf_window(NSPoint screenPoint) {
    NSWindow* keyWindow = NSApp.keyWindow;
    if (![keyWindow isKindOfClass:[SPDFWindow class]]) return NO;
    return NSPointInRect(screenPoint, keyWindow.frame);
}

// Set once the CGEventTap has successfully armed (Accessibility granted). The tap
// is the authoritative path for out-of-focus pinch, so once it is live the
// (unreliable, usually-silent) global NSEvent monitor must stand down — otherwise
// a single physical pinch could be applied twice. Read only on the main thread;
// the tap callback also runs on the main thread's run loop.
static BOOL gSPDFMagnifyTapActive = NO;

// One-shot diagnostic window: when SPDF_ZOOM_PROFILE=1, the tap (temporarily
// masking ALL events) logs every CGEventType it sees for the first few seconds
// after arming, so a single manual out-of-focus pinch reveals which CGEventType
// trackpad magnify actually arrives as on the user's macOS version. The shipped
// fix still masks only the specific gesture type; this is observation only.
static NSTimeInterval gSPDFMagnifyTapDiagnosticUntil = 0.0;

// kCGEventGesture / NSEventTypeGesture. Not in the documented CGEventType enum,
// but this is the umbrella HID gesture event that carries magnify/rotate/swipe
// and is how Hammerspoon, LinearMouse, Mos, PinchBar, BetterTouchTool observe
// pinch system-wide. Verified against PinchBar (eventsOfInterest: 1<<29).
static const CGEventType kSPDFGestureEventType = (CGEventType)29;

// Route one magnify NSEvent (rebuilt from a tapped gesture CGEvent) to the
// ShenzhenPDF window under the cursor, if any. Shared by the tap callback. The
// caller has already confirmed the app is inactive. Returns nothing; missing
// windows / zero deltas are simply ignored.
static void spdf_route_tapped_magnify_event(NSEvent* event) {
    NSPoint screenPoint = NSEvent.mouseLocation;
    SPDFWindow* window = spdf_magnify_window_under_screen_point(screenPoint);
    CGFloat delta = window ? spdf_normalized_magnify_delta(event) : 0.0;
    if (spdf_zoom_profile_enabled()) {
        spdf_zoom_profile_log(@"inactiveMagnify path=tap window=%@ phase=%lu raw=%.4f delta=%.4f",
                              window ? @"hit" : @"miss", (unsigned long)event.phase,
                              (double)event.magnification, (double)delta);
    }
    if (!window || window.keyWindow || delta == 0.0) return;
    [window routeInactiveMagnifyEvent:event screenPoint:screenPoint magnification:delta];
}

// The scroll event the tap most recently turned into a zoom, and the uptime at
// which it did so. Should the window server ALSO hand that same scroll to the
// unfocused window, -scrollWheel: consults these (through
// spdf_zoom_wheel_handled_by_tap) and declines rather than zooming twice.
static double gSPDFTapZoomWheelEventTimestamp = 0.0;
static NSTimeInterval gSPDFTapZoomWheelAppliedUptime = 0.0;

// Route one zoom wheel (Cmd/Ctrl + scroll), rebuilt from a tapped scroll
// CGEvent, to the ShenzhenPDF window under the cursor. Out of focus this is the
// dependable path: the tap sits at the head of the HID chain, so it sees the
// scroll before the window server decides where it goes and before any
// third-party HID tap downstream can reshape or swallow it. Plain scrolls are
// left entirely alone — AppKit already delivers those to the window under the
// cursor, and this must not become a second scrolling path.
static void spdf_route_tapped_zoom_wheel_event(NSEvent* event) {
    if (!spdf_scroll_is_zoom_wheel(event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask,
                                   event.momentumPhase != NSEventPhaseNone))
        return;
    NSPoint screenPoint = NSEvent.mouseLocation;
    SPDFWindow* window = spdf_magnify_window_under_screen_point(screenPoint);
    if (spdf_zoom_profile_enabled())
        spdf_zoom_profile_log(@"inactiveZoomWheel path=tap window=%@ dY=%.2f precise=%d", window ? @"hit" : @"miss",
                              (double)(event.scrollingDeltaY != 0.0 ? event.scrollingDeltaY : event.deltaY),
                              (int)event.hasPreciseScrollingDeltas);
    if (!window || window.keyWindow) return;
    if (![window routeInactiveZoomWheelEvent:event screenPoint:screenPoint]) return;
    gSPDFTapZoomWheelEventTimestamp = event.timestamp;
    gSPDFTapZoomWheelAppliedUptime = NSProcessInfo.processInfo.systemUptime;
}

static CFMachPortRef gSPDFMagnifyTapPort = NULL;
static CFRunLoopSourceRef gSPDFMagnifyTapSource = NULL;

static CGEventRef spdf_inactive_magnify_tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef cgEvent,
                                                     void* userInfo) {
    (void)proxy;
    (void)userInfo;

    // The window server disables a tap that takes too long or that the user
    // toggled; re-arm it in place instead of going permanently dead.
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gSPDFMagnifyTapPort) CGEventTapEnable(gSPDFMagnifyTapPort, true);
        if (spdf_zoom_profile_enabled()) spdf_zoom_profile_log(@"inactiveMagnify tap re-enabled type=%u", type);
        return cgEvent;
    }

    // Diagnostic window (SPDF_ZOOM_PROFILE=1, first few seconds after arming): the
    // tap masks ALL events, so log every CGEventType seen. A single out-of-focus
    // pinch here proves which type magnify actually is on this OS. We still only
    // ACT on the specific gesture type below, so all other events pass through
    // untouched even during the diagnostic window.
    if (gSPDFMagnifyTapDiagnosticUntil > 0.0) {
        if (NSDate.timeIntervalSinceReferenceDate <= gSPDFMagnifyTapDiagnosticUntil) {
            // Skip the firehose (mouse-moved/dragged) to keep the all-events tap
            // cheap; still log every other type, and resolve the NSEvent subtype
            // for gesture-family types so magnify is unambiguous in the log.
            BOOL noisy = (type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged ||
                          type == kCGEventRightMouseDragged || type == kCGEventOtherMouseDragged);
            if (!noisy) {
                NSEvent* probe = [NSEvent eventWithCGEvent:cgEvent];
                spdf_zoom_profile_log(@"inactiveMagnify diag cgType=%u nsType=%lu", (unsigned)type,
                                      probe ? (unsigned long)probe.type : 0UL);
            }
        } else {
            gSPDFMagnifyTapDiagnosticUntil = 0.0;
            spdf_zoom_profile_log(@"inactiveMagnify diag window closed");
        }
    }

    // Only act on the two event types the tap is for: the gesture umbrella (which
    // carries pinch) and the scroll wheel (which carries Cmd/Ctrl + scroll zoom).
    // Acting on anything else would be a bug even though, during diagnostics,
    // this callback transiently sees every event there is.
    if (type != kSPDFGestureEventType && type != kCGEventScrollWheel) return cgEvent;

    // Only the inactive case is the tap's job: when the app is active the
    // responder chain / local monitor are authoritative, so passing through here
    // (never routing) guarantees a single physical pinch is applied exactly once.
    if (NSApp.active) return cgEvent;

    // Cmd/Ctrl + scroll. Unlike a plain scroll, a modifier-carrying one is not
    // reliably handed to the unfocused window under the cursor, so route it here
    // and let -scrollWheel: stand down for the same event if it arrives anyway.
    if (type == kCGEventScrollWheel) {
        // Cheap pre-filter straight off the CGEvent: an unmodified scroll — by
        // far the common case, since this tap sees every scroll anywhere while
        // another app is in use — costs one flag read instead of an NSEvent
        // rebuild. The full test, momentum included, runs on the rebuilt event.
        if (!(CGEventGetFlags(cgEvent) & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl))) return cgEvent;
        NSEvent* wheel = [NSEvent eventWithCGEvent:cgEvent];
        if (wheel && wheel.type == NSEventTypeScrollWheel) spdf_route_tapped_zoom_wheel_event(wheel);
        return cgEvent;
    }

    // type 29 = NSEventTypeGesture, the umbrella gesture event that carries
    // magnify. Rebuild an NSEvent so the existing cumulative->delta and routing
    // logic (which keys on NSEventTypeMagnify / phase / magnification) applies
    // verbatim. eventWithCGEvent: reports the magnify subtype as type Magnify;
    // rotate/swipe gestures yield other types and are intentionally ignored.
    NSEvent* event = [NSEvent eventWithCGEvent:cgEvent];
    if (event && event.type == NSEventTypeMagnify) spdf_route_tapped_magnify_event(event);
    else if (event && spdf_zoom_profile_enabled())
        spdf_zoom_profile_log(@"inactiveMagnify gesture nsType=%lu (not magnify; ignored)",
                              (unsigned long)event.type);

    // Listen-only tap: never consume or modify; the event continues to its
    // normal destination, so focused pinch and all other gestures are untouched.
    return cgEvent;
}

BOOL spdf_inactive_magnify_tap_authorized(void) {
    // The tap uses kCGEventTapOptionDefault, which is gated by ACCESSIBILITY (not
    // Input Monitoring). AXIsProcessTrusted reflects exactly that grant. Query
    // without the prompting option so this is a silent check.
    return AXIsProcessTrusted() ? YES : NO;
}

SPDFMagnifyTapResult spdf_install_inactive_magnify_tap(void) {
    static BOOL armed = NO;
    if (armed) return SPDFMagnifyTapResultArmed;  // main-thread only; arm at most once per launch

    // type 29 = kCGEventGesture / NSEventTypeGesture, the umbrella HID gesture
    // event that carries magnify. Trackpad gesture events are LOW-LEVEL HID
    // events: they are observable at kCGHIDEventTap, not at the session tap
    // (where they have already been dispatched into the focused app's stream).
    // PinchBar, the canonical pinch-tapping app, uses cghidEventTap + defaultTap
    // for exactly this reason. defaultTap is gated by Accessibility (listenOnly
    // would be Input Monitoring, which does NOT authorize an HID gesture tap).
    CGEventMask mask = CGEventMaskBit(kSPDFGestureEventType) | CGEventMaskBit(kCGEventScrollWheel);

    // When profiling, widen the mask to ALL events for a brief diagnostic window
    // so one manual pinch reveals which CGEventType magnify really is on this OS.
    if (spdf_zoom_profile_enabled()) {
        mask = kCGEventMaskForAllEvents;
        gSPDFMagnifyTapDiagnosticUntil = NSDate.timeIntervalSinceReferenceDate + 8.0;
    }

    CFMachPortRef port = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask,
                                          spdf_inactive_magnify_tap_callback, NULL);
    if (!port) {
        // Accessibility not granted (or tap creation otherwise refused). Degrade
        // silently: the legacy global NSEvent monitor remains in place and the
        // feature is simply inactive. The opt-in flow guides the user to grant
        // Accessibility; do NOT prompt aggressively from here.
        gSPDFMagnifyTapDiagnosticUntil = 0.0;
        BOOL trusted = spdf_inactive_magnify_tap_authorized();
        if (spdf_zoom_profile_enabled())
            spdf_zoom_profile_log(@"inactiveMagnify tap create FAILED (HID/defaultTap); AXIsProcessTrusted=%d; "
                                  @"%@ — falling back to global monitor",
                                  trusted, trusted ? @"unexpected (signing/sandbox?)" : @"Accessibility not granted");
        return trusted ? SPDFMagnifyTapResultCreateFailed : SPDFMagnifyTapResultNoPermission;
    }

    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0);
    if (!source) {
        CFMachPortInvalidate(port);
        CFRelease(port);
        gSPDFMagnifyTapDiagnosticUntil = 0.0;
        if (spdf_zoom_profile_enabled()) spdf_zoom_profile_log(@"inactiveMagnify tap source creation failed");
        return SPDFMagnifyTapResultCreateFailed;
    }

    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CGEventTapEnable(port, true);
    // A non-nil tap is not necessarily a healthy tap (re-signed/relaunched dev
    // builds can install an inert tap). Verify it is actually enabled.
    BOOL enabled = CGEventTapIsEnabled(port) ? YES : NO;
    gSPDFMagnifyTapPort = port;
    gSPDFMagnifyTapSource = source;
    gSPDFMagnifyTapActive = YES;
    armed = YES;
    if (spdf_zoom_profile_enabled())
        spdf_zoom_profile_log(@"inactiveMagnify tap ARMED tap=HID place=headInsert option=defaultTap "
                              @"mask=%@ enabled=%d AXIsProcessTrusted=%d%@",
                              (mask == kCGEventMaskForAllEvents) ? @"ALL(diag)" : @"gesture(29)+scroll(22)", enabled,
                              spdf_inactive_magnify_tap_authorized(),
                              (mask == kCGEventMaskForAllEvents) ? @" [diag window 8s: pinch now]" : @"");
    return enabled ? SPDFMagnifyTapResultArmed : SPDFMagnifyTapResultInert;
}

void spdf_teardown_inactive_magnify_tap(void) {
    gSPDFMagnifyTapActive = NO;
    if (gSPDFMagnifyTapSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), gSPDFMagnifyTapSource, kCFRunLoopCommonModes);
        CFRelease(gSPDFMagnifyTapSource);
        gSPDFMagnifyTapSource = NULL;
    }
    if (gSPDFMagnifyTapPort) {
        CGEventTapEnable(gSPDFMagnifyTapPort, false);
        CFMachPortInvalidate(gSPDFMagnifyTapPort);
        CFRelease(gSPDFMagnifyTapPort);
        gSPDFMagnifyTapPort = NULL;
    }
}

static void spdf_install_inactive_magnify_monitor(void) {
    static dispatch_once_t onceToken;
    static id spdf_global_magnify_monitor = nil;
    static id spdf_local_magnify_monitor = nil;
    dispatch_once(&onceToken, ^{
      // Another app is active: its event stream receives the pinch, so the magnify events are only observable
      // through a global monitor (global monitors never see events delivered to this app). These events carry
      // cumulative magnification, so they are converted to per-event deltas before routing. When this app is
      // active its own event stream (local monitor / responder chain) is authoritative and the global
      // observation is ignored, so no event can ever be applied through two paths.
      spdf_global_magnify_monitor = [NSEvent
          addGlobalMonitorForEventsMatchingMask:NSEventMaskMagnify
                                        handler:^(NSEvent* event) {
                                          // The CGEventTap, once armed, is the authoritative inactive path;
                                          // standing down here keeps a single physical pinch from being applied
                                          // twice. In practice global monitors do not observe gesture/magnify
                                          // events delivered to other apps, so this handler is usually silent —
                                          // it remains only as the fallback when Accessibility is not granted.
                                          if (gSPDFMagnifyTapActive) return;
                                          if (NSApp.active) return;
                                          NSPoint screenPoint = NSEvent.mouseLocation;
                                          SPDFWindow* window = spdf_magnify_window_under_screen_point(screenPoint);
                                          if (!window || window.keyWindow) return;
                                          CGFloat delta = spdf_normalized_magnify_delta(event);
                                          if (spdf_zoom_profile_enabled()) {
                                              spdf_zoom_profile_log(@"inactiveMagnify path=global phase=%lu raw=%.4f "
                                                                    @"delta=%.4f",
                                                                    (unsigned long)event.phase,
                                                                    (double)event.magnification, (double)delta);
                                          }
                                          if (delta == 0.0) return;
                                          [window routeInactiveMagnifyEvent:event
                                                                screenPoint:screenPoint
                                                              magnification:delta];
                                        }];
      // This app is active: AppKit routes magnify events to the key window even when the cursor hovers another
      // ShenzhenPDF window, so reroute them to the window under the cursor and swallow the event. When the
      // cursor is over the key window itself the event is returned unchanged so the regular responder-chain
      // magnifyWithEvent: path handles it exactly once. These are first-class AppKit events whose
      // magnification is already a per-event delta.
      spdf_local_magnify_monitor = [NSEvent
          addLocalMonitorForEventsMatchingMask:NSEventMaskMagnify
                                       handler:^NSEvent*(NSEvent* event) {
                                         NSPoint screenPoint = NSEvent.mouseLocation;
                                         if (spdf_point_in_key_spdf_window(screenPoint)) return event;
                                         SPDFWindow* window = spdf_magnify_window_under_screen_point(screenPoint);
                                         if (!window || window.keyWindow) return event;
                                         CGFloat delta = spdf_normalized_magnify_delta(event);
                                         if (spdf_zoom_profile_enabled()) {
                                             spdf_zoom_profile_log(
                                                 @"inactiveMagnify path=local phase=%lu raw=%.4f delta=%.4f",
                                                 (unsigned long)event.phase, (double)event.magnification,
                                                 (double)delta);
                                         }
                                         if (delta == 0.0) return nil;
                                         if ([window routeInactiveMagnifyEvent:event
                                                                   screenPoint:screenPoint
                                                                 magnification:delta])
                                             return nil;
                                         return event;
                                       }];
      (void)spdf_global_magnify_monitor;
      (void)spdf_local_magnify_monitor;
    });
}

// The document scroll view or minimap under `windowPoint`, found through the
// content view's own hit test so an unfocused zoom lands on exactly the view
// AppKit would have delivered to. nil when the point is over window chrome.
static NSView* spdf_inactive_zoom_target_view(NSWindow* window, NSPoint windowPoint) {
    NSView* contentView = window.contentView;
    if (!contentView) return nil;
    // hitTest: expects the point in the receiver's superview coordinate space.
    NSView* hitReference = contentView.superview ?: contentView;
    NSView* hitView = [contentView hitTest:[hitReference convertPoint:windowPoint fromView:nil]];
    Class minimapClass = NSClassFromString(@"SPDFMinimapView");
    for (NSView* view = hitView; view; view = view.superview) {
        if ([view isKindOfClass:SPDFScrollView.class]) return view;
        if (minimapClass && [view isKindOfClass:minimapClass]) return view;
    }
    return nil;
}

// The reader behind a minimap hit, plus the document point the minimap position
// stands for, so an unfocused zoom over the minimap zooms the page it points
// at. nil when `view` is not a minimap or the minimap has no layout yet.
static id<SPDFMacUIReader> spdf_inactive_zoom_minimap_reader(NSView* view, NSPoint windowPoint,
                                                             NSPoint* documentPointOut) {
    SEL documentPointSelector = @selector(documentPointForMinimapCenterPoint:scale:gap:contentHeight:contentTop:);
    if (![view respondsToSelector:@selector(layoutScale:gap:contentTop:contentHeight:visibleRect:)] ||
        ![view respondsToSelector:documentPointSelector])
        return nil;

    CGFloat scale = 1.0;
    CGFloat gap = 4.0;
    CGFloat contentTop = 8.0;
    CGFloat contentHeight = 0.0;
    if (![view layoutScale:&scale gap:&gap contentTop:&contentTop contentHeight:&contentHeight visibleRect:NULL])
        return nil;

    *documentPointOut = [view documentPointForMinimapCenterPoint:[view convertPoint:windowPoint fromView:nil]
                                                           scale:scale
                                                             gap:gap
                                                   contentHeight:contentHeight
                                                      contentTop:contentTop];
    return [view valueForKey:@"reader"];
}

void spdf_inactive_zoom_register_window(SPDFWindow* window) {
    spdf_install_inactive_magnify_monitor();
    [spdf_inactive_magnify_windows() addObject:window];
}

void spdf_inactive_zoom_forget_window(SPDFWindow* window) {
    [spdf_inactive_magnify_windows() removeObject:window];
}

BOOL spdf_inactive_zoom_wheel_already_applied(NSEvent* event) {
    return spdf_zoom_wheel_handled_by_tap(gSPDFMagnifyTapActive, NSApp.active, event.timestamp,
                                          gSPDFTapZoomWheelEventTimestamp,
                                          NSProcessInfo.processInfo.systemUptime - gSPDFTapZoomWheelAppliedUptime);
}

@implementation SPDFWindow (SPDFInactiveZoomRouting)

- (BOOL)routeInactiveMagnifyEvent:(NSEvent*)event windowPoint:(NSPoint)windowPoint magnification:(CGFloat)magnification {
    if (event.type != NSEventTypeMagnify || self.keyWindow || !self.visible || self.miniaturized) return NO;

    // Defensive: a genuine pinch never produces per-event deltas anywhere near this large, so anything
    // bigger is a misdecoded monitor event; swallow it instead of slamming the zoom.
    if (fabs(magnification) > 0.5) {
        if (spdf_zoom_profile_enabled())
            spdf_zoom_profile_log(@"inactiveMagnify dropped out-of-range delta=%.4f", (double)magnification);
        return YES;
    }

    NSView* target = spdf_inactive_zoom_target_view(self, windowPoint);
    if ([target isKindOfClass:SPDFScrollView.class]) {
        [(SPDFScrollView*)target spdf_magnifyWithEvent:event
                                         magnification:magnification
                                 centeredAtWindowPoint:windowPoint];
        return YES;
    }
    NSPoint documentPoint = NSZeroPoint;
    id<SPDFMacUIReader> reader = spdf_inactive_zoom_minimap_reader(target, windowPoint, &documentPoint);
    if (!reader) return NO;
    [reader minimapViewDidReceiveMagnifyDelta:magnification documentPoint:documentPoint];
    return YES;
}

// The zoom wheel counterpart of the magnify router above: same hit test, same
// two destinations, but the scroll event is handed on whole so the focused and
// unfocused wheel zooms share one conversion from wheel delta to zoom factor.
- (BOOL)routeInactiveZoomWheelEvent:(NSEvent*)event screenPoint:(NSPoint)screenPoint {
    if (event.type != NSEventTypeScrollWheel || self.keyWindow || !self.visible || self.miniaturized) return NO;
    if (!NSPointInRect(screenPoint, self.frame)) return NO;

    NSPoint windowPoint = [self convertPointFromScreen:screenPoint];
    NSView* target = spdf_inactive_zoom_target_view(self, windowPoint);
    if ([target isKindOfClass:SPDFScrollView.class])
        return [(SPDFScrollView*)target spdf_zoomWithScrollWheelEvent:event centeredAtWindowPoint:windowPoint];
    NSPoint documentPoint = NSZeroPoint;
    id<SPDFMacUIReader> reader = spdf_inactive_zoom_minimap_reader(target, windowPoint, &documentPoint);
    if (!reader) return NO;
    [reader minimapViewDidReceiveZoomScrollWheel:event documentPoint:documentPoint];
    return YES;
}

- (BOOL)routeInactiveMagnifyEvent:(NSEvent*)event screenPoint:(NSPoint)screenPoint magnification:(CGFloat)magnification {
    if (event.type != NSEventTypeMagnify || self.keyWindow || !self.visible || self.miniaturized) return NO;
    if (!NSPointInRect(screenPoint, self.frame)) return NO;
    return [self routeInactiveMagnifyEvent:event
                               windowPoint:[self convertPointFromScreen:screenPoint]
                             magnification:magnification];
}

- (BOOL)routeInactiveMagnifyEvent:(NSEvent*)event {
    if (event.type != NSEventTypeMagnify || self.keyWindow) return NO;
    // When the CGEventTap is armed it is the single authoritative inactive path;
    // if AppKit ALSO happens to deliver the same physical pinch to this window's
    // own event stream (scroll-focus delivery), routing it here too would
    // double-apply. Let it fall through to super (the tap already handled it).
    if (gSPDFMagnifyTapActive) return NO;
    // Magnify events AppKit dispatches to an inactive window under the cursor
    // (scroll-focus delivery) are rebuilt raw from gesture CGEvents: phase-less
    // with CUMULATIVE magnification. spdf_normalized_magnify_delta converts
    // those to per-event deltas and passes phased gesture-session events as-is.
    CGFloat delta = spdf_normalized_magnify_delta(event);
    if (spdf_zoom_profile_enabled()) {
        spdf_zoom_profile_log(@"inactiveMagnify path=sendEvent phase=%lu raw=%.4f delta=%.4f",
                              (unsigned long)event.phase, (double)event.magnification, (double)delta);
    }
    if (delta == 0.0) return YES;
    return [self routeInactiveMagnifyEvent:event windowPoint:event.locationInWindow magnification:delta];
}

@end
