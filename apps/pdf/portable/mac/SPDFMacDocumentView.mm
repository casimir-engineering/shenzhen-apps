#import "SPDFMacDocumentView.h"
#import "SPDFMacEmptyDocumentView.h"
#import "SPDFMacCursorOverlay.h"
#import "SPDFMacDelayedLinkActivation.h"
#import "SPDFMacFitGeometry.h"
#import "SPDFMacPageRendering.h"
#import "SPDFMacSupport.h"

#include <math.h>

static const CGFloat kPageMargin = 44.0;
static const CGFloat kPageGap = 26.0;
static const CGFloat kSelectionOverlayAlpha = 0.20;

// Launch profiling (SPDF_LAUNCH_PROFILE=1): logs the first completed drawRect
// that painted actual document pages — i.e. the first visible paint.
static void spdf_launch_log_first_document_paint(NSUInteger pageCount, double startMs) {
    if (startMs <= 0.0 || pageCount == 0) return;
    static BOOL logged;
    if (logged) return;
    logged = YES;
    spdf_launch_profile_log(@"first document drawRect complete pages=%lu draw=%.1fms", (unsigned long)pageCount,
                            spdf_zoom_profile_now_ms() - startMs);
}

@implementation SPDFDocumentView {
    BOOL _isPanning;
    BOOL _isSelecting;
    BOOL _rightMouseMoved;
    NSPoint _panStartInWindow;
    NSPoint _panStartOrigin;
    NSPoint _lastPanPoint;
    NSTimeInterval _lastPanTime;
    NSPoint _panVelocity;
    NSTimer* _inertiaTimer;
    NSInteger _selectionPageIndex;
    NSPoint _selectionStart;
    // Click-vs-drag decision for link activation: the press is recorded here and
    // the link (if any) at the PRESS point is only opened on mouse-up when the
    // gesture never became a selection drag (see SPDFMacCursorRegions.h).
    SPDFLinkClickGesture _linkGesture;
    NSInteger _linkGesturePageIndex;
    NSPoint _linkGesturePagePoint;
    SPDFMacDelayedLinkActivation* _pendingLinkActivation;
    // Where the document sat before the most recent in-document link jump, so
    // the second click of a double/triple click can put it back and select at
    // the point the user actually pressed. Live for exactly one click run.
    NSPoint _linkUndoOrigin;
    NSInteger _linkUndoPageIndex;
    BOOL _linkUndoAvailable;
    NSTrackingArea* _trackingArea;
    NSDictionary* _hoveredComment;
    BOOL _layoutCacheValid;
    NSArray<SPDFRenderedPage*>* _layoutPages;
    NSArray<NSValue*>* _layoutPageSizes;
    NSArray<NSValue*>* _layoutContinuousPageRects;
    NSSize _layoutBoundsSize;
    CGFloat _layoutViewportWidth;
    CGFloat _layoutViewportHeight;
    CGFloat _layoutEffectiveBackingScale;
    CGFloat _layoutZoom;
    BOOL _layoutPresentationMode;
    CGFloat _layoutWidestPage;
    CGFloat _layoutContinuousDocumentHeight;
    // Bumped on every layout rebuild/invalidation so the page-index memo below
    // can tell when it is stale.
    NSUInteger _layoutGeneration;
    // Memo for pageIndexForVisibleRect: — it is O(total pages) and called several
    // times per scroll event with the same rect; cache the result for a given
    // (rect, currentPage, layout generation).
    NSRect _pageIndexMemoRect;
    NSInteger _pageIndexMemoCurrentPage;
    NSUInteger _pageIndexMemoGeneration;
    NSInteger _pageIndexMemoResult;
    BOOL _pageIndexMemoValid;
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    (void)event;
    return YES;
}

- (void)copy:(id)sender {
    [self.reader copySelection:sender];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) [self removeTrackingArea:_trackingArea];
    // ActiveAlways (was ActiveInKeyWindow) so cursor feedback works over
    // unfocused windows like the app's other hover affordances. Comment hover
    // previews keep their historical key-window-only gating in mouseMoved:.
    _trackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways
               owner:self
            userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)setPages:(NSArray<SPDFRenderedPage*>*)pages {
    [_pendingLinkActivation cancel];
    _linkUndoAvailable = NO;
    _pages = [pages copy];
    if (_pages.count) SPDFHideEmptyDocumentView(self);
    [self invalidateLayoutCache];
    [self setNeedsDisplay:YES];
}

- (void)refreshRenderedPages:(NSArray<SPDFRenderedPage*>*)pages changedPageIndex:(NSInteger)changedIndex {
    _pages = [pages copy];
    // The caller guarantees page SIZES are unchanged (image-only update), so the
    // laid-out rects are still valid. Re-point the layout cache at the new array
    // so ensureLayoutCache's identity check passes instead of rebuilding, and
    // leave _layoutGeneration untouched so the page-index memo stays valid.
    if (_layoutCacheValid) _layoutPages = _pages;
    NSRect changedRect = changedIndex >= 0 ? [self rectForPageAtIndex:changedIndex] : NSZeroRect;
    if (!NSIsEmptyRect(changedRect))
        [self setNeedsDisplayInRect:changedRect];
    else
        [self setNeedsDisplay:YES];
}

- (void)setZoom:(CGFloat)zoom {
    if (_zoom == zoom) return;
    _zoom = zoom;
    [self invalidateLayoutCache];
}

- (void)setViewportWidthHint:(CGFloat)viewportWidthHint {
    if (_viewportWidthHint == viewportWidthHint) return;
    _viewportWidthHint = viewportWidthHint;
    [self invalidateLayoutCache];
}

