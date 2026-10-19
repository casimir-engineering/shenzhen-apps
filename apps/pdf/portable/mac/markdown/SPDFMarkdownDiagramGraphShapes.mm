#import "SPDFMarkdownDiagramInternal.h"

// Vector emitter for the flowchart-family graphs (flowchart, state, class,
// flow fences). Measures node sizes with the scaled body font, runs the
// layered layout under its deadline (reflowing labels narrower when the page
// box would otherwise shrink the drawing below the legibility floor), then emits
// the node shapes. Edge geometry is its own concern: see
// SPDFMarkdownDiagramGraphEdges.mm.

static const CGFloat kSPDFDiagramGraphMargin = 20;
static const CGFloat kSPDFDiagramLabelMaxWidth = 170;
// Narrower label wraps the emitter is allowed to fall back to when the page box
// would otherwise shrink the drawing below the legibility floor. Tightening the
// wrap trades WIDTH for HEIGHT (a node's text takes more lines), which is
// exactly the trade a wide flowchart needs on a portrait page. Ordered
// widest-first, and the first entry is the ordinary wrap, so a diagram that
// already fits costs nothing and comes out byte for byte as it did before.
static const CGFloat kSPDFDiagramLabelWrapLadder[] = {kSPDFDiagramLabelMaxWidth, 130, 100, 76};
static const CGFloat kSPDFDiagramNodePaddingX = 13;
static const CGFloat kSPDFDiagramNodePaddingY = 8;
static const CGFloat kSPDFDiagramClassGutter = 4;
static const CGFloat kSPDFDiagramSlant = 10;   // parallelogram side slant
static const CGFloat kSPDFDiagramRound = 8;    // rounded-rectangle corner radius
// Clear air demanded between the text block's extreme corners and a CURVED
// outline. A curve only pinches in near those corners, so this is deliberately
// smaller than the flat padding: at mid-height a stadium keeps the full
// kSPDFDiagramNodePaddingX. It must stay below kSPDFDiagramNodePaddingY, or a
// block's corner would sit outside the cap arc's own vertical extent.
static const CGFloat kSPDFDiagramCurveAir = 4;

typedef struct {
    NSFont* label;
    NSFont* small;
    NSFont* bold;
} SPDFDiagramGraphFonts;

// A classDiagram box shows ONLY the compartments it has members for: a class
// with no attributes and no methods is a single named box, and a class with
// members on one side gets exactly one extra compartment. Empty strips are
// never drawn.
static NSArray<NSArray<NSString*>*>* SPDFDiagramClassCompartments(SPDFMarkdownDiagramNode* node) {
    NSMutableArray<NSArray<NSString*>*>* compartments = [NSMutableArray arrayWithCapacity:2];
    if (node.memberAttributes.count) [compartments addObject:node.memberAttributes];
    if (node.memberMethods.count) [compartments addObject:node.memberMethods];
    return compartments;
}

// The half-width the DRAWN outline of `shape` still offers `offset` above and
// below the node's center. This is the whole interior model in one function:
// SPDFDiagramBoxForBlock inverts it per shape to pick a box, and the emitter
// evaluates it to pick the width it wraps the label at, so sizing and drawing
// cannot disagree about where the outline is.
static CGFloat SPDFDiagramInteriorHalfWidth(SPDFMarkdownDiagramNodeShape shape, NSRect frame, CGFloat offset,
                                            CGFloat scale) {
    CGFloat halfWidth = NSWidth(frame) / 2;
    CGFloat halfHeight = NSHeight(frame) / 2;
    CGFloat dy = MIN(fabs(offset), halfHeight);
    switch (shape) {
        case SPDFMarkdownDiagramNodeShapeStadium:
        case SPDFMarkdownDiagramNodeShapeRound: {
            // One formula for both rounded rectangles: flat until the corner
            // arc starts, then the arc. Radius and clamp match what
            // SPDFDiagramAddNodeShape asks the canvas for.
            CGFloat radius = shape == SPDFMarkdownDiagramNodeShapeStadium ? halfHeight
                                                                         : kSPDFDiagramRound * scale;
            radius = MAX(0, MIN(radius, MIN(halfWidth, halfHeight)));
            CGFloat into = dy - (halfHeight - radius);
            if (into > 0) halfWidth -= radius - sqrt(MAX(0, radius * radius - into * into));
            break;
        }
        case SPDFMarkdownDiagramNodeShapeCircle:
            if (halfHeight > 0) halfWidth *= sqrt(MAX(0, 1 - (dy / halfHeight) * (dy / halfHeight)));
            break;
        case SPDFMarkdownDiagramNodeShapeDiamond:
            if (halfHeight > 0) halfWidth *= 1 - dy / halfHeight;
            break;
        case SPDFMarkdownDiagramNodeShapeParallelogram:
            halfWidth -= kSPDFDiagramSlant * scale;  // the slant costs the same at every height
            break;
        case SPDFMarkdownDiagramNodeShapeSubroutine:
            halfWidth -= 5 * scale;  // the two vertical bars
            break;
        default:
            break;  // a rectangle's interior is its frame
    }
    return MAX(0, halfWidth);
}

