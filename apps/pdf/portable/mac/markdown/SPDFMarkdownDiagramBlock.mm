#import "SPDFMarkdownDiagramBand.h"
#import "SPDFMarkdownRenderInternal.h"

// The block-renderer hook: a fenced code block whose language is a diagram
// type (mermaid / sequence / flow) renders as native VECTOR artwork instead of
// a code box. The fence SOURCE text is not canonical (like image
// attachments), but every diagram LABEL is: each label lands in the attributed
// string as its own tab-separated run, so a diagram's text is selectable,
// findable by Cmd+F, copied with the selection, and exported as real text.
// The shapes travel separately, as one page decoration (see
// SPDFMarkdownDiagramBand.h). When the seam returns nil the caller falls
// through to the unchanged code-box path and the code text stays canonical.
//
// The rendered block is recorded as a PARAGRAPH: pagination and decoration
// planning must not reserve code-box spacer bands, draw the code box, or offer
// the interactive language pill for a diagram.

BOOL SPDFMarkdownRenderDiagramBlock(SPDFMarkdownRenderContext* context, SPDFMarkdownBlock* block,
                                          NSUInteger depth, BOOL record) {
    NSString* identifier = context.overrides[@(block.blockIndex)] ?: block.codeLanguage;
    if (!SPDFMarkdownDiagramIsDiagramLanguage(identifier)) return NO;
    CGFloat scale = SPDFMarkdownRenderScale(context);
    // A diagram is a FIGURE, so it is sized by the page, not by the inline-image
    // budget: the whole printable column wide, and no taller than one page's
    // printable height net of the air the band reserves above and below. Both
    // come off the live page configuration, so screen, print, Save as PDF and
    // Copy Page agree by construction and turning the paper re-fits the artwork.
    // A render with no page attached keeps the old width-only image budget.
    CGFloat margin = context.options.paragraphSpacing * scale;
    CGFloat depthIndent = depth * 22;
    NSSize contentBox = NSMakeSize(
        MAX(64.0, SPDFMarkdownContentWidthBudget(context, depthIndent, context.options.maximumImageWidth)),
        SPDFMarkdownContentHeightBudget(context, 0));
    SPDFMarkdownDiagramLayout* layout =
        SPDFMarkdownDiagramRender(identifier, block.plainText ?: @"", contentBox, context.options.fontScale,
                                  context.options.diagramCache);
    if (!layout) return NO;

    NSUInteger start = context.output.length;
    SPDFMarkdownThemeVariant variant = context.options.themeVariant;
    NSMutableArray<NSValue*>* labelRanges = [NSMutableArray arrayWithCapacity:layout.labels.count];
    for (SPDFMarkdownDiagramLabel* label in layout.labels) {
        // One tab between labels: it keeps neighboring labels from reading as
        // one word for search and selection, and gives the flowing fallback
        // text view a legible column-ish layout.
        SPDFMarkdownAppend(context, @"\t", @{});
        NSUInteger labelStart = context.output.length;
        SPDFMarkdownAppend(context, label.text,
                           @{
                               NSFontAttributeName: label.font,
                               NSForegroundColorAttributeName: SPDFMarkdownDiagramLabelColor(label, variant),
                           });
        // A label's `<b>`/`<i>` runs are set right here, in the canonical
        // string, because that is the ONE place a diagram's text exists: the
        // band measures each line off this attributed substring and the page
        // and the PDF export draw it, so the emphasis reaches all three at
        // once and can never disagree with what the label was measured at.
        for (SPDFMarkdownDiagramLabelSpan* span in label.spans) {
            NSRange range = NSMakeRange(labelStart + span.range.location, span.range.length);
            if (!range.length || NSMaxRange(range) > context.output.length) continue;
            [context.output addAttribute:NSFontAttributeName value:[label fontForSpan:span] range:range];
            // Underline and strikethrough are not font traits, so they are set
            // here as ordinary text attributes — the same ones body text uses,
            // drawn by the same CTLine pass in the band, the page and the export.
            if (span.underline)
                [context.output addAttribute:NSUnderlineStyleAttributeName
                                       value:@(NSUnderlineStyleSingle)
                                       range:range];
            if (span.strikethrough)
                [context.output addAttribute:NSStrikethroughStyleAttributeName value:@1 range:range];
        }
        [labelRanges addObject:[NSValue valueWithRange:NSMakeRange(labelStart,
                                                                   context.output.length - labelStart)]];
    }
    SPDFMarkdownAppend(context, @"\n", @{});

    NSRange range = NSMakeRange(start, context.output.length - start);
    NSMutableParagraphStyle* style = [NSMutableParagraphStyle new];
    style.lineSpacing = context.options.lineSpacing * scale;
    style.paragraphSpacing = context.options.paragraphSpacing * scale;
    style.headIndent = depthIndent;
    style.firstLineHeadIndent = depthIndent;
    style.alignment = NSTextAlignmentCenter;  // the flowing fallback view centers the labels
    [context.output addAttribute:NSParagraphStyleAttributeName value:style range:range];
    if (record) {
        [context.output addAttribute:SPDFMarkdownBlockIndexAttribute value:@(block.blockIndex) range:range];
        [context.output addAttribute:SPDFMarkdownBlockKindAttribute
                               value:@(SPDFMarkdownBlockKindParagraph)
                               range:range];
        // The paginated band reserves its own air above and below the artwork
        // (paragraph spacing never reaches a band item) -- the same `margin` the
        // height budget above already took off the page.
        SPDFMarkdownDiagramBlockInfo* info =
            [[SPDFMarkdownDiagramBlockInfo alloc] initWithLayout:layout
                                                     labelRanges:labelRanges
                                                       topMargin:margin
                                                    bottomMargin:margin
                                                     depthIndent:depthIndent];
        [context.blocks addObject:[[SPDFMarkdownRenderedBlock alloc] initWithBlockIndex:block.blockIndex
                                                                                   kind:SPDFMarkdownBlockKindParagraph
                                                                        attributedRange:range
                                                                                  level:block.level
                                                                                  depth:depth
                                                                           tableRowInfo:nil
                                                                            diagramInfo:info]];
    }
    return YES;
}
