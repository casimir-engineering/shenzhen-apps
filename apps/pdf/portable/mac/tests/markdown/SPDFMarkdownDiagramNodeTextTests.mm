#import "SPDFMarkdownTestSupport.h"

#import "../../markdown/SPDFMarkdownDiagramInternal.h"

// A node's label has to fit inside the shape that is actually DRAWN, not
// inside its bounding rectangle. Those are the same thing only for a
// rectangle: a stadium's caps, an ellipse, a diamond's taper and a
// parallelogram's slant all take width back, and the curved ones take MORE of
// it the taller the text block is, because they pinch inward toward its first
// and last lines. Sizing tuned on one- and two-line labels was therefore fine
// until the legibility reflow ladder started producing four- and five-line
// ones, and the `VSYS 3.5-4.26 V = VBAT + 50 mV` stadium in
// fixtures/power-tree.md printed its top line straight across both caps.
//
// This suite re-derives each outline from scratch -- rounded rectangle,
// ellipse, rhombus, parallelogram -- and asserts that every text line the
// emitter placed is strictly inside it, with clear air. It deliberately does
// NOT call the emitter's own interior math, so a wrong formula cannot agree
// with itself.

static const CGFloat kSPDFTextClearance = 1.0;  // pt of air demanded on every side

// --- Outlines ------------------------------------------------------------------

static BOOL SPDFInsideRoundedRect(NSPoint point, NSRect frame, CGFloat radius) {
    radius = MAX(0, MIN(radius, MIN(NSWidth(frame), NSHeight(frame)) / 2));
    if (!NSPointInRect(point, frame)) return NO;
    CGFloat dx = fabs(point.x - NSMidX(frame)) - (NSWidth(frame) / 2 - radius);
    CGFloat dy = fabs(point.y - NSMidY(frame)) - (NSHeight(frame) / 2 - radius);
    if (dx <= 0 || dy <= 0) return YES;  // not in a corner quadrant
    return dx * dx + dy * dy <= radius * radius;
}

static BOOL SPDFInsideEllipse(NSPoint point, NSRect frame) {
    CGFloat a = NSWidth(frame) / 2, b = NSHeight(frame) / 2;
    if (a <= 0 || b <= 0) return NO;
    CGFloat dx = (point.x - NSMidX(frame)) / a, dy = (point.y - NSMidY(frame)) / b;
    return dx * dx + dy * dy <= 1;
}

static BOOL SPDFInsideDiamond(NSPoint point, NSRect frame) {
    CGFloat a = NSWidth(frame) / 2, b = NSHeight(frame) / 2;
    if (a <= 0 || b <= 0) return NO;
    return fabs(point.x - NSMidX(frame)) / a + fabs(point.y - NSMidY(frame)) / b <= 1;
}

// The emitter's parallelogram leans one way: its top edge starts `slant` in
// from the left, its bottom edge stops `slant` short of the right.
static BOOL SPDFInsideParallelogram(NSPoint point, NSRect frame, CGFloat slant) {
    if (!NSPointInRect(point, frame)) return NO;
    CGFloat t = NSHeight(frame) > 0 ? (point.y - NSMinY(frame)) / NSHeight(frame) : 0;
    return point.x >= NSMinX(frame) + slant * (1 - t) && point.x <= NSMaxX(frame) - slant * t;
}

static BOOL SPDFInsideNode(NSPoint point, SPDFMarkdownDiagramNode* node, CGFloat scale) {
    NSRect frame = node.frame;
    switch (node.shape) {
        case SPDFMarkdownDiagramNodeShapeStadium:
            return SPDFInsideRoundedRect(point, frame, NSHeight(frame) / 2);
        case SPDFMarkdownDiagramNodeShapeRound:
            return SPDFInsideRoundedRect(point, frame, 8 * scale);
        case SPDFMarkdownDiagramNodeShapeCircle:
        case SPDFMarkdownDiagramNodeShapeStartDot:
        case SPDFMarkdownDiagramNodeShapeEndDot:
            return SPDFInsideEllipse(point, frame);
        case SPDFMarkdownDiagramNodeShapeDiamond:
            return SPDFInsideDiamond(point, frame);
        case SPDFMarkdownDiagramNodeShapeParallelogram:
            return SPDFInsideParallelogram(point, frame, 10 * scale);
        case SPDFMarkdownDiagramNodeShapeSubroutine:
            return NSPointInRect(point, NSInsetRect(frame, 5 * scale, 0));  // inside the two bars
        default:
            return NSPointInRect(point, frame);
    }
}

