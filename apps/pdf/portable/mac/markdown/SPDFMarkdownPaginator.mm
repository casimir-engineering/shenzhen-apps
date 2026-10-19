#import "SPDFMarkdownPaginator.h"

#import <CoreText/CoreText.h>

#import "SPDFMarkdownDiagramBand.h"
#import "SPDFMarkdownImageRowBand.h"
#import "SPDFMarkdownRenderInternal.h"
#import "SPDFMarkdownTableDecorations.h"
#import "SPDFMarkdownTableLayout.h"

// A4's two edges in points, and the Word-standard one-inch margin reduced 15%
// per user preference. Turning the paper swaps the edges and leaves the margin
// alone, so every margin stays a margin instead of being transposed with it.
static const CGFloat kSPDFMarkdownA4ShortEdge = 595.2756;
static const CGFloat kSPDFMarkdownA4LongEdge = 841.8898;
static const CGFloat kSPDFMarkdownA4Margin = 61.2;

@implementation SPDFMarkdownPageConfiguration
+ (instancetype)A4ConfigurationForOrientation:(SPDFMarkdownPageOrientation)orientation {
    NSSize paper = orientation == SPDFMarkdownPageOrientationLandscape
                       ? NSMakeSize(kSPDFMarkdownA4LongEdge, kSPDFMarkdownA4ShortEdge)
                       : NSMakeSize(kSPDFMarkdownA4ShortEdge, kSPDFMarkdownA4LongEdge);
    CGFloat margin = kSPDFMarkdownA4Margin;
    NSRect printable = NSMakeRect(margin, margin, paper.width - margin * 2, paper.height - margin * 2);
    return [self configurationForPaperSize:paper printableRect:printable];
}
+ (instancetype)A4PortraitConfiguration {
    return [self A4ConfigurationForOrientation:SPDFMarkdownPageOrientationPortrait];
}
+ (instancetype)A4LandscapeConfiguration {
    return [self A4ConfigurationForOrientation:SPDFMarkdownPageOrientationLandscape];
}
+ (instancetype)configurationForPaperSize:(NSSize)paperSize printableRect:(NSRect)printableRect {
    SPDFMarkdownPageConfiguration* value = [SPDFMarkdownPageConfiguration new];
    value.paperSize = paperSize;
    value.printableRect = printableRect;
    value.headingKeepThreshold = 0.75;
    return value;
}
- (CGFloat)topContentInset {
    return self.paperSize.height - NSMaxY(self.printableRect);
}
- (SPDFMarkdownPageOrientation)orientation {
    return self.paperSize.width > self.paperSize.height ? SPDFMarkdownPageOrientationLandscape
                                                        : SPDFMarkdownPageOrientationPortrait;
}
- (id)copyWithZone:(NSZone*)zone {
    SPDFMarkdownPageConfiguration* copy = [[[self class] allocWithZone:zone] init];
    copy.paperSize = self.paperSize;
    copy.printableRect = self.printableRect;
    copy.headingKeepThreshold = self.headingKeepThreshold;
    copy.includesCodeLanguageControlSpacing = self.includesCodeLanguageControlSpacing;
    copy.themeVariant = self.themeVariant;
    copy.preservesImageColors = self.preservesImageColors;
    return copy;
}
@end

@implementation SPDFMarkdownTextLine
- (instancetype)initWithAttributedRange:(NSRange)attributedRange
                                 height:(CGFloat)height
                                xOffset:(CGFloat)xOffset
                         baselineOffset:(CGFloat)baselineOffset
                        rowLocalYOffset:(CGFloat)rowLocalYOffset {
    self = [super init];
    if (self) {
        _attributedRange = attributedRange;
        _height = MAX(height, 0.5);
        _xOffset = MAX(0, xOffset);
        _baselineOffset = MAX(0, baselineOffset);
        _rowLocalYOffset = MAX(0, rowLocalYOffset);
    }
    return self;
}
- (instancetype)initWithAttributedRange:(NSRange)attributedRange
                                 height:(CGFloat)height
                                xOffset:(CGFloat)xOffset
                         baselineOffset:(CGFloat)baselineOffset {
    return [self initWithAttributedRange:attributedRange
                                  height:height
                                 xOffset:xOffset
                          baselineOffset:baselineOffset
                         rowLocalYOffset:0];
}
@end

