#import "SPDFMarkdownTestSupport.h"

#import "../../markdown/SPDFMarkdownDiagramInternal.h"
#import "../../markdown/SPDFMarkdownDocument.h"
#import "../../markdown/SPDFMarkdownPaginator.h"
#import "../../markdown/SPDFMarkdownParser.h"
#import "../../markdown/SPDFMarkdownRenderer.h"
#import "../../markdown/SPDFMarkdownDecorations.h"

// Basic HTML formatting, in body text and inside diagram labels.
//
// `<b>`, `<i>`, `<s>`/`<del>`, `<code>`, `<kbd>`, `<sub>`/`<sup>` were honored;
// `<u>`, `<ins>` and `<mark>` were not, and a diagram label understood only
// weight and slant. Measured before the fix by rasterizing a sheet and counting
// non-paper pixels: `<u>text</u>` painted exactly as much ink as `text` (1035
// either way) while a link's underline painted 1297 -- proof the drawing path
// honors the attribute and the tag was simply never mapped to one.
//
// So each case here asserts BOTH halves: the trait reaches the canonical string
// AND the sheet gains ink. A trait that is set but never drawn passes the first
// and fails the second.

static NSAttributedString* SPDFRenderCanonical(NSString* markdown, SPDFMarkdownThemeVariant variant) {
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] parseString:markdown sourceURL:nil error:nil];
    if (!model) return nil;
    SPDFMarkdownRenderOptions* options = [SPDFMarkdownRenderOptions defaultOptionsForThemeVariant:variant];
    SPDFMarkdownDocument* document = [[SPDFMarkdownDocument alloc] initWithModel:model options:options];
    return document.renderedDocument.attributedString;
}

static id SPDFAttributeAt(NSAttributedString* text, NSString* needle, NSAttributedStringKey key) {
    NSRange range = [text.string rangeOfString:needle];
    if (range.location == NSNotFound) return nil;
    return [text attribute:key atIndex:range.location effectiveRange:NULL];
}

// Non-paper pixels on the first sheet: what the reader actually sees.
static NSUInteger SPDFInkForMarkdown(NSString* markdown) {
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] parseString:markdown sourceURL:nil error:nil];
    SPDFMarkdownDocument* document =
        [[SPDFMarkdownDocument alloc] initWithModel:model options:SPDFMarkdownRenderOptions.defaultOptions];
    SPDFMarkdownRenderedDocument* rendered = document.renderedDocument;
    SPDFMarkdownPageConfiguration* configuration = [SPDFMarkdownPageConfiguration A4PortraitConfiguration];
    SPDFMarkdownPaginator* paginator = [SPDFMarkdownPaginator new];
    SPDFMarkdownPaginationPlan* plan =
        [paginator paginateItems:[paginator measureRenderedDocument:rendered
                                                     containerWidth:NSWidth(configuration.printableRect)]
                   configuration:configuration];
    size_t width = (size_t)configuration.paperSize.width;
    size_t height = (size_t)configuration.paperSize.height;
    unsigned char* pixels = (unsigned char*)calloc(width * height, 4);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context =
        CGBitmapContextCreate(pixels, width, height, 8, width * 4, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    NSUInteger inked = 0;
    if (context) {
        [plan drawPageAtIndex:0 attributedString:rendered.attributedString inContext:context];
        unsigned char* paper = pixels;  // the top-left corner is never written on
        for (size_t i = 0; i < width * height; ++i) {
            unsigned char* p = pixels + i * 4;
            if (p[0] != paper[0] || p[1] != paper[1] || p[2] != paper[2]) ++inked;
        }
        CGContextRelease(context);
    }
    free(pixels);
    return inked;
}

static SPDFMarkdownDiagramLabelSpan* SPDFSpanCovering(SPDFMarkdownDiagramLabel* label, NSString* needle) {
    NSRange expected = [label.text rangeOfString:needle];
    if (expected.location == NSNotFound) return nil;
    for (SPDFMarkdownDiagramLabelSpan* span in label.spans)
        if (NSEqualRanges(span.range, expected)) return span;
    return nil;
}

