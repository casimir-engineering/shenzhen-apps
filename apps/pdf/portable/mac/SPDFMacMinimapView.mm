#import "SPDFMacMinimapView.h"
#import "SPDFMacMinimapWindow.h"
#import "SPDFMacMinimapViewOverlays.h"
#import "SPDFMacMinimapViewTheme.h"
#import "SPDFMacSupport.h"

#include <math.h>

static const CGFloat kPageMargin = 44.0;
static const CGFloat kPageGap = 26.0;
// Switch from 1:1 minimap drag to accelerated "long document" drag based on the
// document's total height in PDF points, not page count: a few very large pages
// scroll just as far as many normal pages. ~16000pt is just above 20 US-Letter
// pages (20 * 792 = 15840), so ordinary documents keep their prior threshold.
static const CGFloat kLongDocumentDragHeightThreshold = 16000.0;
static const CGFloat kLongDocumentDragFineSpeed = 180.0;
static const CGFloat kLongDocumentDragFullSpeed = 300.0;
// The whole-strip cache is only worth it when the strip is short enough that
// building/patching the single bitmap is cheap. For a tall multi-page strip
// (e.g. a 100+ page document at ~200px/thumb) the cache image is many thousands
// of pixels tall, and every rebuild AND every per-thumbnail lockFocus patch pays
// for the full bitmap — tens of ms each. Past these caps the minimap draws the
// visible slice directly (only ~a handful of thumbnails are on screen at once),
// which is ~1ms and needs no cache invalidation.
static const CGFloat kLiveContentCacheMaxPixels = 320000.0;
static const CGFloat kLiveContentCacheMaxHeight = 1600.0;
// Line-based (classic wheel) scroll deltas converted to strip pixels with the
// same factor the document scroll view uses (kSPDFMouseWheelPointsPerLine in
// SPDFMacUIHelpers.mm), so one notch feels consistent in both places.
static const CGFloat kMinimapWheelPointsPerLine = 32.0;

static CGFloat spdf_clamp_cg(CGFloat value, CGFloat minValue, CGFloat maxValue) {
    return MAX(minValue, MIN(maxValue, value));
}

static CGFloat spdf_smoothstep_cg(CGFloat value) {
    value = spdf_clamp_cg(value, 0.0, 1.0);
    return value * value * value * (value * (value * 6.0 - 15.0) + 10.0);
}

@implementation SPDFMinimapView {
    BOOL _draggingVisibleRect;
    BOOL _pressPending;
    BOOL _dragMoved;
    NSPoint _pressPoint;
    NSPoint _dragOffsetFromVisibleCenter;
    CGFloat _dragOffsetFromVisibleTop;
    CGFloat _dragThumbTop;
    CGFloat _dragLastMouseY;
    NSTimeInterval _dragLastTimestamp;
    BOOL _scrollWheelDrivingViewport;
    BOOL _miniLayoutCacheValid;
    NSArray<SPDFRenderedPage*>* _miniLayoutPages;
    NSArray<NSValue*>* _miniLayoutPageRects;
    NSDictionary<NSNumber*, NSValue*>* _miniLayoutPageRectsByIndex;
    CGFloat _miniLayoutScale;
    CGFloat _miniLayoutGap;
    CGFloat _miniLayoutBoundsWidth;
    NSImage* _contentImageCache;
    NSArray<SPDFRenderedPage*>* _contentImageCachePages;
    CGFloat _contentImageCacheScale;
    CGFloat _contentImageCacheGap;
    CGFloat _contentImageCacheHeight;
    CGFloat _contentImageCacheBoundsWidth;
    NSInteger _contentImageCacheCurrentPageIndex;
    BOOL _contentImageCacheDrawImages;
    SPDFMarkdownThemeVariant _contentImageCacheThemeVariant;
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    (void)event;
    return YES;
}

