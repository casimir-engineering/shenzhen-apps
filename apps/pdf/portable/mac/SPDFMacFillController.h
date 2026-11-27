#pragma once
// Fill & Sign, one per window, created the first time Fill & Sign is used or a form PDF settles (never at launch).
// It owns the overlay over the pages, the palette, the text editor and the per-tab sessions, and turns clicks into
// core calls on the main-thread document (docs/plans/fill-and-sign.md, UI).
#import <Cocoa/Cocoa.h>

#import "SPDFMacFillModel.h"

#include "shenzhen_pdf_core.h"

@class SPDFDocumentView, SPDFDocumentTab, SPDFMacFillOverlayView, SPDFMacFillPalette, SPDFMacFillEditor;

// What the reader gives Fill & Sign (implemented by ShenzhenMacDelegate in SPDFMacFillIntegration.mm).
@protocol SPDFMacFillHost <NSObject>
- (spdf_document*)fillDocument;
- (NSString*)fillPath;
- (NSString*)fillWorkingPath;
- (SPDFDocumentTab*)fillTab;
- (NSScrollView*)fillScrollView;
- (NSView*)fillContainer;
- (NSWindow*)fillWindow;
- (BOOL)fillHidden;  // presentation mode, a Markdown tab, no document
- (CGFloat)fillZoom;
- (NSString*)fillAuthor;
- (BOOL)fillDarkPages;  // the reading theme shows pages dark
- (BOOL)fillDarkPagesKeepImages;  // and leaves their pictures in their own colours
// The picture of a page shown now: pixels, the part of the page it covers, where (SPDFMacFillShowFirst.h).
- (NSSize)fillShownPictureOfPage:(NSInteger)page covering:(NSRect*)covering drawnAt:(NSRect*)drawn;
// Before the first change of a burst: the owner's permissions, a signed or certified PDF, then a Collection version
// or a writable copy. fieldValuesOnly: only the PDF's own fields change (no placed items). NO: nothing may change.
- (BOOL)fillPrepareForChangeOfFieldsOnly:(BOOL)fieldValuesOnly;
// After a change in the document, first: these pages drawn again from the document in memory, then (once the
// overlay is up to date) the window shown, so the change is on screen in the next frame.
// areas: for some pages the part that changed (page points from the top-left corner): only that part is drawn again.
- (void)fillShowPagesNow:(NSIndexSet*)pages areas:(NSDictionary<NSNumber*, NSValue*>*)areas;
- (void)fillDisplayNow;
// Then: the file is saved once the changes rest, and these pages drawn again at full quality (SPDFMacFillSaving.h).
- (void)fillScheduleSaveOfPages:(NSIndexSet*)pages;
- (void)fillShowError:(NSString*)title detail:(NSString*)detail;
- (spdf_document*)fillOpenReadDocumentAtPath:(NSString*)path error:(char*)err length:(size_t)len;
- (void)fillStateDidChange;
// The document is the app's own copy of a file that couldn't be changed where it is.
- (BOOL)fillIsEditedCopy;
// The file can't be changed where it is: the first change moves the tab to the app's own copy.
- (BOOL)fillWillFillACopy;
// The palette's line when the document is (or the first change makes it) the app's own copy, saying why; else nil.
- (NSString*)fillEditedCopyNote;
// A press with a drawing tool: a change may follow, so the objects its save reads start being read ahead.
- (void)fillPrepareSaveWhenIdle;
// Keeps this much room above the first page, so the palette can be scrolled clear of it (0: none).
- (void)fillSetPageTopReserve:(CGFloat)reserve;
@end

@interface SPDFMacFillController : NSObject
@property(nonatomic, weak, readonly) id<SPDFMacFillHost> host;
@property(nonatomic, strong, readonly) SPDFMacFillOverlayView* overlay;
@property(nonatomic, strong, readonly) SPDFMacFillPalette* palette;
@property(nonatomic, strong, readonly) SPDFMacFillEditor* editor;

- (instancetype)initWithHost:(id<SPDFMacFillHost>)host;

// The active tab's session (created on demand) and whether Fill & Sign shows for it.
- (SPDFFillSession*)session;
- (BOOL)isShowing;
- (void)setOn:(BOOL)on;
// Annotate on for a tab that is not in front (an agent's operations on it): it shows when the tab is chosen.
+ (void)turnOnForTab:(SPDFDocumentTab*)tab;
// The active tab or its document changed: drop caches, close the editor, show or hide for the new tab.
- (void)activeDocumentChanged;
// Writes what the open editor holds into the document now (before the document is left), keeping the editor open.
- (void)flushEditor;
// Commits and closes the editor and drops the picked-up signature (Done, another tool).
- (void)endInteraction;
- (void)refreshChrome;

// Page data, read from the main-thread document and cached until a change on that page.
- (NSArray<SPDFFillField*>*)fieldsOnPage:(NSInteger)page;
- (NSArray<SPDFFillItem*>*)itemsOnPage:(NSInteger)page;
// Snap geometry: NULL while it loads in the background (the overlay redraws when it arrives).
- (const spdf_snap_geometry*)geometryForPage:(NSInteger)page;
// The same, read now when it isn't there yet: an agent's text or mark lands where a click would put it at once.
- (const spdf_snap_geometry*)geometryForPageNow:(NSInteger)page;
- (void)invalidatePage:(NSInteger)page;
- (NSInteger)pageCount;
// "3 of 12 filled", or nil for a PDF without its own fields.
- (NSString*)progressText;
@end