static SPDFMarkdownDiagramLabel* SPDFLabelWithText(SPDFMarkdownDiagramLayout* layout, NSString* text) {
    for (SPDFMarkdownDiagramLabel* label in layout.labels)
        if ([label.text isEqualToString:text]) return label;
    return nil;
}

int main(void) {
    @autoreleasepool {
        NSString* plain = @"AAAA BBBB CCCC\n";
        NSUInteger plainInk = SPDFInkForMarkdown(plain);
        SPDFExpect(plainInk > 0, @"the control line paints something");

        // --- Underline: <u> and <ins> ---------------------------------------
        for (NSString* tag in @[ @"u", @"ins" ]) {
            NSString* source = [NSString stringWithFormat:@"<%@>AAAA BBBB CCCC</%@>\n", tag, tag];
            NSAttributedString* canonical = SPDFRenderCanonical(source, SPDFMarkdownThemeVariantLight);
            SPDFExpect(![canonical.string containsString:@"<"],
                       ([NSString stringWithFormat:@"<%@> never reaches drawn text", tag]));
            NSNumber* underline = SPDFAttributeAt(canonical, @"AAAA", NSUnderlineStyleAttributeName);
            SPDFExpect(underline.integerValue != 0,
                       ([NSString stringWithFormat:@"<%@> sets the underline attribute", tag]));
            SPDFExpect(SPDFInkForMarkdown(source) > plainInk,
                       ([NSString stringWithFormat:@"<%@> actually paints an underline on the sheet", tag]));
        }

        // --- Highlight: <mark> ----------------------------------------------
        NSString* marked = @"<mark>AAAA BBBB CCCC</mark>\n";
        NSAttributedString* markCanonical = SPDFRenderCanonical(marked, SPDFMarkdownThemeVariantLight);
        SPDFExpect(![markCanonical.string containsString:@"<mark>"], @"<mark> never reaches drawn text");
        NSColor* background = SPDFAttributeAt(markCanonical, @"AAAA", NSBackgroundColorAttributeName);
        SPDFExpect(background != nil, @"<mark> sets a background color");
        SPDFExpect([background isEqual:[SPDFMarkdownTheme themeForVariant:SPDFMarkdownThemeVariantLight]
                                          .markHighlightColor],
                   @"<mark> uses the theme's highlight role, not an ad-hoc color");
        SPDFExpect(SPDFInkForMarkdown(marked) > plainInk, @"<mark> actually paints its background");
        // The dark palette is its own concrete color, like every other role.
        NSColor* darkBackground = SPDFAttributeAt(SPDFRenderCanonical(marked, SPDFMarkdownThemeVariantDark), @"AAAA",
                                                  NSBackgroundColorAttributeName);
        SPDFExpect(darkBackground != nil && ![darkBackground isEqual:background],
                   @"the dark theme highlights with its own color");

        // --- Strikethrough stays working (it did; this guards it) ------------
        for (NSString* source in @[ @"<s>AAAA BBBB CCCC</s>\n", @"<del>AAAA BBBB CCCC</del>\n",
                                    @"<strike>AAAA BBBB CCCC</strike>\n", @"~~AAAA BBBB CCCC~~\n" ]) {
            NSAttributedString* canonical = SPDFRenderCanonical(source, SPDFMarkdownThemeVariantLight);
            NSNumber* strike = SPDFAttributeAt(canonical, @"AAAA", NSStrikethroughStyleAttributeName);
            SPDFExpect(strike.integerValue != 0, @"strikethrough markup sets the attribute");
            SPDFExpect(SPDFInkForMarkdown(source) > plainInk, @"strikethrough paints its line");
        }

        // --- Combined, and inside a table cell (the HTML islands path) -------
        NSAttributedString* combined =
            SPDFRenderCanonical(@"<b><u>BOLDUNDER</u></b> and <mark><code>MARKCODE</code></mark>\n",
                                SPDFMarkdownThemeVariantLight);
        SPDFExpect([[combined attribute:NSUnderlineStyleAttributeName
                                atIndex:[combined.string rangeOfString:@"BOLDUNDER"].location
                         effectiveRange:NULL] integerValue] != 0,
                   @"<b><u> keeps the underline as well as the weight");
        NSColor* markedCode = SPDFAttributeAt(combined, @"MARKCODE", NSBackgroundColorAttributeName);
        SPDFExpect([markedCode isEqual:[SPDFMarkdownTheme themeForVariant:SPDFMarkdownThemeVariantLight]
                                           .markHighlightColor],
                   @"<mark> around <code> wins over the quieter code chip");
        NSAttributedString* inTable =
            SPDFRenderCanonical(@"| H |\n| --- |\n| <u>CELLUNDER</u> |\n", SPDFMarkdownThemeVariantLight);
        SPDFExpect([[inTable attribute:NSUnderlineStyleAttributeName
                               atIndex:[inTable.string rangeOfString:@"CELLUNDER"].location
                        effectiveRange:NULL] integerValue] != 0,
                   @"a table cell underlines too");

        // --- Diagram labels --------------------------------------------------
        NSString* diagram = @"flowchart LR\n"
                             "  A[\"<u>RAIL</u> up\"]\n"
                             "  B[\"<s>OLD</s> gone\"]\n"
                             "  C[\"<b><u>BOTH</u></b> set\"]\n"
                             "  A --> B --> C\n";
        SPDFMarkdownDiagramLayout* layout = SPDFMarkdownDiagramRender(@"mermaid", diagram, NSMakeSize(1200, 0), 1.0,
                                                                      nil);
        SPDFExpect(layout != nil && layout.labels.count > 0, @"the diagram lays out");
        for (SPDFMarkdownDiagramLabel* label in layout.labels)
            for (NSString* tag in @[ @"<u>", @"</u>", @"<s>", @"</s>", @"<ins>", @"<del>" ])
                SPDFExpect(![label.text containsString:tag], @"no diagram label draws a formatting tag");

        SPDFMarkdownDiagramLabelSpan* rail = SPDFSpanCovering(SPDFLabelWithText(layout, @"RAIL up"), @"RAIL");
        SPDFExpect(rail.underline && !rail.strikethrough && !rail.bold, @"<u> in a label is an underline span");
        SPDFMarkdownDiagramLabelSpan* old = SPDFSpanCovering(SPDFLabelWithText(layout, @"OLD gone"), @"OLD");
        SPDFExpect(old.strikethrough && !old.underline, @"<s> in a label is a strikethrough span");
        SPDFMarkdownDiagramLabelSpan* both = SPDFSpanCovering(SPDFLabelWithText(layout, @"BOTH set"), @"BOTH");
        SPDFExpect(both.bold && both.underline, @"<b><u> in a label is bold AND underlined");

        // ...and the label's canonical text carries the attributes, which is what
        // the band, the page and the PDF export all draw from.
        NSAttributedString* diagramCanonical =
            SPDFRenderCanonical([NSString stringWithFormat:@"```mermaid\n%@```\n", diagram],
                                SPDFMarkdownThemeVariantLight);
        SPDFExpect([[diagramCanonical attribute:NSUnderlineStyleAttributeName
                                        atIndex:[diagramCanonical.string rangeOfString:@"RAIL"].location
                                 effectiveRange:NULL] integerValue] != 0,
                   @"the diagram's canonical text underlines the <u> span");
        SPDFExpect([[diagramCanonical attribute:NSStrikethroughStyleAttributeName
                                        atIndex:[diagramCanonical.string rangeOfString:@"OLD"].location
                                 effectiveRange:NULL] integerValue] != 0,
                   @"the diagram's canonical text strikes the <s> span");
    }
    return SPDFFinishTests(@"SPDFMarkdownInlineFormattingTests");
}