- (void)setPages:(NSArray<SPDFRenderedPage*>*)pages {
    _pages = [pages copy];
    [self invalidateMiniLayoutCache];
    [self invalidateContentImageCache];
    [self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)newSize {
    NSSize oldSize = self.frame.size;
    [super setFrameSize:newSize];
    if (!NSEqualSizes(oldSize, newSize)) {
        [self invalidateMiniLayoutCache];
        [self invalidateContentImageCache];
    }
}

- (void)setBoundsSize:(NSSize)newSize {
    NSSize oldSize = self.bounds.size;
    [super setBoundsSize:newSize];
    if (!NSEqualSizes(oldSize, newSize)) {
        [self invalidateMiniLayoutCache];
        [self invalidateContentImageCache];
    }
}

- (void)invalidateMiniLayoutCache {
    _miniLayoutCacheValid = NO;
    _miniLayoutPages = nil;
    _miniLayoutPageRects = nil;
    _miniLayoutPageRectsByIndex = nil;
}

- (void)invalidateContentImageCache {
    _contentImageCache = nil;
    _contentImageCachePages = nil;
}

static const CGFloat kMinimapMaxWidthRatio = 2.5;

- (CGFloat)widestPage {
    CGFloat widest = 0;
    for (SPDFRenderedPage* page in self.pages) widest = MAX(widest, page.pageWidth);
    return widest;
}

// Median page width across all pages. Robust to a single huge-outlier page
// (unlike the mean or max), so a document with one enormous page does not
// shrink the normal pages to unreadable squares.
- (CGFloat)baseWidth {
    NSUInteger count = self.pages.count;
    if (count == 0) return 0;
    NSMutableArray<NSNumber*>* widths = [NSMutableArray arrayWithCapacity:count];
    for (SPDFRenderedPage* page in self.pages) [widths addObject:@(MAX(1.0, page.pageWidth))];
    [widths sortUsingSelector:@selector(compare:)];
    if (count % 2 == 1) return widths[count / 2].doubleValue;
    return (widths[count / 2 - 1].doubleValue + widths[count / 2].doubleValue) / 2.0;
}

// Points->minimap-px scale shared by every page that is not over-wide. Computed
// from the median width so a lone giant page is clamped to at most
// kMinimapMaxWidthRatio (2.5x) the median width. When no page exceeds the cap
// (e.g. a uniform-width document) this is exactly usable/widestPage, preserving
// the prior behaviour where the widest page filled the strip.
- (CGFloat)layoutPointScaleForUsableWidth:(CGFloat)usable {
    CGFloat widest = [self widestPage];
    if (widest <= 0) return 0;
    CGFloat base = [self baseWidth];
    CGFloat cap = base > 0 ? kMinimapMaxWidthRatio * base : widest;
    CGFloat effectiveWidest = MIN(widest, cap);
    if (effectiveWidest <= 0) effectiveWidest = widest;
    return usable / effectiveWidest;
}

- (CGFloat)thumbnailRenderZoomForPage:(SPDFRenderedPage*)page {
    if (!page || page.pageWidth <= 0.0) return 0.0;
    CGFloat usable = NSWidth(self.bounds) - 18.0;
    if (usable <= 1.0) return 0.0;
    CGFloat scale = [self layoutPointScaleForUsableWidth:usable];
    if (scale <= 0.0) return 0.0;
    // Match the page's clamped display width (see ensureMiniLayoutCache): an
    // over-wide page is capped at the strip width, so its thumbnail zoom is
    // usable/pageWidth; normal pages render at the shared point scale.
    CGFloat displayWidth = MIN(page.pageWidth * scale, usable);
    return displayWidth / page.pageWidth;
}

- (CGFloat)scrollFraction {
    CGFloat visibleHeight = NSHeight(self.documentVisibleRect);
    CGFloat maxScroll = MAX(1.0, self.documentHeight - visibleHeight);
    return spdf_clamp_cg(NSMinY(self.documentVisibleRect) / maxScroll, 0.0, 1.0);
}

- (void)ensureMiniLayoutCacheForScale:(CGFloat)scale gap:(CGFloat)gap {
    CGFloat boundsWidth = NSWidth(self.bounds);
    if (_miniLayoutCacheValid && _miniLayoutPages == self.pages && _miniLayoutScale == scale && _miniLayoutGap == gap &&
        _miniLayoutBoundsWidth == boundsWidth)
        return;

    // Per-page geometry. The displayed width is the page width at the shared
    // point scale, but clamped to the usable strip width so an over-wide page
    // is capped at kMinimapMaxWidthRatio x the median (see layoutPointScale).
    // Height follows the clamped width so each page keeps its own aspect ratio.
    CGFloat usable = MAX(1.0, boundsWidth - 18.0);
    NSMutableArray<NSValue*>* pageRects = [NSMutableArray arrayWithCapacity:self.pages.count];
    NSMutableDictionary<NSNumber*, NSValue*>* pageRectsByIndex = [NSMutableDictionary dictionary];
    CGFloat y = 0.0;
    for (SPDFRenderedPage* page in self.pages) {
        CGFloat srcWidth = MAX(1.0, page.pageWidth);
        CGFloat srcHeight = MAX(1.0, page.pageHeight);
        CGFloat pageWidth = MAX(1.0, MIN(srcWidth * scale, usable));
        CGFloat pageHeight = MAX(1.0, pageWidth * (srcHeight / srcWidth));
        NSRect rect = NSMakeRect(floor((boundsWidth - pageWidth) / 2.0), y, pageWidth, pageHeight);
        NSValue* value = [NSValue valueWithRect:rect];
        [pageRects addObject:value];
        NSNumber* pageIndex = @(page.pageIndex);
        if (!pageRectsByIndex[pageIndex]) pageRectsByIndex[pageIndex] = value;
        y += pageHeight + gap;
    }

    _miniLayoutPages = self.pages;
    _miniLayoutPageRects = pageRects;
    _miniLayoutPageRectsByIndex = pageRectsByIndex;
    _miniLayoutScale = scale;
    _miniLayoutGap = gap;
    _miniLayoutBoundsWidth = boundsWidth;
    _miniLayoutCacheValid = YES;
}

- (NSRect)miniRectForPage:(SPDFRenderedPage*)targetPage scale:(CGFloat)scale gap:(CGFloat)gap {
    [self ensureMiniLayoutCacheForScale:scale gap:gap];
    NSValue* indexedRect = _miniLayoutPageRectsByIndex[@(targetPage.pageIndex)];
    if (indexedRect) return indexedRect.rectValue;

    for (SPDFRenderedPage* page in self.pages) {
        if (page == targetPage || page.pageIndex == targetPage.pageIndex) {
            NSUInteger index = [self.pages indexOfObjectIdenticalTo:page];
            if (index != NSNotFound && index < _miniLayoutPageRects.count)
                return [_miniLayoutPageRects[index] rectValue];
        }
    }
    return NSZeroRect;
}

- (NSRect)documentRectForPage:(SPDFRenderedPage*)targetPage {
    if (targetPage.pageIndex >= 0 && targetPage.pageIndex < (NSInteger)self.documentPageRects.count) {
        NSRect rect = [self.documentPageRects[(NSUInteger)targetPage.pageIndex] rectValue];
        if (!NSIsEmptyRect(rect)) return rect;
    }

    CGFloat documentScale = MAX(0.01, self.documentScale);
    CGFloat documentWidth = MAX(1.0, self.documentWidth);
    CGFloat y = kPageMargin / 2.0;

    for (SPDFRenderedPage* page in self.pages) {
        if (page.pageIndex >= targetPage.pageIndex) break;
        y += page.pageHeight * documentScale + kPageGap;
    }

    CGFloat width = MAX(1.0, targetPage.pageWidth * documentScale);
    CGFloat height = MAX(1.0, targetPage.pageHeight * documentScale);
    CGFloat x = floor((documentWidth - width) / 2.0);
    return NSMakeRect(MAX(kPageMargin / 2.0, x), y, width, height);
}

- (NSRect)miniRectForDocumentIntersection:(NSRect)intersection
                             documentRect:(NSRect)documentRect
                                 miniRect:(NSRect)miniRect {
    if (NSIsEmptyRect(intersection) || NSIsEmptyRect(documentRect) || NSIsEmptyRect(miniRect)) return NSZeroRect;

    CGFloat x0 = spdf_clamp_cg((NSMinX(intersection) - NSMinX(documentRect)) / NSWidth(documentRect), 0.0, 1.0);
    CGFloat x1 = spdf_clamp_cg((NSMaxX(intersection) - NSMinX(documentRect)) / NSWidth(documentRect), 0.0, 1.0);
    CGFloat y0 = spdf_clamp_cg((NSMinY(intersection) - NSMinY(documentRect)) / NSHeight(documentRect), 0.0, 1.0);
    CGFloat y1 = spdf_clamp_cg((NSMaxY(intersection) - NSMinY(documentRect)) / NSHeight(documentRect), 0.0, 1.0);

    return NSMakeRect(NSMinX(miniRect) + x0 * NSWidth(miniRect), NSMinY(miniRect) + y0 * NSHeight(miniRect),
                      MAX(1.0, (x1 - x0) * NSWidth(miniRect)), MAX(1.0, (y1 - y0) * NSHeight(miniRect)));
}

- (CGFloat)totalDocumentPointHeight {
    CGFloat total = 0.0;
    for (SPDFRenderedPage* page in self.pages) total += MAX(1.0, page.pageHeight);
    return total;
}

- (BOOL)shouldUseLongDocumentViewportDrag {
    return [self totalDocumentPointHeight] > kLongDocumentDragHeightThreshold;
}

- (CGFloat)longDocumentViewportDragThumbHeightForContentHeight:(CGFloat)contentHeight track:(NSRect)track {
    (void)contentHeight;
    // The drag thumb height must be a fraction of the TRACK, not of the minimap's
    // total content height. contentHeight scales with page count, so for very long
    // documents (~200+ pages) heightFraction*contentHeight overshoots the track and
    // clamps to the full track height — which collapses the drag range
    // (maxTop == minTop) and makes the viewport undraggable. Sizing against the
    // track keeps a usable range at any document length.
    CGFloat heightFraction =
        spdf_clamp_cg(NSHeight(self.documentVisibleRect) / MAX(1.0, self.documentHeight), 0.02, 1.0);
    return MIN(MAX(10.0, heightFraction * NSHeight(track)), NSHeight(track));
}

- (NSRect)unscrolledVisibleRectForScale:(CGFloat)scale gap:(CGFloat)gap contentHeight:(CGFloat)contentHeight {
    if (self.pages.count == 0 || contentHeight <= 0) return NSZeroRect;

    if (self.documentHeight > 1.0) {
        NSRect visible = NSZeroRect;
        BOOL hasVisiblePage = NO;
        for (SPDFRenderedPage* page in self.pages) {
            NSRect documentRect = [self documentRectForPage:page];
            NSRect intersection = NSIntersectionRect(self.documentVisibleRect, documentRect);
            if (NSIsEmptyRect(intersection)) continue;

            NSRect miniRect = [self miniRectForPage:page scale:scale gap:gap];
            NSRect miniVisible = [self miniRectForDocumentIntersection:intersection
                                                          documentRect:documentRect
                                                              miniRect:miniRect];
            if (NSIsEmptyRect(miniVisible)) continue;

            visible = hasVisiblePage ? NSUnionRect(visible, miniVisible) : miniVisible;
            hasVisiblePage = YES;
        }
        if (hasVisiblePage) return NSInsetRect(visible, -2.0, -2.0);
    }

    CGFloat heightFraction =
        spdf_clamp_cg(NSHeight(self.documentVisibleRect) / MAX(1.0, self.documentHeight), 0.02, 1.0);
    CGFloat height = MAX(10.0, heightFraction * contentHeight);
    CGFloat top = [self scrollFraction] * MAX(0.0, contentHeight - height);
    if (top + height > contentHeight) top = MAX(0.0, contentHeight - height);
    return NSMakeRect(5.0, top, NSWidth(self.bounds) - 10.0, height);
}

- (BOOL)layoutScale:(CGFloat*)scaleOut
                gap:(CGFloat*)gapOut
         contentTop:(CGFloat*)topOut
      contentHeight:(CGFloat*)heightOut
        visibleRect:(NSRect*)visibleOut {
    if (self.pages.count == 0 || NSWidth(self.bounds) < 16 || NSHeight(self.bounds) < 16) return NO;

    CGFloat usable = NSWidth(self.bounds) - 18.0;
    CGFloat scale = [self layoutPointScaleForUsableWidth:usable];
    if (scale <= 0) return NO;

    CGFloat gap = 4.0;
    // Derive content height from the cached per-page rects so the value stays in
    // exact agreement with the laid-out geometry used for hit-testing and the
    // viewport indicator (heights are clamped per page, not pageHeight*scale).
    [self ensureMiniLayoutCacheForScale:scale gap:gap];
    CGFloat contentHeight = 0;
    for (NSValue* value in _miniLayoutPageRects) contentHeight += NSHeight(value.rectValue);
    contentHeight += gap * MAX(0, (NSInteger)self.pages.count - 1);
    CGFloat available = MAX(1.0, NSHeight(self.bounds) - 16.0);
    NSRect visible = [self unscrolledVisibleRectForScale:scale gap:gap contentHeight:contentHeight];
    CGFloat offset = 0;
    if (contentHeight > available) {
        CGFloat maxOffset = contentHeight - available;
        offset = [self scrollFraction] * maxOffset;
    }

    CGFloat contentTop =
        contentHeight < available ? floor((NSHeight(self.bounds) - contentHeight) / 2.0) : 8.0 - offset;
    visible.origin.y += contentTop;
    if (scaleOut) *scaleOut = scale;
    if (gapOut) *gapOut = gap;
    if (topOut) *topOut = contentTop;
    if (heightOut) *heightOut = contentHeight;
    if (visibleOut) *visibleOut = visible;
    return YES;
}

- (CGFloat)contentTopForDocumentCenterY:(CGFloat)documentY contentHeight:(CGFloat)contentHeight {
    CGFloat available = MAX(1.0, NSHeight(self.bounds) - 16.0);
    if (contentHeight < available) return floor((NSHeight(self.bounds) - contentHeight) / 2.0);

    CGFloat visibleHeight = NSHeight(self.documentVisibleRect);
    CGFloat maxScroll = MAX(1.0, self.documentHeight - visibleHeight);
    CGFloat originY = spdf_clamp_cg(documentY - visibleHeight * 0.5, 0.0, maxScroll);
    CGFloat offset = (originY / maxScroll) * (contentHeight - available);
    return 8.0 - offset;
}

- (NSPoint)documentPointForUnscrolledMiniPoint:(NSPoint)point scale:(CGFloat)scale gap:(CGFloat)gap {
    CGFloat y = 0;
    for (SPDFRenderedPage* page in self.pages) {
        NSRect miniRect = [self miniRectForPage:page scale:scale gap:gap];
        NSRect documentRect = [self documentRectForPage:page];
        CGFloat displayHeight =
            NSIsEmptyRect(miniRect) ? MAX(1.0, page.pageHeight * scale) : NSHeight(miniRect);
        if (NSIsEmptyRect(miniRect) || NSIsEmptyRect(documentRect)) {
            y += displayHeight + gap;
            continue;
        }

        if (point.y >= NSMinY(miniRect) && point.y <= NSMaxY(miniRect)) {
            CGFloat xFraction = spdf_clamp_cg((point.x - NSMinX(miniRect)) / MAX(1.0, NSWidth(miniRect)), 0.0, 1.0);
            CGFloat yFraction = spdf_clamp_cg((point.y - NSMinY(miniRect)) / MAX(1.0, NSHeight(miniRect)), 0.0, 1.0);
            return NSMakePoint(NSMinX(documentRect) + xFraction * NSWidth(documentRect),
                               NSMinY(documentRect) + yFraction * NSHeight(documentRect));
        }

        CGFloat gapStart = NSMaxY(miniRect);
        CGFloat gapEnd = gapStart + gap;
        if (point.y > gapStart && point.y < gapEnd) {
            CGFloat xFraction = spdf_clamp_cg((point.x - NSMinX(miniRect)) / MAX(1.0, NSWidth(miniRect)), 0.0, 1.0);
            CGFloat gapFraction = spdf_clamp_cg((point.y - gapStart) / MAX(1.0, gap), 0.0, 1.0);
            return NSMakePoint(NSMinX(documentRect) + xFraction * NSWidth(documentRect),
                               NSMaxY(documentRect) + gapFraction * kPageGap);
        }
        y += displayHeight + gap;
    }

    CGFloat yFraction = spdf_clamp_cg(point.y / MAX(1.0, y), 0.0, 1.0);
    return NSMakePoint(NSMidX(self.documentVisibleRect), yFraction * self.documentHeight);
}

- (NSPoint)documentPointForMinimapCenterPoint:(NSPoint)point
                                        scale:(CGFloat)scale
                                          gap:(CGFloat)gap
                                contentHeight:(CGFloat)contentHeight
                                   contentTop:(CGFloat)contentTop {
    NSPoint documentPoint = [self documentPointForUnscrolledMiniPoint:NSMakePoint(point.x, point.y - contentTop)
                                                                scale:scale
                                                                  gap:gap];
    for (NSInteger i = 0; i < 8; ++i) {
        CGFloat projectedTop = [self contentTopForDocumentCenterY:documentPoint.y contentHeight:contentHeight];
        NSPoint unscrolledPoint = NSMakePoint(point.x, point.y - projectedTop);
        documentPoint = [self documentPointForUnscrolledMiniPoint:unscrolledPoint scale:scale gap:gap];
    }
    return documentPoint;
}

- (BOOL)pageHitForMiniPoint:(NSPoint)point
                      scale:(CGFloat)scale
                        gap:(CGFloat)gap
                 contentTop:(CGFloat)contentTop
                  pageIndex:(NSInteger*)pageIndexOut
            xFractionInPage:(CGFloat*)xFractionOut
            yFractionInPage:(CGFloat*)yFractionOut {
    NSPoint unscrolledPoint = NSMakePoint(point.x, point.y - contentTop);
    for (SPDFRenderedPage* page in self.pages) {
        NSRect miniRect = [self miniRectForPage:page scale:scale gap:gap];
        if (NSIsEmptyRect(miniRect)) continue;
        if (unscrolledPoint.y >= NSMinY(miniRect) && unscrolledPoint.y <= NSMaxY(miniRect)) {
            if (pageIndexOut) *pageIndexOut = page.pageIndex;
            if (xFractionOut)
                *xFractionOut =
                    spdf_clamp_cg((unscrolledPoint.x - NSMinX(miniRect)) / MAX(1.0, NSWidth(miniRect)), 0.0, 1.0);
            if (yFractionOut)
                *yFractionOut =
                    spdf_clamp_cg((unscrolledPoint.y - NSMinY(miniRect)) / MAX(1.0, NSHeight(miniRect)), 0.0, 1.0);
            return YES;
        }
    }
    return NO;
}

- (NSRect)draggableVisibleRectForRect:(NSRect)visibleRect {
    return NSIntersectionRect(visibleRect, NSInsetRect(self.bounds, 1.0, 1.0));
}

- (NSTimeInterval)dragDeltaTimeForTimestamp:(NSTimeInterval)timestamp {
    NSTimeInterval deltaT = timestamp - _dragLastTimestamp;
    if (!isfinite(deltaT) || deltaT <= 0.0) deltaT = 1.0 / 60.0;
    return spdf_clamp_cg(deltaT, 1.0 / 240.0, 1.0 / 15.0);
}

- (CGFloat)longDocumentDragScaleForDeltaY:(CGFloat)deltaY timestamp:(NSTimeInterval)timestamp {
    if (![self shouldUseLongDocumentViewportDrag]) return 1.0;

    NSTimeInterval deltaT = [self dragDeltaTimeForTimestamp:timestamp];
    CGFloat speed = fabs(deltaY) / deltaT;
    CGFloat acceleration = spdf_smoothstep_cg((speed - kLongDocumentDragFineSpeed) /
                                              (kLongDocumentDragFullSpeed - kLongDocumentDragFineSpeed));
    CGFloat pageScale = spdf_clamp_cg(20.0 / MAX(1.0, (CGFloat)self.pages.count), 0.30, 0.72);
    return pageScale + acceleration * (1.0 - pageScale);
}

- (CGFloat)longDocumentDragDocumentXForStripX:(CGFloat)stripX
                                     fraction:(CGFloat)fraction
                                        scale:(CGFloat)scale
                                          gap:(CGFloat)gap {
    // Pick the page to pan across from the SAME vertical target the drag is sending
    // (documentCenterY derived from `fraction`, matching the reader's origin.y = fraction*maxY),
    // not from the track-space thumb Y, which lives in a different height space and can
    // converge onto a neighbouring (narrow) page — limiting horizontal pan to that page's width.
    CGFloat visibleHeight = NSHeight(self.documentVisibleRect);
    CGFloat documentCenterY =
        spdf_clamp_cg(fraction, 0.0, 1.0) * MAX(0.0, self.documentHeight - visibleHeight) + visibleHeight * 0.5;

    for (SPDFRenderedPage* page in self.pages) {
        NSRect documentRect = [self documentRectForPage:page];
        if (NSIsEmptyRect(documentRect)) continue;
        if (documentCenterY < NSMinY(documentRect) || documentCenterY > NSMaxY(documentRect)) continue;

        NSRect miniRect = [self miniRectForPage:page scale:scale gap:gap];
        if (NSIsEmptyRect(miniRect)) continue;
        CGFloat xFraction = spdf_clamp_cg((stripX - NSMinX(miniRect)) / MAX(1.0, NSWidth(miniRect)), 0.0, 1.0);
        return NSMinX(documentRect) + xFraction * NSWidth(documentRect);
    }
    return NSMidX(self.documentVisibleRect);
}

- (BOOL)sendLongDocumentViewportDragForPoint:(NSPoint)point
                                       event:(NSEvent*)event
                                       scale:(CGFloat)scale
                                         gap:(CGFloat)gap
                               contentHeight:(CGFloat)contentHeight
                                  contentTop:(CGFloat)contentTop {
    if (!_draggingVisibleRect || ![self shouldUseLongDocumentViewportDrag]) return NO;

    NSRect track = NSInsetRect(self.bounds, 1.0, 1.0);
    CGFloat thumbHeight = [self longDocumentViewportDragThumbHeightForContentHeight:contentHeight track:track];
    CGFloat minTop = NSMinY(track);
    CGFloat maxTop = MAX(minTop, NSMaxY(track) - thumbHeight);
    CGFloat deltaY = point.y - _dragLastMouseY;
    CGFloat dragScale = [self longDocumentDragScaleForDeltaY:deltaY timestamp:event.timestamp];
    _dragThumbTop = spdf_clamp_cg(_dragThumbTop + deltaY * dragScale, minTop, maxTop);
    _dragLastMouseY = point.y;
    _dragLastTimestamp = event.timestamp;

    CGFloat fraction = maxTop <= minTop ? 0.0 : (_dragThumbTop - minTop) / (maxTop - minTop);
    CGFloat documentX = [self longDocumentDragDocumentXForStripX:point.x - _dragOffsetFromVisibleCenter.x
                                                        fraction:fraction
                                                           scale:scale
                                                             gap:gap];
    if (!isfinite(documentX)) documentX = NSMidX(self.documentVisibleRect);
    [self.reader minimapViewDidRequestViewportTopFraction:fraction documentCenterX:documentX];
    return YES;
}

- (BOOL)documentPointForEvent:(NSEvent*)event documentPoint:(NSPoint*)documentPointOut {
    CGFloat scale = 1.0;
    CGFloat gap = 4.0;
    CGFloat contentTop = 8.0;
    CGFloat contentHeight = 0;
    if (![self layoutScale:&scale gap:&gap contentTop:&contentTop contentHeight:&contentHeight visibleRect:NULL])
        return NO;

    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (documentPointOut)
        *documentPointOut = [self documentPointForMinimapCenterPoint:point
                                                               scale:scale
                                                                 gap:gap
                                                       contentHeight:contentHeight
                                                          contentTop:contentTop];
    return YES;
}

- (void)drawPageContentAtContentTop:(CGFloat)contentTop
                              scale:(CGFloat)scale
                                gap:(CGFloat)gap
                         drawImages:(BOOL)drawImages
                           clipRect:(NSRect)clipRect {
    // Read the cached per-page rects so the strip draws at exactly the clamped
    // (capped-width, aspect-preserved) geometry used for hit-testing/indicator.
    [self ensureMiniLayoutCacheForScale:scale gap:gap];
    for (SPDFRenderedPage* page in self.pages) {
        NSRect cachedRect = [self miniRectForPage:page scale:scale gap:gap];
        if (NSIsEmptyRect(cachedRect)) continue;
        NSRect pageRect = cachedRect;
        pageRect.origin.y += contentTop;
        if (NSHeight(pageRect) >= 1.0 && NSIntersectsRect(pageRect, clipRect))
            [self drawMiniPage:page inPageRect:pageRect drawImages:drawImages];
    }
}

// Draws one page's slot (white background, thumbnail or placeholder, search /
// selection overlays). Shared by the full strip draw and the single-page cache
// patch. The selected-page outline is intentionally not drawn here — it is a
// drawRect: overlay so it never bakes the current page into the cached strip.
- (void)drawMiniPage:(SPDFRenderedPage*)page inPageRect:(NSRect)pageRect drawImages:(BOOL)drawImages {
    // Page draws are uniformly scaled per page (width/height share one factor by
    // construction), so overlays in page-space points map with this scale.
    CGFloat pageScale = NSWidth(pageRect) / MAX(1.0, page.pageWidth);
    [self.pageFillColor setFill];
    NSRectFillUsingOperation(pageRect, NSCompositingOperationSourceOver);
    // Thumbnails first: drawing full page bitmaps here forces whole-image decodes
    // that can cost >100ms across a document strip.
    NSImage* image = page.minimapImage ?: page.image;
    if (drawImages && image && NSHeight(pageRect) >= 5.0) {
        [image drawInRect:pageRect
                  fromRect:NSZeroRect
                 operation:NSCompositingOperationSourceOver
                  fraction:1.0
            respectFlipped:YES
                     hints:@{NSImageHintInterpolation : @(NSImageInterpolationLow)}];
    } else {
        [self drawPlaceholderInRect:pageRect];
    }
    [self drawSearchRects:page.highlights pageRect:pageRect scale:pageScale];
    [self drawRects:page.selectionRects
           pageRect:pageRect
              scale:pageScale
              color:[NSColor colorWithCalibratedRed:0.30 green:0.58 blue:0.93 alpha:0.70]
          minHeight:1.0];
    [self drawPageBorderInRect:pageRect];
}

// `pages` is a snapshot, and a full-page render REPLACES the reader's page
// object; a thumbnail landing after that was stored on the replacement only, so
// its slot kept the placeholder until a scroll reassigned `pages` (26.10.11: a
// restored A3 set at page 7 showed 4 of 10). Swap the live object in -- same
// geometry, so the layout and the cached strip stay valid -- then patch.
- (void)noteThumbnailLoadedForPage:(SPDFRenderedPage*)page {
    NSInteger index = page.pageIndex;
    SPDFRenderedPage* held = index >= 0 && index < (NSInteger)_pages.count ? _pages[(NSUInteger)index] : nil;
    if (held && held != page && held.pageIndex == index && fabs(held.pageWidth - page.pageWidth) <= 0.01 &&
        fabs(held.pageHeight - page.pageHeight) <= 0.01) {
        NSArray<SPDFRenderedPage*>* previous = _pages;
        NSMutableArray<SPDFRenderedPage*>* adopted = [_pages mutableCopy];
        adopted[(NSUInteger)index] = page;
        _pages = [adopted copy];
        if (_miniLayoutPages == previous) _miniLayoutPages = _pages;
        if (_contentImageCachePages == previous) _contentImageCachePages = _pages;
    }
    [self noteThumbnailLoadedForPageIndex:index];
}

// A thumbnail finished rendering: draw just that page into the existing cached
// strip image (a single image draw at its slot) instead of throwing the cache
// away and rebuilding the whole strip on the next scroll frame. Falls through to
// a normal redraw if there is no live cache to patch.
- (void)noteThumbnailLoadedForPageIndex:(NSInteger)pageIndex {
    if (_contentImageCache && _contentImageCacheScale > 0.0) {
        SPDFRenderedPage* target = nil;
        for (SPDFRenderedPage* page in self.pages) {
            if (page.pageIndex == pageIndex) {
                target = page;
                break;
            }
        }
        if (target) {
            NSRect miniRect = [self miniRectForPage:target
                                              scale:_contentImageCacheScale
                                                gap:_contentImageCacheGap];
            if (!NSIsEmptyRect(miniRect) && NSHeight(miniRect) >= 1.0) {
                [_contentImageCache lockFocusFlipped:YES];
                [self drawMiniPage:target inPageRect:miniRect drawImages:_contentImageCacheDrawImages];
                [_contentImageCache unlockFocus];
            }
        }
    }
    [self setNeedsDisplay:YES];
}

// Selected-page outline, drawn over the (current-page-independent) cached strip
// so crossing a page boundary while scrolling doesn't invalidate the cache.
- (void)drawCurrentPageOutlineAtContentTop:(CGFloat)contentTop scale:(CGFloat)scale gap:(CGFloat)gap {
    if (self.currentPageIndex < 0) return;
    NSRect pageRect = NSZeroRect;
    for (SPDFRenderedPage* page in self.pages) {
        if (page.pageIndex != self.currentPageIndex) continue;
        pageRect = [self miniRectForPage:page scale:scale gap:gap];
        break;
    }
    if (NSIsEmptyRect(pageRect)) return;
    pageRect.origin.y += contentTop;
    if (!NSIntersectsRect(pageRect, self.bounds)) return;
    // Light gray, not the accent color — the accent/blue is the viewport
    // indicator's color, so the selected-page outline must not compete with it.
    [[NSColor colorWithCalibratedWhite:0.75 alpha:0.9] setStroke];
    NSBezierPath* path = [NSBezierPath bezierPathWithRect:NSInsetRect(pageRect, -1, -1)];
    path.lineWidth = 1.5;
    [path stroke];
}

- (BOOL)contentImageCacheMatchesScale:(CGFloat)scale
                                  gap:(CGFloat)gap
                        contentHeight:(CGFloat)contentHeight
                           drawImages:(BOOL)drawImages {
    // currentPageIndex is intentionally NOT part of the key — the selected-page
    // outline is a drawRect: overlay, not baked into the strip — so scrolling
    // across page boundaries reuses the cached strip instead of rebuilding it.
    return _contentImageCache && _contentImageCachePages == self.pages && _contentImageCacheScale == scale &&
           _contentImageCacheGap == gap && _contentImageCacheHeight == contentHeight &&
           _contentImageCacheBoundsWidth == NSWidth(self.bounds) && _contentImageCacheDrawImages == drawImages &&
           _contentImageCacheThemeVariant == self.themeVariant;
}

- (BOOL)rebuildContentImageCacheForScale:(CGFloat)scale
                                     gap:(CGFloat)gap
                           contentHeight:(CGFloat)contentHeight
                              drawImages:(BOOL)drawImages {
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = ceil(MAX(1.0, contentHeight));
    if (width < 1.0 || height < 1.0) return NO;
    if (height > kLiveContentCacheMaxHeight || width * height > kLiveContentCacheMaxPixels) return NO;

    NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
    [image lockFocusFlipped:YES];
    [[NSColor clearColor] setFill];
    NSRectFill(NSMakeRect(0, 0, width, height));
    [self drawPageContentAtContentTop:0.0
                                scale:scale
                                  gap:gap
                           drawImages:drawImages
                             clipRect:NSMakeRect(0, 0, width, height)];
    [image unlockFocus];

    _contentImageCache = image;
    _contentImageCachePages = self.pages;
    _contentImageCacheScale = scale;
    _contentImageCacheGap = gap;
    _contentImageCacheHeight = contentHeight;
    _contentImageCacheBoundsWidth = width;
    _contentImageCacheCurrentPageIndex = self.currentPageIndex;
    _contentImageCacheDrawImages = drawImages;
    _contentImageCacheThemeVariant = self.themeVariant;
    return YES;
}

- (BOOL)drawCachedPageContentAtContentTop:(CGFloat)contentTop
                                    scale:(CGFloat)scale
                                      gap:(CGFloat)gap
                            contentHeight:(CGFloat)contentHeight
                               drawImages:(BOOL)drawImages {
    if (![self contentImageCacheMatchesScale:scale gap:gap contentHeight:contentHeight drawImages:drawImages] &&
        ![self rebuildContentImageCacheForScale:scale gap:gap contentHeight:contentHeight drawImages:drawImages])
        return NO;

    [_contentImageCache drawInRect:NSMakeRect(0, contentTop, NSWidth(self.bounds), ceil(MAX(1.0, contentHeight)))
                          fromRect:NSZeroRect
                         operation:NSCompositingOperationSourceOver
                          fraction:1.0
                    respectFlipped:YES
                             hints:@{NSImageHintInterpolation : @(NSImageInterpolationLow)}];
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    double profileStart = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
    [self.stripBackgroundColor setFill];
    NSRectFill(self.bounds);
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(0, 0, 1, NSHeight(self.bounds)));

    CGFloat scale = 1.0;
    CGFloat gap = 4.0;
    CGFloat contentTop = 8.0;
    CGFloat contentHeight = 0;
    NSRect visibleRect = NSZeroRect;
    if (![self layoutScale:&scale
                       gap:&gap
                contentTop:&contentTop
             contentHeight:&contentHeight
               visibleRect:&visibleRect])
        return;

    // Thumbnails draw at any page count: the delegate only renders/keeps a
    // bounded window of thumbnails around the viewport (see
    // SPDFMacMinimapWindow.h), pages outside it have no minimapImage and fall
    // back to the cheap placeholder, and the direct draw path below clips to
    // the visible slice — so per-frame cost stays bounded for any document
    // size. (This replaces a hard `pages.count <= 400` cap that made the
    // minimap never show content on larger documents.)
    BOOL drawImages = YES;
    BOOL drewCachedContent = self.liveViewportOnly && [self drawCachedPageContentAtContentTop:contentTop
                                                                                        scale:scale
                                                                                          gap:gap
                                                                                contentHeight:contentHeight
                                                                                   drawImages:drawImages];
    if (!drewCachedContent)
        [self drawPageContentAtContentTop:contentTop scale:scale gap:gap drawImages:drawImages clipRect:self.bounds];
    if (!self.liveViewportOnly) [self invalidateContentImageCache];
    [self drawCurrentPageOutlineAtContentTop:contentTop scale:scale gap:gap];

    if (contentHeight > 1.0) {
        visibleRect = NSIntersectionRect(visibleRect, NSInsetRect(self.bounds, 1.0, 1.0));
        if (NSWidth(visibleRect) > 1.0 && NSHeight(visibleRect) > 1.0) {
            [[NSColor colorWithCalibratedRed:0.18 green:0.55 blue:0.92 alpha:0.18] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:visibleRect xRadius:4 yRadius:4] fill];
            [[NSColor controlAccentColor] setStroke];
            NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:visibleRect xRadius:4 yRadius:4];
            path.lineWidth = 1.2;
            [path stroke];
        }
    }
    if (spdf_zoom_profile_enabled()) {
        double elapsed = spdf_zoom_profile_now_ms() - profileStart;
        if (elapsed > 2.0) spdf_zoom_profile_log(@"minimap drawRect total=%.2fms", elapsed);
    }
}

