// The drawing tools on the overlay: Pen, Arrow, Eraser and Select gestures, their pointer, keys and menu
// (docs/plans/fill-and-sign.md, "Pen and arrow"). During a gesture only the overlay changes; on release the change is
// handed to the controller, which writes it as one undo step. What is on screen is painted in +DrawingLayer.mm.
#import "SPDFMacFillDrawingState.h"

#import "SPDFMacDocumentView.h"
#import "SPDFMacFillController.h"
#import "SPDFMacFillDrawingStyle.h"
#import "SPDFMacFillEditor.h"
#import "SPDFMacModels.h"

#include "spdf_fill_ink_geometry.h"

#include <vector>

static const int kSPDFFillMaxPointsPerLine = 4000;

static spdf_fill_point SPDFFillPoint(NSPoint p) {
    spdf_fill_point out = {(float)p.x, (float)p.y};
    return out;
}

// A line's points for hit tests: a pen line as drawn; an arrow's shaft and head as one path.
static std::vector<spdf_fill_point> SPDFFillHitPoints(SPDFFillItem* item) {
    std::vector<spdf_fill_point> points(item.pointBytes, item.pointBytes + item.pointCount);
    if (item.kind == SPDF_FILL_ARROW && points.size() >= 2) {
        spdf_fill_point head[3];
        spdf_ink_arrow_head(points[0], points[1], (float)item.lineWidth, head);
        points.resize(2);
        points.push_back(head[0]);
        points.push_back(head[1]);
        points.push_back(head[2]);
    }
    return points;
}

@implementation SPDFMacFillOverlayView (DrawingHooks)

- (SPDFFillTool)tool {
    return [self.controller session].tool;
}

- (BOOL)drawingsAnswerPointer {
    SPDFFillTool tool = [self tool];
    return tool == SPDFFillToolSelect || tool == SPDFFillToolEraser;
}

// Near the ink itself, never just inside its box, so a big circle does not catch clicks inside it.
- (BOOL)drawing:(SPDFFillItem*)item isNear:(NSPoint)p {
    CGFloat zoom = [self zoom];
    CGFloat reach = MAX(4.0 / zoom, item.lineWidth / 2 + 3.0 / zoom);
    if (!NSPointInRect(p, NSInsetRect(item.rect, -reach, -reach))) return NO;
    std::vector<spdf_fill_point> points = SPDFFillHitPoints(item);
    return spdf_ink_distance_to_polyline(points.data(), (int)points.size(), SPDFFillPoint(p)) <= reach;
}

- (void)cancelDrawingGesture {
    SPDFFillDrawingState* state = [self drawingState];
    state.page = -1;
    state.live = nil;
    state.hasLiveTail = NO;
    state.erasing = nil;
    state.swath = nil;
    state.swathRadius = 0;
    state.banding = NO;
    state.moving = nil;
    state.delta = NSZeroSize;
    state.nudging = NO;
    state.endArrow = nil;
    state.endPreview = nil;
    self.needsDisplay = YES;
}

// The next drag or release of a gesture, or nil when Escape ends it (nothing is written then).
- (NSEvent*)nextGestureEvent {
    for (;;) {
        NSEvent* event = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp |
                                                            NSEventMaskKeyDown
                                                  untilDate:NSDate.distantFuture
                                                     inMode:NSEventTrackingRunLoopMode
                                                    dequeue:YES];
        if (!event) return nil;
        if (event.type != NSEventTypeKeyDown) return event;
        if (event.keyCode == 53) return nil;
    }
}

- (BOOL)drawingMouseDown:(NSEvent*)event {
    SPDFFillTool tool = [self tool];
    if (!SPDFFillToolDraws(tool)) return NO;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger page;
    if (![self locateViewPoint:point page:&page pagePoint:NULL]) return YES;
    [self.controller.editor commitAndClose];
    [self.window makeFirstResponder:self];
    if (tool != SPDFFillToolPen && tool != SPDFFillToolArrow) [self.controller writePendingStrokes];
    [self commitNudge];
    switch (tool) {
        case SPDFFillToolPen: [self trackPenFrom:point page:page]; break;
        case SPDFFillToolArrow: [self trackArrowFrom:point page:page]; break;
        case SPDFFillToolEraser: [self trackEraserFrom:point page:page]; break;
        default: [self trackSelectFrom:point page:page event:event]; break;
    }
    [self cancelDrawingGesture];
    [self drawingHover:[self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil]];
    return YES;
}

#pragma mark - Pen and arrow

