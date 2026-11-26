#pragma once
// Fill & Sign in the reader (docs/plans/fill-and-sign.md): the toolbar button and menu items, turning it on by itself
// for a PDF with its own form once the first page has painted, and the reader services the controller uses (saving,
// redrawing a changed page, the writable copy and Collection version before the first change).
//
// Launch cost: the button and two menu items are built with the window; everything else is created the first time
// Fill & Sign is used or a form PDF settles. A PDF without a form costs one bounded read of its form dictionary on the
// main-thread document after first paint (no page is loaded) and nothing else.
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacFillSaving.h"

@interface ShenzhenMacDelegate (SPDFMacFill)
- (void)toggleFillAndSign:(id)sender;
- (void)saveFinalCopy:(id)sender;
- (BOOL)fillSignAvailable;
- (BOOL)fillSignShowing;
- (BOOL)fillSignCanAddItems;
// The document holds pen lines and arrows (drawingsOnly) or anything Fill & Sign added, written or waiting.
- (BOOL)fillSignHasAddedItemsDrawingsOnly:(BOOL)drawingsOnly;
// A field of the PDF's own form holds a value Fill & Sign put there.
- (BOOL)fillSignHasFilledFields;
// Edit menu: every pen line and arrow, or everything Fill & Sign added (the values it put in the form's own fields
// included, which go back to what they held before), in the document; each one undo step.
- (void)removeAllPenLinesAndArrows:(id)sender;
- (void)removeEverythingAddedWithFillSign:(id)sender;
// After first paint of a document (the metadata stage): reads whether the PDF has a form and turns Fill & Sign on.
- (void)fillSignDocumentDidSettle;
// The document view was replaced for another tab.
- (void)fillSignActiveDocumentChanged;
// Before the active document is left (rememberActiveTabState): what is being typed is written into the file.
- (void)fillSignFlushEdits;
// The toolbar chrome synced: keep the overlay and palette in step (presentation mode, Markdown tabs).
- (void)fillSignChromeDidSync;
@end

void SPDFFillInstallMenuItems(NSMenu* editMenu, NSMenu* fileMenu, ShenzhenMacDelegate* reader);
