#pragma once
// The single path for every Annotate change (docs/plans/annotate.md § 6): a palette control, a menu item, a key, a
// gesture on the canvas, `szpdf annotate`, the assistant and MCP all call -applyOperation:tab:completion:, and nothing
// changes a document any other way. SPDFMacFillController stays the per-window controller of the mode (on/off, Done,
// auto-on for forms, flush hooks, undo per tab, the writable copy); this category adds the entry point and routes:
//
// 1. spdf_paint_check_op with the tab's document kind: unknown op, bad arguments, a text document (needs_pdf but for
//    doc.save_as_pdf), a form operation off a PDF (pdf_only), a page change on a PDF (page_locked) are answered here,
//    the same answer for every surface.
// 2. By the op's route (spdf_paint_op_info.route):
//    - canvas: -[SPDFMacAnnotateSession applyCanvasOperation:page:input:] on the picture's canvas or the "page"'s
//      (picture.add {path | clipboard} and image.remove_background are worked out first: decoded picture, Vision
//      subject mask);
//    - fill_on_pdf: on a PDF, the existing Fill & Sign code (pen.add -> addDrawnStrokes:, arrow.add, erase.lines,
//      form.* -> setText:forField:, addTextItem:..., addMarkOnPage:..., addSignature:..., removeAllDrawings,
//      removeEverythingAdded, Save Final Copy), recorded on the tab's undo stack with -recordFillStep; elsewhere as
//      canvas;
//    - frontend: the session and the integration (doc.save*, doc.copy, mode.set, view.*, tool.choose, canvas.new,
//      history.undo/redo across the tab's pages and Fill & Sign steps).
// 3. Afterwards: the canvas view redraws the damage, the palette, Layers panel and status bar follow, the change is
//    saved as § 5 says (a picture on Cmd-S, Done, close, switch or quit; a PDF after Fill & Sign's 0.35 s rest).
//
// Annotate is turned on for the tab when an operation that needs it arrives with it off (agents: the window does not
// come forward). Main thread; completion runs on the main thread, once, with the answer
// ({"ok": true, ...} or {"ok": false, "error": code, "message": sentence}), possibly before this returns.
#import "SPDFMacFillController.h"

#import "SPDFMacAnnotateSession.h"

@class SPDFMacAnnotateCanvasView, SPDFMacAnnotateLayersPanel, SPDFMacAnnotatePaletteGroups;

NS_ASSUME_NONNULL_BEGIN

typedef void (^SPDFAnnotateCompletion)(NSDictionary* result);

@interface SPDFMacFillController (Annotate)

// op: {"op": name, ...arguments} as § 6 writes it. tab: the tab it acts on (nil: the active tab). A tab that is not
// shown (an agent's target in the background) is worked on without switching to it.
- (void)applyOperation:(NSDictionary*)op
                   tab:(nullable SPDFDocumentTab*)tab
            completion:(nullable SPDFAnnotateCompletion)completion;

// The same, for a list applied in order that stops at the first error (`szpdf annotate --script`): answers
// {"ok": all ok, "results": [each answer]}.
- (void)applyOperations:(NSArray<NSDictionary*>*)ops
                    tab:(nullable SPDFDocumentTab*)tab
             completion:(nullable SPDFAnnotateCompletion)completion;

// The tab's session, made on demand for a document Annotate can work on (nil otherwise).
- (nullable SPDFMacAnnotateSession*)annotateSessionForTab:(nullable SPDFDocumentTab*)tab create:(BOOL)create;

// The views Annotate adds to the window, made the first time Annotate shows.
@property(nonatomic, readonly, nullable) SPDFMacAnnotateCanvasView* annotateCanvasView;
@property(nonatomic, readonly, nullable) SPDFMacAnnotateLayersPanel* annotateLayersPanel;
@property(nonatomic, readonly, nullable) SPDFMacAnnotatePaletteGroups* annotatePaletteGroups;

@end

NS_ASSUME_NONNULL_END
