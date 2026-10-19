#pragma once

#import <AppKit/AppKit.h>

#import "SPDFMarkdownDecorations.h"
#import "SPDFMarkdownLanguage.h"
#import "SPDFMarkdownHighlighter.h"
#import "SPDFMarkdownModel.h"
#import "SPDFMarkdownAsync.h"

NS_ASSUME_NONNULL_BEGIN

@class SPDFMarkdownTableRowInfo;
@class SPDFMarkdownDiagramBlockInfo;
@class SPDFMarkdownDiagramCache;

FOUNDATION_EXPORT NSAttributedStringKey const SPDFMarkdownBlockIndexAttribute;
FOUNDATION_EXPORT NSAttributedStringKey const SPDFMarkdownBlockKindAttribute;
FOUNDATION_EXPORT NSAttributedStringKey const SPDFMarkdownWikiLinkAttribute;
FOUNDATION_EXPORT NSAttributedStringKey const SPDFMarkdownImageTargetAttribute;
FOUNDATION_EXPORT NSAttributedStringKey const SPDFMarkdownCodeLanguageAttribute;

@interface SPDFMarkdownRenderOptions : NSObject <NSCopying>
@property(nonatomic) CGFloat textSize;
@property(nonatomic) CGFloat codeSize;
@property(nonatomic) CGFloat lineSpacing;
@property(nonatomic) CGFloat paragraphSpacing;
// Uniform typography multiplier, clamped to [0.5, 3.0] (default 1.0). Fonts and
// vertical spacing scale with it; indent constants and image budgets do not.
@property(nonatomic) CGFloat fontScale;
// The reading theme (default Light). Setting it re-derives the five palette
// role colors below from SPDFMarkdownTheme, so a render is deterministic per
// themeVariant; set any custom color AFTER the variant. Copied like fontScale.
@property(nonatomic) SPDFMarkdownThemeVariant themeVariant;
@property(nonatomic) CGFloat contentInset;
// The PRINTABLE BOX of the page this render is destined for, in points, taken
// off the same SPDFMarkdownPageConfiguration the pagination plan is built with
// (SPDFMacMarkdownPlanForRendition). It is what page-sized content is budgeted
// against: diagram figures, image display sizes, the pending remote
// placeholder box, image-row fitting, and the table renderer's provisional
// column distribution all use this box instead of the constant image budgets,
// so a figure uses the whole column and turning the paper (portrait A4's
// 473 pt against landscape's 719 pt) really does re-fit tables, images and
// diagrams rather than leaving them at some constant. NSZeroSize (the default)
// means "no page known" and falls back to the maximumImageWidth /
// maximumImageHeight constants below, which is what every page-less caller —
// and every render before this existed — gets.
@property(nonatomic) NSSize pageContentSize;
// The page-less display budgets: the width/height caps used wherever
// pageContentSize is NSZeroSize.
@property(nonatomic) CGFloat maximumImageWidth;
@property(nonatomic) CGFloat maximumImageHeight;
@property(nonatomic) NSUInteger maximumResourceBytes;
@property(nonatomic) NSUInteger maximumDecodedImagePixels;
// Raw bytes for remote (https-only) images, keyed by
// SPDFMarkdownRemoteImageKeyForTarget output. The session layer downloads
// asynchronously and feeds completed bytes in here; the render consults the
// map synchronously and never performs network work itself. A remote target
// with no entry renders as a fixed-size pending placeholder box (reserving
// layout space for the download), an entry that fails to decode or a target
// in failedRemoteImageTargets renders as the stable "[Image: alt]" text
// placeholder, and non-https remote schemes are always rejected.
@property(nonatomic, copy, nullable) NSDictionary<NSString*, NSData*>* remoteImageData;
@property(nonatomic, copy, nullable) NSSet<NSString*>* failedRemoteImageTargets;
// YES for a document whose remote images must not be fetched (one someone else sent: see
// SPDFMacMarkdownRemoteImagePolicy.h): every remote target renders as the "[Image: alt]" text placeholder, never as
// a pending box waiting for a download that will not come, whatever remoteImageData holds.
@property(nonatomic) BOOL remoteImagesWithheld;
// Height of the pending remote-image placeholder box (width is the printable
// page width when the render carries one, else maximumImageWidth). Unscaled
// by fontScale, like the image budgets.
@property(nonatomic) CGFloat remoteImagePlaceholderHeight;
// Shared, thread-safe render cache for native diagram fences (mermaid /
// sequence / flow — see SPDFMarkdownDiagram.h). One cache lives per document
// session and is carried by REFERENCE through -copyWithZone: (never deep
// copied), so text-size rerenders reuse the resolved layouts whose key still
// matches — and a THEME switch reuses all of them, since a layout carries color
// roles rather than colors. nil (the default) simply means no caching: diagrams
// still render, their geometry is just recomputed every pass.
@property(nonatomic, strong, nullable) SPDFMarkdownDiagramCache* diagramCache;
@property(nonatomic, strong) NSColor* textColor;
@property(nonatomic, strong) NSColor* secondaryTextColor;
@property(nonatomic, strong) NSColor* linkColor;
@property(nonatomic, strong) NSColor* codeBackgroundColor;
@property(nonatomic, strong) NSColor* markHighlightColor;
@property(nonatomic, strong) NSColor* quoteColor;
+ (instancetype)defaultOptions;
// defaultOptions carrying the given variant's palette roles.
+ (instancetype)defaultOptionsForThemeVariant:(SPDFMarkdownThemeVariant)variant;
+ (instancetype)printOptions;
@end

