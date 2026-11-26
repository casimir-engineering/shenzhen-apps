#pragma once
// Annotate in the reader (docs/plans/annotate.md § Decisions, § 1, § 5, § 8 Mac): the toolbar button (Fill & Sign's,
// renamed Annotate, for every document), File > New Canvas and canvas tabs, opening .szpaint files, text documents
// asked to become a PDF first, saving (Cmd-S, Save As, Set as Desktop Picture), and the tab-close and quit hooks.
// SPDFMacAnnotateIntegration.mm implements the category; the menus, context menus and keys live in
// SPDFMacAnnotateMenus.mm and the sheets in SPDFMacAnnotateSheets.mm (both declared here).
//
// Launch cost: none. The button and menu items are the ones Fill & Sign already builds with the window (their titles
// change); every Annotate object, file and font is created the first time Annotate is opened, a form PDF is detected
// (as today), or a .szpaint or canvas tab is restored. applicationDidFinishLaunching, loadPersistentState and main()
// reference nothing here except -annotateRestoreCanvasTab:, called only when such a tab exists.
#import "SPDFMacDelegatePrivate.h"

#import "SPDFMacAnnotateSession.h"

@class SPDFMacFillController;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Text the person sees (exactly as the spec writes it)

FOUNDATION_EXPORT NSString* const SPDFAnnotateTitle;                // "Annotate" (button, mode, menu items)
FOUNDATION_EXPORT NSString* const SPDFAnnotateFormGroupTitle;       // "Fill & Sign" (the PDF form group's own label)
FOUNDATION_EXPORT NSString* const SPDFAnnotateNewCanvasTitle;       // "New Canvas…" (File menu; it opens a sheet)
FOUNDATION_EXPORT NSString* const SPDFAnnotateUntitledCanvasTitle;  // "Untitled canvas" (the tab)
FOUNDATION_EXPORT NSString* const SPDFAnnotateSaveAsPDFQuestion;    // "To annotate this document, save it as a PDF."
FOUNDATION_EXPORT NSString* const SPDFAnnotateSaveAsPDFButton;      // "Save as PDF…"
FOUNDATION_EXPORT NSString* const SPDFAnnotatePageLockedText;       // "The page itself can't be changed."
FOUNDATION_EXPORT NSString* const SPDFAnnotateNeedsPDFText;         // "Save this document as a PDF to annotate it."
FOUNDATION_EXPORT NSString* const SPDFAnnotateCopyNoteText;         // "Annotate saves a copy of this picture as PNG."
// "You're annotating a copy, because the original can't be changed. Choose File > Save As... to put it where you
// want." (Fill & Sign's writable-copy note, worded for annotations)
FOUNDATION_EXPORT NSString* const SPDFAnnotateWritableCopyNote;
FOUNDATION_EXPORT NSString* const SPDFAnnotateGrowCanvasQuestion;   // "Make the canvas bigger to fit?"
FOUNDATION_EXPORT NSString* const SPDFAnnotateRemoveEverythingTitle;// "Remove Everything Added with Annotate"
FOUNDATION_EXPORT NSString* const SPDFAnnotateProjectFormatTitle;   // "Shenzhen Paint project"

// The toolbar button's pencil-and-brush picture (a template image, tinted like the other toolbar icons): SF Symbols
// has no such symbol, so a pencil and a mirrored paintbrush are drawn crossed.
FOUNDATION_EXPORT NSImage* SPDFAnnotateIcon(void);

#pragma mark - The reader's side

// What File > Recently Opened keeps for a tab's path: the .szpaint a project tab shows, nothing for a canvas never
// saved (its picture is Annotate's own), the path itself otherwise.
FOUNDATION_EXPORT NSString* _Nullable SPDFAnnotateRecentPath(NSString* _Nullable path);

@interface ShenzhenMacDelegate (SPDFMacAnnotate)

// The toolbar button and Option-Cmd-F: Annotate on or off for the active tab. On a text document it asks first
// (SPDFAnnotateAskToSaveAsPDF); on a picture it loads the canvas.
- (void)toggleAnnotate:(id _Nullable)sender;
- (BOOL)annotateAvailable;  // a document Annotate can open (not presentation mode, not a missing file)
- (BOOL)annotateShowing;
- (SPDFAnnotateDocumentKind)annotateActiveDocumentKind;
// A fitted picture or canvas fitted again to the room Annotate leaves it (SPDFMacFitViewport.mm).
- (void)annotateRefit;
// The active tab's Annotate session (nil until Annotate is used on it).
- (nullable SPDFMacAnnotateSession*)annotateActiveSession;
// The Layers panel takes the minimap's place while it shows; the minimap comes back when it goes.
- (void)annotateLayersPanelDidShow:(BOOL)shown;

