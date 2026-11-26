// The canvas view's gestures and keys (SPDFMacAnnotateCanvasView.h): each mouse-down to mouse-up is previewed here
// and sent on release as ONE operation through -applyOperation:tab:completion:. The right button: no movement (4 pt)
// or Control-click opens the context menu of what is under the pointer; a right-drag with a pixel or shape tool draws
// with Color 2. Escape drops the gesture in progress.
#import "SPDFMacFillDrawingStyle.h"
#import "SPDFMacAnnotateCanvasViewPrivate.h"

#import "SPDFMacAnnotateImageIO.h"
#import "SPDFMacAnnotateIntegration.h"
#import "SPDFMacAnnotateSessionPrivate.h"
#import "SPDFMacFillController.h"
#import "SPDFMacFillOverlayView.h"

static const CGFloat kClickSlop = 4.0;  // points: less than this is a click (§ Decisions Right button)

static BOOL IsPixelOrShapeTool(SPDFAnnotateTool tool) {
    return tool == SPDFAnnotateToolPencil || tool == SPDFAnnotateToolBrush || tool == SPDFAnnotateToolEraser ||
           tool == SPDFAnnotateToolShape || tool == SPDFAnnotateToolFill || tool == SPDFAnnotateToolColorPicker ||
           tool == SPDFAnnotateToolMagnifier;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation SPDFMacAnnotateCanvasView (Gestures)

#pragma mark - Settings of the chosen tool

- (NSDictionary*)toolOptions {
    return [SPDFAnnotateSettings.shared optionsForTool:SPDFAnnotateToolName(self.session.tool, self.session.brush)];
}

- (CGFloat)toolSize {
    CGFloat size = [[self toolOptions][@"size"] doubleValue];
    if (size > 0) return size;
    switch (self.session.tool) {
        case SPDFAnnotateToolPencil: return 1;
        case SPDFAnnotateToolEraser: return 4;
        case SPDFAnnotateToolPen:
        case SPDFAnnotateToolArrow: return 2;
        default: return 5;
    }
}

- (NSString*)colorFor:(BOOL)second {
    // Pen and Arrow draw in the colour chosen in their own row (Fill & Sign's four), as Fill & Sign's pen does.
    SPDFAnnotateTool tool = self.session.tool;
    if (!second && (tool == SPDFAnnotateToolPen || tool == SPDFAnnotateToolArrow)) {
        SPDFFillRGB c = [SPDFMacFillDrawingStyle colorAtIndex:[SPDFMacFillDrawingStyle sharedStyle].colorIndex];
        return [NSString stringWithFormat:@"#%02X%02X%02X", (int)lround(c.r * 255), (int)lround(c.g * 255),
                                          (int)lround(c.b * 255)];
    }
    return SPDFAnnotateColorString(second ? self.session.color2 : self.session.color1);
}

#pragma mark - Hit tests

- (NSDictionary*)objectAt:(NSPoint)point page:(NSInteger)page {
    CGFloat slop = 3 / MAX([self scaleForPage:page], 0.01);
    for (NSDictionary* object in [self objectsOnPage:page]) {
        if ([object[@"locked"] boolValue]) continue;
        if (NSPointInRect(point, NSInsetRect([object[@"bounds"] rectValue], -slop, -slop))) return object;
    }
    return nil;
}

- (BOOL)pointInPixelSelection:(NSPoint)point page:(NSInteger)page {
    NSDictionary* box = [self selectionOnPage:page][@"bounds"];
    if (![box isKindOfClass:NSDictionary.class]) return NO;
    return NSPointInRect(point, NSMakeRect([box[@"x"] doubleValue], [box[@"y"] doubleValue], [box[@"w"] doubleValue],
                                           [box[@"h"] doubleValue]));
}

- (NSPoint)canvasPointOf:(NSEvent*)event page:(NSInteger*)page {
    NSPoint view = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger found = self.gesture != SPDFAnnotateGestureNone ? self.gesturePage : -1;
    NSPoint point = NSZeroPoint;
    if (self.gesture == SPDFAnnotateGestureNone) {
        [self canvasPointForViewPoint:view page:&found canvasPoint:&point];
        // A handle of an object hanging over the page's edge, pressed off the page: the selection's page.
        if (found < 0 && self.session.selectedObjects.count && [self objectHandleAt:view] >= 0)
            found = self.session.kind == SPDFAnnotateDocumentPDF ? [self pageInView] : -1;
        // A press or click on a page nothing was added to yet: its canvas opens now, so the gesture has one to preview
        // on and the operation names that page.
        if (found >= 0 && self.session.kind == SPDFAnnotateDocumentPDF && ![self docForPage:found])
            [self.session canvasForPage:found document:[self.controller.host fillDocument] create:YES];
    }
    NSRect canvas = [self canvasRectForPage:found];
    CGFloat scale = [self scaleForPage:found];
    point = NSMakePoint((view.x - NSMinX(canvas)) / scale, (view.y - NSMinY(canvas)) / scale);
    if (page) *page = found;
    return point;
}

#pragma mark - Mouse

- (void)mouseDown:(NSEvent*)event {
    if (self.textEditor) {
        [self commitTextEditor];
        return;
    }
    if (event.modifierFlags & NSEventModifierFlagControl) {
        [self showContextMenu:event];
        return;
    }
    [self takeKeys];
    [self beginGesture:event right:NO];
}

- (void)rightMouseDown:(NSEvent*)event {
    if (self.textEditor) [self commitTextEditor];
    NSInteger page = -1;
    NSPoint point = [self canvasPointOf:event page:&page];
    self.gesture = SPDFAnnotateGesturePendingRight;
    self.gesturePage = page;
    self.startView = [self convertPoint:event.locationInWindow fromView:nil];
    self.startPoint = self.currentPoint = point;
}

- (void)rightMouseDragged:(NSEvent*)event {
    if (self.gesture == SPDFAnnotateGesturePendingRight) {
        NSPoint view = [self convertPoint:event.locationInWindow fromView:nil];
        if (hypot(view.x - self.startView.x, view.y - self.startView.y) < kClickSlop) return;
        if (!IsPixelOrShapeTool(self.session.tool)) return;  // a right-drag elsewhere is nothing; release: no menu
        self.gesture = SPDFAnnotateGestureNone;
        [self beginGesture:event right:YES];
        // The press was where the button went down, not where the drag was recognised.
        if (self.gesture == SPDFAnnotateGestureStroke && self.points.count) {
            [self.points insertObject:@(self.startPoint) atIndex:0];
            [self.pressures insertObject:@1 atIndex:0];
        }
    }
    [self mouseDragged:event];
}

- (void)rightMouseUp:(NSEvent*)event {
    if (self.gesture == SPDFAnnotateGesturePendingRight) {
        self.gesture = SPDFAnnotateGestureNone;
        // Right-click without moving: Fill and the colour picker take Color 2; everything else shows the menu.
        if (self.session.tool == SPDFAnnotateToolFill || self.session.tool == SPDFAnnotateToolColorPicker ||
            self.session.tool == SPDFAnnotateToolMagnifier) {
            [self beginGesture:event right:YES];
            [self mouseUp:event];
            return;
        }
        [self showContextMenu:event];
        return;
    }
    [self mouseUp:event];
}

- (void)showContextMenu:(NSEvent*)event {
    NSInteger page = -1;
    NSPoint point = [self canvasPointOf:event page:&page];
    NSDictionary* hit = [self objectAt:point page:page];
    if (hit && ![self.session.selectedObjects containsObject:hit[@"id"]]) self.session.selectedObjects = @[hit[@"id"]];
    NSMenu* menu = SPDFAnnotateContextMenu(self.controller, page, point);
    if (menu) [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

- (void)beginGesture:(NSEvent*)event right:(BOOL)right {
    SPDFMacAnnotateSession* session = self.session;
    NSInteger page = -1;
    NSPoint point = [self canvasPointOf:event page:&page];
    NSPoint view = [self convertPoint:event.locationInWindow fromView:nil];
    if (page < 0 && session.kind == SPDFAnnotateDocumentPDF) return;  // between pages
    self.gesturePage = page;
    if (page >= 0) session.currentPage = page;
    self.rightButton = right;
    self.startView = view;
    self.startPoint = self.currentPoint = point;
    self.gestureModifiers = event.modifierFlags;
    // A polygon's next corner and a curve's bends add to the gesture already there.
    BOOL continuing = session.tool == SPDFAnnotateToolShape && self.points.count &&
                      (self.gesture == SPDFAnnotateGesturePolygon || self.gesture == SPDFAnnotateGestureCurve);
    if (!continuing) {
        [self.points removeAllObjects];
        [self.pressures removeAllObjects];
    }
    if (!right && !continuing) {
        SPDFAnnotateCanvasHandle canvasHandle = [self canvasHandleAt:view];
        if (canvasHandle != SPDFAnnotateCanvasHandleNone) {
            int width = 0, height = 0;
            spdf_paint_size(session.canvas, &width, &height);
            self.canvasHandle = canvasHandle;
            self.liveResizeSize = NSMakeSize(width, height);
            self.gesture = SPDFAnnotateGestureCanvasResize;
            return;
        }
        NSInteger handle = [self objectHandleAt:view];
        if (handle >= 0 && session.selectedObjects.count) {
            NSDictionary* object = nil;
            for (NSDictionary* candidate in [self objectsOnPage:page])
                if ([candidate[@"id"] isEqual:session.selectedObjects.firstObject]) object = candidate;
            self.handle = handle;
            NSRect rect = [object[@"rect"] rectValue];
            if (session.selectedObjects.count > 1)  // the box around their own boxes, which the new one maps onto
                for (NSDictionary* other in [self objectsOnPage:page])
                    if ([session.selectedObjects containsObject:other[@"id"]]) rect = NSUnionRect(rect, [other[@"rect"] rectValue]);
            self.originalRect = NSIsEmptyRect(rect) ? [self boundsOfObjects:session.selectedObjects page:page] : rect;
            self.originalRotation = [object[@"rotation"] doubleValue];
            self.gesture = handle == 8 ? SPDFAnnotateGestureRotate : SPDFAnnotateGestureResize;
            return;
        }
    }
    switch (session.tool) {
        case SPDFAnnotateToolSelect: {
            NSDictionary* hit = [self objectAt:point page:page];
            if (hit && event.clickCount == 2 && [hit[@"kind"] isEqual:@"text"]) {
                [self editTextObject:hit page:page];
                return;
            }
            if (hit) {
                NSMutableArray* selected = [session.selectedObjects mutableCopy];
                if (event.modifierFlags & NSEventModifierFlagShift) {
                    if ([selected containsObject:hit[@"id"]]) [selected removeObject:hit[@"id"]];
                    else [selected addObject:hit[@"id"]];
                } else if (![selected containsObject:hit[@"id"]]) {
                    selected = [@[hit[@"id"]] mutableCopy];
                }
                session.selectedObjects = selected;
                self.dragObjects = selected;
                self.gesture = SPDFAnnotateGestureMove;
            } else {
                if (!(event.modifierFlags & NSEventModifierFlagShift)) session.selectedObjects = @[];
                self.gesture = SPDFAnnotateGestureBoxSelect;
            }
            break;
        }
        case SPDFAnnotateToolRectSelect:
        case SPDFAnnotateToolFreeformSelect:
            if ([self pointInPixelSelection:point page:page]) {
                self.dragObjects = nil;  // lifted on the first movement
                self.gesture = SPDFAnnotateGestureMove;
            } else {
                self.gesture = session.tool == SPDFAnnotateToolRectSelect ? SPDFAnnotateGestureRectSelect
                                                                          : SPDFAnnotateGestureLasso;
                if (self.gesture == SPDFAnnotateGestureLasso) [self.points addObject:@(point)];
            }
            break;
        case SPDFAnnotateToolPencil:
        case SPDFAnnotateToolBrush:
        case SPDFAnnotateToolEraser:
        case SPDFAnnotateToolPen:
            self.gesture = SPDFAnnotateGestureStroke;
            [self.points addObject:@(point)];
            [self.pressures addObject:@(event.pressure > 0 ? event.pressure : 1)];
            break;
        case SPDFAnnotateToolArrow:
            self.gesture = SPDFAnnotateGestureShape;
            break;
        case SPDFAnnotateToolShape:
            if ([session.shape isEqual:@"polygon"]) {
                self.gesture = SPDFAnnotateGesturePolygon;
            } else if ([session.shape isEqual:@"curve"]) {
                self.gesture = SPDFAnnotateGestureCurve;
            } else {
                self.gesture = SPDFAnnotateGestureShape;
            }
            break;
        case SPDFAnnotateToolTextBox:
            self.gesture = SPDFAnnotateGestureTextBox;
            break;
        default:  // Fill, Color picker, Magnifier act on release
            self.gesture = SPDFAnnotateGestureNone;
            break;
    }
    [self setNeedsDisplayInRect:NSInsetRect(NSMakeRect(view.x, view.y, 0, 0), -40, -40)];
}

- (void)mouseDragged:(NSEvent*)event {
    if (self.gesture == SPDFAnnotateGestureNone || self.gesture == SPDFAnnotateGesturePendingRight) return;
    NSPoint point = [self canvasPointOf:event page:NULL];
    NSPoint previous = self.currentPoint;
    self.currentPoint = point;
    self.gestureModifiers = event.modifierFlags;
    CGFloat scale = [self scaleForPage:self.gesturePage];
    switch (self.gesture) {
        case SPDFAnnotateGestureStroke:
        case SPDFAnnotateGestureLasso: {
            NSPoint last = self.points.lastObject.pointValue;
            if (hypot(point.x - last.x, point.y - last.y) * scale < 0.5) return;
            if (self.gesture == SPDFAnnotateGestureStroke && [self shiftStraightensStroke:event]) {
                [self straightenStrokeTo:point];  // Shift: one straight line from the press, at 45 degree steps
                self.needsDisplay = YES;
                break;
            }
            [self.points addObject:@(point)];
            [self.pressures addObject:@(event.pressure > 0 ? event.pressure : 1)];
            // Not NSUnionRect: it drops zero-size rects, so the segment came out as the canvas's corner and the line
            // only showed once the stroke was released.
            NSRect segment = NSMakeRect(MIN(last.x, point.x), MIN(last.y, point.y), fabs(point.x - last.x),
                                        fabs(point.y - last.y));
            if (event.modifierFlags & NSEventModifierFlagShift) self.needsDisplay = YES;
            else [self redrawCanvasRect:segment page:self.gesturePage inflate:[self toolSize] * scale + 4];
            break;
        }
        case SPDFAnnotateGestureMove:
            if (!self.dragObjects && hypot(point.x - self.startPoint.x, point.y - self.startPoint.y) * scale >= kClickSlop)
                [self liftSelection];
            self.needsDisplay = YES;
            break;
        case SPDFAnnotateGestureCanvasResize: {
            int width = 0, height = 0;
            spdf_paint_size(self.session.canvas, &width, &height);
            CGFloat w = width, h = height;
            // From where the handle was taken, so grabbing it a few points off the edge changes nothing.
            if (self.canvasHandle != SPDFAnnotateCanvasHandleBottom) w = round(width + point.x - self.startPoint.x);
            if (self.canvasHandle != SPDFAnnotateCanvasHandleRight) h = round(height + point.y - self.startPoint.y);
            if (self.canvasHandle == SPDFAnnotateCanvasHandleCorner && (event.modifierFlags & NSEventModifierFlagShift))
                h = round(w * height / (CGFloat)MAX(1, width));
            w = MAX(1, MIN(SPDF_PAINT_MAX_SIDE, w));
            h = MAX(1, MIN(SPDF_PAINT_MAX_SIDE, h));
            while (w * h > SPDF_PAINT_MAX_PIXELS) h = floor(SPDF_PAINT_MAX_PIXELS / w);
            self.liveResizeSize = NSMakeSize(w, h);
            [NSNotificationCenter.defaultCenter postNotificationName:SPDFAnnotateCanvasPointerDidMoveNotification
                                                              object:self];
            self.needsDisplay = YES;
            break;
        }
        default:
            (void)previous;
            self.needsDisplay = YES;
            break;
    }
    [self notePointer:point page:self.gesturePage inside:YES];
    [self autoscroll:event];
}

- (void)liftSelection {
    self.dragObjects = @[];
    __weak SPDFMacAnnotateCanvasView* weakSelf = self;
    [self operation:@{@"op": @"select.lift"} page:self.gesturePage done:^(NSDictionary* result) {
        SPDFMacAnnotateCanvasView* view = weakSelf;
        if (![result[@"ok"] boolValue] || !result[@"id"]) return;
        view.session.selectedObjects = @[result[@"id"]];
        view.dragObjects = @[result[@"id"]];
    }];
}

- (void)mouseUp:(NSEvent*)event {
    SPDFAnnotateGesture gesture = self.gesture;
    if (gesture == SPDFAnnotateGesturePendingRight) return;
    NSInteger page = self.gesturePage;
    NSPoint point = gesture == SPDFAnnotateGestureNone ? [self canvasPointOf:event page:&page]
                                                       : [self canvasPointOf:event page:NULL];
    self.currentPoint = point;
    CGFloat scale = [self scaleForPage:page];
    BOOL moved = hypot(point.x - self.startPoint.x, point.y - self.startPoint.y) * scale >= kClickSlop;
    SPDFMacAnnotateSession* session = self.session;
    BOOL right = self.rightButton;
    if (gesture != SPDFAnnotateGesturePolygon && gesture != SPDFAnnotateGestureCurve)
        self.gesture = SPDFAnnotateGestureNone;
    self.needsDisplay = YES;  // a change on a PDF page shows before this returns: the gesture's preview goes with it
    __weak SPDFMacAnnotateCanvasView* weakSelf = self;
    void (^selectAnswer)(NSDictionary*) = ^(NSDictionary* result) {
        if ([result[@"ok"] boolValue] && result[@"id"]) weakSelf.session.selectedObjects = @[result[@"id"]];
    };
    switch (gesture) {
        case SPDFAnnotateGestureStroke: {
            // The release point ends the stroke (a quick flick can release away from the last drag).
            NSPoint last = self.points.lastObject.pointValue;
            if (self.points.count && [self shiftStraightensStroke:event]) {
                [self straightenStrokeTo:point];
            } else if (self.points.count && hypot(point.x - last.x, point.y - last.y) * scale >= 0.5) {
                [self.points addObject:@(point)];
                [self.pressures addObject:self.pressures.lastObject ?: @1];
            }
            [self finishStrokeOnPage:page right:right];
            break;
        }
        case SPDFAnnotateGestureShape: {
            if (!moved) {  // a click with a shape tool selects the object under it (§ 3)
                NSDictionary* hit = [self objectAt:point page:page];
                session.selectedObjects = hit ? @[hit[@"id"]] : @[];
                break;
            }
            NSString* outline = [self colorFor:right], *fill = [self colorFor:!right];
            if (session.tool == SPDFAnnotateToolArrow) {
                [self operation:@{@"op": @"arrow.add", @"tail": SPDFAnnotatePointArray(self.startPoint),
                                  @"tip": SPDFAnnotatePointArray([self constrainedEnd]), @"color": outline, @"width": @([self toolSize])}
                           page:page done:selectAnswer];
                break;
            }
            NSDictionary* options = [SPDFAnnotateSettings.shared optionsForTool:@"shape"];
            NSMutableDictionary* outlineStyle = [@{@"style": @"solid", @"width": @3} mutableCopy];
            if ([options[@"outline"] isKindOfClass:NSDictionary.class]) [outlineStyle addEntriesFromDictionary:options[@"outline"]];
            outlineStyle[@"color"] = outline;
            NSMutableDictionary* fillStyle = [@{@"style": @"none"} mutableCopy];
            if ([options[@"fill"] isKindOfClass:NSDictionary.class]) [fillStyle addEntriesFromDictionary:options[@"fill"]];
            fillStyle[@"color"] = fill;
            NSMutableDictionary* op = [@{@"op": @"shape.add", @"shape": session.shape, @"outline": outlineStyle,
                                         @"fill": fillStyle} mutableCopy];
            if ([session.shape isEqual:@"line"] || [session.shape isEqual:@"arrow_line"] || [session.shape isEqual:@"curve"])
                op[@"points"] = @[SPDFAnnotatePointArray(self.startPoint), SPDFAnnotatePointArray([self constrainedEnd])];
            else
                op[@"rect"] = SPDFAnnotateRectObject([self gestureCanvasRect]);
            [self operation:op page:page done:selectAnswer];
            break;
        }
        case SPDFAnnotateGesturePolygon: {
            NSPoint first = self.points.firstObject.pointValue;
            BOOL closes = self.points.count >= 3 &&
                          (event.clickCount >= 2 || hypot(point.x - first.x, point.y - first.y) * scale < 8);
            if (!closes) {
                [self.points addObject:@(point)];
                self.needsDisplay = YES;
                break;
            }
            [self finishPolygonOnPage:page];
            break;
        }
        case SPDFAnnotateGestureCurve:
            [self curveReleasedAt:point page:page moved:moved];
            break;
        case SPDFAnnotateGestureRectSelect:
            if (moved) {
                NSRect r = [self gestureCanvasRect];
                [self operation:@{@"op": @"select.rect", @"x": @(NSMinX(r)), @"y": @(NSMinY(r)), @"w": @(MAX(1, NSWidth(r))),
                                  @"h": @(MAX(1, NSHeight(r)))} page:page done:nil];
            } else {
                [self operation:@{@"op": @"select.none"} page:page done:nil];
            }
            break;
        case SPDFAnnotateGestureLasso: {
            NSMutableArray* points = [NSMutableArray array];
            for (NSValue* value in self.points) [points addObject:SPDFAnnotatePointArray(value.pointValue)];
            [self operation:points.count >= 3 && moved ? @{@"op": @"select.freeform", @"points": points}
                                                       : @{@"op": @"select.none"}
                       page:page done:nil];
            break;
        }
        case SPDFAnnotateGestureBoxSelect: {
            if (!moved) break;
            NSRect box = [self gestureCanvasRect];
            NSMutableArray* picked = [session.selectedObjects mutableCopy];
            for (NSDictionary* object in [self objectsOnPage:page])
                if (![object[@"locked"] boolValue] && NSIntersectsRect(box, [object[@"bounds"] rectValue]) &&
                    ![picked containsObject:object[@"id"]])
                    [picked addObject:object[@"id"]];
            session.selectedObjects = picked;
            break;
        }
        case SPDFAnnotateGestureMove:
            if (moved && self.dragObjects.count)
                [self operation:@{@"op": @"object.move", @"ids": self.dragObjects,
                                  @"dx": @(point.x - self.startPoint.x), @"dy": @(point.y - self.startPoint.y)}
                           page:page done:nil];
            break;
        case SPDFAnnotateGestureResize:
            if (moved) [self resizeSelectionTo:[self resizedRect] page:page];
            break;
        case SPDFAnnotateGestureRotate:
            if (moved)
                [self operation:@{@"op": @"object.transform", @"id": session.selectedObjects.firstObject,
                                  @"rotation": @(self.originalRotation + [self rotationDelta])} page:page done:nil];
            break;
        case SPDFAnnotateGestureCanvasResize: {
            NSSize size = self.liveResizeSize;
            self.liveResizeSize = NSZeroSize;
            int width = 0, height = 0;
            spdf_paint_size(session.canvas, &width, &height);
            if ((int)size.width != width || (int)size.height != height)
                [self operation:@{@"op": @"canvas.resize", @"width": @((int)size.width), @"height": @((int)size.height),
                                  @"anchor": @"top-left"} page:-1 done:nil];
            break;
        }
        case SPDFAnnotateGestureTextBox: {
            NSRect r = moved ? [self gestureCanvasRect] : NSMakeRect(point.x, point.y, 0, 0);
            [self openTextEditorAt:r page:page object:nil text:@""];
            break;
        }
        case SPDFAnnotateGestureNone:
            [self clickWithTool:session.tool at:point page:page right:right event:event];
            break;
        default:
            break;
    }
    self.rightButton = NO;
    self.needsDisplay = YES;
}


@end
#pragma clang diagnostic pop
