#pragma once

#import <AppKit/AppKit.h>

#import "SPDFMacModels.h"
#import "markdown/SPDFMarkdownPaginator.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const NSUInteger SPDFMarkdownMinimapDefaultMaximumPixelDimension;
FOUNDATION_EXPORT const NSUInteger SPDFMarkdownMinimapHardMaximumPixelDimension;

typedef void (^SPDFMarkdownMinimapThumbnailCompletion)(SPDFRenderedPage* _Nullable page, NSImage* _Nullable image);

// Bridges the immutable Markdown pagination plan to the existing PDF minimap.
// Page proxies and A4 geometry are available immediately; thumbnails are
// rendered directly from the vector pagination plan only when requested.
@interface SPDFMacMarkdownMinimapModel : NSObject

@property(nonatomic, readonly, strong) SPDFMarkdownPaginationPlan* paginationPlan;
@property(nonatomic, readonly, copy) NSArray<SPDFRenderedPage*>* pages;

// Canonical, unscaled A4 pages stacked without display gaps. The actual view
// layout belongs to the caller and is supplied through updateViewportPageRects.
@property(nonatomic, readonly, copy) NSArray<NSValue*>* a4PageRects;

// A defensive snapshot of the paged view's current document geometry. These
// properties can be assigned directly to SPDFMinimapView's matching inputs.
@property(nonatomic, readonly, copy) NSArray<NSValue*>* documentPageRects;
@property(nonatomic, readonly) NSRect documentVisibleRect;
@property(nonatomic, readonly) NSSize documentSize;
@property(nonatomic, readonly) CGFloat documentScale;

@property(nonatomic, readonly) NSUInteger maximumThumbnailPixelDimension;
@property(nonatomic, readonly) NSUInteger pendingThumbnailRequestCount;

- (instancetype)initWithPaginationPlan:(SPDFMarkdownPaginationPlan*)paginationPlan
                      attributedString:(NSAttributedString*)attributedString;
- (instancetype)initWithPaginationPlan:(SPDFMarkdownPaginationPlan*)paginationPlan
                      attributedString:(NSAttributedString*)attributedString
        maximumThumbnailPixelDimension:(NSUInteger)maximumPixelDimension NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)updateViewportPageRects:(NSArray<NSValue*>*)pageRects
                    visibleRect:(NSRect)visibleRect
                   documentSize:(NSSize)documentSize
                  documentScale:(CGFloat)documentScale;

// Publishes per-page search-match rects onto the page proxies' `highlights`
// (page-local points with y growing down from the page top — the space
// SPDFMinimapView draws page.highlights in; the paged view's
// pageLocalRectsForRanges: output can be passed straight through). `pages` is
// republished as a FRESH array of the same proxies so the minimap's cached
// strip, keyed on the pages array identity, repaints. nil clears every page.
// Main thread only.
- (void)updateSearchHighlightRects:(nullable NSDictionary<NSNumber*, NSArray<NSValue*>*>*)rectsByPage;

// targetPixelSize is a bounding box. The rendered image always preserves the
// A4 aspect ratio and is hard-capped by maximumThumbnailPixelDimension.
// Duplicate requests for an equal or smaller image share one render. Completion
// and proxy publication always occur on the main thread.
- (void)requestThumbnailForPageIndex:(NSUInteger)pageIndex
                     targetPixelSize:(NSSize)targetPixelSize
                          completion:(nullable SPDFMarkdownMinimapThumbnailCompletion)completion;
- (void)cancelThumbnailRequestForPageIndex:(NSUInteger)pageIndex;
- (void)cancelAllThumbnailRequests;

// Drops cached thumbnails so they are re-rendered from the current plan.
- (void)invalidateThumbnails;
@end

NS_ASSUME_NONNULL_END