@implementation SPDFMarkdownPaginationItem
- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                              kind:(SPDFMarkdownBlockKind)kind
                      headingLevel:(NSUInteger)headingLevel
                      tableRowInfo:(SPDFMarkdownTableRowInfo*)tableRowInfo
                       diagramInfo:(SPDFMarkdownDiagramBlockInfo*)diagramInfo
                        bandLayout:(BOOL)bandLayout
                             lines:(NSArray<SPDFMarkdownTextLine*>*)lines {
    self = [super init];
    if (self) {
        _blockIndex = blockIndex;
        _kind = kind;
        _headingLevel = headingLevel;
        _tableRowInfo = tableRowInfo;
        _diagramInfo = diagramInfo;
        _bandLayout = bandLayout || tableRowInfo != nil || diagramInfo != nil;
        _lines = [lines copy];
        CGFloat height = 0;
        if (_bandLayout) {
            // A band's lines share it side by side (table cells, an image
            // row's captions under their images); the band is as tall as its
            // deepest line extent, not the sum of every line.
            for (SPDFMarkdownTextLine* line in lines)
                height = MAX(height, line.rowLocalYOffset + line.height);
        } else {
            for (SPDFMarkdownTextLine* line in lines) height += line.height;
        }
        _measuredHeight = height;
    }
    return self;
}
- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                              kind:(SPDFMarkdownBlockKind)kind
                      headingLevel:(NSUInteger)headingLevel
                      tableRowInfo:(SPDFMarkdownTableRowInfo*)tableRowInfo
                        bandLayout:(BOOL)bandLayout
                             lines:(NSArray<SPDFMarkdownTextLine*>*)lines {
    return [self initWithBlockIndex:blockIndex
                                kind:kind
                        headingLevel:headingLevel
                        tableRowInfo:tableRowInfo
                         diagramInfo:nil
                          bandLayout:bandLayout
                               lines:lines];
}
- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                              kind:(SPDFMarkdownBlockKind)kind
                      headingLevel:(NSUInteger)headingLevel
                      tableRowInfo:(SPDFMarkdownTableRowInfo*)tableRowInfo
                             lines:(NSArray<SPDFMarkdownTextLine*>*)lines {
    return [self initWithBlockIndex:blockIndex
                                kind:kind
                        headingLevel:headingLevel
                        tableRowInfo:tableRowInfo
                          bandLayout:tableRowInfo != nil
                               lines:lines];
}
- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                              kind:(SPDFMarkdownBlockKind)kind
                      headingLevel:(NSUInteger)headingLevel
                             lines:(NSArray<SPDFMarkdownTextLine*>*)lines {
    return [self initWithBlockIndex:blockIndex kind:kind headingLevel:headingLevel tableRowInfo:nil lines:lines];
}
@end

@interface SPDFMarkdownPageFragment ()
- (instancetype)initWithItemIndex:(NSUInteger)itemIndex
                       blockIndex:(NSUInteger)blockIndex
                             line:(SPDFMarkdownTextLine*)line
                      pageYOffset:(CGFloat)pageYOffset
                            scale:(CGFloat)scale
                     continuation:(BOOL)continuation;
@end
@implementation SPDFMarkdownPageFragment
- (instancetype)initWithItemIndex:(NSUInteger)itemIndex
                       blockIndex:(NSUInteger)blockIndex
                             line:(SPDFMarkdownTextLine*)line
                      pageYOffset:(CGFloat)pageYOffset
                            scale:(CGFloat)scale
                     continuation:(BOOL)continuation {
    self = [super init];
    if (self) {
        _itemIndex = itemIndex;
        _blockIndex = blockIndex;
        _attributedRange = line.attributedRange;
        _pageYOffset = pageYOffset;
        _scale = MIN(1, MAX(scale, 0.001));
        _height = line.height * _scale;
        _xOffset = line.xOffset * _scale;
        _baselineOffset = line.baselineOffset * _scale;
        _continuation = continuation;
    }
    return self;
}
@end

@interface SPDFMarkdownPage ()
- (instancetype)initWithIndex:(NSUInteger)index fragments:(NSArray<SPDFMarkdownPageFragment*>*)fragments;
@end
@implementation SPDFMarkdownPage
- (instancetype)initWithIndex:(NSUInteger)index fragments:(NSArray<SPDFMarkdownPageFragment*>*)fragments {
    self = [super init];
    if (self) {
        _pageIndex = index;
        _fragments = [fragments copy];
        CGFloat height = 0;
        for (SPDFMarkdownPageFragment* fragment in fragments)
            height = MAX(height, fragment.pageYOffset + fragment.height);
        _usedHeight = height;
    }
    return self;
}
@end

@interface SPDFMarkdownPaginationPlan ()
- (instancetype)initWithConfiguration:(SPDFMarkdownPageConfiguration*)configuration
                                items:(NSArray<SPDFMarkdownPaginationItem*>*)items
                                pages:(NSArray<SPDFMarkdownPage*>*)pages;
