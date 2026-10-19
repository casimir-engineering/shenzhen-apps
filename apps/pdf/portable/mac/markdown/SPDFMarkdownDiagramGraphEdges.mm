#import "SPDFMarkdownDiagramInternal.h"

#include <algorithm>
#include <vector>

// Edge routing and emission for the flowchart-family graphs. Split out of
// SPDFMarkdownDiagramGraphShapes so node measurement and box drawing stay one
// concern and edge geometry another.
//
// The whole point of this file is that edges are routed as a FAMILY, not one
// at a time. Every edge leaving one border of one node shares that border, and
// anchoring them all at its midpoint made a fan self-intersect right where it
// leaves the box: four curves from one point, each with its own control
// length, swapping order within a few points of the source. Three things fix
// that, and together they make a fan provably non-crossing:
//
//   1. SPREAD ANCHORS. A pre-pass groups the edges by the border they use,
//      sorts each group by where its far end sits on the cross axis, and
//      spreads the anchors along the border in that same order -- topmost
//      target, topmost anchor. Fan-INS get the same treatment on the arriving
//      border.
//   2. A DEPARTURE LANE. Every edge runs straight out of its anchor to a lane
//      a fixed distance beyond the node's bounding border, so a whole fan
//      starts curving at the same coordinate on the flow axis. Straight runs
//      at distinct cross positions cannot cross each other.
//   3. AN ARRIVAL LANE at the leading edge of the target's COLUMN, where the
//      curve ends and a straight run carries the arrow into the box. A column
//      is a lane line every edge entering it shares.
//
// With both ends of the curve pinned to the same two flow-axis coordinates,
// the two control points of the cubic sit on those same coordinates too, so
// the cross-axis position of the curve is a fixed convex combination of its
// two anchors: two curves of one fan with ordered anchors and ordered targets
// stay ordered at every point. That is what the routing tests assert, and it
// is why the fix is not "nudge the control lengths until it looks right".

static const CGFloat kSPDFDiagramFanStep = 9;           // ideal anchor pitch along a border
static const CGFloat kSPDFDiagramFanBorderShare = 0.8;  // of the border a fan may use
static const CGFloat kSPDFDiagramDepartLane = 10;       // straight run out of a border

static NSValue* SPDFEdgePoint(CGFloat x, CGFloat y) { return [NSValue valueWithPoint:NSMakePoint(x, y)]; }

// A point on the node's own OUTLINE at `crossOffset` from its center, on the
// rising or falling side of the flow axis. A fanned anchor slid along a
// bounding box would float off a rounded, elliptical or diamond node; this
// pulls it back onto the shape the emitter actually draws.
static CGFloat SPDFDiagramOutlineMain(SPDFMarkdownDiagramNode* node, BOOL vertical, BOOL rising,
                                      CGFloat crossOffset, CGFloat scale) {
    NSRect frame = node.frame;
    CGFloat mainHalf = (vertical ? NSHeight(frame) : NSWidth(frame)) / 2;
    CGFloat crossHalf = (vertical ? NSWidth(frame) : NSHeight(frame)) / 2;
    CGFloat center = vertical ? NSMidY(frame) : NSMidX(frame);
    CGFloat reach = mainHalf;
    CGFloat offset = MIN(fabs(crossOffset), crossHalf);
    switch (node.shape) {
        case SPDFMarkdownDiagramNodeShapeCircle:
        case SPDFMarkdownDiagramNodeShapeStartDot:
        case SPDFMarkdownDiagramNodeShapeEndDot:
            reach = crossHalf > 0.001 ? mainHalf * sqrt(MAX(0, 1 - (offset / crossHalf) * (offset / crossHalf)))
                                      : mainHalf;
            break;
        case SPDFMarkdownDiagramNodeShapeDiamond:
            reach = crossHalf > 0.001 ? mainHalf * (1 - offset / crossHalf) : mainHalf;
            break;
        case SPDFMarkdownDiagramNodeShapeRound:
        case SPDFMarkdownDiagramNodeShapeStadium: {
            // One formula for every rounded rect: flat until the corner arc
            // starts, then the arc. Radius matches what SPDFDiagramAddNodeShape
            // asks the canvas for, clamped the same way.
            CGFloat radius = node.shape == SPDFMarkdownDiagramNodeShapeStadium ? NSHeight(frame) / 2 : 8 * scale;
            radius = MAX(0, MIN(radius, MIN(NSWidth(frame), NSHeight(frame)) / 2));
            CGFloat into = offset - (crossHalf - radius);
            if (into > 0) reach = mainHalf - (radius - sqrt(MAX(0, radius * radius - into * into)));
            break;
        }
        default:
            break;
    }
    return rising ? center + reach : center - reach;
}

