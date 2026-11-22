#import "SPDFMacEditedPageThumbnails.h"

#import "SPDFMacMinimapView.h"

#import <objc/runtime.h>

static char kSPDFMinimapEditStampsKey;
static NSUInteger gSPDFMinimapEditStamp;

// Implemented by the coordinator.
@interface ShenzhenMacDelegate (SPDFMacEditedPageThumbnailsHost)
- (CGFloat)backingScale;
- (void)enqueueVisibleMinimapThumbnailRenders;
@end

@implementation ShenzhenMacDelegate (SPDFMacEditedPageThumbnails)

- (void)copyMinimapThumbnailFromPage:(SPDFRenderedPage*)source toPage:(SPDFRenderedPage*)destination {
    if (!source || !destination) return;
    destination.minimapImage = source.minimapImage;
    destination.minimapImageZoom = source.minimapImageZoom;
    destination.minimapImageScale = source.minimapImageScale;
    destination.baseImage = source.baseImage;
    destination.baseImagePointWidth = source.baseImagePointWidth;
    destination.baseImagePointHeight = source.baseImagePointHeight;
    destination.baseImageZoom = source.baseImageZoom;
    destination.baseImageScale = source.baseImageScale;
    destination.highQualityImage = source.highQualityImage;
    destination.highQualityImagePointWidth = source.highQualityImagePointWidth;
    destination.highQualityImagePointHeight = source.highQualityImagePointHeight;
    destination.highQualityImageZoom = source.highQualityImageZoom;
    destination.highQualityImageScale = source.highQualityImageScale;
}

- (NSMutableDictionary<NSNumber*, NSNumber*>*)spdf_minimapEditStamps {
    NSMutableDictionary* stamps = objc_getAssociatedObject(self, &kSPDFMinimapEditStampsKey);
    if (!stamps) {
        stamps = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &kSPDFMinimapEditStampsKey, stamps, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return stamps;
}

- (NSUInteger)minimapThumbnailEditStampForPage:(NSInteger)pageIndex {
    NSDictionary* stamps = objc_getAssociatedObject(self, &kSPDFMinimapEditStampsKey);
    return [stamps[@(pageIndex)] unsignedIntegerValue];
}

- (void)spdf_forgetQueuedMinimapThumbnailOfPage:(NSNumber*)number {
    [(NSOperation*)[_queuedMinimapThumbnailOperations objectForKey:number] cancel]; // an SPDFRenderOperation
    [_queuedMinimapThumbnailOperations removeObjectForKey:number];
    [_queuedMinimapThumbnailPages removeObject:number];
}

- (void)refreshMinimapThumbnailsOfEditedPages:(NSIndexSet*)pages {
    if (!_doc || pages.count == 0) return;
    NSMutableDictionary<NSNumber*, NSNumber*>* stamps = [self spdf_minimapEditStamps];
    NSSet<NSNumber*>* shown = _minimapVisible ? [NSSet setWithArray:[_minimapView visiblePageIndexes]] : [NSSet set];
    CGFloat scale = [self backingScale];
    __block BOOL renderLater = NO;
    [pages enumerateIndexesUsingBlock:^(NSUInteger index, BOOL* stop) {
      if (index >= self->_renderedPages.count) {
          *stop = YES;
          return;
      }
      NSNumber* number = @(index);
      stamps[number] = @(++gSPDFMinimapEditStamp);
      [self spdf_forgetQueuedMinimapThumbnailOfPage:number];
      SPDFRenderedPage* page = self->_renderedPages[index];
      CGFloat zoom = [self->_minimapView thumbnailRenderZoomForPage:page];
      SPDFRenderedPage* thumbnail = nil;
      if (zoom > 0.0 && scale > 0.0 && [shown containsObject:number]) {
          char err[512];
          thumbnail = [self renderedPageAtIndex:(NSInteger)index document:self->_doc zoom:zoom displayScale:scale
                                          error:err errorLength:sizeof(err)];
      }
      if (thumbnail.image) {
          page.minimapImage = thumbnail.image;
          page.minimapImageZoom = zoom;
          page.minimapImageScale = scale;
          [self->_minimapView noteThumbnailLoadedForPage:page];
          return;
      }
      // Not in the strip's view. Within the thumbnail window the new one is queued now, and the old one keeps the
      // place until it lands; further out the old one goes, and the page renders when the window gets there.
      if (spdf_minimap_window_contains(self->_minimapThumbnailWindow, (NSInteger)index)) {
          page.minimapImageZoom = 0.0;
          renderLater = YES;
      } else {
          page.minimapImage = nil;
          page.minimapImageZoom = 0.0;
          page.minimapImageScale = 0.0;
      }
    }];
    if (renderLater) [self enqueueVisibleMinimapThumbnailRenders];
}

- (void)rerenderDocumentAfterEditOfPages:(NSIndexSet*)pages restoreOrigin:(NSValue*)restoreOrigin {
    NSArray<SPDFRenderedPage*>* before = [_renderedPages copy];
    [self renderDocumentAndScrollToPage:_pageIndex alignTop:NO restoreOrigin:restoreOrigin];
    if (_renderedPages.count != before.count) return;
    CGFloat scale = [self backingScale];
    for (NSUInteger index = 0; index < before.count; ++index) {
        SPDFRenderedPage* old = before[index];
        SPDFRenderedPage* page = _renderedPages[index];
        if ([pages containsIndex:index] || !old.minimapImage || page.minimapImage ||
            fabs(old.pageWidth - page.pageWidth) > 0.01 || fabs(old.pageHeight - page.pageHeight) > 0.01)
            continue;
        page.minimapImage = old.minimapImage;
        page.minimapImageZoom = old.minimapImageZoom;
        page.minimapImageScale = old.minimapImageScale;
        // The re-render queued it again along with every page that had lost its thumbnail.
        CGFloat zoom = [_minimapView thumbnailRenderZoomForPage:page];
        if (fabs(page.minimapImageZoom - zoom) <= 0.01 && fabs(page.minimapImageScale - scale) <= 0.01)
            [self spdf_forgetQueuedMinimapThumbnailOfPage:@(index)];
    }
    [self refreshMinimapThumbnailsOfEditedPages:pages];
    [_minimapView setNeedsDisplay:YES];
}

@end