@end
@implementation SPDFMarkdownPaginationPlan
- (instancetype)initWithConfiguration:(SPDFMarkdownPageConfiguration*)configuration
                                items:(NSArray<SPDFMarkdownPaginationItem*>*)items
                                pages:(NSArray<SPDFMarkdownPage*>*)pages {
    self = [super init];
    if (self) {
        _configuration = [configuration copy];
        _items = [items copy];
        _pages = [pages copy];
    }
    return self;
}

- (void)setPreservesImageColors:(BOOL)preservesImageColors {
    _configuration.preservesImageColors = preservesImageColors;
}

- (NSArray<SPDFMarkdownPageDecoration*>*)decorationsForPageIndex:(NSUInteger)pageIndex {
    if (pageIndex >= self.pages.count) return @[];
    return SPDFMarkdownDecorationsForPage(self.pages[pageIndex], self.items,
                                          NSWidth(self.configuration.printableRect));
}

// drawPageAtIndex:attributedString:inContext: lives in
// SPDFMarkdownPaginatorDrawing.mm with the rest of the concrete-palette
// drawing pipeline.
@end

static CGFloat SPDFHeadingSectionLeadHeight(NSArray<SPDFMarkdownPaginationItem*>* items, NSUInteger headingIndex,
                                            CGFloat pageHeight) {
    SPDFMarkdownPaginationItem* heading = items[headingIndex];
    CGFloat height = 0;
    for (NSUInteger i = headingIndex; i < items.count; ++i) {
        SPDFMarkdownPaginationItem* item = items[i];
        if (item.kind == SPDFMarkdownBlockKindPageBreak) break;
        if (i > headingIndex && item.kind == SPDFMarkdownBlockKindHeading && item.headingLevel <= heading.headingLevel)
            break;
        if (item.bandLayout) {
            // Band lines share their band; the atomic band contributes its
            // height once.
            if (height + item.measuredHeight > pageHeight + 0.01) return pageHeight;
            height += item.measuredHeight;
            continue;
        }
        for (SPDFMarkdownTextLine* line in item.lines) {
            if (height + line.height > pageHeight + 0.01) return pageHeight;
            height += line.height;
        }
    }
    return height;
}

static const CGFloat kSPDFMarkdownCodeLanguageControlHeight = 34.0;
static const CGFloat kSPDFMarkdownCodeBoxPadding = 8.0;

static SPDFMarkdownTextLine* SPDFSpacerLine(NSUInteger location, CGFloat height) {
    return [[SPDFMarkdownTextLine alloc] initWithAttributedRange:NSMakeRange(location, 0)
                                                          height:height
                                                         xOffset:0
                                                  baselineOffset:0];
}

// Every configuration reserves real layout space around fenced code so the
// drawn code box has genuine padding bands instead of overdraw. The screen
// opt-in grows the leading band to fit its interactive language control. Each
// band also reserves SPDFMarkdownCodeBoxOuterMargin of unpainted page outside
// the drawn box, so code boxes never sit flush against neighboring text or
// against each other (the decoration insets the box by the same margin).
static NSArray<SPDFMarkdownPaginationItem*>* SPDFItemsForConfiguration(NSArray<SPDFMarkdownPaginationItem*>* items,
                                                                       SPDFMarkdownPageConfiguration* configuration) {
    NSMutableArray<SPDFMarkdownPaginationItem*>* configuredItems = [NSMutableArray arrayWithCapacity:items.count];
    CGFloat leadingHeight = (configuration.includesCodeLanguageControlSpacing ? kSPDFMarkdownCodeLanguageControlHeight
                                                                              : kSPDFMarkdownCodeBoxPadding) +
                            SPDFMarkdownCodeBoxOuterMargin;
    CGFloat trailingHeight = kSPDFMarkdownCodeBoxPadding + SPDFMarkdownCodeBoxOuterMargin;
    for (SPDFMarkdownPaginationItem* item in items) {
        if (item.kind != SPDFMarkdownBlockKindCode || !item.lines.count) {
            [configuredItems addObject:item];
            continue;
        }
        NSMutableArray<SPDFMarkdownTextLine*>* lines = [item.lines mutableCopy];
        [lines insertObject:SPDFSpacerLine(item.lines.firstObject.attributedRange.location, leadingHeight) atIndex:0];
        [lines addObject:SPDFSpacerLine(NSMaxRange(item.lines.lastObject.attributedRange), trailingHeight)];
        [configuredItems addObject:[[SPDFMarkdownPaginationItem alloc] initWithBlockIndex:item.blockIndex
                                                                                     kind:item.kind
                                                                             headingLevel:item.headingLevel
                                                                                    lines:lines]];
    }
    return configuredItems;
}