// Where the segment toward `toward` leaves the node's frame. Still the answer
// for a same-band edge, which has no facing borders to fan across.
static NSPoint SPDFDiagramAnchor(SPDFMarkdownDiagramNode* node, NSPoint toward) {
    NSRect frame = node.frame;
    NSPoint center = NSMakePoint(NSMidX(frame), NSMidY(frame));
    CGFloat dx = toward.x - center.x;
    CGFloat dy = toward.y - center.y;
    if (fabs(dx) < 0.001 && fabs(dy) < 0.001) return center;
    CGFloat scaleX = fabs(dx) > 0.001 ? (NSWidth(frame) / 2) / fabs(dx) : CGFLOAT_MAX;
    CGFloat scaleY = fabs(dy) > 0.001 ? (NSHeight(frame) / 2) / fabs(dy) : CGFLOAT_MAX;
    CGFloat scale = MIN(scaleX, scaleY);
    return NSMakePoint(center.x + dx * scale, center.y + dy * scale);
}

static void SPDFDiagramAddArrowHead(SPDFMarkdownDiagramCanvas* canvas, NSPoint tip, NSPoint fromDirection,
                                    SPDFMarkdownDiagramArrowHead head, CGFloat scale) {
    if (head == SPDFMarkdownDiagramArrowHeadNone) return;
    CGFloat dx = tip.x - fromDirection.x;
    CGFloat dy = tip.y - fromDirection.y;
    CGFloat length = hypot(dx, dy);
    if (length < 0.001) return;
    dx /= length;
    dy /= length;
    BOOL diamond = head == SPDFMarkdownDiagramArrowHeadFilledDiamond ||
                   head == SPDFMarkdownDiagramArrowHeadHollowDiamond;
    CGFloat size = (head == SPDFMarkdownDiagramArrowHeadArrow ? 7 : 9) * scale;
    NSPoint back = NSMakePoint(tip.x - dx * size, tip.y - dy * size);
    NSMutableArray<NSValue*>* points = [NSMutableArray arrayWithCapacity:4];
    [points addObject:SPDFEdgePoint(tip.x, tip.y)];
    [points addObject:SPDFEdgePoint(back.x - dy * size * 0.5, back.y + dx * size * 0.5)];
    if (diamond) [points addObject:SPDFEdgePoint(tip.x - dx * size * 2, tip.y - dy * size * 2)];
    [points addObject:SPDFEdgePoint(back.x + dy * size * 0.5, back.y - dx * size * 0.5)];
    BOOL hollow = head == SPDFMarkdownDiagramArrowHeadHollowTriangle ||
                  head == SPDFMarkdownDiagramArrowHeadHollowDiamond;
    [canvas addPolygon:points
                  fill:hollow ? SPDFMarkdownDiagramRolePaper : SPDFMarkdownDiagramRoleSecondary
                stroke:SPDFMarkdownDiagramRoleSecondary
                 width:1];
}