- (void)trackPenFrom:(NSPoint)start page:(NSInteger)page {
    SPDFMacFillDrawingStyle* style = [SPDFMacFillDrawingStyle sharedStyle];
    SPDFFillDrawingState* state = [self drawingState];
    CGFloat zoom = [self zoom];
    float tolerance = (float)(0.1 / zoom), gap = (float)(0.75 / zoom);
    spdf_fill_point first = SPDFFillPoint([self pagePointForViewPoint:start page:page]);
    std::vector<spdf_fill_point> raw(1, first), flat(1, first);
    spdf_fill_point piece[256];
    auto flatten = [&](size_t i) {  // the curve from raw[i] to raw[i + 1]
        spdf_fill_point p0 = raw[i > 0 ? i - 1 : i], p3 = raw[i + 2 < raw.size() ? i + 2 : i + 1];
        int n = spdf_ink_flatten_segment(p0, raw[i], raw[i + 1], p3, tolerance, 1.5f, piece, 256);
        flat.insert(flat.end(), piece, piece + n);
    };
    state.page = page;
    BOOL straight = NO, finished = NO;
    spdf_fill_point end = first;
    for (NSEvent* event; (event = [self nextGestureEvent]);) {
        end = SPDFFillPoint([self pagePointForViewPoint:[self convertPoint:event.locationInWindow fromView:nil]
                                                   page:page]);
        straight = (event.modifierFlags & NSEventModifierFlagShift) != 0;
        if (!straight && hypotf(end.x - raw.back().x, end.y - raw.back().y) >= gap) {
            raw.push_back(end);
            if (raw.size() >= 3) flatten(raw.size() - 3);
        }
        spdf_fill_point line[2] = {first, end};
        state.live = [SPDFFillItem strokeOfKind:SPDF_FILL_PEN page:page points:straight ? line : flat.data()
                                          count:straight ? 2 : (int)flat.size() color:style.color width:style.width];
        state.hasLiveTail = !straight;
        state.liveTail = NSMakePoint(end.x, end.y);
        self.needsDisplay = YES;
        if (event.type == NSEventTypeLeftMouseUp) {
            finished = YES;
            break;
        }
    }
    if (!finished) return;
    if (straight) {
        flat.assign(1, first);
        flat.push_back(end);
    } else if (raw.size() >= 2) {
        flatten(raw.size() - 2);
    }
    // Exactly what was drawn, less points nobody could see; a very long line goes on as a new one.
    int count = spdf_ink_simplify(flat.data(), (int)flat.size(), 0.05f);
    NSMutableArray* strokes = [NSMutableArray array];
    for (int from = 0; from < count;) {
        int n = MIN(kSPDFFillMaxPointsPerLine, count - from);
        [strokes addObject:[SPDFFillItem strokeOfKind:SPDF_FILL_PEN page:page points:flat.data() + from count:n
                                                color:style.color width:style.width]];
        from += n;
        if (from < count) from -= 1;  // the next piece starts where this one ends
    }
    [self.controller addDrawnStrokes:strokes];
}

- (void)trackArrowFrom:(NSPoint)start page:(NSInteger)page {
    SPDFMacFillDrawingStyle* style = [SPDFMacFillDrawingStyle sharedStyle];
    SPDFFillDrawingState* state = [self drawingState];
    spdf_fill_point ends[2];
    ends[0] = ends[1] = SPDFFillPoint([self pagePointForViewPoint:start page:page]);
    NSPoint last = start;
    state.page = page;
    BOOL finished = NO;
    for (NSEvent* event; (event = [self nextGestureEvent]);) {
        last = [self convertPoint:event.locationInWindow fromView:nil];
        ends[1] = SPDFFillPoint([self pagePointForViewPoint:last page:page]);
        if (event.modifierFlags & NSEventModifierFlagShift) ends[1] = [self snapAngleFrom:ends[0] to:ends[1] page:page];
        state.live = [SPDFFillItem strokeOfKind:SPDF_FILL_ARROW page:page points:ends count:2 color:style.color
                                          width:style.width];
        self.needsDisplay = YES;
        if (event.type == NSEventTypeLeftMouseUp) {
            finished = YES;
            break;
        }
    }
    if (!finished || hypot(last.x - start.x, last.y - start.y) < 4) return;
    [self.controller addDrawnStrokes:@[ [SPDFFillItem strokeOfKind:SPDF_FILL_ARROW page:page points:ends count:2
                                                             color:style.color width:style.width] ]];
}

