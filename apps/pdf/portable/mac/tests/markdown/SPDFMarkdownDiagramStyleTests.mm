#import "SPDFMarkdownTestSupport.h"

#import "../../markdown/SPDFMarkdownDiagram.h"
#import "../../markdown/SPDFMarkdownDocument.h"
#import "spdf_recolor.h"

// mermaid node STYLING and the label syntax that came with it: `classDef` +
// `:::name`, the `class a,b name` statement, `<br/>` hard line breaks, HTML
// entities, and the `<-->` bidirectional edge.
//
// The suite's acceptance fixture is a real user document
// (fixtures/power-tree.md) that fell back to a code box before this work: it
// carries 32 `:::` suffixes, 18 `<br/>` breaks, 4 `classDef` declarations, one
// `<-->` and one `&lt;`. It must RENDER, and every construct is also pinned in
// isolation so a regression names itself.
//
// The dark-theme color policy is asserted twice over: once against the core's
// own spdf_recolor LUMA_REMAP (the arithmetic must be the SAME, not merely
// similar) and once as the property that actually matters -- a pale authored
// fill goes dark, its dark authored text goes light, and the contrast the
// author built survives with its polarity flipped.

static const NSSize kSPDFStyleTestBox = {440, 0};
// Wider than the fixture's 1687 pt natural width, so no fit and no reflow.
static const NSSize kSPDFStyleNaturalBox = {4096, 0};

static SPDFMarkdownDiagramLayout* SPDFStyleRender(NSString* source) {
    return SPDFMarkdownDiagramRender(@"mermaid", source, kSPDFStyleTestBox, 1.0, nil);
}

static NSString* SPDFStyleFixtureMarkdown(void) {
    NSError* error = nil;
    NSString* markdown = [NSString stringWithContentsOfURL:SPDFFixtureURL(@"power-tree.md")
                                                 encoding:NSUTF8StringEncoding
                                                    error:&error];
    return markdown;
}

// The one ```mermaid fence in the fixture.
static NSString* SPDFStyleFixtureFence(NSString* markdown) {
    NSRange open = [markdown rangeOfString:@"```mermaid\n"];
    if (open.location == NSNotFound) return nil;
    NSRange rest = NSMakeRange(NSMaxRange(open), markdown.length - NSMaxRange(open));
    NSRange close = [markdown rangeOfString:@"\n```" options:0 range:rest];
    if (close.location == NSNotFound) return nil;
    return [markdown substringWithRange:NSMakeRange(rest.location, close.location - rest.location)];
}

static BOOL SPDFStyleHasLabel(SPDFMarkdownDiagramLayout* diagram, NSString* text) {
    for (SPDFMarkdownDiagramLabel* label in diagram.labels)
        if ([label.text isEqualToString:text]) return YES;
    return NO;
}

static NSUInteger SPDFStyleShapeCount(SPDFMarkdownDiagramLayout* diagram, SPDFMarkdownDiagramShapeKind kind) {
    NSUInteger count = 0;
    for (SPDFMarkdownDiagramShape* shape in diagram.shapes)
        if (shape.kind == kind) ++count;
    return count;
}

// The shape whose rect contains `point` (the node box behind a label).
static SPDFMarkdownDiagramShape* SPDFStyleBoxAround(SPDFMarkdownDiagramLayout* diagram, NSPoint point) {
    for (SPDFMarkdownDiagramShape* shape in diagram.shapes) {
        if (shape.kind != SPDFMarkdownDiagramShapeRectangle && shape.kind != SPDFMarkdownDiagramShapeEllipse)
            continue;
        if (NSPointInRect(point, shape.rect)) return shape;
    }
    return nil;
}

static SPDFMarkdownDiagramLabel* SPDFStyleLabel(SPDFMarkdownDiagramLayout* diagram, NSString* text) {
    for (SPDFMarkdownDiagramLabel* label in diagram.labels)
        if ([label.text isEqualToString:text]) return label;
    return nil;
}

// Rec.601 luma of a resolved color, 0..255, matching spdf_recolor's weights.
static CGFloat SPDFStyleLuma(NSColor* color) {
    NSColor* srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return 77 * srgb.redComponent * 255 / 256 + 150 * srgb.greenComponent * 255 / 256 +
           29 * srgb.blueComponent * 255 / 256;
}

