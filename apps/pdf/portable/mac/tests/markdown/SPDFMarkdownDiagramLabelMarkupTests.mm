#import "SPDFMarkdownTestSupport.h"

#import "../../markdown/SPDFMarkdownDiagramInternal.h"
#import "../../markdown/SPDFMarkdownDocument.h"
#import "../../markdown/SPDFMarkdownParser.h"
#import "../../markdown/SPDFMarkdownRenderer.h"

// mermaid renders node/edge labels as HTML, so a real-world power tree writes
// `USB["<b>USB-C VBUS</b> 5 V"]` and means a BOLD RUN inside one label line.
// This renderer used to draw the tags themselves -- `<b>USB-C VBUS</b> 5 V`,
// seven literal characters of markup, measured and wrapped as text -- because
// the label cleaner only knew about `<br>` and HTML entities.
//
// This suite pins the three things that fix has to get right at once: the tags
// never reach drawn text, the emphasis survives as a real font run in the
// canonical attributed string (so selection, Cmd+F, and the vector PDF export
// all see it), and MEASUREMENT follows the runs -- the markup contributes no
// width, and a bold run is measured in the bold face it will be drawn in.

// Deliberately roomy: a box that forces the legibility reflow ladder would
// re-wrap the labels and make the per-line assertions below about the
// LADDER rather than about the markup.
static const NSSize kSPDFMarkupBox = {1200, 0};

static SPDFMarkdownDiagramLayout* SPDFMarkupDiagram(NSString* source) {
    return SPDFMarkdownDiagramRender(@"mermaid", source, kSPDFMarkupBox, 1.0, nil);
}

static SPDFMarkdownDiagramLabel* SPDFMarkupLabel(SPDFMarkdownDiagramLayout* layout, NSString* text) {
    for (SPDFMarkdownDiagramLabel* label in layout.labels)
        if ([label.text isEqualToString:text]) return label;
    return nil;
}

// The traits of one span, keyed by the substring it must cover.
static BOOL SPDFMarkupSpanMatches(SPDFMarkdownDiagramLabel* label, NSString* needle, BOOL bold, BOOL italic) {
    NSRange expected = [label.text rangeOfString:needle];
    if (expected.location == NSNotFound) return NO;
    for (SPDFMarkdownDiagramLabelSpan* span in label.spans)
        if (NSEqualRanges(span.range, expected) && span.bold == bold && span.italic == italic) return YES;
    return NO;
}

static BOOL SPDFMarkupFontIsBold(NSFont* font) {
    return font && ([NSFontManager.sharedFontManager traitsOfFont:font] & NSBoldFontMask) != 0;
}

static BOOL SPDFMarkupFontIsItalic(NSFont* font) {
    return font && ([NSFontManager.sharedFontManager traitsOfFont:font] & NSItalicFontMask) != 0;
}

static NSAttributedString* SPDFMarkupRender(NSString* markdown) {
    NSError* error = nil;
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] parseString:markdown sourceURL:nil error:&error];
    if (!model) return nil;
    SPDFMarkdownDocument* document =
        [[SPDFMarkdownDocument alloc] initWithModel:model
                                             options:SPDFMarkdownRenderOptions.defaultOptions];
    return document.renderedDocument.attributedString;
}

// The font in effect at the first character of `needle`.
static NSFont* SPDFMarkupFontAt(NSAttributedString* rendered, NSString* needle, NSUInteger offset) {
    NSRange range = [rendered.string rangeOfString:needle];
    if (range.location == NSNotFound || range.location + offset >= rendered.length) return nil;
    return [rendered attribute:NSFontAttributeName atIndex:range.location + offset effectiveRange:NULL];
}