// Shift: the direction from `from` in 15 degree steps, same length, kept on the page.
- (spdf_fill_point)snapAngleFrom:(spdf_fill_point)from to:(spdf_fill_point)to page:(NSInteger)page {
    double length = hypot(to.x - from.x, to.y - from.y);
    double step = M_PI / 12, angle = round(atan2(to.y - from.y, to.x - from.x) / step) * step;
    CGAffineTransform t = [self pageToView:page];
    NSPoint p = NSMakePoint(from.x + length * cos(angle), from.y + length * sin(angle));
    return SPDFFillPoint([self pagePointForViewPoint:CGPointApplyAffineTransform(p, t) page:page]);
}

#pragma mark - Eraser

- (void)trackEraserFrom:(NSPoint)start page:(NSInteger)page {
    SPDFMacFillDrawingStyle* style = [SPDFMacFillDrawingStyle sharedStyle];
    SPDFFillDrawingState* state = [self drawingState];
    CGFloat zoom = [self zoom];
    BOOL parts = style.eraserParts;
    CGFloat radius = parts ? style.eraserSize / 2 / zoom : 6 / zoom;
    NSMutableArray<SPDFFillItem*>* lines = [NSMutableArray array];
    for (SPDFFillItem* item in [self.controller itemsOnPage:page])
        if (item.isDrawing) [lines addObject:item];
    std::vector<spdf_fill_point> swath(1, SPDFFillPoint([self pagePointForViewPoint:start page:page]));
    state.page = page;
    state.erasing = [NSMutableArray array];
    state.swathRadius = parts ? radius : 0;
    BOOL finished = NO;
    NSEvent* event = nil;
    for (size_t from = 0;; from = swath.size() - 2) {
        // Whole lines: every line the newest piece of the eraser's path comes near fades at once.
        for (SPDFFillItem* line in parts ? @[] : [lines copy]) {
            float reach = (float)(radius + line.lineWidth / 2);
            std::vector<spdf_fill_point> points = SPDFFillHitPoints(line);
            if (spdf_ink_polyline_distance(points.data(), (int)points.size(), swath.data() + from,
                                           (int)(swath.size() - from)) > reach)
                continue;
            [state.erasing addObject:line];
            [lines removeObject:line];
        }
        state.swath = parts ? [NSMutableData dataWithBytes:swath.data() length:swath.size() * sizeof(spdf_fill_point)]
                            : nil;
        self.needsDisplay = YES;
        if (event.type == NSEventTypeLeftMouseUp) {
            finished = YES;
            break;
        }
        if (!(event = [self nextGestureEvent])) break;
        swath.push_back(SPDFFillPoint([self pagePointForViewPoint:[self convertPoint:event.locationInWindow fromView:nil]
                                                             page:page]));
    }
    if (!finished) return;
    if (!parts) {
        if (state.erasing.count) [self.controller removeItems:state.erasing];
        return;
    }
    NSMutableArray<SPDFFillItem*>* originals = [NSMutableArray array];
    NSMutableArray<SPDFFillItem*>* pieces = [NSMutableArray array];
    for (SPDFFillItem* line in lines) [self erase:line swath:swath radius:radius originals:originals pieces:pieces];
    if (originals.count) [self.controller replaceItems:originals withStrokes:pieces];
}

// Parts: what the eraser leaves of one line. An arrow keeps its head on the piece that still ends at its tip, unless
// the head itself was rubbed; every other piece is a plain pen line.
- (void)erase:(SPDFFillItem*)line swath:(const std::vector<spdf_fill_point>&)swath radius:(CGFloat)radius
    originals:(NSMutableArray*)originals pieces:(NSMutableArray*)pieces {
    float reach = (float)(radius + line.lineWidth / 2);
    BOOL arrow = line.kind == SPDF_FILL_ARROW;
    int count = arrow ? MIN(2, line.pointCount) : line.pointCount;
    BOOL headRubbed = NO;
    if (arrow && count == 2) {
        spdf_fill_point head[3];
        spdf_ink_arrow_head(line.pointBytes[0], line.pointBytes[1], (float)line.lineWidth, head);
        headRubbed = spdf_ink_polyline_distance(head, 3, swath.data(), (int)swath.size()) <= reach;
    }
    spdf_ink_runs runs;
    if (!spdf_ink_erase(line.pointBytes, count, swath.data(), (int)swath.size(), reach, (float)line.lineWidth, &runs))
        return;
    if (runs.touched || headRubbed) {
        [originals addObject:line];
        spdf_fill_point* p = runs.points;
        for (int i = 0; i < runs.run_count; p += runs.run_lengths[i], ++i) {
            BOOL keepsHead = arrow && !headRubbed && i == runs.run_count - 1 && runs.last_run_keeps_end;
            spdf_fill_point shaft[2] = {p[0], p[runs.run_lengths[i] - 1]};
            int n = keepsHead ? 2 : spdf_ink_simplify(p, runs.run_lengths[i], 0.05f);
            [pieces addObject:[SPDFFillItem strokeOfKind:keepsHead ? SPDF_FILL_ARROW : SPDF_FILL_PEN page:line.page
                                                  points:keepsHead ? shaft : p count:n color:line.color
                                                   width:line.lineWidth]];
        }
    }
    spdf_ink_free_runs(&runs);
}