// --- Where the lines land --------------------------------------------------------

// The width the emitter re-wraps a node's label at, re-derived here from the
// OUTLINES above rather than from the emitter's own interior helper: the
// interior's half-width at the measured block's extreme lines, less the air
// demanded there. Found by bisection on the independently written
// SPDFInsideNode, so a wrong formula in the emitter cannot agree with itself.
static CGFloat SPDFNodeSafeWidth(SPDFMarkdownDiagramNode* node, CGFloat scale) {
    NSRect frame = node.frame;
    CGFloat air = 4 * scale;
    CGFloat y = NSMidY(frame) + MIN(node.labelBlock.height / 2 + air, NSHeight(frame) / 2);
    CGFloat low = 0, high = NSWidth(frame) / 2;
    for (NSUInteger step = 0; step < 40; ++step) {
        CGFloat mid = (low + high) / 2;
        if (SPDFInsideNode(NSMakePoint(NSMidX(frame) + mid, y), node, scale) &&
            SPDFInsideNode(NSMakePoint(NSMidX(frame) - mid, y), node, scale))
            low = mid;
        else
            high = mid;
    }
    return MAX(2 * (low - air), node.labelBlock.width);
}

// Re-derived from the laid-out MODEL the way the emitter and the page band do
// it together: the label re-wraps into the safe interior above, the stack is
// centered on the node, and each line is centered on the node's axis at its own
// typographic width. Working from the model rather than from the finished
// layout keeps the check valid at any page box -- a layout is fit-scaled to its
// box, the model is not -- and SPDFExpectDerivationMatchesEmitter below pins
// the derivation to what the emitter really emitted.
static NSArray<NSValue*>* SPDFNodeLineInks(SPDFMarkdownDiagramNode* node, NSFont* font, CGFloat scale) {
    if (node.labelBlock.width <= 0 || !node.label.length) return @[];
    NSRect frame = node.frame;
    CGFloat lineHeight = SPDFMarkdownDiagramLineHeight(font);
    NSArray<NSString*>* lines = SPDFMarkdownDiagramWrapText(node.label, font, SPDFNodeSafeWidth(node, scale));
    CGFloat top = NSMidY(frame) - ceil(lines.count * lineHeight) / 2;
    NSMutableArray<NSValue*>* inks = [NSMutableArray array];
    NSUInteger index = 0;
    for (NSString* line in lines) {
        CGFloat width = [line sizeWithAttributes:@{NSFontAttributeName: font}].width;
        [inks addObject:[NSValue valueWithRect:NSMakeRect(NSMidX(frame) - width / 2, top + index * lineHeight,
                                                          width, lineHeight)]];
        ++index;
    }
    return inks;
}

// --- The properties --------------------------------------------------------------

// The safety argument for re-wrapping at draw time rests on the re-wrap only
// ever SHEDDING lines: a box was solved to hold the measured block, and fewer
// lines only pull the extreme ones closer to the middle, where every outline is
// wider. One extra line would push them the other way, past everything that was
// solved for -- so an extra line is the failure to watch for.
static void SPDFExpectRewrapOnlySheds(SPDFMarkdownDiagramGraph* graph, CGFloat scale, NSString* what) {
    NSFont* font = [NSFont systemFontOfSize:12 * scale];
    CGFloat lineHeight = SPDFMarkdownDiagramLineHeight(font);
    NSUInteger grew = 0;
    for (SPDFMarkdownDiagramNode* node in graph.nodes) {
        if (node.shape == SPDFMarkdownDiagramNodeShapeClassBox || node.labelBlock.width <= 0) continue;
        CGFloat safe = SPDFNodeSafeWidth(node, scale);
        NSArray<NSValue*>* inks = SPDFNodeLineInks(node, font, scale);
        if (ceil(inks.count * lineHeight) > node.labelBlock.height + 0.01) ++grew;
        for (NSValue* value in inks)
            if (NSWidth(value.rectValue) > safe + 0.01) ++grew;
    }
    SPDFExpect(grew == 0,
               [NSString stringWithFormat:@"%@ re-wraps every label into its interior without adding a line "
                                          @"(%lu grew)",
                                          what, (unsigned long)grew]);
}

