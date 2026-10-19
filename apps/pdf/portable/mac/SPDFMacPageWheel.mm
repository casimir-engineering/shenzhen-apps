#import "SPDFMacPageWheel.h"

#import "SPDFMacUIHelpers.h"  // the reader protocol this routes to

// One notch of a smoothed wheel measured ~14.5 points of scrollingDeltaY on a
// LinearMouse setup, so a ~14pt threshold turns about one page per notch and
// two notches turn two. A raw (unsmoothed) wheel reports whole lines instead,
// where one line is one notch.
static const double kPrecisePointsPerPage = 14.0;
static const double kDiscreteLinesPerPage = 1.0;
// A pause means the reader stopped and started again; drop any part-page of
// travel so a new spin begins cleanly rather than paging early.
static const double kGestureIdleReset = 0.35;
// A single enormous delta (a hard trackpad flick) should not teleport through
// the document.
static const int kMaxPagesPerEvent = 4;

bool spdf_page_wheel_modifiers_page(NSEventModifierFlags flags) {
    NSEventModifierFlags relevant = flags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (!(relevant & NSEventModifierFlagOption)) return false;
    // Command and Control already mean zoom; leave those alone.
    return !(relevant & (NSEventModifierFlagCommand | NSEventModifierFlagControl));
}

static void spdf_page_wheel_reset(spdf_page_wheel_state* state) {
    state->accumulator = 0.0;
    state->direction = 0;
    state->turnedInGesture = false;
    state->gestureActive = false;
}

int spdf_page_wheel_step(spdf_page_wheel_state* state, double deltaY, bool preciseDeltas, bool phaseBegan,
                         bool phaseEnded, bool momentum, double timestamp) {
    if (!state) return 0;
    if (phaseBegan) spdf_page_wheel_reset(state);
    // Momentum is the tail of a flick, not the reader asking for more pages.
    if (momentum || phaseEnded) {
        spdf_page_wheel_reset(state);
        state->lastEventTimestamp = timestamp;
        return 0;
    }
    if (state->lastEventTimestamp > 0.0 && timestamp - state->lastEventTimestamp > kGestureIdleReset)
        spdf_page_wheel_reset(state);
    if (fabs(deltaY) < 0.0001) {
        state->lastEventTimestamp = timestamp;
        return 0;
    }
    int direction = deltaY < 0 ? -1 : 1;
    if (state->direction != 0 && direction != state->direction) {
        state->accumulator = 0.0;
        state->turnedInGesture = false;
    }
    state->direction = direction;
    state->gestureActive = true;
    state->accumulator += deltaY;
    state->lastEventTimestamp = timestamp;
    double threshold = preciseDeltas ? kPrecisePointsPerPage : kDiscreteLinesPerPage;
    if (fabs(state->accumulator) < threshold) return 0;
    // Scrolling forward (negative delta, the direction that advances the
    // document) goes to the next page, matching the presentation-mode paging.
    int forward = state->accumulator < 0 ? 1 : -1;
    int pages = (int)(fabs(state->accumulator) / threshold);
    if (pages > kMaxPagesPerEvent) pages = kMaxPagesPerEvent;
    // Keep the remainder: at speed the leftover travel belongs to the next page,
    // which is what stops fast scrolling from losing notches.
    // Drain the pages just turned, keeping the sign: forward is +1 when the
    // accumulator is negative, so ADDING forward*pages*threshold moves it back
    // toward zero. (Subtracting instead grew it, which mis-paged everything
    // after the first event.)
    state->accumulator += (double)pages * threshold * (double)forward;
    state->turnedInGesture = true;
    state->lastTurnTimestamp = timestamp;
    return pages * forward;
}

BOOL spdf_page_wheel_handle_window_scroll(NSWindow* window, NSEvent* event) {
    if (!window || event.type != NSEventTypeScrollWheel) return NO;
    if (!spdf_page_wheel_modifiers_page(event.modifierFlags)) return NO;
    id reader = [window respondsToSelector:@selector(reader)] ? [(id)window reader] : nil;
    if (![reader respondsToSelector:@selector(nextPage:)]) return NO;

    // One window per process, so the gesture state can live here.
    static spdf_page_wheel_state state;
    BOOL phaseBegan = (event.phase & (NSEventPhaseBegan | NSEventPhaseMayBegin)) != 0;
    BOOL phaseEnded = (event.phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) != 0;
    double delta = event.scrollingDeltaY != 0.0 ? event.scrollingDeltaY : event.deltaY;
    int step = spdf_page_wheel_step(&state, delta, event.hasPreciseScrollingDeltas, phaseBegan, phaseEnded,
                                    event.momentumPhase != NSEventPhaseNone, event.timestamp);
    // step is a COUNT: a fast spin earns several pages and must get them all.
    for (int i = 0; i < step; ++i) [reader nextPage:nil];
    for (int i = 0; i > step; --i) [reader previousPage:nil];
    // Consumed either way: an Option + wheel event must never also scroll
    // whatever the pointer happens to be over.
    return YES;
}