#pragma mark - Select

- (NSInteger)arrowEndAt:(NSPoint)point of:(SPDFFillItem*)arrow {
    if (arrow.kind != SPDF_FILL_ARROW || arrow.pointCount < 2) return -1;
    CGAffineTransform t = [self pageToView:arrow.page];
    for (NSInteger i = 1; i >= 0; --i) {
        NSPoint end = CGPointApplyAffineTransform(NSMakePoint(arrow.pointBytes[i].x, arrow.pointBytes[i].y), t);
        if (hypot(end.x - point.x, end.y - point.y) <= 7) return i;
    }
    return -1;
}

- (NSArray<SPDFFillItem*>*)selectionOnPage:(NSInteger)page {
    return [self.controller session].selectionPage == page ? [self.controller selectedItems] : @[];
}

- (void)trackSelectFrom:(NSPoint)start page:(NSInteger)page event:(NSEvent*)down {
    SPDFFillDrawingState* state = [self drawingState];
    NSPoint p = [self pagePointForViewPoint:start page:page];
    NSArray<SPDFFillItem*>* selected = [self selectionOnPage:page];
    NSInteger end = selected.count == 1 ? [self arrowEndAt:start of:selected.firstObject] : -1;
    if (end >= 0) {
        [self trackArrowEnd:end of:selected.firstObject];
        return;
    }
    SPDFFillItem* hit = [self itemAt:p page:page];
    BOOL shift = (down.modifierFlags & NSEventModifierFlagShift) != 0;
    if (hit && down.clickCount == 2 && hit.text) {
        [self.controller openEditorForItem:hit];
        return;
    }
    if (hit && shift) {
        NSMutableArray* changed = [selected mutableCopy];
        NSUInteger at = [[selected valueForKey:@"nm"] indexOfObject:hit.nm];
        if (at == NSNotFound) [changed addObject:hit];
        else [changed removeObjectAtIndex:at];
        [self.controller selectItems:changed page:page];
        return;
    }
    if (hit && ![[selected valueForKey:@"nm"] containsObject:hit.nm]) {
        selected = @[ hit ];
        [self.controller selectItems:selected page:page];
    }
    state.page = page;
    if (hit) state.moving = selected;
    else state.banding = YES;
    CGFloat zoom = [self zoom];
    BOOL dragged = NO, finished = NO;
    NSPoint now = start;
    for (NSEvent* event; (event = [self nextGestureEvent]);) {
        now = [self convertPoint:event.locationInWindow fromView:nil];
        dragged = dragged || hypot(now.x - start.x, now.y - start.y) > 3;
        NSPoint q = [self pagePointForViewPoint:now page:page];
        if (hit && dragged) state.delta = NSMakeSize((now.x - start.x) / zoom, (now.y - start.y) / zoom);
        if (!hit) state.band = NSMakeRect(MIN(p.x, q.x), MIN(p.y, q.y), fabs(q.x - p.x), fabs(q.y - p.y));
        self.needsDisplay = YES;
        if (event.type == NSEventTypeLeftMouseUp) {
            finished = YES;
            break;
        }
    }
    if (!finished) return;
    if (hit) {
        if (dragged) [self.controller moveItems:selected by:state.delta];
        else if (selected.count > 1) [self.controller selectItems:@[ hit ] page:page];  // a click picks it alone
        return;
    }
    NSMutableArray* chosen = shift ? [selected mutableCopy] : [NSMutableArray array];
    if (dragged) {
        BOOL inside = (NSEvent.modifierFlags & NSEventModifierFlagOption) != 0;
        spdf_rect box = SPDFFillRectToCore(state.band);
        for (SPDFFillItem* item in [self.controller itemsOnPage:page]) {
            if (item.cell >= 0 || [[chosen valueForKey:@"nm"] containsObject:item.nm]) continue;
            BOOL in = item.isDrawing ? (inside ? spdf_ink_inside_rect : spdf_ink_touches_rect)(
                                           item.pointBytes, item.pointCount, (float)item.lineWidth / 2, box)
                                     : inside ? NSContainsRect(state.band, item.rect)
                                              : NSIntersectsRect(state.band, item.rect);
            if (in) [chosen addObject:item];
        }
    }
    [self.controller selectItems:chosen page:page];
}