static void SPDFExpectLabelsInsideShapes(SPDFMarkdownDiagramGraph* graph, CGFloat scale, NSString* what) {
    NSFont* font = [NSFont systemFontOfSize:12 * scale];
    NSUInteger checked = 0, escaped = 0;
    NSString* worst = nil;
    for (SPDFMarkdownDiagramNode* node in graph.nodes) {
        if (node.shape == SPDFMarkdownDiagramNodeShapeClassBox) continue;  // compartments, not one block
        for (NSValue* value in SPDFNodeLineInks(node, font, scale)) {
            ++checked;
            // Every corner of the ink, grown by the clearance, must be inside
            // the outline: four corners are what a convex shape needs.
            NSRect probe = NSInsetRect(value.rectValue, -kSPDFTextClearance, -kSPDFTextClearance);
            NSPoint corners[4] = {
                NSMakePoint(NSMinX(probe), NSMinY(probe)), NSMakePoint(NSMaxX(probe), NSMinY(probe)),
                NSMakePoint(NSMaxX(probe), NSMaxY(probe)), NSMakePoint(NSMinX(probe), NSMaxY(probe))};
            BOOL inside = YES;
            for (NSUInteger corner = 0; corner < 4; ++corner)
                if (!SPDFInsideNode(corners[corner], node, scale)) inside = NO;
            if (inside) continue;
            ++escaped;
            if (!worst) worst = [NSString stringWithFormat:@"a line of %@", node.identifier];
        }
    }
    SPDFExpect(checked > 0, [what stringByAppendingString:@" places node labels to check"]);
    SPDFExpect(escaped == 0,
               [NSString stringWithFormat:@"%@ keeps every one of its %lu label lines inside the drawn shape "
                                          @"(%lu escaped, first: %@)",
                                          what, (unsigned long)checked, (unsigned long)escaped,
                                          worst ?: @"none"]);
}

// The derivation above is only worth anything if it matches the real emitter.
// At a box big enough that nothing is fit-scaled, the two must agree exactly.
static void SPDFExpectDerivationMatchesEmitter(SPDFMarkdownDiagramGraph* graph,
                                               SPDFMarkdownDiagramLayout* layout, CGFloat scale) {
    NSFont* font = [NSFont systemFontOfSize:12 * scale];
    NSMutableArray<NSValue*>* derived = [NSMutableArray array];
    for (SPDFMarkdownDiagramNode* node in graph.nodes)
        for (NSValue* value in SPDFNodeLineInks(node, font, scale))
            [derived addObject:[NSValue valueWithPoint:NSMakePoint(NSMidX(value.rectValue),
                                                                   NSMidY(value.rectValue))]];
    NSMutableArray<NSValue*>* emitted = [NSMutableArray array];
    for (SPDFMarkdownDiagramLabel* label in layout.labels) {
        if (fabs(label.fontSize - font.pointSize) > 0.01 || label.semibold) continue;
        [emitted addObject:[NSValue valueWithPoint:NSMakePoint(NSMidX(label.frame), NSMidY(label.frame))]];
    }
    NSUInteger matched = 0;
    for (NSValue* one in derived)
        for (NSValue* two in emitted)
            if (fabs(one.pointValue.x - two.pointValue.x) < 0.01 &&
                fabs(one.pointValue.y - two.pointValue.y) < 0.01) {
                ++matched;
                break;
            }
    SPDFExpect(derived.count > 0 && matched == derived.count,
               [NSString stringWithFormat:@"the emitter places every node label line where the model says "
                                          @"(%lu of %lu)",
                                          (unsigned long)matched, (unsigned long)derived.count]);
}