- (void)setViewportHeightHint:(CGFloat)viewportHeightHint {
    if (_viewportHeightHint == viewportHeightHint) return;
    _viewportHeightHint = viewportHeightHint;
    [self invalidateLayoutCache];
}

- (void)setBackingScale:(CGFloat)backingScale {
    if (_backingScale == backingScale) return;
    _backingScale = backingScale;
    [self invalidateLayoutCache];
}

- (void)setPresentationMode:(BOOL)presentationMode {
    if (_presentationMode == presentationMode) return;
    _presentationMode = presentationMode;
    [self invalidateLayoutCache];
}

- (void)setFrameSize:(NSSize)newSize {
    NSSize oldSize = self.frame.size;
    [super setFrameSize:newSize];
    if (fabs(oldSize.width - newSize.width) > 0.001) [self invalidateLayoutCache];
}

- (void)setBoundsSize:(NSSize)newSize {
    NSSize oldSize = self.bounds.size;
    [super setBoundsSize:newSize];
    if (fabs(oldSize.width - newSize.width) > 0.001) [self invalidateLayoutCache];
}

// drawRect: always fills its whole dirty rect with an opaque background, so the
// view is opaque — telling AppKit lets it skip compositing anything behind it
// during scroll.
- (BOOL)isOpaque {
    return YES;
}

- (void)invalidateLayoutCache {
    _layoutCacheValid = NO;
    _layoutPages = nil;
    _layoutPageSizes = nil;
    _layoutContinuousPageRects = nil;
    _layoutGeneration++;
    _pageIndexMemoValid = NO;
}

- (CGFloat)viewportWidth {
    CGFloat width = self.viewportWidthHint > 1.0 ? self.viewportWidthHint : NSWidth(self.bounds);
    NSScrollView* scrollView = self.enclosingScrollView;
    if (scrollView) width = MAX(width, scrollView.contentSize.width);
    return width;
}

// Viewport height for the vertical-inset math. Unlike viewportWidth there is no
// bounds fallback — this view's own height IS the laid-out canvas height — so
// with no hint and no scroll view this returns 0 and the layout keeps the full
// decorative inset (spdf_mac_vertical_canvas_inset's viewport-unknown case).
- (CGFloat)viewportHeight {
    CGFloat height = self.viewportHeightHint > 1.0 ? self.viewportHeightHint : 0.0;
    NSScrollView* scrollView = self.enclosingScrollView;
    if (scrollView) height = MAX(height, scrollView.contentSize.height);
    return height;
}

- (void)ensureLayoutCache {
    CGFloat viewportWidth = [self viewportWidth];
    CGFloat viewportHeight = [self viewportHeight];
    CGFloat effectiveBackingScale = spdf_mac_effective_backing_scale(self.backingScale, self.window);
    NSSize boundsSize = self.bounds.size;
    BOOL boundsWidthMatches = fabs(_layoutBoundsSize.width - boundsSize.width) <= 0.001;
    if (_layoutCacheValid && _layoutPages == self.pages && _layoutZoom == self.zoom &&
        _layoutPresentationMode == self.presentationMode &&
        _layoutViewportWidth == viewportWidth && _layoutViewportHeight == viewportHeight &&
        _layoutEffectiveBackingScale == effectiveBackingScale && boundsWidthMatches)
        return;
    // About to rebuild the layout — the page rects change, so the page-index memo
    // is stale.
    _layoutGeneration++;
    _pageIndexMemoValid = NO;

    CGFloat pageMargin = self.presentationMode ? 0.0 : kPageMargin;
    CGFloat pageGap = self.presentationMode ? 0.0 : kPageGap;
    NSMutableArray<NSValue*>* pageSizes = [NSMutableArray arrayWithCapacity:self.pages.count];
    NSMutableArray<NSValue*>* continuousRects = [NSMutableArray arrayWithCapacity:self.pages.count];

    CGFloat widestPage = 0.0;
    CGFloat tallestPage = 0.0;
    for (SPDFRenderedPage* page in self.pages) {
        NSSize pageSize = spdf_mac_view_size_for_page(page, self.zoom, effectiveBackingScale);
        [pageSizes addObject:[NSValue valueWithSize:pageSize]];
        widestPage = MAX(widestPage, pageSize.width);
        tallestPage = MAX(tallestPage, pageSize.height);
    }

    // Center every page on the same vertical axis — the canvas midline — so a
    // page wider than the viewport (e.g. an oversized schematic) shares its
    // midline with the normal pages instead of being pinned to the left while
    // the narrow pages sit centered in the viewport. The canvas is as wide as the
    // widest page, so center within max(viewportWidth, widestPage); for a uniform
    // document this equals viewportWidth, leaving the prior layout unchanged.
    CGFloat layoutWidth = MAX(viewportWidth, widestPage);
    // Exact-viewport fit: the outer top/bottom inset collapses to 0 as the
    // tallest page reaches the viewport height (a fit page's top sits at the
    // viewport top), and a single page shorter than the viewport is centered
    // vertically. See SPDFMacFitGeometry.h.
    CGFloat verticalInset =
        spdf_mac_vertical_canvas_inset(self.pages.count, tallestPage, viewportHeight, pageMargin / 2.0);
    CGFloat continuousY = verticalInset;
    for (NSUInteger i = 0; i < self.pages.count; ++i) {
        NSSize pageSize = [pageSizes[i] sizeValue];
        CGFloat x = floor((layoutWidth - pageSize.width) / 2.0);
        // The decorative side margin collapses within one margin of exact fit,
        // so a near-fit page stays centered instead of being pushed off-axis.
        CGFloat minX = MIN(spdf_mac_horizontal_canvas_margin(pageSize.width, layoutWidth, pageMargin) / 2.0, x);
        NSRect continuousRect =
            NSMakeRect(MAX(minX, spdf_mac_pixel_snapped_origin(x, effectiveBackingScale)),
                       spdf_mac_pixel_snapped_origin(continuousY, effectiveBackingScale), pageSize.width,
                       pageSize.height);
        [continuousRects addObject:[NSValue valueWithRect:continuousRect]];
        continuousY += pageSize.height + pageGap;
    }

    _layoutPages = self.pages;
    _layoutPageSizes = pageSizes;
    _layoutContinuousPageRects = continuousRects;
    _layoutBoundsSize = boundsSize;
    _layoutViewportWidth = viewportWidth;
    _layoutViewportHeight = viewportHeight;
    _layoutEffectiveBackingScale = effectiveBackingScale;
    _layoutZoom = self.zoom;
    _layoutPresentationMode = self.presentationMode;
    _layoutWidestPage = widestPage;
    // Symmetric outer chrome: content ends at (continuousY - pageGap); the same
    // collapsed inset closes the canvas below, so at exact fit the document
    // height equals the page stack exactly (a single fit page is unscrollable).
    _layoutContinuousDocumentHeight = self.pages.count == 0 ? 0.0 : continuousY - pageGap + verticalInset;
    _layoutCacheValid = YES;
}