@interface SPDFMarkdownRenderedBlock : NSObject
@property(nonatomic, readonly) NSUInteger blockIndex;
@property(nonatomic, readonly) SPDFMarkdownBlockKind kind;
@property(nonatomic, readonly) NSRange attributedRange;
@property(nonatomic, readonly) NSUInteger level;
@property(nonatomic, readonly) NSUInteger depth;
// Non-nil only for table rows: the row's role and column geometry, recorded by
// the renderer so the pagination plan can draw the table grid decoration
// without re-deriving tab-stop math (see SPDFMarkdownTableDecorations.h).
@property(nonatomic, readonly, nullable) SPDFMarkdownTableRowInfo* tableRowInfo;
// Non-nil only for native diagram fences: the block's resolved vector layout
// and the canonical range of each of its labels (see SPDFMarkdownDiagramBand.h).
// The diagram's LABEL TEXT is part of this block's attributed range, so it is
// selectable, searchable and exported as text like any other paragraph.
@property(nonatomic, readonly, nullable) SPDFMarkdownDiagramBlockInfo* diagramInfo;
- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                              kind:(SPDFMarkdownBlockKind)kind
                   attributedRange:(NSRange)attributedRange
                             level:(NSUInteger)level
                             depth:(NSUInteger)depth
                      tableRowInfo:(nullable SPDFMarkdownTableRowInfo*)tableRowInfo
                       diagramInfo:(nullable SPDFMarkdownDiagramBlockInfo*)diagramInfo
    NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                              kind:(SPDFMarkdownBlockKind)kind
                   attributedRange:(NSRange)attributedRange
                             level:(NSUInteger)level
                             depth:(NSUInteger)depth
                      tableRowInfo:(nullable SPDFMarkdownTableRowInfo*)tableRowInfo;
- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                              kind:(SPDFMarkdownBlockKind)kind
                   attributedRange:(NSRange)attributedRange
                             level:(NSUInteger)level
                             depth:(NSUInteger)depth;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface SPDFMarkdownRenderedHeading : NSObject
@property(nonatomic, readonly) NSUInteger blockIndex;
@property(nonatomic, readonly) NSUInteger level;
@property(nonatomic, readonly, copy) NSString* title;
@property(nonatomic, readonly) NSRange attributedRange;
@end

@interface SPDFMarkdownRenderedDocument : NSObject
@property(nonatomic, readonly, copy) NSAttributedString* attributedString;
@property(nonatomic, readonly, copy) NSArray<SPDFMarkdownRenderedBlock*>* renderedBlocks;
@property(nonatomic, readonly, copy) NSArray<SPDFMarkdownRenderedHeading*>* headings;
- (nullable SPDFMarkdownRenderedBlock*)renderedBlockWithIndex:(NSUInteger)blockIndex;
- (NSArray<SPDFMarkdownSearchMatch*>*)searchForQuery:(NSString*)query
                                       caseSensitive:(BOOL)caseSensitive;
- (NSArray<SPDFMarkdownSearchMatch*>*)searchForQuery:(NSString*)query
                                       caseSensitive:(BOOL)caseSensitive
                                   cancellationToken:(nullable SPDFMarkdownCancellationToken*)cancellationToken;
// Superset of the plain search with an NSRegularExpression path (regex == YES).
// Result shape, non-overlapping semantics, the interactive 4096-code-unit query
// cap, and the cancellation contract (cancelled searches return @[]) match the
// plain path; zero-length regex matches are skipped. An INVALID pattern is the
// one case that returns nil, with the parse failure in `error`.
- (nullable NSArray<SPDFMarkdownSearchMatch*>*)searchForQuery:(NSString*)query
                                                caseSensitive:(BOOL)caseSensitive
                                                        regex:(BOOL)regex
                                            cancellationToken:(nullable SPDFMarkdownCancellationToken*)cancellationToken
                                                        error:(NSError* _Nullable* _Nullable)error;
@end

@interface SPDFMarkdownRenderer : NSObject
@property(nonatomic, readonly) SPDFMarkdownLanguageCatalog* languageCatalog;
- (instancetype)initWithLanguageCatalog:(SPDFMarkdownLanguageCatalog*)languageCatalog NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

// languageOverrides maps code block indexes to a supported language identifier.
- (SPDFMarkdownRenderedDocument*)renderModel:(SPDFMarkdownDocumentModel*)model
                                     options:(SPDFMarkdownRenderOptions*)options
                           languageOverrides:(nullable NSDictionary<NSNumber*, NSString*>*)languageOverrides;
- (nullable SPDFMarkdownRenderedDocument*)renderModel:(SPDFMarkdownDocumentModel*)model
                                               options:(SPDFMarkdownRenderOptions*)options
                                     languageOverrides:(nullable NSDictionary<NSNumber*, NSString*>*)languageOverrides
                                     cancellationToken:(nullable SPDFMarkdownCancellationToken*)cancellationToken;
- (NSTextView*)newSelectableTextViewForRenderedDocument:(SPDFMarkdownRenderedDocument*)document
                                                 options:(SPDFMarkdownRenderOptions*)options;
@end

NS_ASSUME_NONNULL_END
