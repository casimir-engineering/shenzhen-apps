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
// Before the first change of a burst: the owner's permissions, a signed or certified PDF, then a Collection version
// or a writable copy. fieldValuesOnly: only the PDF's own fields change (no placed items). NO: nothing may change.
- (BOOL)fillPrepareForChangeOfFieldsOnly:(BOOL)fieldValuesOnly;
// After a change in the document: saves it and redraws these pages.
- (BOOL)fillSaveAndRedrawPages:(NSIndexSet*)pages;
- (void)fillShowError:(NSString*)title detail:(NSString*)detail;
- (spdf_document*)fillOpenReadDocumentAtPath:(NSString*)path error:(char*)err length:(size_t)len;
- (void)fillStateDidChange;
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
- (void)moveFocusForward:(BOOL)forward;
- (BOOL)isFieldFocused:(SPDFFillField*)field;
- (void)toggleFocusedField;
- (void)showChoiceMenuForField:(SPDFFillField*)field;
- (void)editMyDetails;
@end
