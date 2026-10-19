#import "SPDFMarkdownTestSupport.h"

#import <CoreText/CoreText.h>

#import "../../markdown/SPDFMarkdownDiagram.h"
#import "../../markdown/SPDFMarkdownDiagramBand.h"
#import "../../markdown/SPDFMarkdownDocument.h"

// The native diagram engine: every supported fence type resolves to bounded
// VECTOR geometry plus canonical text labels, every unsupported / malformed /
// over-budget fence degrades to the ordinary code box, diagram labels are real
// searchable text in the canonical string laid out as one atomic band, the
// work counter proves a diagram-free document does zero diagram work, and the
// session cache proves a rerender (and now a theme switch) does no work twice.

// A width-only box (zero height = no height budget), i.e. exactly the fit these
// suites always asserted; the page-BOX policy is exercised in its own suite.
static const NSSize kSPDFDiagramTestBox = {440, 0};

static SPDFMarkdownDiagramLayout* SPDFRenderDiagram(NSString* language, NSString* source) {
    return SPDFMarkdownDiagramRender(language, source, kSPDFDiagramTestBox, 1.0, nil);
}

// A rendered diagram is well formed: non-empty logical size, inside the content
// width budget and the dimension budget, at least one vector shape, and every
// label inside the diagram box with a real font size.
static void SPDFExpectWellFormedDiagram(SPDFMarkdownDiagramLayout* diagram, NSString* what) {
    if (!diagram) {
        SPDFExpect(NO, [what stringByAppendingString:@" renders a diagram"]);
        return;
    }
    SPDFExpect(diagram.size.width > 0 && diagram.size.height > 0,
               [what stringByAppendingString:@" has a positive logical size"]);
    SPDFExpect(diagram.size.width <= kSPDFDiagramTestBox.width + 0.5,
               [what stringByAppendingString:@" fits the content width budget"]);
    SPDFExpect(diagram.size.width <= SPDFMarkdownDiagramMaximumDimension &&
                   diagram.size.height <= SPDFMarkdownDiagramMaximumDimension,
               [what stringByAppendingString:@" stays inside the dimension budget"]);
    SPDFExpect(diagram.shapes.count > 0, [what stringByAppendingString:@" emits vector shapes"]);
    SPDFExpect(diagram.labels.count > 0, [what stringByAppendingString:@" emits text labels"]);
    BOOL bounded = YES;
    for (SPDFMarkdownDiagramLabel* label in diagram.labels) {
        if (label.fontSize <= 0 || !label.text.length) bounded = NO;
        if (NSMinX(label.frame) < -1 || NSMinY(label.frame) < -1 ||
            NSMaxY(label.frame) > diagram.size.height + 2)
            bounded = NO;
    }
    SPDFExpect(bounded, [what stringByAppendingString:@" keeps every label sized and inside the diagram box"]);
}

static BOOL SPDFDiagramHasLabel(SPDFMarkdownDiagramLayout* diagram, NSString* text) {
    for (SPDFMarkdownDiagramLabel* label in diagram.labels)
        if ([label.text isEqualToString:text]) return YES;
    return NO;
}

static NSUInteger SPDFDiagramShapeCount(SPDFMarkdownDiagramLayout* diagram, SPDFMarkdownDiagramShapeKind kind) {
    NSUInteger count = 0;
    for (SPDFMarkdownDiagramShape* shape in diagram.shapes)
        if (shape.kind == kind) ++count;
    return count;
}

static NSString* SPDFOverBudgetFlowchart(void) {
    NSMutableString* source = [NSMutableString stringWithString:@"graph TD\n"];
    for (NSUInteger index = 0; index < 260; ++index)
        [source appendFormat:@"  n%lu --> n%lu\n", (unsigned long)index, (unsigned long)(index + 1)];
    return source;
}

