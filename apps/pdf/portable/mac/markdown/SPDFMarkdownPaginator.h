#pragma once

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>

#import "SPDFMarkdownDecorations.h"
#import "SPDFMarkdownRenderer.h"

NS_ASSUME_NONNULL_BEGIN

// CoreText gives U+FFFC backed by an NSTextAttachment (which carries no
// CTRunDelegate) a tiny default advance, so a plain
// CTLineCreateWithAttributedString would place everything after an inline
// attachment far left of where the NSLayoutManager measurement that produced
// the pagination fragments put it. Every CTLine built from a fragment
// substring — drawing, hit-testing, highlight/selection x-mapping, and the
// attachment offset math — must go through this shared constructor, which
// mirrors each attachment's bounds into a CTRunDelegate (width = bounds width,
// ascent = the bounds' extent above the baseline, descent = any part below),
// matching how TextKit places attachments on the baseline. Caller releases.
FOUNDATION_EXPORT CTLineRef SPDFMarkdownCreateFragmentLine(NSAttributedString* lineString) CF_RETURNS_RETAINED;

// The footer every drawn sheet carries in its bottom margin: "Page 2 of 10".
// One-based, because that is how a reader counts pages.
FOUNDATION_EXPORT NSString* SPDFMarkdownPageFooterText(NSUInteger pageIndex, NSUInteger pageCount);

@class SPDFMarkdownDiagramBlockInfo;
@class SPDFMarkdownTableRowInfo;

// SPDFMarkdownPageOrientation is declared beside SPDFMarkdownThemeVariant in
// SPDFMarkdownDecorations.h, so the session header can name it without pulling
// in the whole paginator.
@interface SPDFMarkdownPageConfiguration : NSObject <NSCopying>
@property(nonatomic) NSSize paperSize;
@property(nonatomic) NSRect printableRect;
@property(nonatomic) CGFloat headingKeepThreshold;
// Screen pagination can reserve space for its interactive code-language control.
// Print and export configurations intentionally default to NO.
@property(nonatomic) BOOL includesCodeLanguageControlSpacing;
// The reading theme the plan's pages are drawn with (default Light). Carried
// by the plan so screen, print, export and copy-page draw the identical
// concrete palette — geometry is theme-independent.
@property(nonatomic) SPDFMarkdownThemeVariant themeVariant;
// Mirrors the reader's "Keep Image Colors in Dark Theme" setting, which since
// 26.9.1-1 defaults to YES (keep the image's own colors). The value is always
// pushed in from the session, which seeds it from settings.yaml
// "darkThemePreservesImages" -- a freshly allocated configuration carries
// whatever the ivar zero-initialises to and that is not the product default.
// Only consulted when themeVariant is Dark, so a Light plan -- every print and
// export plan -- is unaffected whatever this says.
@property(nonatomic) BOOL preservesImageColors;
// Distance from the paper's top edge down to the printable area — the TOP
// margin. Equal to NSMinY(printableRect) (the bottom margin) only when the
// vertical margins are symmetric, so every top-anchored coordinate must use
// this instead of NSMinY(printableRect).
@property(nonatomic, readonly) CGFloat topContentInset;
// DERIVED from paperSize (landscape whenever the paper is wider than tall), so
// a configuration can never disagree with the paper it actually carries and
// -copyWithZone: has nothing extra to copy.
@property(nonatomic, readonly) SPDFMarkdownPageOrientation orientation;
+ (instancetype)A4PortraitConfiguration;
+ (instancetype)A4LandscapeConfiguration;
// A4 in the given orientation. Both A4 factories above route through this, so
// the margins are the same four numbers whichever way the paper is turned.
+ (instancetype)A4ConfigurationForOrientation:(SPDFMarkdownPageOrientation)orientation;
+ (instancetype)configurationForPaperSize:(NSSize)paperSize printableRect:(NSRect)printableRect;
@end

@interface SPDFMarkdownTextLine : NSObject
@property(nonatomic, readonly) NSRange attributedRange;
@property(nonatomic, readonly) CGFloat height;
@property(nonatomic, readonly) CGFloat xOffset;
@property(nonatomic, readonly) CGFloat baselineOffset;
// Vertical offset of this line from the top of its own pagination item. Zero
// for ordinary stacked lines. Table rows place cell lines side by side inside
// the row band, so their lines carry real row-local offsets and the row is
// paginated atomically (see paginateItems:).
@property(nonatomic, readonly) CGFloat rowLocalYOffset;
- (instancetype)initWithAttributedRange:(NSRange)attributedRange
                                 height:(CGFloat)height
                                xOffset:(CGFloat)xOffset
                         baselineOffset:(CGFloat)baselineOffset
                        rowLocalYOffset:(CGFloat)rowLocalYOffset NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithAttributedRange:(NSRange)attributedRange
                                 height:(CGFloat)height
                                xOffset:(CGFloat)xOffset
                         baselineOffset:(CGFloat)baselineOffset;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface SPDFMarkdownPaginationItem : NSObject