// The smallest box of `shape` whose SAFE INTERIOR holds `block` with clear air
// on every side.
//
// A rectangle's interior IS its frame less the padding, so rectangles keep
// exactly the size they always had. Every other outline takes back more than
// the padding, and -- this is the part the old sizing missed -- takes back MORE
// the taller the block is, because a cap, an ellipse or a taper pinches inward
// toward the block's first and last lines. Sizing tuned on one- and two-line
// labels was therefore fine until commit 3f0e19d4b's legibility reflow started
// producing four- and five-line ones, at which point the power-tree fixture's
// `VSYS 3.5-4.26 V` stadium printed its top line straight across both caps.
//
// Each case below states the containment condition it inverts, so the box is a
// solved constraint rather than a tuned fudge factor, and each one leaves at
// least `air` of clearance at the block's extreme lines. Minimums and the
// shape-normalizing clamps are applied once, at the end, so they can never
// re-break a constraint the switch just satisfied. Slack any of them leaves is
// not wasted: SPDFDiagramAddNode re-wraps the label into the interior the
// chosen box actually has.
static NSSize SPDFDiagramBoxForBlock(SPDFMarkdownDiagramNodeShape shape, NSSize block, CGFloat scale) {
    CGFloat padX = kSPDFDiagramNodePaddingX * scale;
    CGFloat padY = kSPDFDiagramNodePaddingY * scale;
    CGFloat air = kSPDFDiagramCurveAir * scale;
    // The flat interior every shape keeps: padding around the block.
    CGFloat width = block.width + 2 * padX;
    CGFloat height = block.height + 2 * padY;
    switch (shape) {
        case SPDFMarkdownDiagramNodeShapeStadium: {
            // Caps of radius R = H/2. At height |dy| off the center the outline
            // has come in by R - sqrt(R^2 - dy^2) on each side. The block's
            // extreme lines sit at |dy| = block.height / 2, and they need `air`
            // beyond that, so require the half-width there to cover
            // block.width / 2 + air.
            CGFloat radius = height / 2;
            CGFloat reach = block.height / 2 + air;  // < radius: air < padY by construction
            CGFloat pinch = radius - sqrt(MAX(0, radius * radius - reach * reach));
            width = MAX(width, block.width + 2 * air + 2 * pinch);
            break;
        }
        case SPDFMarkdownDiagramNodeShapeCircle:
            // A centered rect fits a circle exactly when its CORNER does, which
            // on a circle is just the rect's diagonal. The old `+ 6` keeps a
            // single-line circle the size it has always been.
            width = height = MAX(MAX(width, height) + 6 * scale,
                                 hypot(block.width + 2 * air, block.height + 2 * air));
            break;
        case SPDFMarkdownDiagramNodeShapeDiamond:
            // A rhombus holds a centered w-by-h rect exactly when
            // w/W + h/H <= 1 -- the usable width falls off LINEARLY toward the
            // top and bottom vertices, which makes this the worst case of the
            // family. Splitting the budget evenly between the axes gives each
            // one twice the block it has to clear.
            width = MAX(width, 2 * (block.width + 2 * air));
            height = MAX(height, 2 * (block.height + 2 * air));
            break;
        case SPDFMarkdownDiagramNodeShapeParallelogram:
            // The slant costs the same width at EVERY line, so the usable
            // column is just the overlap of the top and bottom edges. Keeping
            // the ordinary padding inside that column is the whole rule.
            width += 2 * kSPDFDiagramSlant * scale;
            break;
        case SPDFMarkdownDiagramNodeShapeRound:
            // The corner arc has a FIXED radius, so clearing it costs a
            // constant rather than something that grows with the line count:
            // keep the block's corner outside the arc's quadrant entirely.
            // Stated rather than assumed -- the ordinary padding already covers
            // it, so this max never fires.
            width = MAX(width, block.width + 2 * (kSPDFDiagramRound * scale + air));
            break;
        default:
            // Rectangles: the padding IS the interior. Subroutines too -- their
            // two bars sit 5 pt in, well inside the 13 pt of padding.
            break;
    }
    width = MAX(width, 34 * scale);
    height = MAX(height, 26 * scale);
    // A stadium narrower than it is tall would have its cap radius clamped to
    // W/2 by the canvas, invalidating the solve above; a circle must stay
    // square after the minimums.
    if (shape == SPDFMarkdownDiagramNodeShapeStadium) width = MAX(width, height);
    if (shape == SPDFMarkdownDiagramNodeShapeCircle) width = height = MAX(width, height);
    return NSMakeSize(ceil(width), ceil(height));
}

