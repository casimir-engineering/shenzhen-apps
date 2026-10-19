#import "SPDFMacChatMarkdownParts.h"

#import <CoreText/CoreText.h>

#import "markdown/SPDFMarkdownDiagram.h"
#import "markdown/SPDFMarkdownTableDecorations.h"

// Tables, code and diagrams in a chat are drawn from the same page plan the reader prints, one block per plan, so a
// table has its header band, stripes and grid, code its box and highlighting, and a diagram its vector shapes. The
// plan goes on one tall page as wide as the block needs; only its content rect is shown.

const CGFloat SPDFMacChatMarkdownMinimumDiagramLabelSize = 11;
// One page holds the whole block: 128 KB of code at 12 pt is about 45,000 pt.
static const CGFloat kChatPageHeight = 200000;
// The widest a block may grow for sideways scrolling: the engine's own diagram axis cap, and a table or code line
// past it is better read in a document.
static const CGFloat kChatMaximumBlockWidth = 2048;
// A table wider than the bubble gives each over-long column this much before its cells wrap: about 40 characters,
// so a column of prose stays readable rather than one line two thousand points long.
static const CGFloat kChatTableColumnCap = 280;
// Diagram widths are searched within this much time; the natural width, which always keeps 11 pt, is used after.
// Each diagram layout stops at the engine's 50 ms deadline and a table at its row cap; the render's clock
// (SPDFMacChatMarkdownBudget.mm) bounds a message holding many of them.
static const NSTimeInterval kChatDiagramSearchTime = 0.15;
// A drawn table's cap. Uncapped, a friend's 32 KB message of one 2,000-row table took 0.14 s to lay out and a 128 KB
// answer 0.51 s (the security review measured 0.37 and 1.6 s on a busier machine); capped, 0.06 and 0.08 s.
static const NSUInteger kChatTableMaximumRows = 500;
static const NSUInteger kChatTableMaximumCells = 10000;

@implementation SPDFMacChatBlock
@end

SPDFMarkdownRenderOptions* SPDFMacChatRenderOptions(SPDFMacChatMarkdownOptions* options) {
    SPDFMarkdownRenderOptions* render = [SPDFMarkdownRenderOptions
        defaultOptionsForThemeVariant:options.dark ? SPDFMarkdownThemeVariantDark : SPDFMarkdownThemeVariantLight];
    render.textSize = 13;
    render.codeSize = 12;
    render.lineSpacing = 3;
    render.paragraphSpacing = 8;
    render.contentInset = 0;
    render.textColor = options.textColor;
    render.secondaryTextColor = options.secondaryTextColor;
    render.quoteColor = options.secondaryTextColor;
    render.linkColor = options.linkColor;
    // An inline code chip a shade off whatever bubble it sits in: the page's chips vanish on a chat's grey bubble.
    render.codeBackgroundColor = options.dark ? [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:.12]
                                              : [NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:.07];
    // Every image is taken out before rendering (SPDFMacChatMarkdown.mm). These hold if one ever reaches the
    // engine: no remote bytes are drawn, and a local or data image has no budget to load in.
    render.remoteImagesWithheld = YES;
    render.maximumResourceBytes = 0;
    render.maximumDecodedImagePixels = 0;
    return render;
}

// A code block keeps the reader's 34 pt header band inside its box: the language on the left, Copy on the right.
static SPDFMarkdownPaginationPlan* ChatPlan(SPDFMarkdownRenderedDocument* rendered, CGFloat width,
                                            SPDFMarkdownThemeVariant variant, BOOL codeHeader) {
    SPDFMarkdownPaginator* paginator = [SPDFMarkdownPaginator new];
    NSArray* items = [paginator measureRenderedDocument:rendered containerWidth:width];
    SPDFMarkdownPageConfiguration* page =
        [SPDFMarkdownPageConfiguration configurationForPaperSize:NSMakeSize(width, kChatPageHeight)
                                                   printableRect:NSMakeRect(0, 0, width, kChatPageHeight)];
    page.themeVariant = variant;
    page.preservesImageColors = YES;
    page.includesCodeLanguageControlSpacing = codeHeader;
    return [paginator paginateItems:items configuration:page];
}

