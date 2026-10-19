#import "SPDFMarkdownTestSupport.h"

#import "../../markdown/SPDFMarkdownDiagramInternal.h"
#import "../../markdown/SPDFMarkdownPaginator.h"

// The layered (Sugiyama) graph layout, asserted as PROPERTIES rather than
// coordinates: a layout is free to move a box, and none of these tests care
// where it lands as long as the drawing stays readable. What is pinned is what
// "readable" means for a flowchart --
//
//   * no two node boxes intersect, and same-column neighbours keep real air;
//   * columns are monotone along the flow axis, so depth reads left to right;
//   * a fan-out is centered on its source and a chain comes out straight;
//   * a rank-SKIPPING edge carries one bend point per column it crosses, and
//     each of them lands in the clear air between columns, never inside one;
//   * every edge starts and ends ON a box border;
//   * the same source always produces byte-identical geometry;
//   * the whole thing finishes well inside the 50 ms layout deadline.
//
// The acceptance case is the real user document that motivated the work
// (fixtures/power-tree.md): 32 nodes, 31 edges, eight columns deep.

static const NSSize kSPDFLayoutTestBox = {440, 0};
static const CGFloat kSPDFLayoutMinimumGap = 30;  // the emitter asks for 34 pt at scale 1

static NSString* SPDFLayoutFixtureFence(void) {
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

// Parses and lays out one flowchart, leaving the measured, POSITIONED model
// behind: SPDFMarkdownDiagramLayOutGraph writes the final frames onto the
// graph's own nodes and the bend points onto its edges, so the properties can
// be read off the model instead of guessed at from emitted shapes.
// The width is deliberately huge so the fit-to-content-width factor is 1 and
// the emitted shapes share the model's own coordinate space; the budget-facing
// numbers are asserted separately, through the public render seam.
static SPDFMarkdownDiagramGraph* SPDFLayoutGraphForSource(NSString* source, double* outMilliseconds,
                                                          SPDFMarkdownDiagramLayout** outLayout) {
    SPDFMarkdownDiagramGraph* graph = SPDFMarkdownDiagramParseMermaidFlowchart(source);
    if (!graph) return nil;
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    SPDFMarkdownDiagramLayout* layout =
        SPDFMarkdownDiagramLayOutGraph(graph, NSMakeSize(4096, 0), 1.0, start + SPDFMarkdownDiagramLayoutDeadline);
    if (outMilliseconds) *outMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000;
    if (outLayout) *outLayout = layout;
    return layout ? graph : nil;
}

static SPDFMarkdownDiagramNode* SPDFLayoutNode(SPDFMarkdownDiagramGraph* graph, NSString* identifier) {
    return [graph existingNodeForIdentifier:identifier];
}

// --- Properties ----------------------------------------------------------------

static void SPDFExpectNoOverlaps(SPDFMarkdownDiagramGraph* graph, NSString* what) {
    NSArray<SPDFMarkdownDiagramNode*>* nodes = graph.nodes;
    NSString* worst = nil;
    for (NSUInteger a = 0; a + 1 < nodes.count && !worst; ++a) {
        for (NSUInteger b = a + 1; b < nodes.count; ++b) {
            if (!NSIntersectsRect(nodes[a].frame, nodes[b].frame)) continue;
            worst = [NSString stringWithFormat:@"%@ overlaps %@", nodes[a].identifier, nodes[b].identifier];
            break;
        }
    }
    SPDFExpect(worst == nil,
               [NSString stringWithFormat:@"%@ places no two node boxes on top of each other (%@)", what,
                                          worst ?: @"none"]);
}

// Depth reads along the flow axis: every node of a later rank starts past the
// end of every node of an earlier one, so the columns never interleave.
static void SPDFExpectColumnsMonotone(SPDFMarkdownDiagramGraph* graph, NSString* what) {
    NSArray<SPDFMarkdownDiagramNode*>* nodes = graph.nodes;
    BOOL monotone = YES;
    for (SPDFMarkdownDiagramNode* early in nodes) {
        for (SPDFMarkdownDiagramNode* late in nodes) {
            if (early.rank >= late.rank) continue;
            CGFloat earlyEnd = graph.vertical ? NSMaxY(early.frame) : NSMaxX(early.frame);
            CGFloat lateStart = graph.vertical ? NSMinY(late.frame) : NSMinX(late.frame);
            if (lateStart < earlyEnd - 0.5) monotone = NO;
        }
    }
    SPDFExpect(monotone, [what stringByAppendingString:@" keeps every column strictly past the previous one"]);
}

// Same-column neighbours keep clear air between them. The gaps are not all
// equal by design -- coordinate assignment spreads a column to line its boxes
// up with their neighbours -- but the MINIMUM is a hard constraint.
static void SPDFExpectColumnAir(SPDFMarkdownDiagramGraph* graph, NSString* what) {
    NSMutableDictionary<NSNumber*, NSMutableArray<SPDFMarkdownDiagramNode*>*>* columns =
        [NSMutableDictionary dictionary];
    for (SPDFMarkdownDiagramNode* node in graph.nodes) {
        NSMutableArray<SPDFMarkdownDiagramNode*>* column = columns[@(node.rank)];
        if (!column) columns[@(node.rank)] = column = [NSMutableArray array];
        [column addObject:node];
    }
    CGFloat tightest = CGFLOAT_MAX;
    for (NSNumber* rank in [columns.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSArray<SPDFMarkdownDiagramNode*>* column = [columns[rank]
            sortedArrayUsingComparator:^NSComparisonResult(SPDFMarkdownDiagramNode* a,
                                                           SPDFMarkdownDiagramNode* b) {
              CGFloat left = graph.vertical ? NSMinX(a.frame) : NSMinY(a.frame);
              CGFloat right = graph.vertical ? NSMinX(b.frame) : NSMinY(b.frame);
              return left < right ? NSOrderedAscending : (left > right ? NSOrderedDescending : NSOrderedSame);
            }];
        for (NSUInteger index = 0; index + 1 < column.count; ++index) {
            CGFloat end = graph.vertical ? NSMaxX(column[index].frame) : NSMaxY(column[index].frame);
            CGFloat next = graph.vertical ? NSMinX(column[index + 1].frame) : NSMinY(column[index + 1].frame);
            tightest = MIN(tightest, next - end);
        }
    }
    SPDFExpect(tightest == CGFLOAT_MAX || tightest >= kSPDFLayoutMinimumGap,
               [NSString stringWithFormat:@"%@ keeps at least %.0f pt between same-column boxes (tightest %.1f)",
                                          what, kSPDFLayoutMinimumGap,
                                          tightest == CGFLOAT_MAX ? 0 : tightest]);
}

// A bend point exists for every column a long edge crosses, and each one sits
// in the clear air of that column's band rather than inside a box.
static void SPDFExpectRoutedLongEdges(SPDFMarkdownDiagramGraph* graph, BOOL expectSome, NSString* what) {
    BOOL routed = YES, clear = YES;
    NSUInteger longEdges = 0;
    for (SPDFMarkdownDiagramEdge* edge in graph.edges) {
        SPDFMarkdownDiagramNode* from = SPDFLayoutNode(graph, edge.fromIdentifier);
        SPDFMarkdownDiagramNode* to = SPDFLayoutNode(graph, edge.toIdentifier);
        if (!from || !to) continue;
        NSInteger span = labs(to.rank - from.rank);
        if (span < 2) continue;
        ++longEdges;
        if (edge.routePoints.count != (NSUInteger)(span - 1)) routed = NO;
        for (NSValue* value in edge.routePoints) {
            NSPoint point = value.pointValue;
            for (SPDFMarkdownDiagramNode* node in graph.nodes)
                if (NSPointInRect(point, node.frame)) clear = NO;
        }
    }
    if (expectSome)
        SPDFExpect(longEdges > 0, [what stringByAppendingString:@" has a rank-skipping edge to route"]);
    SPDFExpect(routed, [what stringByAppendingString:@" gives every long edge one bend point per column"]);
    SPDFExpect(clear, [what stringByAppendingString:@" keeps every long-edge bend point outside every box"]);
}

// A fan-out is centered on its source: the mean of the successors' cross-axis
// centers is the source's own center, which is what makes a power rail read as
// the trunk of its loads instead of the top of them.
static void SPDFExpectFanOutCentered(SPDFMarkdownDiagramGraph* graph, NSString* sourceIdentifier,
                                     NSArray<NSString*>* targets, NSString* what) {
    SPDFMarkdownDiagramNode* source = SPDFLayoutNode(graph, sourceIdentifier);
    if (!source) {
        SPDFExpect(NO, [what stringByAppendingString:@" has its fan-out source"]);
        return;
    }
    CGFloat sum = 0;
    for (NSString* identifier in targets) {
        SPDFMarkdownDiagramNode* target = SPDFLayoutNode(graph, identifier);
        if (!target) {
            SPDFExpect(NO, [what stringByAppendingString:@" has every fan-out target"]);
            return;
        }
        sum += graph.vertical ? NSMidX(target.frame) : NSMidY(target.frame);
    }
    CGFloat mean = sum / (CGFloat)targets.count;
    CGFloat center = graph.vertical ? NSMidX(source.frame) : NSMidY(source.frame);
    SPDFExpect(fabs(mean - center) <= 1.0,
               [NSString stringWithFormat:@"%@ centers %@ on its %lu loads (off by %.2f pt)", what,
                                          sourceIdentifier, (unsigned long)targets.count,
                                          fabs(mean - center)]);
}

// A -> B -> C with nothing else pulling comes out as one straight run.
static void SPDFExpectChainStraight(SPDFMarkdownDiagramGraph* graph, NSArray<NSString*>* chain, NSString* what) {
    CGFloat first = 0;
    BOOL straight = YES;
    for (NSUInteger index = 0; index < chain.count; ++index) {
        SPDFMarkdownDiagramNode* node = SPDFLayoutNode(graph, chain[index]);
        if (!node) {
            SPDFExpect(NO, [what stringByAppendingString:@" has every node of its chain"]);
            return;
        }
        CGFloat center = graph.vertical ? NSMidX(node.frame) : NSMidY(node.frame);
        if (index == 0) first = center;
        else if (fabs(center - first) > 1.0) straight = NO;
    }
    SPDFExpect(straight, [NSString stringWithFormat:@"%@ runs %@ straight", what,
                                                    [chain componentsJoinedByString:@" -> "]]);
}

// Geometry equality, used for the determinism check.
// The effective on-page size of a fitted diagram's smallest label -- the one
// number that says whether the drawing can be read at 100% zoom.
static CGFloat SPDFLayoutSmallestLabel(SPDFMarkdownDiagramLayout* layout) {
    CGFloat smallest = 0;
    for (SPDFMarkdownDiagramLabel* label in layout.labels)
        smallest = smallest > 0 ? MIN(smallest, label.fontSize) : label.fontSize;
    return smallest;
}

static BOOL SPDFLayoutsEqual(SPDFMarkdownDiagramLayout* a, SPDFMarkdownDiagramLayout* b) {
    if (!a || !b) return NO;
    if (!NSEqualSizes(a.size, b.size)) return NO;
    if (a.shapes.count != b.shapes.count || a.labels.count != b.labels.count) return NO;
    for (NSUInteger index = 0; index < a.shapes.count; ++index) {
        SPDFMarkdownDiagramShape* left = a.shapes[index];
        SPDFMarkdownDiagramShape* right = b.shapes[index];
        if (left.kind != right.kind || !NSEqualRects(left.rect, right.rect)) return NO;
        if (left.fillRole != right.fillRole || left.strokeRole != right.strokeRole) return NO;
        if (fabs(left.lineWidth - right.lineWidth) > 0 || fabs(left.radius - right.radius) > 0) return NO;
        if (left.points.count != right.points.count) return NO;
        for (NSUInteger point = 0; point < left.points.count; ++point)
            if (!NSEqualPoints(left.points[point].pointValue, right.points[point].pointValue)) return NO;
    }
    for (NSUInteger index = 0; index < a.labels.count; ++index) {
        SPDFMarkdownDiagramLabel* left = a.labels[index];
        SPDFMarkdownDiagramLabel* right = b.labels[index];
        if (![left.text isEqualToString:right.text]) return NO;
        if (!NSEqualRects(left.frame, right.frame)) return NO;
        if (left.fontSize != right.fontSize || left.alignment != right.alignment) return NO;
    }
    return YES;
}

// On the border of some node box: inside the box grown by a hair, and in its
// outer BAND rather than its middle. The band, rather than the bounding
// rectangle exactly, because an anchor on a rounded, elliptical or diamond
// outline legitimately sits a little inside the bounding box -- but never
// anywhere near the label. An endpoint that stopped short of its box, or sank
// into it, fails one way or the other.
static BOOL SPDFOnSomeBorder(NSPoint point, NSArray<SPDFMarkdownDiagramNode*>* nodes) {
    for (SPDFMarkdownDiagramNode* node in nodes) {
        NSRect frame = node.frame;
        if (!NSPointInRect(point, NSInsetRect(frame, -0.75, -0.75))) continue;
        CGFloat band = 0.35 * MIN(NSWidth(frame), NSHeight(frame));
        if (NSPointInRect(point, NSInsetRect(frame, band, band))) continue;
        return YES;
    }
    return NO;
}

// Every emitted edge polyline starts and ends ON a box border: an arrowhead
// lands on a node, never short of it and never buried inside it. In a
// flowchart every polyline IS an edge (compartment rules belong to class
// boxes), so the check needs no shape-to-edge bookkeeping.
static void SPDFExpectEdgesTouchBorders(SPDFMarkdownDiagramGraph* graph, SPDFMarkdownDiagramLayout* layout,
                                        NSString* what) {
    NSUInteger checked = 0, stray = 0;
    for (SPDFMarkdownDiagramShape* shape in layout.shapes) {
        if (shape.kind != SPDFMarkdownDiagramShapePolyline || shape.points.count < 2) continue;
        ++checked;
        if (!SPDFOnSomeBorder(shape.points.firstObject.pointValue, graph.nodes) ||
            !SPDFOnSomeBorder(shape.points.lastObject.pointValue, graph.nodes))
            ++stray;
    }
    SPDFExpect(checked >= graph.edges.count && stray == 0,
               [NSString stringWithFormat:@"%@ starts and ends every one of its %lu edge paths on a box border "
                                          @"(%lu stray)",
                                          what, (unsigned long)checked, (unsigned long)stray]);
}

// A curve is a curve: a rank-to-rank edge between boxes that are not aligned
// is emitted as a sampled path, not a two-point straight line or a right-angle
// elbow that would collapse onto its neighbours' trunk.
static void SPDFExpectSmoothEdges(SPDFMarkdownDiagramGraph* graph, SPDFMarkdownDiagramLayout* layout,
                                  NSString* what) {
    NSUInteger curved = 0;
    for (SPDFMarkdownDiagramShape* shape in layout.shapes)
        if (shape.kind == SPDFMarkdownDiagramShapePolyline && shape.points.count >= 8) ++curved;
    SPDFExpect(curved >= graph.edges.count / 2,
               [NSString stringWithFormat:@"%@ draws its offset edges as sampled curves (%lu of %lu)", what,
                                          (unsigned long)curved, (unsigned long)graph.edges.count]);
}

// Nothing the layout draws may reach past the size it reports: the fit factor
// comes from `natural`, so one attempt's size over another attempt's frames
// spills past the bottom -- the reflow bug this pins.
static void SPDFExpectDrawnWithinSize(SPDFMarkdownDiagramLayout* layout, NSString* what) {
    CGFloat maxX = 0, maxY = 0;
    for (SPDFMarkdownDiagramShape* shape in layout.shapes) {
        maxX = MAX(maxX, NSMaxX(shape.rect));
        maxY = MAX(maxY, NSMaxY(shape.rect));
        for (NSValue* value in shape.points) {
            maxX = MAX(maxX, value.pointValue.x);
            maxY = MAX(maxY, value.pointValue.y);
        }
    }
    for (SPDFMarkdownDiagramLabel* label in layout.labels) {
        maxX = MAX(maxX, NSMaxX(label.frame));
        maxY = MAX(maxY, NSMaxY(label.frame));
    }
    SPDFExpect(maxX <= layout.size.width + 1.0 && maxY <= layout.size.height + 1.0,
               [NSString stringWithFormat:@"%@ keeps every drawn point inside its %.0fx%.0f box "
                                          @"(reaches %.0fx%.0f)",
                                          what, layout.size.width, layout.size.height, maxX, maxY]);
}

int main(void) {
    @autoreleasepool {
        NSString* fence = SPDFLayoutFixtureFence();
        SPDFExpect(fence.length > 0, @"the power-tree fixture carries one mermaid fence");
        if (!fence.length) return SPDFFinishTests(@"SPDFMarkdownDiagramLayoutTests");

        // Warm the text system first: the layout deadline covers LAYOUT, and a
        // cold Core Text would otherwise time the font cache instead.
        (void)SPDFLayoutGraphForSource(fence, NULL, NULL);
        double milliseconds = 0;
        SPDFMarkdownDiagramLayout* emitted = nil;
        SPDFMarkdownDiagramGraph* graph = SPDFLayoutGraphForSource(fence, &milliseconds, &emitted);
        SPDFExpect(graph != nil, @"the power-tree fixture lays out");
        if (!graph) return SPDFFinishTests(@"SPDFMarkdownDiagramLayoutTests");

        SPDFExpect(graph.nodes.count <= SPDFMarkdownDiagramMaximumNodes &&
                       graph.edges.count <= SPDFMarkdownDiagramMaximumEdges,
                   [NSString stringWithFormat:@"the fixture fits the node/edge budgets (%lu nodes, %lu edges)",
                                              (unsigned long)graph.nodes.count,
                                              (unsigned long)graph.edges.count]);
        // The graph pass on its own, with the boxes already measured -- the
        // deadline the layout enforces covers exactly this.
        // On its OWN copy: the pass rewrites every frame origin, and the
        // properties below read the frames the emitter actually drew.
        SPDFMarkdownDiagramGraph* measured = SPDFLayoutGraphForSource(fence, NULL, NULL);
        NSSize bounds = NSZeroSize;
        CFAbsoluteTime graphStart = CFAbsoluteTimeGetCurrent();
        BOOL laid = measured && SPDFMarkdownDiagramLayoutGraph(measured, 34, 44,
                                                               graphStart + SPDFMarkdownDiagramLayoutDeadline,
                                                               &bounds);
        double graphMilliseconds = (CFAbsoluteTimeGetCurrent() - graphStart) * 1000;
        printf("Diagram layout (power-tree, %lu nodes / %lu edges): graph %.2f ms, measure+emit %.2f ms\n",
               (unsigned long)graph.nodes.count, (unsigned long)graph.edges.count, graphMilliseconds,
               milliseconds);
        SPDFExpect(laid, @"the fixture's graph pass succeeds inside the deadline");
        // Measured on the fixture; the headroom is the point of the number, so
        // the assertion is deliberately much tighter than the 50 ms budget.
        SPDFExpect(graphMilliseconds < SPDFMarkdownDiagramLayoutDeadline * 1000 / 5,
                   [NSString stringWithFormat:@"the fixture's graph pass takes a fifth of the 50 ms deadline "
                                              @"(%.2f ms)",
                                              graphMilliseconds]);
        SPDFExpect(milliseconds < SPDFMarkdownDiagramLayoutDeadline * 1000,
                   [NSString stringWithFormat:@"measure + layout + emit fits the 50 ms deadline (%.2f ms)",
                                              milliseconds]);

        SPDFExpectNoOverlaps(graph, @"the power tree");
        SPDFExpectColumnsMonotone(graph, @"the power tree");
        SPDFExpectColumnAir(graph, @"the power tree");
        // Every power-tree edge happens to join adjacent columns, so nothing
        // needs a detour; the property still has to hold vacuously.
        SPDFExpectRoutedLongEdges(graph, NO, @"the power tree");
        SPDFExpectEdgesTouchBorders(graph, emitted, @"the power tree");
        SPDFExpectSmoothEdges(graph, emitted, @"the power tree");
        // The always-on rail and its four loads, and the source -> buck -> rail
        // chain that feeds them.
        SPDFExpectFanOutCentered(graph, @"AON", @[ @"NRF", @"IMU", @"ALS", @"KEYS" ], @"the power tree");
        SPDFExpectChainStraight(graph, @[ @"U101", @"AON" ], @"the power tree");
        SPDFExpectChainStraight(graph, @[ @"SW", @"LTE", @"MODEM" ], @"the power tree");

        // Determinism: same source, same geometry, twice, including after the
        // graph model has been laid out once already.
        SPDFMarkdownDiagramLayout* first = SPDFMarkdownDiagramRender(@"mermaid", fence, kSPDFLayoutTestBox,
                                                                     1.0, nil);
        SPDFMarkdownDiagramLayout* second = SPDFMarkdownDiagramRender(@"mermaid", fence, kSPDFLayoutTestBox,
                                                                      1.0, nil);
        SPDFExpect(SPDFLayoutsEqual(first, second), @"two renders of the fixture are geometrically identical");
        SPDFExpect(first.size.width <= SPDFMarkdownDiagramMaximumDimension &&
                       first.size.height <= SPDFMarkdownDiagramMaximumDimension,
                   @"the fixture stays inside the 2048 pt dimension budget");

        // --- Sized by the PAGE, not by the inline-image budget ---------------
        //
        // The fixture is 1687 x 968 pt naturally, so on A4 it is always fitted;
        // what these pin is that the fit is taken from the real printable box
        // of the paper the plan will use, both axes, and that a fit the box
        // would push under the legibility floor is allowed to RE-LAY-OUT the
        // graph narrower instead of only shrinking it further.
        NSSize natural = SPDFMarkdownDiagramRender(@"mermaid", fence, NSMakeSize(4096, 0), 1.0, nil).size;
        NSSize portraitBox = [SPDFMarkdownPageConfiguration A4PortraitConfiguration].printableRect.size;
        NSSize landscapeBox = [SPDFMarkdownPageConfiguration A4LandscapeConfiguration].printableRect.size;
        SPDFMarkdownDiagramLayout* portrait = SPDFMarkdownDiagramRender(@"mermaid", fence, portraitBox, 1.0, nil);
        SPDFMarkdownDiagramLayout* landscape =
            SPDFMarkdownDiagramRender(@"mermaid", fence, landscapeBox, 1.0, nil);
        CGFloat oldSize = SPDFLayoutSmallestLabel(first);  // the old 440 pt inline-image budget
        CGFloat portraitSize = SPDFLayoutSmallestLabel(portrait);
        CGFloat landscapeSize = SPDFLayoutSmallestLabel(landscape);
        printf("Diagram fit (power-tree), smallest label: 440 pt box %.2f pt, A4 portrait box %.2f pt, "
               "A4 landscape box %.2f pt\n",
               oldSize, portraitSize, landscapeSize);
        SPDFExpect(portrait.size.width <= portraitBox.width + 0.5 &&
                       portrait.size.height <= portraitBox.height + 0.5 &&
                       landscape.size.width <= landscapeBox.width + 0.5 &&
                       landscape.size.height <= landscapeBox.height + 0.5,
                   @"a fitted diagram fits the printable BOX, both axes, on either paper");
        SPDFExpect(portraitSize > oldSize && landscapeSize > portraitSize,
                   @"the page box beats the image budget, and turning the paper beats portrait");
        // The reflow is not free scaling: it must beat what a pure width fit of
        // the natural drawing could ever have produced.
        SPDFExpect(portraitSize > 12.0 * portraitBox.width / natural.width + 0.05 &&
                       landscapeSize > 12.0 * landscapeBox.width / natural.width + 0.05,
                   @"the legibility reflow beats a pure rescale of the natural layout");
        SPDFExpect(SPDFLayoutsEqual(portrait, SPDFMarkdownDiagramRender(@"mermaid", fence, portraitBox, 1.0,
                                                                        nil)),
                   @"the reflowed fit is deterministic: same source and same box, same geometry");

        // A diagram that already fits its box is untouched by the search: same
        // geometry as the natural layout, so nothing that fits ever pays for it.
        NSString* small = @"flowchart LR\n  A[One] --> B[Two] --> C[Three]\n";
        SPDFExpect(SPDFLayoutsEqual(SPDFMarkdownDiagramRender(@"mermaid", small, NSMakeSize(4096, 0), 1.0, nil),
                                    SPDFMarkdownDiagramRender(@"mermaid", small, portraitBox, 1.0, nil)),
                   @"a diagram that fits the page box comes out exactly as its natural layout");
        // A box that only constrains the HEIGHT still fits: the old width-only
        // fit would have left this one hanging off the bottom of the page.
        SPDFMarkdownDiagramLayout* shortBox =
            SPDFMarkdownDiagramRender(@"mermaid", fence, NSMakeSize(4096, 300), 1.0, nil);
        SPDFExpect(shortBox != nil && shortBox.size.height <= 300.5,
                   @"a height-only box fits the diagram by its height");
        CFAbsoluteTime fitStart = CFAbsoluteTimeGetCurrent();
        (void)SPDFMarkdownDiagramRender(@"mermaid", fence, portraitBox, 1.0, nil);
        double fitMilliseconds = (CFAbsoluteTimeGetCurrent() - fitStart) * 1000;
        printf("Diagram fit (power-tree, reflow search): %.2f ms\n", fitMilliseconds);
        SPDFExpect(fitMilliseconds < SPDFMarkdownDiagramLayoutDeadline * 1000,
                   [NSString stringWithFormat:@"the whole reflow search fits the 50 ms deadline (%.2f ms)",
                                              fitMilliseconds]);

        // A top-down graph with a rank-skipping edge and a cycle keeps every
        // property; the flow axis just changes which one it is.
        NSString* vertical = @"flowchart TD\n"
                              "  A[Start] --> B{Valid?}\n"
                              "  B -->|yes| C[Fetch]\n"
                              "  B -->|no| D[Reject]\n"
                              "  C --> E[Transform]\n"
                              "  E --> F[(Store)]\n"
                              "  A --> F\n"
                              "  D --> G[Log]\n"
                              "  G --> A\n";
        SPDFMarkdownDiagramLayout* downLayout = nil;
        SPDFMarkdownDiagramGraph* down = SPDFLayoutGraphForSource(vertical, NULL, &downLayout);
        SPDFExpect(down != nil && down.vertical, @"the top-down graph lays out on the vertical axis");
        if (down) {
            SPDFExpectNoOverlaps(down, @"the top-down graph");
            SPDFExpectColumnsMonotone(down, @"the top-down graph");
            SPDFExpectColumnAir(down, @"the top-down graph");
            SPDFExpectRoutedLongEdges(down, YES, @"the top-down graph");
            SPDFExpectEdgesTouchBorders(down, downLayout, @"the top-down graph");
        }

        // At the budget ceiling, with long rank-skipping edges everywhere (the
        // case that makes routing dummies multiply), the seam must still
        // answer inside the deadline -- with a layout or, honestly, with nil.
        NSMutableString* dense = [NSMutableString stringWithString:@"flowchart LR\n"];
        for (NSUInteger index = 0; index + 1 < 190; ++index)
            [dense appendFormat:@"  n%lu --> n%lu\n", (unsigned long)index, (unsigned long)(index + 1)];
        for (NSUInteger index = 0; index + 40 < 190; index += 2)
            [dense appendFormat:@"  n%lu --> n%lu\n", (unsigned long)index, (unsigned long)(index + 40)];
        CFAbsoluteTime denseStart = CFAbsoluteTimeGetCurrent();
        SPDFMarkdownDiagramLayout* denseLayout = SPDFMarkdownDiagramRender(@"mermaid", dense,
                                                                           kSPDFLayoutTestBox, 1.0, nil);
        double denseMilliseconds = (CFAbsoluteTimeGetCurrent() - denseStart) * 1000;
        printf("Diagram layout (dense 190-node chain + 75 long edges): %.2f ms, %s\n", denseMilliseconds,
               denseLayout ? "laid out" : "declined");
        SPDFExpect(denseMilliseconds < 400,
                   [NSString stringWithFormat:@"a budget-ceiling graph answers promptly (%.2f ms)",
                                              denseMilliseconds]);

        // A right-to-left graph mirrors the finished coordinates, so its ranks
        // run the other way; nothing else about the drawing may change.
        SPDFMarkdownDiagramGraph* mirrored =
            SPDFLayoutGraphForSource(@"flowchart RL\n  A --> B --> C\n", NULL, NULL);
        SPDFExpect(mirrored != nil && mirrored.reversed, @"the right-to-left graph lays out mirrored");
        if (mirrored) {
            SPDFExpectNoOverlaps(mirrored, @"the right-to-left graph");
            SPDFMarkdownDiagramNode* a = SPDFLayoutNode(mirrored, @"A");
            SPDFMarkdownDiagramNode* c = SPDFLayoutNode(mirrored, @"C");
            SPDFExpect(a && c && NSMinX(a.frame) > NSMaxX(c.frame),
                       @"the right-to-left graph puts the source to the right of the sink");
        }
        // --- A reflow rung that overruns the dimension budget -----------------
        //
        // A tall chain of labels whose widest line clears the 130 pt ladder
        // rung, so the reflow tries narrower wraps. The natural drawing (~1800
        // pt) clears the 2048 pt budget, but a narrower wrap adds a line to each
        // of the 24 boxes and pushes the total over 2048, so a rung mid-search
        // trips the budget and fails -- leaving its over-tall frames on the
        // graph. Unless the search re-lays-out at its best wrap, the diagram
        // reports a box it fits but draws past the bottom of it. (Should font
        // metrics move the natural size itself past 2048, the render declines
        // to nil instead -- still no mis-fit.)
        NSMutableString* ladderTrip = [NSMutableString stringWithString:@"flowchart TD\n"];
        for (NSUInteger i = 0; i + 1 < 24; ++i)
            [ladderTrip appendFormat:@"  q%lu[Node Alpha Bravo %lu] --> q%lu[Node Alpha Bravo %lu]\n",
                                     (unsigned long)i, (unsigned long)i, (unsigned long)(i + 1),
                                     (unsigned long)(i + 1)];
        NSSize tripBox = {700, 700};
        SPDFMarkdownDiagramLayout* trip = SPDFMarkdownDiagramRender(@"mermaid", ladderTrip, tripBox, 1.0, nil);
        NSSize tripNatural = SPDFMarkdownDiagramRender(@"mermaid", ladderTrip, NSMakeSize(4096, 0), 1.0,
                                                       nil).size;
        printf("Diagram reflow rung trip (24-node chain): natural %.0fx%.0f, fitted %.0fx%.0f\n",
               tripNatural.width, tripNatural.height, trip.size.width, trip.size.height);
        SPDFExpect(tripNatural.height < SPDFMarkdownDiagramMaximumDimension,
                   @"the reflow-trip fixture's natural drawing clears the dimension budget");
        if (trip) {
            SPDFExpect(trip.size.width <= tripBox.width + 0.5 && trip.size.height <= tripBox.height + 0.5,
                       @"the reflow-trip fixture is fitted to its page box");
            SPDFExpectDrawnWithinSize(trip, @"a diagram whose reflow rung overran the budget");
        }
    }
    return SPDFFinishTests(@"SPDFMarkdownDiagramLayoutTests");
}