@implementation SPDFMarkdownPaginator
- (SPDFMarkdownPaginationPlan*)paginateItems:(NSArray<SPDFMarkdownPaginationItem*>*)items
                               configuration:(SPDFMarkdownPageConfiguration*)configuration {
    items = SPDFItemsForConfiguration(items, configuration);
    CGFloat pageHeight = NSHeight(configuration.printableRect);
    if (pageHeight <= 0)
        return [[SPDFMarkdownPaginationPlan alloc] initWithConfiguration:configuration items:items pages:@[]];
    NSMutableArray<SPDFMarkdownPage*>* pages = [NSMutableArray array];
    NSMutableArray<SPDFMarkdownPageFragment*>* current = [NSMutableArray array];
    __block CGFloat used = 0;
    void (^finishPage)(void) = ^{
      [pages addObject:[[SPDFMarkdownPage alloc] initWithIndex:pages.count fragments:[current copy]]];
      [current removeAllObjects];
      used = 0;
    };

    for (NSUInteger itemIndex = 0; itemIndex < items.count; ++itemIndex) {
        SPDFMarkdownPaginationItem* item = items[itemIndex];
        if (item.kind == SPDFMarkdownBlockKindPageBreak) {
            if (current.count) finishPage(); // Leading/repeated/trailing breaks never add blank sheets.
            continue;
        }
        CGFloat remaining = pageHeight - used;
        if (item.kind == SPDFMarkdownBlockKindHeading && used >= pageHeight * configuration.headingKeepThreshold) {
            CGFloat freshLead = SPDFHeadingSectionLeadHeight(items, itemIndex, pageHeight);
            if (freshLead > remaining + 0.01 && current.count) finishPage();
        }
        if (item.kind == SPDFMarkdownBlockKindHeading && item.measuredHeight <= pageHeight &&
            item.measuredHeight > pageHeight - used + 0.01 && current.count)
            finishPage();
        if (item.bandLayout) {
            SPDFMarkdownTableRowInfo* rowInfo = item.tableRowInfo;
            CGFloat rowScale = MIN(1, pageHeight / MAX(item.measuredHeight, 0.5));
            CGFloat rowHeight = item.measuredHeight * rowScale;
            // Keep-with-next mirrors the heading rule: a table header row must
            // not be the last thing on a page — when the header plus the first
            // body row do not both fit the remainder, the table start moves to
            // a fresh page (the lead is capped at one page, like the heading
            // lookahead, so an over-tall body row cannot pin the header).
            if (rowInfo.isHeaderRow && current.count && itemIndex + 1 < items.count) {
                SPDFMarkdownPaginationItem* next = items[itemIndex + 1];
                if (next.tableRowInfo && next.tableRowInfo.tableBlockIndex == rowInfo.tableBlockIndex) {
                    CGFloat lead = MIN(rowHeight + next.measuredHeight, pageHeight);
                    if (lead > remaining + 0.01) finishPage();
                }
            }
            // Rows are atomic: a row never splits across the page break, and a
            // row taller than the printable page scales into one page like any
            // over-tall line.
            if (used + rowHeight > pageHeight + 0.01 && current.count) finishPage();
            for (NSUInteger lineIndex = 0; lineIndex < item.lines.count; ++lineIndex) {
                SPDFMarkdownTextLine* line = item.lines[lineIndex];
                [current addObject:[[SPDFMarkdownPageFragment alloc]
                                       initWithItemIndex:itemIndex
                                              blockIndex:item.blockIndex
                                                    line:line
                                             pageYOffset:used + line.rowLocalYOffset * rowScale
                                                   scale:rowScale
                                            continuation:lineIndex > 0]];
            }
            used += rowHeight;
            continue;
        }
        for (NSUInteger lineIndex = 0; lineIndex < item.lines.count; ++lineIndex) {
            SPDFMarkdownTextLine* line = item.lines[lineIndex];
            CGFloat scale = MIN(1, pageHeight / line.height);
            CGFloat height = line.height * scale;
            if (used + height > pageHeight + 0.01 && current.count) finishPage();
            [current addObject:[[SPDFMarkdownPageFragment alloc] initWithItemIndex:itemIndex
                                                                        blockIndex:item.blockIndex
                                                                              line:line
                                                                       pageYOffset:used
                                                                             scale:scale
                                                                      continuation:lineIndex > 0]];
            used += height;
        }
    }
    if (current.count || pages.count == 0) finishPage();
    return [[SPDFMarkdownPaginationPlan alloc] initWithConfiguration:configuration items:items pages:pages];
}