int main(void) {
    @autoreleasepool {
        NSString* source = @"flowchart LR\n"
                            "  USB[\"<b>USB-C VBUS</b> 5 V\"]\n"
                            "  AON{{\"<b>1.8V_AON</b><br/><b>BUCK-1</b> buck 360 nA IQ\"}}\n"
                            "  MIX[\"<b>bold <i>and slanted</i></b> tail\"]\n"
                            "  LIT[\"a &lt; b plus <notatag> kept\"]\n"
                            "  USB --> AON --> MIX --> LIT\n";
        SPDFMarkdownDiagramLayout* layout = SPDFMarkupDiagram(source);
        SPDFExpect(layout != nil && layout.labels.count > 0, @"the markup flowchart lays out");

        // 1. Markup never reaches drawn text.
        BOOL clean = YES;
        for (SPDFMarkdownDiagramLabel* label in layout.labels)
            for (NSString* tag in @[ @"<b>", @"</b>", @"<i>", @"</i>", @"<strong>", @"<em>" ])
                if ([label.text containsString:tag]) clean = NO;
        SPDFExpect(clean, @"no diagram label draws an inline formatting tag");

        // 2. The label keeps its text, with the emphasis as a span over it.
        SPDFMarkdownDiagramLabel* usb = SPDFMarkupLabel(layout, @"USB-C VBUS 5 V");
        SPDFExpect(usb != nil, @"<b>USB-C VBUS</b> 5 V draws as `USB-C VBUS 5 V`");
        SPDFExpect(SPDFMarkupSpanMatches(usb, @"USB-C VBUS", YES, NO),
                   @"the <b> half of the label is a bold span, the tail is not");
        SPDFExpect(usb.spans.count == 1, @"the plain tail carries no span of its own");

        // 3. A <br/> label still splits into lines, each keeping its own span.
        SPDFMarkdownDiagramLabel* rail = SPDFMarkupLabel(layout, @"1.8V_AON");
        SPDFExpect(rail != nil && SPDFMarkupSpanMatches(rail, @"1.8V_AON", YES, NO),
                   @"a fully bold <br/> line is one bold span");
        SPDFMarkdownDiagramLabel* part = SPDFMarkupLabel(layout, @"BUCK-1 buck 360 nA IQ");
        SPDFExpect(part != nil && SPDFMarkupSpanMatches(part, @"BUCK-1", YES, NO),
                   @"the second <br/> line bolds only its part number");

        // 4. Nesting: <b>bold <i>and slanted</i></b> is bold throughout and
        //    slanted only inside the inner tag.
        SPDFMarkdownDiagramLabel* mix = SPDFMarkupLabel(layout, @"bold and slanted tail");
        SPDFExpect(mix != nil, @"the nested label draws its text without markup");
        SPDFExpect(SPDFMarkupSpanMatches(mix, @"bold ", YES, NO) &&
                       SPDFMarkupSpanMatches(mix, @"and slanted", YES, YES),
                   @"nested <b><i> yields a bold span and a bold+italic span");

        // 5. A stray `<` (here from &lt;) and an unknown tag stay literal text.
        SPDFExpect(SPDFMarkupLabel(layout, @"a < b plus <notatag> kept") != nil,
                   @"a bare < and an unknown tag are drawn as the text they are");

        // 6. Measurement follows the runs: the markup contributes no width, and
        //    a bold run is measured in the face it is drawn in. Without this the
        //    reflow ladder sizes every node for characters it never draws.
        NSFont* body = [NSFont systemFontOfSize:12];
        NSFont* semibold = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        CGFloat measured = SPDFMarkdownDiagramMeasureText(@"<b>BUCK-1</b>", body, 400).width;
        CGFloat bold = ceil([@"BUCK-1" sizeWithAttributes:@{NSFontAttributeName: semibold}].width);
        CGFloat literal = ceil([@"<b>BUCK-1</b>" sizeWithAttributes:@{NSFontAttributeName: body}].width);
        SPDFExpect(fabs(measured - bold) < 0.51, @"a <b> run measures as the bold text it draws");
        SPDFExpect(measured < literal - 1, @"the tags themselves take no width");

        // 7. The canonical attributed string carries the run, so the selectable
        //    text, Cmd+F and the vector export all agree with the drawing.
        NSAttributedString* rendered =
            SPDFMarkupRender([NSString stringWithFormat:@"```mermaid\n%@```\n", source]);
        SPDFExpect(rendered != nil && ![rendered.string containsString:@"<b>"],
                   @"the canonical diagram text carries no markup");
        SPDFExpect(SPDFMarkupFontIsBold(SPDFMarkupFontAt(rendered, @"USB-C VBUS 5 V", 0)),
                   @"the canonical text is bold where the label is bold");
        SPDFExpect(!SPDFMarkupFontIsBold(SPDFMarkupFontAt(rendered, @"USB-C VBUS 5 V", 11)),
                   @"and plain again on the tail after </b>");
        SPDFExpect(SPDFMarkupFontIsItalic(SPDFMarkupFontAt(rendered, @"and slanted tail", 0)),
                   @"a nested <i> run is slanted in the canonical text");

        // 8. PROSE is a separate path and was never broken: markdown `**bold**`
        //    and an inline `<b>` island both style the body text. Pinned here so
        //    a change to the diagram label seam can never be mistaken for one.
        NSAttributedString* prose = SPDFMarkupRender(@"Star **bolded** and tag <b>tagged</b> here.\n");
        SPDFExpect(SPDFMarkupFontIsBold(SPDFMarkupFontAt(prose, @"bolded", 0)) &&
                       SPDFMarkupFontIsBold(SPDFMarkupFontAt(prose, @"tagged", 0)),
                   @"prose **bold** and <b>bold</b> both render bold");
        SPDFExpect(!SPDFMarkupFontIsBold(SPDFMarkupFontAt(prose, @"Star", 0)),
                   @"prose around them stays plain");
    }
    return SPDFFinishTests(@"SPDFMarkdownDiagramLabelMarkupTests");
}
