#import <Cocoa/Cocoa.h>

// Option + scroll wheel steps whole pages, wherever the pointer happens to be
// -- the document, the minimap, the sidebar, the toolbar. It is the wheel
// equivalent of the page arrows: the delegate's -nextPage:/-previousPage: do
// the work, so a fitted page simply advances, a zoomed page lands on the next
// page at the same zoom and relative position, and Markdown pages too.
//
// Routed from SPDFWindow -sendEvent: rather than from a view's -scrollWheel:,
// because a view only sees the wheel while the pointer is over it.

// One wheel gesture's accumulated state. A window per process, so one instance.
typedef struct {
    double accumulator;
    int direction;  // -1 up/back, +1 down/forward, 0 none yet
    double lastEventTimestamp;
    double lastTurnTimestamp;
    bool turnedInGesture;
    bool gestureActive;
} spdf_page_wheel_state;

// How many pages this wheel event should turn: positive forward, negative
// back, 0 not yet. It is a COUNT, not a flag, so scrolling fast keeps up
// instead of dropping notches.
//
// Distance-based rather than one-page-per-gesture: a scroll driver that
// smooths the wheel (LinearMouse, and macOS itself for some mice) sends a
// burst of small PRECISE deltas per notch, which is indistinguishable from a
// trackpad flick -- so "one page per gesture" turned a fast spin of the wheel
// into a single page. Each threshold's worth of travel turns one page and is
// SUBTRACTED from the accumulator, so the pages keep pace with the wheel and
// nothing is lost between events. Momentum is still ignored, so a flick's tail
// cannot run away through the document.
int spdf_page_wheel_step(spdf_page_wheel_state* state, double deltaY, bool preciseDeltas, bool phaseBegan,
                         bool phaseEnded, bool momentum, double timestamp);

// True when these modifiers mean "page", i.e. Option without Command or
// Control (those already mean zoom).
bool spdf_page_wheel_modifiers_page(NSEventModifierFlags flags);

// Handle a window's scroll event. Returns YES when the event was consumed --
// including the events that only accumulate, so Option + wheel never also
// scrolls the thing under the pointer.
BOOL spdf_page_wheel_handle_window_scroll(NSWindow* window, NSEvent* event);
