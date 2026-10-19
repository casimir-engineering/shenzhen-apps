#import "SPDFMarkdownTestSupport.h"

#import "../../markdown/SPDFMarkdownMathTypesetter.h"
#import "../../markdown/SPDFMarkdownParser.h"
#import "../../markdown/SPDFMarkdownRenderer.h"

// LaTeX math spans: parsing traits, the native subset typesetter, display
// layout, search correspondence over the emitted canonical text, and font
// scaling.

static SPDFMarkdownRenderedDocument* SPDFRenderMarkdown(NSString* markdown, CGFloat fontScale) {
    NSError* error = nil;
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] parseString:markdown
                                                                   sourceURL:nil
                                                                       error:&error];
    SPDFExpect(model != nil && error == nil, @"math markdown parses");
    SPDFMarkdownRenderOptions* options = SPDFMarkdownRenderOptions.defaultOptions;
    options.fontScale = fontScale;
    return [[SPDFMarkdownRenderer new] renderModel:model options:options languageOverrides:nil];
}

static NSDictionary* SPDFAttributesAt(SPDFMarkdownRenderedDocument* rendered, NSString* needle) {
    NSRange range = [rendered.attributedString.string rangeOfString:needle];
    if (range.location == NSNotFound) return nil;
    return [rendered.attributedString attributesAtIndex:range.location effectiveRange:NULL];
}

static void SPDFTestParserTraits(void) {
    NSError* error = nil;
    SPDFMarkdownDocumentModel* model =
        [[SPDFMarkdownParser new] parseString:@"Euler: $e^{i\\pi} + 1 = 0$ done.\n\n$$x^2$$\n"
                                    sourceURL:nil
                                        error:&error];
    SPDFExpect(model != nil, @"math document parses");
    SPDFMarkdownBlock* inlineParagraph = model.blocks.firstObject;
    SPDFExpect(inlineParagraph.runs.count == 3, @"inline math paragraph splits into three runs");
    SPDFMarkdownInlineRun* mathRun = inlineParagraph.runs[1];
    SPDFExpect(mathRun.traits == SPDFMarkdownInlineTraitMath, @"inline $...$ carries the math trait");
    SPDFExpect([mathRun.text isEqualToString:@"e^{i\\pi} + 1 = 0"],
               @"math run text is the raw LaTeX with delimiters stripped");
    SPDFMarkdownInlineRun* displayRun = model.blocks.lastObject.runs.firstObject;
    SPDFExpect(displayRun.traits == (SPDFMarkdownInlineTraitMath | SPDFMarkdownInlineTraitDisplayMath),
               @"display $$...$$ carries math and display-math traits");
    SPDFExpect([displayRun.text isEqualToString:@"x^2"], @"display math text strips $$ delimiters");
}

