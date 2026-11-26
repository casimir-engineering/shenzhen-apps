#pragma once
// What the canvas view's files share: SPDFMacAnnotateCanvasView.mm (geometry, tiles, drawing), +Gestures.mm (mouse,
// keys, the text box), +Decorations.mm (ants, handles, preview, canvas handles, rulers, grid, thumbnail).
#import "SPDFMacAnnotateCanvasView.h"

#import "SPDFMacFillController+Annotate.h"

@class SPDFDocumentView;

typedef NS_ENUM(NSInteger, SPDFAnnotateGesture) {
    SPDFAnnotateGestureNone = 0,
    SPDFAnnotateGesturePendingRight,  // right button down, not moved yet: a menu on release, a Color 2 drag if it moves
    SPDFAnnotateGestureStroke,        // pencil, brushes, pixel eraser, color eraser, pen, whole-line eraser
    SPDFAnnotateGestureShape,         // a shape's box or line, the arrow
    SPDFAnnotateGestureRectSelect,
    SPDFAnnotateGestureLasso,
    SPDFAnnotateGestureBoxSelect,     // Select dragged from empty canvas: every object it touches
    SPDFAnnotateGestureMove,          // selected objects (or a lifted selection) dragged
    SPDFAnnotateGestureResize,        // an object's handle
    SPDFAnnotateGestureRotate,        // an object's rotation handle
    SPDFAnnotateGestureCanvasResize,  // a canvas handle
    SPDFAnnotateGestureTextBox,       // the text box's frame being dragged
    SPDFAnnotateGesturePolygon,       // corners clicked one by one
    SPDFAnnotateGestureCurve          // the line drawn, then two bends
};

// Handles of a box: 0-7 clockwise from the top-left corner, 8 the rotation handle. Canvas handles: right, bottom,
// corner.
typedef NS_ENUM(NSInteger, SPDFAnnotateCanvasHandle) {
    SPDFAnnotateCanvasHandleNone = 0,
    SPDFAnnotateCanvasHandleRight,
    SPDFAnnotateCanvasHandleBottom,
    SPDFAnnotateCanvasHandleCorner
};

@interface SPDFMacAnnotateCanvasView ()
@property(nonatomic, weak, readwrite) SPDFMacFillController* controller;
@property(nonatomic, weak, readwrite) SPDFMacFillOverlayView* overlay;
@property(nonatomic, readwrite) BOOL holdsLastFrame;
@property(nonatomic, readwrite) BOOL hasPointer;
@property(nonatomic, readwrite) NSPoint pointerPoint;
@property(nonatomic, readwrite) NSInteger pointerPage;
@property(nonatomic, readwrite) NSSize liveResizeSize;

// The gesture in progress (canvas units on gesturePage).
@property(nonatomic) SPDFAnnotateGesture gesture;
@property(nonatomic) NSInteger gesturePage;
@property(nonatomic) BOOL rightButton;
@property(nonatomic) NSPoint startView;
@property(nonatomic) NSPoint startPoint;
@property(nonatomic) NSPoint currentPoint;
@property(nonatomic, strong) NSMutableArray<NSValue*>* points;    // canvas units
@property(nonatomic, strong) NSMutableArray<NSNumber*>* pressures;
@property(nonatomic) NSInteger handle;
@property(nonatomic) SPDFAnnotateCanvasHandle canvasHandle;
@property(nonatomic) NSRect originalRect;   // the object's box when the drag began
@property(nonatomic) CGFloat originalRotation;
@property(nonatomic, copy) NSArray<NSNumber*>* dragObjects;
@property(nonatomic) NSEventModifierFlags gestureModifiers;

// The text box being typed in.
@property(nonatomic, strong) NSTextView* textEditor;
@property(nonatomic) NSRect textRect;  // canvas units
@property(nonatomic) NSInteger textPage;
@property(nonatomic, strong) NSNumber* textObject;  // the text object being edited again, or nil for a new one

@property(nonatomic, strong) SPDFDocumentView* zoomWatched;  // whose zoom is observed (SPDFMacAnnotateCanvasView.mm)
@property(nonatomic) CGFloat antsPhase;
@property(nonatomic) NSRect shownSelectionRect;  // the selection box and its handles as last asked to be drawn
@property(nonatomic, strong) NSTimer* antsTimer;

