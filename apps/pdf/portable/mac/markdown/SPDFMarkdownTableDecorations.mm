#import "SPDFMarkdownTableDecorations.h"

#import "SPDFMarkdownPaginator.h"

const CGFloat SPDFMarkdownTableOuterMargin = 10.0;

@implementation SPDFMarkdownTableRowInfo
- (instancetype)initWithTableBlockIndex:(NSUInteger)tableBlockIndex
                              headerRow:(BOOL)headerRow
                                lastRow:(BOOL)lastRow
                           bodyRowIndex:(NSUInteger)bodyRowIndex
                       columnBoundaries:(NSArray<NSNumber*>*)columnBoundaries
                             cellRanges:(NSArray<NSValue*>*)cellRanges
                         cellAlignments:(NSArray<NSNumber*>*)cellAlignments
                    naturalColumnWidths:(NSArray<NSNumber*>*)naturalColumnWidths
                        verticalPadding:(CGFloat)verticalPadding
                            depthIndent:(CGFloat)depthIndent {
    self = [super init];
    if (self) {
        _tableBlockIndex = tableBlockIndex;
        _headerRow = headerRow;
        _lastRow = lastRow;
        _bodyRowIndex = bodyRowIndex;
        _columnBoundaries = [columnBoundaries copy];
        _cellRanges = [cellRanges copy];
        _cellAlignments = [cellAlignments copy];
        _naturalColumnWidths = [naturalColumnWidths copy];
        _verticalPadding = verticalPadding;
        _depthIndent = depthIndent;
    }
    return self;
}
- (instancetype)initWithTableBlockIndex:(NSUInteger)tableBlockIndex
                              headerRow:(BOOL)headerRow
                                lastRow:(BOOL)lastRow
                           bodyRowIndex:(NSUInteger)bodyRowIndex
                       columnBoundaries:(NSArray<NSNumber*>*)columnBoundaries {
    return [self initWithTableBlockIndex:tableBlockIndex
                               headerRow:headerRow
                                 lastRow:lastRow
                            bodyRowIndex:bodyRowIndex
                        columnBoundaries:columnBoundaries
                              cellRanges:@[]
                          cellAlignments:@[]
                     naturalColumnWidths:@[]
                         verticalPadding:6.0
                             depthIndent:columnBoundaries.firstObject.doubleValue];
}
- (instancetype)rowInfoWithColumnBoundaries:(NSArray<NSNumber*>*)columnBoundaries {
    return [[SPDFMarkdownTableRowInfo alloc] initWithTableBlockIndex:self.tableBlockIndex
                                                           headerRow:self.headerRow
                                                             lastRow:self.lastRow
                                                        bodyRowIndex:self.bodyRowIndex
                                                    columnBoundaries:columnBoundaries
                                                          cellRanges:self.cellRanges
                                                      cellAlignments:self.cellAlignments
                                                 naturalColumnWidths:self.naturalColumnWidths
                                                     verticalPadding:self.verticalPadding
                                                         depthIndent:self.depthIndent];
}
@end

static void SPDFAppendDecoration(NSMutableArray<SPDFMarkdownPageDecoration*>* decorations,
                                 SPDFMarkdownPageDecorationType type, NSRect rect, NSUInteger blockIndex) {
    [decorations addObject:[[SPDFMarkdownPageDecoration alloc] initWithType:type rect:rect blockIndex:blockIndex]];
}

