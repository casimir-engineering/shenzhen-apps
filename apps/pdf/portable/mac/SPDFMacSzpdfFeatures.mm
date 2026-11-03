// `szpdf features` (SPDFMacSzpdfInternal.h): what the reader renders, as data. The parts that live in tables in the
// renderer are read from them here (code languages, the HTML tag policy, the image budgets, diagram limits); the rest
// is written down below and held to the renderer by mac/tests/SPDFMacSzpdfTests.mm, which renders each example.
#import "SPDFMacSzpdfInternal.h"

// Long texts are written as adjacent literals inside array literals on purpose.
#pragma clang diagnostic ignored "-Wobjc-string-concatenation"
#import "markdown/SPDFMarkdownDiagram.h"
#import "markdown/SPDFMarkdownHTMLInternal.h"
#import "markdown/SPDFMarkdownLanguage.h"
#import "markdown/SPDFMarkdownRenderer.h"

static NSDictionary* F(NSString* format, NSString* area, NSString* name, NSString* support, NSString* notes,
                       NSString* example) {
    return @{@"format" : format, @"area" : area, @"name" : name, @"support" : support, @"notes" : notes,
             @"example" : example ?: @""};
}

// Markdown syntax: md4c with MD_DIALECT_GITHUB | MD_FLAG_WIKILINKS | MD_FLAG_LATEXMATHSPANS (SPDFMarkdownParser.mm).
static NSArray* MarkdownSyntax(void) {
    return @[
        F(@"md", @"syntax", @"headings", @"yes", @"ATX (#) and setext, levels 1-6; H1 and H2 are underlined", @"## Wiring"),
        F(@"md", @"syntax", @"emphasis, strong, inline code", @"yes", @"", @"*a* **b** `c`"),
        F(@"md", @"syntax", @"strikethrough", @"yes", @"GFM ~~text~~", @"~~old~~"),
        F(@"md", @"syntax", @"tables", @"yes", @"GFM pipes with :--- alignment; columns sized to their content, "
                                             @"at least 44 pt each; rows never split across pages, a row taller than "
                                             @"a page is drawn smaller", @"| a | b |\n|---|--:|\n| 1 | 2 |"),
        F(@"md", @"syntax", @"task lists", @"yes", @"drawn as ☐ / ☑", @"- [x] done\n- [ ] todo"),
        F(@"md", @"syntax", @"lists", @"yes", @"nested; ordered lists keep their start number", @"3. third\n4. fourth"),
        F(@"md", @"syntax", @"autolinks", @"yes", @"<url>, bare https://, www. and e-mail addresses", @"https://example.com"),
        F(@"md", @"syntax", @"links", @"partial", @"http(s) and mailto open outside; #heading scrolls to a heading by its "
                                               @"slug (lowercase, spaces to -); a relative .md/.markdown in the same "
                                               @"folder opens in the reader; anything else is blocked", @"[see](#power-rails)"),
        F(@"md", @"syntax", @"wiki links", @"partial", @"[[Note]] and [[Note|text]] open Note.md beside the document; "
                                                    @"[[Note#Heading]] does not open", @"[[Bring-up notes]]"),
        F(@"md", @"syntax", @"footnotes", @"no", @"[^1] shows as written", @"Text[^1]"),
        F(@"md", @"syntax", @"blockquotes", @"yes", @"", @"> quoted"),
        F(@"md", @"syntax", @"callouts", @"yes", @"GitHub alerts: > [!NOTE], [!TIP], [!WARNING] ... with an optional title",
          @"> [!WARNING] Hot\n> Do not touch."),
        F(@"md", @"syntax", @"code blocks", @"yes", @"fenced (``` or ~~~) and indented; highlighted when the fence names a "
                                                 @"language listed under \"code\"", @"```python\nprint(1)\n```"),
        F(@"md", @"syntax", @"thematic break", @"yes", @"", @"---"),
        F(@"md", @"syntax", @"hard line breaks", @"yes", @"two trailing spaces or a backslash; a single newline is a space",
          @"line one\\\nline two"),
        F(@"md", @"syntax", @"page break", @"yes", @"exactly <!-- pagebreak --> on its own line; other HTML comments are "
                                                @"hidden", @"<!-- pagebreak -->"),
        F(@"md", @"syntax", @"front matter", @"partial", @"--- key: value --- at the top; only the paper-* keys do anything "
                                                      @"(see \"page\")", @"---\npaper-size: A4\n---"),
        F(@"md", @"syntax", @"math", @"yes", @"$inline$ and $$display$$ LaTeX, typeset natively: scripts, \\frac, \\sqrt, "
                                          @"\\text, Greek; an unknown command shows as \\name. A ```math fence is plain "
                                          @"code", @"$E = mc^2$"),
        F(@"md", @"syntax", @"emoji", @"partial", @"Unicode emoji show as typed; :shortcodes: stay as text", @"✅"),
        F(@"md", @"syntax", @"smart quotes", @"no", @"quotes and dashes show as typed", @""),
        F(@"md", @"syntax", @"entities", @"yes", @"&amp; &lt; &gt; &quot; &apos; &nbsp; and numeric &#…;", @"&nbsp;"),
    ];
}

