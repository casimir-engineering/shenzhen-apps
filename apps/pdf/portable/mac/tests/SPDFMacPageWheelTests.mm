// Option + wheel = the page arrows. The rules that matter are the gesture
// rules: a mouse notch turns exactly one page, a trackpad flick turns exactly
// one page however long the flick, momentum never turns any, and the modifier
// must not collide with the zoom gestures.

#import <Cocoa/Cocoa.h>

#import "SPDFMacPageWheel.h"

static int gFailures;

// The routing only needs -reader from the window and the two page selectors
// from it; standing in for them keeps this a unit test.
@interface SPDFPageWheelRecorder : NSObject {
@public
    int steps;
    BOOL lastWasNext;
}
@end
@implementation SPDFPageWheelRecorder
- (void)nextPage:(id)sender {
    (void)sender;
    ++steps;
    lastWasNext = YES;
}
- (void)previousPage:(id)sender {
    (void)sender;
    ++steps;
    lastWasNext = NO;
}
@end

@interface SPDFPageWheelFakeWindow : NSObject
@property(nonatomic, strong) SPDFPageWheelRecorder* recorder;
- (id)reader;
@end
@implementation SPDFPageWheelFakeWindow
- (id)reader {
    return self.recorder;
}
@end

static void Expect(const char* what, BOOL condition) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", what);
    ++gFailures;
}

// deltaY < 0 is the direction that advances the document.
static const double kForward = -1.0;
static const double kBack = 1.0;