- (NSSize)cachedViewSizeForPageAtIndex:(NSInteger)pageIndex {
    [self ensureLayoutCache];
    if (pageIndex < 0 || pageIndex >= (NSInteger)_layoutPageSizes.count) return NSZeroSize;
    return [_layoutPageSizes[(NSUInteger)pageIndex] sizeValue];
}

- (NSRect)continuousRectForPageAtIndex:(NSInteger)pageIndex {
    [self ensureLayoutCache];
    if (pageIndex < 0 || pageIndex >= (NSInteger)_layoutContinuousPageRects.count) return NSZeroRect;
    return [_layoutContinuousPageRects[(NSUInteger)pageIndex] rectValue];
}

- (CGFloat)widestPage {
    [self ensureLayoutCache];
    return _layoutWidestPage;
}

- (CGFloat)continuousDocumentHeight {
    [self ensureLayoutCache];
    return _layoutContinuousDocumentHeight;
}

- (NSInteger)boundedPageIndex:(NSInteger)pageIndex {
    if (self.pages.count == 0) return 0;
    return MAX(0, MIN(pageIndex, (NSInteger)self.pages.count - 1));
}

- (NSSize)documentSizeForClipSize:(NSSize)clipSize {
    CGFloat pageMargin = self.presentationMode ? 0.0 : kPageMargin;
    CGFloat widestPage = [self widestPage];
    // The decorative side margin collapses near exact fit (see
    // SPDFMacFitGeometry.h) so a fit-width/fit-page document never gains a
    // horizontal scroller from chrome alone.
    CGFloat width =
        MAX(clipSize.width, widestPage + spdf_mac_horizontal_canvas_margin(widestPage, clipSize.width, pageMargin));
    CGFloat height = pageMargin;

    if (self.pages.count == 0) return NSMakeSize(MAX(clipSize.width, 1), MAX(clipSize.height, 1));

    // Presentation mode shows exactly one page (the current one) fit to and
    // centered in the viewport, with no scrolling — the document view is a
    // single viewport and page changes just swap which page is drawn.
    if (self.presentationMode) return NSMakeSize(clipSize.width, clipSize.height);

    height = [self continuousDocumentHeight];
    return NSMakeSize(width, MAX(height, clipSize.height));
}

- (NSRect)presentationRectForPageAtIndex:(NSInteger)pageIndex {
    // Only the current page is shown in presentation mode, centered in the
    // single-viewport document view at its current view size. Other pages are
    // placed far offscreen so nothing else is drawn or hit-tested.
    NSInteger current = MAX(0, MIN(self.currentPageIndex, (NSInteger)self.pages.count - 1));
    if (pageIndex != current) return NSMakeRect(0.0, -1.0e7, 0.0, 0.0);
    CGFloat backingScale = spdf_mac_effective_backing_scale(self.backingScale, self.window);
    NSSize pageSize = spdf_mac_view_size_for_page(self.pages[(NSUInteger)current], self.zoom, backingScale);
    NSRect bounds = self.bounds;
    CGFloat x = spdf_mac_pixel_snapped_origin(NSMinX(bounds) + (NSWidth(bounds) - pageSize.width) / 2.0,
                                               backingScale);
    CGFloat y = spdf_mac_pixel_snapped_origin(NSMinY(bounds) + (NSHeight(bounds) - pageSize.height) / 2.0,
                                               backingScale);
    return NSMakeRect(x, y, pageSize.width, pageSize.height);
}

- (NSRect)rectForPageAtIndex:(NSInteger)pageIndex {
    if (pageIndex < 0 || pageIndex >= (NSInteger)self.pages.count) return NSZeroRect;
    if (self.presentationMode) return [self presentationRectForPageAtIndex:pageIndex];
    return [self continuousRectForPageAtIndex:pageIndex];
}