// The HTML tags whose fate is decided by SPDFMarkdownHTMLClassifyTag, plus the block tags the HTML-island translator
// knows (SPDFMarkdownHTMLBlocks.mm).
static NSArray* HTMLTags(void) {
    NSMutableArray* rows = [NSMutableArray array];
    NSDictionary* blockNotes = @{
        @"h1" : @"a real heading (h1-h6)", @"p" : @"a paragraph", @"table" : @"a table; td/th align is honoured; "
                                                                            @"colspan or rowspan above 1 turns the whole "
                                                                            @"table into plain rows; width and valign "
                                                                            @"are ignored",
        @"details" : @"always shown open; <summary> is a bold line starting with ▸", @"div" : @"its content; align= "
                                                                                          @"left|center|right is honoured",
        @"center" : @"centres its content", @"ul" : @"a list (ol start= is honoured)", @"pre" : @"a code block",
        @"blockquote" : @"a quote", @"hr" : @"a rule", @"figure" : @"its content (figcaption a paragraph)",
    };
    for (NSString* tag in [blockNotes.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [rows addObject:F(@"md", @"html", [NSString stringWithFormat:@"<%@>", tag],
                          [tag isEqual:@"table"] || [tag isEqual:@"details"] ? @"partial" : @"yes", blockNotes[tag],
                          [tag isEqual:@"div"] ? @"<div align=\"center\">\n\n![logo](img/logo.png)\n\n</div>" : @"")];
    NSArray* inlineTags = @[ @"a", @"b", @"br", @"code", @"del", @"em", @"i", @"img", @"ins", @"kbd", @"mark", @"s",
                             @"samp", @"strike", @"strong", @"sub", @"sup", @"tt", @"u", @"span", @"font", @"script",
                             @"style", @"iframe", @"svg", @"video", @"audio", @"form", @"input", @"meta", @"link" ];
    for (NSString* tag in inlineTags) {
        NSString *support = @"yes", *notes = @"";
        switch (SPDFMarkdownHTMLClassifyTag(tag)) {
            case SPDFMarkdownHTMLTagClassDropWithContent:
                support = @"no", notes = @"removed together with everything inside it";
                break;
            case SPDFMarkdownHTMLTagClassDropVoid: support = @"no", notes = @"removed"; break;
            case SPDFMarkdownHTMLTagClassInlineTrait: notes = @"styles its text"; break;
            case SPDFMarkdownHTMLTagClassAnchor: notes = @"href http(s), mailto or #heading; title is a tooltip"; break;
            case SPDFMarkdownHTMLTagClassImage:
                notes = @"src, alt, title, width and height (a number or Npx: a largest size, never larger than the "
                        @"picture or the column; one alone keeps the proportions)";
                break;
            case SPDFMarkdownHTMLTagClassLineBreak: notes = @"a line break"; break;
            case SPDFMarkdownHTMLTagClassPassThrough:
                support = @"partial", notes = @"the tag is ignored, its content shows unstyled";
                break;
        }
        [rows addObject:F(@"md", @"html", [NSString stringWithFormat:@"<%@>", tag], support, notes,
                          [tag isEqual:@"img"] ? @"<img src=\"img/board.png\" width=\"300\" alt=\"Board\">" : @"")];
    }
    [rows addObject:F(@"md", @"html", @"attributes", @"partial", @"read: href, src, alt, title, align, width and height "
                                                                 @"(img only), start, colspan, rowspan; style, class, "
                                                                 @"id, valign, color and every other attribute are "
                                                                 @"ignored", @"")];
    return rows;
}

static NSArray* Images(SPDFMarkdownRenderOptions* options) {
    return @[
        F(@"md", @"images", @"local images", @"yes", @"a relative path inside the document's folder (subfolders too); "
                                                  @"not /absolute, ~, .. or ?query", @"![Board](img/board.png)"),
        F(@"md", @"images", @"formats", @"yes", @"whatever ImageIO reads (PNG, JPEG, GIF first frame, HEIC, TIFF, WebP, "
                                             @"BMP); SVG through NSImage", @""),
        F(@"md", @"images", @"remote images", @"partial", @"https only, fetched when shown (20 MB, 20 s each); an empty "
                                                       @"box in szpdf pictures and checks, [Image: alt] in documents "
                                                       @"others sent", @""),
        F(@"md", @"images", @"data: URIs", @"no", @"shown as [Image: alt]", @""),
        F(@"md", @"images", @"sizing", @"yes", @"never enlarged; shrunk to the column width and the page height; images "
                                            @"side by side share one factor, at least 0.45; a lone image is a centred "
                                            @"figure captioned with its title or alt", @""),
        F(@"md", @"images", @"decoded-pixel budget", @"partial",
          [NSString stringWithFormat:@"%lu pixels (width x height, added up) per document, in order; images past it, "
                                     @"missing or unreadable show as \"[Image: alt]\" (szpdf check lists them)",
                                     (unsigned long)options.maximumDecodedImagePixels],
          @""),
        F(@"md", @"images", @"file budget",
          @"partial", [NSString stringWithFormat:@"%lu bytes of local image files per document",
                                                 (unsigned long)options.maximumResourceBytes],
          @""),
        F(@"md", @"images", @"dark theme", @"yes", @"the reader's dark theme remaps every image's lightness (pictures "
                                                @"over 8192 px a side are left alone) unless the tab keeps image "
                                                @"colours; print, export and szpdf pictures stay light", @""),
    ];
}

static NSArray* Diagrams(void) {
    NSString* limits = [NSString stringWithFormat:@"drawn natively as selectable text and shapes; at most %lu nodes, %lu "
                                                  @"edges, %.0f pt a side; a syntax error, an unknown type or a diagram "
                                                  @"over budget shows as code",
                                                  (unsigned long)SPDFMarkdownDiagramMaximumNodes,
                                                  (unsigned long)SPDFMarkdownDiagramMaximumEdges,
                                                  SPDFMarkdownDiagramMaximumDimension];
    return @[
        F(@"md", @"diagrams", @"mermaid", @"partial", [@"flowchart/graph, sequenceDiagram, pie, stateDiagram(-v2), "
                                                       @"classDiagram, gantt; " stringByAppendingString:limits],
          @"```mermaid\nflowchart LR\n  A --> B\n```"),
        F(@"md", @"diagrams", @"sequence (js-sequence)", @"yes", @"a ```sequence fence", @"```sequence\nA->B: hi\n```"),
        F(@"md", @"diagrams", @"flow (flowchart.js)", @"yes", @"a ```flow fence", @""),
        F(@"md", @"diagrams", @"graphviz, plantuml", @"no", @"shown as code", @""),
    ];
}

static NSArray* Code(void) {
    NSMutableArray* rows = [NSMutableArray array];
    for (SPDFMarkdownLanguage* language in SPDFMarkdownLanguageCatalog.sharedCatalog.languages)
        [rows addObject:F(@"md", @"code", language.identifier, @"yes",
                          language.aliases.count ? [@"also " stringByAppendingString:[language.aliases componentsJoinedByString:@", "]]
                                                 : @"",
                          [NSString stringWithFormat:@"```%@", language.identifier])];
    [rows addObject:F(@"md", @"code", @"other languages", @"partial", @"shown uncoloured; the reader can pick a language", @"")];
    return rows;
}

static NSArray* Pages(void) {
    return @[
        F(@"md", @"page", @"paper-size", @"yes", @"A3, A4 (default), A5, Letter, Legal", @"paper-size: Letter"),
        F(@"md", @"page", @"paper-orientation", @"yes", @"portrait (default) or landscape; the reader can also turn it",
          @"paper-orientation: landscape"),
        F(@"md", @"page", @"paper-margin", @"yes", @"points (72 per inch), all sides or paper-margin-top/-right/-bottom/"
                                                @"-left; default 61.2; at least 72 pt must remain", @"paper-margin: 36"),
        F(@"md", @"page", @"pagination", @"yes", @"a heading low on a page moves to the next page with its section; "
                                              @"diagrams and image rows stay whole; anything taller than a page is drawn "
                                              @"smaller", @""),
        F(@"md", @"comments", @"comments file", @"yes", @"\"<name> - comments.md\" beside the document: one block per "
                                                     @"comment between --- rules (location line, > quote with the "
                                                     @"**commented words**, byline with a hidden exact time, text, "
                                                     @"- reply items); unplaced ones under ## Unplaced", @""),
        F(@"pdf", @"pdf", @"reading", @"yes", @"any PDF MuPDF opens; password PDFs ask in the reader (szpdf refuses "
                                           @"them)", @""),
        F(@"pdf", @"pdf", @"outline", @"yes", @"the PDF's bookmarks are its headings (szpdf headings, open --heading); "
                                           @"named destinations also work with --heading", @""),
        F(@"pdf", @"pdf", @"comments", @"yes", @"annotations in the file: highlights, notes, replies (/IRT), resolved as "
                                            @"the review state Acrobat and Preview use", @""),
        F(@"pdf", @"pdf", @"scanned pages", @"partial", @"shown; their text is searchable only after OCR in the reader", @""),
        F(@"pdf", @"pdf", @"dark theme", @"yes", @"pages recoloured; images optional", @""),
    ];
}

NSDictionary* SPDFMacSzpdfFeatures(NSString* format) {
    SPDFMarkdownRenderOptions* options = [SPDFMarkdownRenderOptions defaultOptions];
    NSMutableArray* all = [NSMutableArray array];
    for (NSArray* part in @[ MarkdownSyntax(), HTMLTags(), Images(options), Diagrams(), Code(), Pages() ])
        [all addObjectsFromArray:part];
    NSMutableArray* chosen = [NSMutableArray array];
    for (NSDictionary* feature in all)
        if ([format isEqualToString:@"all"] || [feature[@"format"] isEqualToString:format]) [chosen addObject:feature];
    return @{
        @"format" : format,
        @"features" : chosen,
        @"limits" : @{
            @"decodedImagePixels" : @(options.maximumDecodedImagePixels),
            @"imageBytes" : @(options.maximumResourceBytes),
            @"diagramNodes" : @(SPDFMarkdownDiagramMaximumNodes),
            @"diagramEdges" : @(SPDFMarkdownDiagramMaximumEdges),
            @"diagramPoints" : @(SPDFMarkdownDiagramMaximumDimension),
            @"tableColumnMinimumPoints" : @44,
        },
        @"notes" : @"Markdown and text files are laid out at their own paper settings; szpdf check <file.md> says what the "
                   @"reader will do with one file.",
    };
}
