#import "SPDFMarkdownTableLayout.h"

const CGFloat SPDFMarkdownTableCellInset = 8.0;
const CGFloat SPDFMarkdownTableMinimumColumnWidth = 44.0;

NSArray<NSNumber*>* SPDFMarkdownTableColumnWidths(NSArray<NSNumber*>* naturalWidths, CGFloat availableWidth) {
    NSUInteger count = naturalWidths.count;
    if (!count) return @[];
    CGFloat minimum = SPDFMarkdownTableMinimumColumnWidth;
    CGFloat naturalSum = 0;
    for (NSNumber* width in naturalWidths) naturalSum += MAX(width.doubleValue, minimum);
    NSMutableArray<NSNumber*>* widths = [NSMutableArray arrayWithCapacity:count];
    if (naturalSum <= availableWidth + 0.01) {
        // Compact, GitHub-style: a table narrower than the page keeps its
        // natural content widths instead of stretching to fill.
        for (NSNumber* width in naturalWidths) [widths addObject:@(MAX(width.doubleValue, minimum))];
        return widths;
    }
    CGFloat minimumSum = minimum * count;
    if (availableWidth <= minimumSum + 0.01) {
        // Degenerate: even the per-column minimum overflows. Share the page
        // evenly so every column still gets a box.
        CGFloat even = MAX(1.0, availableWidth / count);
        for (NSUInteger i = 0; i < count; ++i) [widths addObject:@(even)];
        return widths;
    }
    // Cap at the printable width with a fair-share waterfall: walking the
    // columns narrowest first, a column at or below its fair share of the
    // remaining budget keeps its natural width; the over-wide columns split
    // the rest equally (their cells wrap).
    // The fair share never drops below the minimum because the even-split
    // branch above already handled availableWidth <= minimum * count.
    NSMutableArray<NSNumber*>* order = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; ++i) [order addObject:@(i)];
    [order sortUsingComparator:^NSComparisonResult(NSNumber* left, NSNumber* right) {
      CGFloat a = naturalWidths[left.unsignedIntegerValue].doubleValue;
      CGFloat b = naturalWidths[right.unsignedIntegerValue].doubleValue;
      if (a == b) return NSOrderedSame;
      return a < b ? NSOrderedAscending : NSOrderedDescending;
    }];
    for (NSUInteger i = 0; i < count; ++i) [widths addObject:@(minimum)];
    CGFloat budget = availableWidth;
    for (NSUInteger position = 0; position < count; ++position) {
        NSUInteger column = order[position].unsignedIntegerValue;
        CGFloat natural = MAX(naturalWidths[column].doubleValue, minimum);
        NSUInteger remaining = count - position;
        if (natural <= budget / remaining + 0.01) {
            widths[column] = @(natural);
            budget -= natural;
            continue;
        }
        // Water filling must keep the same floor for every remaining column.
        // Proportional sharing lets one huge description starve another column
        // below the minimum (even below one glyph plus its insets).
        CGFloat share = budget / remaining;
        for (NSUInteger rest = position; rest < count; ++rest)
            widths[order[rest].unsignedIntegerValue] = @(share);
        break;
    }
    return widths;
}

NSArray<NSNumber*>* SPDFMarkdownTableColumnBoundaries(NSArray<NSNumber*>* widths, CGFloat leftEdge) {
    NSMutableArray<NSNumber*>* boundaries = [NSMutableArray arrayWithCapacity:widths.count + 1];
    CGFloat x = leftEdge;
    [boundaries addObject:@(x)];
    for (NSNumber* width in widths) {
        x += width.doubleValue;
        [boundaries addObject:@(x)];
    }
    return boundaries;
}

// One reusable TextKit stack per measured cell keeps attachment-aware wrapping
// (CTFramesetter would collapse NSTextAttachment runs) without rebuilding
// layout objects for every cell.
static NSArray<NSNumber*>* SPDFBoundariesForTable(SPDFMarkdownTableRowInfo* info, CGFloat containerWidth,
                                                  NSMutableDictionary<NSNumber*, NSArray<NSNumber*>*>* cache) {
    NSArray<NSNumber*>* boundaries = cache[@(info.tableBlockIndex)];
    if (boundaries) return boundaries;
    CGFloat available = MAX(SPDFMarkdownTableMinimumColumnWidth, containerWidth - info.depthIndent);
    NSArray<NSNumber*>* widths = SPDFMarkdownTableColumnWidths(info.naturalColumnWidths, available);
    boundaries = SPDFMarkdownTableColumnBoundaries(widths, info.depthIndent);
    cache[@(info.tableBlockIndex)] = boundaries;
    return boundaries;
}