// A smooth curve through `waypoints`, sampled into a polyline. Each span is a
// cubic Bezier whose two control points sit on the FLOW axis, half a span
// apart: that makes the path leave and land perpendicular to a node's border,
// keeps it monotone along the flow axis (so a fan-out never loops back over
// its own source anchor), and joins spans with a matching tangent, so a
// rank-skipping route reads as one continuous wave. The shape vocabulary has
// no curve primitive and does not need one -- at this density the sampled path
// IS the curve for screen, print and PDF export alike, and two edges that
// cross stay traceable instead of collapsing onto a shared right-angle trunk.
static NSArray<NSValue*>* SPDFDiagramCurveThrough(NSArray<NSValue*>* waypoints, BOOL vertical) {
    if (waypoints.count < 2) return waypoints;
    const NSUInteger samples = 8;
    NSMutableArray<NSValue*>* path = [NSMutableArray arrayWithCapacity:(waypoints.count - 1) * samples + 1];
    [path addObject:waypoints.firstObject];
    for (NSUInteger index = 0; index + 1 < waypoints.count; ++index) {
        NSPoint a = waypoints[index].pointValue, d = waypoints[index + 1].pointValue;
        CGFloat reach = (vertical ? (d.y - a.y) : (d.x - a.x)) / 2;
        NSPoint b = vertical ? NSMakePoint(a.x, a.y + reach) : NSMakePoint(a.x + reach, a.y);
        NSPoint c = vertical ? NSMakePoint(d.x, d.y - reach) : NSMakePoint(d.x - reach, d.y);
        if (fabs(vertical ? (d.x - a.x) : (d.y - a.y)) < 0.5) {  // already aligned: a straight run
            [path addObject:SPDFEdgePoint(d.x, d.y)];
            continue;
        }
        for (NSUInteger step = 1; step <= samples; ++step) {
            CGFloat t = (CGFloat)step / samples, u = 1 - t;
            CGFloat w0 = u * u * u, w1 = 3 * u * u * t, w2 = 3 * u * t * t, w3 = t * t * t;
            [path addObject:SPDFEdgePoint(w0 * a.x + w1 * b.x + w2 * c.x + w3 * d.x,
                                          w0 * a.y + w1 * b.y + w2 * c.y + w3 * d.y)];
        }
    }
    return path;
}

namespace {

// One edge's resolved route, filled in by the grouping pass.
struct SPDFEdgeRoute {
    BOOL curved = NO;        // facing borders, so it fans and curves
    BOOL rising = YES;       // target sits later along the flow axis
    NSInteger source = -1;   // node index, or -1 when the edge is not routed
    NSInteger target = -1;
    CGFloat startMain = 0, endMain = 0;    // the two facing bounding borders
    CGFloat startCross = 0, endCross = 0;  // anchor position ALONG each border
    CGFloat startGuide = 0, endGuide = 0;  // where the far end sits, for ordering
    CGFloat span = 0;                      // flow-axis distance between borders
    CGFloat endLane = 0;                   // leading edge of the target's column
};

// One shared border: a node plus which side of it, and the edges using it.
struct SPDFBorderGroup {
    NSInteger key = 0;
    std::vector<NSUInteger> edges;
};

}  // namespace

// Spreads one group's anchors along its border, in the order the group was
// sorted into. A group of one keeps the border midpoint, so an ordinary edge
// is untouched.
static void SPDFDiagramFanBorder(std::vector<SPDFEdgeRoute>& routes, const std::vector<NSUInteger>& group,
                                 CGFloat center, CGFloat extent, CGFloat scale, BOOL departing) {
    size_t count = group.size();
    if (count < 2) return;
    CGFloat span = MIN(extent * kSPDFDiagramFanBorderShare, kSPDFDiagramFanStep * scale * (CGFloat)(count - 1));
    for (size_t position = 0; position < count; ++position) {
        CGFloat offset = -span / 2 + span * (CGFloat)position / (CGFloat)(count - 1);
        SPDFEdgeRoute& route = routes[group[position]];
        if (departing) route.startCross = center + offset;
        else route.endCross = center + offset;
    }
}