// Sizes one node's box for a given label wrap. Returns the width the node's own
// TEXT actually took, so the reflow search can tell whether a narrower wrap
// could still change anything (a cap at or above the widest text is a no-op).
static CGFloat SPDFDiagramMeasureNode(SPDFMarkdownDiagramNode* node, SPDFDiagramGraphFonts fonts, CGFloat scale,
                                      CGFloat labelWrap) {
    CGFloat maxWidth = labelWrap * scale;
    if (node.shape == SPDFMarkdownDiagramNodeShapeStartDot || node.shape == SPDFMarkdownDiagramNodeShapeEndDot) {
        CGFloat diameter = 14 * scale;
        node.frame = NSMakeRect(0, 0, diameter, diameter);
        return 0;
    }
    if (node.shape == SPDFMarkdownDiagramNodeShapeClassBox) {
        CGFloat width = SPDFMarkdownDiagramMeasureText(node.label, fonts.bold, maxWidth).width;
        CGFloat lineHeight = SPDFMarkdownDiagramLineHeight(fonts.small);
        NSArray<NSArray<NSString*>*>* compartments = SPDFDiagramClassCompartments(node);
        for (NSArray<NSString*>* members in compartments)
            for (NSString* member in members)
                width = MAX(width, SPDFMarkdownDiagramMeasureText(member, fonts.small, 320 * scale).width);
        CGFloat titleHeight = SPDFMarkdownDiagramMeasureText(node.label.length ? node.label : @"X", fonts.bold,
                                                             maxWidth)
                                  .height;
        CGFloat height = titleHeight + 2 * kSPDFDiagramNodePaddingY * scale;
        // Each PRESENT compartment adds its divider gutter above and below its
        // member lines; an absent one adds nothing at all.
        for (NSArray<NSString*>* members in compartments)
            height += 2 * kSPDFDiagramClassGutter * scale + members.count * lineHeight;
        node.frame = NSMakeRect(0, 0, ceil(width + 2 * kSPDFDiagramNodePaddingX * scale), ceil(height));
        return width;
    }
    NSSize text = SPDFMarkdownDiagramMeasureText(node.label.length ? node.label : @" ", fonts.label, maxWidth);
    node.labelBlock = text;
    NSSize box = SPDFDiagramBoxForBlock(node.shape, text, scale);
    node.frame = NSMakeRect(0, 0, box.width, box.height);
    return text.width;
}

static NSValue* SPDFPoint(CGFloat x, CGFloat y) { return [NSValue valueWithPoint:NSMakePoint(x, y)]; }

// Author `classDef` colors ride on the shape, not on its role: the layout stays
// theme-independent and each draw target resolves them for the variant it
// paints with (see SPDFMarkdownDiagramAuthorColor).
static void SPDFDiagramTintShape(SPDFMarkdownDiagramShape* shape, SPDFMarkdownDiagramNodeStyle* style) {
    if (!shape || !style) return;
    shape.authorFillColor = style.fillColor;
    shape.authorStrokeColor = style.strokeColor;
}

