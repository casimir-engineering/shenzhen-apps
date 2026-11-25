#pragma once
// Annotate, per tab (docs/plans/annotate.md § 8 Mac): the core canvas of a picture or blank canvas, or one core canvas
// per touched PDF page; the tool, its settings and the two colours; the tab's one undo stack; saving a picture
// (flatten, encode off the main thread, write beside and swap in, Collection before and after), the .szpaint kept
// beside a picture 2 s after the last change, and PDF pages written through Fill & Sign's commit cycle.
//
// Created the first time Annotate is turned on for a tab, a .szpaint file or a restored canvas tab opens, or an
// operation arrives for the tab: never at launch. Found again through the tab (an associated object, as
// SPDFFillSession is). Main thread only, like the main-thread document it reads.
//
// Every change goes through -[SPDFMacFillController applyOperation:tab:completion:] (SPDFMacFillController+Annotate.h);
// the session's -applyCanvasOperation:page:input: is what that entry point calls for the canvas route, never the UI.
#import <Cocoa/Cocoa.h>

#include "spdf_paint.h"

@class SPDFDocumentTab;

NS_ASSUME_NONNULL_BEGIN

// What the tab shows, as the operation table names document kinds (spdf_paint_doc_kind).
typedef NS_ENUM(NSInteger, SPDFAnnotateDocumentKind) {
    SPDFAnnotateDocumentNone = 0,  // nothing Annotate can work on (no document, presentation mode)
    SPDFAnnotateDocumentPicture = SPDF_PAINT_DOC_PICTURE,
    SPDFAnnotateDocumentCanvas = SPDF_PAINT_DOC_CANVAS,  // File > New Canvas, a .szpaint
    SPDFAnnotateDocumentPDF = SPDF_PAINT_DOC_PDF,
    SPDFAnnotateDocumentText = SPDF_PAINT_DOC_TEXT       // Markdown, plain text, EPUB...: asks to save as PDF first
};

// The tools of § 2, as the palette, keys and tool.choose name them. A PDF's form group is Fill & Sign's own tools
// (SPDFFillTool): FormText, FormMark and FormSignature map to SPDFFillToolText, Mark and Signature; Pen, Arrow, Eraser
// (whole lines) and Select stay Fill & Sign's on a PDF.
typedef NS_ENUM(NSInteger, SPDFAnnotateTool) {
    SPDFAnnotateToolFormText = 0,     // "form_text"   T on a PDF
    SPDFAnnotateToolFormMark,         // "form_mark"
    SPDFAnnotateToolFormSignature,    // "form_signature"
    SPDFAnnotateToolSelect,           // "select"           S (S again: rectangular, then free-form)
    SPDFAnnotateToolRectSelect,       // "rect_select"
    SPDFAnnotateToolFreeformSelect,   // "freeform_select"
    SPDFAnnotateToolPen,              // "pen"              P
    SPDFAnnotateToolArrow,            // "arrow"            A
    SPDFAnnotateToolPencil,           // "pencil"           N
    SPDFAnnotateToolFill,             // "fill"             F
    SPDFAnnotateToolTextBox,          // "text_box"         Shift-T (T where there is no form Text)
    SPDFAnnotateToolEraser,           // "eraser"           E (E again: whole lines / pixels)
    SPDFAnnotateToolColorPicker,      // "color_picker"     I
    SPDFAnnotateToolMagnifier,        // "magnifier"        Z
    SPDFAnnotateToolBrush,            // "brush", "calligraphy1" ... "watercolor": B (B again cycles); see .brush
    SPDFAnnotateToolShape             // "shape"            U (U again cycles), L Line; see .shape
};

// The tool.choose name ("pencil", "brush"...) and back. A brush name gives SPDFAnnotateToolBrush and sets *brush;
// returns NO for an unknown name.
FOUNDATION_EXPORT NSString* SPDFAnnotateToolName(SPDFAnnotateTool tool, NSInteger brush);
FOUNDATION_EXPORT BOOL SPDFAnnotateToolFromName(NSString* name, SPDFAnnotateTool* tool, NSInteger* _Nullable brush);

