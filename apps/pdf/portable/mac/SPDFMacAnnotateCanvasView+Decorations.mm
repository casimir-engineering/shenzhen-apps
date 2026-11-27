// What the canvas view draws on top of the composite (SPDFMacAnnotateCanvasView.h): the checkerboard under
// transparency, the marching ants, the selected objects' box with eight handles and a rotation handle, the live
// preview of a gesture, the canvas handles with the dotted outline of a resize (rulers, gridlines and the thumbnail are
// in +Rulers.mm).
// Screen only: none of it is in a saved file or a page picture.
#import "SPDFMacAnnotateCanvasViewPrivate.h"

#import <objc/runtime.h>

#import "SPDFMacAnnotateImageIO.h"
#import "SPDFMacAnnotateSessionPrivate.h"

static const CGFloat kHandle = 7.0;         // a handle's side, points
static const CGFloat kRotationReach = 22.0; // the rotation handle above the box's top edge

static BOOL IsDark(NSView* view) {
    return [view.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
           == NSAppearanceNameDarkAqua;
}

static NSColor* Hex(unsigned rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0 alpha:1];
}

// 8 x 8 pt squares: #FFFFFF / #E8E8E8 in light appearance, #3C3C3C / #323232 in dark (§ 1 Checkerboard).
static NSColor* CheckerPattern(BOOL dark) {
    static NSColor* patterns[2];
    NSColor* __strong* slot = &patterns[dark ? 1 : 0];
    if (*slot) return *slot;
    NSImage* tile = [NSImage imageWithSize:NSMakeSize(16, 16) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        (void)rect;
        [Hex(dark ? 0x3C3C3C : 0xFFFFFF) setFill];
        NSRectFill(NSMakeRect(0, 0, 16, 16));
        [Hex(dark ? 0x323232 : 0xE8E8E8) setFill];
        NSRectFill(NSMakeRect(8, 0, 8, 8));
        NSRectFill(NSMakeRect(0, 8, 8, 8));
        return YES;
    }];
    *slot = [NSColor colorWithPatternImage:tile];
    return *slot;
}

static NSBezierPath* HandleSquare(NSPoint center) {
    return [NSBezierPath bezierPathWithRect:NSMakeRect(center.x - kHandle / 2, center.y - kHandle / 2, kHandle, kHandle)];
}

// The eight handles of a box, clockwise from the top-left corner.
static NSPoint HandlePoint(NSRect r, NSInteger i) {
    CGFloat xs[] = {NSMinX(r), NSMidX(r), NSMaxX(r), NSMaxX(r), NSMaxX(r), NSMidX(r), NSMinX(r), NSMinX(r)};
    CGFloat ys[] = {NSMinY(r), NSMinY(r), NSMinY(r), NSMidY(r), NSMaxY(r), NSMaxY(r), NSMaxY(r), NSMidY(r)};
    return NSMakePoint(xs[i], ys[i]);
}

// NSBezierPath.CGPath is macOS 14; the app runs from macOS 12.
static void AddPath(CGContextRef context, NSBezierPath* path) {
    NSPoint p[3];
    for (NSInteger i = 0; i < path.elementCount; ++i) {
        switch ([path elementAtIndex:i associatedPoints:p]) {
            case NSBezierPathElementMoveTo: CGContextMoveToPoint(context, p[0].x, p[0].y); break;
            case NSBezierPathElementLineTo: CGContextAddLineToPoint(context, p[0].x, p[0].y); break;
            case NSBezierPathElementCurveTo:
                CGContextAddCurveToPoint(context, p[0].x, p[0].y, p[1].x, p[1].y, p[2].x, p[2].y);
                break;
            case NSBezierPathElementClosePath: CGContextClosePath(context); break;
            default: break;
        }
    }
}

@implementation SPDFMacAnnotateCanvasView (Decorations)

- (NSInteger)currentPageForDecorations {
    return self.session.kind == SPDFAnnotateDocumentPDF ? self.session.currentPage : -1;
}

