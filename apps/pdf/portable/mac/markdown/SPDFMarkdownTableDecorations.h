#pragma once

#import <AppKit/AppKit.h>

#import "SPDFMarkdownDecorations.h"

NS_ASSUME_NONNULL_BEGIN

@class SPDFMarkdownPageFragment;
@class SPDFMarkdownPaginationItem;

// Geometry and role of one rendered table row. The block renderer records this
// on the row's rendered block (and the paginator carries it onto the row's
// pagination item), so decoration planning never re-derives layout math from
// pixels. Column boundaries are the column edge x positions in page-content
// space — columnCount + 1 values, including the table's left and right edges,
// already offset by the row's list-depth indentation. bodyRowIndex counts body
// rows from 0 across the whole table, so a table split across pages keeps its
// zebra-stripe parity. The renderer records provisional boundaries; the
// paginator's measurement rebinds them to the real printable width through
// rowInfoWithColumnBoundaries:, so plan decorations always match the measured
// cell geometry.
@interface SPDFMarkdownTableRowInfo : NSObject
@property(nonatomic, readonly) NSUInteger tableBlockIndex;
@property(nonatomic, readonly, getter=isHeaderRow) BOOL headerRow;
@property(nonatomic, readonly, getter=isLastRow) BOOL lastRow;
@property(nonatomic, readonly) NSUInteger bodyRowIndex;
@property(nonatomic, readonly, copy) NSArray<NSNumber*>* columnBoundaries;
// Canonical attributed-string range of each cell's text, in row order. Cell
// text stays one contiguous, searchable range per cell.
@property(nonatomic, readonly, copy) NSArray<NSValue*>* cellRanges;
// NSTextAlignment per cell, applied inside the cell's own column box.
@property(nonatomic, readonly, copy) NSArray<NSNumber*>* cellAlignments;
// Content-measured natural width per column (widest single-line cell plus the
// horizontal cell insets, floored at the minimum column width). Shared by all
// rows of one table so measurement can re-distribute at any container width.
@property(nonatomic, readonly, copy) NSArray<NSNumber*>* naturalColumnWidths;
// Symmetric vertical row padding (already fontScale-scaled).
@property(nonatomic, readonly) CGFloat verticalPadding;
// List-depth indentation of the table's left edge.
@property(nonatomic, readonly) CGFloat depthIndent;
- (instancetype)initWithTableBlockIndex:(NSUInteger)tableBlockIndex
                              headerRow:(BOOL)headerRow
                                lastRow:(BOOL)lastRow
                           bodyRowIndex:(NSUInteger)bodyRowIndex
                       columnBoundaries:(NSArray<NSNumber*>*)columnBoundaries
                             cellRanges:(NSArray<NSValue*>*)cellRanges
                         cellAlignments:(NSArray<NSNumber*>*)cellAlignments
                    naturalColumnWidths:(NSArray<NSNumber*>*)naturalColumnWidths
                        verticalPadding:(CGFloat)verticalPadding
                            depthIndent:(CGFloat)depthIndent NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithTableBlockIndex:(NSUInteger)tableBlockIndex
                              headerRow:(BOOL)headerRow
                                lastRow:(BOOL)lastRow
                           bodyRowIndex:(NSUInteger)bodyRowIndex
                       columnBoundaries:(NSArray<NSNumber*>*)columnBoundaries;
// Same row with the boundaries recomputed for a concrete container width.
- (instancetype)rowInfoWithColumnBoundaries:(NSArray<NSNumber*>*)columnBoundaries;
- (instancetype)init NS_UNAVAILABLE;
@end

// Unpainted page margin kept between the table's closed grid and its
// neighbors. The block renderer reserves it in the first row's spacing-before
// and the last row's spacing-after; the decoration geometry insets the grid by
// the same amount at the table's true top and bottom (page-split portions keep
// flush edges at the break).
FOUNDATION_EXPORT const CGFloat SPDFMarkdownTableOuterMargin;

// Appends the GitHub-style table decorations for one table portion on one page:
// a header-row fill band, subtle stripe fills on odd body rows, then the 1px
// hairline grid (fills are emitted before hairlines so the lines always paint
// on top of the bands). fragments[startIndex] must belong to a table row item;
// consecutive fragments of rows from the same table are consumed and the index
// of the first fragment past the table portion is returned. The grid closes at
// the portion's top and bottom, so a table continuing across pages closes at
// the page break and resumes on the next page.
FOUNDATION_EXPORT NSUInteger SPDFMarkdownAppendTableDecorations(
    NSArray<SPDFMarkdownPageFragment*>* fragments, NSUInteger startIndex,
    NSArray<SPDFMarkdownPaginationItem*>* items, CGFloat printableWidth,
    NSMutableArray<SPDFMarkdownPageDecoration*>* decorations);

// Paints one table decoration (header band, stripe, or grid hairline) with the
// given theme's concrete role color. rect is in the drawing context's own
// coordinates; the caller has already mapped page-content geometry.
FOUNDATION_EXPORT void SPDFMarkdownDrawTableDecoration(CGContextRef context,
                                                       SPDFMarkdownPageDecorationType type,
                                                       CGRect rect,
                                                       SPDFMarkdownTheme* theme);

NS_ASSUME_NONNULL_END