// A rectangle's safe interior IS its frame, so a rectangle must come out byte
// for byte as it always did: the fix may not churn the fixture's ordinary
// boxes, or every flowchart in every document re-lays-out for nothing. Both
// halves of the pre-fix behaviour are re-derived here and demanded back -- the
// box (the measured block plus 13 pt of padding each side and 8 pt above and
// below, floored at 34 x 26) and the label placement (a re-wrap into the frame
// inset by 4 pt a side, which is exactly what the interior model now yields).
static void SPDFExpectRectanglesUnchanged(SPDFMarkdownDiagramGraph* graph, CGFloat scale, NSString* what) {
    NSUInteger checked = 0, churned = 0;
    for (SPDFMarkdownDiagramNode* node in graph.nodes) {
        if (node.shape != SPDFMarkdownDiagramNodeShapeRect) continue;
        NSSize block = node.labelBlock;
        ++checked;
        if (fabs(NSWidth(node.frame) - ceil(MAX(block.width + 26 * scale, 34 * scale))) > 0.01 ||
            fabs(NSHeight(node.frame) - ceil(MAX(block.height + 16 * scale, 26 * scale))) > 0.01 ||
            fabs(SPDFNodeSafeWidth(node, scale) - (NSWidth(node.frame) - 8 * scale)) > 0.01)
            ++churned;
    }
    SPDFExpect(checked > 0, [what stringByAppendingString:@" has rectangles to compare"]);
    SPDFExpect(churned == 0,
               [NSString stringWithFormat:@"%@ leaves all %lu of its rectangles byte-identical (%lu churned)",
                                          what, (unsigned long)checked, (unsigned long)churned]);
}

// --- Fixtures --------------------------------------------------------------------

static SPDFMarkdownDiagramGraph* SPDFTextLayOut(SPDFMarkdownDiagramGraph* graph, NSSize box, CGFloat scale,
                                                SPDFMarkdownDiagramLayout** outLayout) {
    if (!graph) return nil;
    SPDFMarkdownDiagramLayout* layout =
        SPDFMarkdownDiagramLayOutGraph(graph, box, scale,
                                       CFAbsoluteTimeGetCurrent() + SPDFMarkdownDiagramLayoutDeadline);
    if (outLayout) *outLayout = layout;
    return layout ? graph : nil;
}