// File > New Canvas (Cmd-N) and the tab strip's + menu: the New Canvas sheet (a searchable list of sizes, width and
// height, resolution; SPDFMacAnnotateNewCanvas.mm), then a tab "Untitled canvas", transparent, Annotate on. Also
// canvas.new from the agents (width, height, ppi, background; front NO keeps the window behind).
- (void)newCanvas:(id _Nullable)sender;
- (nullable SPDFDocumentTab*)annotateNewCanvasWidth:(NSInteger)width height:(NSInteger)height ppi:(double)ppi
                                         background:(spdf_paint_color)background front:(BOOL)front;
// A restored tab that was a never-saved canvas: its pixels come back from <state>/Annotate. Called only for such tabs.
- (void)annotateRestoreCanvasTab:(SPDFDocumentTab*)tab;
// Opening a .szpaint: a canvas tab with its layers, Annotate on. NO when path is not one.
- (BOOL)annotateOpenProjectAtPath:(NSString*)path;

// Text documents: writes the PDF the app's print and `szpdf export-pdf` make (path nil: the Save panel, same folder
// and name with .pdf), opens it in a new tab beside the original with Annotate on, and answers that tab (nil when
// cancelled or failed, with error). The original is never changed.
- (void)annotateSaveTextDocumentAsPDF:(nullable NSString*)path
                           completion:(void (^)(SPDFDocumentTab* _Nullable tab, NSError* _Nullable error))completion;

// File menu: Cmd-S, Save As... (PNG, JPEG, HEIC, TIFF, BMP, GIF, Shenzhen Paint project), Set as Desktop Picture.
- (void)annotateSaveDocument:(id _Nullable)sender;
- (void)annotateSaveDocumentAs:(id _Nullable)sender;
- (void)setDesktopPicture:(id _Nullable)sender;

// View menu and the palette: the Layers panel (Shift-Cmd-L), Status Bar, Rulers, Gridlines, Thumbnail.
- (void)toggleAnnotateLayers:(id _Nullable)sender;
- (void)toggleAnnotateStatusBar:(id _Nullable)sender;
- (void)toggleAnnotateRulers:(id _Nullable)sender;
- (void)toggleAnnotateGridlines:(id _Nullable)sender;
- (void)toggleAnnotateThumbnail:(id _Nullable)sender;

// Hooks, one line each in the reader. Before the active document is left: pending changes written. The active tab
// changed: chrome follows. A tab is closing: NO keeps it open (a never-saved canvas asked Save / Don't Save / Cancel,
// and the person chose Cancel). Quitting: everything written now, never asking (never-saved canvases are kept for
// next launch).
- (void)annotateFlushEdits;
- (void)annotateActiveDocumentChanged;
- (BOOL)annotateTabShouldClose:(SPDFDocumentTab*)tab;
- (void)annotateFlushForQuit;
// More one-line hooks: Fill & Sign's -toggleFillAndSign: (YES: not a PDF, Annotate handled it), its settle hook after
// first paint (a canvas or project tab comes back with Annotate on), -openPaths: (a .szpaint opens as its picture),
// and Save As (Cmd-S today; YES: a picture or canvas in Annotate was saved).
- (BOOL)annotateToggleIfNotPDF;
- (void)annotateDocumentDidSettle;
- (NSArray<NSString*>*)annotateReaderPathsForPaths:(NSArray<NSString*>*)paths;
- (BOOL)annotateHandlesSave:(id _Nullable)sender;

// Zoom for the status bar, the Magnifier and view.zoom: level in view points per canvas unit (1 = 100 %, 0.125-8),
// or "fit" / "actual"; point (canvas units, NSValue) stays under the pointer, nil keeps the viewport's centre.
- (void)annotateZoomTo:(id)level atCanvasPoint:(nullable NSValue*)point;
// The reader zoom that 100% means (SPDFMacFitViewport.mm): 1, or with Annotate on a picture or canvas the one that
// shows one picture pixel per screen point. The toolbar, Zoom > 100% and the status bar all count from it.
- (CGFloat)actualZoom;
// Room to pan past a picture's or canvas's edges with Annotate on (SPDFMacFitViewport.mm): whether there is, the
// margin (zero elsewhere), applied to the clip view on each layout (YES: on), and a scroll origin held within it.
- (BOOL)annotatePansPastEdges;
- (NSEdgeInsets)annotatePanMargin;
- (BOOL)annotateUpdatePanMargin;
- (NSPoint)documentScrollOriginWithinPanRange:(NSPoint)origin;
// The Layers panel sits in the minimap's place while it shows (SPDFMacAnnotateIntegrationFiles.mm): the slot it sits
// in (nil while it doesn't show), and the minimap's own width, which is what is kept in the settings meanwhile.
- (nullable NSView*)annotateLayersSlot;
- (CGFloat)persistedMinimapWidth;
// After Done's write: the reader shows the written file, then the canvas stops covering the page.
- (void)annotateShowWrittenPictureOfSession:(SPDFMacAnnotateSession*)session;
// The Save panel (PNG chosen for a canvas or a picture that can't be written in its own format); saved: it was.
- (void)annotateAskWhereToSaveSession:(SPDFMacAnnotateSession*)session completion:(nullable void (^)(BOOL saved))completion;

