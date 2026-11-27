#pragma once
// What the Annotate palette, the menu bar, the context menus and the keys share (docs/plans/annotate.md § 1-4):
// the tool, brush, shape and style tables with their names as the operations spell them, colours as "#RRGGBBAA",
// the one way they send an operation (through -[SPDFMacFillController applyOperation:tab:completion:], then the
// chrome follows), and the command items every menu is built from.
//
// A command item's representedObject says what it does: an operation (NSDictionary, {"op": ...}), several applied in
// order (NSArray of them), or a frontend command (NSString, SPDFAnnotateCommand* below) that opens a sheet, a panel or
// a file dialog and then sends operations. Its target validates it (greyed with "The page itself can't be changed."
// when the operation would change a PDF page).
#import <Cocoa/Cocoa.h>

#import "SPDFMacAnnotateSession.h"

@class SPDFMacFillController, ShenzhenMacDelegate;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Colours

FOUNDATION_EXPORT NSString* SPDFAnnotateHex(spdf_paint_color color);  // "#RRGGBB", or "#RRGGBBAA" when not opaque
FOUNDATION_EXPORT BOOL SPDFAnnotateParseHex(NSString* _Nullable hex, spdf_paint_color* color);
FOUNDATION_EXPORT NSColor* SPDFAnnotateNSColor(spdf_paint_color color);  // sRGB
FOUNDATION_EXPORT spdf_paint_color SPDFAnnotateColorFromNSColor(NSColor* color);
FOUNDATION_EXPORT NSString* SPDFAnnotatePaletteColorName(NSInteger index);  // "Black", "Grey 50 %" ...

#pragma mark - Tables

// One row of a tool, brush, shape or style table: name (as the operations spell it), label (as the person reads it),
// SF Symbol, and key letter ("" when none).
@interface SPDFAnnotateEntry : NSObject
@property(nonatomic, copy) NSString* name;
@property(nonatomic, copy) NSString* label;
@property(nonatomic, copy) NSString* symbol;
@property(nonatomic, copy) NSString* key;
@property(nonatomic, copy) NSString* hint;  // what the tool does, under its name in the tooltip ("" when the name says it)
@end

FOUNDATION_EXPORT NSArray<SPDFAnnotateEntry*>* SPDFAnnotateTools(void);    // the Tools group, left to right
FOUNDATION_EXPORT NSArray<SPDFAnnotateEntry*>* SPDFAnnotateBrushes(void);  // the nine brushes, in Paint's order
FOUNDATION_EXPORT NSArray<SPDFAnnotateEntry*>* SPDFAnnotateShapes(void);   // the 24 shapes and the arrow line
FOUNDATION_EXPORT NSArray<SPDFAnnotateEntry*>* SPDFAnnotateStyles(void);   // none, solid, crayon ... watercolor
FOUNDATION_EXPORT SPDFAnnotateEntry* _Nullable SPDFAnnotateEntryNamed(NSArray<SPDFAnnotateEntry*>* table,
                                                                      NSString* _Nullable name);
// The brush's index in spdf_paint_brush (brush = 1 ... watercolor = 9) and back.
FOUNDATION_EXPORT NSInteger SPDFAnnotateBrushIndex(NSString* name);
FOUNDATION_EXPORT NSString* SPDFAnnotateBrushName(NSInteger index);
FOUNDATION_EXPORT NSImage* _Nullable SPDFAnnotateSymbol(NSString* symbol, NSString* label);
// "Fill (F)" and, on the next line, what the tool does.
FOUNDATION_EXPORT NSString* SPDFAnnotateToolTip(SPDFAnnotateEntry* _Nullable tool, NSString* key);

#pragma mark - The document and its session

// What the active tab is, for the palette (the session's kind, else the reader's, else a PDF when Fill & Sign shows).
FOUNDATION_EXPORT SPDFAnnotateDocumentKind SPDFAnnotateCurrentKind(SPDFMacFillController* controller);
FOUNDATION_EXPORT SPDFMacAnnotateSession* _Nullable SPDFAnnotateCurrentSession(SPDFMacFillController* controller,
                                                                               BOOL create);