- (NSArray<SPDFMarkdownPaginationItem*>*)measureRenderedDocument:(SPDFMarkdownRenderedDocument*)document
                                                  containerWidth:(CGFloat)containerWidth {
    if (containerWidth <= 0 || document.attributedString.length == 0) return @[];
    NSTextStorage* storage = [[NSTextStorage alloc] initWithAttributedString:document.attributedString];
    NSLayoutManager* layout = [NSLayoutManager new];
    NSTextContainer* container = [[NSTextContainer alloc] initWithSize:NSMakeSize(containerWidth, CGFLOAT_MAX)];
    container.lineFragmentPadding = 0;
    [layout addTextContainer:container];
    [storage addLayoutManager:layout];
    [layout ensureLayoutForTextContainer:container];

    NSMutableArray* result = [NSMutableArray array];
    // Final column boundaries per table, distributed once from the natural
    // widths at this container width and shared by every row of the table.
    NSMutableDictionary<NSNumber*, NSArray<NSNumber*>*>* tableBoundaries = [NSMutableDictionary dictionary];
    for (SPDFMarkdownRenderedBlock* block in document.renderedBlocks) {
        if (block.kind == SPDFMarkdownBlockKindPageBreak) {
            [result addObject:[[SPDFMarkdownPaginationItem alloc] initWithBlockIndex:block.blockIndex
                kind:block.kind headingLevel:0 lines:@[]]];
            continue;
        }
        if (!block.attributedRange.length || NSMaxRange(block.attributedRange) > storage.length) continue;
        if (block.diagramInfo) {
            // A native diagram is ONE atomic band: its labels are canonical
            // text placed at the resolved layout's own positions.
            SPDFMarkdownPaginationItem* diagramItem =
                SPDFMarkdownMeasureDiagramItem(block, document.attributedString, containerWidth);
            if (diagramItem) [result addObject:diagramItem];
            continue;
        }
        if (block.tableRowInfo.cellRanges.count) {
            // Table rows get content-aware column layout: cells wrap within
            // their own column box and the row band is its tallest cell.
            SPDFMarkdownPaginationItem* rowItem =
                SPDFMarkdownMeasureTableRowItem(block, document.attributedString, containerWidth, tableBoundaries);
            if (rowItem) [result addObject:rowItem];
            continue;
        }
        NSRange glyphRange = [layout glyphRangeForCharacterRange:block.attributedRange actualCharacterRange:nil];
        NSMutableArray* lines = [NSMutableArray array];
        [layout enumerateLineFragmentsForGlyphRange:glyphRange
                                         usingBlock:^(NSRect rect, NSRect usedRect, NSTextContainer* textContainer,
                                                      NSRange lineGlyphRange, BOOL* stop) {
                                           (void)rect;
                                           (void)textContainer;
                                           (void)stop;
                                           NSRange characterRange = [layout characterRangeForGlyphRange:lineGlyphRange
                                                                                       actualGlyphRange:nil];
                                           characterRange = NSIntersectionRange(characterRange, block.attributedRange);
                                           if (!characterRange.length) return;
                                           // locationForGlyphAtIndex: is already relative to the line
                                           // fragment origin; subtracting NSMinY(rect) again would zero
                                           // the baseline of every line after the document's first.
                                           NSPoint glyphLocation =
                                               [layout locationForGlyphAtIndex:lineGlyphRange.location];
                                           CGFloat lineHeight = MAX(NSHeight(rect), NSHeight(usedRect));
                                           CGFloat baseline = MIN(lineHeight, MAX(0, glyphLocation.y));
                                           [lines addObject:[[SPDFMarkdownTextLine alloc]
                                                                initWithAttributedRange:characterRange
                                                                                 height:lineHeight
                                                                                xOffset:NSMinX(usedRect)
                                                                         baselineOffset:baseline]];
                                         }];
        if (lines.count) {
            // An image row with captions re-shapes into an atomic band whose
            // caption lines sit centered under their own images.
            SPDFMarkdownPaginationItem* item =
                SPDFMarkdownImageRowBandItem(block, document.attributedString, layout, container, lines)
                    ?: [[SPDFMarkdownPaginationItem alloc] initWithBlockIndex:block.blockIndex
                                                                         kind:block.kind
                                                                 headingLevel:block.level
                                                                 tableRowInfo:block.tableRowInfo
                                                                        lines:lines];
            [result addObject:item];
        }
    }
    return result;
}
@end