- (NSArray<NSNumber*>*)visiblePageIndexes {
    return [self visiblePageIndexesWithPaddingScreens:0.0];
}

// Pages whose strip slot intersects the visible bounds expanded vertically by
// `screens` times the strip height on each side. Padding 0 = strictly visible
// (used for eviction/keep); a large padding is used to prerender thumbnails well
// above and below the viewport so scrolling reveals already-rendered frames.
- (NSArray<NSNumber*>*)visiblePageIndexesWithPaddingScreens:(CGFloat)screens {
    CGFloat scale = 1.0;
    CGFloat gap = 4.0;
    CGFloat contentTop = 8.0;
    CGFloat contentHeight = 0;
    if (![self layoutScale:&scale gap:&gap contentTop:&contentTop contentHeight:&contentHeight visibleRect:NULL])
        return @[];

    NSRect testRect = NSInsetRect(self.bounds, 0.0, -MAX(0.0, screens) * NSHeight(self.bounds));
    NSMutableArray<NSNumber*>* indexes = [NSMutableArray array];
    for (SPDFRenderedPage* page in self.pages) {
        NSRect miniRect = [self miniRectForPage:page scale:scale gap:gap];
        miniRect.origin.y += contentTop;
        if (NSIntersectsRect(miniRect, testRect)) [indexes addObject:@(page.pageIndex)];
    }
    return indexes;
}

