#import <Cocoa/Cocoa.h>

#import "SPDFMacDelegatePrivate.h"

// Deciding whether an ocrmypdf run actually did its job.
//
// "Did any page come back with text?" is not that question. ocrmypdf skips a
// page that carries no raster image --
//   "2 page has no images - skipping all processing on this page to avoid
//    losing detail. Use --force-ocr ... to perform OCR on pages that have
//    vector content."
// -- so a datasheet whose cover is a scan and whose body pages are vector
// comes back with a text layer on page 1 and nothing on pages 2..8. Page 1
// alone satisfied the old check, the run was declared a success, and the user
// found they could not select a word past the cover.
//
// The honest test is per page: any page still without text means the pass was
// partial, and the image pass (--force-ocr) is the one that covers it.

// Whether the document's text sits on top of a full-page scan. Such a text
// layer is itself OCR output, not text the document was authored with, so
// re-recognising the pixels loses nothing -- whereas --redo-ocr trusts it and
// leaves whatever the previous pass missed missing. Measured on a USB-C
// footprint: redo recovered four of five dimension numbers and left one that
// forcing the same page at the same resolution recovered.
FOUNDATION_EXPORT BOOL spdf_mac_ocr_document_is_image_backed(spdf_document* doc);

// How many of the document's pages have no extractable text, or -1 if the file
// could not be read. A blank sheet counts as a page without text, which is why
// this arms a single retry and not a loop.
FOUNDATION_EXPORT NSInteger spdf_mac_ocr_pages_without_text(spdf_document* doc);

// YES when ocrmypdf refused the file for a reason the forced image pass fixes,
// and said so itself. The case that prompted this: a scanned purchase order
// carrying /Marked true, which ocrmypdf rejects with
//   "This PDF is marked as a Tagged PDF ... Use --force-ocr, --skip-text or
//    --redo-ocr to override this error."
// and exit 2. The tag says the file came from an office document and needs no
// OCR; here it was nine scanned pages with no text on any of them, and forcing
// the pass recognised all nine. A refusal like that arrives on the FAILURE
// path, before the page-coverage check, so it needs its own retry.
FOUNDATION_EXPORT BOOL spdf_mac_ocr_failure_wants_forced_pass(NSString* output);

// ocrmypdf's own output turned into something worth putting in an alert, and
// capped at a length a dialog can show. Never empty.
FOUNDATION_EXPORT NSString* spdf_mac_ocr_human_readable_failure(NSString* output);

@interface ShenzhenMacDelegate (SPDFMacOCRValidation)
// Whether `path` has any selectable text at all: 1 yes, 0 no, -1 unreadable.
- (NSInteger)selectableTextStateForPDFAtPath:(NSString*)path errorMessage:(NSString**)errorOut;
// YES when `path` opens but leaves at least one page without text: an OCR run
// that reported success while skipping pages.
- (BOOL)ocrOutputIsPartialAtPath:(NSString*)path;
@end