- (void)drawCheckerboardInRect:(NSRect)rect {
    NSRect canvas = [self canvasRectForPage:-1];
    [NSGraphicsContext saveGraphicsState];
    // Anchored to the canvas, so the squares scroll with it instead of swimming under the picture.
    NSPoint phase = [self convertPoint:canvas.origin toView:nil];
    [NSGraphicsContext.currentContext setPatternPhase:phase];
    [CheckerPattern(IsDark(self)) setFill];
    NSRectFill(rect);
    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawDecorationsInRect:(NSRect)dirty {
    NSInteger page = [self currentPageForDecorations];
    [self drawGridlinesInRect:dirty page:page];  // +Rulers.mm
    [self drawAntsOnPage:page];
    [self drawSelectedObjectsOnPage:page];
    [self drawPreviewOnPage:self.gesture == SPDFAnnotateGestureNone ? page : self.gesturePage];
    if (self.session.kind != SPDFAnnotateDocumentPDF) [self drawCanvasHandles];
    if (self.showsRulers) [self drawRulersOnPage:page];
    if (self.showsThumbnail) [self drawThumbnail];
}

#pragma mark - Ants

- (NSBezierPath*)antsPathOnPage:(NSInteger)page {
    NSDictionary* selection = [self selectionOnPage:page];
    if (!selection) return nil;
    NSBezierPath* path = [NSBezierPath bezierPath];
    NSArray* outline = [selection[@"outline"] isKindOfClass:NSArray.class] ? selection[@"outline"] : nil;
    if (outline.count >= 3) {
        BOOL first = YES;
        for (NSArray* point in outline) {
            if (![point isKindOfClass:NSArray.class] || point.count < 2) continue;
            NSPoint p = [self viewPointForCanvasPoint:NSMakePoint([point[0] doubleValue], [point[1] doubleValue])
                                                 page:page];
            if (first) [path moveToPoint:p];
            else [path lineToPoint:p];
            first = NO;
        }
        [path closePath];
        return path;
    }
    NSDictionary* box = selection[@"bounds"];
    NSRect rect = NSMakeRect([box[@"x"] doubleValue], [box[@"y"] doubleValue], [box[@"w"] doubleValue],
                             [box[@"h"] doubleValue]);
    return NSIsEmptyRect(rect) ? nil : [NSBezierPath bezierPathWithRect:[self viewRectForCanvasRect:rect page:page]];
}

- (void)drawAntsOnPage:(NSInteger)page {
    NSBezierPath* path = [self antsPathOnPage:page];
    if (!path) return;
    path.lineWidth = 1;
    [NSColor.whiteColor setStroke];
    [path stroke];
    CGFloat dash[] = {4, 4};
    [path setLineDash:dash count:2 phase:self.antsPhase];
    [NSColor.blackColor setStroke];
    [path stroke];
}

- (void)updateAntsTimer {
    BOOL needed = self.session && [self selectionOnPage:[self currentPageForDecorations]] != nil && !self.hidden;
    if (needed == (self.antsTimer != nil)) return;
    [self.antsTimer invalidate];
    self.antsTimer = nil;
    if (!needed) return;
    __weak SPDFMacAnnotateCanvasView* weakSelf = self;
    self.antsTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer* timer) {
        SPDFMacAnnotateCanvasView* view = weakSelf;
        if (!view) return [timer invalidate];
        view.antsPhase = fmod(view.antsPhase + 1, 8);
        NSBezierPath* ants = [view antsPathOnPage:[view currentPageForDecorations]];
        if (ants) [view setNeedsDisplayInRect:NSInsetRect(ants.bounds, -2, -2)];
        else [view updateAntsTimer];
    }];
}

#pragma mark - Objects

