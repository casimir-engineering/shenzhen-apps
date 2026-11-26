// A change to a PDF page shows in the very next frame, before the file is saved.
//
// Fill & Sign and Annotate write a change into the document in memory, then save the file and redraw the page. The
// save of a large PDF takes from a few to a few hundred milliseconds (the first one after opening is the slowest), and
// the redraw of a whole page at a high zoom tens more, so a deleted object stayed on screen for several frames. Now
// the changed pages are drawn again from the document in memory first (only the part in view when the whole page
// would cost much more), the window is displayed and committed to the screen, and only then is the file saved and the
// rest of the page drawn at full quality, once the changes rest (SPDFMacFillSaving.h). When the change says where it
// is (Annotate's canvas damage), only that part of the page is drawn again, into the picture already shown.
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

static char kSPDFFillPixelsOwnerKey;  // a picture sharing another's pixels keeps the one that owns them

@implementation ShenzhenMacDelegate (SPDFMacFillShowFirst)

- (NSMutableIndexSet*)fillShownPages:(const void*)key {
    NSMutableIndexSet* set = objc_getAssociatedObject(self, key);
    if (!set) {
        set = [NSMutableIndexSet indexSet];
        objc_setAssociatedObject(self, key, set, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return set;
}

// image (showing `shown`, page points) with the part of the page in `area` drawn again from the document in memory,
// into its own pixels, and handed back as a new picture over them (so nothing keeps a drawing of the old ones):
// nothing the size of the whole page is rendered or copied. nil when it isn't a picture this can do it with.
- (NSImage*)fillImage:(NSImage*)image showing:(NSRect)shown page:(NSUInteger)index patched:(NSRect)area {
    NSBitmapImageRep* rep = (NSBitmapImageRep*)image.representations.firstObject;
    if (!image || image.representations.count != 1 || ![rep isKindOfClass:NSBitmapImageRep.class] || rep.isPlanar ||
        rep.bitsPerPixel != 32 || rep.samplesPerPixel != 4 || !rep.bitmapData || NSIsEmptyRect(shown))
        return nil;
    // The scale it was drawn at (pixels per page point): the zoom's, unless the page was too large for it.
    CGFloat sx = _zoom * [self backingScale];
    if (sx <= 0 || fabs(rep.pixelsWide - NSWidth(shown) * sx) > 1.5 || fabs(rep.pixelsHigh - NSHeight(shown) * sx) > 1.5)
        return nil;
    // Its pixels in the picture: the part's edges on the picture's pixels.
    NSInteger px0 = MAX(0, (NSInteger)floor((NSMinX(area) - NSMinX(shown)) * sx));
    NSInteger py0 = MAX(0, (NSInteger)floor((NSMinY(area) - NSMinY(shown)) * sx));
    NSInteger px1 = MIN(rep.pixelsWide, (NSInteger)ceil((NSMaxX(area) - NSMinX(shown)) * sx));
    NSInteger py1 = MIN(rep.pixelsHigh, (NSInteger)ceil((NSMaxY(area) - NSMinY(shown)) * sx));
    if (px1 <= px0 || py1 <= py0) return image;  // nothing of it in this picture
    NSRect crop = NSMakeRect(NSMinX(shown) + px0 / sx, NSMinY(shown) + py0 / sx, (px1 - px0) / sx, (py1 - py0) / sx);
    char err[256];
    NSImage* part = [self renderedPageCropImageAtIndex:(NSInteger)index document:_doc zoom:_zoom displayScale:sx / _zoom
                                          pageCropRect:crop useList:NO error:err errorLength:sizeof(err)];
    NSBitmapImageRep* patch = (NSBitmapImageRep*)part.representations.firstObject;
    if (![patch isKindOfClass:NSBitmapImageRep.class] || patch.bitsPerPixel != 32 || patch.isPlanar) return nil;
    unsigned char* pixels = rep.bitmapData;
    NSInteger rows = MIN(patch.pixelsHigh, py1 - py0), columns = MIN(patch.pixelsWide, px1 - px0);
    for (NSInteger y = 0; y < rows; ++y)
        memcpy(pixels + (size_t)(py0 + y) * (size_t)rep.bytesPerRow + (size_t)px0 * 4,
               patch.bitmapData + (size_t)y * (size_t)patch.bytesPerRow, (size_t)columns * 4);
    NSBitmapImageRep* shared = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:&pixels pixelsWide:rep.pixelsWide
        pixelsHigh:rep.pixelsHigh bitsPerSample:8 samplesPerPixel:4 hasAlpha:rep.hasAlpha isPlanar:NO
        colorSpaceName:rep.colorSpaceName bitmapFormat:rep.bitmapFormat bytesPerRow:rep.bytesPerRow bitsPerPixel:32];
    if (!shared) return nil;
    NSBitmapImageRep* owner = objc_getAssociatedObject(rep, &kSPDFFillPixelsOwnerKey) ?: rep;
    objc_setAssociatedObject(shared, &kSPDFFillPixelsOwnerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    shared.size = rep.size;
    NSImage* patched = [[NSImage alloc] initWithSize:image.size];
    [patched addRepresentation:shared];
    return patched;
}

// Only the changed part of a page drawn again, into the sharp picture of it on screen (the whole page, or at a high
// zoom the part in view): a redraw of the whole costs all its pixels, and a change is a few of them.
// The page's other pictures stay, as when the whole is drawn. NO: drawn as before (*whole: the whole page was patched).
- (BOOL)fillPatchPage:(NSUInteger)index area:(NSRect)area scale:(CGFloat)scale whole:(BOOL*)whole {
    SPDFRenderedPage* page = _renderedPages[index];
    if (page.pageWidth <= 0 || page.pageHeight <= 0) return NO;
    // Two points around what changed: an annotation's own drawing can reach a little past its object's box.
    area = NSIntersectionRect(NSInsetRect(area, -2, -2), NSMakeRect(0, 0, page.pageWidth, page.pageHeight));
    if (NSIsEmptyRect(area)) return NO;
    SPDFRenderedPage* now = [SPDFRenderedPage new];  // the part draws in the reading theme of the moment: the page's own
    [self stampReadingThemeOnRenderedPage:now renderFlags:[self readingThemeRenderFlags]];
    if (now.imageDarkTheme != page.imageDarkTheme || now.imagePreservesImageColors != page.imagePreservesImageColors)
        return NO;
    if (page.image && fabs(page.imageZoom - _zoom) <= 0.001 && fabs(page.imageScale - scale) <= 0.001) {
        NSImage* image = [self fillImage:page.image showing:NSMakeRect(0, 0, page.pageWidth, page.pageHeight) page:index
                                 patched:area];
        if (!image) return NO;
        page.image = image;
        *whole = YES;
        return YES;
    }
    // The part in view, when what is in view is all in it (a scroll since may have left some of it outside).
    NSRect visible = [self visiblePageCropRectForPageIndex:(NSInteger)index extraViewMargin:0];
    NSRect shown = page.viewportImagePageRect;
    if (!page.viewportImage || fabs(page.viewportImageZoom - _zoom) > 0.001 ||
        fabs(page.viewportImageScale - scale) > 0.001 || !NSContainsRect(NSInsetRect(shown, -0.5, -0.5), visible))
        return NO;
    NSImage* image = [self fillImage:page.viewportImage showing:shown page:index patched:area];
    if (!image) return NO;
    page.viewportImage = image;
    *whole = NO;
    return YES;
}

- (void)fillRedrawFromMemoryPages:(NSIndexSet*)pages areas:(NSDictionary<NSNumber*, NSValue*>*)areas {
    NSMutableIndexSet* whole = [self fillShownPages:&kSPDFFillShownWholeKey];
    NSMutableIndexSet* inView = [self fillShownPages:&kSPDFFillShownInViewKey];
    // Pages changed earlier and not saved yet keep how they were shown; these are shown again now.
    [whole removeIndexes:pages];
    [inView removeIndexes:pages];
    if (!_doc || !_pageView || !pages.count) return;
    _visibleCropRenderSequence++;  // a crop of the page as it was, still rendering, is never shown
    CGFloat scale = [self backingScale];
    NSInteger preferred = -1;
    NSArray<NSNumber*>* visible = [self visibleDocumentPageIndexesWithExtraRadius:0 preferredPage:&preferred];
    [pages enumerateIndexesUsingBlock:^(NSUInteger index, BOOL* stop) {
      (void)stop;
      if (index >= self->_renderedPages.count || ![visible containsObject:@(index)]) return;
      NSValue* area = areas[@(index)];
      BOOL patchedWhole = NO;
      if (area && [self fillPatchPage:index area:area.rectValue scale:scale whole:&patchedWhole]) {
          [self->_pageView refreshRenderedPages:self->_renderedPages changedPageIndex:(NSInteger)index];
          [(patchedWhole ? whole : inView) addIndex:index];  // as if drawn so: the save's redraw follows that
          return;
      }
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

- (void)fillForgetShownPages:(NSIndexSet*)pages {
    for (NSMutableIndexSet* set in @[[self fillShownPages:&kSPDFFillShownWholeKey], [self fillShownPages:&kSPDFFillShownInViewKey]])
        pages ? [set removeIndexes:pages] : [set removeAllIndexes];
}

@end