// Every tool's settings (size, opacity, brush, shape styles, font...), shared by every tab and window of the process,
// remembered in <state>/Annotate/settings.json: read the first time Annotate opens (Fill & Sign's drawing.json is
// read once into it), written on change. Keys are the operations' argument names, per tool:
// {"pencil": {"size": 1, "opacity": 100}, "brush": {...}, "shape": {"shape": "rectangle", "outline": {...}}, ...}.
@interface SPDFAnnotateSettings : NSObject
+ (instancetype)shared;
- (NSDictionary*)optionsForTool:(NSString*)toolName;
- (void)setOptions:(NSDictionary*)options forTool:(NSString*)toolName;  // merged; written soon after
@property(nonatomic) BOOL showsStatusBar;  // View > Status Bar
@property(nonatomic) BOOL showsRulers;     // View > Rulers
@property(nonatomic) BOOL showsGridlines;  // View > Gridlines
@property(nonatomic) BOOL showsLayers;     // the Layers panel (Shift-Cmd-L)
@property(nonatomic, copy) NSArray<NSString*>* customColors;  // 10 "#RRGGBBAA" or "" (empty slot)
@end

@interface SPDFMacAnnotateSession : NSObject

+ (nullable instancetype)existingSessionForTab:(SPDFDocumentTab*)tab;
// Makes the tab's session if it has none. kind from SPDFAnnotateDocumentKindForPath (SPDFMacAnnotateImageIO.h) or a
// canvas tab; path is the file the tab shows (nil for a never-saved canvas).
+ (instancetype)sessionForTab:(SPDFDocumentTab*)tab kind:(SPDFAnnotateDocumentKind)kind path:(nullable NSString*)path;
// Frees the canvases (tab closed). The session must have been flushed (-flushForClose:).
+ (void)discardSessionForTab:(SPDFDocumentTab*)tab;

@property(nonatomic, weak, readonly) SPDFDocumentTab* tab;
@property(nonatomic, readonly) SPDFAnnotateDocumentKind kind;
@property(nonatomic, copy, nullable) NSString* path;  // changes after Save As
// The picture's format (a UTI, "public.png"), and whether it can be written back in place. NO for WebP, camera RAW
// and animated GIF or HEIC: Annotate works on a copy and the first save asks where, PNG chosen (paletteCopyNote).
@property(nonatomic, copy, readonly, nullable) NSString* format;
@property(nonatomic, readonly) BOOL writesInPlace;
// The palette's line for this document, or nil: "Annotate saves a copy of this picture as PNG." on a picture that
// can't be written in place (Fill & Sign's own writable-copy line stays the controller's, on PDFs).
@property(nonatomic, copy, readonly, nullable) NSString* paletteCopyNote;

// Tool state (UI state: never on the undo stack).
@property(nonatomic) SPDFAnnotateTool tool;
@property(nonatomic) NSInteger brush;        // spdf_paint_brush, for SPDFAnnotateToolBrush
@property(nonatomic, copy) NSString* shape;  // shape.add's name, for SPDFAnnotateToolShape ("rectangle")
@property(nonatomic) BOOL eraserPixels;      // the Eraser: pixels (YES) or Fill & Sign's whole lines (NO)
@property(nonatomic) spdf_paint_color color1;  // black
@property(nonatomic) spdf_paint_color color2;  // white
@property(nonatomic) SPDFAnnotateTool toolBeforePicker;  // the Color picker returns to it after one pick

// Loads the picture into its canvas the first time Annotate turns on (or at once for a .szpaint or a canvas tab):
// decodes with ImageIO, and takes the layers kept beside the picture when the file is unchanged (size and
// modification time match). NO with error when it can't be read. Does nothing for PDFs (pages open on demand).
- (BOOL)loadIfNeeded:(NSError* _Nullable* _Nullable)error;
@property(nonatomic, readonly) BOOL loaded;