// Groups the routed edges by the border they share and fans each group. Sorting
// is by the far end's cross position with the edge index as the tie-break, so
// the assignment is a pure function of the graph.
static void SPDFDiagramFanBorders(std::vector<SPDFEdgeRoute>& routes,
                                  NSArray<SPDFMarkdownDiagramNode*>* nodes, BOOL vertical, CGFloat scale,
                                  BOOL departing) {
    std::vector<SPDFBorderGroup> groups;
    for (NSUInteger index = 0; index < routes.size(); ++index) {
        const SPDFEdgeRoute& route = routes[index];
        if (!route.curved) continue;
        NSInteger node = departing ? route.source : route.target;
        NSInteger key = node * 2 + ((departing ? route.rising : !route.rising) ? 1 : 0);
        auto found = std::find_if(groups.begin(), groups.end(),
                                  [key](const SPDFBorderGroup& group) { return group.key == key; });
        if (found == groups.end()) {
            groups.push_back({key, {index}});
        } else {
            found->edges.push_back(index);
        }
    }
    for (SPDFBorderGroup& group : groups) {
        std::stable_sort(group.edges.begin(), group.edges.end(),
                         [&routes, departing](NSUInteger a, NSUInteger b) {
                           CGFloat left = departing ? routes[a].startGuide : routes[a].endGuide;
                           CGFloat right = departing ? routes[b].startGuide : routes[b].endGuide;
                           return left < right;
                         });
        SPDFMarkdownDiagramNode* node =
            nodes[(NSUInteger)(departing ? routes[group.edges[0]].source : routes[group.edges[0]].target)];
        CGFloat center = vertical ? NSMidX(node.frame) : NSMidY(node.frame);
        CGFloat extent = vertical ? NSWidth(node.frame) : NSHeight(node.frame);
        SPDFDiagramFanBorder(routes, group.edges, center, extent, scale, departing);
    }
}

