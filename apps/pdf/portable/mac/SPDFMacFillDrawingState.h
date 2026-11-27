#pragma once
// What the overlay's drawing tools keep between events (SPDFMacFillOverlayView+Drawing.mm draws it in
// +DrawingLayer.mm): the gesture in progress, and the lines it keeps drawing or covering after a change until the
// page image shows the change. Page space throughout.
#import "SPDFMacFillOverlayViewPrivate.h"

@class SPDFRenderedPage;

// A line kept on screen (ink) or covered with the paper colour (wash) until the page image catches up.
@interface SPDFFillHold : NSObject
@property(nonatomic, strong) SPDFFillItem* item;
@property(nonatomic) BOOL wash;
@property(nonatomic, weak) SPDFRenderedPage* before;  // the page image when the change was written
@property(nonatomic) BOOL hadBefore;
@property(nonatomic, weak) id beforeImage, beforeViewportImage;  // its pictures then (a change patches them in place)
@property(nonatomic) NSTimeInterval deadline;
@end

@interface SPDFFillDrawingState : NSObject
@property(nonatomic) NSInteger page;                       // the page of the gesture in progress, or -1
@property(nonatomic, strong) SPDFFillItem* live;           // the pen line or arrow being drawn
@property(nonatomic) BOOL hasLiveTail;                     // pen: a straight piece from the line to the pointer
@property(nonatomic) NSPoint liveTail;
@property(nonatomic, strong) NSMutableArray<SPDFFillItem*>* erasing;  // whole lines the eraser touched
@property(nonatomic, strong) NSMutableData* swath;         // the eraser's path (spdf_fill_point)
@property(nonatomic) CGFloat swathRadius;                  // parts: the eraser's radius
@property(nonatomic) BOOL banding;
@property(nonatomic) NSRect band;
@property(nonatomic, strong) NSArray<SPDFFillItem*>* moving;  // items being dragged or nudged
@property(nonatomic) NSSize delta;
@property(nonatomic) BOOL nudging;
@property(nonatomic, strong) SPDFFillItem* endArrow;       // an arrow whose end is being dragged
@property(nonatomic, strong) SPDFFillItem* endPreview;
@property(nonatomic, strong) NSMutableArray<SPDFFillHold*>* holds;
@property(nonatomic, strong) id holdObserver;  // checks the holds before each screen update while there are any
@property(nonatomic, strong) NSTimer* holdTimer;  // the deadline
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSCursor*>* cursors;
@end

// SPDFMacFillOverlayView.mm.
@interface SPDFMacFillOverlayView (Pages)
- (SPDFRenderedPage*)renderedPage:(NSInteger)index;
@end

@interface SPDFMacFillOverlayView (DrawingShared)
- (SPDFFillDrawingState*)drawingState;
- (CGAffineTransform)pageToView:(NSInteger)page;
- (NSPoint)pagePointForViewPoint:(NSPoint)point page:(NSInteger)page;  // clamped to the page
// The line as drawn on screen (view space): its width at this zoom plus `extra`, round caps and joins.
- (NSBezierPath*)viewPathForItem:(SPDFFillItem*)item extra:(CGFloat)extra;
- (NSColor*)inkColorForItem:(SPDFFillItem*)item;
- (NSCursor*)drawingCursorForTool:(SPDFFillTool)tool;
@end
