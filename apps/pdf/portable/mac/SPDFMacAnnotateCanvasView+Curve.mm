// The Curve (docs/plans/annotate.md § 2 Shapes): drag the line, then click-drag twice to bend it, as classic Paint.
// The gesture stays SPDFAnnotateGestureCurve from the first press to the second bend; self.points holds the two ends,
// then the first bend. Return ends early with the bends made so far, Escape drops it. One shape.add on the end.
#import "SPDFMacAnnotateCanvasViewPrivate.h"

#import "SPDFMacAnnotateImageIO.h"
#import "SPDFMacAnnotateSessionPrivate.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation SPDFMacAnnotateCanvasView (Curve)

- (void)curveReleasedAt:(NSPoint)point page:(NSInteger)page moved:(BOOL)moved {
    if (!self.points.count) {
        if (!moved) {  // a click with a shape tool selects the object under it (§ 3)
            self.gesture = SPDFAnnotateGestureNone;
            NSDictionary* hit = [self objectAt:point page:page];
            self.session.selectedObjects = hit ? @[hit[@"id"]] : @[];
            return;
        }
        [self.points addObject:@(self.startPoint)];
        [self.points addObject:@([self constrainedEnd])];
        self.currentPoint = self.points.lastObject.pointValue;  // straight until the first bend
        return;
    }
    [self.points addObject:@(point)];  // a bend, where the button came up
    if (self.points.count >= 4) [self finishCurveOnPage:page];
}

- (void)finishCurveOnPage:(NSInteger)page {
    NSMutableArray* points = [NSMutableArray array];
    for (NSValue* value in self.points) [points addObject:SPDFAnnotatePointArray(value.pointValue)];
    self.gesture = SPDFAnnotateGestureNone;
    [self.points removeAllObjects];
    self.needsDisplay = YES;
    if (points.count < 2) return;
    NSDictionary* options = [SPDFAnnotateSettings.shared optionsForTool:@"shape"];
    NSMutableDictionary* outline = [@{@"style": @"solid", @"width": @3} mutableCopy];
    if ([options[@"outline"] isKindOfClass:NSDictionary.class]) [outline addEntriesFromDictionary:options[@"outline"]];
    outline[@"color"] = [self colorFor:self.rightButton];
    NSMutableDictionary* fill = [@{@"style": @"none"} mutableCopy];
    if ([options[@"fill"] isKindOfClass:NSDictionary.class]) [fill addEntriesFromDictionary:options[@"fill"]];
    fill[@"color"] = [self colorFor:!self.rightButton];
    __weak SPDFMacAnnotateCanvasView* weakSelf = self;
    [self operation:@{@"op": @"shape.add", @"shape": @"curve", @"points": points, @"outline": outline, @"fill": fill}
               page:page done:^(NSDictionary* result) {
                 if ([result[@"ok"] boolValue] && result[@"id"]) weakSelf.session.selectedObjects = @[result[@"id"]];
               }];
}

// The ends, and the bends: the one being dragged follows the pointer; the second starts where the first is.
- (NSBezierPath*)curvePreviewOnPage:(NSInteger)page {
    NSBezierPath* path = [NSBezierPath bezierPath];
    NSArray<NSValue*>* p = self.points;
    NSPoint a = p.count ? p[0].pointValue : self.startPoint;
    NSPoint z = p.count >= 2 ? p[1].pointValue : [self constrainedEnd];
    [path moveToPoint:[self viewPointForCanvasPoint:a page:page]];
    if (p.count < 2) {
        [path lineToPoint:[self viewPointForCanvasPoint:z page:page]];
        return path;
    }
    NSPoint c1 = p.count >= 3 ? p[2].pointValue : self.currentPoint, c2 = self.currentPoint;
    [path curveToPoint:[self viewPointForCanvasPoint:z page:page]
         controlPoint1:[self viewPointForCanvasPoint:c1 page:page]
         controlPoint2:[self viewPointForCanvasPoint:c2 page:page]];
    return path;
}

@end
#pragma clang diagnostic pop