static SPDFMarkdownDiagramShape* SPDFDiagramAddNodeShape(SPDFMarkdownDiagramCanvas* canvas,
                                                         SPDFMarkdownDiagramNode* node, CGFloat scale) {
    NSRect frame = node.frame;
    BOOL accentDot = node.shape == SPDFMarkdownDiagramNodeShapeStartDot;
    SPDFMarkdownDiagramRole fill = accentDot ? SPDFMarkdownDiagramRoleSecondary
                                             : SPDFMarkdownDiagramRoleNodeFill;
    SPDFMarkdownDiagramRole stroke = SPDFMarkdownDiagramRoleNodeStroke;
    switch (node.shape) {
        case SPDFMarkdownDiagramNodeShapeRound:
            return [canvas addRect:frame radius:kSPDFDiagramRound * scale fill:fill stroke:stroke width:1];
        case SPDFMarkdownDiagramNodeShapeStadium:
            return [canvas addRect:frame radius:NSHeight(frame) / 2 fill:fill stroke:stroke width:1];
        case SPDFMarkdownDiagramNodeShapeCircle:
        case SPDFMarkdownDiagramNodeShapeStartDot:
        case SPDFMarkdownDiagramNodeShapeEndDot:
            return [canvas addEllipse:frame fill:fill stroke:stroke width:1];
        case SPDFMarkdownDiagramNodeShapeDiamond:
            return [canvas addPolygon:@[
                SPDFPoint(NSMidX(frame), NSMinY(frame)), SPDFPoint(NSMaxX(frame), NSMidY(frame)),
                SPDFPoint(NSMidX(frame), NSMaxY(frame)), SPDFPoint(NSMinX(frame), NSMidY(frame))
            ]
                                 fill:fill
                               stroke:stroke
                                width:1];
        case SPDFMarkdownDiagramNodeShapeParallelogram: {
            CGFloat slant = kSPDFDiagramSlant * scale;
            return [canvas addPolygon:@[
                SPDFPoint(NSMinX(frame) + slant, NSMinY(frame)), SPDFPoint(NSMaxX(frame), NSMinY(frame)),
                SPDFPoint(NSMaxX(frame) - slant, NSMaxY(frame)), SPDFPoint(NSMinX(frame), NSMaxY(frame))
            ]
                                 fill:fill
                               stroke:stroke
                                width:1];
        }
        case SPDFMarkdownDiagramNodeShapeRect:
        case SPDFMarkdownDiagramNodeShapeSubroutine:
        case SPDFMarkdownDiagramNodeShapeClassBox:
        default:
            return [canvas addRect:frame radius:0 fill:fill stroke:stroke width:1];
    }
}

static void SPDFDiagramAddClassBody(SPDFMarkdownDiagramCanvas* canvas, SPDFMarkdownDiagramNode* node,
                                    SPDFDiagramGraphFonts fonts, CGFloat scale) {
    NSRect frame = node.frame;
    CGFloat lineHeight = SPDFMarkdownDiagramLineHeight(fonts.small);
    CGFloat titleHeight =
        SPDFMarkdownDiagramMeasureText(node.label.length ? node.label : @"X", fonts.bold, NSWidth(frame)).height;
    CGFloat y = NSMinY(frame) + kSPDFDiagramNodePaddingY * scale;
    [canvas addText:node.label
             inRect:NSMakeRect(NSMinX(frame), y, NSWidth(frame), titleHeight)
               font:fonts.bold
               role:SPDFMarkdownDiagramRoleText
          alignment:NSTextAlignmentCenter];
    y += titleHeight + kSPDFDiagramNodePaddingY * scale;
    CGFloat textX = NSMinX(frame) + kSPDFDiagramNodePaddingX * scale;
    CGFloat textWidth = NSWidth(frame) - 2 * kSPDFDiagramNodePaddingX * scale;
    for (NSArray<NSString*>* members in SPDFDiagramClassCompartments(node)) {
        [canvas addLineFrom:NSMakePoint(NSMinX(frame), y)
                         to:NSMakePoint(NSMaxX(frame), y)
                     stroke:SPDFMarkdownDiagramRoleNodeStroke
                      width:1
                       dash:0];
        y += kSPDFDiagramClassGutter * scale;
        for (NSString* member in members) {
            [canvas addText:member
                     inRect:NSMakeRect(textX, y, textWidth, lineHeight)
                       font:fonts.small
                       role:SPDFMarkdownDiagramRoleText
                  alignment:NSTextAlignmentLeft];
            y += lineHeight;
        }
        y += kSPDFDiagramClassGutter * scale;
    }
}