// The canvas of a picture or blank canvas; NULL before -loadIfNeeded: and on PDFs.
@property(nonatomic, readonly, nullable) spdf_paint_doc* canvas;
// A PDF page's canvas (page from 0), opened from its annotations on first use when create is YES (pdf: the tab's
// main-thread document). NULL when the page is not open and create is NO.
- (nullable spdf_paint_doc*)canvasForPage:(NSInteger)page document:(nullable spdf_document*)pdf create:(BOOL)create;
@property(nonatomic, readonly) NSIndexSet* openPages;
// The page the Layers panel and status bar follow: the page last touched, else the page most in view (-1: none).
@property(nonatomic) NSInteger currentPage;

// Applies a canvas-route operation (spdf_paint_apply_ex) to the picture's canvas or the given page's (0-based; -1 on a
// picture), records it on the tab's undo stack when the core recorded it, notes the change for saving, and answers
// the parsed result ({"ok": ...}). Called by -applyOperation:tab:completion: only.
- (NSDictionary*)applyCanvasOperation:(NSDictionary*)op page:(NSInteger)page
                                input:(nullable const spdf_paint_apply_input*)input;

// The tab's one undo stack: core canvas steps (with their page) and Fill & Sign's steps (recorded by the controller
// with -recordFillStep, undone through its NSUndoManager), in the order they were made.
- (void)recordFillStep;
@property(nonatomic, readonly) BOOL canUndo;
@property(nonatomic, readonly) BOOL canRedo;
@property(nonatomic, readonly, copy, nullable) NSString* undoActionName;  // for Edit > Undo <name>
@property(nonatomic, readonly, copy, nullable) NSString* redoActionName;
// Undoes or redoes `steps` steps; the answer as history.undo answers ({"ok", "undone": n} or nothing_to_undo).
- (NSDictionary*)undo:(NSInteger)steps;
- (NSDictionary*)redo:(NSInteger)steps;
// Edit > Repeat (F4): the last undoable operation, to apply again, or nil.
@property(nonatomic, readonly, copy, nullable) NSDictionary* repeatableOperation;

// Saving (§ 5). dirty: changed since the last write (a PDF page: not yet written back).
@property(nonatomic, readonly) BOOL dirty;
// A canvas with no file yet: closing it asks Save / Don't Save / Cancel.
@property(nonatomic, readonly) BOOL neverSaved;
// Writes the flattened picture into its file in its own format, with its metadata (Collection told before and after),
// encoding off the main thread; or, for a PDF, writes the changed pages back as annotations and saves through the
// Fill & Sign commit cycle. completion on the main thread with nil or the error. A never-saved canvas or a picture
// that can't be written in place answers an error asking for doc.save_as.
- (void)saveWithCompletion:(void (^)(NSError* _Nullable error))completion;
// Save As: PNG, JPEG, HEIC, TIFF, BMP, GIF or a Shenzhen Paint project (format as doc.save_as names it); the tab then
// shows the new file. quality 0-1 for JPEG and HEIC (0.92 by default).
- (void)saveAsPath:(NSString*)path format:(NSString*)format quality:(CGFloat)quality
        completion:(void (^)(NSError* _Nullable error))completion;
// The .szpaint kept beside a picture (<state>/Annotate/<hash of path>.szpaint), written 2 s after the last change.
- (void)scheduleProjectAutosave;
// Before the tab closes, the document is left, or the app quits: writes what is pending now, on this thread, so
// nothing is lost and no frame shows a wrong state. A never-saved canvas is kept for next launch (quit) instead.
- (BOOL)flushForClose:(BOOL)quitting error:(NSError* _Nullable* _Nullable)error;

@end

NS_ASSUME_NONNULL_END
