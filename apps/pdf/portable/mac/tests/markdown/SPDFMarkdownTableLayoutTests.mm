#import "SPDFMarkdownTestSupport.h"

#import <CoreText/CoreText.h>

#import "../../markdown/SPDFMarkdownDocument.h"
#import "../../markdown/SPDFMarkdownTableDecorations.h"
#import "../../markdown/SPDFMarkdownTableLayout.h"

// Content-aware table layout: cells wrap inside their own column box, rows are
// as tall as their tallest cell, headers keep-with-next across page breaks,
// and the drawn grid derives from the measured column geometry. The fixture is
// the markdown-it demo "Tables" section: a left-aligned and a fully
// right-aligned table whose description cells are far wider than one column.

static CGFloat SPDFLineWidth(NSAttributedString* text, NSRange range) {
    CTLineRef line = CTLineCreateWithAttributedString(
        (__bridge CFAttributedStringRef)[text attributedSubstringFromRange:range]);
    double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL) - CTLineGetTrailingWhitespaceWidth(line);
    CFRelease(line);
    return width;
}

static NSInteger SPDFCellIndexForRange(SPDFMarkdownTableRowInfo* info, NSRange range) {
    for (NSUInteger i = 0; i < info.cellRanges.count; ++i)
        if (NSLocationInRange(range.location, info.cellRanges[i].rangeValue)) return (NSInteger)i;
    return -1;
}

static SPDFMarkdownPaginationItem* SPDFSyntheticRow(NSUInteger blockIndex, BOOL header, NSUInteger bodyRowIndex,
                                                    CGFloat height) {
    SPDFMarkdownTableRowInfo* info =
        [[SPDFMarkdownTableRowInfo alloc] initWithTableBlockIndex:500
                                                        headerRow:header
                                                          lastRow:NO
                                                     bodyRowIndex:bodyRowIndex
                                                 columnBoundaries:@[ @0, @60, @120 ]];
    SPDFMarkdownTextLine* band = [[SPDFMarkdownTextLine alloc] initWithAttributedRange:NSMakeRange(blockIndex * 50, 5)
                                                                                height:height
                                                                               xOffset:0
                                                                        baselineOffset:height * 0.8];
    return [[SPDFMarkdownPaginationItem alloc] initWithBlockIndex:blockIndex
                                                             kind:SPDFMarkdownBlockKindTableRow
                                                     headingLevel:0
                                                     tableRowInfo:info
                                                            lines:@[ band ]];
}

static SPDFMarkdownPaginationItem* SPDFSyntheticParagraph(NSUInteger blockIndex, CGFloat height) {
    SPDFMarkdownTextLine* line = [[SPDFMarkdownTextLine alloc] initWithAttributedRange:NSMakeRange(blockIndex * 50, 5)
                                                                                height:height
                                                                               xOffset:0
                                                                        baselineOffset:height * 0.8];
    return [[SPDFMarkdownPaginationItem alloc] initWithBlockIndex:blockIndex
                                                             kind:SPDFMarkdownBlockKindParagraph
                                                     headingLevel:0
                                                            lines:@[ line ]];
}

// Row band on a page: the min/max envelope over one row item's fragments.
static NSRange SPDFRowFragmentRun(NSArray<SPDFMarkdownPageFragment*>* fragments, NSUInteger start, CGFloat* top,
                                  CGFloat* bottom) {
    NSUInteger itemIndex = fragments[start].itemIndex;
    CGFloat minY = CGFLOAT_MAX;
    CGFloat maxY = -CGFLOAT_MAX;
    NSUInteger end = start;
    while (end < fragments.count && fragments[end].itemIndex == itemIndex) {
        minY = MIN(minY, fragments[end].pageYOffset);
        maxY = MAX(maxY, fragments[end].pageYOffset + fragments[end].height);
        ++end;
    }
    *top = minY;
    *bottom = maxY;
    return NSMakeRange(start, end - start);
}

