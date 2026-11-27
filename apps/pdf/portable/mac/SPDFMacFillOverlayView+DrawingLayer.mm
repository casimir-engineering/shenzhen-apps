// How the overlay paints pen lines and arrows that are not in the page image yet, or no longer: the line being drawn,
// lines waiting to be written, lines just written until a page image made after the write is on screen, lines being
// erased or moved (covered with the paper colour, clipped to the ink), the selection and the rubber band.
#import "SPDFMacFillDrawingState.h"

#import "SPDFMacDocumentView.h"
#import "SPDFMacFillController.h"
#import "SPDFMacFillDrawingStyle.h"
#import "SPDFMacModels.h"

#include "spdf_fill_ink_geometry.h"

#import <objc/runtime.h>

static char kSPDFFillDrawingStateKey;
static const NSTimeInterval kSPDFFillHoldLimit = 3.0;  // a page that takes longer shows the change itself

@implementation SPDFFillHold
@end

@interface SPDFMacFillOverlayView (DrawingHolds)
- (BOOL)holdIsDone:(SPDFFillHold*)hold now:(NSTimeInterval)now;
@end

// NSBezierPath.CGPath needs macOS 14; the app runs on 12.
static CGPathRef SPDFFillCreateCGPath(NSBezierPath* path) {
    CGMutablePathRef out = CGPathCreateMutable();
    NSPoint p[3];
    for (NSInteger i = 0; i < path.elementCount; ++i) {
        switch ([path elementAtIndex:i associatedPoints:p]) {
            case NSBezierPathElementMoveTo: CGPathMoveToPoint(out, NULL, p[0].x, p[0].y); break;
            case NSBezierPathElementLineTo: CGPathAddLineToPoint(out, NULL, p[0].x, p[0].y); break;
            case NSBezierPathElementCurveTo:
                CGPathAddCurveToPoint(out, NULL, p[0].x, p[0].y, p[1].x, p[1].y, p[2].x, p[2].y);
                break;
            case NSBezierPathElementClosePath: CGPathCloseSubpath(out); break;
            default: break;
        }
    }
    return out;
}

@implementation SPDFFillDrawingState
- (instancetype)init {
    if ((self = [super init])) {
        _page = -1;
        _holds = [NSMutableArray array];
        _cursors = [NSMutableDictionary dictionary];
    }
    return self;
}
@end

@implementation SPDFMacFillOverlayView (DrawingShared)