- (NSInteger)pageIndexForVisibleRect:(NSRect)visibleRect {
    if (self.pages.count == 0) return 0;

    // This is O(total pages) and is called several times per scroll event with an
    // identical rect (page-change check + horizontal lock, etc.). Memoize on
    // (rect, currentPage, layout generation) so the repeats are O(1).
    [self ensureLayoutCache];
    if (_pageIndexMemoValid && _pageIndexMemoGeneration == _layoutGeneration &&
        _pageIndexMemoCurrentPage == self.currentPageIndex && NSEqualRects(visibleRect, _pageIndexMemoRect))
        return _pageIndexMemoResult;

    NSInteger bestPage = self.currentPageIndex;
    CGFloat bestOverlap = -1;
    CGFloat visibleMidY = NSMidY(visibleRect);
    CGFloat visibleMaxY = NSMaxY(visibleRect);
    CGFloat bestCenterDistance = CGFLOAT_MAX;
    CGFloat closestDistance = CGFLOAT_MAX;
    for (SPDFRenderedPage* page in self.pages) {
        NSRect pageRect = [self rectForPageAtIndex:page.pageIndex];
        CGFloat overlap = NSHeight(NSIntersectionRect(visibleRect, pageRect));
        CGFloat centerDistance = fabs(NSMidY(pageRect) - visibleMidY);
        if (overlap > bestOverlap + 0.5 ||
            (overlap > 0.0 && fabs(overlap - bestOverlap) <= 0.5 && centerDistance < bestCenterDistance)) {
            bestOverlap = overlap;
            bestCenterDistance = centerDistance;
            bestPage = page.pageIndex;
        }
        if (overlap <= 0.0) {
            CGFloat distance =
                visibleMidY < NSMinY(pageRect) ? NSMinY(pageRect) - visibleMidY : visibleMidY - NSMaxY(pageRect);
            if (distance < closestDistance) {
                closestDistance = distance;
                if (bestOverlap <= 0.0) bestPage = page.pageIndex;
            }
        }
        // Pages are laid out in monotonically increasing Y; once one starts below
        // the visible rect, every later page is further below and cannot win.
        if (NSMinY(pageRect) > visibleMaxY) break;
    }

    _pageIndexMemoRect = visibleRect;
    _pageIndexMemoCurrentPage = self.currentPageIndex;
    _pageIndexMemoGeneration = _layoutGeneration;
    _pageIndexMemoResult = bestPage;
    _pageIndexMemoValid = YES;
    return bestPage;
}

- (void)drawPage:(SPDFRenderedPage*)page inRect:(NSRect)pageRect dirtyRect:(NSRect)dirtyRect {
    // Cached once instead of allocated per page per frame — the 12pt blurred
    // shadow is the same for every page, and the alloc showed up on the trackpad
    // scroll path (drawPage runs for every page touching the exposed strip).
    static NSShadow* pageShadow;
    static dispatch_once_t pageShadowOnce;
    dispatch_once(&pageShadowOnce, ^{
        pageShadow = [[NSShadow alloc] init];
        pageShadow.shadowBlurRadius = 12.0;
        pageShadow.shadowOffset = NSMakeSize(0.0, -2.0);
        pageShadow.shadowColor = [NSColor colorWithCalibratedWhite:0.0 alpha:0.28];
    });

    [NSGraphicsContext saveGraphicsState];
    if (!self.presentationMode && self.drawsPageShadow) [pageShadow set];
    [self.pageFillColor setFill];
    NSRectFill(pageRect);
    [NSGraphicsContext restoreGraphicsState];

    CGFloat backingScale = spdf_mac_effective_backing_scale(self.backingScale, self.window);
    BOOL hasLiveZoomSeed = self.liveZooming && page.zoomSeedImage && !NSIsEmptyRect(page.zoomSeedPageRect);
    BOOL liveZoomSeedCoversFullPage =
        hasLiveZoomSeed && spdf_mac_page_subrect_covers_full_page(page.zoomSeedPageRect, page);
    BOOL drewLiveZoomSeed = liveZoomSeedCoversFullPage &&
                            spdf_mac_draw_page_image(page.zoomSeedImage, page.zoomSeedPageRect, pageRect,
                                                     dirtyRect, page, NSImageInterpolationHigh);

    BOOL hasExactFullPageImage = page.image && fabs(page.imageZoom - self.zoom) <= 0.001 &&
                                 fabs(page.imageScale - backingScale) <= 0.001;
    BOOL hasReusableViewportImage = page.viewportImage && !NSIsEmptyRect(page.viewportImagePageRect);
    BOOL hasHighQualityImage = page.highQualityImage && page.highQualityImagePointWidth > 0.0 &&
                               page.highQualityImagePointHeight > 0.0;
    BOOL hasBaseImage = page.baseImage && page.baseImagePointWidth > 0.0 && page.baseImagePointHeight > 0.0;
    NSRect fullPageSubrect = NSMakeRect(0.0, 0.0, page.pageWidth, page.pageHeight);
    NSImage* image = nil;
    NSImageInterpolation imageInterpolation = NSImageInterpolationHigh;
    if (hasExactFullPageImage) image = page.image;
    else if (self.liveZooming && hasHighQualityImage)
        image = page.highQualityImage;
    else if (self.liveZooming && hasBaseImage)
        image = page.baseImage;
    else if (self.liveZooming && spdf_mac_should_draw_stale_full_page_image(page, self.zoom, backingScale))
        image = page.image;
    else if (self.liveZooming && !hasReusableViewportImage)
        image = page.minimapImage;
    else if (self.liveZooming)
        image = nil;
    else image = page.image ?: page.highQualityImage ?: page.baseImage ?: page.minimapImage;
    if (!drewLiveZoomSeed && image) {
        BOOL drawingExactImage = hasExactFullPageImage && page.image == image;
        BOOL exactSize = drawingExactImage && fabs(NSWidth(pageRect) - page.imagePointWidth) < 0.01 &&
                         fabs(NSHeight(pageRect) - page.imagePointHeight) < 0.01;
        imageInterpolation = exactSize ? NSImageInterpolationNone : NSImageInterpolationHigh;
        spdf_mac_draw_page_image(image, fullPageSubrect, pageRect, dirtyRect, page, imageInterpolation);
    }

    BOOL hasCurrentViewportImage = page.viewportImage && fabs(page.viewportImageZoom - self.zoom) <= 0.001 &&
                                   fabs(page.viewportImageScale - backingScale) <= 0.001;
    BOOL canDrawViewportImage = hasCurrentViewportImage || (self.liveZooming && hasReusableViewportImage);
    if (!drewLiveZoomSeed && !hasExactFullPageImage && canDrawViewportImage) {
        spdf_mac_draw_page_image(page.viewportImage, page.viewportImagePageRect, pageRect, dirtyRect, page,
                                 NSImageInterpolationHigh);
    }

    if (hasLiveZoomSeed && !drewLiveZoomSeed) {
        spdf_mac_draw_page_image(page.zoomSeedImage, page.zoomSeedPageRect, pageRect, dirtyRect, page,
                                 NSImageInterpolationHigh);
    }

    if (page.highlights.count > 0 && self.zoom > 0) {
        [[NSColor colorWithCalibratedRed:1.0 green:0.84 blue:0.12 alpha:0.38] setFill];
        for (NSValue* value in page.highlights) {
            NSRect r = spdf_mac_page_rect_to_view_rect([value rectValue], pageRect, page);
            [[NSBezierPath bezierPathWithRoundedRect:r xRadius:2.0 yRadius:2.0] fill];
        }
    }

    if (self.activeFindAlpha > 0 && page.pageIndex == self.activeFindPageIndex && self.zoom > 0) {
        NSRect r = spdf_mac_page_rect_to_view_rect(self.activeFindRect, pageRect, page);
        r = NSInsetRect(r, -2.0, -2.0);
        [[NSColor colorWithCalibratedRed:0.94 green:0.03 blue:0.02 alpha:self.activeFindAlpha] setStroke];
        NSBezierPath* path = [NSBezierPath bezierPathWithRect:r];
        path.lineWidth = 1.2;
        [path stroke];
    }

    if (page.selectionRects.count > 0 && self.zoom > 0) {
        [[NSColor colorWithCalibratedRed:0.40 green:0.62 blue:0.86 alpha:kSelectionOverlayAlpha] setFill];
        for (NSValue* value in page.selectionRects) {
            NSRect r = spdf_mac_page_rect_to_view_rect([value rectValue], pageRect, page);
            NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);
        }
    }

    NSArray<NSDictionary*>* comments = [self.reader commentAnnotationsForPage:page.pageIndex];
    if (comments.count > 0 && self.zoom > 0) {
        [[NSColor colorWithCalibratedRed:1.0 green:0.76 blue:0.10 alpha:0.16] setFill];
        [[NSColor colorWithCalibratedRed:0.92 green:0.52 blue:0.0 alpha:0.95] setStroke];
        for (NSDictionary* comment in comments) {
            NSRect r = spdf_mac_page_rect_to_view_rect([comment[@"bounds"] rectValue], pageRect, page);
            r = NSInsetRect(r, -2.0, -2.0);
            NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:r xRadius:3.0 yRadius:3.0];
            [path fill];
            path.lineWidth = 1.2;
            [path stroke];
        }
    }

    [self drawPageBorderInRect:pageRect];
}

