// `szpdf check` (SPDFMacSzpdfInternal.h): what the reader will do with a Markdown file, from the reader's own code
// where it can be asked (the image store and its decoder, the HTML tag policy, the diagram renderer, the layout's
// diagnostics, comment anchoring) and from the source text for the rest (links, attributes, footnotes).
#import "SPDFMacSzpdfInternal.h"
#import "SPDFMacMarkdownComments.h"
#import "SPDFMacMarkdownRouting.h"
#import "markdown/SPDFMarkdownAuthoring.h"
#import "markdown/SPDFMarkdownDiagram.h"
#import "markdown/SPDFMarkdownHTMLInternal.h"
#import "markdown/SPDFMarkdownPaginator.h"
#import "markdown/SPDFMarkdownParser.h"
#import "markdown/SPDFMarkdownPicture.h"
#import "markdown/SPDFMarkdownRenderer.h"
#import "markdown/SPDFMarkdownResources.h"


@interface SPDFMacSzpdfChecker : NSObject
@property(nonatomic) SPDFMacSzpdfDocument* document;
@property(nonatomic) NSArray<NSString*>* lines;
@property(nonatomic) NSMutableArray* issues;
@property(nonatomic) NSMutableIndexSet* hiddenLines;  // fenced code and front matter, 1-based
@end

@implementation SPDFMacSzpdfChecker

- (void)add:(NSString*)severity line:(NSInteger)line code:(NSString*)code message:(NSString*)message {
    [self.issues addObject:@{@"severity" : severity, @"line" : line > 0 ? @(line) : NSNull.null, @"code" : code,
                             @"message" : message}];
}