static NSString* SPDFTextFixtureFence(void) {
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

static NSString* SPDFGalleryLabel(NSUInteger lines) {
    NSMutableString* label = [NSMutableString stringWithString:@"Wwwww mmmmm 1"];
    for (NSUInteger line = 1; line < lines; ++line)
        [label appendFormat:@"<br/>line %lu of text", (unsigned long)line];
    return label;
}

// Every mermaid node form, at a given line count, chained so the graph is
// valid. `[(...)]` (cylinder) and `{{...}}` (hexagon) are both drawn as
// stadiums, which is exactly why they belong here: they reach the stadium
// solve through a different door.
static SPDFMarkdownDiagramGraph* SPDFShapeGallery(NSUInteger lines) {
    NSString* label = SPDFGalleryLabel(lines);
    NSArray<NSString*>* forms = @[ @"n%lu[%@]", @"n%lu(%@)", @"n%lu([%@])", @"n%lu{%@}", @"n%lu((%@))",
                                   @"n%lu[[%@]]", @"n%lu[(%@)]", @"n%lu{{%@}}", @"n%lu[/%@/]" ];
    NSMutableString* source = [NSMutableString stringWithString:@"flowchart LR\n"];
    for (NSUInteger index = 0; index < forms.count; ++index)
        [source appendFormat:[@"  " stringByAppendingString:[forms[index] stringByAppendingString:@"\n"]],
                             (unsigned long)index, label];
    // Three short chains rather than one long one: the gallery stays a compact
    // 3x3 block, so five-line labels at a large font scale cannot walk the
    // whole drawing off the dimension budget and turn a containment failure
    // into a "did not lay out" one.
    for (NSUInteger index = 0; index + 1 < forms.count; ++index)
        if (index % 3 != 2)
            [source appendFormat:@"  n%lu --> n%lu\n", (unsigned long)index, (unsigned long)(index + 1)];
    return SPDFMarkdownDiagramParseMermaidFlowchart(source);
}

int main(void) {
    @autoreleasepool {
        // Every shape the flowchart family draws, at one through five lines --
        // the range the reflow ladder actually produces.
        for (NSUInteger lines = 1; lines <= 5; ++lines) {
            SPDFMarkdownDiagramLayout* layout = nil;
            SPDFMarkdownDiagramGraph* graph =
                SPDFTextLayOut(SPDFShapeGallery(lines), NSMakeSize(4096, 4096), 1.0, &layout);
            NSString* what = [NSString stringWithFormat:@"the %lu-line shape gallery", (unsigned long)lines];
            SPDFExpect(graph != nil, [what stringByAppendingString:@" lays out"]);
            if (!graph) continue;
            SPDFExpectRewrapOnlySheds(graph, 1.0, what);
            SPDFExpectLabelsInsideShapes(graph, 1.0, what);
            SPDFExpectRectanglesUnchanged(graph, 1.0, what);
            if (lines == 4) SPDFExpectDerivationMatchesEmitter(graph, layout, 1.0);
        }

        // The same at a larger font scale, where every padding and radius moves.
        SPDFMarkdownDiagramLayout* scaled = nil;
        SPDFMarkdownDiagramGraph* big = SPDFTextLayOut(SPDFShapeGallery(4), NSMakeSize(4096, 4096), 1.6,
                                                       &scaled);
        SPDFExpect(big != nil, @"the shape gallery lays out at a larger font scale");
        if (big) {
            SPDFExpectRewrapOnlySheds(big, 1.6, @"the scaled shape gallery");
            SPDFExpectLabelsInsideShapes(big, 1.6, @"the scaled shape gallery");
            SPDFExpectRectanglesUnchanged(big, 1.6, @"the scaled shape gallery");
            SPDFExpectDerivationMatchesEmitter(big, scaled, 1.6);
        }

        // The acceptance case: the real document, at page boxes that DO drive
        // the reflow ladder down its rungs (this is where the report came
        // from), and at one that does not.
        NSString* fence = SPDFTextFixtureFence();
        SPDFExpect(fence.length > 0, @"the power-tree fixture carries one mermaid fence");
        NSArray<NSValue*>* boxes = @[
            [NSValue valueWithSize:NSMakeSize(4096, 4096)],  // no reflow: the ordinary wrap
            [NSValue valueWithSize:NSMakeSize(473, 650)],    // A4 portrait
            [NSValue valueWithSize:NSMakeSize(719, 430)],    // A4 landscape
            [NSValue valueWithSize:NSMakeSize(440, 600)],    // the old image budget
        ];
        for (NSValue* value in boxes) {
            NSSize box = value.sizeValue;
            SPDFMarkdownDiagramGraph* graph =
                SPDFTextLayOut(SPDFMarkdownDiagramParseMermaidFlowchart(fence), box, 1.0, NULL);
            NSString* what = [NSString stringWithFormat:@"the power tree in a %.0f x %.0f box", box.width,
                                                        box.height];
            SPDFExpect(graph != nil, [what stringByAppendingString:@" lays out"]);
            if (!graph) continue;
            SPDFExpectRewrapOnlySheds(graph, 1.0, what);
            SPDFExpectLabelsInsideShapes(graph, 1.0, what);
            SPDFExpectRectanglesUnchanged(graph, 1.0, what);
        }
    }
    return SPDFFinishTests(@"SPDFMarkdownDiagramNodeTextTests");
}