- (SPDFFillDrawingState*)drawingState {
    SPDFFillDrawingState* state = objc_getAssociatedObject(self, &kSPDFFillDrawingStateKey);
    if (!state) {
        state = [SPDFFillDrawingState new];
        objc_setAssociatedObject(self, &kSPDFFillDrawingStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

- (CGAffineTransform)pageToView:(NSInteger)page {
    NSRect r = [self viewRectForPageRect:NSMakeRect(0, 0, 1000, 1000) page:page];
    return CGAffineTransformMake(NSWidth(r) / 1000, 0, 0, NSHeight(r) / 1000, NSMinX(r), NSMinY(r));
}

- (NSPoint)pagePointForViewPoint:(NSPoint)point page:(NSInteger)page {
    CGPoint p = CGPointApplyAffineTransform(point, CGAffineTransformInvert([self pageToView:page]));
    SPDFRenderedPage* rendered = [self renderedPage:page];
    if (rendered) {
        p.x = MAX(0.0, MIN(p.x, rendered.pageWidth));
        p.y = MAX(0.0, MIN(p.y, rendered.pageHeight));
    }
    return p;
}

- (NSBezierPath*)viewPathForItem:(SPDFFillItem*)item extra:(CGFloat)extra {
    NSBezierPath* path = [NSBezierPath bezierPath];
    const spdf_fill_point* p = item.pointBytes;
    int count = item.pointCount;
    if (!count) return path;
    if (item.kind == SPDF_FILL_ARROW && count >= 2) {
        spdf_fill_point head[3];
        spdf_ink_arrow_head(p[0], p[1], (float)item.lineWidth, head);
        [path moveToPoint:NSMakePoint(p[0].x, p[0].y)];
        [path lineToPoint:NSMakePoint(p[1].x, p[1].y)];
        [path moveToPoint:NSMakePoint(head[0].x, head[0].y)];
        [path lineToPoint:NSMakePoint(head[1].x, head[1].y)];
        [path lineToPoint:NSMakePoint(head[2].x, head[2].y)];
    } else {
        [path moveToPoint:NSMakePoint(p[0].x, p[0].y)];
        for (int i = 1; i < count; ++i) [path lineToPoint:NSMakePoint(p[i].x, p[i].y)];
        if (count == 1) [path lineToPoint:NSMakePoint(p[0].x, p[0].y)];  // a dot: the round caps draw it
    }
    CGAffineTransform t = [self pageToView:item.page];
    NSAffineTransform* transform = [NSAffineTransform transform];
    NSAffineTransformStruct m = {t.a, t.b, t.c, t.d, t.tx, t.ty};
    transform.transformStruct = m;
    [path transformUsingAffineTransform:transform];
    path.lineWidth = MAX(0.5, item.lineWidth * t.a + extra);
    path.lineCapStyle = NSLineCapStyleRound;
    path.lineJoinStyle = NSLineJoinStyleRound;
    return path;
}

- (NSColor*)inkColorForItem:(SPDFFillItem*)item {
    return SPDFFillScreenColor(item.color, [self.controller.host fillDarkPages], self.window.colorSpace);
}

- (NSCursor*)cursorNamed:(NSString*)name size:(CGFloat)size draw:(void (^)(NSRect dot))draw {
    SPDFFillDrawingState* state = [self drawingState];
    NSCursor* cursor = state.cursors[name];
    if (cursor) return cursor;
    CGFloat side = ceil(size + 6);
    NSImage* image = [NSImage imageWithSize:NSMakeSize(side, side) flipped:NO drawingHandler:^BOOL(NSRect rect) {
      draw(NSInsetRect(rect, (side - size) / 2, (side - size) / 2));
      return YES;
    }];
    cursor = [[NSCursor alloc] initWithImage:image hotSpot:NSMakePoint(side / 2, side / 2)];
    state.cursors[name] = cursor;
    return cursor;
}

- (NSCursor*)drawingCursorForTool:(SPDFFillTool)tool {
    SPDFMacFillDrawingStyle* style = [SPDFMacFillDrawingStyle sharedStyle];
    if (tool == SPDFFillToolPen) {
        // A dot of the line's own width and colour, in a white ring so it shows on any page.
        CGFloat size = MAX(3.0, round(style.width * [self zoom]));
        SPDFFillRGB c = style.color;
        NSColor* ink = SPDFFillScreenColor(c, [self.controller.host fillDarkPages], self.window.colorSpace);
        NSString* name = [NSString stringWithFormat:@"pen %.0f %.2f %.2f %.2f %d", size, c.r, c.g, c.b,
                                                    [self.controller.host fillDarkPages]];
        return [self cursorNamed:name size:size draw:^(NSRect dot) {
          [NSColor.whiteColor setFill];
          [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dot, -1.5, -1.5)] fill];
          [ink setFill];
          [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
        }];
    }
    if (tool == SPDFFillToolEraser) {
        CGFloat size = style.eraserParts ? style.eraserSize : 12;
        return [self cursorNamed:[NSString stringWithFormat:@"eraser %.0f", size] size:size draw:^(NSRect dot) {
          NSBezierPath* ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dot, 0.5, 0.5)];
          ring.lineWidth = 2.5;
          [[NSColor colorWithWhite:1 alpha:0.9] setStroke];
          [ring stroke];
          ring.lineWidth = 1;
          [[NSColor colorWithWhite:0.15 alpha:0.9] setStroke];
          [ring stroke];
        }];
    }
    if (tool == SPDFFillToolArrow) return NSCursor.crosshairCursor;
    return NSCursor.arrowCursor;
}