static void SPDFTestTypesetterSubset(void) {
    NSFont* body = [NSFont systemFontOfSize:15];
    NSFont* code = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    NSColor* color = NSColor.blackColor;
    NSFontManager* manager = NSFontManager.sharedFontManager;

    NSAttributedString* greek = SPDFMarkdownMathTypeset(@"\\alpha \\to \\Omega \\times \\infty",
                                                        body, code, color);
    SPDFExpect([greek.string isEqualToString:@"α → Ω × ∞"], @"greek letters and symbols map to Unicode");

    NSAttributedString* squared = SPDFMarkdownMathTypeset(@"x^2", body, code, color);
    SPDFExpect([squared.string isEqualToString:@"x2"], @"x^2 emits x and 2 as the searchable text");
    NSFont* variableFont = [squared attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
    SPDFExpect(([manager traitsOfFont:variableFont] & NSItalicFontMask) != 0,
               @"single-letter variables render in math italic");
    NSFont* superscriptFont = [squared attribute:NSFontAttributeName atIndex:1 effectiveRange:NULL];
    NSNumber* superscriptOffset = [squared attribute:NSBaselineOffsetAttributeName
                                             atIndex:1
                                      effectiveRange:NULL];
    SPDFExpect(superscriptFont.pointSize < variableFont.pointSize && superscriptOffset.doubleValue > 0,
               @"superscripts render smaller and raised");

    NSAttributedString* subscripted = SPDFMarkdownMathTypeset(@"a_{ij}", body, code, color);
    SPDFExpect([subscripted.string isEqualToString:@"aij"], @"a_{ij} emits the grouped subscript");
    NSFont* subscriptFont = [subscripted attribute:NSFontAttributeName atIndex:1 effectiveRange:NULL];
    NSNumber* subscriptOffset = [subscripted attribute:NSBaselineOffsetAttributeName
                                               atIndex:1
                                        effectiveRange:NULL];
    SPDFExpect(subscriptFont.pointSize < body.pointSize && subscriptOffset.doubleValue < 0,
               @"subscripts render smaller and lowered");

    SPDFExpect([SPDFMarkdownMathTypeset(@"\\frac{1}{2}", body, code, color).string isEqualToString:@"½"],
               @"a trivial \\frac collapses to the Unicode vulgar fraction");
    NSAttributedString* fraction = SPDFMarkdownMathTypeset(@"\\frac{n(n+1)}{2}", body, code, color);
    SPDFExpect([fraction.string containsString:@"\u2044"] && [fraction.string containsString:@"n(n+1)"],
               @"a non-trivial \\frac renders numerator/denominator around a fraction slash");

    NSAttributedString* sum = SPDFMarkdownMathTypeset(@"\\sum_{i=0}^{n}", body, code, color);
    SPDFExpect([sum.string isEqualToString:@"∑i=0n"], @"\\sum with scripts emits ∑ plus both scripts");
    NSNumber* lowerOffset = [sum attribute:NSBaselineOffsetAttributeName atIndex:1 effectiveRange:NULL];
    NSNumber* upperOffset = [sum attribute:NSBaselineOffsetAttributeName
                                   atIndex:sum.length - 1
                            effectiveRange:NULL];
    SPDFExpect(lowerOffset.doubleValue < 0 && upperOffset.doubleValue > 0,
               @"\\sum bounds render as lowered and raised script runs");

    NSAttributedString* text = SPDFMarkdownMathTypeset(@"\\text{speed} = v", body, code, color);
    NSFont* textFont = [text attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
    SPDFExpect(([manager traitsOfFont:textFont] & NSItalicFontMask) == 0,
               @"\\text content renders upright");

    NSAttributedString* root = SPDFMarkdownMathTypeset(@"\\sqrt{x+1}", body, code, color);
    SPDFExpect([root.string isEqualToString:@"√(x+1)"],
               @"\\sqrt degrades to the radical sign with a parenthesized radicand");

    NSAttributedString* unknown = SPDFMarkdownMathTypeset(@"\\foobar x", body, code, color);
    SPDFExpect([unknown.string isEqualToString:@"\\foobar x"],
               @"an unknown command degrades to its visible name, dropping nothing");
    NSFont* unknownFont = [unknown attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
    SPDFExpect([unknownFont.familyName isEqualToString:code.familyName],
               @"the unknown command name renders in the code font");
}

static void SPDFTestRenderedDocument(void) {
    SPDFMarkdownRenderedDocument* rendered = SPDFRenderMarkdown(
        @"Euler: $e^{i\\pi} + 1 = 0$ holds.\n\n$$\\sum_{i=0}^{n} i = \\frac{n(n+1)}{2}$$\n\nAfter.\n",
        1.0);
    NSString* canonical = rendered.attributedString.string;
    SPDFExpect(![canonical containsString:@"$"], @"math delimiters never reach the canonical text");
    SPDFExpect([canonical containsString:@"Euler: eiπ + 1 = 0 holds."],
               @"inline math flows inside its paragraph");
    SPDFExpect([canonical containsString:@"∑i=0n i = n(n+1)"], @"display math typesets its subset");

    // Inline math stays baseline-aligned in a left-aligned paragraph.
    NSRange inlineRange = [canonical rangeOfString:@"eiπ"];
    NSParagraphStyle* inlineStyle = [rendered.attributedString attribute:NSParagraphStyleAttributeName
                                                                 atIndex:inlineRange.location
                                                          effectiveRange:NULL];
    SPDFExpect(inlineStyle.alignment != NSTextAlignmentCenter, @"inline math keeps paragraph flow");

    // Display math renders centered on its own line with vertical margin and a
    // slightly larger font than body text.
    NSRange displayRange = [canonical rangeOfString:@"∑"];
    NSDictionary* displayAttributes = [rendered.attributedString attributesAtIndex:displayRange.location
                                                                    effectiveRange:NULL];
    NSParagraphStyle* displayStyle = displayAttributes[NSParagraphStyleAttributeName];
    SPDFExpect(displayStyle.alignment == NSTextAlignmentCenter, @"display math paragraph is centered");
    SPDFExpect(displayStyle.paragraphSpacingBefore >= 10 && displayStyle.paragraphSpacing >= 10,
               @"display math reserves vertical margin");
    NSFont* displayFont = displayAttributes[NSFontAttributeName];
    SPDFExpect(displayFont.pointSize > 15, @"display math sets slightly larger than body text");
    NSRange afterRange = [canonical rangeOfString:@"After."];
    NSParagraphStyle* afterStyle = [rendered.attributedString attribute:NSParagraphStyleAttributeName
                                                                atIndex:afterRange.location
                                                         effectiveRange:NULL];
    SPDFExpect(afterStyle.alignment != NSTextAlignmentCenter,
               @"the display-math centering does not leak into following paragraphs");

    // Canonical-coordinate contract: emitted math text is the searchable text.
    for (NSString* query in @[ @"eiπ", @"∑i=0n", @"n(n+1)" ]) {
        NSArray<SPDFMarkdownSearchMatch*>* matches = [rendered searchForQuery:query caseSensitive:YES];
        SPDFExpect(matches.count == 1, [@"search finds emitted math text " stringByAppendingString:query]);
        for (SPDFMarkdownSearchMatch* match in matches)
            SPDFExpect([[canonical substringWithRange:match.range] isEqualToString:query],
                       [@"math search range exactly selects " stringByAppendingString:query]);
    }
}

static void SPDFTestFontScale(void) {
    SPDFMarkdownRenderedDocument* base = SPDFRenderMarkdown(@"$x^2 + \\alpha$\n", 1.0);
    SPDFMarkdownRenderedDocument* doubled = SPDFRenderMarkdown(@"$x^2 + \\alpha$\n", 2.0);
    NSFont* baseVariable = SPDFAttributesAt(base, @"x")[NSFontAttributeName];
    NSFont* doubledVariable = SPDFAttributesAt(doubled, @"x")[NSFontAttributeName];
    SPDFExpect(fabs(doubledVariable.pointSize - 2 * baseVariable.pointSize) < 0.001,
               @"fontScale scales math variable fonts");
    NSFont* baseScript = SPDFAttributesAt(base, @"2")[NSFontAttributeName];
    NSFont* doubledScript = SPDFAttributesAt(doubled, @"2")[NSFontAttributeName];
    SPDFExpect(fabs(doubledScript.pointSize - 2 * baseScript.pointSize) < 0.001 &&
                   baseScript.pointSize < baseVariable.pointSize,
               @"fontScale scales script runs while they stay smaller than their base");
    NSNumber* baseOffset = SPDFAttributesAt(base, @"2")[NSBaselineOffsetAttributeName];
    NSNumber* doubledOffset = SPDFAttributesAt(doubled, @"2")[NSBaselineOffsetAttributeName];
    SPDFExpect(fabs(doubledOffset.doubleValue - 2 * baseOffset.doubleValue) < 0.001,
               @"fontScale scales script baseline offsets");
}

int main(void) {
    @autoreleasepool {
        SPDFTestParserTraits();
        SPDFTestTypesetterSubset();
        SPDFTestRenderedDocument();
        SPDFTestFontScale();
    }
    return SPDFFinishTests(@"SPDFMarkdownMathTests");
}