// The tool.choose name of what the session has chosen ("pencil", "brush", "shape", "eraser", "form_text"...).
FOUNDATION_EXPORT NSString* SPDFAnnotateChosenToolName(SPDFMacAnnotateSession* _Nullable session);
// A tool's remembered options with their defaults filled in (SPDFAnnotateSettings).
FOUNDATION_EXPORT NSDictionary* SPDFAnnotateToolOptions(NSString* tool);
// Canvas units for sizes: "px" on pictures and canvases, "pt" on PDFs.
FOUNDATION_EXPORT NSString* SPDFAnnotateUnit(SPDFAnnotateDocumentKind kind);

#pragma mark - Sending

// Sends one operation for the active tab; afterwards the palette, menus and Layers panel follow. completion may be nil.
FOUNDATION_EXPORT void SPDFAnnotateSend(SPDFMacFillController* controller, NSDictionary* op,
                                        void (^_Nullable completion)(NSDictionary* result));
// tool.choose {tool, options}: the palette, keys and menus choose tools and set their options this way.
FOUNDATION_EXPORT void SPDFAnnotateChooseTool(SPDFMacFillController* controller, NSString* tool,
                                              NSDictionary* _Nullable options);
// doc.state for what the palette and panel show (the PDF page the session follows), answered synchronously when the
// controller answers at once, else nil.
FOUNDATION_EXPORT NSDictionary* _Nullable SPDFAnnotateDocState(SPDFMacFillController* controller);
// The ids of the selected objects in a doc.state answer, front to back (empty when none).
FOUNDATION_EXPORT NSArray<NSNumber*>* SPDFAnnotateSelectedObjectIds(NSDictionary* _Nullable state);
FOUNDATION_EXPORT BOOL SPDFAnnotateStateHasPixelSelection(NSDictionary* _Nullable state);
// doc.state's layers and their objects in one list, bottom to top, as they stack: each object with "layer" (its
// layer's id), hidden when its layer is and locked when its layer is.
FOUNDATION_EXPORT NSArray<NSDictionary*>* SPDFAnnotateStateEntries(NSDictionary* _Nullable state);
// The id of the layer above (or below) the one holding objectId, when objects can go there (not the base layer, not a
// locked layer); nil at the ends.
FOUNDATION_EXPORT NSNumber* _Nullable SPDFAnnotateLayerNeighbour(NSDictionary* _Nullable state, NSNumber* _Nullable objectId,
                                                                 BOOL above);
// An operation with "page" added (1-based, the page the session follows) on a PDF when the op needs one.
FOUNDATION_EXPORT NSDictionary* SPDFAnnotateOnCurrentPage(SPDFMacFillController* controller, NSDictionary* op);

#pragma mark - The palette's UI-state operations (SPDFMacAnnotateSettings.mm)

// Called first by -applyOperation:tab:completion: for every operation. tool.choose is answered here (the tool and its
// options in the session and settings, and on a PDF Fill & Sign's own tool chosen with -chooseTool:): the answer is
// returned and nothing else should run. colors.set and palette.set_custom update the session's colours and the
// remembered custom slots, then return nil so the routing carries them on to the canvases. Anything else: nil.
FOUNDATION_EXPORT NSDictionary* _Nullable SPDFAnnotateApplyPaletteOperation(SPDFMacFillController* controller,
                                                                            NSDictionary* op,
                                                                            SPDFDocumentTab* _Nullable tab);

#pragma mark - Command items

FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandResizeSheet;     // Resize and skew...
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandCanvasSheet;     // Canvas size and properties...
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandRotateBySheet;   // Rotate by...
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandEditColors;      // the macOS colour panel
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandSaveColors;      // Save Colors...
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandGetColors;       // Get Colors...
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandSwapColors;      // X
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandDefaultColors;   // D
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandCut;             // doc.copy, then select.delete
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandCopyToFile;      // Copy to file...
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandPasteFromFile;   // Paste from file...
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandTransparent;    // Transparent selection (on / off)
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandRepeat;          // Edit > Repeat (F4)
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandLayers;          // the Layers panel
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandEditText;        // double-click a text box, from the menu
// Edit Text (the text object's context menu): tool.choose text_box is sent, then this is posted (object: the
// controller) so the canvas view opens the selected text object for typing, as a double-click does.
FOUNDATION_EXPORT NSNotificationName const SPDFAnnotateEditTextNotification;
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandNewCanvas;       // File > New Canvas
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandSave;            // File > Save
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandSaveAs;          // File > Save As...
FOUNDATION_EXPORT NSString* const SPDFAnnotateCommandDesktopPicture;  // File > Set as Desktop Picture