- (void)indexLines {
    self.hiddenLines = [NSMutableIndexSet indexSet];
    BOOL fenced = NO, front = self.lines.count && [self.lines[0] isEqualToString:@"---"];
    for (NSUInteger i = 0; i < self.lines.count; i++) {
        NSString* trimmed = [self.lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        BOOL fence = [trimmed hasPrefix:@"```"] || [trimmed hasPrefix:@"~~~"];
        if (front || fence || fenced) [self.hiddenLines addIndex:i + 1];
        if (front && i > 0 && ([trimmed isEqualToString:@"---"] || [trimmed isEqualToString:@"..."])) front = NO;
        if (fence) fenced = !fenced;
    }
}

// The first visible source line at or after `from` that holds `needle`.
- (NSInteger)lineOf:(NSString*)needle from:(NSInteger)from {
    for (NSInteger i = MAX(1, from); i <= (NSInteger)self.lines.count; i++)
        if (![self.hiddenLines containsIndex:(NSUInteger)i] && [self.lines[(NSUInteger)i - 1] containsString:needle])
            return i;
    return 0;
}

static void CollectImages(NSArray<SPDFMarkdownBlock*>* blocks, NSMutableArray<SPDFMarkdownInlineRun*>* out) {
    for (SPDFMarkdownBlock* block in blocks) {
        for (SPDFMarkdownInlineRun* run in block.runs)
            if ((run.traits & SPDFMarkdownInlineTraitImage) && run.destination.length) [out addObject:run];
        CollectImages(block.children, out);
    }
}

static void CollectCode(NSArray<SPDFMarkdownBlock*>* blocks, NSMutableArray<SPDFMarkdownBlock*>* out) {
    for (SPDFMarkdownBlock* block in blocks) {
        if (block.kind == SPDFMarkdownBlockKindCode) [out addObject:block];
        CollectCode(block.children, out);
    }
}

static void CollectTables(NSArray<SPDFMarkdownBlock*>* blocks, NSMutableArray<SPDFMarkdownBlock*>* out) {
    for (SPDFMarkdownBlock* block in blocks) {
        if (block.kind == SPDFMarkdownBlockKindTable) [out addObject:block];
        else CollectTables(block.children, out);
    }
}

static NSUInteger CountRows(SPDFMarkdownBlock* block) {
    NSUInteger rows = block.kind == SPDFMarkdownBlockKindTableRow;
    for (SPDFMarkdownBlock* child in block.children) rows += CountRows(child);
    return rows;
}

// Whether the reader can draw `image`: a picture is decoded here the way a page
// decodes it, small.
static BOOL Decodes(NSImage* image) {
    SPDFMarkdownPictureRep* picture = SPDFMarkdownPictureRepForImage(image);
    if (!picture) return image != nil;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, 8, 8, 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGImageRef decoded = context ? [picture copyImageForContext:context size:CGSizeMake(8, 8) variant:NULL] : NULL;
    if (context) CGContextRelease(context);
    if (decoded) CGImageRelease(decoded);
    return decoded != NULL;
}

- (void)checkImages {
    SPDFMarkdownDocumentModel* model = self.document.model;
    SPDFMarkdownRenderOptions* options = [SPDFMarkdownRenderOptions defaultOptions];
    SPDFMarkdownResourceStore* store =
        [[SPDFMarkdownResourceStore alloc] initWithDocumentURL:[NSURL fileURLWithPath:self.document.path]
                                          maximumResourceBytes:options.maximumResourceBytes];
    NSMutableArray<SPDFMarkdownInlineRun*>* images = [NSMutableArray array];
    CollectImages(model.blocks, images);
    NSString* folder = self.document.path.stringByDeletingLastPathComponent;
    NSMutableDictionary<NSString*, NSNumber*>* searchFrom = [NSMutableDictionary dictionary];
    for (SPDFMarkdownInlineRun* run in images) {
        NSString* target = run.destination;
        NSInteger line = [self lineOf:target from:searchFrom[target].integerValue];
        if (line) searchFrom[target] = @(line + 1);
        NSString* shown = [NSString stringWithFormat:@"[Image: %@]", run.text.length ? run.text : @"untitled"];
        NSString* scheme = [NSURL URLWithString:target].scheme.lowercaseString;
        if ([scheme isEqualToString:@"https"]) {
            [self add:@"info" line:line code:@"remote-image"
                message:[NSString stringWithFormat:@"%@ is downloaded when the document is shown; it is not checked "
                                                   @"here.", target]];
            continue;
        }
        if (scheme.length || [target hasPrefix:@"/"] || [target hasPrefix:@"~"] || [target containsString:@".."]) {
            [self add:@"error" line:line code:@"image-not-allowed"
                message:[NSString stringWithFormat:@"%@ shows as %@: only https addresses and paths inside the "
                                                   @"document's folder are drawn.", target, shown]];
            continue;
        }
        NSString* decoded = [[target componentsSeparatedByString:@"#"].firstObject stringByRemovingPercentEncoding] ?: target;
        NSString* file = [folder stringByAppendingPathComponent:decoded];
        if (![NSFileManager.defaultManager fileExistsAtPath:file]) {
            [self add:@"error" line:line code:@"image-missing"
                message:[NSString stringWithFormat:@"%@ does not exist; it shows as %@.", target, shown]];
            continue;
        }
        NSImage* image = [store imageForTarget:target resolvedURL:NULL];
        if (Decodes(image)) continue;
        [self add:@"error" line:line code:@"image-unreadable"
            message:[NSString stringWithFormat:@"%@ could not be read as a picture (or the file is over %lu bytes); "
                                               @"it shows as %@.", target,
                                               (unsigned long)options.maximumResourceBytes,
                                               image ? @"an empty space" : shown]];
    }
}

- (void)checkHTML {
    static NSRegularExpression *tagPattern, *attributePattern, *codeSpan;
    static NSSet *blockTags, *readAttributes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      tagPattern = [NSRegularExpression regularExpressionWithPattern:@"<([A-Za-z][A-Za-z0-9-]*)((?:\\s+[^<>]*?)?)\\s*/?>"
                                                             options:0 error:nil];
      attributePattern = [NSRegularExpression regularExpressionWithPattern:@"([A-Za-z_:][-A-Za-z0-9_:.]*)\\s*(?:=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+))?"
                                                                  options:0 error:nil];
      codeSpan = [NSRegularExpression regularExpressionWithPattern:@"`[^`]*`" options:0 error:nil];
      blockTags = [NSSet setWithArray:@[ @"h1", @"h2", @"h3", @"h4", @"h5", @"h6", @"p", @"hr", @"blockquote", @"ul", @"ol",
                                         @"li", @"pre", @"table", @"thead", @"tbody", @"tfoot", @"tr", @"th", @"td",
                                         @"caption", @"details", @"summary", @"div", @"center", @"section", @"article",
                                         @"main", @"figure", @"figcaption", @"aside", @"header", @"footer", @"nav",
                                         @"dl", @"dt", @"dd" ]];
      readAttributes = [NSSet setWithArray:@[ @"href", @"src", @"alt", @"title", @"align", @"width", @"height", @"start",
                                              @"colspan", @"rowspan" ]];
    });
    NSMutableSet* reported = [NSMutableSet set];
    for (NSUInteger index = 0; index < self.lines.count; index++) {
        if ([self.hiddenLines containsIndex:index + 1]) continue;
        NSString* line = [codeSpan stringByReplacingMatchesInString:self.lines[index] options:0
                                                              range:NSMakeRange(0, self.lines[index].length) withTemplate:@""];
        if ([line hasPrefix:@"    "] || [line hasPrefix:@"\t"]) continue;  // indented code
        for (NSTextCheckingResult* match in [tagPattern matchesInString:line options:0 range:NSMakeRange(0, line.length)]) {
            NSString* tag = [line substringWithRange:[match rangeAtIndex:1]].lowercaseString;
            NSString* attributes = [line substringWithRange:[match rangeAtIndex:2]];
            SPDFMarkdownHTMLTagClass kind = SPDFMarkdownHTMLClassifyTag(tag);
            NSString* key = [NSString stringWithFormat:@"%lu %@", (unsigned long)index, tag];
            if ([reported containsObject:key]) continue;
            [reported addObject:key];
            if (kind == SPDFMarkdownHTMLTagClassDropWithContent)
                [self add:@"warning" line:(NSInteger)index + 1 code:@"html-dropped"
                    message:[NSString stringWithFormat:@"<%@> and everything inside it is not shown.", tag]];
            else if (kind == SPDFMarkdownHTMLTagClassDropVoid)
                [self add:@"warning" line:(NSInteger)index + 1 code:@"html-dropped"
                    message:[NSString stringWithFormat:@"<%@> is not shown.", tag]];
            else if (kind == SPDFMarkdownHTMLTagClassPassThrough && ![blockTags containsObject:tag])
                [self add:@"info" line:(NSInteger)index + 1 code:@"html-ignored"
                    message:[NSString stringWithFormat:@"<%@> has no effect; its content shows unstyled.", tag]];
            for (NSTextCheckingResult* pair in [attributePattern matchesInString:attributes options:0
                                                                          range:NSMakeRange(0, attributes.length)]) {
                NSString* name = [attributes substringWithRange:[pair rangeAtIndex:1]].lowercaseString;
                NSString* value = [pair rangeAtIndex:2].location == NSNotFound
                                      ? @""
                                      : [[attributes substringWithRange:[pair rangeAtIndex:2]]
                                            stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\"'"]];
                BOOL sizeOutsideImage = ([name isEqual:@"width"] || [name isEqual:@"height"]) && ![tag isEqual:@"img"];
                if (![readAttributes containsObject:name] || sizeOutsideImage)
                    [self add:@"info" line:(NSInteger)index + 1 code:@"html-attribute-ignored"
                        message:[NSString stringWithFormat:@"%@= on <%@> is ignored.", name, tag]];
                else if (([name isEqual:@"colspan"] || [name isEqual:@"rowspan"]) && value.integerValue > 1)
                    [self add:@"warning" line:(NSInteger)index + 1 code:@"html-table-span"
                        message:[NSString stringWithFormat:@"%@=%@: a table with merged cells is shown as plain rows.",
                                                           name, value]];
            }
        }
    }
}