// A pixel selection, while a selection tool is chosen and no object is selected, has the objects' handles too: a
// handle lifts it into a picture (select.lift) and resizes or turns it as one.
- (NSRect)pixelSelectionViewRect {
    SPDFAnnotateTool tool = self.session.tool;
    if (self.session.selectedObjects.count || (tool != SPDFAnnotateToolSelect && tool != SPDFAnnotateToolRectSelect &&
                                               tool != SPDFAnnotateToolFreeformSelect))
        return NSZeroRect;
    NSInteger page = [self currentPageForDecorations];
    NSDictionary* box = [self selectionOnPage:page][@"bounds"];
    if (![box isKindOfClass:NSDictionary.class]) return NSZeroRect;
    NSRect rect = NSMakeRect([box[@"x"] doubleValue], [box[@"y"] doubleValue], [box[@"w"] doubleValue], [box[@"h"] doubleValue]);
    return NSIsEmptyRect(rect) ? NSZeroRect : [self viewRectForCanvasRect:rect page:page];
}

- (NSRect)selectedObjectsViewRect {
    if (!self.session.selectedObjects.count) return [self pixelSelectionViewRect];
    NSInteger page = [self currentPageForDecorations];
    // The objects' own boxes, so the handles sit on them (what they paint reaches further: a thick outline, a brush's
    // texture); a turned object's painted bounds, which hold it whole.
    NSRect bounds = NSZeroRect;
    for (NSDictionary* object in [self objectsOnPage:page]) {
        if (![self.session.selectedObjects containsObject:object[@"id"]]) continue;
        NSRect own = [object[@"rect"] rectValue];
        BOOL turned = fmod(fabs([object[@"rotation"] doubleValue]), 360) > 0.01;
        bounds = NSUnionRect(bounds, turned || NSIsEmptyRect(own) ? [object[@"bounds"] rectValue] : own);
    }
    return NSIsEmptyRect(bounds) ? NSZeroRect : [self viewRectForCanvasRect:bounds page:page];
}

- (NSInteger)objectHandleAt:(NSPoint)p {
    NSRect box = [self selectedObjectsViewRect];
    if (NSIsEmptyRect(box)) return -1;
    if (self.session.selectedObjects.count <= 1) {  // one object, or a pixel selection
        NSPoint rotation = NSMakePoint(NSMidX(box), NSMinY(box) - kRotationReach);
        if (hypot(p.x - rotation.x, p.y - rotation.y) <= kHandle) return 8;
    }
    for (NSInteger i = 0; i < 8; ++i) {
        NSPoint h = HandlePoint(box, i);
        if (fabs(p.x - h.x) <= kHandle && fabs(p.y - h.y) <= kHandle) return i;
    }
    return -1;
}

- (void)drawSelectedObjectsOnPage:(NSInteger)page {
    NSRect box = [self selectedObjectsViewRect];
    if (NSIsEmptyRect(box)) return;
    NSPoint delta = NSZeroPoint;
    CGFloat scale = [self scaleForPage:page];
    if (self.gesture == SPDFAnnotateGestureMove)
        delta = NSMakePoint((self.currentPoint.x - self.startPoint.x) * scale,
                            (self.currentPoint.y - self.startPoint.y) * scale);
    if (self.gesture == SPDFAnnotateGestureResize) box = [self viewRectForCanvasRect:[self resizedRect] page:page];
    box = NSOffsetRect(box, delta.x, delta.y);
    NSColor* accent = NSColor.controlAccentColor;
    if (self.gesture == SPDFAnnotateGestureRotate) {
        CGFloat angle = [self rotationDelta];
        NSAffineTransform* turn = [NSAffineTransform transform];
        [turn translateXBy:NSMidX(box) yBy:NSMidY(box)];
        [turn rotateByDegrees:angle];
        [turn translateXBy:-NSMidX(box) yBy:-NSMidY(box)];
        NSBezierPath* turned = [turn transformBezierPath:[NSBezierPath bezierPathWithRect:box]];
        CGFloat dash[] = {3, 3};
        [turned setLineDash:dash count:2 phase:0];
        [accent setStroke];
        [turned stroke];
    }
    NSBezierPath* frame = [NSBezierPath bezierPathWithRect:NSInsetRect(box, -0.5, -0.5)];
    frame.lineWidth = 1;
    [accent setStroke];
    if (self.session.selectedObjects.count) [frame stroke];  // a pixel selection keeps its marching ants
    if (self.gesture == SPDFAnnotateGestureMove) return;
    if (self.session.selectedObjects.count <= 1) {
        NSPoint top = NSMakePoint(NSMidX(box), NSMinY(box));
        NSPoint knob = NSMakePoint(top.x, top.y - kRotationReach);
        NSBezierPath* stem = [NSBezierPath bezierPath];
        [stem moveToPoint:top];
        [stem lineToPoint:knob];
        [stem stroke];
        NSBezierPath* circle = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(knob.x - 4.5, knob.y - 4.5, 9, 9)];
        [NSColor.whiteColor setFill];
        [circle fill];
        [circle stroke];
    }
    for (NSInteger i = 0; i < 8; ++i) {
        NSBezierPath* square = HandleSquare(HandlePoint(box, i));
        [NSColor.whiteColor setFill];
        [square fill];
        [accent setStroke];
        [square stroke];
    }
}

