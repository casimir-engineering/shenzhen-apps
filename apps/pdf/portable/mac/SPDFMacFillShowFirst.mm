// A change to a PDF page shows in the very next frame, before the file is saved.
//
// Fill & Sign and Annotate write a change into the document in memory, then save the file and redraw the page. The
// save of a large PDF takes from a few to a few hundred milliseconds (the first one after opening is the slowest), and
// the redraw of a whole page at a high zoom tens more, so a deleted object stayed on screen for several frames. Now
// the changed pages are drawn again from the document in memory first (only the part in view when the whole page
// would cost much more), the window is displayed and committed to the screen, and only then is the file saved and the
// rest of the page drawn at full quality. Everything still happens in the same turn: nothing waits for later, so a
// close or quit right after the change finds the file saved, as before.
#import "SPDFMacFillShowFirst.h"

#import "SPDFMacEditedPageThumbnails.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacViewportRenderPriority.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static char kSPDFFillShownWholeKey, kSPDFFillShownInViewKey;

// Implemented by the coordinator (ShenzhenPDFMac.mm).
@interface ShenzhenMacDelegate (SPDFMacFillShowFirstReader)
- (CGFloat)backingScale;
- (SPDFRenderedPage*)renderedPageAtIndex:(NSInteger)pageIndex
                                document:(spdf_document*)doc
                                    zoom:(CGFloat)zoom
                            displayScale:(CGFloat)displayScale
                                   error:(char*)err
                             errorLength:(size_t)errLen;
- (NSImage*)renderedPageCropImageAtIndex:(NSInteger)pageIndex
                                document:(spdf_document*)doc
                                    zoom:(CGFloat)zoom
                            displayScale:(CGFloat)displayScale
                            pageCropRect:(NSRect)pageCropRect
                                 useList:(BOOL)useList
                                   error:(char*)err
                             errorLength:(size_t)errLen;
- (NSRect)pixelSnappedPageCropRect:(NSRect)cropRect
                              page:(SPDFRenderedPage*)page
                              zoom:(CGFloat)zoom
                      displayScale:(CGFloat)displayScale;
@end

@implementation ShenzhenMacDelegate (SPDFMacFillShowFirst)

- (NSMutableIndexSet*)fillShownPages:(const void*)key {
    NSMutableIndexSet* set = objc_getAssociatedObject(self, key);
    if (!set) {
        set = [NSMutableIndexSet indexSet];
        objc_setAssociatedObject(self, key, set, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return set;
}

- (void)fillRedrawFromMemoryPages:(NSIndexSet*)pages {
    NSMutableIndexSet* whole = [self fillShownPages:&kSPDFFillShownWholeKey];
    NSMutableIndexSet* inView = [self fillShownPages:&kSPDFFillShownInViewKey];
    [whole removeAllIndexes];
    [inView removeAllIndexes];
    if (!_doc || !_pageView || !pages.count) return;
    _visibleCropRenderSequence++;  // a crop of the page as it was, still rendering, is never shown
    CGFloat scale = [self backingScale];
    NSInteger preferred = -1;
    NSArray<NSNumber*>* visible = [self visibleDocumentPageIndexesWithExtraRadius:0 preferredPage:&preferred];
    [pages enumerateIndexesUsingBlock:^(NSUInteger index, BOOL* stop) {
      (void)stop;
      if (index >= self->_renderedPages.count || ![visible containsObject:@(index)]) return;
      SPDFRenderedPage* old = self->_renderedPages[index];
      NSRect crop = [self visiblePageCropRectForPageIndex:(NSInteger)index extraViewMargin:0];
      crop = [self pixelSnappedPageCropRect:crop page:old zoom:self->_zoom displayScale:scale];
      if (NSIsEmptyRect(crop)) return;
      // The whole page when it costs about what the part in view does (a page that fits the window); else that part.
      BOOL wholeAllowed = [self fullPageRenderAllowedForPage:old zoom:self->_zoom displayScale:scale];
      BOOL wholePage = wholeAllowed && old.pageWidth * old.pageHeight <= 2.0 * NSWidth(crop) * NSHeight(crop);
      char err[512];
      SPDFRenderedPage* page = nil;
      if (wholePage) {
          page = [self renderedPageAtIndex:(NSInteger)index document:self->_doc zoom:self->_zoom displayScale:scale
                                     error:err errorLength:sizeof(err)];
      } else {
          NSImage* image = [self renderedPageCropImageAtIndex:(NSInteger)index document:self->_doc zoom:self->_zoom
                                                 displayScale:scale pageCropRect:crop useList:NO error:err
                                                  errorLength:sizeof(err)];
          if (image) {
              page = [[SPDFRenderedPage alloc] init];
              page.pageIndex = old.pageIndex;
              page.pageWidth = old.pageWidth;
              page.pageHeight = old.pageHeight;
              [self stampReadingThemeOnRenderedPage:page renderFlags:[self readingThemeRenderFlags]];
              page.viewportImage = image;
              page.viewportImagePageRect = crop;
              page.viewportImageZoom = self->_zoom;
              page.viewportImageScale = scale;
          }
      }
      if (!page) return;  // the save's redraw draws it, as before
      page.highlights = old.highlights ?: @[];
      page.selectionRects = old.selectionRects ?: @[];
      if (wholePage) {
          [self copyMinimapThumbnailFromPage:old toPage:page];
      } else {  // the lower-resolution pictures of the page as it was would show past the crop's edges
          page.minimapImage = old.minimapImage;
          page.minimapImageZoom = old.minimapImageZoom;
          page.minimapImageScale = old.minimapImageScale;
      }
      [self->_renderedPages replaceObjectAtIndex:index withObject:page];
      [self->_pageView refreshRenderedPages:self->_renderedPages changedPageIndex:(NSInteger)index];
      [(wholePage ? whole : inView) addIndex:index];
    }];
}

- (void)fillCommitDisplay {
    [_window displayIfNeeded];
    [CATransaction flush];
}

- (BOOL)fillPageShownWhole:(NSUInteger)index {
    return [[self fillShownPages:&kSPDFFillShownWholeKey] containsIndex:index];
}

- (BOOL)fillPageShownInView:(NSUInteger)index {
    return [[self fillShownPages:&kSPDFFillShownInViewKey] containsIndex:index];
}

- (void)fillForgetShownPages {
    [[self fillShownPages:&kSPDFFillShownWholeKey] removeAllIndexes];
    [[self fillShownPages:&kSPDFFillShownInViewKey] removeAllIndexes];
}

@end