static SPDFMarkdownDocument* SPDFDocumentForMarkdown(NSString* markdown, SPDFMarkdownRenderOptions* options) {
    NSError* error = nil;
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] parseString:markdown sourceURL:nil error:&error];
    return model ? [[SPDFMarkdownDocument alloc] initWithModel:model options:options] : nil;
}

// The one pagination item carrying diagram geometry, and its page.
static SPDFMarkdownPaginationItem* SPDFDiagramItem(SPDFMarkdownPaginationPlan* plan, NSUInteger* outIndex) {
    for (NSUInteger index = 0; index < plan.items.count; ++index) {
        if (plan.items[index].diagramInfo) {
            if (outIndex) *outIndex = index;
            return plan.items[index];
        }
    }
    return nil;
}

int main(void) {
    @autoreleasepool {
        // --- Language classification is O(1) and total ----------------------
        SPDFExpect(SPDFMarkdownDiagramIsDiagramLanguage(@"mermaid") &&
                       SPDFMarkdownDiagramIsDiagramLanguage(@"Mermaid") &&
                       SPDFMarkdownDiagramIsDiagramLanguage(@"sequence") &&
                       SPDFMarkdownDiagramIsDiagramLanguage(@"flow"),
                   @"mermaid / sequence / flow are diagram fences, case-insensitively");
        SPDFExpect(!SPDFMarkdownDiagramIsDiagramLanguage(@"swift") &&
                       !SPDFMarkdownDiagramIsDiagramLanguage(@"") &&
                       !SPDFMarkdownDiagramIsDiagramLanguage(nil) &&
                       !SPDFMarkdownDiagramIsDiagramLanguage(@"mermaidish"),
                   @"ordinary code fences are not diagram fences");

        // --- Per-type parse + layout smoke (the dist/diagram-demo.md set) ---
        SPDFMarkdownDiagramLayout* flowchart =
            SPDFRenderDiagram(@"mermaid",
                              @"graph TD\n"
                              @"  A[Start] --> B{Ready?}\n"
                              @"  B -- yes --> C([Ship it])\n"
                              @"  B -- no --> D((Wait))\n"
                              @"  C --> E[[Report]]\n"
                              @"  D -.-> B\n");
        SPDFExpectWellFormedDiagram(flowchart, @"mermaid flowchart with shapes and labelled edges");
        SPDFExpect(SPDFDiagramHasLabel(flowchart, @"Start") && SPDFDiagramHasLabel(flowchart, @"Ready?") &&
                       SPDFDiagramHasLabel(flowchart, @"yes"),
                   @"node and edge labels are text, not paths");
        SPDFExpect(SPDFDiagramShapeCount(flowchart, SPDFMarkdownDiagramShapePolyline) >= 5 &&
                       SPDFDiagramShapeCount(flowchart, SPDFMarkdownDiagramShapeEllipse) >= 1,
                   @"a flowchart emits edge polylines and its circle node as vectors");
        SPDFExpectWellFormedDiagram(SPDFRenderDiagram(@"mermaid",
                                                      @"flowchart LR\n"
                                                      @"  A[Left] --> B[Right]\n"),
                                    @"mermaid flowchart LR");
        SPDFExpectWellFormedDiagram(SPDFRenderDiagram(@"mermaid",
                                                      @"sequenceDiagram\n"
                                                      @"  participant A as Reader\n"
                                                      @"  participant B as Renderer\n"
                                                      @"  A->>B: open document\n"
                                                      @"  Note right of B: parses once\n"
                                                      @"  alt cached\n"
                                                      @"    B-->>A: reuse layout\n"
                                                      @"  else cold\n"
                                                      @"    B-->>A: lay it out\n"
                                                      @"  end\n"),
                                    @"mermaid sequenceDiagram");
        SPDFMarkdownDiagramLayout* pie = SPDFRenderDiagram(@"mermaid",
                                                           @"pie title Fence types\n"
                                                           @"  \"flowchart\" : 45\n"
                                                           @"  \"sequence\" : 30\n"
                                                           @"  \"other\" : 25\n");
        SPDFExpectWellFormedDiagram(pie, @"mermaid pie");
        SPDFExpect(SPDFDiagramShapeCount(pie, SPDFMarkdownDiagramShapePieSlice) == 3,
                   @"a pie emits one filled slice primitive per entry");
        SPDFExpectWellFormedDiagram(SPDFRenderDiagram(@"mermaid",
                                                      @"stateDiagram-v2\n"
                                                      @"  [*] --> Idle\n"
                                                      @"  Idle --> Parsing : fence seen\n"
                                                      @"  Parsing --> Drawn\n"
                                                      @"  Drawn --> [*]\n"),
                                    @"mermaid stateDiagram-v2");
        SPDFExpectWellFormedDiagram(SPDFRenderDiagram(@"mermaid",
                                                      @"classDiagram\n"
                                                      @"  class Renderer {\n"
                                                      @"    +NSSize logicalSize\n"
                                                      @"    +render()\n"
                                                      @"  }\n"
                                                      @"  Renderer <|-- GraphRenderer\n"
                                                      @"  Renderer o-- Cache : reuses\n"),
                                    @"mermaid classDiagram");
        SPDFExpectWellFormedDiagram(SPDFRenderDiagram(@"mermaid",
                                                      @"gantt\n"
                                                      @"  title Diagram engine\n"
                                                      @"  dateFormat YYYY-MM-DD\n"
                                                      @"  section Parsing\n"
                                                      @"    Grammar : done, g1, 2026-01-01, 10d\n"
                                                      @"    Layout : active, after g1, 2w\n"
                                                      @"  section Raster\n"
                                                      @"    Drawing : crit, 2026-02-01, 2026-02-20\n"),
                                    @"mermaid gantt");
        SPDFExpectWellFormedDiagram(SPDFRenderDiagram(@"sequence",
                                                      @"Title: js-sequence\n"
                                                      @"Alice->Bob: hello\n"
                                                      @"Bob-->Alice: hi back\n"
                                                      @"Note over Alice,Bob: done\n"),
                                    @"js-sequence `sequence` fence");
        SPDFExpectWellFormedDiagram(SPDFRenderDiagram(@"flow",
                                                      @"st=>start: Begin\n"
                                                      @"op=>operation: Parse fence\n"
                                                      @"cond=>condition: Supported?\n"
                                                      @"io=>inputoutput: Code box\n"
                                                      @"e=>end: Figure\n"
                                                      @"st->op->cond\n"
                                                      @"cond(yes)->e\n"
                                                      @"cond(no)->io\n"),
                                    @"flowchart.js `flow` fence");

        // --- classDiagram compartments: no empty strips ----------------------
        SPDFMarkdownDiagramLayout* bare = SPDFRenderDiagram(@"mermaid", @"classDiagram\n  class GraphImage\n");
        SPDFMarkdownDiagramLayout* attributesOnly =
            SPDFRenderDiagram(@"mermaid", @"classDiagram\n  class GraphImage {\n    +NSSize size\n  }\n");
        SPDFMarkdownDiagramLayout* methodsOnly =
            SPDFRenderDiagram(@"mermaid", @"classDiagram\n  class GraphImage {\n    +draw()\n  }\n");
        SPDFMarkdownDiagramLayout* both = SPDFRenderDiagram(@"mermaid",
                                                            @"classDiagram\n  class GraphImage {\n"
                                                            @"    +NSSize size\n    +draw()\n  }\n");
        SPDFExpect(bare != nil && attributesOnly != nil && methodsOnly != nil && both != nil,
                   @"every classDiagram member shape renders");
        // Each compartment DIVIDER is one polyline; the box itself is the rect.
        SPDFExpect(SPDFDiagramShapeCount(bare, SPDFMarkdownDiagramShapeRectangle) == 1 &&
                       SPDFDiagramShapeCount(bare, SPDFMarkdownDiagramShapePolyline) == 0,
                   @"a class with NO members is a single box with no empty compartment strips");
        SPDFExpect(SPDFDiagramShapeCount(attributesOnly, SPDFMarkdownDiagramShapePolyline) == 1 &&
                       SPDFDiagramShapeCount(methodsOnly, SPDFMarkdownDiagramShapePolyline) == 1,
                   @"a class with members on ONE side draws exactly one extra compartment");
        SPDFExpect(SPDFDiagramShapeCount(both, SPDFMarkdownDiagramShapePolyline) == 2,
                   @"a class with attributes AND methods draws three compartments");
        SPDFExpect(bare.size.height < attributesOnly.size.height &&
                       attributesOnly.size.height < both.size.height,
                   @"an empty class box is shorter than one with members");

        // --- Degradation: every failure mode returns nil ---------------------
        SPDFExpect(SPDFRenderDiagram(@"mermaid", @"graph XX\n  A --> B\n") == nil,
                   @"an unknown flow direction degrades to the code box");
        SPDFExpect(SPDFRenderDiagram(@"mermaid", @"erDiagram\n  A ||--o{ B : has\n") == nil,
                   @"an unimplemented mermaid sub-type degrades to the code box");
        SPDFExpect(SPDFRenderDiagram(@"mermaid", @"not a diagram at all\njust prose\n") == nil,
                   @"garbage in a mermaid fence degrades to the code box");
        SPDFExpect(SPDFRenderDiagram(@"mermaid", @"graph TD\n  A[unterminated --> B\n") == nil,
                   @"a syntax error degrades the whole diagram");
        SPDFExpect(SPDFRenderDiagram(@"mermaid", @"sequenceDiagram\n  A wanders off\n") == nil,
                   @"a malformed sequence line degrades the whole diagram");
        SPDFExpect(SPDFRenderDiagram(@"mermaid", @"pie\n  \"only\" : not-a-number\n") == nil,
                   @"a non-numeric pie value degrades the whole diagram");
        SPDFExpect(SPDFRenderDiagram(@"flow", @"a->b\n") == nil,
                   @"a flow fence referencing undefined nodes degrades");
        SPDFExpect(SPDFRenderDiagram(@"mermaid", SPDFOverBudgetFlowchart()) == nil,
                   @"a graph beyond the 200-node budget degrades to the code box");
        SPDFExpect(SPDFRenderDiagram(@"mermaid", @"") == nil && SPDFRenderDiagram(@"swift", @"let x = 1\n") == nil,
                   @"an empty fence and a non-diagram language both render nothing");

        // --- Fitting: an over-wide diagram scales by ONE common factor --------
        NSString* wideSource = @"graph LR\n  A[One] --> B[Two] --> C[Three] --> D[Four] --> E[Five]\n";
        SPDFMarkdownDiagramLayout* natural = SPDFMarkdownDiagramRender(@"mermaid", wideSource, NSMakeSize(4000, 0), 1.0, nil);
        SPDFMarkdownDiagramLayout* fitted = SPDFMarkdownDiagramRender(@"mermaid", wideSource, NSMakeSize(220, 0), 1.0, nil);
        SPDFExpect(natural != nil && fitted != nil && natural.size.width > 220 && fitted.size.width <= 220.5,
                   @"a diagram wider than the column is fitted, not clipped");
        CGFloat factor = fitted.size.width / natural.size.width;
        SPDFExpect(fabs(fitted.size.height - natural.size.height * factor) <= 1.5,
                   @"the fit scales height by the same factor as width");
        SPDFExpect(natural.labels.count == fitted.labels.count && natural.shapes.count == fitted.shapes.count,
                   @"fitting never drops geometry");
        BOOL fontsScaled = natural.labels.count > 0;
        for (NSUInteger index = 0; index < natural.labels.count && index < fitted.labels.count; ++index) {
            CGFloat expected = natural.labels[index].fontSize * factor;
            if (fabs(fitted.labels[index].fontSize - expected) > 0.05) fontsScaled = NO;
        }
        SPDFExpect(fontsScaled, @"label FONT SIZES scale by the same common factor as the geometry");

        // --- Laziness: a diagram-free document does zero diagram work --------
        SPDFMarkdownDiagramResetWorkCount();
        SPDFExpect(SPDFMarkdownDiagramWorkCount() == 0, @"the work counter resets");
        NSString* plainMarkdown = @"# Title\n\nSome prose with `inline code`.\n\n"
                                  @"```swift\nlet answer = 42\n```\n\n"
                                  @"| a | b |\n| --- | --- |\n| 1 | 2 |\n\n"
                                  @"> a quote\n\n- item one\n- item two\n";
        SPDFMarkdownDocument* plain =
            SPDFDocumentForMarkdown(plainMarkdown, SPDFMarkdownRenderOptions.defaultOptions);
        SPDFExpect(plain != nil, @"the diagram-free document renders");
        SPDFExpect(SPDFMarkdownDiagramWorkCount() == 0,
                   @"a document with no diagram fence performs ZERO diagram work");
        SPDFExpect([plain.renderedDocument.attributedString.string containsString:@"let answer = 42"],
                   @"an ordinary code fence still renders its source text");

        NSString* diagramMarkdown = @"# Flow\n\n```mermaid\ngraph TD\n  A[Start] --> B[Stop]\n```\n\nAfter.\n";
        SPDFMarkdownDocument* withDiagram =
            SPDFDocumentForMarkdown(diagramMarkdown, SPDFMarkdownRenderOptions.defaultOptions);
        SPDFExpect(withDiagram != nil && SPDFMarkdownDiagramWorkCount() == 1,
                   @"a document WITH a diagram fence performs exactly one unit of diagram work");

        // --- Cache: one session cache, one layout per distinct key ------------
        SPDFMarkdownDiagramResetWorkCount();
        SPDFMarkdownDiagramCache* cache = [SPDFMarkdownDiagramCache new];
        NSString* cachedSource = @"graph LR\n  A[One] --> B[Two]\n";
        SPDFMarkdownDiagramLayout* first = SPDFMarkdownDiagramRender(@"mermaid", cachedSource,
                                                                     kSPDFDiagramTestBox, 1.0, cache);
        SPDFMarkdownDiagramLayout* second = SPDFMarkdownDiagramRender(@"mermaid", cachedSource,
                                                                      kSPDFDiagramTestBox, 1.0, cache);
        SPDFExpect(first != nil && second == first && SPDFMarkdownDiagramWorkCount() == 1,
                   @"a second render of the same fence hits the cache instead of laying it out again");
        SPDFMarkdownDiagramRender(@"mermaid", cachedSource, kSPDFDiagramTestBox, 1.5, cache);
        SPDFExpect(SPDFMarkdownDiagramWorkCount() == 2, @"a text-size change re-lays out");
        SPDFMarkdownDiagramRender(@"mermaid", cachedSource, NSMakeSize(260, 0), 1.0, cache);
        SPDFExpect(SPDFMarkdownDiagramWorkCount() == 3, @"a width change re-lays out");
        // Negative caching: a malformed fence is parsed once, never again.
        SPDFMarkdownDiagramResetWorkCount();
        NSString* broken = @"graph TD\n  A[bad --> B\n";
        SPDFExpect(SPDFMarkdownDiagramRender(@"mermaid", broken, kSPDFDiagramTestBox, 1.0, cache) == nil &&
                       SPDFMarkdownDiagramRender(@"mermaid", broken, kSPDFDiagramTestBox, 1.0, cache) == nil &&
                       SPDFMarkdownDiagramWorkCount() == 1,
                   @"a failed parse is cached too, so a rerender never re-parses it");
        SPDFExpect(cache.count > 0, @"the cache holds its entries");
        [cache removeAllEntries];
        SPDFExpect(cache.count == 0, @"the cache can be emptied");

        // --- Theme: one geometry, two palettes -------------------------------
        SPDFExpect(![SPDFMarkdownDiagramRoleColor(SPDFMarkdownDiagramRoleText, SPDFMarkdownThemeVariantLight)
                        isEqual:SPDFMarkdownDiagramRoleColor(SPDFMarkdownDiagramRoleText,
                                                             SPDFMarkdownThemeVariantDark)] &&
                       ![SPDFMarkdownDiagramRoleColor(SPDFMarkdownDiagramRoleNodeFill,
                                                      SPDFMarkdownThemeVariantLight)
                           isEqual:SPDFMarkdownDiagramRoleColor(SPDFMarkdownDiagramRoleNodeFill,
                                                                SPDFMarkdownThemeVariantDark)],
                   @"the same role resolves to DIFFERENT colors per reading theme");
        NSColor* lightPaper = [SPDFMarkdownDiagramRoleColor(SPDFMarkdownDiagramRolePaper,
                                                            SPDFMarkdownThemeVariantLight)
            colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        NSColor* darkPaper = [SPDFMarkdownDiagramRoleColor(SPDFMarkdownDiagramRolePaper,
                                                           SPDFMarkdownThemeVariantDark)
            colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        SPDFExpect(lightPaper.brightnessComponent - darkPaper.brightnessComponent > 0.3,
                   @"the dark theme resolves a dark paper where the light theme resolves a light one");
        SPDFExpect(SPDFMarkdownDiagramRoleColor(SPDFMarkdownDiagramRoleNone,
                                                SPDFMarkdownThemeVariantLight)
                           .alphaComponent == 0,
                   @"the None role paints nothing");
        SPDFMarkdownDiagramResetWorkCount();
        SPDFMarkdownDiagramCache* themeCache = [SPDFMarkdownDiagramCache new];
        SPDFMarkdownDocument* lightDocument = SPDFDocumentForMarkdown(
            diagramMarkdown, ({
              SPDFMarkdownRenderOptions* options = [SPDFMarkdownRenderOptions
                  defaultOptionsForThemeVariant:SPDFMarkdownThemeVariantLight];
              options.diagramCache = themeCache;
              options;
            }));
        SPDFMarkdownDocument* darkDocument = SPDFDocumentForMarkdown(
            diagramMarkdown, ({
              SPDFMarkdownRenderOptions* options = [SPDFMarkdownRenderOptions
                  defaultOptionsForThemeVariant:SPDFMarkdownThemeVariantDark];
              options.diagramCache = themeCache;
              options;
            }));
        SPDFExpect(lightDocument != nil && darkDocument != nil && SPDFMarkdownDiagramWorkCount() == 1,
                   @"geometry is theme-independent, so a theme switch REUSES the cached layout");
        NSRange labelRange = [darkDocument.renderedDocument.attributedString.string rangeOfString:@"Start"];
        NSColor* darkLabelColor = [darkDocument.renderedDocument.attributedString
            attribute:NSForegroundColorAttributeName
              atIndex:labelRange.location
            effectiveRange:NULL];
        NSColor* lightLabelColor = [lightDocument.renderedDocument.attributedString
            attribute:NSForegroundColorAttributeName
              atIndex:labelRange.location
            effectiveRange:NULL];
        SPDFExpect(labelRange.location != NSNotFound && ![darkLabelColor isEqual:lightLabelColor],
                   @"the same label text takes its theme's text color in the canonical string");

        // --- Text is canonical: labels are selectable, searchable text --------
        NSAttributedString* diagramString = withDiagram.renderedDocument.attributedString;
        SPDFExpect(![diagramString.string containsString:@"graph TD"] &&
                       ![diagramString.string containsString:@"A[Start]"],
                   @"a rendered diagram keeps its fence SOURCE out of the canonical string");
        SPDFExpect([diagramString.string containsString:@"Start"] &&
                       [diagramString.string containsString:@"Stop"],
                   @"a rendered diagram puts its node LABELS into the canonical string");
        SPDFExpect(![diagramString.string containsString:@"￼"],
                   @"a vector diagram contributes NO attachment character");
        SPDFMarkdownRenderedBlock* diagramBlock = nil;
        for (SPDFMarkdownRenderedBlock* block in withDiagram.renderedDocument.renderedBlocks)
            if (block.diagramInfo) diagramBlock = block;
        SPDFExpect(diagramBlock != nil && diagramBlock.kind == SPDFMarkdownBlockKindParagraph,
                   @"a diagram fence records as a PARAGRAPH so no code box or language pill is planned");
        SPDFExpect(diagramBlock.diagramInfo.labelRanges.count == diagramBlock.diagramInfo.layout.labels.count,
                   @"every resolved label owns a canonical range");
        BOOL rangesMatch = YES;
        for (NSUInteger index = 0; index < diagramBlock.diagramInfo.labelRanges.count; ++index) {
            NSRange range = diagramBlock.diagramInfo.labelRanges[index].rangeValue;
            NSString* canonical = [diagramString.string substringWithRange:range];
            if (![canonical isEqualToString:diagramBlock.diagramInfo.layout.labels[index].text])
                rangesMatch = NO;
        }
        SPDFExpect(rangesMatch, @"each label's canonical range holds exactly that label's text");
        SPDFExpect([diagramString attribute:SPDFMarkdownCodeLanguageAttribute
                                    atIndex:diagramBlock.attributedRange.location
                             effectiveRange:nil] == nil,
                   @"a diagram carries no code-language attribute");

        NSArray<SPDFMarkdownSearchMatch*>* matches = [withDiagram searchForQuery:@"Start" caseSensitive:NO];
        SPDFExpect(matches.count == 1 &&
                       NSLocationInRange(matches.firstObject.range.location, diagramBlock.attributedRange),
                   @"Cmd+F finds a word INSIDE a diagram and counts it as a match in the diagram block");

        // --- Geometry: one atomic band of centered label lines ---------------
        SPDFMarkdownPageConfiguration* configuration = SPDFMarkdownPageConfiguration.A4PortraitConfiguration;
        SPDFMarkdownPaginationPlan* plan = [withDiagram paginationPlanForConfiguration:configuration];
        NSUInteger diagramItemIndex = NSNotFound;
        SPDFMarkdownPaginationItem* item = SPDFDiagramItem(plan, &diagramItemIndex);
        SPDFExpect(item != nil && item.bandLayout && item.lines.count > 1,
                   @"a diagram measures as one band item with a line per label");
        SPDFExpect(item.measuredHeight >=
                       item.diagramInfo.layout.size.height + item.diagramInfo.topMargin - 0.01,
                   @"the band reserves the diagram's full height plus its margins");
        NSUInteger pagesWithDiagram = 0;
        for (SPDFMarkdownPage* page in plan.pages) {
            BOOL seen = NO;
            for (SPDFMarkdownPageFragment* fragment in page.fragments)
                if (fragment.itemIndex == diagramItemIndex) seen = YES;
            if (seen) ++pagesWithDiagram;
        }
        SPDFExpect(pagesWithDiagram == 1, @"the diagram band is ATOMIC: it never splits across pages");

        // Every label line centers on its own box, which sits inside a node shape.
        NSRange startRange = [diagramString.string rangeOfString:@"Start"];
        SPDFMarkdownTextLine* startLine = nil;
        for (SPDFMarkdownTextLine* line in item.lines)
            if (NSEqualRanges(line.attributedRange, startRange)) startLine = line;
        SPDFMarkdownDiagramLabel* startLabel = nil;
        for (SPDFMarkdownDiagramLabel* label in item.diagramInfo.layout.labels)
            if ([label.text isEqualToString:@"Start"]) startLabel = label;
        SPDFExpect(startLine != nil && startLabel != nil, @"the Start label has both a line and a layout label");
        CTLineRef measured =
            SPDFMarkdownCreateFragmentLine([diagramString attributedSubstringFromRange:startRange]);
        CGFloat measuredWidth = (CGFloat)CTLineGetTypographicBounds(measured, NULL, NULL, NULL);
        CFRelease(measured);
        CGFloat lineCenter = startLine.xOffset + measuredWidth / 2;
        CGFloat boxCenter = item.diagramInfo.xOrigin + NSMidX(startLabel.frame);
        SPDFExpect(fabs(lineCenter - boxCenter) < 1.0,
                   @"a node label's drawn text is centered in its node box");
        SPDFMarkdownDiagramShape* nodeBox = nil;
        for (SPDFMarkdownDiagramShape* shape in item.diagramInfo.layout.shapes) {
            if (shape.kind != SPDFMarkdownDiagramShapeRectangle) continue;
            if (NSPointInRect(NSMakePoint(NSMidX(startLabel.frame), NSMidY(startLabel.frame)), shape.rect))
                nodeBox = shape;
        }
        SPDFExpect(nodeBox != nil && fabs(NSMidX(nodeBox.rect) - NSMidX(startLabel.frame)) < 1.0,
                   @"the label box shares its center with the node rectangle it sits in");
        SPDFExpect(item.diagramInfo.xOrigin > 0, @"the diagram band is centered in the printable column");

        // Degradation is preserved end to end: an invalid mermaid fence still
        // renders as ordinary, canonical, searchable code text.
        SPDFMarkdownDocument* invalid = SPDFDocumentForMarkdown(
            @"```mermaid\nerDiagram\n  CUSTOMER ||--o{ ORDER : places\n```\n",
            SPDFMarkdownRenderOptions.defaultOptions);
        NSString* invalidText = invalid.renderedDocument.attributedString.string;
        SPDFExpect([invalidText containsString:@"erDiagram"] &&
                       [invalidText containsString:@"CUSTOMER ||--o{ ORDER : places"],
                   @"an unsupported mermaid fence still renders its code text canonically");
        SPDFMarkdownRenderedBlock* invalidBlock = invalid.renderedDocument.renderedBlocks.firstObject;
        SPDFExpect(invalidBlock.kind == SPDFMarkdownBlockKindCode && invalidBlock.diagramInfo == nil,
                   @"an unsupported mermaid fence stays a recorded CODE block");

        // The options carry the shared cache by reference through a copy, so
        // the renderer's internal copies all hit the same session store.
        SPDFMarkdownRenderOptions* options = SPDFMarkdownRenderOptions.defaultOptions;
        SPDFExpect(options.diagramCache == nil, @"the diagram cache defaults to nil (rendering still works)");
        SPDFMarkdownDiagramCache* sessionCache = [SPDFMarkdownDiagramCache new];
        options.diagramCache = sessionCache;
        SPDFMarkdownRenderOptions* copiedOptions = [options copy];
        SPDFExpect(copiedOptions.diagramCache == sessionCache,
                   @"the shared diagram cache survives a copy BY REFERENCE");

        SPDFMarkdownDiagramResetWorkCount();
        SPDFMarkdownRenderOptions* cachedOptions = SPDFMarkdownRenderOptions.defaultOptions;
        cachedOptions.diagramCache = [SPDFMarkdownDiagramCache new];
        SPDFDocumentForMarkdown(diagramMarkdown, cachedOptions);
        NSUInteger afterFirstDocument = SPDFMarkdownDiagramWorkCount();
        SPDFDocumentForMarkdown(diagramMarkdown, cachedOptions);
        SPDFExpect(afterFirstDocument == 1 && SPDFMarkdownDiagramWorkCount() == 1,
                   @"a rerender with the session cache reuses the layout instead of recomputing it");
    }
    return SPDFFinishTests(@"SPDFMarkdownDiagramTests");
}