// The box a handle drag gives (canvas units); Shift keeps the ratio.
- (NSRect)resizedRect {
    NSRect r = self.originalRect;
    CGFloat dx = self.currentPoint.x - self.startPoint.x, dy = self.currentPoint.y - self.startPoint.y;
    CGFloat minX = NSMinX(r), minY = NSMinY(r), maxX = NSMaxX(r), maxY = NSMaxY(r);
    NSInteger h = self.handle;
    if (h == 0 || h == 6 || h == 7) minX += dx;
    if (h == 2 || h == 3 || h == 4) maxX += dx;
    if (h == 0 || h == 1 || h == 2) minY += dy;
    if (h == 4 || h == 5 || h == 6) maxY += dy;
    NSRect out = NSMakeRect(MIN(minX, maxX), MIN(minY, maxY), MAX(1, fabs(maxX - minX)), MAX(1, fabs(maxY - minY)));
    // Proportions kept unless Shift is held (a line, flat in one direction, has none to keep). A corner keeps the
    // opposite corner in place, an edge the opposite edge, centred across.
    BOOL keep = !(self.gestureModifiers & NSEventModifierFlagShift) && NSWidth(r) >= 2 && NSHeight(r) >= 2;
    if (!keep) return out;
    CGFloat ratio = NSWidth(r) / NSHeight(r);
    if (h == 1 || h == 5) {
        out.size.width = NSHeight(out) * ratio;
        out.origin.x = NSMidX(r) - NSWidth(out) / 2;
    } else if (h == 3 || h == 7) {
        out.size.height = NSWidth(out) / ratio;
        out.origin.y = NSMidY(r) - NSHeight(out) / 2;
    } else {
        if (NSWidth(out) / NSHeight(out) > ratio) out.size.height = NSWidth(out) / ratio;
        else out.size.width = NSHeight(out) * ratio;
        if (h == 0 || h == 6) out.origin.x = maxX - NSWidth(out);
        if (h == 0 || h == 2) out.origin.y = maxY - NSHeight(out);
    }
    return out;
}

- (CGFloat)rotationDelta {
    NSRect r = self.originalRect;
    NSPoint c = NSMakePoint(NSMidX(r), NSMidY(r));
    CGFloat a0 = atan2(self.startPoint.y - c.y, self.startPoint.x - c.x);
    CGFloat a1 = atan2(self.currentPoint.y - c.y, self.currentPoint.x - c.x);
    CGFloat degrees = (a1 - a0) * 180 / M_PI;
    if (self.gestureModifiers & NSEventModifierFlagShift) degrees = round(degrees / 15) * 15;
    return degrees;
}

