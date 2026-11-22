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

@interface SPDFMacFillOverlayView (Interaction)
- (void)trackItem:(SPDFFillItem*)item page:(NSInteger)index from:(NSPoint)start event:(NSEvent*)event;
@end
