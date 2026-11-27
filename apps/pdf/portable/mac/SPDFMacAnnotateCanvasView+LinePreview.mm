// The Pen's line and the Arrow while the button is held (SPDFMacAnnotateCanvasView.h). They are drawn as the core draws
// the object the release adds (line_path in spdf_paint_composite.c): the same smoothing, arrow head, width and colour
// (the Pen row's colour, Color 2 with the right button), so the release changes nothing on screen. They were drawn in
// Color 1 as a thin polyline, which on a canvas's dark checkerboard did not show until the release.
#import "SPDFMacAnnotateCanvasViewPrivate.h"

#import "SPDFMacAnnotateImageIO.h"
#import "SPDFMacAnnotateSessionPrivate.h"
#include "spdf_fill_ink_geometry.h"

static spdf_fill_point InkPoint(NSPoint p) { return (spdf_fill_point){(float)p.x, (float)p.y}; }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation SPDFMacAnnotateCanvasView (LinePreview)

- (BOOL)previewsLineObject {
    SPDFAnnotateTool tool = self.session.tool;
    return (self.gesture == SPDFAnnotateGestureStroke && tool == SPDFAnnotateToolPen) ||
           (self.gesture == SPDFAnnotateGestureShape && tool == SPDFAnnotateToolArrow);
}

// The canvas-unit path the release's pen.add or arrow.add will draw.
- (NSBezierPath*)lineObjectCanvasPath {
    NSBezierPath* path = [NSBezierPath bezierPath];
    if (self.session.tool == SPDFAnnotateToolArrow) {
        spdf_fill_point tail = InkPoint(self.startPoint), tip = InkPoint([self constrainedEnd]), head[3];
        spdf_ink_arrow_head(tail, tip, (float)[self toolSize], head);
        [path moveToPoint:NSMakePoint(tail.x, tail.y)];
        [path lineToPoint:NSMakePoint(tip.x, tip.y)];
        [path moveToPoint:NSMakePoint(head[0].x, head[0].y)];
        [path lineToPoint:NSMakePoint(head[1].x, head[1].y)];
        [path lineToPoint:NSMakePoint(head[2].x, head[2].y)];
        return path;
    }
    NSArray<NSValue*>* points = self.points;
    NSUInteger n = points.count;
    if (!n) return path;
    [path moveToPoint:points[0].pointValue];
    if (n == 1) [path lineToPoint:points[0].pointValue];
    spdf_fill_point out[64];
    for (NSUInteger i = 0; i + 1 < n; i++) {
        spdf_fill_point p0 = InkPoint(points[i > 0 ? i - 1 : i].pointValue), p1 = InkPoint(points[i].pointValue);
        spdf_fill_point p2 = InkPoint(points[i + 1].pointValue), p3 = InkPoint(points[i + 2 < n ? i + 2 : i + 1].pointValue);
        int k = spdf_ink_flatten_segment(p0, p1, p2, p3, 0.2f, 4.0f, out, 64);
        for (int j = 0; j < k; j++) [path lineToPoint:NSMakePoint(out[j].x, out[j].y)];
    }
    return path;
}

- (void)drawLineObjectPreviewOnPage:(NSInteger)page {
    NSRect canvas = [self canvasRectForPage:page];
    CGFloat scale = [self scaleForPage:page];
    NSAffineTransform* toView = [NSAffineTransform transform];
    [toView translateXBy:NSMinX(canvas) yBy:NSMinY(canvas)];
    [toView scaleBy:scale];
    NSBezierPath* path = [toView transformBezierPath:[self lineObjectCanvasPath]];
    path.lineWidth = [self toolSize] * scale;
    path.lineCapStyle = NSLineCapStyleRound;
    path.lineJoinStyle = NSLineJoinStyleRound;
    spdf_paint_color color = 0x000000FF;
    SPDFAnnotateParseColor([self colorFor:self.rightButton], &color);
    [SPDFAnnotateColor(color) setStroke];
    [path stroke];
}

// What a new drag point changes: the Pen's last curve piece bends toward it too, so the pieces from the third point
// back are drawn again.
- (NSRect)penRedrawRectAfterAdding {
    NSArray<NSValue*>* points = self.points;
    NSRect box = NSZeroRect;
    BOOL first = YES;
    for (NSUInteger i = points.count > 4 ? points.count - 4 : 0; i < points.count; i++) {
        NSPoint p = points[i].pointValue;
        NSRect r = NSMakeRect(p.x, p.y, 0, 0);
        box = first ? r : NSMakeRect(MIN(NSMinX(box), p.x), MIN(NSMinY(box), p.y),
                                      MAX(NSMaxX(box), p.x) - MIN(NSMinX(box), p.x),
                                      MAX(NSMaxY(box), p.y) - MIN(NSMinY(box), p.y));
        first = NO;
    }
    // A Catmull-Rom piece can swing a little outside its points' box.
    CGFloat swing = MAX(NSWidth(box), NSHeight(box)) / 4;
    return NSInsetRect(box, -swing, -swing);
}

@end
#pragma clang diagnostic pop