#pragma mark - Preview of the gesture

- (NSBezierPath*)pathThroughPoints:(NSArray<NSValue*>*)points page:(NSInteger)page close:(BOOL)close {
    NSBezierPath* path = [NSBezierPath bezierPath];
    for (NSUInteger i = 0; i < points.count; ++i) {
        NSPoint p = [self viewPointForCanvasPoint:points[i].pointValue page:page];
        if (i == 0) [path moveToPoint:p];
        else [path lineToPoint:p];
    }
    if (points.count == 1) [path lineToPoint:[self viewPointForCanvasPoint:points[0].pointValue page:page]];
    if (close && points.count > 2) [path closePath];
    return path;
}

- (NSRect)gestureCanvasRect {
    NSPoint a = self.startPoint, b = self.currentPoint;
    NSRect r = NSMakeRect(MIN(a.x, b.x), MIN(a.y, b.y), fabs(b.x - a.x), fabs(b.y - a.y));
    if (self.gestureModifiers & NSEventModifierFlagShift) {
        CGFloat side = MAX(NSWidth(r), NSHeight(r));
        r = NSMakeRect(b.x < a.x ? a.x - side : a.x, b.y < a.y ? a.y - side : a.y, side, side);
    }
    return r;
}

- (void)drawPreviewOnPage:(NSInteger)page {
    SPDFMacAnnotateSession* session = self.session;
    CGFloat scale = [self scaleForPage:page];
    NSColor* color = SPDFAnnotateColor(self.rightButton ? session.color2 : session.color1);
    CGFloat dash[] = {4, 3};
    // What the release paints or adds stays inside the canvas (a page): so does its preview.
    SPDFAnnotateGesture gesture = self.gesture;
    BOOL paints = gesture == SPDFAnnotateGestureStroke || gesture == SPDFAnnotateGestureShape ||
                  gesture == SPDFAnnotateGestureCurve || gesture == SPDFAnnotateGesturePolygon;
    [NSGraphicsContext saveGraphicsState];
    if (paints) NSRectClip([self canvasRectForPage:page]);
    if ([self previewsLineObject]) [self drawLineObjectPreviewOnPage:page];  // +LinePreview.mm
    else switch (gesture) {
        case SPDFAnnotateGestureStroke: {
            NSDictionary* options = [SPDFAnnotateSettings.shared optionsForTool:SPDFAnnotateToolName(session.tool, session.brush)];
            CGFloat size = [options[@"size"] doubleValue];
            if (size <= 0) size = session.tool == SPDFAnnotateToolPencil ? 1 : session.tool == SPDFAnnotateToolEraser ? 4
                                : session.tool == SPDFAnnotateToolPen ? 2 : 5;
            CGFloat opacity = options[@"opacity"] ? [options[@"opacity"] doubleValue] / 100.0 : 1.0;
            NSBezierPath* path = [self pathThroughPoints:self.points page:page close:NO];
            path.lineWidth = MAX(1, size * scale);
            BOOL eraser = session.tool == SPDFAnnotateToolEraser;
            path.lineCapStyle = eraser || session.tool == SPDFAnnotateToolPencil ? NSLineCapStyleSquare
                                                                                 : NSLineCapStyleRound;
            path.lineJoinStyle = NSLineJoinStyleRound;
            if (eraser && !self.rightButton) {
                [self drawCheckerboardStroke:path];
            } else {
                [[color colorWithAlphaComponent:color.alphaComponent * opacity] setStroke];
                [path stroke];
            }
            break;
        }
        case SPDFAnnotateGestureShape: {
            NSRect r = [self viewRectForCanvasRect:[self gestureCanvasRect] page:page];
            NSBezierPath* path;
            NSString* shape = session.tool == SPDFAnnotateToolArrow ? @"arrow_line" : session.shape;
            if ([shape isEqual:@"line"] || [shape isEqual:@"arrow_line"] || [shape isEqual:@"curve"]) {
                path = [NSBezierPath bezierPath];
                [path moveToPoint:[self viewPointForCanvasPoint:self.startPoint page:page]];
                [path lineToPoint:[self viewPointForCanvasPoint:[self constrainedEnd] page:page]];
            } else if ([shape isEqual:@"oval"] || [shape hasSuffix:@"callout"] || [shape isEqual:@"heart"]) {
                path = [NSBezierPath bezierPathWithOvalInRect:r];
            } else if ([shape isEqual:@"rounded_rectangle"]) {
                path = [NSBezierPath bezierPathWithRoundedRect:r xRadius:MIN(NSWidth(r), NSHeight(r)) / 6
                                                       yRadius:MIN(NSWidth(r), NSHeight(r)) / 6];
            } else {
                path = [NSBezierPath bezierPathWithRect:r];
            }
            NSDictionary* options = [SPDFAnnotateSettings.shared optionsForTool:@"shape"];
            CGFloat width = [options[@"outline"][@"width"] doubleValue] ?: 3;
            path.lineWidth = MAX(1, width * scale);
            [color setStroke];
            [path stroke];
            break;
        }
        case SPDFAnnotateGestureCurve: {
            NSBezierPath* path = [self curvePreviewOnPage:page];
            NSDictionary* options = [SPDFAnnotateSettings.shared optionsForTool:@"shape"];
            path.lineWidth = MAX(1, ([options[@"outline"][@"width"] doubleValue] ?: 3) * scale);
            [color setStroke];
            [path stroke];
            break;
        }
        case SPDFAnnotateGesturePolygon:
        case SPDFAnnotateGestureLasso: {
            NSMutableArray* points = [self.points mutableCopy];
            if (self.gesture != SPDFAnnotateGestureLasso) [points addObject:@(self.currentPoint)];
            NSBezierPath* path = [self pathThroughPoints:points page:page close:self.gesture == SPDFAnnotateGestureLasso];
            path.lineWidth = 1;
            [path setLineDash:dash count:2 phase:0];
            [(self.gesture == SPDFAnnotateGestureLasso ? NSColor.labelColor : color) setStroke];
            [path stroke];
            break;
        }
        case SPDFAnnotateGestureRectSelect:
        case SPDFAnnotateGestureBoxSelect:
        case SPDFAnnotateGestureTextBox: {
            NSBezierPath* path = [NSBezierPath bezierPathWithRect:[self viewRectForCanvasRect:[self gestureCanvasRect]
                                                                                        page:page]];
            path.lineWidth = 1;
            [path setLineDash:dash count:2 phase:0];
            [(self.gesture == SPDFAnnotateGestureBoxSelect ? NSColor.controlAccentColor : NSColor.labelColor) setStroke];
            [path stroke];
            break;
        }
        default:
            break;
    }
    [NSGraphicsContext restoreGraphicsState];
}