NSUInteger SPDFMarkdownAppendTableDecorations(NSArray<SPDFMarkdownPageFragment*>* fragments, NSUInteger startIndex,
                                              NSArray<SPDFMarkdownPaginationItem*>* items, CGFloat printableWidth,
                                              NSMutableArray<SPDFMarkdownPageDecoration*>* decorations) {
    SPDFMarkdownTableRowInfo* tableInfo = items[fragments[startIndex].itemIndex].tableRowInfo;
    NSUInteger tableIndex = tableInfo.tableBlockIndex;

    // One run per row item portion on this page. A row's fragments share the
    // row's vertical band (wrapped cells sit side by side within it), so the
    // band is the min/max envelope over the run — the row's full-band spacer
    // fragment extends it to the true row top and bottom including padding.
    NSMutableArray<SPDFMarkdownTableRowInfo*>* rowInfos = [NSMutableArray array];
    NSMutableArray<NSNumber*>* rowTops = [NSMutableArray array];
    NSMutableArray<NSNumber*>* rowBottoms = [NSMutableArray array];
    NSMutableArray<NSNumber*>* rowBlockIndexes = [NSMutableArray array];
    NSUInteger index = startIndex;
    while (index < fragments.count) {
        SPDFMarkdownPageFragment* first = fragments[index];
        SPDFMarkdownPaginationItem* item = first.itemIndex < items.count ? items[first.itemIndex] : nil;
        SPDFMarkdownTableRowInfo* info = item.tableRowInfo;
        if (!info || info.tableBlockIndex != tableIndex) break;
        NSUInteger runEnd = index;
        CGFloat top = first.pageYOffset;
        CGFloat bottom = first.pageYOffset + first.height;
        while (runEnd + 1 < fragments.count && fragments[runEnd + 1].itemIndex == first.itemIndex) {
            ++runEnd;
            SPDFMarkdownPageFragment* fragment = fragments[runEnd];
            top = MIN(top, fragment.pageYOffset);
            bottom = MAX(bottom, fragment.pageYOffset + fragment.height);
        }
        [rowInfos addObject:info];
        [rowTops addObject:@(top)];
        [rowBottoms addObject:@(bottom)];
        [rowBlockIndexes addObject:@(item.blockIndex)];
        index = runEnd + 1;
    }

    // The table's true first row (GFM tables always lead with the header)
    // reserves the outer margin in its spacing-before; the true last row in its
    // spacing-after. Inset the grid so that margin stays unpainted page. A
    // portion that starts or ends at a page split keeps flush edges.
    if (rowInfos.firstObject.isHeaderRow)
        rowTops[0] = @(MIN(rowTops.firstObject.doubleValue + SPDFMarkdownTableOuterMargin,
                           rowBottoms.firstObject.doubleValue));
    if (rowInfos.lastObject.isLastRow)
        rowBottoms[rowBottoms.count - 1] = @(MAX(rowBottoms.lastObject.doubleValue - SPDFMarkdownTableOuterMargin,
                                                 rowTops.lastObject.doubleValue));
    CGFloat tableTop = rowTops.firstObject.doubleValue;
    CGFloat tableBottom = rowBottoms.lastObject.doubleValue;
    NSArray<NSNumber*>* boundaries = tableInfo.columnBoundaries;
    CGFloat left = boundaries.firstObject.doubleValue;
    CGFloat right = MIN(boundaries.lastObject.doubleValue, printableWidth);
    CGFloat width = right - left;
    if (boundaries.count < 2 || width <= 1 || tableBottom - tableTop < 1) return index;

    // Fills first: the header band and body stripes lie beneath the hairlines.
    for (NSUInteger row = 0; row < rowInfos.count; ++row) {
        SPDFMarkdownTableRowInfo* info = rowInfos[row];
        CGFloat top = rowTops[row].doubleValue;
        CGFloat bottom = rowBottoms[row].doubleValue;
        if (bottom - top < 1) continue;
        BOOL striped = !info.headerRow && info.bodyRowIndex % 2 == 1;
        if (!info.headerRow && !striped) continue;
        SPDFAppendDecoration(decorations,
                             info.headerRow ? SPDFMarkdownPageDecorationTypeTableHeaderBand
                                            : SPDFMarkdownPageDecorationTypeTableStripe,
                             NSMakeRect(left, top, width, bottom - top), rowBlockIndexes[row].unsignedIntegerValue);
    }

    // Horizontal hairlines: the table portion's top edge, one boundary at the
    // top of every following row portion, and a bottom edge kept inside the
    // portion so the closed grid never bleeds past the table.
    SPDFAppendDecoration(decorations, SPDFMarkdownPageDecorationTypeTableGridLine,
                         NSMakeRect(left, tableTop, width, 1), tableIndex);
    for (NSUInteger row = 1; row < rowInfos.count; ++row) {
        SPDFAppendDecoration(decorations, SPDFMarkdownPageDecorationTypeTableGridLine,
                             NSMakeRect(left, rowTops[row].doubleValue, width, 1), tableIndex);
    }
    SPDFAppendDecoration(decorations, SPDFMarkdownPageDecorationTypeTableGridLine,
                         NSMakeRect(left, tableBottom - 1, width, 1), tableIndex);

    // Vertical hairlines at every column boundary, clipped to the printable
    // width when a many-column table overflows the page.
    for (NSNumber* boundary in boundaries) {
        CGFloat x = boundary.doubleValue;
        if (x > printableWidth) continue;
        x = MIN(x, printableWidth - 1);
        SPDFAppendDecoration(decorations, SPDFMarkdownPageDecorationTypeTableGridLine,
                             NSMakeRect(x, tableTop, 1, tableBottom - tableTop), tableIndex);
    }
    return index;
}

void SPDFMarkdownDrawTableDecoration(CGContextRef context, SPDFMarkdownPageDecorationType type, CGRect rect,
                                     SPDFMarkdownTheme* theme) {
    NSColor* color = theme.tableGridColor;
    if (type == SPDFMarkdownPageDecorationTypeTableHeaderBand) color = theme.tableHeaderFillColor;
    if (type == SPDFMarkdownPageDecorationTypeTableStripe) color = theme.tableStripeFillColor;
    NSColor* sRGB = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.blackColor;
    CGContextSetRGBFillColor(context, sRGB.redComponent, sRGB.greenComponent, sRGB.blueComponent,
                             sRGB.alphaComponent);
    CGContextFillRect(context, rect);
}