int main(void) {
    @autoreleasepool {
        // Column distribution rule.
        NSArray<NSNumber*>* compact = SPDFMarkdownTableColumnWidths(@[ @60, @100 ], 523);
        SPDFExpect(compact.count == 2 && fabs(compact[0].doubleValue - 60) < 0.001 &&
                       fabs(compact[1].doubleValue - 100) < 0.001,
                   @"a table narrower than the page keeps its compact natural widths");
        NSArray<NSNumber*>* capped = SPDFMarkdownTableColumnWidths(@[ @60, @800 ], 523);
        SPDFExpect(capped.count == 2 &&
                       fabs(capped[0].doubleValue + capped[1].doubleValue - 523) < 0.01 &&
                       fabs(capped[0].doubleValue - 60) < 0.001 && fabs(capped[1].doubleValue - 463) < 0.001,
                   @"an over-wide table caps at the available width; the short column keeps its natural "
                   @"width and the long column absorbs the whole reduction");
        NSArray<NSNumber*>* even = SPDFMarkdownTableColumnWidths(@[ @300, @300, @300 ], 100);
        SPDFExpect(even.count == 3 && fabs(even[1].doubleValue - 100.0 / 3) < 0.01,
                   @"a page narrower than the per-column minimum splits evenly");

        NSArray<NSNumber*>* decision = SPDFMarkdownTableColumnWidths(@[@44, @260, @6000], 523);
        SPDFExpect(fabs(decision[0].doubleValue - 44) < 0.01 && decision[1].doubleValue >= 200 &&
            fabs(decision[1].doubleValue - decision[2].doubleValue) < 0.01,
            @"one huge reason cell cannot starve the Choice column into character-by-character wrapping");
        for (NSNumber* width in decision)
            SPDFExpect(width.doubleValue >= SPDFMarkdownTableMinimumColumnWidth,
                @"all columns retain their width floor whenever the page can fit it");

        NSError* error = nil;
        SPDFMarkdownDocument* document = [SPDFMarkdownDocument documentWithURL:SPDFFixtureURL(@"tables-long-cells.md")
                                                                       options:nil
                                                                         error:&error];
        SPDFExpect(document != nil && error == nil, @"long-cell table fixture loads");
        SPDFMarkdownRenderedDocument* rendered = document.renderedDocument;
        NSAttributedString* text = rendered.attributedString;
        SPDFMarkdownPageConfiguration* A4 = SPDFMarkdownPageConfiguration.A4PortraitConfiguration;
        CGFloat printableWidth = NSWidth(A4.printableRect);
        SPDFMarkdownPaginator* paginator = [SPDFMarkdownPaginator new];
        NSArray<SPDFMarkdownPaginationItem*>* items = [paginator measureRenderedDocument:rendered
                                                                          containerWidth:printableWidth];

        NSMutableArray<SPDFMarkdownPaginationItem*>* rowItems = [NSMutableArray array];
        for (SPDFMarkdownPaginationItem* item in items)
            if (item.tableRowInfo) [rowItems addObject:item];
        SPDFExpect(rowItems.count == 8, @"both fixture tables measure a header and three body rows each");

        BOOL cellsContained = YES;
        BOOL bandsCoverCells = YES;
        BOOL rowHeightIsTallestCell = YES;
        NSUInteger wrappedCells = 0;
        for (SPDFMarkdownPaginationItem* item in rowItems) {
            SPDFMarkdownTableRowInfo* info = item.tableRowInfo;
            NSArray<NSNumber*>* boundaries = info.columnBoundaries;
            SPDFExpect(boundaries.count == 3 && item.lines.count >= 3,
                       @"each row records two column boxes and measures its spacer plus cell lines");
            SPDFMarkdownTextLine* band = item.lines.firstObject;
            SPDFExpect(band.attributedRange.length == 0 && fabs(band.height - item.measuredHeight) < 0.001,
                       @"the row's leading spacer line spans the exact row band");
            NSMutableDictionary<NSNumber*, NSNumber*>* linesPerCell = [NSMutableDictionary dictionary];
            CGFloat maxCellExtent = 0;
            for (NSUInteger index = 1; index < item.lines.count; ++index) {
                SPDFMarkdownTextLine* line = item.lines[index];
                NSInteger cell = SPDFCellIndexForRange(info, line.attributedRange);
                if (cell < 0) {
                    cellsContained = NO;
                    continue;
                }
                linesPerCell[@(cell)] = @(linesPerCell[@(cell)].unsignedIntegerValue + 1);
                CGFloat columnLeft = boundaries[(NSUInteger)cell].doubleValue;
                CGFloat columnRight = boundaries[(NSUInteger)cell + 1].doubleValue;
                CGFloat lineWidth = SPDFLineWidth(text, line.attributedRange);
                // Every wrapped line stays inside its own column's content box.
                if (line.xOffset < columnLeft + SPDFMarkdownTableCellInset - 0.5 ||
                    line.xOffset + lineWidth > columnRight - SPDFMarkdownTableCellInset + 1.5)
                    cellsContained = NO;
                if (line.rowLocalYOffset + line.height > item.measuredHeight + 0.01) bandsCoverCells = NO;
                maxCellExtent = MAX(maxCellExtent, line.rowLocalYOffset + line.height);
            }
            for (NSNumber* count in linesPerCell.allValues)
                if (count.unsignedIntegerValue > 1) ++wrappedCells;
            CGFloat bottomMargin = info.isLastRow ? SPDFMarkdownTableOuterMargin : 0;
            if (fabs(item.measuredHeight - (maxCellExtent + info.verticalPadding + bottomMargin)) > 1.0)
                rowHeightIsTallestCell = NO;
        }
        SPDFExpect(cellsContained, @"every cell line stays inside its own column box, never crossing the grid");
        SPDFExpect(bandsCoverCells, @"every cell line lies inside its row band");
        SPDFExpect(wrappedCells >= 4, @"long description cells wrap to multiple lines within their column");
        SPDFExpect(rowHeightIsTallestCell, @"a row is as tall as its tallest cell plus the row padding");

        // The long tables cap at the printable width and keep the short Option
        // column far narrower than the Description column.
        NSArray<NSNumber*>* firstBoundaries = rowItems.firstObject.tableRowInfo.columnBoundaries;
        SPDFExpect(fabs(firstBoundaries.lastObject.doubleValue - printableWidth) < 0.1,
                   @"a table with over-wide natural columns caps at the printable width");
        SPDFExpect(firstBoundaries[1].doubleValue - firstBoundaries[0].doubleValue <
                       (firstBoundaries[2].doubleValue - firstBoundaries[1].doubleValue) / 2,
                   @"the short column keeps a compact width; the long column takes the rest and wraps");

        // Fully right-aligned table: every cell right-aligns inside its own
        // column without bleeding into a neighbor (regression: the tab layout
        // collapsed all cells into one right-aligned line).
        BOOL rightAligned = YES;
        for (NSUInteger rowIndex = 4; rowIndex < rowItems.count; ++rowIndex) {
            SPDFMarkdownPaginationItem* item = rowItems[rowIndex];
            SPDFMarkdownTableRowInfo* info = item.tableRowInfo;
            for (NSUInteger index = 1; index < item.lines.count; ++index) {
                SPDFMarkdownTextLine* line = item.lines[index];
                NSInteger cell = SPDFCellIndexForRange(info, line.attributedRange);
                if (cell < 0) continue;
                if (info.cellAlignments[(NSUInteger)cell].integerValue != NSTextAlignmentRight) rightAligned = NO;
                CGFloat contentRight =
                    info.columnBoundaries[(NSUInteger)cell + 1].doubleValue - SPDFMarkdownTableCellInset;
                CGFloat rightEdge = line.xOffset + SPDFLineWidth(text, line.attributedRange);
                if (rightEdge > contentRight + 1.0 || rightEdge < contentRight - 6.0) rightAligned = NO;
            }
        }
        SPDFExpect(rightAligned, @"right-aligned cells flush to their own column's content edge, cell by cell");

        // Header keep-with-next: a page whose remainder fits the header row but
        // not the header plus the first body row moves the table start to the
        // next page.
        NSUInteger headerIndex = (NSUInteger)[items indexOfObject:rowItems.firstObject];
        CGFloat beforeHeight = 0;
        for (NSUInteger i = 0; i < headerIndex; ++i) beforeHeight += items[i].measuredHeight;
        CGFloat keepPageHeight =
            beforeHeight + rowItems[0].measuredHeight + rowItems[1].measuredHeight - 1;
        SPDFMarkdownPageConfiguration* keepPage = [SPDFMarkdownPageConfiguration
            configurationForPaperSize:NSMakeSize(printableWidth + 72, keepPageHeight + 72)
                        printableRect:NSMakeRect(36, 36, printableWidth, keepPageHeight)];
        SPDFMarkdownPaginationPlan* keepPlan = [paginator paginateItems:items configuration:keepPage];
        NSInteger headerPage = -1;
        NSInteger firstBodyPage = -1;
        for (SPDFMarkdownPage* page in keepPlan.pages) {
            for (SPDFMarkdownPageFragment* fragment in page.fragments) {
                SPDFMarkdownTableRowInfo* info = keepPlan.items[fragment.itemIndex].tableRowInfo;
                if (!info || info.tableBlockIndex != rowItems.firstObject.tableRowInfo.tableBlockIndex) continue;
                if (info.isHeaderRow && headerPage < 0) headerPage = (NSInteger)page.pageIndex;
                if (!info.isHeaderRow && info.bodyRowIndex == 0 && firstBodyPage < 0)
                    firstBodyPage = (NSInteger)page.pageIndex;
            }
        }
        SPDFExpect(headerPage == 1 && firstBodyPage == 1,
                   @"a header row near the page bottom moves to the next page with its first body row");

        // Synthetic keep-with-next mirrors the numbers of the heading rule.
        SPDFMarkdownPageConfiguration* smallPage =
            [SPDFMarkdownPageConfiguration configurationForPaperSize:NSMakeSize(200, 100)
                                                       printableRect:NSMakeRect(0, 0, 200, 100)];
        SPDFMarkdownPaginationPlan* widowPlan = [paginator paginateItems:@[
            SPDFSyntheticParagraph(1, 75), SPDFSyntheticRow(2, YES, 0, 15), SPDFSyntheticRow(3, NO, 0, 15)
        ]
                                                           configuration:smallPage];
        SPDFExpect(widowPlan.pages.count == 2 && widowPlan.pages[0].fragments.count == 1 &&
                       widowPlan.pages[1].fragments.firstObject.blockIndex == 2 &&
                       widowPlan.pages[1].fragments.lastObject.blockIndex == 3,
                   @"a header row that cannot keep its first body row moves to the next page");
        SPDFMarkdownPaginationPlan* fitPlan = [paginator paginateItems:@[
            SPDFSyntheticParagraph(1, 60), SPDFSyntheticRow(2, YES, 0, 15), SPDFSyntheticRow(3, NO, 0, 15)
        ]
                                                         configuration:smallPage];
        SPDFExpect(fitPlan.pages.count == 1, @"a header row that keeps its first body row stays in place");
        SPDFMarkdownPaginationPlan* tallRowPlan =
            [paginator paginateItems:@[ SPDFSyntheticRow(7, NO, 0, 250) ] configuration:smallPage];
        SPDFExpect(tallRowPlan.pages.count == 1 &&
                       fabs(tallRowPlan.pages.firstObject.fragments.firstObject.scale - 0.4) < 0.001 &&
                       fabs(tallRowPlan.pages.firstObject.fragments.firstObject.height - 100) < 0.001,
                   @"a row taller than the printable page scales into one page instead of splitting");

        // Split table: rows stay atomic, the grid resumes at the measured
        // column boundaries on the next page, and zebra parity is per table.
        SPDFMarkdownPageConfiguration* splitPage = [SPDFMarkdownPageConfiguration
            configurationForPaperSize:NSMakeSize(printableWidth + 72, 170 + 72)
                        printableRect:NSMakeRect(36, 36, printableWidth, 170)];
        SPDFMarkdownPaginationPlan* splitPlan = [paginator paginateItems:items configuration:splitPage];
        SPDFExpect(splitPlan.pages.count >= 2, @"the fixture spans multiple 170pt pages");
        NSMutableDictionary<NSNumber*, NSNumber*>* rowItemPage = [NSMutableDictionary dictionary];
        BOOL rowsAtomic = YES;
        for (SPDFMarkdownPage* page in splitPlan.pages) {
            NSArray<SPDFMarkdownPageFragment*>* fragments = page.fragments;
            NSUInteger index = 0;
            while (index < fragments.count) {
                SPDFMarkdownPaginationItem* item = splitPlan.items[fragments[index].itemIndex];
                if (!item.tableRowInfo) {
                    ++index;
                    continue;
                }
                CGFloat top = 0;
                CGFloat bottom = 0;
                NSRange run = SPDFRowFragmentRun(fragments, index, &top, &bottom);
                NSNumber* key = @(fragments[index].itemIndex);
                if (rowItemPage[key]) rowsAtomic = NO;
                rowItemPage[key] = @(page.pageIndex);
                // Every expected stripe/grid check consumes the run bounds via
                // the decorations below; here only atomicity matters.
                index = NSMaxRange(run);
            }
            NSMutableArray<SPDFMarkdownPageDecoration*>* stripes = [NSMutableArray array];
            NSMutableArray<SPDFMarkdownPageDecoration*>* verticals = [NSMutableArray array];
            for (SPDFMarkdownPageDecoration* decoration in [splitPlan decorationsForPageIndex:page.pageIndex]) {
                if (decoration.type == SPDFMarkdownPageDecorationTypeTableStripe) [stripes addObject:decoration];
                if (decoration.type == SPDFMarkdownPageDecorationTypeTableGridLine &&
                    NSHeight(decoration.rect) > 1.001)
                    [verticals addObject:decoration];
            }
            // Expected stripes: one per odd body row portion on this page.
            NSUInteger expectedStripes = 0;
            index = 0;
            while (index < fragments.count) {
                SPDFMarkdownPaginationItem* item = splitPlan.items[fragments[index].itemIndex];
                SPDFMarkdownTableRowInfo* info = item.tableRowInfo;
                if (!info) {
                    ++index;
                    continue;
                }
                CGFloat top = 0;
                CGFloat bottom = 0;
                NSRange run = SPDFRowFragmentRun(fragments, index, &top, &bottom);
                if (!info.isHeaderRow && info.bodyRowIndex % 2 == 1) {
                    ++expectedStripes;
                    BOOL matched = NO;
                    for (SPDFMarkdownPageDecoration* stripe in stripes)
                        if (fabs(NSMinY(stripe.rect) - top) < 0.01) matched = YES;
                    if (!matched) rowsAtomic = NO;
                }
                // Vertical grid lines sit exactly at this row's boundaries
                // (the table's right edge line is kept on the page by the
                // decoration's printable-width clamp).
                for (NSNumber* boundary in info.columnBoundaries) {
                    CGFloat expected = MIN(boundary.doubleValue, printableWidth - 1);
                    BOOL found = NO;
                    for (SPDFMarkdownPageDecoration* line in verticals)
                        if (fabs(NSMinX(line.rect) - expected) < 0.01) found = YES;
                    if (!found) rowsAtomic = NO;
                }
                index = NSMaxRange(run);
            }
            if (stripes.count != expectedStripes) rowsAtomic = NO;
        }
        SPDFExpect(rowItemPage.count == rowItems.count, @"every row appears in the split plan");
        SPDFExpect(rowsAtomic,
                   @"split-table pages keep rows atomic, stripe parity per table, and grid lines at the "
                   @"measured column boundaries");

        // Search correspondence: a query inside a wrapped description cell
        // highlights fragments whose glyph runs sit inside that cell's column.
        NSArray<SPDFMarkdownSearchMatch*>* matches = [rendered searchForQuery:@"Handlebars is the default"
                                                                caseSensitive:YES];
        SPDFExpect(matches.count == 2, @"the wrapped-cell query matches once per table");
        SPDFMarkdownPaginationPlan* plan = [document paginationPlanForConfiguration:A4];
        BOOL highlightInsideColumn = YES;
        NSUInteger highlightRects = 0;
        for (SPDFMarkdownSearchMatch* match in matches) {
            for (SPDFMarkdownPage* page in plan.pages) {
                for (SPDFMarkdownPageFragment* fragment in page.fragments) {
                    NSRange intersection = NSIntersectionRange(fragment.attributedRange, match.range);
                    if (!intersection.length) continue;
                    SPDFMarkdownTableRowInfo* info = plan.items[fragment.itemIndex].tableRowInfo;
                    NSInteger cell = info ? SPDFCellIndexForRange(info, intersection) : -1;
                    if (cell < 0) {
                        highlightInsideColumn = NO;
                        continue;
                    }
                    NSAttributedString* lineString =
                        [text attributedSubstringFromRange:fragment.attributedRange];
                    CTLineRef line =
                        CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)lineString);
                    CFIndex start = (CFIndex)(intersection.location - fragment.attributedRange.location);
                    CFIndex end = (CFIndex)(NSMaxRange(intersection) - fragment.attributedRange.location);
                    CGFloat x0 = fragment.xOffset + CTLineGetOffsetForStringIndex(line, start, NULL) * fragment.scale;
                    CGFloat x1 = fragment.xOffset + CTLineGetOffsetForStringIndex(line, end, NULL) * fragment.scale;
                    CFRelease(line);
                    ++highlightRects;
                    if (x0 < info.columnBoundaries[(NSUInteger)cell].doubleValue - 0.01 ||
                        x1 > info.columnBoundaries[(NSUInteger)cell + 1].doubleValue + 0.01)
                        highlightInsideColumn = NO;
                }
            }
        }
        SPDFExpect(highlightRects >= 2 && highlightInsideColumn,
                   @"search highlight rects inside a wrapped cell stay inside that cell's column box");
    }
    return SPDFFinishTests(@"SPDFMarkdownTableLayoutTests");
}
