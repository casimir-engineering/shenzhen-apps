#import <Cocoa/Cocoa.h>

#import "../SPDFMacFindNearest.h"

static int gFailureCount = 0;

static void expect_nearest(NSString* label,
                           NSInteger expected,
                           const NSInteger* pages,
                           const CGFloat* centers,
                           NSInteger count,
                           NSInteger firstVisiblePage,
                           NSInteger lastVisiblePage,
                           CGFloat viewportCenterY) {
    NSInteger actual =
        spdf_nearest_find_match_index(pages, centers, count, firstVisiblePage, lastVisiblePage, viewportCenterY);
    if (actual != expected) {
        fprintf(stderr, "FAIL %s: expected %ld, got %ld\n", label.UTF8String, (long)expected, (long)actual);
        ++gFailureCount;
    }
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        expect_nearest(@"no matches", -1, NULL, NULL, 0, 0, 0, 0.0);

        {
            NSInteger pages[] = {7};
            CGFloat centers[] = {7400.0};
            expect_nearest(@"single match wins regardless of distance", 0, pages, centers, 1, 0, 0, 100.0);
        }

        {
            // One match per page 0..9, page height 1000; viewport shows page 4.
            // The user note's "5 / 10" case: index 4 (the fifth match) wins even
            // though match #1 exists earlier in document order.
            NSInteger pages[] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9};
            CGFloat centers[] = {50.0, 1050.0, 2050.0, 3050.0, 4450.0, 5050.0, 6050.0, 7050.0, 8050.0, 9050.0};
            expect_nearest(@"match on the visible page wins", 4, pages, centers, 10, 4, 4, 4500.0);
        }

        {
            // No match on a visible page: page distance decides (page 5 is one
            // page below the visible range 3..4; page 0 is three pages above).
            NSInteger pages[] = {0, 5};
            CGFloat centers[] = {50.0, 5050.0};
            expect_nearest(@"smaller page distance wins", 1, pages, centers, 2, 3, 4, 3600.0);
        }

        {
            // Equal page distance (one page above vs one page below the visible
            // range): the vertical distance from the viewport center decides.
            NSInteger pages[] = {2, 6};
            CGFloat centers[] = {2950.0, 6050.0};
            expect_nearest(@"page-distance tie broken by vertical distance", 0, pages, centers, 2, 3, 5, 4200.0);
            expect_nearest(@"page-distance tie broken the other way", 1, pages, centers, 2, 3, 5, 4800.0);
        }

        {
            // Several matches on the same visible page: closest to the viewport
            // center wins, not the first on the page.
            NSInteger pages[] = {4, 4, 4};
            CGFloat centers[] = {4100.0, 4480.0, 4900.0};
            expect_nearest(@"closest match within the visible page wins", 1, pages, centers, 3, 4, 4, 4500.0);
        }

        {
            // Exact tie on both criteria keeps document order (lowest index).
            NSInteger pages[] = {4, 4};
            CGFloat centers[] = {4400.0, 4600.0};
            expect_nearest(@"exact tie keeps document order", 0, pages, centers, 2, 4, 4, 4500.0);
        }

        {
            // Multi-page viewport (zoomed out): every match on any visible page
            // has page distance 0 and competes on vertical distance only.
            NSInteger pages[] = {2, 3, 4, 8};
            CGFloat centers[] = {2100.0, 3900.0, 4050.0, 8050.0};
            expect_nearest(@"multi-page viewport picks vertically closest", 1, pages, centers, 4, 2, 4, 3600.0);
        }

        {
            // Inverted visible range is normalized instead of misbehaving.
            NSInteger pages[] = {0, 4};
            CGFloat centers[] = {50.0, 4050.0};
            expect_nearest(@"inverted visible range is normalized", 1, pages, centers, 2, 4, 3, 3900.0);
        }
    }
    if (gFailureCount > 0) return 1;
    printf("SPDFMacFindNearestTests passed\n");
    return 0;
}