- (void)sendScrollRequestForEvent:(NSEvent*)event {
    CGFloat scale = 1.0;
    CGFloat gap = 4.0;
    CGFloat contentTop = 8.0;
    CGFloat contentHeight = 0;
    NSRect visibleRect = NSZeroRect;
    if (![self layoutScale:&scale
                       gap:&gap
                contentTop:&contentTop
             contentHeight:&contentHeight
               visibleRect:&visibleRect])
        return;

    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if ([self sendLongDocumentViewportDragForPoint:point
                                             event:event
                                             scale:scale
                                               gap:gap
                                     contentHeight:contentHeight
                                        contentTop:contentTop])
        return;
    if (_draggingVisibleRect) {
        point = NSMakePoint(point.x - _dragOffsetFromVisibleCenter.x, point.y - _dragOffsetFromVisibleCenter.y);
    }
    NSPoint documentPoint = [self documentPointForMinimapCenterPoint:point
                                                               scale:scale
                                                                 gap:gap
                                                       contentHeight:contentHeight
                                                          contentTop:contentTop];
    [self.reader minimapViewDidRequestCenterAtDocumentPoint:documentPoint];
}

- (void)sendClickRequestForEvent:(NSEvent*)event {
    CGFloat scale = 1.0;
    CGFloat gap = 4.0;
    CGFloat contentTop = 8.0;
    CGFloat contentHeight = 0;
    if (![self layoutScale:&scale gap:&gap contentTop:&contentTop contentHeight:&contentHeight visibleRect:NULL])
        return;

    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger pageIndex = -1;
    CGFloat xFraction = 0.5;
    CGFloat yFraction = 0.0;
    if ([self pageHitForMiniPoint:point
                            scale:scale
                              gap:gap
                       contentTop:contentTop
                        pageIndex:&pageIndex
                  xFractionInPage:&xFraction
                  yFractionInPage:&yFraction]) {
        [self.reader minimapViewDidRequestCenterOnPage:pageIndex xFractionInPage:xFraction yFractionInPage:yFraction];
    }
}