- (void)checkHeadingsAndLinks {
    NSMutableDictionary<NSString*, NSNumber*>* firstLine = [NSMutableDictionary dictionary];
    NSMutableSet* slugs = [NSMutableSet set];
    for (NSDictionary* heading in self.document.headings) {
        [slugs addObject:spdf_mac_markdown_heading_slug(heading[@"title"])];
        NSString* key = [heading[@"title"] lowercaseString];
        NSInteger line = [heading[@"line"] isKindOfClass:NSNumber.class] ? [heading[@"line"] integerValue] : 0;
        if (firstLine[key])
            [self add:@"warning" line:line code:@"duplicate-heading"
                message:[NSString stringWithFormat:@"“%@” is also the heading at line %@: --heading needs its path "
                                                   @"(\"%@\") and a #link reaches only the first.",
                                                   heading[@"title"], firstLine[key],
                                                   [heading[@"path"] componentsJoinedByString:@" › "]]];
        else firstLine[key] = @(line);
    }
    static NSRegularExpression *link, *footnote;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      link = [NSRegularExpression regularExpressionWithPattern:@"(?<!!)\\[[^\\]]*\\]\\(\\s*<?([^)\\s>]+)>?(?:\\s+\"[^\"]*\")?\\s*\\)"
                                                       options:0 error:nil];
      footnote = [NSRegularExpression regularExpressionWithPattern:@"\\[\\^[^\\]]+\\]" options:0 error:nil];
    });
    NSString* folder = self.document.path.stringByDeletingLastPathComponent;
    for (NSUInteger index = 0; index < self.lines.count; index++) {
        if ([self.hiddenLines containsIndex:index + 1]) continue;
        static NSRegularExpression* codeSpan;
        if (!codeSpan) codeSpan = [NSRegularExpression regularExpressionWithPattern:@"`[^`]*`" options:0 error:nil];
        NSString* line = [codeSpan stringByReplacingMatchesInString:self.lines[index] options:0
                                                              range:NSMakeRange(0, self.lines[index].length) withTemplate:@""];
        NSInteger number = (NSInteger)index + 1;
        if ([footnote firstMatchInString:line options:0 range:NSMakeRange(0, line.length)])
            [self add:@"warning" line:number code:@"footnote" message:@"Footnotes are not supported: [^…] shows as written."];
        for (NSTextCheckingResult* match in [link matchesInString:line options:0 range:NSMakeRange(0, line.length)]) {
            NSString* target = [line substringWithRange:[match rangeAtIndex:1]];
            NSString* scheme = [NSURL URLWithString:target].scheme.lowercaseString;
            if ([@[ @"http", @"https", @"mailto" ] containsObject:scheme ?: @""]) continue;
            if ([target hasPrefix:@"#"]) {
                NSString* anchor = [[target substringFromIndex:1] stringByRemovingPercentEncoding] ?: @"";
                if (![slugs containsObject:spdf_mac_markdown_heading_slug(anchor)])
                    [self add:@"error" line:number code:@"broken-anchor"
                        message:[NSString stringWithFormat:@"%@ names no heading here (a heading's anchor is its title in "
                                                           @"lowercase with spaces as -).", target]];
                continue;
            }
            if (scheme.length) {
                [self add:@"warning" line:number code:@"link-blocked"
                    message:[NSString stringWithFormat:@"%@: the reader opens only http(s), mailto, #headings and .md "
                                                       @"files in the same folder.", target]];
                continue;
            }
            NSString* file = [[target componentsSeparatedByString:@"#"].firstObject stringByRemovingPercentEncoding] ?: target;
            NSString* full = [folder stringByAppendingPathComponent:file];
            if (![NSFileManager.defaultManager fileExistsAtPath:full])
                [self add:@"error" line:number code:@"broken-link"
                    message:[NSString stringWithFormat:@"%@ does not exist.", file]];
            else if (![@[ @"md", @"markdown", @"mdown" ] containsObject:file.pathExtension.lowercaseString] ||
                     [file hasPrefix:@"/"] || [file containsString:@".."])
                [self add:@"warning" line:number code:@"link-blocked"
                    message:[NSString stringWithFormat:@"%@: the reader opens only Markdown files in the document's "
                                                       @"folder.", file]];
        }
    }
}