@end

@implementation SPDFMacFillOverlayView (Drawing)

#pragma mark - Holding lines until the page image shows the change

// A held line lets go as soon as the page image on screen was made after the write: the change's own redraw, in the
// same turn as the write, or the first render after it (a render begun before the write is never installed over a
// newer image of the same page, and a full re-render starts a new generation). Checked just before each screen
// update, so the line and the page image that contains it are never drawn together.
- (BOOL)holdIsDone:(SPDFFillHold*)hold now:(NSTimeInterval)now {
    if (now >= hold.deadline) return YES;
    SPDFRenderedPage* current = [self renderedPage:hold.item.page];
    BOOL newer = !hold.hadBefore || !hold.before || current != hold.before || current.image != hold.beforeImage ||
                 current.viewportImage != hold.beforeViewportImage;  // a redraw of the changed part only
    return newer && (current.image || current.viewportImage);
}

- (void)stopWatchingDrawingHolds {
    SPDFFillDrawingState* state = [self drawingState];
    if (state.holdObserver) CFRunLoopObserverInvalidate((__bridge CFRunLoopObserverRef)state.holdObserver);
    state.holdObserver = nil;
    [state.holdTimer invalidate];
    state.holdTimer = nil;
}

- (void)holdInk:(NSArray<SPDFFillItem*>*)ink washes:(NSArray<SPDFFillItem*>*)washes {
    SPDFFillDrawingState* state = [self drawingState];
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    NSMutableSet<NSString*>* names = [NSMutableSet set];
    for (SPDFFillItem* item in [ink arrayByAddingObjectsFromArray:washes ?: @[]]) [names addObject:item.nm];
    // A newer change to the same line replaces what was held for it.
    [state.holds filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SPDFFillHold* hold, NSDictionary* bindings) {
                   (void)bindings;
                   return ![names containsObject:hold.item.nm];
                 }]];
    for (NSUInteger pass = 0; pass < 2; ++pass)
        for (SPDFFillItem* item in pass == 0 ? washes : ink) {
            SPDFFillHold* hold = [SPDFFillHold new];
            hold.item = item;
            hold.wash = pass == 0;
            SPDFRenderedPage* page = [self renderedPage:item.page];
            hold.before = page;
            hold.hadBefore = page != nil;
            hold.beforeImage = page.image, hold.beforeViewportImage = page.viewportImage;
            hold.deadline = now + kSPDFFillHoldLimit;
            [state.holds addObject:hold];
        }
    if (state.holds.count && !state.holdObserver) {
        __weak SPDFMacFillOverlayView* weakSelf = self;
        CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, 0,  // before AppKit draws and Core Animation commits
            ^(CFRunLoopObserverRef o, CFRunLoopActivity activity) {
              (void)o;
              (void)activity;
              [weakSelf checkDrawingHolds:nil];
            });
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
        state.holdObserver = CFBridgingRelease(observer);
        state.holdTimer = [NSTimer timerWithTimeInterval:kSPDFFillHoldLimit + 0.05 target:self
                                                selector:@selector(checkDrawingHolds:) userInfo:nil repeats:NO];
        [NSRunLoop.mainRunLoop addTimer:state.holdTimer forMode:NSRunLoopCommonModes];
    }
    self.needsDisplay = YES;
}

- (void)checkDrawingHolds:(NSTimer*)timer {
    (void)timer;
    SPDFFillDrawingState* state = [self drawingState];
    if (!state.holds.count) {
        [self stopWatchingDrawingHolds];
        return;
    }
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    NSUInteger before = state.holds.count;
    NSMutableArray* kept = [NSMutableArray array];
    for (SPDFFillHold* hold in state.holds)
        if (![self holdIsDone:hold now:now]) [kept addObject:hold];
    state.holds = kept;
    if (kept.count != before) self.needsDisplay = YES;
    if (!kept.count) [self stopWatchingDrawingHolds];
}

