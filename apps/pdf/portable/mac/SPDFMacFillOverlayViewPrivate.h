#pragma once
// What the overlay's interaction category (SPDFMacFillOverlayView+Interaction.mm) shares with its drawing.
#import "SPDFMacFillOverlayView.h"

@class SPDFDocumentView;

@interface SPDFMacFillOverlayView ()
@property(nonatomic, strong) SPDFFillItem* hoverItem;
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

@interface SPDFMacFillOverlayView (Interaction)
- (void)trackItem:(SPDFFillItem*)item page:(NSInteger)index from:(NSPoint)start event:(NSEvent*)event;
@end