// In an operation's "id" or "ids": the selected objects, worked out when it runs ("id": one operation each).
FOUNDATION_EXPORT NSString* const SPDFAnnotateSelectedIds;  // "$selected"

// A menu item that does `payload` (an op, an array of ops, or a command) for the controller's active tab, or, when
// controller is nil, for the reader's (menu bar items). key "" for none.
FOUNDATION_EXPORT NSMenuItem* SPDFAnnotateItem(NSString* title, NSString* key, NSEventModifierFlags modifiers,
                                               id payload, SPDFMacFillController* _Nullable controller,
                                               ShenzhenMacDelegate* _Nullable reader);
// Carries out a payload as an item would (palette buttons, keys).
FOUNDATION_EXPORT void SPDFAnnotatePerform(SPDFMacFillController* controller, id payload);
// Paste: the clipboard's picture as a Picture object, then the Select tool, so it can be moved and resized (Paint).
FOUNDATION_EXPORT NSArray* SPDFAnnotatePastePayload(void);
// Whether an item's payload can run now; *tooltip gets "The page itself can't be changed." when the reason is the page.
FOUNDATION_EXPORT BOOL SPDFAnnotatePayloadEnabled(SPDFMacFillController* _Nullable controller, id payload,
                                                  NSString* _Nullable* _Nullable tooltip);

// The menus several places show (the palette's ▾ buttons, the menu bar, the context menus), built fresh each time.
FOUNDATION_EXPORT NSMenu* SPDFAnnotateSelectionMenu(SPDFMacFillController* _Nullable controller,
                                                    ShenzhenMacDelegate* _Nullable reader);
FOUNDATION_EXPORT NSMenu* SPDFAnnotateRotateMenu(SPDFMacFillController* _Nullable controller,
                                                 ShenzhenMacDelegate* _Nullable reader, NSString* scope);
FOUNDATION_EXPORT NSMenu* SPDFAnnotateFlipMenu(SPDFMacFillController* _Nullable controller,
                                               ShenzhenMacDelegate* _Nullable reader, NSString* scope);
// Image: Crop, Resize and skew..., Rotate, Flip, Invert colors, Remove background (macOS 14 and later), Canvas size
// and properties..., Clear image.
FOUNDATION_EXPORT NSMenu* SPDFAnnotateImageMenu(SPDFMacFillController* _Nullable controller,
                                                ShenzhenMacDelegate* _Nullable reader);
// The Tools group's tools, each with its key.
FOUNDATION_EXPORT NSMenu* SPDFAnnotateToolsMenu(SPDFMacFillController* _Nullable controller,
                                                ShenzhenMacDelegate* _Nullable reader);
FOUNDATION_EXPORT BOOL SPDFAnnotateCanRemoveBackground(void);  // macOS 14 and later (Vision's subject mask)
FOUNDATION_EXPORT NSMenu* SPDFAnnotateBrushMenu(SPDFMacFillController* _Nullable controller,
                                                ShenzhenMacDelegate* _Nullable reader);
FOUNDATION_EXPORT NSMenu* SPDFAnnotateShapeMenu(SPDFMacFillController* _Nullable controller,
                                                ShenzhenMacDelegate* _Nullable reader);
// Outline or Fill styles: each item sets the Shapes tool's option, and restyles the selected shape (objectId > 0).
FOUNDATION_EXPORT NSMenu* SPDFAnnotateStyleMenu(SPDFMacFillController* _Nullable controller, BOOL outline,
                                                NSInteger objectId);

NS_ASSUME_NONNULL_END
