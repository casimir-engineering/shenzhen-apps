// The canvas view's finished gestures and clicks, the pointer and the keys (SPDFMacAnnotateCanvasView.h): a stroke
// becomes one paint.stroke (or pen.add, erase.lines) with all its points, a polygon one shape.add, a click with Fill,
// the colour picker or the Magnifier its operation; Escape, Delete, the arrows and Return act on the selection.
#import "SPDFMacAnnotateCanvasViewPrivate.h"

#import "SPDFMacAnnotateImageIO.h"
#import "SPDFMacAnnotateIntegration.h"
#import "SPDFMacAnnotateSessionPrivate.h"
#import "SPDFMacFillController.h"
#import "SPDFMacFillOverlayView.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation SPDFMacAnnotateCanvasView (Finishing)

- (void)finishStrokeOnPage:(NSInteger)page right:(BOOL)right {
    SPDFMacAnnotateSession* session = self.session;
    NSMutableArray* points = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.points.count; ++i) {
        NSPoint p = self.points[i].pointValue;
        CGFloat pressure = i < self.pressures.count ? self.pressures[i].doubleValue : 1;
        [points addObject:pressure < 0.999 ? @[@(p.x), @(p.y), @(pressure)] : SPDFAnnotatePointArray(p)];
    }
    if (!points.count) return;
    self.lastStrokeEnd = self.points.lastObject.pointValue;
    self.hasLastStrokeEnd = YES;
    NSDictionary* options = [self toolOptions];
    NSDictionary* op;
    if (session.tool == SPDFAnnotateToolPen) {
        op = @{@"op": @"pen.add", @"points": points, @"color": [self colorFor:right], @"width": @([self toolSize])};
    } else if (session.tool == SPDFAnnotateToolEraser && !session.eraserPixels) {
        op = @{@"op": @"erase.lines", @"points": points, @"size": @(MAX(1, [self toolSize]))};
    } else {
        NSString* tool = session.tool == SPDFAnnotateToolEraser ? (right ? @"color_eraser" : @"eraser")
                                                                : SPDFAnnotateToolName(session.tool, session.brush);
        NSMutableDictionary* stroke = [@{@"op": @"paint.stroke", @"tool": tool, @"points": points,
                                         @"size": @(MAX(1, MIN(100, [self toolSize]))),
                                         @"seed": @(arc4random())} mutableCopy];
        if (options[@"opacity"]) stroke[@"opacity"] = options[@"opacity"];
        if (![tool isEqual:@"eraser"]) stroke[@"color"] = [self colorFor:right && ![tool isEqual:@"color_eraser"]];
        op = stroke;
    }
    [self operation:op page:page done:nil];
}

- (void)finishPolygonOnPage:(NSInteger)page {
    NSMutableArray* points = [NSMutableArray array];
    for (NSValue* value in self.points) [points addObject:SPDFAnnotatePointArray(value.pointValue)];
    self.gesture = SPDFAnnotateGestureNone;
    [self.points removeAllObjects];
    if (points.count < 3) return;
    NSDictionary* options = [SPDFAnnotateSettings.shared optionsForTool:@"shape"];
    NSMutableDictionary* outline = [@{@"style": @"solid", @"width": @3} mutableCopy];
    if ([options[@"outline"] isKindOfClass:NSDictionary.class]) [outline addEntriesFromDictionary:options[@"outline"]];
    outline[@"color"] = [self colorFor:NO];
    NSMutableDictionary* fill = [@{@"style": @"none"} mutableCopy];
    if ([options[@"fill"] isKindOfClass:NSDictionary.class]) [fill addEntriesFromDictionary:options[@"fill"]];
    fill[@"color"] = [self colorFor:YES];
    __weak SPDFMacAnnotateCanvasView* weakSelf = self;
    [self operation:@{@"op": @"shape.add", @"shape": @"polygon", @"points": points, @"outline": outline, @"fill": fill}
               page:page done:^(NSDictionary* result) {
                 if ([result[@"ok"] boolValue] && result[@"id"]) weakSelf.session.selectedObjects = @[result[@"id"]];
               }];
}

- (void)clickWithTool:(SPDFAnnotateTool)tool at:(NSPoint)point page:(NSInteger)page right:(BOOL)right
                event:(NSEvent*)event {
    SPDFMacAnnotateSession* session = self.session;
    if (tool == SPDFAnnotateToolFill) {
        NSDictionary* options = [self toolOptions];
        NSMutableDictionary* op = [@{@"op": @"paint.fill", @"x": @(point.x), @"y": @(point.y),
                                     @"color": [self colorFor:right]} mutableCopy];
        if (options[@"tolerance"]) op[@"tolerance"] = options[@"tolerance"];
        if (options[@"contiguous"]) op[@"contiguous"] = options[@"contiguous"];
        [self operation:op page:page done:nil];
    } else if (tool == SPDFAnnotateToolColorPicker) {
        NSString* from = [[self toolOptions][@"from"] isEqual:@"layer"] ? @"layer" : @"visible";
        NSDictionary* picked = [session readOperation:@{@"op": @"color.pick", @"x": @(point.x), @"y": @(point.y),
                                                        @"from": from} page:page];
        if ([picked[@"ok"] boolValue] && [picked[@"color"] isKindOfClass:NSString.class])
            [self operation:@{@"op": @"colors.set", (right ? @"color2" : @"color1"): picked[@"color"]} page:page done:nil];
        session.tool = session.toolBeforePicker;  // one pick, then back (Paint)
        [self toolDidChange];
        [session noteChange];
    } else if (tool == SPDFAnnotateToolMagnifier) {
        CGFloat level = [self zoomLevel];
        BOOL out = right || (event.modifierFlags & NSEventModifierFlagOption);
        const CGFloat steps[] = {1, 2, 4, 8};
        CGFloat target = out ? level / 2 : 8;
        if (!out)
            for (int i = 0; i < 4; ++i)
                if (steps[i] > level + 0.01) { target = steps[i]; break; }
        ShenzhenMacDelegate* reader = (ShenzhenMacDelegate*)self.controller.host;
        if ([reader respondsToSelector:@selector(annotateZoomTo:atCanvasPoint:)])
            [reader annotateZoomTo:@(MAX(0.125, MIN(8, target))) atCanvasPoint:[NSValue valueWithPoint:point]];
    }
}