static BOOL SPDFStyleColorsEqual(NSColor* a, NSColor* b) {
    NSColor* left = [a colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor* right = [b colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return fabs(left.redComponent - right.redComponent) < 0.002 &&
           fabs(left.greenComponent - right.greenComponent) < 0.002 &&
           fabs(left.blueComponent - right.blueComponent) < 0.002;
}

int main(void) {
    @autoreleasepool {
        // --- The acceptance fixture -------------------------------------
        NSString* markdown = SPDFStyleFixtureMarkdown();
        NSString* fence = SPDFStyleFixtureFence(markdown);
        SPDFExpect(fence.length > 0, @"the power-tree fixture is readable and holds a mermaid fence");
        SPDFExpect([fence containsString:@":::"] && [fence containsString:@"<br/>"] &&
                       [fence containsString:@"classDef"] && [fence containsString:@"<-->"] &&
                       [fence containsString:@"&lt;"],
                   @"the fixture still exercises every construct this suite covers");
        // The content assertions below are about the AUTHOR's label lines, so
        // they read the fixture at its natural size: a page box small enough to
        // trigger the legibility reflow deliberately re-wraps labels, which is
        // the subject of SPDFMarkdownDiagramFitTests, not of this suite.
        SPDFMarkdownDiagramLayout* real =
            SPDFMarkdownDiagramRender(@"mermaid", fence, kSPDFStyleNaturalBox, 1.0, nil);
        SPDFExpect(real != nil, @"the user's real power-tree flowchart renders as a diagram");
        SPDFMarkdownDiagramLayout* fitted = SPDFStyleRender(fence);
        SPDFExpect(fitted.size.width > 0 && fitted.size.width <= kSPDFStyleTestBox.width + 0.5 &&
                       fitted.size.height > 0 && fitted.size.height <= SPDFMarkdownDiagramMaximumDimension,
                   @"the power-tree diagram stays inside the width and dimension budgets");
        // Its `<br/>` breaks are honored: the two halves of a broken label are
        // separate lines, not one run joined by a space.
        SPDFExpect(SPDFStyleHasLabel(real, @"USB-C VBUS") && SPDFStyleHasLabel(real, @"5 V input"),
                   @"a <br/> in the fixture becomes two label lines");
        SPDFExpect(!SPDFStyleHasLabel(real, @"USB-C VBUS 5 V input"),
                   @"a <br/> is NOT flattened back into one line");
        // Its one HTML entity decodes.
        SPDFExpect(SPDFStyleHasLabel(real, @"R106 · FW lockout < 3.4 V"),
                   @"the fixture's &lt; entity decodes to a real < in the label text");
        // Its author colors reach the geometry.
        NSUInteger authored = 0;
        for (SPDFMarkdownDiagramShape* shape in real.shapes)
            if (shape.authorFillColor) ++authored;
        SPDFExpect(authored >= 30, @"the fixture's 32 :::-styled nodes carry author fills");

        // End to end through the document pipeline: the fence is a diagram
        // BAND, not a code box, and its labels are canonical searchable text.
        NSError* error = nil;
        SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] parseString:markdown
                                                                      sourceURL:nil
                                                                          error:&error];
        SPDFMarkdownRenderOptions* naturalOptions = SPDFMarkdownRenderOptions.defaultOptions;
        naturalOptions.pageContentSize = kSPDFStyleNaturalBox;  // author's own label lines, as above
        SPDFMarkdownDocument* document =
            model ? [[SPDFMarkdownDocument alloc] initWithModel:model options:naturalOptions] : nil;
        SPDFMarkdownRenderedBlock* fenceBlock = nil;
        for (SPDFMarkdownRenderedBlock* block in document.renderedDocument.renderedBlocks)
            if (block.diagramInfo) fenceBlock = block;
        SPDFExpect(fenceBlock != nil, @"the fixture's fence is recorded as a diagram block, not a code box");
        NSString* canonical = document.renderedDocument.attributedString.string;
        SPDFExpect([canonical containsString:@"BB-5 buck-boost"] &&
                       [canonical containsString:@"FW lockout < 3.4 V"],
                   @"the diagram's label text is real canonical (selectable, searchable) text");
        SPDFExpect(![canonical containsString:@"classDef aon fill:"],
                   @"the fence source is no longer emitted as code text");

        // --- classDef + ::: in isolation --------------------------------
        NSString* styled = @"flowchart LR\n"
                            "  classDef aon fill:#e1f5ee,stroke:#0f6e56,color:#04342c\n"
                            "  A[Rail]:::aon --> B[Load]\n";
        SPDFMarkdownDiagramLayout* classDiagram = SPDFStyleRender(styled);
        SPDFExpect(classDiagram != nil, @"a classDef + ::: flowchart renders");
        SPDFMarkdownDiagramLabel* railLabel = SPDFStyleLabel(classDiagram, @"Rail");
        SPDFMarkdownDiagramLabel* loadLabel = SPDFStyleLabel(classDiagram, @"Load");
        SPDFMarkdownDiagramShape* railBox =
            SPDFStyleBoxAround(classDiagram, NSMakePoint(NSMidX(railLabel.frame), NSMidY(railLabel.frame)));
        SPDFMarkdownDiagramShape* loadBox =
            SPDFStyleBoxAround(classDiagram, NSMakePoint(NSMidX(loadLabel.frame), NSMidY(loadLabel.frame)));
        SPDFExpect(railBox != nil && loadBox != nil, @"both nodes emit a box");
        NSColor* authoredFill = [NSColor colorWithSRGBRed:0xE1 / 255.0
                                                   green:0xF5 / 255.0
                                                    blue:0xEE / 255.0
                                                   alpha:1];
        SPDFExpect(SPDFStyleColorsEqual(railBox.authorFillColor, authoredFill),
                   @"the :::-styled node carries the classDef fill verbatim");
        SPDFExpect(railBox.authorStrokeColor != nil && railLabel.authorColor != nil,
                   @"the :::-styled node carries the classDef stroke and text color");
        // The UNSTYLED node is untouched: same roles, no author color at all.
        SPDFExpect(loadBox.authorFillColor == nil && loadBox.authorStrokeColor == nil &&
                       loadLabel.authorColor == nil,
                   @"a node with no class keeps today's theme roles exactly");
        SPDFExpect(SPDFStyleColorsEqual(
                       SPDFMarkdownDiagramShapeFillColor(loadBox, SPDFMarkdownThemeVariantLight),
                       SPDFMarkdownDiagramRoleColor(loadBox.fillRole, SPDFMarkdownThemeVariantLight)),
                   @"an unstyled node resolves to its role color unchanged");

        // Partial and unknown keys: stroke-width is dropped, not fatal, and a
        // classDef that only sets `fill` leaves the other two on the theme.
        SPDFMarkdownDiagramLayout* partial =
            SPDFStyleRender(@"flowchart LR\n"
                             "  classDef only fill:#123456,stroke-width:4px,font-weight:bold\n"
                             "  A[X]:::only\n");
        SPDFExpect(partial != nil, @"unknown classDef keys are ignored rather than failing the diagram");
        SPDFMarkdownDiagramLabel* xLabel = SPDFStyleLabel(partial, @"X");
        SPDFMarkdownDiagramShape* xBox =
            SPDFStyleBoxAround(partial, NSMakePoint(NSMidX(xLabel.frame), NSMidY(xLabel.frame)));
        SPDFExpect(xBox.authorFillColor != nil && xBox.authorStrokeColor == nil && xLabel.authorColor == nil,
                   @"a fill-only classDef styles only the fill");
        // `#rgb` shorthand and `classDef default` as the catch-all.
        SPDFMarkdownDiagramLayout* shorthand =
            SPDFStyleRender(@"flowchart LR\n  classDef default fill:#f9f\n  A[X] --> B[Y]\n");
        SPDFMarkdownDiagramLabel* shortLabel = SPDFStyleLabel(shorthand, @"Y");
        SPDFMarkdownDiagramShape* shortBox =
            SPDFStyleBoxAround(shorthand, NSMakePoint(NSMidX(shortLabel.frame), NSMidY(shortLabel.frame)));
        SPDFExpect(SPDFStyleColorsEqual(shortBox.authorFillColor,
                                        [NSColor colorWithSRGBRed:1 green:0x99 / 255.0 blue:1 alpha:1]),
                   @"`classDef default fill:#f9f` expands the shorthand and styles every node");

        // --- `class a,b name` statement ---------------------------------
        SPDFMarkdownDiagramLayout* assigned =
            SPDFStyleRender(@"flowchart TD\n"
                             "  classDef hot fill:#ffdddd\n"
                             "  A[One] --> B[Two]\n"
                             "  class A,B hot;\n");
        SPDFExpect(assigned != nil, @"a `class a,b name;` statement renders");
        NSUInteger tinted = 0;
        for (SPDFMarkdownDiagramShape* shape in assigned.shapes)
            if (shape.authorFillColor) ++tinted;
        SPDFExpect(tinted == 2, @"`class A,B hot` styles BOTH named nodes even though it follows them");

        // --- `<br/>` hard breaks and their sizing -----------------------
        SPDFMarkdownDiagramLayout* oneLine = SPDFStyleRender(@"flowchart LR\n  A[\"Alpha\"]\n");
        SPDFMarkdownDiagramLayout* twoLines = SPDFStyleRender(@"flowchart LR\n  A[\"Alpha<br/>Beta\"]\n");
        SPDFMarkdownDiagramLayout* threeForms =
            SPDFStyleRender(@"flowchart LR\n  A[\"One<br>Two<br />Three\"]\n");
        SPDFExpect(oneLine && twoLines && threeForms, @"<br>, <br/> and <br /> all parse");
        SPDFExpect(SPDFStyleHasLabel(twoLines, @"Alpha") && SPDFStyleHasLabel(twoLines, @"Beta") &&
                       twoLines.labels.count == 2,
                   @"a <br/> label becomes exactly two label lines");
        SPDFExpect(threeForms.labels.count == 3, @"all three <br> spellings break a line");
        SPDFMarkdownDiagramLabel* alpha = SPDFStyleLabel(twoLines, @"Alpha");
        SPDFMarkdownDiagramLabel* beta = SPDFStyleLabel(twoLines, @"Beta");
        SPDFExpect(NSMinY(beta.frame) >= NSMaxY(alpha.frame) - 0.5,
                   @"the second line is stacked below the first, in source order");
        SPDFExpect(fabs(NSMidX(alpha.frame) - NSMidX(beta.frame)) < 0.5,
                   @"both lines share a horizontal center, so each line is centered");
        // Sizing: the node grew by about one line, and both lines are INSIDE
        // the box (this is what a naive "just add a newline" would break).
        CGFloat lineHeight = NSHeight(alpha.frame);
        SPDFExpect(twoLines.size.height >= oneLine.size.height + lineHeight - 1,
                   @"a two-line label makes its node a line taller");
        SPDFMarkdownDiagramShape* twoLineBox =
            SPDFStyleBoxAround(twoLines, NSMakePoint(NSMidX(alpha.frame), NSMidY(alpha.frame)));
        SPDFExpect(twoLineBox != nil && NSMinY(twoLineBox.rect) <= NSMinY(alpha.frame) + 0.5 &&
                       NSMaxY(twoLineBox.rect) >= NSMaxY(beta.frame) - 0.5,
                   @"both label lines sit inside the node box that backs them");
        SPDFExpect(fabs(NSMidY(twoLineBox.rect) - (NSMinY(alpha.frame) + NSMaxY(beta.frame)) / 2) < 1.0,
                   @"the two-line stack is vertically centered on its node");

        // --- HTML entities ----------------------------------------------
        SPDFMarkdownDiagramLayout* entities =
            SPDFStyleRender(@"flowchart LR\n  A[\"a &lt; b &gt; c &amp; d &quot;q&quot; &#39;s&#39;\"]\n");
        SPDFExpect(entities != nil, @"a label of HTML entities renders");
        SPDFExpect(SPDFStyleHasLabel(entities, @"a < b > c & d \"q\" 's'"),
                   @"&lt; &gt; &amp; &quot; and &#39; all decode");
        SPDFExpect(SPDFStyleRender(@"flowchart LR\n  A[\"&amp;lt;\"]\n") != nil &&
                       SPDFStyleHasLabel(SPDFStyleRender(@"flowchart LR\n  A[\"&amp;lt;\"]\n"), @"&lt;"),
                   @"&amp; decodes LAST, so &amp;lt; stays the text &lt;");
        // A `;` still ends a statement at top level, and still does NOT end
        // one inside a label -- the bug that made &lt; fail.
        SPDFMarkdownDiagramLayout* semicolons = SPDFStyleRender(@"flowchart LR\n  A[One] --> B[Two]; B --> C[Three]\n");
        SPDFExpect(semicolons != nil && semicolons.labels.count == 3,
                   @"a top-level `;` still separates two statements on one line");

        // --- `<-->` bidirectional edge ----------------------------------
        SPDFMarkdownDiagramLayout* single = SPDFStyleRender(@"flowchart LR\n  A --> B\n");
        SPDFMarkdownDiagramLayout* both = SPDFStyleRender(@"flowchart LR\n  A <--> B\n");
        SPDFExpect(single && both, @"`-->` and `<-->` both render");
        NSUInteger singleHeads = SPDFStyleShapeCount(single, SPDFMarkdownDiagramShapePolygon);
        NSUInteger bothHeads = SPDFStyleShapeCount(both, SPDFMarkdownDiagramShapePolygon);
        SPDFExpect(singleHeads == 1 && bothHeads == 2,
                   @"`<-->` draws an arrowhead at BOTH ends where `-->` draws one");
        SPDFExpect(SPDFStyleShapeCount(SPDFStyleRender(@"flowchart LR\n  A <-- B\n"),
                                       SPDFMarkdownDiagramShapePolygon) == 1,
                   @"`<--` draws only the tail arrowhead");
        SPDFExpect(SPDFStyleShapeCount(SPDFStyleRender(@"flowchart LR\n  A <-.-> B\n"),
                                       SPDFMarkdownDiagramShapePolygon) == 2 &&
                       SPDFStyleShapeCount(SPDFStyleRender(@"flowchart LR\n  A <==> B\n"),
                                           SPDFMarkdownDiagramShapePolygon) == 2,
                   @"the dotted and thick bidirectional forms keep both heads");

        // --- Still-unsupported input still degrades ---------------------
        SPDFExpect(SPDFStyleRender(@"erDiagram\n  A ||--o{ B : has\n") == nil,
                   @"an unsupported mermaid DIAGRAM TYPE still yields nil");
        SPDFExpect(SPDFStyleRender(@"flowchart LR\n  A[X] --> B[Y]\n  A@{ shape: rounded }\n") == nil,
                   @"mermaid v11 node-metadata syntax is still unsupported and yields nil");
        SPDFExpect(SPDFStyleRender(@"flowchart LR\n  A[X] ~~~ B[Y]\n") == nil,
                   @"an unknown edge operator still fails the whole diagram");
        SPDFExpect(SPDFStyleRender(@"flowchart LR\n  A[X]::: --> B[Y]\n") == nil,
                   @"a bare `:::` with no class name is malformed and yields nil");
        SPDFExpect(SPDFStyleRender(@"flowchart QQ\n  A --> B\n") == nil,
                   @"an unknown direction still yields nil");

        // --- The dark-theme author-color POLICY -------------------------
        // 1. Light is byte-identical to what the author wrote.
        NSColor* lightFill =
            SPDFMarkdownDiagramShapeFillColor(railBox, SPDFMarkdownThemeVariantLight);
        SPDFExpect(SPDFStyleColorsEqual(lightFill, authoredFill),
                   @"the light theme paints an author color exactly as written");
        // 2. Dark is the CORE's luma remap, not a lookalike: compare against
        //    spdf_recolor run independently here.
        spdf_recolor_table table;
        spdf_recolor_table_init(&table, SPDF_RECOLOR_LUMA_REMAP, spdf_recolor_default_dark_theme());
        unsigned char pixel[4] = {0xE1, 0xF5, 0xEE, 255};
        spdf_recolor_rgba_span(pixel, 0, 1, &table);
        NSColor* expectedDark = [NSColor colorWithSRGBRed:pixel[0] / 255.0
                                                   green:pixel[1] / 255.0
                                                    blue:pixel[2] / 255.0
                                                   alpha:1];
        NSColor* darkFill = SPDFMarkdownDiagramShapeFillColor(railBox, SPDFMarkdownThemeVariantDark);
        SPDFExpect(SPDFStyleColorsEqual(darkFill, expectedDark),
                   @"the dark theme resolves an author color through the CORE's LUMA_REMAP");
        // 3. The property that matters: the pale fill goes dark, the dark text
        //    goes light, and the author's contrast survives (never dark-on-dark).
        NSColor* darkText = SPDFMarkdownDiagramLabelColor(railLabel, SPDFMarkdownThemeVariantDark);
        NSColor* lightText = SPDFMarkdownDiagramLabelColor(railLabel, SPDFMarkdownThemeVariantLight);
        SPDFExpect(SPDFStyleLuma(lightFill) > 200 && SPDFStyleLuma(darkFill) < 80,
                   @"a pale authored fill becomes a dark fill on dark paper");
        SPDFExpect(SPDFStyleLuma(lightText) < 80 && SPDFStyleLuma(darkText) > 180,
                   @"the near-black authored text color becomes light ink on dark paper");
        SPDFExpect(SPDFStyleLuma(darkText) - SPDFStyleLuma(darkFill) > 100,
                   @"text and fill keep a wide luma separation in dark, so nothing is dark-on-dark");
        // The luma map is exactly affine with slope -(ink_Y - paper_Y)/255, so
        // the author's separation comes back INVERTED and scaled by the dark
        // theme's own paper..ink span (221 - 30) / 255 = 0.749 -- the same
        // compression a PDF page's contrast takes in dark mode, no more.
        CGFloat lightSeparation = SPDFStyleLuma(lightFill) - SPDFStyleLuma(lightText);
        CGFloat darkSeparation = SPDFStyleLuma(darkText) - SPDFStyleLuma(darkFill);
        SPDFExpect(lightSeparation > 0 && darkSeparation > 0,
                   @"the author's contrast polarity is flipped, not lost");
        SPDFExpect(fabs(darkSeparation / lightSeparation - 191.0 / 255.0) < 0.03,
                   @"the author's contrast is scaled by the dark theme's paper..ink span, exactly");
        // 4. Chroma survives: the four authored hues stay four hues.
        CGFloat hue = 0, saturation = 0, brightness = 0, opacity = 0;
        [[darkFill colorUsingColorSpace:NSColorSpace.sRGBColorSpace] getHue:&hue
                                                                saturation:&saturation
                                                                brightness:&brightness
                                                                     alpha:&opacity];
        SPDFExpect(saturation > 0.05, @"the remapped fill is still a green, not a neutral gray");
        // 5. A stroke without an author color still follows its role, and both
        //    themes resolve every shape without ever returning nil.
        BOOL resolvable = YES;
        for (SPDFMarkdownDiagramShape* shape in real.shapes) {
            if (!SPDFMarkdownDiagramShapeFillColor(shape, SPDFMarkdownThemeVariantDark) ||
                !SPDFMarkdownDiagramShapeStrokeColor(shape, SPDFMarkdownThemeVariantLight))
                resolvable = NO;
        }
        for (SPDFMarkdownDiagramLabel* label in real.labels)
            if (!SPDFMarkdownDiagramLabelColor(label, SPDFMarkdownThemeVariantDark)) resolvable = NO;
        SPDFExpect(resolvable, @"every shape and label in the fixture resolves a color in both themes");

        // --- Determinism and laziness -----------------------------------
        SPDFMarkdownDiagramLayout* again = SPDFStyleRender(fence);
        BOOL identical = again.shapes.count == fitted.shapes.count &&
                         again.labels.count == fitted.labels.count &&
                         fabs(again.size.height - fitted.size.height) < 0.001;
        for (NSUInteger index = 0; identical && index < again.labels.count; ++index)
            identical = [again.labels[index].text isEqualToString:fitted.labels[index].text] &&
                        NSEqualRects(again.labels[index].frame, fitted.labels[index].frame);
        SPDFExpect(identical, @"the same styled source lays out identically twice");
        SPDFMarkdownDiagramResetWorkCount();
        SPDFMarkdownDiagramRender(@"c", @"classDef aon fill:#fff\n", kSPDFStyleTestBox, 1.0, nil);
        SPDFExpect(SPDFMarkdownDiagramWorkCount() == 0,
                   @"a non-diagram fence that merely LOOKS like styling does no diagram work");
    }
    return SPDFFinishTests(@"SPDFMarkdownDiagramStyleTests");
}