static CGFloat SmallestLabel(SPDFMarkdownDiagramLayout* layout) {
    CGFloat smallest = CGFLOAT_MAX;
    for (SPDFMarkdownDiagramLabel* label in layout.labels) smallest = MIN(smallest, label.fontSize);
    return smallest;
}

typedef struct {
    CGFloat width;
    CGFloat scale;
} ChatDiagramFit;

// The narrowest box, from the bubble up to the natural width, that keeps every label at 11 pt or more. The engine
// fits a diagram to its box by one factor (re-wrapping flowchart labels first), so labels shrink with the box: at
// the natural width nothing shrinks. Its smaller label kinds (edge labels 10.5 pt, Gantt axis 9.5 pt) start under
// the floor, so the whole diagram is set larger until the smallest reaches it. Each probe is cached under exactly
// the key the engine's own render of the block uses (box = width x 0, this font scale), so the final render is a
// cache hit. Zero width means the diagram cannot be drawn.
static ChatDiagramFit FitDiagram(NSString* language, NSString* source, CGFloat visible,
                                 SPDFMarkdownDiagramCache* cache, NSTimeInterval budget) {
    ChatDiagramFit none = {0, 1};
    NSDate* start = [NSDate date];
    const CGFloat floorSize = SPDFMacChatMarkdownMinimumDiagramLabelSize - 0.01;
    SPDFMarkdownDiagramLayout* natural =
        SPDFMarkdownDiagramRender(language, source, NSMakeSize(SPDFMarkdownDiagramMaximumDimension, 0), 1, cache);
    if (!natural) return none;
    CGFloat scale = 1;
    CGFloat smallest = SmallestLabel(natural);
    if (smallest < floorSize && smallest > 0) {
        scale = MIN(3.0, ceil(SPDFMacChatMarkdownMinimumDiagramLabelSize / smallest * 1000) / 1000);
        SPDFMarkdownDiagramLayout* larger = SPDFMarkdownDiagramRender(
            language, source, NSMakeSize(SPDFMarkdownDiagramMaximumDimension, 0), scale, cache);
        // Set larger it no longer fits the engine's 2048 pt cap: keep the natural size, the most legible it has.
        if (larger) natural = larger;
        else scale = 1;
    }
    CGFloat naturalWidth = ceil(natural.size.width);
    ChatDiagramFit fit = {MAX(visible, naturalWidth), scale};
    if (naturalWidth > visible) {
        CGFloat low = visible, high = naturalWidth;
        SPDFMarkdownDiagramLayout* probe =
            SPDFMarkdownDiagramRender(language, source, NSMakeSize(low, 0), scale, cache);
        if (probe && SmallestLabel(probe) >= floorSize) high = low;
        // Bisection on the box width: each pass halves the gap between a width known to shrink labels under the
        // floor and one known to keep them; within 24 pt the wider is taken.
        while (high - low > 24 && -[start timeIntervalSinceNow] < MIN(kChatDiagramSearchTime, budget)) {
            CGFloat middle = floor((low + high) / 2);
            probe = SPDFMarkdownDiagramRender(language, source, NSMakeSize(middle, 0), scale, cache);
            if (probe && SmallestLabel(probe) >= floorSize) high = middle;
            else low = middle;
        }
        fit.width = high;
    }
    return fit;
}

// A table keeps the bubble's width while its columns fit; past that, each column gets up to kChatTableColumnCap and
// the table scrolls sideways.
static CGFloat TableWidth(SPDFMarkdownRenderedDocument* rendered, CGFloat visible) {
    for (SPDFMarkdownRenderedBlock* block in rendered.renderedBlocks) {
        if (!block.tableRowInfo) continue;
        CGFloat natural = 0, capped = 0;
        for (NSNumber* width in block.tableRowInfo.naturalColumnWidths) {
            natural += width.doubleValue;
            capped += MIN(width.doubleValue, kChatTableColumnCap);
        }
        return natural <= visible ? visible : MIN(kChatMaximumBlockWidth, MAX(visible, ceil(capped)));
    }
    return visible;
}

