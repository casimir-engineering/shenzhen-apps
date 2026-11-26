#pragma once
// What the overlay's interaction category (SPDFMacFillOverlayView+Interaction.mm) shares with its drawing.
#import "SPDFMacFillOverlayView.h"

@class SPDFDocumentView;

@interface SPDFMacFillOverlayView ()
@property(nonatomic, strong) SPDFFillItem* hoverItem;
@property(nonatomic, strong) NSCursor* hoverCursor;  // what the last hover chose (SPDFApplyCursorOverlay asks for it)
@property(nonatomic, strong) SPDFFillItem* dragItem;  // being dragged or resized
@property(nonatomic) NSRect dragRect;
- (SPDFDocumentView*)documentView;
- (SPDFFillItem*)itemAt:(NSPoint)p page:(NSInteger)index;
- (NSRect)resizeHandleForViewRect:(NSRect)r;
- (void)updateHover:(NSPoint)point modifiers:(NSEventModifierFlags)modifiers;
@end

// The drawing tools' hooks in the overlay (SPDFMacFillOverlayView+Drawing.mm).
@interface SPDFMacFillOverlayView (DrawingHooks)
- (BOOL)drawingMouseDown:(NSEvent*)event;       // YES: a drawing tool took the click
- (BOOL)drawingRightMouseDown:(NSEvent*)event;  // YES: the Select tool's menu
- (BOOL)drawingHover:(NSPoint)point;            // YES: a drawing tool set the pointer
- (BOOL)drawingsAnswerPointer;                  // pen lines and arrows can be clicked (Select, Eraser)
- (BOOL)drawing:(SPDFFillItem*)item isNear:(NSPoint)pagePoint;
- (void)cancelDrawingGesture;
@end

// The drawing tools' keys (SPDFMacFillOverlayView+Interaction.mm).
@interface SPDFMacFillOverlayView (DrawingKeys)
- (BOOL)drawingKeyDown:(NSEvent*)event;  // YES: handled (tool letters, Delete, nudges, Escape)
- (void)commitNudge;                     // writes a run of arrow-key moves
@end

@interface SPDFMacFillOverlayView (DrawingPaint)
- (void)drawDrawingLayer;  // SPDFMacFillOverlayView+DrawingLayer.mm
@end

// Annotate's tools on the pages (SPDFMacFillOverlayView+Annotate.mm): events handed to the canvas view under the overlay.
@interface SPDFMacFillOverlayView (Annotate)
- (BOOL)annotateTakeMouseDown:(NSEvent*)event;  // YES: the canvas view took it and the gesture it starts
- (BOOL)annotateMouseMoved:(NSEvent*)event;
- (BOOL)annotateKeyDown:(NSEvent*)event;  // Delete and the arrows on Annotate's selected objects; YES: handled
- (void)annotateAttachCanvasView;
@end

@interface SPDFMacFillOverlayView (Interaction)
- (void)trackItem:(SPDFFillItem*)item page:(NSInteger)index from:(NSPoint)start event:(NSEvent*)event;
@end