// Geometry (SPDFMacAnnotateCanvasView.mm).
- (spdf_paint_doc*)docForPage:(NSInteger)page;
- (NSRect)canvasRectForPage:(NSInteger)page;  // the whole canvas in view points
- (CGFloat)scaleForPage:(NSInteger)page;      // view points per canvas unit
- (SPDFDocumentView*)documentView;           // the reader's page view under the canvas view
- (NSArray<NSNumber*>*)pagesInView;            // -1 for a picture
- (NSRect)viewRectForCanvasRect:(NSRect)rect page:(NSInteger)page;
- (NSPoint)viewPointForCanvasPoint:(NSPoint)point page:(NSInteger)page;
- (void)redrawCanvasRect:(NSRect)rect page:(NSInteger)page inflate:(CGFloat)points;
- (void)operation:(NSDictionary*)op page:(NSInteger)page done:(void (^)(NSDictionary* result))done;
// Objects of the page's doc.state, front first: {"id", "kind", "name", "bounds" (canvas NSRect value), "rect",
// "rotation", "object" (the state's dictionary)}.
- (NSArray<NSDictionary*>*)objectsOnPage:(NSInteger)page;
- (NSRect)boundsOfObjects:(NSArray<NSNumber*>*)ids page:(NSInteger)page;
- (NSDictionary*)selectionOnPage:(NSInteger)page;  // the state's "selection", or nil
@end

@interface SPDFMacAnnotateCanvasView (Decorations)
- (void)drawDecorationsInRect:(NSRect)dirty;
- (void)drawCheckerboardInRect:(NSRect)rect;
- (NSInteger)objectHandleAt:(NSPoint)viewPoint;  // -1, 0-7, 8 rotation
- (SPDFAnnotateCanvasHandle)canvasHandleAt:(NSPoint)viewPoint;
- (NSRect)selectedObjectsViewRect;
- (void)updateAntsTimer;
- (NSRect)resizedRect;         // canvas units, from the handle being dragged
- (CGFloat)rotationDelta;      // degrees, from the rotation handle being dragged
- (NSRect)gestureCanvasRect;   // the box from startPoint to currentPoint (Shift: square)
- (NSPoint)constrainedEnd;     // currentPoint, at 45 degree steps with Shift
- (BOOL)shiftStraightensStroke:(NSEvent*)event;  // Shift held: the stroke is one straight line from the press
- (void)straightenStrokeTo:(NSPoint)point;       // press point -> point (Pencil and brushes at 45 degree steps)
@end

@interface SPDFMacAnnotateCanvasView (Rulers)
- (void)drawRulersOnPage:(NSInteger)page;
- (void)drawGridlinesInRect:(NSRect)dirty page:(NSInteger)page;
- (void)drawThumbnail;
@end

@interface SPDFMacAnnotateCanvasView (Gestures)
- (NSDictionary*)toolOptions;        // the chosen tool's settings (SPDFAnnotateSettings)
- (CGFloat)toolSize;
- (NSString*)colorFor:(BOOL)second;  // "#RRGGBB" of Color 2 (YES) or Color 1
- (NSDictionary*)objectAt:(NSPoint)point page:(NSInteger)page;
@end

// +Finishing.mm: the operations a finished gesture or a click sends, the pointer, the keys.
@interface SPDFMacAnnotateCanvasView (Finishing)
// Select on a PDF is Fill & Sign's, except on Annotate's own objects (shapes, text boxes, pictures, pen lines) and the
// handles of what Annotate selected: YES there, so the canvas takes the press.
- (BOOL)takesSelectPressAt:(NSPoint)viewPoint;
- (void)resizeSelectionTo:(NSRect)rect page:(NSInteger)page;  // object.transform of each selected object
- (void)finishStrokeOnPage:(NSInteger)page right:(BOOL)right;
- (void)finishPolygonOnPage:(NSInteger)page;
- (void)clickWithTool:(SPDFAnnotateTool)tool at:(NSPoint)point page:(NSInteger)page right:(BOOL)right
                event:(NSEvent*)event;
- (void)notePointer:(NSPoint)point page:(NSInteger)page inside:(BOOL)inside;
@end

// +Curve.mm: the Curve, drawn as a line and then bent twice (classic Paint).
@interface SPDFMacAnnotateCanvasView (Curve)
- (void)curveReleasedAt:(NSPoint)point page:(NSInteger)page moved:(BOOL)moved;
- (void)finishCurveOnPage:(NSInteger)page;  // also Return, with fewer bends
- (NSBezierPath*)curvePreviewOnPage:(NSInteger)page;
@end

// +TextBox.mm: the text box being typed in.
@interface SPDFMacAnnotateCanvasView (TextBox)
- (void)openTextEditorAt:(NSRect)rect page:(NSInteger)page object:(NSNumber*)object text:(NSString*)text;
- (void)editTextObject:(NSDictionary*)object page:(NSInteger)page;
- (void)editTextRequested:(NSNotification*)note;
- (void)layoutTextEditor;
@end

// Operation arguments: a point as [x, y] (two decimals), a box as {x, y, w, h} (at least 1 x 1).
static inline NSArray* SPDFAnnotatePointArray(NSPoint p) {
    return @[@(round(p.x * 100) / 100), @(round(p.y * 100) / 100)];
}
static inline NSDictionary* SPDFAnnotateRectObject(NSRect r) {
    return @{@"x": @(NSMinX(r)), @"y": @(NSMinY(r)), @"w": @(MAX(1, NSWidth(r))), @"h": @(MAX(1, NSHeight(r)))};
}