static NSPoint SPDFAnnotateAt45(NSPoint a, NSPoint b) {
    CGFloat angle = round(atan2(b.y - a.y, b.x - a.x) / (M_PI / 4)) * (M_PI / 4);
    CGFloat length = hypot(b.x - a.x, b.y - a.y);
    return NSMakePoint(a.x + cos(angle) * length, a.y + sin(angle) * length);
}

- (NSPoint)constrainedEnd {
    if (!(self.gestureModifiers & NSEventModifierFlagShift)) return self.currentPoint;
    return SPDFAnnotateAt45(self.startPoint, self.currentPoint);
}

- (BOOL)shiftStraightensStroke:(NSEvent*)event {
    return (event.modifierFlags & NSEventModifierFlagShift) != 0;
}

// Pencil and brushes as in Paint (0, 45 and 90 degrees); the Pen as Fill & Sign's, straight in any direction.
- (void)straightenStrokeTo:(NSPoint)point {
    NSValue* start = self.points.firstObject ?: @(self.startPoint);
    NSNumber* pressure = self.pressures.firstObject ?: @1;
    NSPoint end = self.session.tool == SPDFAnnotateToolPen ? point : SPDFAnnotateAt45(start.pointValue, point);
    [self.points setArray:@[ start, @(end) ]];
    [self.pressures setArray:@[ pressure, pressure ]];
}

