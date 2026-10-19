#import "SPDFMarkdownDiagramInternal.h"

#include <algorithm>
#include <vector>

// Sugiyama layered layout for the flowchart family (flowchart, state, class,
// flow fences), in four passes:
//
//   1. RANK. A DFS sweep marks back edges (so cycles are safe), then a
//      longest-path relaxation over the remaining edges gives every node the
//      smallest rank its predecessors allow. `LR` ranks are columns, `TD`
//      ranks are rows; `RL`/`BT` mirror the finished coordinates.
//   2. LAYER. Every edge spanning more than one rank is split into a chain of
//      routing DUMMIES, one per intermediate rank. That is what keeps a long
//      edge from being drawn straight through the boxes of the ranks it skips,
//      and it lets the ordering pass see the edge as a rank-local one.
//   3. ORDER. Median/barycenter sweeps over the layers, keeping the ordering
//      with the fewest inter-layer crossings seen. Every tie breaks on the
//      cell's current order, so the result is a pure function of the input.
//   4. POSITION. Alternating sweeps of an exact WEIGHTED ISOTONIC REGRESSION
//      per layer: each cell wants the median of its neighbours on the adjacent
//      layer, and PAVA finds the closest assignment that still respects the
//      layer's order and its minimum separation. Dummies carry a large weight,
//      so long edges come out straight; a fan-out ends up centered on its
//      source, and a chain comes out as one straight line. Because separation
//      is a hard constraint of the regression, node overlap is impossible by
//      construction.
//
// Every loop nest checks the wall-clock deadline and bails with NO.

static const NSUInteger kSPDFDiagramMaximumCells = 1600;  // real nodes + routing dummies
static const NSUInteger kSPDFDiagramOrderSweeps = 8;
static const NSUInteger kSPDFDiagramPositionSweeps = 8;

static BOOL SPDFDeadlinePassed(CFAbsoluteTime deadline) {
    return CFAbsoluteTimeGetCurrent() > deadline;
}

namespace {

// One box in the layered structure: a real node, or a routing dummy standing
// in for one rank crossed by a long edge.
struct SPDFLayoutCell {
    NSInteger rank = 0;
    NSInteger order = 0;
    CGFloat cross = 0;    // extent along the cross axis
    CGFloat center = 0;   // cross-axis center
    CGFloat weight = 1;   // position-pass weight (dummies pull hardest)
    NSInteger node = -1;  // index into graph.nodes; -1 for a dummy
};

struct SPDFLayered {
    std::vector<SPDFLayoutCell> cells;
    std::vector<std::vector<NSUInteger>> up;     // neighbour cells one rank lower
    std::vector<std::vector<NSUInteger>> down;   // neighbour cells one rank higher
    std::vector<std::vector<NSUInteger>> ranks;  // cell indexes per rank, in order
};

}  // namespace

// Iterative DFS marking every edge that closes a cycle. Those edges take no
// part in ranking, so a cyclic graph still gets a finite layering.
static BOOL SPDFFindBackEdges(NSUInteger count, const std::vector<std::vector<NSUInteger>>& outgoing,
                              const std::vector<NSInteger>& edgeTarget, std::vector<bool>& backEdges,
                              CFAbsoluteTime deadline) {
    std::vector<uint8_t> colors(count, 0);  // 0 white, 1 gray (on stack), 2 black
    std::vector<NSUInteger> stack, cursors;
    for (NSUInteger root = 0; root < count; ++root) {
        if (colors[root] != 0) continue;
        stack.clear();
        cursors.clear();
        stack.push_back(root);
        cursors.push_back(0);
        colors[root] = 1;
        while (!stack.empty()) {
            if (SPDFDeadlinePassed(deadline)) return NO;
            NSUInteger node = stack.back();
            NSUInteger cursor = cursors.back();
            if (cursor >= outgoing[node].size()) {
                colors[node] = 2;
                stack.pop_back();
                cursors.pop_back();
                continue;
            }
            cursors.back() = cursor + 1;
            NSUInteger edgeIndex = outgoing[node][cursor];
            NSInteger target = edgeTarget[edgeIndex];
            if (target < 0) continue;
            if (colors[(NSUInteger)target] == 1) {
                backEdges[edgeIndex] = true;
            } else if (colors[(NSUInteger)target] == 0) {
                colors[(NSUInteger)target] = 1;
                stack.push_back((NSUInteger)target);
                cursors.push_back(0);
            }
        }
    }
    return YES;
}