- (void)mouseDown:(NSEvent*)event {
    spdf_activate_window_for_view(self);

    CGFloat scale = 1.0;
    CGFloat gap = 4.0;
    CGFloat contentTop = 8.0;
    CGFloat contentHeight = 0;
    NSRect visibleRect = NSZeroRect;
    if (![self layoutScale:&scale
                       gap:&gap
                contentTop:&contentTop
             contentHeight:&contentHeight
               visibleRect:&visibleRect])
        return;

    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect drawnVisibleRect = [self draggableVisibleRectForRect:visibleRect];
    _pressPending = YES;
    _dragMoved = NO;
    _pressPoint = point;
    _draggingVisibleRect = NSPointInRect(point, drawnVisibleRect);
    _dragOffsetFromVisibleCenter =
        _draggingVisibleRect ? NSMakePoint(point.x - NSMidX(drawnVisibleRect), point.y - NSMidY(drawnVisibleRect))
                             : NSZeroPoint;
    _dragOffsetFromVisibleTop = _draggingVisibleRect ? point.y - NSMinY(drawnVisibleRect) : 0.0;
    _dragThumbTop = _draggingVisibleRect ? NSMinY(drawnVisibleRect) : 0.0;
    if (_draggingVisibleRect && [self shouldUseLongDocumentViewportDrag]) {
        NSRect track = NSInsetRect(self.bounds, 1.0, 1.0);
        CGFloat thumbHeight = [self longDocumentViewportDragThumbHeightForContentHeight:contentHeight track:track];
        CGFloat minTop = NSMinY(track);
        CGFloat maxTop = MAX(minTop, NSMaxY(track) - thumbHeight);
        _dragThumbTop = minTop + [self scrollFraction] * (maxTop - minTop);
    }
    _dragLastMouseY = point.y;
    _dragLastTimestamp = event.timestamp;
}