int main(void) {
    @autoreleasepool {
        // --- Which modifiers mean "page" -------------------------------
        Expect("option alone pages", spdf_page_wheel_modifiers_page(NSEventModifierFlagOption));
        Expect("no modifier does not page", !spdf_page_wheel_modifiers_page(0));
        // Command and Control already mean zoom; stealing them would break it.
        Expect("option+command does not page",
               !spdf_page_wheel_modifiers_page(NSEventModifierFlagOption | NSEventModifierFlagCommand));
        Expect("option+control does not page",
               !spdf_page_wheel_modifiers_page(NSEventModifierFlagOption | NSEventModifierFlagControl));
        Expect("command alone does not page", !spdf_page_wheel_modifiers_page(NSEventModifierFlagCommand));
        // Shift is not a zoom modifier, so it may ride along.
        Expect("option+shift still pages",
               spdf_page_wheel_modifiers_page(NSEventModifierFlagOption | NSEventModifierFlagShift));

        // --- A raw wheel: one line is one notch is one page --------------
        {
            spdf_page_wheel_state state = {};
            Expect("a notch forward turns to the next page",
                   spdf_page_wheel_step(&state, kForward, false, false, false, false, 1.00) == 1);
            Expect("the next notch turns another page",
                   spdf_page_wheel_step(&state, kForward, false, false, false, false, 1.05) == 1);
            Expect("a notch the other way goes back a page",
                   spdf_page_wheel_step(&state, kBack, false, false, false, false, 1.10) == -1);
        }

        // --- A smoothed wheel: pages keep pace with the wheel -----------
        // The defect this pins: a scroll driver that smooths the wheel sends a
        // burst of small PRECISE deltas per notch, which looked exactly like one
        // trackpad flick -- so spinning the wheel fast turned a single page and
        // "missed most events". Travel decides now, so N notches turn N pages.
        {
            spdf_page_wheel_state state = {};
            int pages = 0;
            // Three notches, ~14.5pt each, delivered as four smoothed deltas.
            for (int notch = 0; notch < 3; ++notch) {
                double burst[4] = {1.1, 2.0, 5.0, 6.4};
                for (int i = 0; i < 4; ++i)
                    pages += spdf_page_wheel_step(&state, -burst[i], true, false, false, false,
                                                  10.0 + notch * 0.10 + i * 0.02);
            }
            Expect("three notches of a smoothed wheel turn three pages", pages == 3);
        }

        // --- A trackpad flick pages by how far it travelled ------------
        {
            spdf_page_wheel_state state = {};
            int turns = 0;
            // A flick is one Began plus a tail of precise deltas: ~36pt here.
            turns += spdf_page_wheel_step(&state, kForward * 0.4, true, true, false, false, 10.0);
            for (int i = 1; i < 25; ++i)
                turns += spdf_page_wheel_step(&state, kForward * 1.5, true, false, false, false, 10.0 + i * 0.01);
            // 0.4 + 24*1.5 = 36.4pt over a 14pt page = 2 pages, not 1: paging
            // now follows the wheel rather than capping at one per gesture.
            Expect("a flick turns a page per threshold of travel", turns == 2);
            // Momentum is the tail of that flick, not a request for more.
            int momentum = 0;
            for (int i = 0; i < 20; ++i) {
                if (spdf_page_wheel_step(&state, kForward * 3.0, true, false, false, true, 10.3 + i * 0.01)) ++momentum;
            }
            Expect("momentum turns no pages", momentum == 0);
            // A fresh gesture starts from zero travel, so a small nudge alone
            // is not yet a page.
            Expect("a fresh small nudge is not yet a page",
                   spdf_page_wheel_step(&state, kForward * 2.0, true, true, false, false, 12.0) == 0);
            Expect("...and it pages once the travel adds up",
                   spdf_page_wheel_step(&state, kForward * 13.0, true, false, false, false, 12.02) == 1);
        }

        // --- Reversing mid-gesture ------------------------------------
        {
            spdf_page_wheel_state state = {};
            spdf_page_wheel_step(&state, kForward * 3.0, true, true, false, false, 20.0);
            // Reversing discards the abandoned direction's travel, then pages
            // the way the wheel now turns.
            Expect("a reversal does not fire the abandoned direction",
                   spdf_page_wheel_step(&state, kBack * 2.0, true, false, false, false, 20.05) == 0);
            Expect("reversing pages the way the wheel now turns",
                   spdf_page_wheel_step(&state, kBack * 13.0, true, false, false, false, 20.07) == -1);
        }

        // --- A pause drops the part-page of travel ---------------------
        {
            spdf_page_wheel_state state = {};
            Expect("a half-page of travel is not a page",
                   spdf_page_wheel_step(&state, kForward * 10.0, true, true, false, false, 30.0) == 0);
            // After an idle gap that leftover travel is gone, so the same nudge
            // again does not suddenly page.
            Expect("a pause drops the leftover travel",
                   spdf_page_wheel_step(&state, kForward * 10.0, true, false, false, false, 31.0) == 0);
        }

        // --- A single huge delta cannot teleport -----------------------
        {
            spdf_page_wheel_state state = {};
            int pages = spdf_page_wheel_step(&state, kForward * 1000.0, true, true, false, false, 50.0);
            Expect("one enormous delta is capped", pages > 0 && pages <= 4);
        }

        // --- Degenerate input -----------------------------------------
        {
            spdf_page_wheel_state state = {};
            Expect("a zero delta does nothing", spdf_page_wheel_step(&state, 0.0, true, false, false, false, 40.0) == 0);
            Expect("a null state is safe", spdf_page_wheel_step(NULL, kForward, false, false, false, false, 41.0) == 0);
        }

        // --- The routing, not just the policy -------------------------
        // The policy above is pure; this checks the window entry point really
        // turns an Option + wheel NSEvent into a page-arrow call, and leaves
        // every other scroll alone. Events are CONSTRUCTED, not posted: posting
        // needs Input Monitoring permission the test process does not have.
        {
            CGEventRef scroll = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, -1);
            CGEventSetFlags(scroll, kCGEventFlagMaskAlternate);
            NSEvent* optionWheel = [NSEvent eventWithCGEvent:scroll];
            CGEventSetFlags(scroll, 0);
            NSEvent* plainWheel = [NSEvent eventWithCGEvent:scroll];
            CGEventSetFlags(scroll, kCGEventFlagMaskCommand);
            NSEvent* commandWheel = [NSEvent eventWithCGEvent:scroll];
            CFRelease(scroll);
            Expect("an option wheel event is built", optionWheel != nil);

            SPDFPageWheelRecorder* recorder = [SPDFPageWheelRecorder new];
            SPDFPageWheelFakeWindow* window = [SPDFPageWheelFakeWindow new];
            window.recorder = recorder;

            Expect("a plain wheel event is left to scroll",
                   !spdf_page_wheel_handle_window_scroll((NSWindow*)window, plainWheel) && recorder->steps == 0);
            Expect("a command wheel event is left to the zoom path",
                   !spdf_page_wheel_handle_window_scroll((NSWindow*)window, commandWheel) && recorder->steps == 0);
            BOOL consumed = spdf_page_wheel_handle_window_scroll((NSWindow*)window, optionWheel);
            Expect("an option wheel event is consumed", consumed);
            Expect("...and asks the reader for a page", recorder->steps == 1);
            Expect("...forward, because the wheel turned forward", recorder->lastWasNext);
        }

        if (gFailures == 0) fprintf(stderr, "SPDFMacPageWheelTests passed\n");
    }
    return gFailures == 0 ? 0 : 1;
}