// What erasing leaves, before the stroke is applied: the checkerboard along the path.
- (void)drawCheckerboardStroke:(NSBezierPath*)path {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    AddPath(context, path);
    CGContextSetLineWidth(context, path.lineWidth);
    CGContextSetLineCap(context, kCGLineCapSquare);
    CGContextSetLineJoin(context, kCGLineJoinRound);
    CGContextReplacePathWithStrokedPath(context);
    CGContextClip(context);
    [self drawCheckerboardInRect:NSInsetRect(path.bounds, -path.lineWidth, -path.lineWidth)];
    CGContextRestoreGState(context);
}

#pragma mark - Canvas handles

- (NSPoint)canvasHandlePoint:(SPDFAnnotateCanvasHandle)handle {
    NSRect canvas = [self canvasRectForPage:-1];
    if (!NSIsEmptyRect(canvas) && self.liveResizeSize.width > 0) {
        CGFloat scale = [self scaleForPage:-1];
        canvas.size = NSMakeSize(self.liveResizeSize.width * scale, self.liveResizeSize.height * scale);
    }
    switch (handle) {
        case SPDFAnnotateCanvasHandleRight: return NSMakePoint(NSMaxX(canvas) + kHandle / 2 + 1, NSMidY(canvas));
        case SPDFAnnotateCanvasHandleBottom: return NSMakePoint(NSMidX(canvas), NSMaxY(canvas) + kHandle / 2 + 1);
        case SPDFAnnotateCanvasHandleCorner:
            return NSMakePoint(NSMaxX(canvas) + kHandle / 2 + 1, NSMaxY(canvas) + kHandle / 2 + 1);
        default: return NSZeroPoint;
    }
}

- (SPDFAnnotateCanvasHandle)canvasHandleAt:(NSPoint)p {
    if (self.session.kind == SPDFAnnotateDocumentPDF || !self.session.canvas) return SPDFAnnotateCanvasHandleNone;
    for (NSInteger h = SPDFAnnotateCanvasHandleCorner; h >= SPDFAnnotateCanvasHandleRight; --h) {
        NSPoint c = [self canvasHandlePoint:(SPDFAnnotateCanvasHandle)h];
        if (fabs(p.x - c.x) <= kHandle && fabs(p.y - c.y) <= kHandle) return (SPDFAnnotateCanvasHandle)h;
    }
    return SPDFAnnotateCanvasHandleNone;
}

- (void)drawCanvasHandles {
    if (!self.session.canvas) return;
    if (self.gesture == SPDFAnnotateGestureCanvasResize && self.liveResizeSize.width > 0) {
        NSRect canvas = [self canvasRectForPage:-1];
        CGFloat scale = [self scaleForPage:-1];
        NSRect outline = NSMakeRect(NSMinX(canvas), NSMinY(canvas), self.liveResizeSize.width * scale,
                                    self.liveResizeSize.height * scale);
        NSBezierPath* path = [NSBezierPath bezierPathWithRect:NSInsetRect(outline, -0.5, -0.5)];
        CGFloat dots[] = {1, 2};
        [path setLineDash:dots count:2 phase:0];
        [NSColor.labelColor setStroke];
        [path stroke];
    }
    for (NSInteger h = SPDFAnnotateCanvasHandleRight; h <= SPDFAnnotateCanvasHandleCorner; ++h) {
        NSBezierPath* square = HandleSquare([self canvasHandlePoint:(SPDFAnnotateCanvasHandle)h]);
        [NSColor.whiteColor setFill];
        [square fill];
        [NSColor.secondaryLabelColor setStroke];
        [square stroke];
    }
}

@end
