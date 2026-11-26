// The canvas view's finished gestures and clicks, the pointer and the keys (SPDFMacAnnotateCanvasView.h): a stroke
// becomes one paint.stroke (or pen.add, erase.lines) with all its points, a polygon one shape.add, a click with Fill,
// the colour picker or the Magnifier its operation; Escape, Delete, the arrows and Return act on the selection.
#import "SPDFMacAnnotateCanvasViewPrivate.h"

#import "SPDFMacAnnotateImageIO.h"
#import "SPDFMacAnnotateIntegration.h"
#import "SPDFMacAnnotateMenus.h"
#import "SPDFMacAnnotateSessionPrivate.h"
#import "SPDFMacFillController.h"
#import "SPDFMacFillOverlayView.h"

// A box's handles 0-7 clockwise from the top-left corner: the edges' own arrows, a crosshair on the corners.
static NSCursor* SPDFAnnotateResizeCursor(NSInteger handle) {
    if (handle == 1 || handle == 5) return NSCursor.resizeUpDownCursor;
    if (handle == 3 || handle == 7) return NSCursor.resizeLeftRightCursor;
    return NSCursor.crosshairCursor;
}

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
        // Nothing there (a fully transparent pixel): the colour stays, so the next stroke isn't invisible ink.
        BOOL clear = [picked[@"color"] isKindOfClass:NSString.class] && [picked[@"color"] length] == 9 &&
                     [[picked[@"color"] substringFromIndex:7] isEqualToString:@"00"];
        if ([picked[@"ok"] boolValue] && [picked[@"color"] isKindOfClass:NSString.class] && !clear)
            [self operation:@{@"op": @"colors.set", (right ? @"color2" : @"color1"): picked[@"color"]} page:page done:nil];
        session.tool = session.toolBeforePicker;  // one pick, then back (Paint)
        [self toolDidChange];
        [session noteChange];
        [self.controller refreshChrome];  // the palette shows the tool it went back to
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

#pragma mark - Resizing and the page

// One object takes the new box; several keep their places and sizes relative to the box around them.
- (void)resizeSelectionTo:(NSRect)to page:(NSInteger)page {
    NSDictionary<NSNumber*, NSValue*>* rects = [self rectsForResizeTo:to page:page];  // as shown while dragging
    for (NSNumber* id in rects)
        [self operation:@{@"op": @"object.transform", @"id": id, @"rect": SPDFAnnotateRectObject(rects[id].rectValue)}
                   page:page done:nil];
}

- (NSInteger)pageInView {
    NSArray<NSNumber*>* shown = [self.overlay visiblePages];
    NSInteger current = self.session.currentPage;
    if (current >= 0 && (!shown.count || [shown containsObject:@(current)])) return current;
    NSInteger best = shown.count ? shown.firstObject.integerValue : MAX(0, current);
    CGFloat most = 0;
    for (NSNumber* page in shown) {
        NSRect seen = NSIntersectionRect([self canvasRectForPage:page.integerValue], self.visibleRect);
        if (NSWidth(seen) * NSHeight(seen) > most) most = NSWidth(seen) * NSHeight(seen), best = page.integerValue;
    }
    return best;
}

- (NSRect)placementForSize:(NSSize)size page:(NSInteger)page {
    NSRect canvas = [self canvasRectForPage:page];
    CGFloat scale = [self scaleForPage:page];
    NSRect seen = NSIntersectionRect(canvas, self.visibleRect);
    if (NSIsEmptyRect(seen) || scale <= 0 || size.width <= 0 || size.height <= 0) return NSZeroRect;
    NSRect area = NSMakeRect((NSMinX(seen) - NSMinX(canvas)) / scale, (NSMinY(seen) - NSMinY(canvas)) / scale,
                             NSWidth(seen) / scale, NSHeight(seen) / scale);
    CGFloat fit = MIN(1, MIN(NSWidth(area) * 0.9 / size.width, NSHeight(area) * 0.9 / size.height));
    NSSize placed = NSMakeSize(MAX(1, size.width * fit), MAX(1, size.height * fit));
    return NSMakeRect(round((NSMidX(area) - placed.width / 2) * 100) / 100, round((NSMidY(area) - placed.height / 2) * 100) / 100,
                      placed.width, placed.height);
}