- (void)trackArrowEnd:(NSInteger)end of:(SPDFFillItem*)arrow {
    SPDFFillDrawingState* state = [self drawingState];
    spdf_fill_point ends[2] = {arrow.pointBytes[0], arrow.pointBytes[1]};
    state.page = arrow.page;
    state.endArrow = arrow;
    BOOL finished = NO;
    for (NSEvent* event; (event = [self nextGestureEvent]);) {
        NSPoint now = [self convertPoint:event.locationInWindow fromView:nil];
        ends[end] = SPDFFillPoint([self pagePointForViewPoint:now page:arrow.page]);
        if (event.modifierFlags & NSEventModifierFlagShift)
            ends[end] = [self snapAngleFrom:ends[1 - end] to:ends[end] page:arrow.page];
        SPDFFillItem* preview = [arrow itemMovedBy:NSZeroSize];
        preview.points = [NSData dataWithBytes:ends length:sizeof(ends)];
        [preview updateDrawingBounds];
        state.endPreview = preview;
        self.needsDisplay = YES;
        if (event.type == NSEventTypeLeftMouseUp) {
            finished = YES;
            break;
        }
    }
    if (finished)
        [self.controller setArrow:arrow tail:NSMakePoint(ends[0].x, ends[0].y) tip:NSMakePoint(ends[1].x, ends[1].y)];
}

#pragma mark - Pointer, menu and keys

- (BOOL)drawingHover:(NSPoint)point {
    SPDFFillTool tool = [self tool];
    if (!SPDFFillToolDraws(tool) || self.hidden) return NO;
    [self.controller postponePendingStrokes];  // still moving: the lines wait until the pointer rests
    NSInteger page;
    NSPoint p;
    BOOL onPage = [self locateViewPoint:point page:&page pagePoint:&p];
    SPDFFillItem* hover = onPage && tool == SPDFFillToolSelect ? [self itemAt:p page:page] : nil;
    if (![hover.nm isEqual:self.hoverItem.nm]) self.needsDisplay = YES;
    self.hoverItem = hover;
    self.toolTip = nil;
    NSCursor* cursor = onPage ? [self drawingCursorForTool:tool] : NSCursor.arrowCursor;
    NSArray* selected = onPage && tool == SPDFFillToolSelect ? [self selectionOnPage:page] : @[];
    if (selected.count == 1 && [self arrowEndAt:point of:selected.firstObject] >= 0) cursor = NSCursor.crosshairCursor;
    dispatch_async(dispatch_get_main_queue(), ^{ if (!self.hidden) [cursor set]; });
    return YES;
}

- (BOOL)drawingRightMouseDown:(NSEvent*)event {
    if (![self drawingsAnswerPointer]) return NO;
    NSInteger page;
    NSPoint p;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    SPDFFillItem* hit = [self locateViewPoint:point page:&page pagePoint:&p] ? [self itemAt:p page:page] : nil;
    if (!hit) return NO;
    if (![[[self selectionOnPage:page] valueForKey:@"nm"] containsObject:hit.nm])
        [self.controller selectItems:@[ hit ] page:page];
    [self.window makeFirstResponder:self];
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
    [menu addItemWithTitle:@"Remove" action:@selector(removeSelection:) keyEquivalent:@""].target = self;
    if ([self.controller selectionHasDrawings]) {
        [menu addItem:[NSMenuItem separatorItem]];
        for (NSInteger i = 0; i < [SPDFMacFillDrawingStyle colorCount]; ++i) {
            NSMenuItem* item = [menu addItemWithTitle:[SPDFMacFillDrawingStyle colorNameAtIndex:i]
                                               action:@selector(recolorSelection:) keyEquivalent:@""];
            item.tag = i;
            item.target = self;
        }
    }
    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
    return YES;
}

- (void)removeSelection:(id)sender {
    (void)sender;
    [self.controller removeItems:[self.controller selectedItems]];
}

- (void)recolorSelection:(NSMenuItem*)sender {
    [self.controller restyleSelectionWithColor:sender.tag width:-1];
}

@end
