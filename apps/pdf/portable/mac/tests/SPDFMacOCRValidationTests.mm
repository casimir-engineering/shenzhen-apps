// What an ocrmypdf run's RESULT means.
//
// Two refusals reach the app differently and both used to end as "OCR failed".
//
// A scanned purchase order carrying /Marked true is rejected before any page is
// read, with exit 2 and ocrmypdf's own advice in the output. The tag claims the
// file came from an office document and needs no OCR; measured on the real
// file, all nine pages had zero extractable characters, and --force-ocr
// recognised text on all nine. That refusal arrives on the failure path, where
// no page-coverage check runs, so it needs its own retry.
//
// The strings below are ocrmypdf 17.4.2's actual output, kept verbatim.

#import <Cocoa/Cocoa.h>

#import "../SPDFMacOCRValidation.h"

static int gFailures;

static void Expect(BOOL condition, NSString* what) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", what.UTF8String);
    ++gFailures;
}

int main(void) {
    @autoreleasepool {
        // --- Verbatim, from the run that prompted this --------------------------
        NSString* tagged =
            @"This PDF is marked as a Tagged PDF. This often indicates that the PDF was generated from an "
            @"office document and does not need OCR. PDF pages processed by OCRmyPDF may not be tagged "
            @"correctly.\nUse --tagged-pdf-mode ignore to ignore Tagged PDFs.\nTaggedPDFError: This PDF is "
            @"marked as a Tagged PDF. This often indicates\nthat the PDF was generated from an office "
            @"document and does\nnot need OCR. Use --force-ocr, --skip-text or --redo-ocr to\noverride this "
            @"error.";
        Expect(spdf_mac_ocr_failure_wants_forced_pass(tagged),
               @"a Tagged PDF refusal retries forced: the tag lied, the pages were scans");

        NSString* vector =
            @"2 page has no images - skipping all processing on this page to avoid losing detail. "
            @"Use --force-ocr (or --mode force) if you wish to perform OCR on pages that have vector content.";
        Expect(spdf_mac_ocr_failure_wants_forced_pass(vector), @"so does a refusal over vector content");

        // --- What must NOT trigger a forced rasterisation -----------------------
        Expect(!spdf_mac_ocr_failure_wants_forced_pass(@""), @"no output is not an invitation to force");
        Expect(!spdf_mac_ocr_failure_wants_forced_pass(@"tesseract: command not found"),
               @"a missing toolchain is not fixed by forcing");
        Expect(!spdf_mac_ocr_failure_wants_forced_pass(
                   @"ERROR: Input file is not a valid PDF: could not find xref"),
               @"nor is a corrupt file");
        Expect(!spdf_mac_ocr_failure_wants_forced_pass(@"This PDF is marked as a Tagged PDF."),
               @"the flag ocrmypdf names is what decides, not the prose: no --force-ocr, no retry");
        Expect(!spdf_mac_ocr_failure_wants_forced_pass(
                   @"--redo-ocr is not compatible with --deskew, --clean-final"),
               @"a redo-ocr incompatibility is reported, not rasterised behind the user's back");

        // --- The alert text -----------------------------------------------------
        Expect([spdf_mac_ocr_human_readable_failure(@"") isEqualToString:@"OCRmyPDF exited with an error."],
               @"an empty failure still says something");
        Expect([spdf_mac_ocr_human_readable_failure(@"--redo-ocr is not compatible with --deskew")
                   containsString:@"could not redo OCR"],
               @"the redo-ocr incompatibility is explained rather than pasted");
        Expect([spdf_mac_ocr_human_readable_failure(@"Traceback (most recent call last):")
                   containsString:@"crashed"],
               @"a traceback is named as an OCRmyPDF problem, not a Shenzhen PDF one");
        NSString* huge = [@"" stringByPaddingToLength:4000 withString:@"x" startingAtIndex:0];
        Expect(spdf_mac_ocr_human_readable_failure(huge).length == 1200,
               @"a wall of output is trimmed to what an alert can show");
        Expect([spdf_mac_ocr_human_readable_failure(@"short and unrecognised")
                   isEqualToString:@"short and unrecognised"],
               @"anything else reaches the user as ocrmypdf wrote it");

        if (gFailures == 0) puts("SPDFMacOCRValidationTests passed");
    }
    return gFailures == 0 ? 0 : 1;
}
