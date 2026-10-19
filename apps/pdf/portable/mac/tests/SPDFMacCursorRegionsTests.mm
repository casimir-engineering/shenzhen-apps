#import <Foundation/Foundation.h>

#import "../SPDFMacCursorRegions.h"

static int gFailureCount = 0;

static void expect_region(NSString* label, SPDFCursorRegionKind expected, NSPoint point,
                          NSArray<NSValue*>* linkRects, NSArray<NSValue*>* textRects, CGFloat linkPadding) {
    SPDFCursorRegionKind actual = spdf_cursor_region_at_point(point, linkRects, textRects, linkPadding);
    if (actual != expected) {
        fprintf(stderr, "FAIL %s: expected %ld, got %ld\n", label.UTF8String, (long)expected, (long)actual);
        ++gFailureCount;
    }
}

static void expect_bool(NSString* label, BOOL expected, BOOL actual) {
    if (actual != expected) {
        fprintf(stderr, "FAIL %s: expected %s, got %s\n", label.UTF8String, expected ? "YES" : "NO",
                actual ? "YES" : "NO");
        ++gFailureCount;
    }
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSArray<NSValue*>* links = @[ [NSValue valueWithRect:NSMakeRect(100, 100, 80, 12)] ];
        NSArray<NSValue*>* text = @[
            [NSValue valueWithRect:NSMakeRect(50, 50, 300, 14)],
            [NSValue valueWithRect:NSMakeRect(50, 98, 300, 16)]  // overlaps the link line
        ];

        // Region resolution: none / text / link, link priority, padding.
        expect_region(@"empty caches resolve to none", SPDFCursorRegionNone, NSMakePoint(10, 10), @[], @[], 2.0);
        expect_region(@"gutter point resolves to none", SPDFCursorRegionNone, NSMakePoint(400, 400), links, text, 2.0);
        expect_region(@"text-only point resolves to text", SPDFCursorRegionText, NSMakePoint(60, 55), links, text, 2.0);
        expect_region(@"link wins over overlapping text", SPDFCursorRegionLink, NSMakePoint(120, 105), links, text,
                      2.0);
        expect_region(@"link padding extends the hit target", SPDFCursorRegionLink, NSMakePoint(181.5, 106), links,
                      text, 2.0);
        expect_region(@"point outside padded link is text (overlapping line)", SPDFCursorRegionText,
                      NSMakePoint(183, 106), links, text, 2.0);
        expect_region(@"nil caches resolve to none", SPDFCursorRegionNone, NSMakePoint(120, 105), nil, nil, 2.0);

        // Click vs drag-select: plain click activates.
        {
            SPDFLinkClickGesture gesture = spdf_link_click_gesture_begin(NSMakePoint(120, 105));
            expect_bool(@"press-release with no movement is a click", YES,
                        spdf_link_click_gesture_activates_on_release(&gesture));
        }

        // Jitter within the threshold still activates.
        {
            SPDFLinkClickGesture gesture = spdf_link_click_gesture_begin(NSMakePoint(120, 105));
            spdf_link_click_gesture_drag(&gesture, NSMakePoint(121, 106), NO);
            spdf_link_click_gesture_drag(&gesture, NSMakePoint(119, 104), NO);
            expect_bool(@"sub-threshold jitter is still a click", YES,
                        spdf_link_click_gesture_activates_on_release(&gesture));
        }

        // Drag beyond the threshold is a selection gesture.
        {
            SPDFLinkClickGesture gesture = spdf_link_click_gesture_begin(NSMakePoint(120, 105));
            spdf_link_click_gesture_drag(&gesture, NSMakePoint(140, 105), NO);
            expect_bool(@"drag beyond threshold does not activate", NO,
                        spdf_link_click_gesture_activates_on_release(&gesture));
        }

        // Drag out and back to the press point must still count as a drag.
        {
            SPDFLinkClickGesture gesture = spdf_link_click_gesture_begin(NSMakePoint(120, 105));
            spdf_link_click_gesture_drag(&gesture, NSMakePoint(160, 110), NO);
            spdf_link_click_gesture_drag(&gesture, NSMakePoint(120, 105), NO);
            expect_bool(@"drag returning to press point stays a drag", NO,
                        spdf_link_click_gesture_activates_on_release(&gesture));
        }

        // A selection created by the drag blocks activation even within the threshold.
        {
            SPDFLinkClickGesture gesture = spdf_link_click_gesture_begin(NSMakePoint(120, 105));
            spdf_link_click_gesture_drag(&gesture, NSMakePoint(122, 105), YES);
            expect_bool(@"created selection blocks activation", NO,
                        spdf_link_click_gesture_activates_on_release(&gesture));
        }

        // Selection flag is sticky even if later drags report no selection.
        {
            SPDFLinkClickGesture gesture = spdf_link_click_gesture_begin(NSMakePoint(120, 105));
            spdf_link_click_gesture_drag(&gesture, NSMakePoint(122, 105), YES);
            spdf_link_click_gesture_drag(&gesture, NSMakePoint(120, 105), NO);
            expect_bool(@"selection flag is sticky", NO, spdf_link_click_gesture_activates_on_release(&gesture));
        }

        // An inactive (never begun) gesture never activates.
        {
            SPDFLinkClickGesture gesture = {};
            expect_bool(@"inactive gesture never activates", NO,
                        spdf_link_click_gesture_activates_on_release(&gesture));
            expect_bool(@"null gesture never activates", NO, spdf_link_click_gesture_activates_on_release(NULL));
            spdf_link_click_gesture_drag(NULL, NSMakePoint(0, 0), NO);  // must not crash
        }
    }

    if (gFailureCount > 0) {
        fprintf(stderr, "%d cursor region test(s) failed\n", gFailureCount);
        return 1;
    }
    printf("All cursor region tests passed\n");
    return 0;
}