- (void)checkCodeAndLayout {
    NSMutableArray<SPDFMarkdownBlock*>* code = [NSMutableArray array];
    CollectCode([self.document.model blocks], code);
    SPDFMarkdownPaginationPlan* plan = self.document.plan;
    NSInteger from = 1;
    for (SPDFMarkdownBlock* block in code) {
        NSString* fence = block.codeInfo ?: block.codeLanguage ?: @"";
        NSString* language = [[fence componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                                  .firstObject lowercaseString] ?: @"";
        NSInteger line = 0;
        for (NSInteger i = from; i <= (NSInteger)self.lines.count && language.length; i++)
            if ([self.lines[(NSUInteger)i - 1] containsString:@"```"] || [self.lines[(NSUInteger)i - 1] containsString:@"~~~"])
                if ([self.lines[(NSUInteger)i - 1].lowercaseString containsString:language]) { line = i; from = i + 1; break; }
        if (SPDFMarkdownDiagramIsDiagramLanguage(language)) {
            if (!SPDFMarkdownDiagramRender(language, block.plainText, plan.configuration.printableRect.size, 1, nil))
                [self add:@"warning" line:line code:@"diagram-as-code"
                    message:@"This diagram is shown as code: its type is not supported, it has a syntax error, or it "
                            @"is over the size budget (szpdf features --format md)."];
        } else if ([@[ @"math", @"latex-math", @"dot", @"graphviz", @"plantuml", @"puml" ] containsObject:language])
            [self add:@"info" line:line code:@"fence-as-code"
                message:[NSString stringWithFormat:@"A ```%@ fence is shown as code.%@", language,
                                                   [language isEqual:@"math"] ? @" Use $$…$$ for display math." : @""]];
    }
    NSDictionary* report = SPDFMarkdownLayoutReport(self.document.model, self.document.rendered, plan);
    NSMutableArray<SPDFMarkdownBlock*>* tables = [NSMutableArray array];
    CollectTables([self.document.model blocks], tables);
    NSArray* laidOut = report[@"tables"];
    CGFloat width = NSWidth(plan.configuration.printableRect);
    NSUInteger fit = (NSUInteger)floor(width / 44);
    for (NSUInteger i = 0; i < tables.count && i < laidOut.count; i++) {
        NSUInteger rows = CountRows(tables[i]), columns = tables[i].tableColumnCount;
        NSArray* pages = laidOut[i][@"pages"];
        NSUInteger start = [laidOut[i][@"range"][@"location"] unsignedIntegerValue];
        NSRange range = NSMakeRange(start, MIN((NSUInteger)60, [laidOut[i][@"range"][@"length"] unsignedIntegerValue]));
        id line = [self.document placeOfRenderedRange:range][@"line"];
        NSInteger number = [line isKindOfClass:NSNumber.class] ? [line integerValue] : 0;
        if (columns > fit)
            [self add:@"warning" line:number code:@"wide-table"
                message:[NSString stringWithFormat:@"This table has %lu columns; about %lu fit across the page at 44 pt "
                                                   @"each, so the text in them is squeezed. Use paper-orientation: "
                                                   @"landscape or fewer columns.", (unsigned long)columns, (unsigned long)fit]];
        if (rows > 200 || pages.count > 3)
            [self add:@"warning" line:number code:@"large-table"
                message:[NSString stringWithFormat:@"This table has %lu rows over pages %@-%@; consider splitting it.",
                                                   (unsigned long)rows, pages.firstObject, pages.lastObject]];
    }
    for (NSDictionary* diagnostic in report[@"diagnostics"]) {
        BOOL scaled = [diagnostic[@"kind"] isEqual:@"scaled-block"], overflow = [diagnostic[@"kind"] isEqual:@"overflow"];
        if (!scaled && !overflow) continue;
        SPDFMarkdownRenderedBlock* block = [self.document.rendered renderedBlockWithIndex:[diagnostic[@"block"] unsignedIntegerValue]];
        id line = block ? [self.document placeOfRenderedRange:NSMakeRange(block.attributedRange.location, MIN((NSUInteger)40, block.attributedRange.length))][@"line"] : nil;
        [self add:scaled ? @"info" : @"warning" line:[line isKindOfClass:NSNumber.class] ? [line integerValue] : 0
             code:scaled ? @"scaled-block" : @"overflow"
          message:scaled ? [NSString stringWithFormat:@"This block is larger than the page and is drawn at %.0f%% on page %@.",
                                                      [diagnostic[@"scale"] doubleValue] * 100, diagnostic[@"page"]]
                         : [NSString stringWithFormat:@"This block runs past the printable area on page %@.", diagnostic[@"page"]]];
    }
}

- (void)checkComments {
    NSString* file = SPDFMarkdownCommentsFilePath(self.document.path);
    NSString* text = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
    if (!text) return;
    SPDFMarkdownCommentAnchors* anchors = [[SPDFMarkdownCommentAnchors alloc] initWithSource:self.document.source
                                                                                    rendered:self.document.renderedText];
    for (SPDFMarkdownComment* comment in SPDFMarkdownCommentsParseFile(text)) {
        NSInteger line = comment.line;
        [anchors placeComment:comment];
        if (!comment.placed)
            [self add:@"warning" line:line code:@"comment-unplaced"
                message:[NSString stringWithFormat:@"%@'s comment on “%@” no longer finds its words; the reader lists it "
                                                   @"under Unplaced.", comment.author.length ? comment.author : @"A",
                                                   comment.quote]];
    }
}

@end

NSDictionary* SPDFMacSzpdfCheck(SPDFMacSzpdfDocument* document) {
    if (!document.markdown)
        return SPDFMacSzpdfFailure(@"unsupported", @"check reads Markdown and text documents.", nil);
    SPDFMacSzpdfChecker* checker = [SPDFMacSzpdfChecker new];
    checker.document = document;
    checker.lines = [[document.source stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
        componentsSeparatedByString:@"\n"];
    checker.issues = [NSMutableArray array];
    [checker indexLines];
    [checker checkImages];
    [checker checkHTML];
    [checker checkHeadingsAndLinks];
    [checker checkCodeAndLayout];
    [checker checkComments];
    [checker.issues sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
      NSInteger x = [a[@"line"] isKindOfClass:NSNumber.class] ? [a[@"line"] integerValue] : NSIntegerMax;
      NSInteger y = [b[@"line"] isKindOfClass:NSNumber.class] ? [b[@"line"] integerValue] : NSIntegerMax;
      return x < y ? NSOrderedAscending : x > y ? NSOrderedDescending : NSOrderedSame;
    }];
    NSUInteger errors = 0, warnings = 0;
    for (NSDictionary* issue in checker.issues) {
        errors += [issue[@"severity"] isEqual:@"error"];
        warnings += [issue[@"severity"] isEqual:@"warning"];
    }
    return @{@"path" : document.path, @"pageCount" : @(document.pageCount), @"issues" : checker.issues,
             @"errors" : @(errors), @"warnings" : @(warnings)};
}