// Changes (SPDFMacFillController+Edits.mm). Each one checks, writes, saves, redraws and can be undone.
@interface SPDFMacFillController (Edits)
- (BOOL)setText:(NSString*)text forField:(SPDFFillField*)field;
- (BOOL)setOn:(BOOL)on forField:(SPDFFillField*)field;
- (BOOL)setChoice:(NSString*)choice forField:(SPDFFillField*)field;
- (SPDFFillItem*)addTextItem:(NSString*)text page:(NSInteger)page rect:(NSRect)rect size:(CGFloat)size;
- (BOOL)addCombText:(NSString*)text page:(NSInteger)page cells:(NSArray<NSValue*>*)cells size:(CGFloat)size;
- (BOOL)addMarkOnPage:(NSInteger)page box:(NSRect)box cross:(BOOL)cross;
- (SPDFFillItem*)addSignature:(SPDFMacSignature*)signature page:(NSInteger)page rect:(NSRect)rect;
- (BOOL)updateItem:(SPDFFillItem*)item rect:(NSRect)rect;
- (BOOL)updateItem:(SPDFFillItem*)item text:(NSString*)text size:(CGFloat)size;
- (BOOL)setItem:(SPDFFillItem*)item cross:(BOOL)cross;
- (BOOL)deleteItem:(SPDFFillItem*)item;
- (void)undo;
- (void)redo;
- (BOOL)canUndo;
- (BOOL)canRedo;
@end

// Clicks, keys and the editor (SPDFMacFillController+Interaction.mm).
@interface SPDFMacFillController (Interaction)
- (void)clickOnPage:(NSInteger)page at:(NSPoint)point modifiers:(NSEventModifierFlags)modifiers;
- (void)openEditorForField:(SPDFFillField*)field;
- (void)openEditorForItem:(SPDFFillItem*)item;
- (void)placeSignatureInField:(SPDFFillField*)field;
- (void)pickUpSignature:(SPDFMacSignature*)signature;
- (void)addSignatureWithInitials:(BOOL)initials;
- (void)showChoiceMenuForField:(SPDFFillField*)field;
- (void)editMyDetails;
@end

// Pen lines, arrows, the eraser and the Select tool (SPDFMacFillController+Drawing.mm). Each change is one undo step.
@interface SPDFMacFillController (Drawing)
// Picks a tool from the palette or a key: writes what is pending, closes the text box. The Eraser chosen again
// switches between whole lines and parts.
- (void)chooseTool:(SPDFFillTool)tool;
// Lines just drawn: written together once the pointer has rested a moment, or sooner (flushPendingChanges).
- (void)addDrawnStrokes:(NSArray<SPDFFillItem*>*)strokes;
- (NSArray<SPDFFillItem*>*)pendingStrokesOnPage:(NSInteger)page;
- (BOOL)hasPendingStrokes;
- (void)postponePendingStrokes;
- (void)writePendingStrokes;
- (void)discardPendingStrokes;
// The text box and the lines waiting: written now (before the document is left, a tool change, a Command key).
- (void)flushPendingChanges;
// The Select tool's selection, on one page.
- (NSArray<SPDFFillItem*>*)selectedItems;
- (void)selectItems:(NSArray<SPDFFillItem*>*)items page:(NSInteger)page;
- (BOOL)selectionHasDrawings;
// The colour and width the selection's lines and arrows share (indexes of SPDFMacFillDrawingStyle), -1 when they
// differ or there are none.
- (NSInteger)selectionColorIndex;
- (NSInteger)selectionWidthIndex;
- (BOOL)removeItems:(NSArray<SPDFFillItem*>*)items;
// The eraser cutting lines: the originals go, the pieces left are written, as one change.
- (BOOL)replaceItems:(NSArray<SPDFFillItem*>*)removed withStrokes:(NSArray<SPDFFillItem*>*)strokes;
- (BOOL)moveItems:(NSArray<SPDFFillItem*>*)items by:(NSSize)delta;
// -1 keeps an item's own colour or width.
- (void)restyleSelectionWithColor:(NSInteger)colorIndex width:(NSInteger)widthIndex;
- (BOOL)setArrow:(SPDFFillItem*)arrow tail:(NSPoint)tail tip:(NSPoint)tip;
// Edit menu: every pen line and arrow on every page.
- (void)removeAllDrawings;
@end

// Edit menu: everything Fill & Sign added on every page, and every field it filled in put back to what it held
// before (SPDFMacFillController+RemoveEverything.mm). One undo step.
@interface SPDFMacFillController (RemoveEverything)
- (void)removeEverythingAdded;
@end

// Keyboard focus and Tab (SPDFMacFillController+Focus.mm).
@interface SPDFMacFillController (Focus)
- (void)moveFocusForward:(BOOL)forward;
- (BOOL)isFieldFocused:(SPDFFillField*)field;
- (void)toggleFocusedField;
@end