// Crossings between two adjacent layers under the current ordering, by the
// Barth-Junger-Mutzel accumulator tree: O(E log V) rather than the quadratic
// pair count, which matters because a graph at the 400-edge budget can put
// hundreds of edges between one pair of layers.
static NSUInteger SPDFCountCrossings(const SPDFLayered& layered, NSUInteger rank) {
    if (rank + 1 >= layered.ranks.size()) return 0;
    size_t southern = layered.ranks[rank + 1].size();
    if (!southern) return 0;
    // Edges as southern orders, listed in northern order: within one northern
    // cell they are sorted, so the sequence is exactly the tree's input.
    std::vector<NSInteger> southOrders;
    for (NSUInteger cell : layered.ranks[rank]) {
        std::vector<NSInteger> targets;
        targets.reserve(layered.down[cell].size());
        for (NSUInteger other : layered.down[cell]) targets.push_back(layered.cells[other].order);
        std::sort(targets.begin(), targets.end());
        southOrders.insert(southOrders.end(), targets.begin(), targets.end());
    }
    size_t leaves = 1;
    while (leaves < southern) leaves *= 2;
    std::vector<NSUInteger> tree(2 * leaves - 1, 0);
    size_t firstLeaf = leaves - 1;
    NSUInteger crossings = 0;
    for (NSInteger south : southOrders) {
        size_t index = firstLeaf + (size_t)south;
        ++tree[index];
        while (index > 0) {
            if (index % 2) crossings += tree[index + 1];  // the right sibling's subtree
            index = (index - 1) / 2;
            ++tree[index];
        }
    }
    return crossings;
}

static NSUInteger SPDFTotalCrossings(const SPDFLayered& layered) {
    NSUInteger total = 0;
    for (NSUInteger rank = 0; rank + 1 < layered.ranks.size(); ++rank) total += SPDFCountCrossings(layered, rank);
    return total;
}

// The median of a cell's neighbour ORDERS on the adjacent layer, or -1 when it
// has none (such a cell keeps its place).
static double SPDFMedianOrder(const SPDFLayered& layered, const std::vector<NSUInteger>& neighbors) {
    if (neighbors.empty()) return -1;
    std::vector<NSInteger> orders;
    orders.reserve(neighbors.size());
    for (NSUInteger neighbor : neighbors) orders.push_back(layered.cells[neighbor].order);
    std::sort(orders.begin(), orders.end());
    size_t middle = orders.size() / 2;
    if (orders.size() % 2) return (double)orders[middle];
    return ((double)orders[middle - 1] + (double)orders[middle]) / 2;
}

static void SPDFReindexRank(SPDFLayered& layered, NSUInteger rank) {
    for (NSUInteger order = 0; order < layered.ranks[rank].size(); ++order)
        layered.cells[layered.ranks[rank][order]].order = (NSInteger)order;
}

// Weighted isotonic regression by pool-adjacent-violators: the closest
// non-decreasing sequence to `desired`. Used to place one layer as near as
// possible to where its neighbours want it while keeping order and gaps.
static void SPDFIsotonic(std::vector<double>& desired, const std::vector<double>& weights) {
    size_t count = desired.size();
    if (count < 2) return;
    std::vector<double> value(count), mass(count);
    std::vector<size_t> width(count);
    size_t blocks = 0;
    for (size_t index = 0; index < count; ++index) {
        value[blocks] = desired[index];
        mass[blocks] = weights[index];
        width[blocks] = 1;
        while (blocks > 0 && value[blocks - 1] > value[blocks]) {
            double total = mass[blocks - 1] + mass[blocks];
            value[blocks - 1] = (value[blocks - 1] * mass[blocks - 1] + value[blocks] * mass[blocks]) / total;
            mass[blocks - 1] = total;
            width[blocks - 1] += width[blocks];
            --blocks;
        }
        ++blocks;
    }
    size_t cursor = 0;
    for (size_t block = 0; block < blocks && cursor < count; ++block)
        for (size_t step = 0; step < width[block] && cursor < count; ++step) desired[cursor++] = value[block];
}