@end

#pragma mark - Menus, context menus and keys (SPDFMacAnnotateMenus.mm)

// The Annotate items in the File, Edit, View and Image menus (titles and key equivalents per "Annotate keys" in the
// spec), each sending its operation; validated by SPDFAnnotateValidateMenuItem. Called where Fill & Sign's items are
// installed today (SPDFFillInstallMenuItems), with the window.
FOUNDATION_EXPORT void SPDFAnnotateInstallMenuItems(NSMenu* fileMenu, NSMenu* editMenu, NSMenu* viewMenu,
                                                    ShenzhenMacDelegate* reader);
// YES when the item is one of Annotate's; *enabled says whether it is enabled now (greyed with the tooltip "The page
// itself can't be changed." where it would change a PDF page).
FOUNDATION_EXPORT BOOL SPDFAnnotateValidateMenuItem(NSMenuItem* item, ShenzhenMacDelegate* reader, BOOL* enabled);
// The right-click menu of what is under the pointer (§ 3): an object, the selection, or the canvas. page -1 on a
// picture; point in canvas units.
FOUNDATION_EXPORT NSMenu* _Nullable SPDFAnnotateContextMenu(SPDFMacFillController* controller, NSInteger page,
                                                            NSPoint point);
// Tool letters and the other keys of § 4 while the canvas has the keyboard and no text box is being typed in. YES
// when the key was Annotate's (it then became an operation).
FOUNDATION_EXPORT BOOL SPDFAnnotateHandleKey(NSEvent* event, SPDFMacFillController* controller);

#pragma mark - Sheets and questions (SPDFMacAnnotateSheets.mm)

// Image > Resize and skew... (Option-Cmd-I), Canvas size and properties... (Option-Cmd-C), Rotate by...: each sheet
// sends its operation on OK.
FOUNDATION_EXPORT void SPDFAnnotateShowResizeSheet(NSWindow* window, SPDFMacFillController* controller);
FOUNDATION_EXPORT void SPDFAnnotateShowCanvasPropertiesSheet(NSWindow* window, SPDFMacFillController* controller);
// File > New Canvas's sheet (SPDFMacAnnotateNewCanvas.mm): `create` gets the size and resolution chosen; Cancel calls
// nothing. The last size and resolution are offered next time.
// (SPDFMacAnnotateNewCanvas.mm) `properties` (nil: none) with the resolution set to ppi (<= 0: left as it is), in every form ImageIO writes it: PNG's
// pHYs, JPEG's JFIF density and TIFF's resolution, so the saved file carries the canvas's resolution.
FOUNDATION_EXPORT NSDictionary* SPDFAnnotateResolutionProperties(NSDictionary* _Nullable properties, double ppi);
FOUNDATION_EXPORT void SPDFAnnotateShowNewCanvasSheet(NSWindow* _Nullable window,
                                                      void (^create)(NSInteger width, NSInteger height, double ppi));
FOUNDATION_EXPORT void SPDFAnnotateShowRotateBySheet(NSWindow* window, SPDFMacFillController* controller);
// "To annotate this document, save it as a PDF." [Save as PDF…] [Cancel]. save YES: Save as PDF was chosen.
FOUNDATION_EXPORT void SPDFAnnotateAskToSaveAsPDF(NSWindow* window, void (^answer)(BOOL save));
// Closing a never-saved canvas, or a WebP or RAW drawn on (its changes go into a PNG copy): Save / Don't Save / Cancel.
// copy: the picture's own format can't take the changes. NSAlertFirstButtonReturn = Save, Second = Don't Save, Third =
// Cancel.
FOUNDATION_EXPORT void SPDFAnnotateAskToSaveCanvas(NSWindow* window, NSString* name, BOOL copy,
                                                   void (^answer)(NSModalResponse choice));
// "Make the canvas bigger to fit?" (Yes / No) for a pasted picture larger than the canvas.
FOUNDATION_EXPORT void SPDFAnnotateAskToGrowCanvas(NSWindow* window, void (^answer)(BOOL grow));

NS_ASSUME_NONNULL_END