#pragma mark - Pointer

- (BOOL)takesSelectPressAt:(NSPoint)viewPoint {
    SPDFMacAnnotateSession* session = self.session;
    if (session.kind != SPDFAnnotateDocumentPDF || session.tool != SPDFAnnotateToolSelect) return NO;
    if (session.selectedObjects.count && [self objectHandleAt:viewPoint] >= 0) return YES;
    NSInteger page = -1;
    NSPoint point;
    if (![self canvasPointForViewPoint:viewPoint page:&page canvasPoint:&point]) return NO;
    // A page nobody touched yet has no canvas, so its objects can't be found: a press opens it, so the first click
    // selects (hovering opens nothing).
    NSEventType type = NSApp.currentEvent.type;
    if (![self docForPage:page] && (type == NSEventTypeLeftMouseDown || type == NSEventTypeRightMouseDown))
        [session canvasForPage:page document:[self.controller.host fillDocument] create:YES];
    if (![self docForPage:page]) return NO;
    NSString* kind = [self objectAt:point page:page][@"kind"];
    return [@[@"shape", @"text", @"picture", @"pen", @"arrow"] containsObject:kind ?: @""];
}

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
    // Its own tracking area and the overlay's forwarding both hand it the same move: once is enough.
    static NSTimeInterval handled = -1;
    if (event.timestamp == handled) return;
    handled = event.timestamp;
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

// The page view under the canvas asks the topmost view first (SPDFApplyCursorOverlay, SPDFMacCursorOverlay.h).
- (NSCursor*)spdf_cursorForTrackingOverlayAt:(NSPoint)windowPoint {
    return [self cursorAtWindowPoint:windowPoint];
}

- (void)cursorUpdate:(NSEvent*)event {
    [[self cursorAtWindowPoint:event.locationInWindow] set];
}

// The one answer for the pointer over the canvas: the page view under it and the Fill & Sign overlay over it ask here
// too (SPDFApplyCursorOverlay), so the three tracking areas set the same cursor on every move instead of taking turns.
- (NSCursor*)cursorAtWindowPoint:(NSPoint)windowPoint {
    NSPoint view = [self convertPoint:windowPoint fromView:nil];
    SPDFAnnotateCanvasHandle canvas = [self canvasHandleAt:view];
    NSInteger handle = [self objectHandleAt:view];
    if (canvas == SPDFAnnotateCanvasHandleRight) return NSCursor.resizeLeftRightCursor;
    if (canvas == SPDFAnnotateCanvasHandleBottom) return NSCursor.resizeUpDownCursor;
    if (canvas == SPDFAnnotateCanvasHandleCorner || (handle >= 0 && handle < 8)) return SPDFAnnotateResizeCursor(handle);
    if (handle == 8) return NSCursor.openHandCursor;
    if (self.session.tool == SPDFAnnotateToolSelect) return NSCursor.arrowCursor;
    if (self.session.tool == SPDFAnnotateToolTextBox) return NSCursor.IBeamCursor;
    return NSCursor.crosshairCursor;
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

// Type-to-search asks first (SPDFMacFindInteraction.mm): Annotate's letters stay on the canvas.
- (BOOL)handlesTypedKey:(NSEvent*)event {
    return self.session && !self.hidden && SPDFAnnotateClaimsKey(event, self.controller);
}

- (void)keyDown:(NSEvent*)event {
    SPDFMacAnnotateSession* session = self.session;
    NSInteger page = session.kind == SPDFAnnotateDocumentPDF ? session.currentPage : -1;
    NSString* key = event.charactersIgnoringModifiers;
    unichar c = key.length ? [key characterAtIndex:0] : 0;
    BOOL command = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
    // Fill & Sign's Select chose items on the page (a pen line, a mark, its text): Delete, the arrows, Escape, X, V and
    // Space are theirs, as if the overlay had the keyboard.
    if (!command && !session.selectedObjects.count && [self.controller selectedItems].count && self.overlay) {
        [self.overlay keyDown:event];
        return;
    }
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
    if ((c == '\r' || c == 3) && self.gesture == SPDFAnnotateGestureCurve) {  // Return: the curve as bent so far
        [self finishCurveOnPage:self.gesturePage];
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
