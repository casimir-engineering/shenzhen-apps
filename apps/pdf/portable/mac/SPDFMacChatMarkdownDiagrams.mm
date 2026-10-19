#import "SPDFMacChatMarkdownParts.h"

#import "markdown/SPDFMarkdownDiagram.h"

// Diagrams at chat scale differ from a page's in two ways, both drawn here so documents keep the engine's own look:
//   - A page reserves 14 to 20 pt of air inside every diagram's box (SPDFMarkdownDiagram*Shapes.mm), which a chat
//     bubble added to its paragraph spacing: 30 to 40 pt of blank above and below each diagram. A chat block shows
//     only the inked part of the box.
//   - The engine strokes nodes in the page's hairline grey (#d0d7de, #363636 in dark), 1.3:1 against a chat bubble:
//     the box around "USB-C VBUS" all but vanished. A chat strokes closed node shapes in the bubble's secondary text
//     colour, which every host already keeps legible on its bubbles (4.5:1 for text), so borders clear the 3:1 asked
//     of shapes.

// A stroke's antialiasing reaches about half a point past its line on either side.
static const CGFloat kInkPad = 1.5;

static NSRect ShapeBounds(SPDFMarkdownDiagramShape* shape) {
    switch (shape.kind) {
        case SPDFMarkdownDiagramShapeRectangle:
        case SPDFMarkdownDiagramShapeEllipse:
            return shape.rect;
        case SPDFMarkdownDiagramShapePolygon:
        case SPDFMarkdownDiagramShapePolyline: {
            // By hand: NSUnionRect drops a zero-size rect, which every point is.
            if (!shape.points.count) return NSZeroRect;
            CGFloat left = CGFLOAT_MAX, top = CGFLOAT_MAX, right = -CGFLOAT_MAX, bottom = -CGFLOAT_MAX;
            for (NSValue* value in shape.points) {
                NSPoint point = value.pointValue;
                left = MIN(left, point.x), right = MAX(right, point.x);
                top = MIN(top, point.y), bottom = MAX(bottom, point.y);
            }
            return NSMakeRect(left, top, right - left, bottom - top);
        }
        case SPDFMarkdownDiagramShapePieSlice:
            return NSMakeRect(shape.center.x - shape.radius, shape.center.y - shape.radius, 2 * shape.radius,
                              2 * shape.radius);
    }
    return NSZeroRect;
}

static BOOL Paints(SPDFMarkdownDiagramShape* shape) {
    BOOL fills = (shape.fillRole != SPDFMarkdownDiagramRoleNone || shape.authorFillColor) && shape.fillAlpha > 0;
    BOOL strokes = (shape.strokeRole != SPDFMarkdownDiagramRoleNone || shape.authorStrokeColor) &&
                   shape.strokeAlpha > 0 && shape.lineWidth > 0;
    return fills || strokes;
}

NSRect SPDFMacChatDiagramInkRect(SPDFMarkdownDiagramLayout* layout) {
    NSRect ink = NSZeroRect;
    BOOL first = YES;
    for (SPDFMarkdownDiagramShape* shape in layout.shapes) {
        if (!Paints(shape)) continue;
        // A horizontal or vertical line has a zero-size box; its stroke still has width.
        CGFloat half = MAX(shape.lineWidth, 0.5) / 2;
        NSRect bounds = NSInsetRect(ShapeBounds(shape), -half, -half);
        ink = first ? bounds : NSUnionRect(ink, bounds);
        first = NO;
    }
    // A label's frame is the line its text is centred in: its glyphs stay inside, its blank ends count as ink, which
    // keeps a centred title's box whole.
    for (SPDFMarkdownDiagramLabel* label in layout.labels) {
        if (!label.text.length) continue;
        ink = first ? label.frame : NSUnionRect(ink, label.frame);
        first = NO;
    }
    if (first) return NSMakeRect(0, 0, layout.size.width, layout.size.height);
    NSRect box = NSMakeRect(0, 0, layout.size.width, layout.size.height);
    return NSIntersectionRect(NSInsetRect(ink, -kInkPad, -kInkPad), box);
}