- (void)dropDrawingHolds {
    SPDFFillDrawingState* state = [self drawingState];
    [state.holds removeAllObjects];
    [self stopWatchingDrawingHolds];
    self.needsDisplay = YES;
}

@end

@implementation SPDFMacFillOverlayView (DrawingPaint)

- (NSColor*)paperColor {
    return [[self documentView] pageFillColor] ?: NSColor.whiteColor;
}

- (void)washItem:(SPDFFillItem*)item alpha:(CGFloat)alpha {
    [[[self paperColor] colorWithAlphaComponent:alpha] setStroke];
    [[self viewPathForItem:item extra:1.5] stroke];
}

- (void)inkItem:(SPDFFillItem*)item {
    [[self inkColorForItem:item] setStroke];
    [[self viewPathForItem:item extra:0] stroke];
}

// The eraser's swath in paper colour, only where it crosses the ink of a line, so page text under the line stays.
- (void)washSwathOver:(SPDFFillItem*)item swath:(NSBezierPath*)swath {
    NSBezierPath* line = [self viewPathForItem:item extra:1.5];
    CGPathRef outline = SPDFFillCreateCGPath(line);
    CGPathRef stroked = CGPathCreateCopyByStrokingPath(outline, NULL, line.lineWidth, kCGLineCapRound,
                                                       kCGLineJoinRound, 10);
    CGPathRelease(outline);
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGContextAddPath(context, stroked);
    CGContextClip(context);
    [[self paperColor] setStroke];
    [swath stroke];
    CGContextRestoreGState(context);
    CGPathRelease(stroked);
}

- (void)drawSelectionOf:(NSArray<SPDFFillItem*>*)items accent:(NSColor*)accent {
    NSRect group = NSZeroRect;
    for (SPDFFillItem* item in items) {
        NSRect r = [self viewRectForPageRect:item.rect page:item.page];
        group = NSIsEmptyRect(group) ? r : NSUnionRect(group, r);
        if (item.isDrawing) {
            [[accent colorWithAlphaComponent:0.45] setStroke];
            [[self viewPathForItem:item extra:4] stroke];
            [self inkItem:item];
        } else {
            NSBezierPath* outline = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, -2, -2) xRadius:3 yRadius:3];
            [[accent colorWithAlphaComponent:0.9] setStroke];
            [outline stroke];
        }
    }
    if (items.count > 1) {
        NSBezierPath* box = [NSBezierPath bezierPathWithRect:NSInsetRect(group, -5, -5)];
        CGFloat dash[2] = {4, 3};
        [box setLineDash:dash count:2 phase:0];
        box.lineWidth = 1;
        [[accent colorWithAlphaComponent:0.7] setStroke];
        [box stroke];
    }
    SPDFFillItem* only = items.count == 1 ? items.firstObject : nil;
    if (only.kind == SPDF_FILL_ARROW && only.pointCount >= 2) {
        CGAffineTransform t = [self pageToView:only.page];
        for (int i = 0; i < 2; ++i) {
            NSPoint p = CGPointApplyAffineTransform(NSMakePoint(only.pointBytes[i].x, only.pointBytes[i].y), t);
            NSBezierPath* knob = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - 4.5, p.y - 4.5, 9, 9)];
            [NSColor.whiteColor setFill];
            [knob fill];
            knob.lineWidth = 1.5;
            [accent setStroke];
            [knob stroke];
        }
    }
}

