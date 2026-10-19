#import "SPDFMarkdownTestSupport.h"

#import "../../markdown/SPDFMarkdownDiagramInternal.h"

// Edge routing where several edges share one node border. Anchoring a whole
// fan at the border midpoint made it self-intersect: four curves from one
// point, each with its own control length, swapped order within a few points
// of the box, so the edge heading to the TOP target dived under the ones
// heading below it before turning up.
//
// The properties that say the fan is right, asserted on the real fixture
// (fixtures/power-tree.md, whose `1.8 V AON` rail feeds four loads and whose
// VSYS node feeds eight) and on a top-down graph so the flow axis is exercised
// both ways round:
//
//   * anchors along a shared border are DISTINCT and ordered to match the
//     cross-axis order of the far ends -- topmost target, topmost anchor;
//   * no two edges leaving one node cross each other, anywhere;
//   * no two edges arriving at one node cross each other either;
//   * every anchor still lies on the node's own outline.
//
// Crossing is tested as real segment intersection on the emitted polylines,
// not by eye and not by a proxy.

static NSString* SPDFRoutingFixtureFence(void) {
    NSString* markdown = [NSString stringWithContentsOfURL:SPDFFixtureURL(@"power-tree.md")
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    NSRange open = [markdown rangeOfString:@"```mermaid\n"];
    if (open.location == NSNotFound) return nil;
    NSRange rest = NSMakeRange(NSMaxRange(open), markdown.length - NSMaxRange(open));
    NSRange close = [markdown rangeOfString:@"\n```" options:0 range:rest];
    if (close.location == NSNotFound) return nil;
    return [markdown substringWithRange:NSMakeRange(rest.location, close.location - rest.location)];
}

// The emitter lays every edge's polyline down first, in `graph.edges` order and
// before any node shape, so the first `edges.count` polylines ARE the edges.
static NSArray<SPDFMarkdownDiagramShape*>* SPDFRoutingEdgePaths(SPDFMarkdownDiagramGraph* graph,
                                                                SPDFMarkdownDiagramLayout* layout) {
    NSMutableArray<SPDFMarkdownDiagramShape*>* paths = [NSMutableArray array];
    for (SPDFMarkdownDiagramShape* shape in layout.shapes) {
        if (shape.kind != SPDFMarkdownDiagramShapePolyline || shape.points.count < 2) continue;
        [paths addObject:shape];
        if (paths.count == graph.edges.count) break;
    }
    return paths;
}

static CGFloat SPDFRoutingCross(NSPoint point, BOOL vertical) { return vertical ? point.x : point.y; }

// --- Segment intersection ------------------------------------------------------

static CGFloat SPDFRoutingSide(NSPoint a, NSPoint b, NSPoint c) {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

static BOOL SPDFRoutingSegmentsCross(NSPoint a, NSPoint b, NSPoint c, NSPoint d) {
    CGFloat d1 = SPDFRoutingSide(c, d, a), d2 = SPDFRoutingSide(c, d, b);
    CGFloat d3 = SPDFRoutingSide(a, b, c), d4 = SPDFRoutingSide(a, b, d);
    // Strict straddling only: two paths that merely touch at a shared endpoint
    // are not a crossing, and floating-point grazes are not either.
    const CGFloat epsilon = 0.001;
    BOOL first = (d1 > epsilon && d2 < -epsilon) || (d1 < -epsilon && d2 > epsilon);
    BOOL second = (d3 > epsilon && d4 < -epsilon) || (d3 < -epsilon && d4 > epsilon);
    return first && second;
}

static NSUInteger SPDFRoutingPathCrossings(SPDFMarkdownDiagramShape* left, SPDFMarkdownDiagramShape* right) {
    NSUInteger crossings = 0;
    for (NSUInteger a = 0; a + 1 < left.points.count; ++a) {
        NSPoint p0 = left.points[a].pointValue, p1 = left.points[a + 1].pointValue;
        for (NSUInteger b = 0; b + 1 < right.points.count; ++b) {
            NSPoint q0 = right.points[b].pointValue, q1 = right.points[b + 1].pointValue;
            if (SPDFRoutingSegmentsCross(p0, p1, q0, q1)) ++crossings;
        }
    }
    return crossings;
}

// --- Properties ----------------------------------------------------------------

// Groups the edges by the node they leave (or arrive at) and checks the two
// things a fan owes: distinct anchors ordered like their far ends, and no pair
// of its members crossing.
static void SPDFExpectFanClean(SPDFMarkdownDiagramGraph* graph, SPDFMarkdownDiagramLayout* layout,
                               BOOL departing, BOOL expectFans, NSString* what) {
    NSString* worst = nil;
    NSArray<SPDFMarkdownDiagramShape*>* paths = SPDFRoutingEdgePaths(graph, layout);
    BOOL vertical = graph.vertical;
    NSMutableDictionary<NSString*, NSMutableArray<NSNumber*>*>* fans = [NSMutableDictionary dictionary];
    for (NSUInteger index = 0; index < paths.count && index < graph.edges.count; ++index) {
        SPDFMarkdownDiagramEdge* edge = graph.edges[index];
        NSString* key = departing ? edge.fromIdentifier : edge.toIdentifier;
        NSString* other = departing ? edge.toIdentifier : edge.fromIdentifier;
        if ([key isEqualToString:other]) continue;  // a self-loop is not a fan
        NSMutableArray<NSNumber*>* fan = fans[key];
        if (!fan) fans[key] = fan = [NSMutableArray array];
        [fan addObject:@(index)];
    }
    NSUInteger fanned = 0, disordered = 0, collided = 0, coincident = 0;
    for (NSString* key in [fans.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSArray<NSNumber*>* fan = fans[key];
        if (fan.count < 2) continue;
        ++fanned;
        // Ordered by where each edge's far end sits on the cross axis; the
        // anchors on the shared border must come out in the same order.
        NSArray<NSNumber*>* sorted = [fan sortedArrayUsingComparator:^NSComparisonResult(NSNumber* a,
                                                                                          NSNumber* b) {
          SPDFMarkdownDiagramEdge* left = graph.edges[a.unsignedIntegerValue];
          SPDFMarkdownDiagramEdge* right = graph.edges[b.unsignedIntegerValue];
          NSString* leftFar = departing ? left.toIdentifier : left.fromIdentifier;
          NSString* rightFar = departing ? right.toIdentifier : right.fromIdentifier;
          NSRect leftFrame = [graph existingNodeForIdentifier:leftFar].frame;
          NSRect rightFrame = [graph existingNodeForIdentifier:rightFar].frame;
          CGFloat one = vertical ? NSMidX(leftFrame) : NSMidY(leftFrame);
          CGFloat two = vertical ? NSMidX(rightFrame) : NSMidY(rightFrame);
          return one < two ? NSOrderedAscending : (one > two ? NSOrderedDescending : NSOrderedSame);
        }];
        CGFloat previous = -CGFLOAT_MAX;
        for (NSNumber* index in sorted) {
            SPDFMarkdownDiagramShape* path = paths[index.unsignedIntegerValue];
            NSPoint anchor = departing ? path.points.firstObject.pointValue : path.points.lastObject.pointValue;
            CGFloat cross = SPDFRoutingCross(anchor, vertical);
            if (previous > -CGFLOAT_MAX) {
                if (cross < previous - 0.001) ++disordered;
                if (fabs(cross - previous) < 0.001) ++coincident;
            }
            previous = cross;
        }
        for (NSUInteger a = 0; a + 1 < fan.count; ++a) {
            for (NSUInteger b = a + 1; b < fan.count; ++b) {
                NSUInteger hits = SPDFRoutingPathCrossings(paths[fan[a].unsignedIntegerValue],
                                                           paths[fan[b].unsignedIntegerValue]);
                collided += hits;
                if (hits && !worst)
                    worst = [NSString stringWithFormat:@"%@ -> %@ vs %@", key,
                                                       graph.edges[fan[a].unsignedIntegerValue].toIdentifier,
                                                       graph.edges[fan[b].unsignedIntegerValue].toIdentifier];
            }
        }
    }
    NSString* side = departing ? @"leaving" : @"arriving at";
    if (expectFans) SPDFExpect(fanned > 0, [NSString stringWithFormat:@"%@ has edges %@ one node to fan", what,
                                                                      side]);
    SPDFExpect(coincident == 0,
               [NSString stringWithFormat:@"%@ gives every edge %@ a node its own anchor (%lu shared)", what,
                                          side, (unsigned long)coincident]);
    SPDFExpect(disordered == 0,
               [NSString stringWithFormat:@"%@ orders the anchors %@ a node like their far ends (%lu inverted)",
                                          what, side, (unsigned long)disordered]);
    SPDFExpect(collided == 0,
               [NSString stringWithFormat:@"%@ never crosses two edges %@ the same node (%lu crossings, %@)",
                                          what, side, (unsigned long)collided, worst ?: @"none"]);
}

// A spread anchor still has to sit ON the box it belongs to: inside its
// bounding rectangle and in the outer BAND of it. The band, rather than the
// rectangle exactly, because an anchor slid along a rounded cap, an ellipse or
// a diamond taper legitimately sits a little inside the bounding box -- but it
// may never wander in toward the label.
static void SPDFExpectAnchorsOnNodes(SPDFMarkdownDiagramGraph* graph, SPDFMarkdownDiagramLayout* layout,
                                     NSString* what) {
    NSArray<SPDFMarkdownDiagramShape*>* paths = SPDFRoutingEdgePaths(graph, layout);
    NSUInteger stray = 0;
    for (SPDFMarkdownDiagramShape* path in paths) {
        for (NSValue* value in @[ path.points.firstObject, path.points.lastObject ]) {
            NSPoint point = value.pointValue;
            BOOL onSome = NO;
            for (SPDFMarkdownDiagramNode* node in graph.nodes) {
                NSRect frame = node.frame;
                CGFloat band = 0.35 * MIN(NSWidth(frame), NSHeight(frame));
                if (NSPointInRect(point, NSInsetRect(frame, -0.75, -0.75)) &&
                    !NSPointInRect(point, NSInsetRect(frame, band, band)))
                    onSome = YES;
            }
            if (!onSome) ++stray;
        }
    }
    SPDFExpect(stray == 0, [NSString stringWithFormat:@"%@ keeps every edge end on a node border (%lu stray)",
                                                      what, (unsigned long)stray]);
}

static SPDFMarkdownDiagramGraph* SPDFRoutingLayOut(NSString* source, SPDFMarkdownDiagramLayout** outLayout) {
    SPDFMarkdownDiagramGraph* graph = SPDFMarkdownDiagramParseMermaidFlowchart(source);
    if (!graph) return nil;
    // A box far larger than the drawing, so the fit factor is 1 and the emitted
    // shapes share the model's own coordinates.
    SPDFMarkdownDiagramLayout* layout =
        SPDFMarkdownDiagramLayOutGraph(graph, NSMakeSize(4096, 4096), 1.0,
                                       CFAbsoluteTimeGetCurrent() + SPDFMarkdownDiagramLayoutDeadline);
    if (outLayout) *outLayout = layout;
    return layout ? graph : nil;
}

int main(void) {
    @autoreleasepool {
        NSString* fence = SPDFRoutingFixtureFence();
        SPDFExpect(fence.length > 0, @"the power-tree fixture carries one mermaid fence");
        if (!fence.length) return SPDFFinishTests(@"SPDFMarkdownDiagramEdgeRoutingTests");

        SPDFMarkdownDiagramLayout* layout = nil;
        SPDFMarkdownDiagramGraph* graph = SPDFRoutingLayOut(fence, &layout);
        SPDFExpect(graph != nil, @"the power-tree fixture lays out");
        if (graph) {
            SPDFExpectFanClean(graph, layout, YES, YES, @"the power tree");
            // Every load in the power tree has exactly one supply, so the
            // fixture has no fan-IN; the property still has to hold vacuously.
            SPDFExpectFanClean(graph, layout, NO, NO, @"the power tree");
            SPDFExpectAnchorsOnNodes(graph, layout, @"the power tree");
            // The rail the report was about: four loads off one stadium border.
            NSUInteger loads = 0;
            for (SPDFMarkdownDiagramEdge* edge in graph.edges)
                if ([edge.fromIdentifier isEqualToString:@"AON"]) ++loads;
            SPDFExpect(loads == 4, @"the always-on rail still fans to its four loads");
        }

        // Top-down, with fan-outs, fan-ins, a rank-skipping edge and a cycle:
        // the same properties on the other flow axis.
        NSString* vertical = @"flowchart TD\n"
                              "  A[Start] --> B{Valid?}\n"
                              "  B -->|yes| C[Fetch]\n"
                              "  B -->|no| D[Reject]\n"
                              "  C --> E[Transform]\n"
                              "  E --> F([Store])\n"
                              "  A --> F\n"
                              "  C --> H[Notify]\n"
                              "  F --> H\n"
                              "  D --> G[Log]\n"
                              "  G --> A\n";
        SPDFMarkdownDiagramLayout* downLayout = nil;
        SPDFMarkdownDiagramGraph* down = SPDFRoutingLayOut(vertical, &downLayout);
        SPDFExpect(down != nil && down.vertical, @"the top-down graph lays out on the vertical axis");
        if (down) {
            SPDFExpectFanClean(down, downLayout, YES, YES, @"the top-down graph");
            SPDFExpectFanClean(down, downLayout, NO, YES, @"the top-down graph");
            SPDFExpectAnchorsOnNodes(down, downLayout, @"the top-down graph");
        }

        // Determinism: fan assignment is sorted, never hash-ordered, so two
        // renders of the same source put every anchor in the same place.
        SPDFMarkdownDiagramLayout* again = nil;
        SPDFMarkdownDiagramGraph* twice = SPDFRoutingLayOut(fence, &again);
        BOOL identical = twice && again.shapes.count == layout.shapes.count;
        for (NSUInteger index = 0; identical && index < again.shapes.count; ++index) {
            NSArray<NSValue*>* left = layout.shapes[index].points;
            NSArray<NSValue*>* right = again.shapes[index].points;
            if (left.count != right.count) identical = NO;
            for (NSUInteger point = 0; identical && point < left.count; ++point)
                if (!NSEqualPoints(left[point].pointValue, right[point].pointValue)) identical = NO;
        }
        SPDFExpect(identical, @"two routings of the fixture place every anchor identically");
    }
    return SPDFFinishTests(@"SPDFMarkdownDiagramEdgeRoutingTests");
}