static void SetColor(CGContextRef context, NSColor* resolved, CGFloat alpha, BOOL stroke) {
    NSColor* color = [resolved colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.clearColor;
    CGFloat red = color.redComponent, green = color.greenComponent, blue = color.blueComponent;
    CGFloat opacity = color.alphaComponent * MAX(0, MIN(1, alpha));
    if (stroke) CGContextSetRGBStrokeColor(context, red, green, blue, opacity);
    else CGContextSetRGBFillColor(context, red, green, blue, opacity);
}

// The engine's own path for each shape kind (SPDFMarkdownDiagramBand.mm), which keeps its builder private.
static void AddPath(CGContextRef context, SPDFMarkdownDiagramShape* shape) {
    CGContextBeginPath(context);
    switch (shape.kind) {
        case SPDFMarkdownDiagramShapeRectangle: {
            if (shape.cornerRadius <= 0.01) {
                CGContextAddRect(context, shape.rect);
                return;
            }
            CGPathRef path = CGPathCreateWithRoundedRect(shape.rect, shape.cornerRadius, shape.cornerRadius, NULL);
            CGContextAddPath(context, path);
            CGPathRelease(path);
            return;
        }
        case SPDFMarkdownDiagramShapeEllipse:
            CGContextAddEllipseInRect(context, shape.rect);
            return;
        case SPDFMarkdownDiagramShapePolygon:
        case SPDFMarkdownDiagramShapePolyline: {
            NSArray<NSValue*>* points = shape.points;
            if (points.count < 2) return;
            CGContextMoveToPoint(context, points.firstObject.pointValue.x, points.firstObject.pointValue.y);
            for (NSUInteger index = 1; index < points.count; index++)
                CGContextAddLineToPoint(context, points[index].pointValue.x, points[index].pointValue.y);
            if (shape.kind == SPDFMarkdownDiagramShapePolygon) CGContextClosePath(context);
            return;
        }
        case SPDFMarkdownDiagramShapePieSlice: {
            CGFloat start = shape.startAngle * (CGFloat)M_PI / 180;
            CGFloat end = (shape.startAngle + shape.sweepAngle) * (CGFloat)M_PI / 180;
            CGContextMoveToPoint(context, shape.center.x, shape.center.y);
            CGContextAddArc(context, shape.center.x, shape.center.y, shape.radius, start, end, 0);
            CGContextClosePath(context);
            return;
        }
    }
}

// Node borders only: open lines with the node role (a Gantt chart's day grid, drawn at 60%) stay the page's grey.
static BOOL IsNodeBorder(SPDFMarkdownDiagramShape* shape) {
    return shape.strokeRole == SPDFMarkdownDiagramRoleNodeStroke && !shape.authorStrokeColor &&
           shape.kind != SPDFMarkdownDiagramShapePolyline;
}

static NSColor* StrokeColor(SPDFMarkdownDiagramShape* shape, SPDFMarkdownThemeVariant variant, NSColor* nodeStroke) {
    return IsNodeBorder(shape) && nodeStroke ? nodeStroke : SPDFMarkdownDiagramShapeStrokeColor(shape, variant);
}

void SPDFMacChatDrawDiagramShapes(CGContextRef context, SPDFMarkdownDiagramLayout* layout, CGRect rect,
                                  SPDFMarkdownThemeVariant variant, NSColor* nodeStroke) {
    if (!context || !layout || layout.size.width <= 0 || rect.size.width <= 0) return;
    CGFloat scale = rect.size.width / layout.size.width;
    CGContextSaveGState(context);
    // Diagram-local space runs y-down from the box's top-left corner.
    CGContextTranslateCTM(context, CGRectGetMinX(rect), CGRectGetMaxY(rect));
    CGContextScaleCTM(context, scale, -scale);
    for (SPDFMarkdownDiagramShape* shape in layout.shapes) {
        BOOL fills = (shape.fillRole != SPDFMarkdownDiagramRoleNone || shape.authorFillColor) && shape.fillAlpha > 0;
        BOOL strokes = (shape.strokeRole != SPDFMarkdownDiagramRoleNone || shape.authorStrokeColor) &&
                       shape.strokeAlpha > 0 && shape.lineWidth > 0;
        if (fills) {
            SetColor(context, SPDFMarkdownDiagramShapeFillColor(shape, variant), shape.fillAlpha, NO);
            AddPath(context, shape);
            CGContextFillPath(context);
        }
        if (!strokes) continue;
        SetColor(context, StrokeColor(shape, variant, nodeStroke), shape.strokeAlpha, YES);
        CGContextSetLineWidth(context, shape.lineWidth);
        if (shape.dashLength > 0) {
            CGFloat pattern[2] = {shape.dashLength, shape.dashLength * 0.75};
            CGContextSetLineDash(context, 0, pattern, 2);
        } else {
            CGContextSetLineDash(context, 0, NULL, 0);
        }
        AddPath(context, shape);
        CGContextStrokePath(context);
    }
    CGContextRestoreGState(context);
}
