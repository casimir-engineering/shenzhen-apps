#pragma once
// Annotate on PDFs (docs/plans/annotate.md § Decisions "PDFs", § 5 PDFs): the bridge between a tab's page canvases
// (SPDFMacAnnotateSession, core spdf_paint_pdf_*) and Fill & Sign's commit cycle, and the fill_on_pdf route of
// -applyOperation:tab:completion: (pen.add, arrow.add, erase.lines and every form.* operation go to the existing Fill
// & Sign code, so a line or a signature an agent places is exactly what the person's own gesture makes).
//
// Order of a canvas operation on a PDF page (the controller's canvas route, SPDFMacFillController+Annotate.mm):
//   1. -annotatePrepareForPDFChange (permission, signed PDF, Collection, the writable copy: may replace the tab's
//      document, so it runs BEFORE the canvas changes; the session then reopens its page canvases on the new one);
//   2. -[SPDFMacAnnotateSession applyCanvasOperation:page:input:];
//   3. -annotateWritePDFPage:canvas:error: (the canvas written back as annotations, saved, the page redrawn, all in
//      this turn: what shows on screen is the reader's own page image of the file, so other readers see the same).
// When Fill & Sign changes a page (its own tools, its undo and redo, Remove commands), -annotatePDFPageDidChange: makes
// that page's canvas read its annotations again (called from -invalidatePage:), and every Fill & Sign undo step is
// recorded on the tab's one undo stack (-[SPDFMacAnnotateSession recordFillStep]).
#import "SPDFMacFillController+Annotate.h"

#include "spdf_paint.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMacFillController (AnnotatePDF)

// The fill_on_pdf route on a PDF tab: YES when this took the operation (completion then answers it, once).
- (BOOL)annotateApplyFillOperation:(NSDictionary*)op
                              info:(const spdf_paint_op_info*)info
                               tab:(nullable SPDFDocumentTab*)tab
                        completion:(nullable SPDFAnnotateCompletion)completion;

// Before a canvas operation changes a PDF page (step 1 above). NO: nothing may change (the person was told why).
- (BOOL)annotatePrepareForPDFChange;
// After it (step 3): writes the page's canvas back and saves through Fill & Sign's commit cycle. YES when there was
// nothing to write or it was written and saved; NO with error otherwise (the person was shown it too).
- (BOOL)annotateWritePDFPage:(NSInteger)page canvas:(spdf_paint_doc*)canvas error:(NSString* _Nullable* _Nullable)error;
// Fill & Sign changed this page (0-based): its open canvas reads the page's annotations again and redraws.
- (void)annotatePDFPageDidChange:(NSInteger)page;
// From now on every Fill & Sign undo step is also recorded on the tab's Annotate stack (once per controller).
- (void)annotateTrackFillUndoSteps;

@end

// Commands that would change a PDF page itself are greyed, with SPDFAnnotatePageLockedText ("The page itself can't
// be changed.") as their tooltip. op: the operation the command sends (§ 6 name); canvas: the page's canvas (NULL
// when none is open yet: nothing added, so whole-page commands are locked). NO off PDFs.
FOUNDATION_EXPORT BOOL SPDFAnnotatePDFCommandIsLocked(NSString* op, spdf_paint_doc* _Nullable canvas);

NS_ASSUME_NONNULL_END
