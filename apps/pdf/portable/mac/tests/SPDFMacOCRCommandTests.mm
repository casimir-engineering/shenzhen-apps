// The ocrmypdf command line. Every flag here was chosen from a measurement, so
// this suite states the measurement beside the flag it justifies.

#import <Cocoa/Cocoa.h>

#import "../SPDFMacOCRCommand.h"

static int gFailures;

static void Expect(BOOL condition, NSString* what) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", what.UTF8String);
    ++gFailures;
}

// The value that follows `flag`, or nil.
static NSString* ValueAfter(NSArray<NSString*>* args, NSString* flag) {
    NSUInteger i = [args indexOfObject:flag];
    if (i == NSNotFound || i + 1 >= args.count) return nil;
    return args[i + 1];
}

int main(void) {
    @autoreleasepool {
        NSArray<NSString*>* scan = spdf_mac_ocr_arguments(@"chi_sim+eng", @"/in.pdf", @"/out.pdf", 4, NO, NO);

        // --- Resolution, the thing that decides whether small text is read ----
        // A datasheet drawing page rasterised by hand: 96 dpi recovered 12 of
        // its dimension numbers, 200 dpi recovered 24. Through the whole
        // pipeline on a 96 dpi page: 14 without this flag, 27 with it.
        Expect([ValueAfter(scan, @"--oversample") isEqualToString:@"400"],
               @"pages are recognised at 400 dpi, not at whatever DPI the scan happens to carry");

        // --- Layout analysis, the thing that decides whether a DRAWING is read --
        // A USB-C footprint whose five dimension numbers the app recognised none
        // of: psm 11 recovered four, psm 3 recovered two. Not a trade against
        // prose either -- 137 real words to psm 3's 128 on a text page.
        Expect([ValueAfter(scan, @"--tesseract-pagesegmode") isEqualToString:@"11"],
               @"sparse-text segmentation: a dimension number alone among line art is not a column of prose");

        // --- A source with no text is a scan --------------------------------
        Expect([scan containsObject:@"--deskew"], @"a scan is straightened before recognition");
        Expect(![scan containsObject:@"--force-ocr"], @"but is not forced on the first pass");
        Expect(![scan containsObject:@"--redo-ocr"], @"and has no text layer to redo");

        // --- The forced retry -------------------------------------------------
        NSArray<NSString*>* forced = spdf_mac_ocr_arguments(@"eng", @"/in.pdf", @"/out.pdf", 4, NO, YES);
        Expect([forced containsObject:@"--force-ocr"] && [forced containsObject:@"--deskew"],
               @"the retry forces the image pass, which is what covers vector and tagged pages");

        // --- A source that already has text -----------------------------------
        NSArray<NSString*>* redo = spdf_mac_ocr_arguments(@"eng", @"/in.pdf", @"/out.pdf", 4, YES, NO);
        Expect([redo containsObject:@"--redo-ocr"], @"an existing text layer is redone, not rasterised over");
        Expect(![redo containsObject:@"--deskew"] && ![redo containsObject:@"--force-ocr"],
               @"and nothing is straightened or forced: ocrmypdf rejects those together with --redo-ocr");
        Expect([ValueAfter(redo, @"--oversample") isEqualToString:@"400"], @"oversampling applies to it too");

        // --- The rest of the line ----------------------------------------------
        Expect([ValueAfter(scan, @"-l") isEqualToString:@"chi_sim+eng"], @"the chosen language is passed through");
        Expect([ValueAfter(scan, @"--jobs") isEqualToString:@"4"], @"as is the worker count");
        Expect([scan[scan.count - 2] isEqualToString:@"/in.pdf"] && [scan.lastObject isEqualToString:@"/out.pdf"],
               @"input and output are the last two arguments, in that order");
        Expect([ValueAfter(spdf_mac_ocr_arguments(nil, nil, nil, 1, NO, NO), @"-l") isEqualToString:@"eng"],
               @"a missing language does not produce a command with a dangling -l");

        if (gFailures == 0) puts("SPDFMacOCRCommandTests passed");
    }
    return gFailures == 0 ? 0 : 1;
}