static void SPDFDiagramAddNode(SPDFMarkdownDiagramCanvas* canvas, SPDFMarkdownDiagramNode* node,
                               SPDFMarkdownDiagramGraph* graph, SPDFDiagramGraphFonts fonts, CGFloat scale) {
    SPDFMarkdownDiagramNodeStyle* style = [graph styleForNode:node];
    SPDFDiagramTintShape(SPDFDiagramAddNodeShape(canvas, node, scale), style);
    NSRect frame = node.frame;
    if (node.shape == SPDFMarkdownDiagramNodeShapeEndDot) {
        [canvas addEllipse:NSInsetRect(frame, 3.5 * scale, 3.5 * scale)
                      fill:SPDFMarkdownDiagramRoleSecondary
                    stroke:SPDFMarkdownDiagramRoleNone
                     width:0];
        return;
    }
    if (node.shape == SPDFMarkdownDiagramNodeShapeStartDot) return;
    if (node.shape == SPDFMarkdownDiagramNodeShapeSubroutine) {
        CGFloat inset = 5 * scale;
        for (NSNumber* x in @[ @(NSMinX(frame) + inset), @(NSMaxX(frame) - inset) ]) {
            SPDFDiagramTintShape([canvas addLineFrom:NSMakePoint(x.doubleValue, NSMinY(frame))
                                                  to:NSMakePoint(x.doubleValue, NSMaxY(frame))
                                              stroke:SPDFMarkdownDiagramRoleNodeStroke
                                               width:1
                                                dash:0],
                                 style);
        }
    }
    if (node.shape == SPDFMarkdownDiagramNodeShapeClassBox) {
        SPDFDiagramAddClassBody(canvas, node, fonts, scale);
        return;
    }
    // The label re-wraps into the shape's SAFE INTERIOR, not into its bounding
    // rect -- which is what this used to do, and why a four-line stadium label
    // could be re-broken into three lines wide enough to cross both caps. The
    // interior is asked for its width at the block's own extreme lines, so a
    // tall block gets the pinched width and a short one the generous one.
    //
    // Two bounds make that safe. It can never be NARROWER than the block the
    // box was solved for, so the wrap can only shed lines, never add them; and
    // shedding lines only moves the extreme lines closer to the center, where
    // the outline is wider still. So the re-measured block below fits with at
    // least `air` to spare on every side.
    CGFloat air = kSPDFDiagramCurveAir * scale;
    CGFloat safe = 2 * (SPDFDiagramInteriorHalfWidth(node.shape, frame, node.labelBlock.height / 2 + air,
                                                     scale) -
                        air);
    safe = MAX(safe, node.labelBlock.width);
    NSSize drawn = SPDFMarkdownDiagramMeasureText(node.label, fonts.label, safe);
    NSRect block = NSMakeRect(NSMidX(frame) - safe / 2, NSMidY(frame) - drawn.height / 2, safe, drawn.height);
    NSArray<SPDFMarkdownDiagramLabel*>* labels = [canvas addText:node.label
                                                          inRect:block
                                                            font:fonts.label
                                                            role:SPDFMarkdownDiagramRoleText
                                                       alignment:NSTextAlignmentCenter];
    for (SPDFMarkdownDiagramLabel* label in labels) label.authorColor = style.textColor;
}

// One complete measure+layout attempt at a given label wrap. Leaves the node
// frames in CONTENT space (the diagram margin is folded in by the caller, once,
// for the attempt that actually wins) and reports the natural size the attempt
// would produce plus the widest text any node needed.
static BOOL SPDFDiagramLayOutAtWrap(SPDFMarkdownDiagramGraph* graph, SPDFDiagramGraphFonts fonts, CGFloat scale,
                                    CGFloat labelWrap, CFAbsoluteTime deadline, NSSize* outNatural,
                                    CGFloat* outWidestText) {
    CGFloat widest = 0;
    for (SPDFMarkdownDiagramNode* node in graph.nodes)
        widest = MAX(widest, SPDFDiagramMeasureNode(node, fonts, scale, labelWrap));
    if (outWidestText) *outWidestText = widest / (scale > 0 ? scale : 1);
    NSSize contentSize = NSZeroSize;
    if (!SPDFMarkdownDiagramLayoutGraph(graph, 34 * scale, 44 * scale, deadline, &contentSize)) return NO;
    CGFloat margin = kSPDFDiagramGraphMargin * scale;
    *outNatural = NSMakeSize(contentSize.width + 2 * margin, contentSize.height + 2 * margin);
    // A tighter wrap can only ever make a diagram TALLER, so an attempt that
    // walks off the per-axis dimension budget is discarded rather than allowed
    // to degrade a fence that a looser wrap renders perfectly well.
    return outNatural->width <= SPDFMarkdownDiagramMaximumDimension &&
           outNatural->height <= SPDFMarkdownDiagramMaximumDimension;
}