// Code does not wrap: the block is as wide as its longest line (plus the code box's 12 pt insets) or the bubble.
static CGFloat CodeWidth(SPDFMarkdownRenderedDocument* rendered, CGFloat visible) {
    NSAttributedString* text = rendered.attributedString;
    __block CGFloat widest = 0;
    [text.string enumerateSubstringsInRange:NSMakeRange(0, text.length)
                                    options:NSStringEnumerationByLines | NSStringEnumerationSubstringNotRequired
                                 usingBlock:^(NSString* line, NSRange range, NSRange enclosing, BOOL* stop) {
                                   (void)line, (void)enclosing, (void)stop;
                                   if (!range.length) return;
                                   CTLineRef measured = SPDFMarkdownCreateFragmentLine(
                                       [text attributedSubstringFromRange:range]);
                                   widest = MAX(widest, CTLineGetTypographicBounds(measured, NULL, NULL, NULL));
                                   CFRelease(measured);
                                 }];
    // 24 pt of insets, and a little slack: TextKit's tab stops can place a tabbed line a few points wider.
    return MIN(kChatMaximumBlockWidth, MAX(visible, ceil(widest) + 24 + 6));
}

static NSRect ContentRect(SPDFMarkdownPaginationPlan* plan) {
    NSRect content = NSZeroRect;
    for (SPDFMarkdownPageDecoration* decoration in [plan decorationsForPageIndex:0])
        content = NSIsEmptyRect(content) ? decoration.rect : NSUnionRect(content, decoration.rect);
    if (NSIsEmptyRect(content)) {
        for (SPDFMarkdownPageFragment* fragment in plan.pages.firstObject.fragments) {
            if (!fragment.attributedRange.length) continue;
            NSRect line = NSMakeRect(fragment.xOffset, fragment.pageYOffset, 1, fragment.height);
            content = NSIsEmptyRect(content) ? line : NSUnionRect(content, line);
        }
    }
    return NSIntegralRect(content);
}