// One position sweep over a layer: pull every cell toward the median of its
// neighbours on `neighbors`, then project back onto the feasible set (the
// layer's order plus `gap` of clear air between boxes).
static void SPDFPositionRank(SPDFLayered& layered, NSUInteger rank, BOOL downward, CGFloat gap) {
    const std::vector<NSUInteger>& row = layered.ranks[rank];
    size_t count = row.size();
    if (!count) return;
    std::vector<double> offset(count), desired(count), weights(count);
    double running = 0;
    for (size_t index = 0; index < count; ++index) {
        const SPDFLayoutCell& cell = layered.cells[row[index]];
        running += (index ? gap + cell.cross / 2 : cell.cross / 2);
        offset[index] = running;
        running += cell.cross / 2;
        const std::vector<NSUInteger>& neighbors = downward ? layered.up[row[index]] : layered.down[row[index]];
        double sum = 0;
        for (NSUInteger neighbor : neighbors) sum += layered.cells[neighbor].center;
        double target = neighbors.empty() ? cell.center : sum / (double)neighbors.size();
        desired[index] = target - offset[index];
        weights[index] = cell.weight;
    }
    SPDFIsotonic(desired, weights);
    for (size_t index = 0; index < count; ++index)
        layered.cells[row[index]].center = desired[index] + offset[index];
}

// Slides a layer bodily so the whole drawing keeps one common origin; the
// regression only ever fixes RELATIVE places, never the absolute one.
static void SPDFNormalizeCross(SPDFLayered& layered, CGFloat* outExtent) {
    double lowest = 0, highest = 0;
    BOOL seen = NO;
    for (const SPDFLayoutCell& cell : layered.cells) {
        double low = cell.center - cell.cross / 2;
        double high = cell.center + cell.cross / 2;
        if (!seen || low < lowest) lowest = low;
        if (!seen || high > highest) highest = high;
        seen = YES;
    }
    for (SPDFLayoutCell& cell : layered.cells) cell.center -= lowest;
    if (outExtent) *outExtent = seen ? (CGFloat)(highest - lowest) : 0;
}

