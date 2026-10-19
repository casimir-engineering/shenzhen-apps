#import <Cocoa/Cocoa.h>

// The ocrmypdf command line, as a pure function so the flags can be tested.
//
// Two decisions live here and both were measured rather than guessed.
//
// --oversample 400: recognition of small text is dominated by the resolution
// the page is rasterised at, and a scan carries whatever DPI it was made with.
// On one datasheet drawing page, rasterised by hand: 96 dpi recovered 12 of its
// dimension numbers, 200 dpi recovered 24. Through the whole pipeline on a
// 96 dpi page: 14 without this flag, 27 with it. ocrmypdf only upsamples pages
// below the threshold, so a scan that is already sharp pays nothing for it.
//
// --tesseract-pagesegmode 11 (sparse text): tesseract's default layout analysis
// reads a page as columns of prose, and a mechanical drawing is not that -- its
// dimension numbers sit alone among line art and get discarded as decoration.
// On a USB-C footprint whose five dimensions the app had recognised NONE of:
// psm 11 recovered four of the five, psm 3 recovered two. It is not a trade
// against ordinary pages either; on a prose datasheet page psm 11 read 137 real
// words to psm 3's 128, and on the drawing 128 to 93.
//
// Resolution was the obvious suspect and is not the answer here: that scan is
// already 400 dpi, and raising --oversample to 600, 800 or 1200 changed nothing
// (four of five at every one of them, and 5.8s at 400 against far longer).
//
// --deskew / --force-ocr vs --redo-ocr: a source with no text is a scan and is
// straightened before recognition; --force-ocr is the retry that also covers
// pages ocrmypdf would otherwise skip (vector pages, and PDFs marked as tagged
// -- see SPDFMacOCRValidation.h). A source that already has text gets
// --redo-ocr, which replaces its layer without rasterising what is already
// sharp.
FOUNDATION_EXPORT NSArray<NSString*>* spdf_mac_ocr_arguments(NSString* language, NSString* originalPath,
                                                             NSString* tmpPath, NSInteger jobs,
                                                             BOOL sourceHasText, BOOL forceOCR);