- (void)mouseDragged:(NSEvent*)event {
    if (_pressPending && !_dragMoved) {
        NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
        if (hypot(point.x - _pressPoint.x, point.y - _pressPoint.y) < 3.0) return;
        _dragMoved = YES;
        _pressPending = NO;
    }
    [self sendScrollRequestForEvent:event];
}

- (void)scrollWheel:(NSEvent*)event {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) {
        NSPoint documentPoint = NSZeroPoint;
        if ([self documentPointForEvent:event documentPoint:&documentPoint])
            [self.reader minimapViewDidReceiveZoomScrollWheel:event documentPoint:documentPoint];
        return;
    }

    [self sendStripScrollForEvent:event];
}

// A plain scroll over the minimap scrolls the STRIP by the gesture distance
// (standard scroll feel, momentum included) and the document follows to the
// position that strip offset represents — so a flick traverses the document at
// the strip's page-per-pixel scale (VS Code-style), not the document's. The
// strip has no scroll state of its own: its offset is derived from the document
// scroll position (see layoutScale:...), so moving the document by the
// strip-scale equivalent of the gesture delta makes the strip track the
// gesture 1:1 by construction, with the viewport indicator sliding along the
// track exactly as it does for any other document movement.
- (void)sendStripScrollForEvent:(NSEvent*)event {
    CGFloat scale = 1.0;
    CGFloat gap = 4.0;
    CGFloat contentTop = 8.0;
    CGFloat contentHeight = 0;
    if (![self layoutScale:&scale gap:&gap contentTop:&contentTop contentHeight:&contentHeight visibleRect:NULL]) {
        // No strip layout (no pages / degenerate bounds): keep the historical
        // fall-through to the document scroll view.
        [self.reader minimapViewDidReceiveScrollWheel:event];
        return;
    }

    CGFloat deltaY = event.scrollingDeltaY != 0.0 ? event.scrollingDeltaY : event.deltaY;
    if (!event.hasPreciseScrollingDeltas) deltaY *= kMinimapWheelPointsPerLine;

    if (fabs(deltaY) > 0.0001) {
        // Positive deltaY scrolls toward the document top (the document view's
        // convention, see scrollDocumentClipViewByDeltaX:deltaY:), i.e. the
        // strip content moves toward its start.
        CGFloat available = MAX(1.0, NSHeight(self.bounds) - 16.0);
        CGFloat currentDocumentTop = NSMinY(self.documentVisibleRect);
        CGFloat documentTop =
            spdf_minimap_document_top_for_strip_scroll(currentDocumentTop, -deltaY, contentHeight, available,
                                                       self.documentHeight, NSHeight(self.documentVisibleRect));
        BOOL discreteWheel = !event.hasPreciseScrollingDeltas && event.phase == NSEventPhaseNone &&
                             event.momentumPhase == NSEventPhaseNone;
        if (discreteWheel) {
            documentTop = spdf_minimap_document_top_capped_for_discrete_wheel(
                currentDocumentTop, documentTop, self.currentPageIndex, self.documentPageRects, self.documentHeight,
                NSHeight(self.documentVisibleRect));
        }
        _scrollWheelDrivingViewport = YES;
        // NAN center-x keeps the current horizontal position; the reader's
        // precision path defers full viewport maintenance until the finish
        // call, exactly like a viewport drag.
        [self.reader minimapViewDidRequestViewportTopDocumentY:documentTop documentCenterX:NAN];
    }

    // Finish when the gesture or its momentum tail ends; phase-less events
    // (classic wheel notches) finish immediately. A finish at fingers-up
    // followed by a momentum tail simply re-enters and finishes again.
    BOOL ended = event.phase == NSEventPhaseEnded || event.phase == NSEventPhaseCancelled ||
                 event.momentumPhase == NSEventPhaseEnded || event.momentumPhase == NSEventPhaseCancelled ||
                 (event.phase == NSEventPhaseNone && event.momentumPhase == NSEventPhaseNone);
    if (ended && _scrollWheelDrivingViewport) {
        _scrollWheelDrivingViewport = NO;
        [self.reader minimapViewDidFinishViewportDrag];
    }
}

- (void)magnifyWithEvent:(NSEvent*)event {
    NSPoint documentPoint = NSZeroPoint;
    if ([self documentPointForEvent:event documentPoint:&documentPoint])
        [self.reader minimapViewDidReceiveMagnify:event documentPoint:documentPoint];
}

- (void)mouseUp:(NSEvent*)event {
    BOOL didFinishLongDocumentViewportDrag =
        _draggingVisibleRect && _dragMoved && [self shouldUseLongDocumentViewportDrag];
    if (_pressPending && !_dragMoved) [self sendClickRequestForEvent:event];
    _draggingVisibleRect = NO;
    _pressPending = NO;
    _dragMoved = NO;
    _pressPoint = NSZeroPoint;
    _dragOffsetFromVisibleCenter = NSZeroPoint;
    _dragOffsetFromVisibleTop = 0.0;
    _dragThumbTop = 0.0;
    _dragLastMouseY = 0.0;
    _dragLastTimestamp = 0.0;
    if (didFinishLongDocumentViewportDrag) [self.reader minimapViewDidFinishViewportDrag];
}

@end