SPDFMarkdownDiagramLayout* SPDFMarkdownDiagramLayOutGraph(SPDFMarkdownDiagramGraph* graph, NSSize contentBox,
                                                          CGFloat fontScale, CFAbsoluteTime deadline) {
    CGFloat scale = fontScale > 0 ? fontScale : 1;
    SPDFDiagramGraphFonts fonts = {
        [NSFont systemFontOfSize:12 * scale],
        [NSFont systemFontOfSize:10.5 * scale],
        [NSFont systemFontOfSize:12 * scale weight:NSFontWeightSemibold],
    };
    // The fit the page box would impose, expressed as the label size it leaves:
    // the body font is 12 pt, so clearing the floor means fit >= 7/12.
    const CGFloat legibleFit = SPDFMarkdownDiagramLegibleLabelSize / 12.0;
    NSSize natural = NSZeroSize;
    CGFloat widestText = 0;
    if (!SPDFDiagramLayOutAtWrap(graph, fonts, scale, kSPDFDiagramLabelWrapLadder[0], deadline, &natural,
                                 &widestText))
        return nil;
    CGFloat bestWrap = kSPDFDiagramLabelWrapLadder[0];
    CGFloat bestFit = SPDFMarkdownDiagramBoxFit(natural, contentBox);
    CGFloat appliedWrap = bestWrap;
    // Reflow search. Only a diagram the box would squeeze under the floor pays
    // for it, and only wraps narrower than the widest label can change anything,
    // so the overwhelmingly common case is the single pass above. Ties keep the
    // earlier (wider-label) candidate, which makes the winner a pure function of
    // (source, box, fontScale) -- the diagram cache key.
    const NSUInteger ladderCount = sizeof(kSPDFDiagramLabelWrapLadder) / sizeof(CGFloat);
    for (NSUInteger index = 1; index < ladderCount && bestFit < legibleFit; ++index) {
        CGFloat wrap = kSPDFDiagramLabelWrapLadder[index];
        if (wrap >= widestText) continue;
        NSSize candidate = NSZeroSize;
        // The measure mutates every node's frame before it can fail, so once it
        // runs the graph carries THIS attempt's geometry, win or lose. Record
        // the wrap before the check so a rung that trips the deadline or the
        // dimension budget is re-laid-out at bestWrap below instead of leaving
        // its frames behind under an earlier attempt's `natural`.
        appliedWrap = wrap;
        // A candidate that trips the shared deadline (or the dimension budget)
        // ends the search; the best COMPLETED attempt stands, and attempt zero
        // is the ordinary layout, so the outcome is never worse than before.
        if (!SPDFDiagramLayOutAtWrap(graph, fonts, scale, wrap, deadline, &candidate, NULL)) break;
        CGFloat fit = SPDFMarkdownDiagramBoxFit(candidate, contentBox);
        if (fit <= bestFit + 0.0005) continue;
        bestFit = fit;
        bestWrap = wrap;
        natural = candidate;
    }
    // The frames on the graph belong to the LAST attempt, which is only the
    // winner when the search stopped on it. Reconciling them with `natural`
    // needs its OWN budget: the usual reason the search stopped is that the
    // shared deadline expired, and reusing it here failed instantly and dropped
    // the whole diagram -- trading a mis-fitted figure for no figure at all.
    // The winning wrap already completed once inside the search, so this pass is
    // bounded work, and a genuine failure still declines to nil.
    if (appliedWrap != bestWrap) {
        CFAbsoluteTime reflowDeadline = CFAbsoluteTimeGetCurrent() + SPDFMarkdownDiagramLayoutBudget();
        if (!SPDFDiagramLayOutAtWrap(graph, fonts, scale, bestWrap, reflowDeadline, &natural, NULL)) return nil;
    }

    // The margin used to be a drawing-time transform; with geometry as the
    // product it is folded into the node frames so every emitted point is
    // already in diagram-local space.
    CGFloat margin = kSPDFDiagramGraphMargin * scale;
    for (SPDFMarkdownDiagramNode* node in graph.nodes)
        node.frame = NSOffsetRect(node.frame, margin, margin);

    SPDFMarkdownDiagramCanvas* canvas = [SPDFMarkdownDiagramCanvas new];
    SPDFMarkdownDiagramEmitGraphEdges(canvas, graph, fonts.small, scale);
    for (SPDFMarkdownDiagramNode* node in graph.nodes) SPDFDiagramAddNode(canvas, node, graph, fonts, scale);
    return SPDFMarkdownDiagramFinishLayout(canvas, natural, contentBox);
}