- (void)drawRect:(NSRect)dirtyRect {
    double profileStart = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
    double launchPaintStart = spdf_launch_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
    [(self.presentationMode ? NSColor.blackColor : self.viewportBackgroundColor) setFill];
    NSRectFill(dirtyRect);

    if (self.pages.count == 0) {
        SPDFShowEmptyDocumentView(self,self.emptyMessage,self.reader);
        return;
    }

    if (self.presentationMode) {
        NSInteger index = MAX(0, MIN(self.currentPageIndex, (NSInteger)self.pages.count - 1));
        SPDFRenderedPage* page = self.pages[(NSUInteger)index];
        NSRect pageRect = [self rectForPageAtIndex:index];
        if (NSIntersectsRect(dirtyRect, pageRect)) [self drawPage:page inRect:pageRect dirtyRect:dirtyRect];
        spdf_launch_log_first_document_paint(self.pages.count, launchPaintStart);
        return;
    }

    for (SPDFRenderedPage* page in self.pages) {
        NSRect pageRect = [self rectForPageAtIndex:page.pageIndex];
        if (NSMaxY(pageRect) < NSMinY(dirtyRect) - 1.0) continue;
        if (NSMinY(pageRect) > NSMaxY(dirtyRect) + 1.0) break;
        if (NSIntersectsRect(dirtyRect, pageRect)) [self drawPage:page inRect:pageRect dirtyRect:dirtyRect];
    }
    if (spdf_zoom_profile_enabled()) {
        double elapsed = spdf_zoom_profile_now_ms() - profileStart;
        if (elapsed > 2.0)
            spdf_zoom_profile_log(@"drawRect liveZoom=%d zoom=%.2f dirty=%.0fx%.0f total=%.2fms", self.liveZooming,
                                  self.zoom, NSWidth(dirtyRect), NSHeight(dirtyRect), elapsed);
    }
    spdf_launch_log_first_document_paint(self.pages.count, launchPaintStart);
}