#pragma mark - Pointer

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea* area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                       options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                               NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect |
                                                               NSTrackingCursorUpdate
                                                         owner:self userInfo:nil]];
}

- (void)notePointer:(NSPoint)point page:(NSInteger)page inside:(BOOL)inside {
    self.hasPointer = inside;
    self.pointerPoint = point;
    self.pointerPage = page;
    [NSNotificationCenter.defaultCenter postNotificationName:SPDFAnnotateCanvasPointerDidMoveNotification object:self];
}

- (void)mouseMoved:(NSEvent*)event {
    NSPoint view = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger page = -1;
    NSPoint point = NSZeroPoint;
    BOOL inside = [self canvasPointForViewPoint:view page:&page canvasPoint:&point];
    [self notePointer:point page:page inside:inside];
    if (self.gesture == SPDFAnnotateGesturePolygon) {
        self.currentPoint = point;
        self.needsDisplay = YES;
    }
    [self cursorUpdate:event];
}

- (void)mouseExited:(NSEvent*)event {
    (void)event;
    [self notePointer:NSZeroPoint page:-1 inside:NO];
}

- (void)cursorUpdate:(NSEvent*)event {
    NSPoint view = [self convertPoint:event.locationInWindow fromView:nil];
    SPDFAnnotateCanvasHandle canvas = [self canvasHandleAt:view];
    NSInteger handle = [self objectHandleAt:view];
    if (canvas == SPDFAnnotateCanvasHandleRight) [NSCursor.resizeLeftRightCursor set];
    else if (canvas == SPDFAnnotateCanvasHandleBottom) [NSCursor.resizeUpDownCursor set];
    else if (canvas == SPDFAnnotateCanvasHandleCorner || (handle >= 0 && handle < 8)) [NSCursor.crosshairCursor set];
    else if (self.session.tool == SPDFAnnotateToolSelect) [NSCursor.arrowCursor set];
    else if (self.session.tool == SPDFAnnotateToolTextBox) [NSCursor.IBeamCursor set];
    else [NSCursor.crosshairCursor set];
}

// Scrolling and zooming over the canvas behave as over the pages.
- (void)scrollWheel:(NSEvent*)event { [self.overlay scrollWheel:event]; }
- (void)magnifyWithEvent:(NSEvent*)event { [self.overlay magnifyWithEvent:event]; }
- (void)smartMagnifyWithEvent:(NSEvent*)event { [self.overlay smartMagnifyWithEvent:event]; }

#pragma mark - Keys

- (BOOL)cancelGesture {
    BOOL had = self.gesture != SPDFAnnotateGestureNone;
    self.gesture = SPDFAnnotateGestureNone;
    self.liveResizeSize = NSZeroSize;
    self.rightButton = NO;
    [self.points removeAllObjects];
    [self.pressures removeAllObjects];
    if (had) self.needsDisplay = YES;
    return had;
}

- (void)keyDown:(NSEvent*)event {
    SPDFMacAnnotateSession* session = self.session;
    NSInteger page = session.kind == SPDFAnnotateDocumentPDF ? session.currentPage : -1;
    NSString* key = event.charactersIgnoringModifiers;
    unichar c = key.length ? [key characterAtIndex:0] : 0;
    BOOL command = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
    if (c == 27) {  // Escape: the gesture, else the selection (a lifted selection stays an object)
        if ([self cancelGesture]) return;
        session.selectedObjects = @[];
        [self operation:@{@"op": @"select.none"} page:page done:nil];
        return;
    }
    if ((c == '\r' || c == 3) && self.gesture == SPDFAnnotateGesturePolygon) {
        [self finishPolygonOnPage:self.gesturePage];
        return;
    }
    if (!command && (c == NSDeleteCharacter || c == NSBackspaceCharacter || c == NSDeleteFunctionKey)) {
        if (session.selectedObjects.count)
            [self operation:@{@"op": @"object.delete", @"ids": session.selectedObjects} page:page done:nil];
        else if ([self selectionOnPage:page])
            [self operation:@{@"op": @"select.delete"} page:page done:nil];
        else
            NSBeep();
        return;
    }
    if (!command && session.selectedObjects.count &&
        (c == NSLeftArrowFunctionKey || c == NSRightArrowFunctionKey || c == NSUpArrowFunctionKey ||
         c == NSDownArrowFunctionKey)) {
        CGFloat step = (event.modifierFlags & NSEventModifierFlagShift) ? 10 : 1;
        CGFloat dx = c == NSLeftArrowFunctionKey ? -step : c == NSRightArrowFunctionKey ? step : 0;
        CGFloat dy = c == NSUpArrowFunctionKey ? -step : c == NSDownArrowFunctionKey ? step : 0;
        [self operation:@{@"op": @"object.move", @"ids": session.selectedObjects, @"dx": @(dx), @"dy": @(dy)} page:page
                   done:nil];
        return;
    }
    if (SPDFAnnotateHandleKey(event, self.controller)) return;
    [super keyDown:event];
}

@end
#pragma clang diagnostic pop