void SPDFMarkdownDiagramEmitGraphEdges(SPDFMarkdownDiagramCanvas* canvas, SPDFMarkdownDiagramGraph* graph,
                                       NSFont* labelFont, CGFloat scale) {
    NSArray<SPDFMarkdownDiagramNode*>* nodes = graph.nodes;
    NSArray<SPDFMarkdownDiagramEdge*>* edges = graph.edges;
    BOOL vertical = graph.vertical;
    NSMutableDictionary<NSString*, NSNumber*>* indexes = [NSMutableDictionary dictionaryWithCapacity:nodes.count];
    for (NSUInteger index = 0; index < nodes.count; ++index) indexes[nodes[index].identifier] = @(index);

    // Pass 1: classify. A pair of nodes whose bands face each other along the
    // flow axis routes as a curve and joins two border groups; anything else
    // (a self-loop, two boxes in the same band) keeps its own straight line.
    std::vector<SPDFEdgeRoute> routes(edges.count);
    for (NSUInteger index = 0; index < edges.count; ++index) {
        NSNumber* fromNumber = indexes[edges[index].fromIdentifier];
        NSNumber* toNumber = indexes[edges[index].toIdentifier];
        if (!fromNumber || !toNumber || [fromNumber isEqualToNumber:toNumber]) continue;
        SPDFMarkdownDiagramNode* from = nodes[fromNumber.unsignedIntegerValue];
        SPDFMarkdownDiagramNode* to = nodes[toNumber.unsignedIntegerValue];
        CGFloat fromLow = vertical ? NSMinY(from.frame) : NSMinX(from.frame);
        CGFloat fromHigh = vertical ? NSMaxY(from.frame) : NSMaxX(from.frame);
        CGFloat toLow = vertical ? NSMinY(to.frame) : NSMinX(to.frame);
        CGFloat toHigh = vertical ? NSMaxY(to.frame) : NSMaxX(to.frame);
        if (!(toLow >= fromHigh || toHigh <= fromLow)) continue;
        SPDFEdgeRoute& route = routes[index];
        route.curved = YES;
        route.rising = toLow >= fromHigh;
        route.source = (NSInteger)fromNumber.unsignedIntegerValue;
        route.target = (NSInteger)toNumber.unsignedIntegerValue;
        route.startMain = route.rising ? fromHigh : fromLow;
        route.endMain = route.rising ? toLow : toHigh;
        route.span = fabs(route.endMain - route.startMain);
        route.startCross = vertical ? NSMidX(from.frame) : NSMidY(from.frame);
        route.endCross = vertical ? NSMidX(to.frame) : NSMidY(to.frame);
        // Order a fan by where each edge is HEADING: its first bend point when
        // the layout reserved one, else the far node's own center.
        NSArray<NSValue*>* bends = edges[index].routePoints;
        NSPoint firstBend = bends.count ? bends.firstObject.pointValue : NSZeroPoint;
        NSPoint lastBend = bends.count ? bends.lastObject.pointValue : NSZeroPoint;
        route.startGuide = bends.count ? (vertical ? firstBend.x : firstBend.y) : route.endCross;
        route.endGuide = bends.count ? (vertical ? lastBend.x : lastBend.y)
                                     : (vertical ? NSMidX(from.frame) : NSMidY(from.frame));
        // The lane line of the target's COLUMN: where every edge entering that
        // column stops curving and runs straight into its box. Boxes are
        // centered in their band, so a narrow one starts later than a wide one
        // -- and a curve that had to reach further was the sharper curve, which
        // is exactly how two edges out of one node used to cross.
        CGFloat lane = route.endMain;
        for (SPDFMarkdownDiagramNode* peer in nodes) {
            if (peer.rank != to.rank) continue;
            CGFloat edgeMain = route.rising ? (vertical ? NSMinY(peer.frame) : NSMinX(peer.frame))
                                            : (vertical ? NSMaxY(peer.frame) : NSMaxX(peer.frame));
            lane = route.rising ? MIN(lane, edgeMain) : MAX(lane, edgeMain);
        }
        route.endLane = lane;
    }

    // Pass 2: fan every shared border, departures and arrivals alike.
    SPDFDiagramFanBorders(routes, nodes, vertical, scale, YES);
    SPDFDiagramFanBorders(routes, nodes, vertical, scale, NO);

    // Pass 3: emit.
    for (NSUInteger index = 0; index < edges.count; ++index) {
        SPDFMarkdownDiagramEdge* edge = edges[index];
        SPDFMarkdownDiagramNode* from = [graph existingNodeForIdentifier:edge.fromIdentifier];
        SPDFMarkdownDiagramNode* to = [graph existingNodeForIdentifier:edge.toIdentifier];
        if (!from || !to) continue;
        const SPDFEdgeRoute& route = routes[index];
        NSArray<NSValue*>* points = nil;
        if (from == to) {
            // Self-loop: a small square detour off the node's right edge.
            CGFloat loop = 18 * scale;
            NSPoint start = NSMakePoint(NSMaxX(from.frame), NSMidY(from.frame) - 6 * scale);
            NSPoint end = NSMakePoint(NSMaxX(from.frame), NSMidY(from.frame) + 6 * scale);
            points = @[
                SPDFEdgePoint(start.x, start.y), SPDFEdgePoint(start.x + loop, start.y),
                SPDFEdgePoint(end.x + loop, end.y), SPDFEdgePoint(end.x, end.y)
            ];
        } else if (route.curved) {
            CGFloat direction = route.rising ? 1 : -1;
            CGFloat fromMiddle = vertical ? NSMidX(from.frame) : NSMidY(from.frame);
            CGFloat toMiddle = vertical ? NSMidX(to.frame) : NSMidY(to.frame);
            CGFloat startMain =
                SPDFDiagramOutlineMain(from, vertical, route.rising, route.startCross - fromMiddle, scale);
            CGFloat endMain =
                SPDFDiagramOutlineMain(to, vertical, !route.rising, route.endCross - toMiddle, scale);
            NSMutableArray<NSValue*>* waypoints = [NSMutableArray array];
            [waypoints addObject:vertical ? SPDFEdgePoint(route.startCross, startMain)
                                          : SPDFEdgePoint(startMain, route.startCross)];
            // The departure lane is measured from the node's BOUNDING border,
            // not from the outline anchor, so every edge off one border starts
            // curving at the same coordinate however far its own anchor was
            // pulled in by a rounded cap.
            CGFloat departLane = route.startMain + direction * MIN(kSPDFDiagramDepartLane * scale,
                                                                   route.span * 0.3);
            if (fabs(departLane - startMain) > 0.5)
                [waypoints addObject:vertical ? SPDFEdgePoint(route.startCross, departLane)
                                              : SPDFEdgePoint(departLane, route.startCross)];
            [waypoints addObjectsFromArray:edge.routePoints ?: @[]];
            if (fabs(route.endLane - endMain) > 0.5)
                [waypoints addObject:vertical ? SPDFEdgePoint(route.endCross, route.endLane)
                                              : SPDFEdgePoint(route.endLane, route.endCross)];
            [waypoints addObject:vertical ? SPDFEdgePoint(route.endCross, endMain)
                                          : SPDFEdgePoint(endMain, route.endCross)];
            points = SPDFDiagramCurveThrough(waypoints, vertical);
        } else {
            // Overlapping bands (same rank) keep a straight border-to-border line.
            NSPoint fromCenter = NSMakePoint(NSMidX(from.frame), NSMidY(from.frame));
            NSPoint toCenter = NSMakePoint(NSMidX(to.frame), NSMidY(to.frame));
            NSPoint start = SPDFDiagramAnchor(from, toCenter);
            NSPoint end = SPDFDiagramAnchor(to, fromCenter);
            points = @[ SPDFEdgePoint(start.x, start.y), SPDFEdgePoint(end.x, end.y) ];
        }
        [canvas addPolyline:points
                     stroke:SPDFMarkdownDiagramRoleSecondary
                      width:edge.lineStyle == SPDFMarkdownDiagramLineStyleThick ? 2.5 : 1.2
                       dash:edge.lineStyle == SPDFMarkdownDiagramLineStyleDashed ? 4 * scale : 0];
        SPDFDiagramAddArrowHead(canvas, points.lastObject.pointValue, points[points.count - 2].pointValue,
                                edge.head, scale);
        // `<-->`: the same head, pointing back out of the `from` node.
        SPDFDiagramAddArrowHead(canvas, points.firstObject.pointValue, points[1].pointValue, edge.tail, scale);
        if (!edge.label.length) continue;
        // Label chip at the path midpoint, backed with paper so the text stays
        // readable where it crosses the line.
        NSPoint a = points[(points.count - 1) / 2].pointValue;
        NSPoint b = points[(points.count - 1) / 2 + (points.count > 1 ? 1 : 0)].pointValue;
        NSPoint middle = NSMakePoint((a.x + b.x) / 2, (a.y + b.y) / 2);
        NSSize text = SPDFMarkdownDiagramMeasureText(edge.label, labelFont, 150 * scale);
        NSRect chip = NSMakeRect(middle.x - text.width / 2 - 4, middle.y - text.height / 2 - 2, text.width + 8,
                                 text.height + 4);
        [canvas addRect:chip
                 radius:4
                   fill:SPDFMarkdownDiagramRolePaper
                 stroke:SPDFMarkdownDiagramRoleNone
                  width:0];
        [canvas addText:edge.label
                 inRect:NSInsetRect(chip, 4, 2)
                   font:labelFont
                   role:SPDFMarkdownDiagramRoleSecondary
              alignment:NSTextAlignmentCenter];
    }
}