- (BOOL)point:(NSPoint)point fallsInPage:(NSInteger*)pageIndex pagePoint:(NSPoint*)pagePoint {
    for (SPDFRenderedPage* page in self.pages) {
        NSRect pageRect = [self rectForPageAtIndex:page.pageIndex];
        if (NSMaxY(pageRect) < point.y - 1.0) continue;
        if (NSMinY(pageRect) > point.y + 1.0) break;
        if (NSPointInRect(point, pageRect)) {
            if (pageIndex) *pageIndex = page.pageIndex;
            if (pagePoint) *pagePoint = spdf_mac_view_point_to_page_point(point, pageRect, page);
            return YES;
        }
    }
    return NO;
}

- (void)updateHoveredCommentForEvent:(NSEvent*)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSPoint pagePoint = NSZeroPoint;
    NSInteger pageIndex = -1;
    NSDictionary* hitComment = nil;
    if ([self point:point fallsInPage:&pageIndex pagePoint:&pagePoint]) {
        for (NSDictionary* comment in [self.reader commentAnnotationsForPage:pageIndex]) {
            NSRect bounds = [comment[@"bounds"] rectValue];
            if (NSPointInRect(pagePoint, NSInsetRect(bounds, -3.0, -3.0))) {
                hitComment = comment;
                break;
            }
        }
    }

    if (hitComment == _hoveredComment || [hitComment isEqualToDictionary:_hoveredComment]) {
        if (hitComment) [self.reader documentViewHoverComment:hitComment atWindowPoint:event.locationInWindow];
        return;
    }

    _hoveredComment = hitComment;
    if (hitComment) [self.reader documentViewHoverComment:hitComment atWindowPoint:event.locationInWindow];
    else [self.reader documentViewEndHoverComment];
}

- (void)mouseDown:(NSEvent*)event {
    spdf_activate_window_for_view(self);
    [self.reader clearFindFieldFocus];
    [_pendingLinkActivation cancel];
    // Before any view point is converted: a multi-click continuing from a click
    // that already followed an in-document link scrolls back first, so the page
    // coordinates below are the ones the user is looking at.
    [self undoLinkNavigationForClickCount:event.clickCount];
    if (!self.reader) {
        [super mouseDown:event];
        return;
    }
    if ([self.reader handlePresentationEvent:event]) return;
    if (event.modifierFlags & NSEventModifierFlagControl) {
        [self.reader showContextMenuForDocumentView:self event:event];
        return;
    }

    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSPoint pagePoint = NSZeroPoint;
    NSInteger pageIndex = -1;
    if ([self point:point fallsInPage:&pageIndex pagePoint:&pagePoint]) {
        SPDFMacSelectionGranularity granularity = spdf_mac_selection_granularity_for_event(event);
        if (!spdf_mac_selection_uses_range_path(granularity)) {
            _isSelecting = NO;
            _linkGesture.active = NO;
            [self.reader documentViewSelectionChangedOnPage:pageIndex
                                                       from:pagePoint
                                                         to:pagePoint
                                                granularity:granularity];
            return;
        }
        // Link activation is decided on mouse-up (click vs drag-select), so a
        // drag that selects link text never opens the link. Mouse-down only
        // starts the selection gesture and records the press for that decision.
        _isSelecting = YES;
        _selectionPageIndex = pageIndex;
        _selectionStart = pagePoint;
        _linkGesture = spdf_link_click_gesture_begin(point);
        _linkGesturePageIndex = pageIndex;
        _linkGesturePagePoint = pagePoint;
        [self.reader documentViewSelectionChangedOnPage:pageIndex from:pagePoint to:pagePoint];
    } else {
        _linkGesture.active = NO;
        [super mouseDown:event];
    }
}

- (BOOL)windowIsFrontmostAtWindowPoint:(NSPoint)windowPoint {
    NSWindow* window = self.window;
    if (!window) return NO;
    NSRect screenRect = [window convertRectToScreen:NSMakeRect(windowPoint.x, windowPoint.y, 1.0, 1.0)];
    NSInteger hitWindowNumber = [NSWindow windowNumberAtPoint:screenRect.origin belowWindowWithWindowNumber:0];
    return hitWindowNumber == window.windowNumber;
}

- (void)updateCursorForPointInWindow:(NSPoint)windowPoint {
    if (_isPanning || !self.reader) return;  // the closed-hand grab owns the cursor
    if ([self.reader documentViewInPresentationMode]) {
        [NSCursor.arrowCursor set];
        return;
    }
    // Selection drag in progress: I-beam until release, even while over a link.
    if (_isSelecting && (_linkGesture.draggedBeyondThreshold || _linkGesture.selectionCreated)) {
        [NSCursor.IBeamCursor set];
        return;
    }
    // ActiveAlways fires beneath other windows; only the top window may set its cursor.
    // Key windows skip the window-server hit test (IPC) - the responder chain
    // routing is authoritative there.
    if (!self.window.isKeyWindow && ![self windowIsFrontmostAtWindowPoint:windowPoint]) return;
    if (SPDFApplyCursorOverlay(self,windowPoint)) return;
    NSPoint point = [self convertPoint:windowPoint fromView:nil];
    NSPoint pagePoint = NSZeroPoint;
    NSInteger pageIndex = -1;
    SPDFCursorRegionKind kind = SPDFCursorRegionNone;
    if ([self point:point fallsInPage:&pageIndex pagePoint:&pagePoint])
        kind = [self.reader documentViewCursorRegionAtPageIndex:pageIndex pagePoint:pagePoint];
    if (kind == SPDFCursorRegionLink) [NSCursor.pointingHandCursor set];
    else if (kind == SPDFCursorRegionText) [NSCursor.IBeamCursor set];
    else [NSCursor.arrowCursor set];
}

