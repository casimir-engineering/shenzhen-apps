#import <Foundation/Foundation.h>

#include <math.h>

#import "../SPDFMacTabStripGeometry.h"

static int gFailureCount = 0;

static void expect_slot(NSString* label, NSInteger expected, CGFloat x, const CGFloat* midXs, NSInteger visibleCount) {
    NSInteger actual = spdf_tab_strip_drop_slot_for_x(x, midXs, visibleCount);
    if (actual != expected) {
        fprintf(stderr, "FAIL %s: expected %ld, got %ld\n", label.UTF8String, (long)expected, (long)actual);
        ++gFailureCount;
    }
}

static void expect_center_x(NSString* label,
                            CGFloat expected,
                            NSInteger slot,
                            const CGFloat* minXs,
                            const CGFloat* maxXs,
                            NSInteger visibleCount,
                            CGFloat tabGap) {
    CGFloat actual = spdf_tab_strip_drop_indicator_center_x(slot, minXs, maxXs, visibleCount, tabGap);
    if (fabs(actual - expected) > 0.001) {
        fprintf(stderr, "FAIL %s: expected %.3f, got %.3f\n", label.UTF8String, (double)expected, (double)actual);
        ++gFailureCount;
    }
}

static void expect_move_index(NSString* label,
                              NSInteger expected,
                              NSInteger insertionIndex,
                              NSInteger sourceIndex,
                              NSInteger tabCount) {
    NSInteger actual = spdf_tab_strip_same_window_move_index(insertionIndex, sourceIndex, tabCount);
    if (actual != expected) {
        fprintf(stderr, "FAIL %s: expected %ld, got %ld\n", label.UTF8String, (long)expected, (long)actual);
        ++gFailureCount;
    }
}

static void expect_center_nan(NSString* label,
                              NSInteger slot,
                              const CGFloat* minXs,
                              const CGFloat* maxXs,
                              NSInteger visibleCount,
                              CGFloat tabGap) {
    CGFloat actual = spdf_tab_strip_drop_indicator_center_x(slot, minXs, maxXs, visibleCount, tabGap);
    if (!isnan(actual)) {
        fprintf(stderr, "FAIL %s: expected NAN, got %.3f\n", label.UTF8String, (double)actual);
        ++gFailureCount;
    }
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        // Three tabs: [50..150], [170..270], [290..390], gap 20 -> mids 100/220/340.
        const CGFloat minXs[] = {50.0, 170.0, 290.0};
        const CGFloat maxXs[] = {150.0, 270.0, 390.0};
        const CGFloat midXs[] = {100.0, 220.0, 340.0};
        const CGFloat gap = 20.0;

        expect_slot(@"far left of first tab", 0, 0.0, midXs, 3);
        expect_slot(@"left half of first tab", 0, 99.0, midXs, 3);
        expect_slot(@"exactly at first mid goes right", 1, 100.0, midXs, 3);
        expect_slot(@"between first and second tab", 1, 160.0, midXs, 3);
        expect_slot(@"left half of second tab", 1, 219.0, midXs, 3);
        expect_slot(@"right half of second tab", 2, 230.0, midXs, 3);
        expect_slot(@"right half of last tab", 3, 341.0, midXs, 3);
        expect_slot(@"far right of last tab", 3, 10000.0, midXs, 3);
        expect_slot(@"no visible tabs", 0, 120.0, midXs, 0);
        expect_slot(@"nil geometry", 0, 120.0, NULL, 3);

        expect_center_x(@"slot 0 sits half a gap left of first tab", 40.0, 0, minXs, maxXs, 3, gap);
        expect_center_x(@"slot 1 centers the first gap", 160.0, 1, minXs, maxXs, 3, gap);
        expect_center_x(@"slot 2 centers the second gap", 280.0, 2, minXs, maxXs, 3, gap);
        expect_center_x(@"last slot sits half a gap right of last tab", 400.0, 3, minXs, maxXs, 3, gap);
        expect_center_x(@"single tab, before", 44.0, 0, minXs, maxXs, 1, 12.0);
        expect_center_x(@"single tab, after", 156.0, 1, minXs, maxXs, 1, 12.0);

        expect_center_nan(@"negative slot", -1, minXs, maxXs, 3, gap);
        expect_center_nan(@"slot past the end", 4, minXs, maxXs, 3, gap);
        expect_center_nan(@"no visible tabs", 0, minXs, maxXs, 0, gap);
        expect_center_nan(@"nil geometry", 1, NULL, NULL, 3, gap);

        // Same-window continuous drag: insertion index -> final move index once
        // the dragged tab's original slot is removed. Tabs A B C D (source B=1).
        expect_move_index(@"insert before first tab", 0, 0, 1, 4);
        expect_move_index(@"gap left of source is a no-op", 1, 1, 1, 4);
        expect_move_index(@"gap right of source is a no-op", 1, 2, 1, 4);
        expect_move_index(@"insert after next tab", 2, 3, 1, 4);
        expect_move_index(@"insert at the very end", 3, 4, 1, 4);
        expect_move_index(@"source at end, insert at start", 0, 0, 3, 4);
        expect_move_index(@"source at end, end gap is a no-op", 3, 4, 3, 4);
        expect_move_index(@"source at start, insert at end", 3, 4, 0, 4);
        expect_move_index(@"single tab always stays", 0, 1, 0, 1);
        expect_move_index(@"insertion index clamped high", 3, 99, 1, 4);
        expect_move_index(@"insertion index clamped low", 0, -5, 1, 4);
        expect_move_index(@"empty strip returns source", 2, 0, 2, 0);
        expect_move_index(@"source out of range returns source", 7, 0, 7, 4);

        // Indicator/drop consistency: the indicator for the slot chosen for a
        // cursor x must lie in the gap the tab will actually insert into.
        for (CGFloat x = 0.0; x <= 440.0; x += 1.0) {
            NSInteger slot = spdf_tab_strip_drop_slot_for_x(x, midXs, 3);
            CGFloat centerX = spdf_tab_strip_drop_indicator_center_x(slot, minXs, maxXs, 3, gap);
            CGFloat gapLeft = slot == 0 ? minXs[0] - gap : maxXs[slot - 1];
            CGFloat gapRight = slot == 3 ? maxXs[2] + gap : minXs[slot];
            if (isnan(centerX) || centerX < gapLeft || centerX > gapRight) {
                fprintf(stderr, "FAIL consistency at x=%.1f: slot %ld center %.3f outside gap [%.3f, %.3f]\n",
                        (double)x, (long)slot, (double)centerX, (double)gapLeft, (double)gapRight);
                ++gFailureCount;
                break;
            }
        }
    }
    if (gFailureCount > 0) return 1;
    printf("SPDFMacTabStripGeometryTests passed\n");
    return 0;
}