- (void)drawDrawingLayer {
    SPDFFillDrawingState* state = [self drawingState];
    SPDFFillSession* session = [self.controller session];
    NSColor* accent = NSColor.controlAccentColor;
    NSSet<NSNumber*>* visible = [NSSet setWithArray:[self visiblePages]];
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    for (SPDFFillHold* hold in state.holds)
        if (hold.wash && [visible containsObject:@(hold.item.page)] && ![self holdIsDone:hold now:now])
            [self washItem:hold.item alpha:1];
    for (SPDFFillHold* hold in state.holds)
        if (!hold.wash && [visible containsObject:@(hold.item.page)] && ![self holdIsDone:hold now:now])
            [self inkItem:hold.item];
    for (NSNumber* page in visible)
        for (SPDFFillItem* stroke in [self.controller pendingStrokesOnPage:page.integerValue]) [self inkItem:stroke];
    for (SPDFFillItem* item in state.erasing) [self washItem:item alpha:0.85];
    if (state.swath.length && state.swathRadius > 0 && state.page >= 0) {
        const spdf_fill_point* p = (const spdf_fill_point*)state.swath.bytes;
        int count = (int)(state.swath.length / sizeof(spdf_fill_point));
        SPDFFillRGB none = {0, 0, 0};
        SPDFFillItem* path = [SPDFFillItem strokeOfKind:SPDF_FILL_PEN page:state.page points:p count:count
                                                  color:none width:2 * state.swathRadius];
        NSBezierPath* swath = [self viewPathForItem:path extra:0];
        for (SPDFFillItem* item in [self.controller itemsOnPage:state.page])
            if (item.isDrawing && NSIntersectsRect(item.rect, path.rect)) [self washSwathOver:item swath:swath];
    }
    // Moving: the lines leave their place and are drawn where they are going.
    NSSet* movingNames = nil;
    if (state.moving.count && (fabs(state.delta.width) > 0 || fabs(state.delta.height) > 0)) {
        movingNames = [NSSet setWithArray:[state.moving valueForKey:@"nm"]];
        for (SPDFFillItem* item in state.moving)
            if (item.isDrawing) [self washItem:item alpha:1];
        NSMutableArray* moved = [NSMutableArray array];
        for (SPDFFillItem* item in state.moving) {
            SPDFFillItem* there = [item itemMovedBy:state.delta];
            [moved addObject:there];
            if (there.isDrawing) {
                [self inkItem:there];
            } else {
                NSRect r = [self viewRectForPageRect:there.rect page:there.page];
                [[accent colorWithAlphaComponent:0.12] setFill];
                NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);
            }
        }
        [self drawSelectionOf:moved accent:accent];
    }
    if (state.endArrow && state.endPreview) {
        [self washItem:state.endArrow alpha:1];
        [self inkItem:state.endPreview];
        [self drawSelectionOf:@[ state.endPreview ] accent:accent];
    }
    if (state.live) {
        [self inkItem:state.live];
        if (state.hasLiveTail && state.live.pointCount) {
            spdf_fill_point tail[2] = {state.live.pointBytes[state.live.pointCount - 1],
                                       {(float)state.liveTail.x, (float)state.liveTail.y}};
            [self inkItem:[SPDFFillItem strokeOfKind:SPDF_FILL_PEN page:state.live.page points:tail count:2
                                               color:state.live.color width:state.live.lineWidth]];
        }
    }
    if (session.tool == SPDFFillToolSelect && !movingNames && !state.endArrow) {
        NSArray* selected = [self.controller selectedItems];
        if ([visible containsObject:@(session.selectionPage)]) [self drawSelectionOf:selected accent:accent];
        SPDFFillItem* hover = self.hoverItem;
        if (hover.isDrawing && ![session.selection containsObject:hover.nm]) {
            [[accent colorWithAlphaComponent:0.25] setStroke];
            [[self viewPathForItem:hover extra:4] stroke];
            [self inkItem:hover];
        }
    }
    if (state.banding && state.page >= 0) {
        NSRect r = [self viewRectForPageRect:state.band page:state.page];
        [[accent colorWithAlphaComponent:0.08] setFill];
        NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);
        [[accent colorWithAlphaComponent:0.9] setStroke];
        NSBezierPath* outline = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 0.5, 0.5)];
        outline.lineWidth = 1;
        [outline stroke];
    }
}

@end