BOOL SPDFMarkdownDiagramLayoutGraph(SPDFMarkdownDiagramGraph* graph, CGFloat nodeGap, CGFloat rankGap,
                                    CFAbsoluteTime deadline, NSSize* outSize) {
    NSArray<SPDFMarkdownDiagramNode*>* nodes = graph.nodes;
    NSArray<SPDFMarkdownDiagramEdge*>* edges = graph.edges;
    NSUInteger count = nodes.count;
    if (!count) return NO;
    NSMutableDictionary<NSString*, NSNumber*>* indexes = [NSMutableDictionary dictionaryWithCapacity:count];
    for (NSUInteger index = 0; index < count; ++index) indexes[nodes[index].identifier] = @(index);

    // --- 1. Rank -----------------------------------------------------------
    NSUInteger edgeCount = edges.count;
    std::vector<NSInteger> edgeSource(edgeCount, -1), edgeTarget(edgeCount, -1);
    std::vector<std::vector<NSUInteger>> outgoing(count);
    for (NSUInteger index = 0; index < edgeCount; ++index) {
        NSNumber* from = indexes[edges[index].fromIdentifier];
        NSNumber* to = indexes[edges[index].toIdentifier];
        edgeSource[index] = from ? (NSInteger)from.unsignedIntegerValue : -1;
        edgeTarget[index] = to ? (NSInteger)to.unsignedIntegerValue : -1;
        if (from) outgoing[from.unsignedIntegerValue].push_back(index);
    }
    std::vector<bool> backEdges(edgeCount, false);
    if (!SPDFFindBackEdges(count, outgoing, edgeTarget, backEdges, deadline)) return NO;

    std::vector<NSInteger> rankOf(count, 0);
    for (NSUInteger pass = 0; pass < count; ++pass) {
        if (SPDFDeadlinePassed(deadline)) return NO;
        BOOL changed = NO;
        for (NSUInteger index = 0; index < edgeCount; ++index) {
            if (backEdges[index] || edgeSource[index] < 0 || edgeTarget[index] < 0) continue;
            if (edgeSource[index] == edgeTarget[index]) continue;
            NSInteger wanted = rankOf[(NSUInteger)edgeSource[index]] + 1;
            if (rankOf[(NSUInteger)edgeTarget[index]] < wanted) {
                rankOf[(NSUInteger)edgeTarget[index]] = wanted;
                changed = YES;
            }
        }
        if (!changed) break;
    }
    NSInteger maximumRank = 0;
    for (NSUInteger index = 0; index < count; ++index) maximumRank = MAX(maximumRank, rankOf[index]);

    // --- 2. Layer, with a routing dummy per rank a long edge crosses -------
    SPDFLayered layered;
    layered.ranks.resize((size_t)maximumRank + 1);
    layered.cells.reserve(count);
    for (NSUInteger index = 0; index < count; ++index) {
        SPDFLayoutCell cell;
        cell.rank = rankOf[index];
        cell.node = (NSInteger)index;
        NSSize size = nodes[index].frame.size;
        cell.cross = graph.vertical ? size.width : size.height;
        layered.cells.push_back(cell);
        layered.ranks[(size_t)cell.rank].push_back(index);
    }
    // Dummy chains, in edge order: the layout is a pure function of the source.
    CGFloat dummyCross = MAX(1, nodeGap / 6);
    std::vector<std::vector<NSUInteger>> chains(edgeCount);
    for (NSUInteger index = 0; index < edgeCount; ++index) {
        if (SPDFDeadlinePassed(deadline)) return NO;
        if (edgeSource[index] < 0 || edgeTarget[index] < 0) continue;
        NSInteger from = rankOf[(NSUInteger)edgeSource[index]];
        NSInteger to = rankOf[(NSUInteger)edgeTarget[index]];
        NSInteger step = to > from ? 1 : -1;
        if (labs(to - from) < 2) continue;
        if (layered.cells.size() + (size_t)labs(to - from) > kSPDFDiagramMaximumCells) continue;
        for (NSInteger rank = from + step; rank != to; rank += step) {
            SPDFLayoutCell cell;
            cell.rank = rank;
            cell.cross = dummyCross;
            cell.weight = 24;  // a long edge should come out straight
            chains[index].push_back(layered.cells.size());
            layered.ranks[(size_t)rank].push_back(layered.cells.size());
            layered.cells.push_back(cell);
        }
    }
    size_t cellCount = layered.cells.size();
    layered.up.resize(cellCount);
    layered.down.resize(cellCount);
    // Adjacency runs along each edge's full chain: source -> dummies -> target.
    for (NSUInteger index = 0; index < edgeCount; ++index) {
        if (edgeSource[index] < 0 || edgeTarget[index] < 0) continue;
        if (edgeSource[index] == edgeTarget[index]) continue;
        std::vector<NSUInteger> path;
        path.push_back((NSUInteger)edgeSource[index]);
        for (NSUInteger dummy : chains[index]) path.push_back(dummy);
        path.push_back((NSUInteger)edgeTarget[index]);
        for (size_t step = 0; step + 1 < path.size(); ++step) {
            NSUInteger a = path[step], b = path[step + 1];
            NSUInteger lower = layered.cells[a].rank <= layered.cells[b].rank ? a : b;
            NSUInteger upper = lower == a ? b : a;
            if (layered.cells[lower].rank == layered.cells[upper].rank) continue;
            layered.down[lower].push_back(upper);
            layered.up[upper].push_back(lower);
        }
    }
    for (size_t rank = 0; rank < layered.ranks.size(); ++rank) SPDFReindexRank(layered, (NSUInteger)rank);
    // A real node's pull scales with how many chains it must satisfy, so a hub
    // wins its place over a leaf; a leaf then settles around it.
    for (size_t index = 0; index < cellCount; ++index)
        if (layered.cells[index].node >= 0)
            layered.cells[index].weight =
                1 + (CGFloat)(layered.up[index].size() + layered.down[index].size()) / 4;

    // --- 3. Order ----------------------------------------------------------
    std::vector<NSInteger> bestOrders(cellCount);
    for (size_t index = 0; index < cellCount; ++index) bestOrders[index] = layered.cells[index].order;
    NSUInteger bestCrossings = SPDFTotalCrossings(layered);
    for (NSUInteger sweep = 0; sweep < kSPDFDiagramOrderSweeps && bestCrossings; ++sweep) {
        BOOL downward = (sweep % 2) == 0;
        for (NSInteger step = 0; step <= maximumRank; ++step) {
            if (SPDFDeadlinePassed(deadline)) return NO;
            NSUInteger rank = (NSUInteger)(downward ? step : maximumRank - step);
            std::vector<NSUInteger>& row = layered.ranks[rank];
            if (row.size() < 2) continue;
            std::vector<double> keys(row.size());
            for (size_t index = 0; index < row.size(); ++index) {
                double median = SPDFMedianOrder(layered, downward ? layered.up[row[index]]
                                                                  : layered.down[row[index]]);
                keys[index] = median < 0 ? (double)layered.cells[row[index]].order : median;
            }
            std::vector<size_t> permutation(row.size());
            for (size_t index = 0; index < row.size(); ++index) permutation[index] = index;
            std::stable_sort(permutation.begin(), permutation.end(),
                             [&keys](size_t a, size_t b) { return keys[a] < keys[b]; });
            std::vector<NSUInteger> reordered(row.size());
            for (size_t index = 0; index < row.size(); ++index) reordered[index] = row[permutation[index]];
            row = reordered;
            SPDFReindexRank(layered, rank);
        }
        NSUInteger crossings = SPDFTotalCrossings(layered);
        if (crossings < bestCrossings) {
            bestCrossings = crossings;
            for (size_t index = 0; index < cellCount; ++index) bestOrders[index] = layered.cells[index].order;
        }
    }
    for (size_t rank = 0; rank < layered.ranks.size(); ++rank) {
        std::vector<NSUInteger>& row = layered.ranks[rank];
        std::stable_sort(row.begin(), row.end(),
                         [&bestOrders](NSUInteger a, NSUInteger b) { return bestOrders[a] < bestOrders[b]; });
        SPDFReindexRank(layered, (NSUInteger)rank);
    }

    // --- 4. Position -------------------------------------------------------
    for (size_t rank = 0; rank < layered.ranks.size(); ++rank) {
        CGFloat running = 0;
        for (NSUInteger cellIndex : layered.ranks[rank]) {
            SPDFLayoutCell& cell = layered.cells[cellIndex];
            cell.center = running + cell.cross / 2;
            running += cell.cross + nodeGap;
        }
    }
    for (NSUInteger sweep = 0; sweep < kSPDFDiagramPositionSweeps; ++sweep) {
        BOOL downward = (sweep % 2) == 0;
        for (NSInteger step = 0; step <= maximumRank; ++step) {
            if (SPDFDeadlinePassed(deadline)) return NO;
            NSUInteger rank = (NSUInteger)(downward ? step : maximumRank - step);
            SPDFPositionRank(layered, rank, downward, nodeGap);
        }
    }
    CGFloat totalCross = 0;
    SPDFNormalizeCross(layered, &totalCross);

    // Main-axis bands: one per rank, as deep as its deepest node, separated by
    // `rankGap` (widened when any edge carries a label chip to sit in).
    BOOL labeledEdges = NO;
    for (SPDFMarkdownDiagramEdge* edge in edges)
        if (edge.label.length) labeledEdges = YES;
    CGFloat effectiveRankGap = rankGap + (labeledEdges ? 18 : 0);
    std::vector<CGFloat> rankOrigin(layered.ranks.size(), 0), rankDepth(layered.ranks.size(), 0);
    CGFloat mainOffset = 0;
    for (size_t rank = 0; rank < layered.ranks.size(); ++rank) {
        CGFloat depth = 0;
        for (NSUInteger cellIndex : layered.ranks[rank]) {
            NSInteger node = layered.cells[cellIndex].node;
            if (node < 0) continue;
            NSSize size = nodes[(NSUInteger)node].frame.size;
            depth = MAX(depth, graph.vertical ? size.height : size.width);
        }
        rankOrigin[rank] = mainOffset;
        rankDepth[rank] = depth;
        mainOffset += depth + effectiveRankGap;
    }
    CGFloat mainExtent = MAX(0, mainOffset - effectiveRankGap);
    NSSize contentSize = graph.vertical ? NSMakeSize(totalCross, mainExtent) : NSMakeSize(mainExtent, totalCross);

    for (size_t index = 0; index < cellCount; ++index) {
        SPDFLayoutCell& cell = layered.cells[index];
        CGFloat band = rankOrigin[(size_t)cell.rank];
        CGFloat depth = rankDepth[(size_t)cell.rank];
        if (cell.node < 0) continue;  // a dummy contributes a route point, not a box
        SPDFMarkdownDiagramNode* node = nodes[(NSUInteger)cell.node];
        NSSize size = node.frame.size;
        CGFloat main = band + (depth - (graph.vertical ? size.height : size.width)) / 2;
        CGFloat cross = cell.center - (graph.vertical ? size.width : size.height) / 2;
        node.rank = cell.rank;
        node.order = cell.order;
        node.frame = graph.vertical ? NSMakeRect(cross, main, size.width, size.height)
                                    : NSMakeRect(main, cross, size.width, size.height);
    }

    // Route points: the center of each dummy the edge passes through, in the
    // finished coordinate space. The emitter turns them into a smooth curve.
    for (NSUInteger index = 0; index < edgeCount; ++index) {
        if (chains[index].empty()) {
            edges[index].routePoints = nil;
            continue;
        }
        NSMutableArray<NSValue*>* points = [NSMutableArray arrayWithCapacity:chains[index].size()];
        for (NSUInteger cellIndex : chains[index]) {
            const SPDFLayoutCell& cell = layered.cells[cellIndex];
            CGFloat main = rankOrigin[(size_t)cell.rank] + rankDepth[(size_t)cell.rank] / 2;
            NSPoint point = graph.vertical ? NSMakePoint(cell.center, main) : NSMakePoint(main, cell.center);
            [points addObject:[NSValue valueWithPoint:point]];
        }
        edges[index].routePoints = points;
    }

    // BT / RL simply mirror the finished coordinates along the flow axis.
    if (graph.reversed) {
        for (SPDFMarkdownDiagramNode* node in nodes) {
            NSRect frame = node.frame;
            if (graph.vertical) frame.origin.y = contentSize.height - NSMaxY(frame);
            else frame.origin.x = contentSize.width - NSMaxX(frame);
            node.frame = frame;
        }
        for (SPDFMarkdownDiagramEdge* edge in edges) {
            if (!edge.routePoints.count) continue;
            NSMutableArray<NSValue*>* mirrored = [NSMutableArray arrayWithCapacity:edge.routePoints.count];
            for (NSValue* value in edge.routePoints) {
                NSPoint point = value.pointValue;
                if (graph.vertical) point.y = contentSize.height - point.y;
                else point.x = contentSize.width - point.x;
                [mirrored addObject:[NSValue valueWithPoint:point]];
            }
            edge.routePoints = mirrored;
        }
    }
    if (outSize) *outSize = contentSize;
    return YES;
}
