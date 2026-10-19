#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class SPDFMarkdownPaginationItem;
@class SPDFMarkdownRenderedBlock;
@class SPDFMarkdownTextLine;

// Image rows caption each image below itself. The renderer keeps the captions
// canonical — one trailing caption paragraph, each caption's text exactly once,
// image and caption spans linked by SPDFMarkdownImageRowIndexAttribute — and
// this pass turns that paragraph into custom-positioned lines inside one atomic
// band, so the captions keep riding their images across page breaks. Returns
// nil when the block carries no row captions (every other block measures
// through the paginator's ordinary line pass).
FOUNDATION_EXPORT SPDFMarkdownPaginationItem* _Nullable SPDFMarkdownImageRowBandItem(
    SPDFMarkdownRenderedBlock* block, NSAttributedString* text, NSLayoutManager* layout,
    NSTextContainer* container, NSArray<SPDFMarkdownTextLine*>* lines);

NS_ASSUME_NONNULL_END