static NSString* CellText(SPDFMarkdownBlock* cell) {
    NSMutableString* text = [NSMutableString string];
    for (SPDFMarkdownInlineRun* run in cell.runs) [text appendString:run.text ?: @""];
    for (SPDFMarkdownBlock* child in cell.children) [text appendString:CellText(child)];
    return [[text stringByReplacingOccurrencesOfString:@"|" withString:@"\\|"]
        stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
}

static void CollectRows(SPDFMarkdownBlock* block, NSMutableArray<SPDFMarkdownBlock*>* rows) {
    if (block.kind == SPDFMarkdownBlockKindTableRow) [rows addObject:block];
    else for (SPDFMarkdownBlock* child in block.children) CollectRows(child, rows);
}

static NSString* RowSource(SPDFMarkdownBlock* row) {
    NSMutableArray* cells = [NSMutableArray array];
    for (SPDFMarkdownBlock* cell in row.children) [cells addObject:CellText(cell)];
    return [NSString stringWithFormat:@"| %@ |", [cells componentsJoinedByString:@" | "]];
}

NSString* SPDFMacChatTableSource(SPDFMarkdownBlock* table) {
    NSMutableArray<SPDFMarkdownBlock*>* rows = [NSMutableArray array];
    CollectRows(table, rows);
    NSMutableArray<NSString*>* lines = [NSMutableArray array];
    for (NSUInteger index = 0; index < rows.count; index++) {
        [lines addObject:RowSource(rows[index])];
        if (index) continue;
        NSMutableArray* rule = [NSMutableArray array];
        for (SPDFMarkdownBlock* cell in rows[index].children) {
            SPDFMarkdownTableAlignment alignment = cell.tableAlignment;
            [rule addObject:alignment == SPDFMarkdownTableAlignmentCenter ? @":---:"
                            : alignment == SPDFMarkdownTableAlignmentRight ? @"---:"
                            : alignment == SPDFMarkdownTableAlignmentLeft ? @":---" : @"---"];
        }
        [lines addObject:[NSString stringWithFormat:@"| %@ |", [rule componentsJoinedByString:@" | "]]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

SPDFMarkdownBlock* SPDFMacChatCapTable(SPDFMarkdownBlock* table, NSUInteger* drawnRows, NSString** rest) {
    // The header row is one of the cells' rows; a table as wide as Markdown allows (128 columns) keeps 77 more.
    NSUInteger columns = MAX(table.tableColumnCount, (NSUInteger)1);
    NSUInteger limit = MAX((NSUInteger)1, MIN(kChatTableMaximumRows, kChatTableMaximumCells / columns - 1));
    NSUInteger kept = 0;
    NSMutableArray<NSString*>* left = [NSMutableArray array];
    NSMutableArray* sections = [NSMutableArray arrayWithCapacity:table.children.count];
    for (SPDFMarkdownBlock* section in table.children) {
        if (section.kind == SPDFMarkdownBlockKindTableHead) {
            [sections addObject:section];
            continue;
        }
        NSMutableArray* rows = [NSMutableArray array];
        for (SPDFMarkdownBlock* row in section.children) {
            if (kept < limit) [rows addObject:row], kept++;
            else [left addObject:RowSource(row)];
        }
        if (rows.count) [sections addObject:SPDFMacChatRebuiltBlock(section, section.runs, rows)];
    }
    *drawnRows = kept;
    *rest = left.count ? [left componentsJoinedByString:@"\n"] : nil;
    return left.count ? SPDFMacChatRebuiltBlock(table, table.runs, sections) : table;
}

// A diagram block shows only its ink: the engine's box keeps a page's 14 to 20 pt of air on every side.
static NSRect DiagramInk(SPDFMarkdownPaginationPlan* plan, NSRect content) {
    for (SPDFMarkdownPageDecoration* decoration in [plan decorationsForPageIndex:0]) {
        SPDFMarkdownDiagramLayout* layout = decoration.diagramLayout;
        if (decoration.type != SPDFMarkdownPageDecorationTypeDiagram || layout.size.width <= 0) continue;
        CGFloat scale = NSWidth(decoration.rect) / layout.size.width;
        NSRect ink = SPDFMacChatDiagramInkRect(layout);
        NSRect page = NSMakeRect(NSMinX(decoration.rect) + NSMinX(ink) * scale,
                                 NSMinY(decoration.rect) + NSMinY(ink) * scale, NSWidth(ink) * scale,
                                 NSHeight(ink) * scale);
        return NSIntegralRect(NSIntersectionRect(page, content));
    }
    return content;
}

static SPDFMacChatBlock* LayOut(SPDFMarkdownBlock* block, SPDFMacChatBlockKind kind, CGFloat visibleWidth,
                                SPDFMacChatMarkdownOptions* options, SPDFMarkdownDiagramCache* cache,
                                NSTimeInterval timeLeft) {
    CGFloat visible = MAX(120, floor(visibleWidth));
    SPDFMarkdownRenderOptions* render = SPDFMacChatRenderOptions(options);
    render.diagramCache = cache;
    CGFloat width = visible;
    NSString* code = [block.plainText stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] ?: @"";
    if (kind == SPDFMacChatBlockDiagram) {
        ChatDiagramFit fit = FitDiagram(block.codeLanguage, block.plainText ?: @"", visible, cache, timeLeft);
        if (fit.width <= 0) return nil;
        width = fit.width;
        render.fontScale = fit.scale;
    }
    // Height 0: no page height to fit, so a tall diagram keeps its legible width rather than shrinking to a page.
    render.pageContentSize = NSMakeSize(width, 0);
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownDocumentModel alloc] initWithSourceURL:nil frontMatter:@{}
                                                                             rawFrontMatter:nil blocks:@[block]];
    SPDFMarkdownRenderedDocument* rendered = [[SPDFMarkdownRenderer new] renderModel:model options:render
                                                                    languageOverrides:nil];
    if (kind == SPDFMacChatBlockDiagram && !rendered.renderedBlocks.firstObject.diagramInfo) return nil;
    // A caller that cannot scroll sideways gets tables and code wrapped to the column.
    if (kind == SPDFMacChatBlockTable && options.keepsWideBlocks) width = TableWidth(rendered, visible);
    else if (kind == SPDFMacChatBlockCode && options.keepsWideBlocks) width = CodeWidth(rendered, visible);
    SPDFMacChatBlock* result = [SPDFMacChatBlock new];
    result.kind = kind;
    result.rendered = rendered;
    result.variant = render.themeVariant;
    result.visibleWidth = visible;
    result.plan = ChatPlan(rendered, width, result.variant, kind == SPDFMacChatBlockCode);
    result.language = kind == SPDFMacChatBlockCode ? block.codeLanguage.lowercaseString : nil;
    result.contentRect = ContentRect(result.plan);
    if (kind == SPDFMacChatBlockDiagram) {
        result.contentRect = DiagramInk(result.plan, result.contentRect);
        result.nodeStrokeColor = options.secondaryTextColor;
    }
    if (NSIsEmptyRect(result.contentRect)) return nil;
    result.source = kind == SPDFMacChatBlockTable ? SPDFMacChatTableSource(block)
                    : kind == SPDFMacChatBlockCode ? code
                    : [NSString stringWithFormat:@"```%@\n%@\n```", block.codeLanguage ?: @"", code];
    return result;
}

SPDFMacChatBlock* SPDFMacChatLayOutBlock(SPDFMarkdownBlock* block, SPDFMacChatBlockKind kind, CGFloat visibleWidth,
                                         SPDFMacChatMarkdownOptions* options, SPDFMarkdownDiagramCache* cache,
                                         NSTimeInterval* timeLeft) {
    if (*timeLeft <= 0) return nil;
    NSTimeInterval start = SPDFMacChatNow();
    SPDFMacChatBlock* laid = LayOut(block, kind, visibleWidth, options, cache, *timeLeft);
    SPDFMacChatPassExtraLayoutTime();
    *timeLeft -= SPDFMacChatNow() - start;
    return laid;
}

static void SetColor(CGContextRef context, NSColor* color, BOOL stroke) {
    NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.blackColor;
    CGFloat red = rgb.redComponent, green = rgb.greenComponent, blue = rgb.blueComponent, alpha = rgb.alphaComponent;
    if (stroke) CGContextSetRGBStrokeColor(context, red, green, blue, alpha);
    else CGContextSetRGBFillColor(context, red, green, blue, alpha);
}

void SPDFMacChatDrawBlock(SPDFMacChatBlock* block, CGContextRef context, CGFloat scale) {
    NSRect content = block.contentRect;
    SPDFMarkdownTheme* theme = [SPDFMarkdownTheme themeForVariant:block.variant];
    CGContextSaveGState(context);
    CGContextScaleCTM(context, scale, scale);
    CGContextClipToRect(context, CGRectMake(0, 0, NSWidth(content), NSHeight(content)));
    // Page coordinates run down from the top; this context runs up from the content rect's bottom-left corner.
    CGFloat top = NSMaxY(content);
    // A table keeps the page's paper under its chrome: the theme's grid is drawn for that paper, and on a chat
    // bubble's grey (Friends' dark #34343b) its hairlines vanished.
    if (block.kind == SPDFMacChatBlockTable) {
        SetColor(context, theme.paperColor, NO);
        CGContextFillRect(context, CGRectMake(0, 0, NSWidth(content), NSHeight(content)));
    }
    for (SPDFMarkdownPageDecoration* decoration in [block.plan decorationsForPageIndex:0]) {
        CGRect rect = CGRectMake(NSMinX(decoration.rect) - NSMinX(content), top - NSMaxY(decoration.rect),
                                 NSWidth(decoration.rect), NSHeight(decoration.rect));
        switch (decoration.type) {
            case SPDFMarkdownPageDecorationTypeCodeBox: {
                CGRect box = CGRectInset(rect, 0.5, 0.5);
                CGPathRef path = CGPathCreateWithRoundedRect(box, 6, 6, NULL);
                SetColor(context, theme.codeBoxFillColor, NO);
                CGContextAddPath(context, path);
                CGContextFillPath(context);
                SetColor(context, theme.codeBoxStrokeColor, YES);
                CGContextSetLineWidth(context, 1);
                CGContextAddPath(context, path);
                CGContextStrokePath(context);
                CGPathRelease(path);
                break;
            }
            case SPDFMarkdownPageDecorationTypeDiagram:
                SPDFMacChatDrawDiagramShapes(context, decoration.diagramLayout, rect, block.variant,
                                             block.nodeStrokeColor);
                break;
            case SPDFMarkdownPageDecorationTypeTableHeaderBand:
            case SPDFMarkdownPageDecorationTypeTableStripe:
            case SPDFMarkdownPageDecorationTypeTableGridLine:
                SPDFMarkdownDrawTableDecoration(context, decoration.type, rect, theme);
                break;
            default:
                SetColor(context, theme.thematicBreakRuleColor, NO);
                CGContextFillRect(context, rect);
        }
    }
    // Only the lines the drawing needs: a long table redraws the rows on screen, not all of them.
    CGRect clip = CGContextGetClipBoundingBox(context);
    NSAttributedString* text = block.rendered.attributedString;
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    for (SPDFMarkdownPageFragment* fragment in block.plan.pages.firstObject.fragments) {
        if (!fragment.attributedRange.length || NSMaxRange(fragment.attributedRange) > text.length) continue;
        CGFloat baseline = top - fragment.pageYOffset - fragment.baselineOffset;
        CGFloat lineTop = top - fragment.pageYOffset;
        if (lineTop < CGRectGetMinY(clip) || lineTop - fragment.height > CGRectGetMaxY(clip)) continue;
        CTLineRef line = SPDFMarkdownCreateFragmentLine([text attributedSubstringFromRange:fragment.attributedRange]);
        CGContextSaveGState(context);
        CGContextTranslateCTM(context, fragment.xOffset - NSMinX(content), baseline);
        CGContextScaleCTM(context, fragment.scale, fragment.scale);
        CGContextSetTextPosition(context, 0, 0);
        CTLineDraw(line, context);
        CGContextRestoreGState(context);
        CFRelease(line);
    }
    CGContextRestoreGState(context);
}

NSUInteger SPDFMacChatBlockCharacterAtPoint(SPDFMacChatBlock* block, NSPoint point) {
    NSPoint page = NSMakePoint(point.x + NSMinX(block.contentRect), point.y + NSMinY(block.contentRect));
    NSAttributedString* text = block.rendered.attributedString;
    for (SPDFMarkdownPageFragment* fragment in block.plan.pages.firstObject.fragments) {
        if (!fragment.attributedRange.length || NSMaxRange(fragment.attributedRange) > text.length) continue;
        if (page.y < fragment.pageYOffset || page.y > fragment.pageYOffset + fragment.height) continue;
        CTLineRef line = SPDFMarkdownCreateFragmentLine([text attributedSubstringFromRange:fragment.attributedRange]);
        CGFloat scale = MAX(fragment.scale, 0.001);
        CGFloat x = (page.x - fragment.xOffset) / scale;
        CGFloat width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
        NSUInteger found = NSNotFound;
        if (x >= 0 && x <= width) {
            CFIndex index = CTLineGetStringIndexForPosition(line, CGPointMake(x, 0));
            // The caret index lands after a character clicked on its right half.
            if (index > 0 && CTLineGetOffsetForStringIndex(line, index, NULL) > x) index--;
            found = fragment.attributedRange.location +
                    MIN((NSUInteger)MAX(index, (CFIndex)0), fragment.attributedRange.length - 1);
        }
        CFRelease(line);
        if (found != NSNotFound) return found;
    }
    return NSNotFound;
}

NSRect SPDFMacChatBlockCopyRect(SPDFMacChatBlock* block) {
    CGFloat right = MIN(NSWidth(block.contentRect), block.visibleWidth > 0 ? block.visibleWidth : CGFLOAT_MAX);
    if (block.kind != SPDFMacChatBlockCode || right < 120) return NSZeroRect;
    return NSMakeRect(right - 62, 7, 54, 20);
}

NSRect SPDFMacChatBlockRectForRange(SPDFMacChatBlock* block, NSRange range) {
    NSRect found = NSZeroRect;
    NSAttributedString* text = block.rendered.attributedString;
    for (SPDFMarkdownPageFragment* fragment in block.plan.pages.firstObject.fragments) {
        NSRange line = fragment.attributedRange;
        NSRange part = NSIntersectionRange(line, range);
        if (!part.length || NSMaxRange(line) > text.length) continue;
        CTLineRef measured = SPDFMarkdownCreateFragmentLine([text attributedSubstringFromRange:line]);
        CGFloat start = CTLineGetOffsetForStringIndex(measured, (CFIndex)(part.location - line.location), NULL);
        CGFloat end = CTLineGetOffsetForStringIndex(measured, (CFIndex)(NSMaxRange(part) - line.location), NULL);
        CFRelease(measured);
        NSRect rect = NSMakeRect(fragment.xOffset + MIN(start, end) * fragment.scale - NSMinX(block.contentRect),
                                 fragment.pageYOffset - NSMinY(block.contentRect), fabs(end - start) * fragment.scale,
                                 fragment.height);
        found = NSIsEmptyRect(found) ? rect : NSUnionRect(found, rect);
    }
    return found;
}