- (void)refreshCursorForMouseLocation {
    NSWindow* window = self.window;
    if (!window) return;
    NSPoint windowPoint = [window mouseLocationOutsideOfEventStream];
    NSPoint viewPoint = [self convertPoint:windowPoint fromView:nil];
    if (!NSPointInRect(viewPoint, self.visibleRect)) return;
    [self updateCursorForPointInWindow:windowPoint];
}

- (void)mouseMoved:(NSEvent*)event {
    // Comment hover previews keep their historical key-window-only behavior
    // (the tracking area is ActiveAlways now solely for cursor feedback).
    if (self.window.isKeyWindow) {
        [self updateHoveredCommentForEvent:event];
    } else if (_hoveredComment) {
        _hoveredComment = nil;
        [self.reader documentViewEndHoverComment];
    }
    if (!self.reader) return;
    [self updateCursorForPointInWindow:event.locationInWindow];
}

- (void)mouseExited:(NSEvent*)event {
    _hoveredComment = nil;
    [self.reader documentViewEndHoverComment];
    if (_isPanning || (_isSelecting && (_linkGesture.draggedBeyondThreshold || _linkGesture.selectionCreated))) return;
    if ((self.window.isKeyWindow || [self windowIsFrontmostAtWindowPoint:event.locationInWindow]) &&
        !SPDFApplyCursorOverlay(self,event.locationInWindow)) [NSCursor.arrowCursor set];
}

- (void)keyDown:(NSEvent*)event {
    if (self.reader && [self.reader handlePresentationEvent:event]) return;
    if (self.reader && [self.reader documentArrowKeyDown:event]) return;
    if (self.reader && [self.reader documentTypeToSearchKeyDown:event]) return;
    [super keyDown:event];
}

- (void)mouseDragged:(NSEvent*)event {
    [self.reader clearFindFieldFocus];
    if (_isPanning) {
        [self continuePanWithEvent:event];
        return;
    }
    if (!_isSelecting) {
        [super mouseDragged:event];
        return;
    }
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect pageRect = [self rectForPageAtIndex:_selectionPageIndex];
    if (NSIsEmptyRect(pageRect)) return;
    SPDFRenderedPage* page = self.pages[(NSUInteger)_selectionPageIndex];
    NSPoint pagePoint = spdf_mac_view_point_to_page_point(point, pageRect, page);
    BOOL selectionNonEmpty = [self.reader documentViewSelectionChangedOnPage:_selectionPageIndex
                                                                        from:_selectionStart
                                                                          to:pagePoint];
    spdf_link_click_gesture_drag(&_linkGesture, point, selectionNonEmpty);
    if (_linkGesture.draggedBeyondThreshold || _linkGesture.selectionCreated) [NSCursor.IBeamCursor set];
}

// Asks the reader to follow a link at the recorded press point right now, and
// remembers where the document was so a following multi-click can undo it.
// NO means the reader declined (no link, or one that leaves the document) and
// the caller should fall back to deferred activation.
- (BOOL)followInDocumentLinkForGesture {
    NSPoint restoreOrigin = NSZeroPoint;
    NSInteger restorePageIndex = -1;
    if (![self.reader documentViewFollowInDocumentLinkAtPageIndex:_linkGesturePageIndex
                                                        pagePoint:_linkGesturePagePoint
                                                    restoreOrigin:&restoreOrigin
                                                 restorePageIndex:&restorePageIndex])
        return NO;
    _linkUndoOrigin = restoreOrigin;
    _linkUndoPageIndex = restorePageIndex;
    _linkUndoAvailable = YES;
    return YES;
}

// Consumes the snapshot on every press: a continuing multi-click scrolls back,
// a fresh press just forgets it. Either way it survives only one click run.
- (void)undoLinkNavigationForClickCount:(NSInteger)clickCount {
    BOOL undo = spdf_mac_link_undo_applies_to_click(clickCount, _linkUndoAvailable);
    _linkUndoAvailable = NO;
    if (undo) [self.reader documentViewRestoreDocumentPosition:_linkUndoOrigin pageIndex:_linkUndoPageIndex];
}

- (void)mouseUp:(NSEvent*)event {
    if (_isPanning) {
        [self endPan];
        return;
    }
    BOOL wasSelecting = _isSelecting;
    _isSelecting = NO;
    if (wasSelecting && spdf_link_click_gesture_activates_on_release(&_linkGesture)) {
        SPDFCursorRegionKind kind = [self.reader documentViewCursorRegionAtPageIndex:_linkGesturePageIndex
                                                                            pagePoint:_linkGesturePagePoint];
        // Known text is not a link; unresolved regions defer the exact core hit-test.
        if (kind != SPDFCursorRegionText) {
            // A destination inside this document is reached now, on release: the
            // jump is a scroll, and a multi-click that follows takes it back
            // (see undoLinkNavigationForClickCount:). Waiting out the
            // double-click interval here used to cost every table-of-contents
            // click ~500ms for work that measures ~5ms.
            double followStart = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
            if ([self followInDocumentLinkForGesture]) {
                if (spdf_zoom_profile_enabled())
                    spdf_zoom_profile_log(@"link followed in-document %.2fms after release",
                                          spdf_zoom_profile_now_ms() - followStart);
                _linkGesture.active = NO;
                [self updateCursorForPointInWindow:event.locationInWindow];
                return;
            }
            // Anything else (an external URL, or a point the core resolves to no
            // link at all) still waits: opening another application cannot be
            // undone by a second click.
            if (!_pendingLinkActivation) _pendingLinkActivation = [SPDFMacDelayedLinkActivation new];
            __weak id<SPDFMacDocumentViewReader> reader = self.reader;
            [_pendingLinkActivation schedulePageIndex:_linkGesturePageIndex
                                            pagePoint:_linkGesturePagePoint
                                              handler:^(NSInteger pageIndex, NSPoint pagePoint) {
                                                [reader documentViewOpenLinkAtPageIndex:pageIndex pagePoint:pagePoint];
                                              }];
        }
    }
    _linkGesture.active = NO;
    [self updateCursorForPointInWindow:event.locationInWindow];
}

