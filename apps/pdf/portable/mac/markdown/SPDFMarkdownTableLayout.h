#pragma once

#import <AppKit/AppKit.h>

#import "SPDFMarkdownPaginator.h"
#import "SPDFMarkdownTableDecorations.h"

NS_ASSUME_NONNULL_BEGIN

// Content-aware GFM table layout shared by the block renderer (natural column
// measurement, provisional boundaries for the flowing-text fallback view) and
// the paginator (final boundaries at the real printable width, per-cell line
// measurement). Cells wrap within their own column box; a row is as tall as
// its tallest cell.

// Horizontal padding kept between a cell's glyphs and its column edges so text
// never touches the drawn vertical grid hairlines.
FOUNDATION_EXPORT const CGFloat SPDFMarkdownTableCellInset;

// Every column keeps at least this width (insets included), so a table with
// one enormous column cannot starve its neighbors to nothing.
FOUNDATION_EXPORT const CGFloat SPDFMarkdownTableMinimumColumnWidth;

// Distributes final column widths from the measured natural widths:
// - a table whose natural widths fit keeps them (compact, GitHub-style);
// - a wider table caps at the available width: columns at or below their fair
//   share keep their natural width, and only the over-wide columns split the
//   remaining budget proportionally (their cells then wrap);
// - a table that cannot even fit the per-column minimum splits the available
//   width evenly.
FOUNDATION_EXPORT NSArray<NSNumber*>* SPDFMarkdownTableColumnWidths(NSArray<NSNumber*>* naturalWidths,
                                                                    CGFloat availableWidth);

// Column edge x positions (count + 1 values) for the given widths, starting at
// leftEdge (the row's list-depth indentation).
FOUNDATION_EXPORT NSArray<NSNumber*>* SPDFMarkdownTableColumnBoundaries(NSArray<NSNumber*>* widths,
                                                                        CGFloat leftEdge);

// Measures one rendered table row at containerWidth into a pagination item:
// one full-band spacer line spanning the row height (so decorations and
// pagination see the exact row band including padding and outer margins), then
// one SPDFMarkdownTextLine per wrapped cell line, each carrying the cell line's
// x offset inside its column box and its row-local y offset. The item's row
// info is rebound to the final column boundaries, computed once per table and
// cached in tableBoundaries keyed by the table's block index.
FOUNDATION_EXPORT SPDFMarkdownPaginationItem* _Nullable SPDFMarkdownMeasureTableRowItem(
    SPDFMarkdownRenderedBlock* block, NSAttributedString* text, CGFloat containerWidth,
    NSMutableDictionary<NSNumber*, NSArray<NSNumber*>*>* tableBoundaries);

NS_ASSUME_NONNULL_END