@property(nonatomic, readonly) NSUInteger blockIndex;
@property(nonatomic, readonly) SPDFMarkdownBlockKind kind;
@property(nonatomic, readonly) NSUInteger headingLevel;
// Non-nil only for table rows: role and column geometry carried from the
// rendered block so decoration planning can draw the table grid.
@property(nonatomic, readonly, nullable) SPDFMarkdownTableRowInfo* tableRowInfo;
// Non-nil only for native diagram blocks: the resolved vector layout and its
// canonical label ranges, carried from the rendered block so decoration
// planning can emit the diagram's shapes (see SPDFMarkdownDiagramBand.h).
@property(nonatomic, readonly, nullable) SPDFMarkdownDiagramBlockInfo* diagramInfo;
// Band layout: the item's lines are positioned explicitly inside one atomic
// band via rowLocalYOffset instead of stacking, the band's height is its
// deepest line extent, and the band never splits across a page break (an
// over-tall band scales into one page). Always YES for table rows and for
// diagrams; also YES for image rows whose captions sit centered under their
// own images.
@property(nonatomic, readonly) BOOL bandLayout;
@property(nonatomic, readonly, copy) NSArray<SPDFMarkdownTextLine*>* lines;
@property(nonatomic, readonly) CGFloat measuredHeight;
- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                              kind:(SPDFMarkdownBlockKind)kind
                      headingLevel:(NSUInteger)headingLevel
                      tableRowInfo:(nullable SPDFMarkdownTableRowInfo*)tableRowInfo
                       diagramInfo:(nullable SPDFMarkdownDiagramBlockInfo*)diagramInfo
                        bandLayout:(BOOL)bandLayout
                             lines:(NSArray<SPDFMarkdownTextLine*>*)lines NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                              kind:(SPDFMarkdownBlockKind)kind
                      headingLevel:(NSUInteger)headingLevel
                      tableRowInfo:(nullable SPDFMarkdownTableRowInfo*)tableRowInfo
                        bandLayout:(BOOL)bandLayout
                             lines:(NSArray<SPDFMarkdownTextLine*>*)lines;
- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                              kind:(SPDFMarkdownBlockKind)kind
                      headingLevel:(NSUInteger)headingLevel
                      tableRowInfo:(nullable SPDFMarkdownTableRowInfo*)tableRowInfo
                             lines:(NSArray<SPDFMarkdownTextLine*>*)lines;
- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                              kind:(SPDFMarkdownBlockKind)kind
                      headingLevel:(NSUInteger)headingLevel
                             lines:(NSArray<SPDFMarkdownTextLine*>*)lines;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface SPDFMarkdownPageFragment : NSObject
@property(nonatomic, readonly) NSUInteger itemIndex;
@property(nonatomic, readonly) NSUInteger blockIndex;
@property(nonatomic, readonly) NSRange attributedRange;
@property(nonatomic, readonly) CGFloat pageYOffset;
@property(nonatomic, readonly) CGFloat height;
@property(nonatomic, readonly) CGFloat xOffset;
@property(nonatomic, readonly) CGFloat baselineOffset;
@property(nonatomic, readonly) CGFloat scale;
@property(nonatomic, readonly, getter=isContinuation) BOOL continuation;
@end

@interface SPDFMarkdownPage : NSObject
@property(nonatomic, readonly) NSUInteger pageIndex;
@property(nonatomic, readonly, copy) NSArray<SPDFMarkdownPageFragment*>* fragments;
@property(nonatomic, readonly) CGFloat usedHeight;
@end

@interface SPDFMarkdownPaginationPlan : NSObject
@property(nonatomic, readonly, copy) SPDFMarkdownPageConfiguration* configuration;
@property(nonatomic, readonly, copy) NSArray<SPDFMarkdownPaginationItem*>* items;
@property(nonatomic, readonly, copy) NSArray<SPDFMarkdownPage*>* pages;

// Per-page decoration geometry (code boxes, heading rules) in page-content
// coordinates. Print/export draws these itself; the screen canvas consumes the
// same geometry with the same concrete SPDFMarkdownTheme palette (the
// configuration's themeVariant).
- (NSArray<SPDFMarkdownPageDecoration*>*)decorationsForPageIndex:(NSUInteger)pageIndex;

// Retargets the plan's "Keep Image Colors in Dark Theme" answer without
// re-paginating. The flag is consulted only while DRAWING, and geometry does
// not depend on it, so toggling the setting costs a redraw rather than a
// re-render of the whole document.
- (void)setPreservesImageColors:(BOOL)preservesImageColors;
@end

// Concrete-palette page drawing, implemented in SPDFMarkdownPaginatorDrawing.mm.
@interface SPDFMarkdownPaginationPlan (SPDFDrawing)
// Draws the same exact line-fragment plan used by print preview/pagination.
// Decorations are painted first, beneath the planned text.
- (BOOL)drawPageAtIndex:(NSUInteger)pageIndex
       attributedString:(NSAttributedString*)attributedString
              inContext:(CGContextRef)context;
@end

@interface SPDFMarkdownPaginator : NSObject
- (SPDFMarkdownPaginationPlan*)paginateItems:(NSArray<SPDFMarkdownPaginationItem*>*)items
                               configuration:(SPDFMarkdownPageConfiguration*)configuration;
- (NSArray<SPDFMarkdownPaginationItem*>*)measureRenderedDocument:(SPDFMarkdownRenderedDocument*)document
                                                  containerWidth:(CGFloat)containerWidth;
@end

NS_ASSUME_NONNULL_END