- (void)beginPanWithEvent:(NSEvent*)event {
    [self beginPanWithWindowPoint:event.locationInWindow timestamp:event.timestamp];
}

- (void)beginPanWithWindowPoint:(NSPoint)windowPoint timestamp:(NSTimeInterval)timestamp {
    spdf_activate_window_for_view(self);
    [self.reader clearFindFieldFocus];
    NSScrollView* scrollView = self.enclosingScrollView;
    if (!scrollView) return;
    [_inertiaTimer invalidate];
    _inertiaTimer = nil;
    _isPanning = YES;
    _isSelecting = NO;
    _panStartInWindow = windowPoint;
    _panStartOrigin = scrollView.contentView.bounds.origin;
    _lastPanPoint = windowPoint;
    _lastPanTime = timestamp;
    _panVelocity = NSZeroPoint;
    [[NSCursor closedHandCursor] set];
    [self.reader documentViewDidBeginPan];
}

- (void)continuePanWithEvent:(NSEvent*)event {
    if (!_isPanning) return;

    NSPoint current = event.locationInWindow;
    NSPoint delta = NSMakePoint(current.x - _panStartInWindow.x, current.y - _panStartInWindow.y);
    NSPoint origin = NSMakePoint(_panStartOrigin.x - delta.x, _panStartOrigin.y + delta.y);
    NSTimeInterval dt = MAX(0.001, event.timestamp - _lastPanTime);
    _panVelocity = NSMakePoint((current.x - _lastPanPoint.x) / dt, (current.y - _lastPanPoint.y) / dt);
    _lastPanPoint = current;
    _lastPanTime = event.timestamp;
    // The reader clamps (centering a viewport-fit page, panning a wider one),
    // applies the scroll, and posts the position change.
    [self.reader documentViewPanToProposedOrigin:origin];
}

- (void)stepPanInertia:(NSTimer*)timer {
    NSScrollView* scrollView = self.enclosingScrollView;
    NSClipView* clipView = scrollView.contentView;
    if (!scrollView || !clipView) {
        [timer invalidate];
        _inertiaTimer = nil;
        [self.reader documentViewDidFinishPanMotion];
        return;
    }

    NSPoint origin = clipView.bounds.origin;
    origin.x -= _panVelocity.x / 60.0;
    origin.y += _panVelocity.y / 60.0;
    [self.reader documentViewPanToProposedOrigin:origin];

    _panVelocity.x *= 0.90;
    _panVelocity.y *= 0.90;
    if (hypot(_panVelocity.x, _panVelocity.y) < 12.0) {
        [timer invalidate];
        _inertiaTimer = nil;
        [self.reader documentViewDidFinishPanMotion];
    }
}

- (void)endPan {
    _isPanning = NO;
    [[NSCursor arrowCursor] set];
    [self refreshCursorForMouseLocation];
    if (hypot(_panVelocity.x, _panVelocity.y) > 90.0) {
        [_inertiaTimer invalidate];
        _inertiaTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                                         target:self
                                                       selector:@selector(stepPanInertia:)
                                                       userInfo:nil
                                                        repeats:YES];
    } else {
        [self.reader documentViewDidFinishPanMotion];
    }
}

- (void)cancelTransientInteraction {
    [_pendingLinkActivation cancel];
    _linkUndoAvailable = NO;
    [_inertiaTimer invalidate];
    _inertiaTimer = nil;
    _isPanning = NO;
    _isSelecting = NO;
    _rightMouseMoved = NO;
    _linkGesture.active = NO;
    _panVelocity = NSZeroPoint;
    _selectionPageIndex = -1;
    [[NSCursor arrowCursor] set];
}
- (void)dealloc {
    [_pendingLinkActivation cancel];
}
- (void)rightMouseDown:(NSEvent*)event {
    spdf_activate_window_for_view(self);
    _rightMouseMoved = NO;
    if (self.reader && [self.reader handlePresentationEvent:event]) {
        _rightMouseMoved = YES;
        return;
    }
    if (event.modifierFlags & NSEventModifierFlagCommand) return;
    [self beginPanWithEvent:event];
}

- (void)rightMouseDragged:(NSEvent*)event {
    _rightMouseMoved = YES;
    if (_isPanning) [self continuePanWithEvent:event];
}

- (void)rightMouseUp:(NSEvent*)event {
    if (self.reader && [self.reader documentViewInPresentationMode]) return;
    BOOL forceMenu = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
    if (forceMenu || !_rightMouseMoved) [self.reader showContextMenuForDocumentView:self event:event];
    if (_isPanning) [self endPan];
}

- (void)otherMouseDown:(NSEvent*)event {
    if (event.buttonNumber == 2) [self beginPanWithEvent:event];
    else [super otherMouseDown:event];
}

- (void)otherMouseDragged:(NSEvent*)event {
    if (_isPanning) [self continuePanWithEvent:event];
    else [super otherMouseDragged:event];
}

- (void)otherMouseUp:(NSEvent*)event {
    if (_isPanning) [self endPan];
    else [super otherMouseUp:event];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return SPDFDocumentPathsFromPasteboard(sender.draggingPasteboard).count
        ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    return [self.reader openFilesFromPasteboard:sender.draggingPasteboard];
}

@end