SPDFMarkdownPaginationItem* SPDFMarkdownMeasureTableRowItem(
    SPDFMarkdownRenderedBlock* block, NSAttributedString* text, CGFloat containerWidth,
    NSMutableDictionary<NSNumber*, NSArray<NSNumber*>*>* tableBoundaries) {
    SPDFMarkdownTableRowInfo* info = block.tableRowInfo;
    if (!info || !info.cellRanges.count || containerWidth <= 0) return nil;
    NSArray<NSNumber*>* boundaries = SPDFBoundariesForTable(info, containerWidth, tableBoundaries);
    if (boundaries.count < 2) return nil;
    SPDFMarkdownTableRowInfo* boundInfo = [info rowInfoWithColumnBoundaries:boundaries];

    NSTextStorage* storage = [NSTextStorage new];
    NSLayoutManager* layout = [NSLayoutManager new];
    NSTextContainer* container = [[NSTextContainer alloc] initWithSize:NSMakeSize(100, CGFLOAT_MAX)];
    container.lineFragmentPadding = 0;
    [layout addTextContainer:container];
    [storage addLayoutManager:layout];

    // The first row (GFM tables lead with the header) reserves the table's
    // unpainted outer margin above its band, the last row below — the same
    // space the renderer reserves in the row paragraph spacing, and the same
    // amount the grid decoration insets away from.
    CGFloat contentTop = (info.isHeaderRow ? SPDFMarkdownTableOuterMargin : 0) + info.verticalPadding;
    CGFloat bottomMargin = info.isLastRow ? SPDFMarkdownTableOuterMargin : 0;
    NSMutableArray<SPDFMarkdownTextLine*>* cellLines = [NSMutableArray array];
    CGFloat maxCellHeight = 0;
    NSUInteger columnCount = boundaries.count - 1;
    for (NSUInteger i = 0; i < info.cellRanges.count && i < columnCount; ++i) {
        NSRange cellRange = info.cellRanges[i].rangeValue;
        if (!cellRange.length || NSMaxRange(cellRange) > text.length) continue;
        CGFloat columnLeft = boundaries[i].doubleValue;
        CGFloat contentWidth =
            MAX(1.0, boundaries[i + 1].doubleValue - columnLeft - 2 * SPDFMarkdownTableCellInset);
        NSTextAlignment alignment =
            i < info.cellAlignments.count ? (NSTextAlignment)info.cellAlignments[i].integerValue
                                          : NSTextAlignmentLeft;
        NSMutableAttributedString* cell = [[text attributedSubstringFromRange:cellRange] mutableCopy];
        // Measure with the row's line spacing but none of its row-level
        // indents, tabs, or paragraph spacing; alignment is applied manually
        // per line inside the column box below.
        NSParagraphStyle* rowStyle = [cell attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL];
        NSMutableParagraphStyle* measureStyle = [NSMutableParagraphStyle new];
        measureStyle.lineSpacing = rowStyle.lineSpacing;
        measureStyle.lineBreakMode = NSLineBreakByWordWrapping;
        [cell addAttribute:NSParagraphStyleAttributeName value:measureStyle range:NSMakeRange(0, cell.length)];
        [storage setAttributedString:cell];
        container.size = NSMakeSize(contentWidth, CGFLOAT_MAX);
        [layout ensureLayoutForTextContainer:container];
        __block CGFloat cellHeight = 0;
        [layout enumerateLineFragmentsForGlyphRange:[layout glyphRangeForTextContainer:container]
                                         usingBlock:^(NSRect rect, NSRect usedRect, NSTextContainer* textContainer,
                                                      NSRange lineGlyphRange, BOOL* stop) {
                                           (void)textContainer;
                                           (void)stop;
                                           NSRange characterRange =
                                               [layout characterRangeForGlyphRange:lineGlyphRange
                                                                  actualGlyphRange:nil];
                                           if (!characterRange.length) return;
                                           NSPoint glyphLocation =
                                               [layout locationForGlyphAtIndex:lineGlyphRange.location];
                                           CGFloat lineHeight = MAX(NSHeight(rect), NSHeight(usedRect));
                                           CGFloat baseline = MIN(lineHeight, MAX(0, glyphLocation.y));
                                           CGFloat usedWidth = MIN(contentWidth, MAX(0, NSMaxX(usedRect)));
                                           CGFloat shift = 0;
                                           if (alignment == NSTextAlignmentRight) shift = contentWidth - usedWidth;
                                           if (alignment == NSTextAlignmentCenter)
                                               shift = (contentWidth - usedWidth) / 2;
                                           NSRange canonical =
                                               NSMakeRange(cellRange.location + characterRange.location,
                                                           characterRange.length);
                                           [cellLines addObject:[[SPDFMarkdownTextLine alloc]
                                                                    initWithAttributedRange:canonical
                                                                                     height:lineHeight
                                                                                    xOffset:columnLeft +
                                                                                            SPDFMarkdownTableCellInset +
                                                                                            MAX(0, shift)
                                                                             baselineOffset:baseline
                                                                            rowLocalYOffset:contentTop +
                                                                                            MAX(0, NSMinY(rect))]];
                                           cellHeight = MAX(cellHeight, NSMaxY(rect));
                                         }];
        maxCellHeight = MAX(maxCellHeight, cellHeight);
    }
    if (maxCellHeight <= 0) {
        // An all-empty row still reserves one text line of height.
        NSFont* font = block.attributedRange.location < text.length
                           ? [text attribute:NSFontAttributeName
                                     atIndex:block.attributedRange.location
                              effectiveRange:NULL]
                           : nil;
        maxCellHeight = [layout defaultLineHeightForFont:font ?: [NSFont systemFontOfSize:15]];
    }
    CGFloat rowHeight = contentTop + maxCellHeight + info.verticalPadding + bottomMargin;

    // The zero-length spacer line spans the exact row band (padding and outer
    // margins included), so pagination fragments, the grid decoration envelope,
    // and hit-testing all see the true row extent even where cells are short.
    NSMutableArray<SPDFMarkdownTextLine*>* lines = [NSMutableArray arrayWithCapacity:cellLines.count + 1];
    [lines addObject:[[SPDFMarkdownTextLine alloc]
                         initWithAttributedRange:NSMakeRange(block.attributedRange.location, 0)
                                          height:rowHeight
                                         xOffset:0
                                  baselineOffset:0
                                 rowLocalYOffset:0]];
    [lines addObjectsFromArray:cellLines];
    return [[SPDFMarkdownPaginationItem alloc] initWithBlockIndex:block.blockIndex
                                                             kind:block.kind
                                                     headingLevel:block.level
                                                     tableRowInfo:boundInfo
                                                            lines:lines];
}
