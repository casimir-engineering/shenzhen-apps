#pragma once
// What SPDFMacAnnotateMenus.mm adds beside the functions SPDFMacAnnotateIntegration.h declares: the hooks the Fill & Sign
// overlay calls so Annotate's letter keys win over type-to-search, and its edit actions (Cut, Copy, Paste, Select
// All, Undo, Redo) reach Annotate while it shows.
#import <Cocoa/Cocoa.h>

@class SPDFMacFillController, ShenzhenMacDelegate;

NS_ASSUME_NONNULL_BEGIN

// YES when SPDFAnnotateHandleKey would take this key (a tool letter, X, D, [ or ]), without doing anything:
// -[SPDFMacFillOverlayView handlesTypedKey:] claims it so typing it does not start a search.
FOUNDATION_EXPORT BOOL SPDFAnnotateClaimsKey(NSEvent* event, SPDFMacFillController* controller);
// cut:, copy:, paste:, selectAll:, undo:, redo: while Annotate shows: YES when it became an operation (Annotate has a
// selection or a canvas tool is chosen); NO leaves the action to the reader as before.
FOUNDATION_EXPORT BOOL SPDFAnnotatePerformEditAction(SEL action, SPDFMacFillController* controller);
// The toolbar button's pencil-and-brush picture (a template image).
FOUNDATION_EXPORT NSImage* SPDFAnnotateButtonImage(void);

NS_ASSUME_NONNULL_END
