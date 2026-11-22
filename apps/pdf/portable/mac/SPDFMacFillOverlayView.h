#pragma once
// The layer Fill & Sign draws and listens on: a transparent view over the page viewport (a subview of the reader's
// scroll view, above its clip view), so it stays the size of the window, scrolls nothing itself and hands scroll and
// zoom gestures on to the scroll view. Page geometry comes from the document view on every draw, so tab switches,
// zoom and scrolling need no bookkeeping. It draws the tint of the form's fields, the target under the pointer, the
// selection, and hosts the text editor.
#import <Cocoa/Cocoa.h>

#import "SPDFMacFillModel.h"

@class SPDFMacFillController;

@interface SPDFMacFillOverlayView : NSView
@property(nonatomic, weak) SPDFMacFillController* controller;
@property(nonatomic, strong) SPDFFillItem* selectedItem;
@property(nonatomic, strong) SPDFFillField* focusedField;
// A drawn box or line Tab moved to on a page without fields (page space), or NSZeroRect.
@property(nonatomic) NSRect focusedTargetRect;
@property(nonatomic) NSInteger focusedTargetPage;

- (void)attachToScrollView:(NSScrollView*)scrollView;
- (void)refresh;
- (void)clearTransientState;
- (NSRect)viewRectForPageRect:(NSRect)rect page:(NSInteger)page;
- (BOOL)locateViewPoint:(NSPoint)point page:(NSInteger*)page pagePoint:(NSPoint*)pagePoint;
- (NSArray<NSNumber*>*)visiblePages;
- (CGFloat)zoom;  // view points per page point
- (void)revealPageRect:(NSRect)rect page:(NSInteger)page;
// Snap for a placement at a page point with the current tool (free placement when snapping is off or not loaded).
- (spdf_snap_kind)resolveAt:(NSPoint)point page:(NSInteger)page purpose:(spdf_snap_purpose)purpose
                      aspect:(CGFloat)aspect snapping:(BOOL)snapping result:(spdf_snap_result*)result;
@end

@interface SPDFMacFillOverlayView (Keys)
// A typed key this layer acts on (Space toggles, X and V switch a mark): the window's type-to-search leaves it alone.
- (BOOL)handlesTypedKey:(NSEvent*)event;
// Takes the keys when the pages had them, so Tab, Space, X and V work without a click first.
- (void)takeKeysFromPages;
@end

// Pen lines and arrows on the overlay (SPDFMacFillOverlayView+Drawing.mm).
@interface SPDFMacFillOverlayView (Drawing)
// Before a change is written: keep drawing `ink` and cover `washes` with the paper colour until a page image made
// after the write is on screen.
- (void)holdInk:(NSArray<SPDFFillItem*>*)ink washes:(NSArray<SPDFFillItem*>*)washes;
- (void)dropDrawingHolds;
@end

// Shared drawing of a check or a cross inside rect (y down).
NSBezierPath* SPDFFillMarkPath(NSRect rect, BOOL cross);
