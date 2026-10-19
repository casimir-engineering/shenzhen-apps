#import "SPDFMacDelegatePrivate.h"
extern const CGFloat kMinZoom;
extern const CGFloat kMaxZoom;
@interface ShenzhenMacDelegate (FitViewportPrivate)
- (NSSize)documentClipSizeForLayout;
- (CGFloat)zoomForFitMode:(SPDFFitMode)mode pageSize:(NSSize)size clipSize:(NSSize)clip fallbackZoom:(CGFloat)zoom;
@end
@implementation ShenzhenMacDelegate (FitViewport)
- (CGFloat)zoomForFitMode:(SPDFFitMode)fitMode pageIndex:(NSInteger)pageIndex {
    if (!_doc) return _zoom;
    if (fitMode == SPDFFitModeCustom)
        return MAX(kMinZoom, MIN(kMaxZoom, _rememberedCustomZoom > 0 ? _rememberedCustomZoom : _zoom));
    if (fitMode == SPDFFitModeActual) return 1.0;

    char err[1024];
    float pageWidth = 0;
    float pageHeight = 0;
    if (!spdf_page_size(_doc, (int)pageIndex, &pageWidth, &pageHeight, err, sizeof(err)) || pageWidth <= 0 ||
        pageHeight <= 0)
        return _zoom;

    // Predict scrollbar ownership before measuring either fit axis. A stale
    // scrollbar changes the viewport and otherwise makes the first key press
    // differ from the next one, in both Fit Width and Fit Height.
    _pageScrollView.hasHorizontalScroller = NO;
    _pageScrollView.hasVerticalScroller = !_presentationMode && spdf_page_count(_doc) > 1;
    [_pageScrollView tile];
    if (fitMode == SPDFFitModeHeight || fitMode == SPDFFitModeWidth) {
        BOOL heightFit = fitMode == SPDFFitModeHeight;
        NSSize page = NSMakeSize(pageWidth,pageHeight);
        NSSize clip = [self documentClipSizeForLayout];
        CGFloat fitted = [self zoomForFitMode:fitMode pageSize:page clipSize:clip fallbackZoom:_zoom];
        BOOL needsScroller = heightFit ? pageWidth*fitted > clip.width+.5 :
            (!_presentationMode && pageHeight*fitted > clip.height+.5);
        if (needsScroller) {
            if (heightFit) _pageScrollView.hasHorizontalScroller = YES;
            else _pageScrollView.hasVerticalScroller = YES;
            [_pageScrollView tile];
            NSSize reduced = [self documentClipSizeForLayout];
            fitted = [self zoomForFitMode:fitMode pageSize:page clipSize:reduced fallbackZoom:_zoom];
            BOOL stillNeeds = heightFit ? pageWidth*fitted > reduced.width+.5 : pageHeight*fitted > reduced.height+.5;
            if (!stillNeeds && spdf_page_count(_doc)==1) {
                // A legacy scroller can make itself unnecessary near the
                // aspect-ratio boundary. Fit both axes to avoid oscillation.
                _pageScrollView.hasHorizontalScroller = NO;
                _pageScrollView.hasVerticalScroller = NO; [_pageScrollView tile];
                return [self zoomForFitMode:SPDFFitModePage pageSize:page
                                  clipSize:[self documentClipSizeForLayout] fallbackZoom:_zoom];
            }
        }
    }
    return [self zoomForFitMode:fitMode
                       pageSize:NSMakeSize(pageWidth, pageHeight)
                       clipSize:[self documentClipSizeForLayout]
                   fallbackZoom:_zoom];
}

@end
