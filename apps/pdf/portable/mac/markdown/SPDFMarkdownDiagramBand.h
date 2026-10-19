#pragma once

#import <AppKit/AppKit.h>

#import "SPDFMarkdownDiagram.h"

NS_ASSUME_NONNULL_BEGIN

@class SPDFMarkdownPageFragment;
@class SPDFMarkdownPaginationItem;
@class SPDFMarkdownRenderedBlock;

// A rendered diagram block: the resolved vector layout plus the canonical
// attributed range of every one of its labels, in the layout's label order.
// The block renderer records this on the diagram's rendered block (the
// paginator carries it onto the block's pagination item), so the measurement
// pass can place each label as its own positioned line and decoration planning
// can hand the shapes to the page draw path without touching pixels.
//
// A diagram is ONE atomic band: `xOrigin` is the band-local left edge of the
// diagram box (list indentation plus the centering offset, bound at the real
// container width by SPDFMarkdownMeasureDiagramItem), and topMargin /
// bottomMargin are the unpainted air the band reserves above and below the
// artwork in place of ordinary paragraph spacing.
@interface SPDFMarkdownDiagramBlockInfo : NSObject
@property(nonatomic, readonly) SPDFMarkdownDiagramLayout* layout;
@property(nonatomic, readonly, copy) NSArray<NSValue*>* labelRanges;
@property(nonatomic, readonly) CGFloat topMargin;
@property(nonatomic, readonly) CGFloat bottomMargin;
@property(nonatomic, readonly) CGFloat depthIndent;
@property(nonatomic, readonly) CGFloat xOrigin;
- (instancetype)initWithLayout:(SPDFMarkdownDiagramLayout*)layout
                   labelRanges:(NSArray<NSValue*>*)labelRanges
                     topMargin:(CGFloat)topMargin
                  bottomMargin:(CGFloat)bottomMargin
                   depthIndent:(CGFloat)depthIndent NS_DESIGNATED_INITIALIZER;
- (instancetype)infoWithXOrigin:(CGFloat)xOrigin;
- (instancetype)init NS_UNAVAILABLE;
@end

// Measures one diagram block into a single atomic band item: a zero-length
// spacer line spanning the whole band (margins included) plus one positioned
// line per label, each centered/left-aligned inside its own box from the
// label's real typographic width. Returns nil when the block carries no
// diagram info.
FOUNDATION_EXPORT SPDFMarkdownPaginationItem* _Nullable SPDFMarkdownMeasureDiagramItem(
    SPDFMarkdownRenderedBlock* block, NSAttributedString* text, CGFloat containerWidth);

// Appends the single shape decoration for the diagram band whose fragments run
// from startIndex, and returns the index of the first fragment past it.
FOUNDATION_EXPORT NSUInteger SPDFMarkdownAppendDiagramDecoration(
    NSArray<SPDFMarkdownPageFragment*>* fragments, NSUInteger startIndex, NSUInteger runEnd,
    SPDFMarkdownPaginationItem* item, NSMutableArray<SPDFMarkdownPageDecoration*>* decorations);

// Paints one diagram's vector shapes into `rect` (already in the drawing
// context's own coordinates), resolving every color role against `variant`.
// Labels are NOT drawn here: they are canonical text and the page's text pass
// paints them on top.
FOUNDATION_EXPORT void SPDFMarkdownDrawDiagramShapes(CGContextRef context, SPDFMarkdownDiagramLayout* layout,
                                                     CGRect rect, SPDFMarkdownThemeVariant variant);

NS_ASSUME_NONNULL_END
