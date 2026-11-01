#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
extern const CGFloat kMinZoom;
extern const CGFloat kMaxZoom;
@interface ShenzhenMacDelegate (FitViewportPrivate)
- (BOOL)renderDocumentKeepingVisibleCenter;
- (void)applyFitModeKeepingPosition:(SPDFFitMode)fitMode;
- (NSSize)documentClipSizeForLayout;
- (CGFloat)zoomForFitMode:(SPDFFitMode)mode pageSize:(NSSize)size clipSize:(NSSize)clip fallbackZoom:(CGFloat)zoom;
@end
@implementation ShenzhenMacDelegate (FitViewport)
- (void)rememberCurrentZoomForCustomReturn {
    if (_fitMode == SPDFFitModeCustom && _zoom > 0) _rememberedCustomZoom = _zoom;
}

- (void)actualSize:(id)sender {
    (void)sender;
    if ([self isMarkdownActive]) {
        [self markdownApplyFitMode:SPDFFitModeActual];
        return;
    }
    [self applyFitModeKeepingPosition:SPDFFitModeActual];
}

- (void)fitWidth:(id)sender {
    (void)sender;
    if ([self isMarkdownActive]) {
        [self markdownApplyFitMode:SPDFFitModeWidth];
        return;
    }
    [self applyFitModeKeepingPosition:SPDFFitModeWidth];
}

- (void)fitHeight:(id)sender {
    (void)sender;
    if ([self isMarkdownActive]) {
        [self markdownApplyFitMode:SPDFFitModeHeight];
        return;
    }
    [self applyFitModeKeepingPosition:SPDFFitModeHeight];
}

- (void)fitPage:(id)sender {
    (void)sender;
    if ([self isMarkdownActive]) {
        [self markdownApplyFitMode:SPDFFitModePage];
        return;
    }
    [self applyFitModeKeepingPosition:SPDFFitModePage];
}

// Every zoom command of the Zoom menu, the toolbar and the fit popup. Fit Width, 100% and a custom zoom keep the
// reading position: the point of the page under the viewport's centre stays under its centre, as Zoom In and Zoom
// Out keep it. Fit Page and Fit Height show the whole of the current page. Re-rendering with the old scroll origin
// (alignTop:NO) read that origin, taken at the old zoom, against the pages laid out at the new one, and then pulled
// the page's far edge into view: Fit Width from Fit Page or 100% always landed on the bottom of the page.
- (void)applyFitModeKeepingPosition:(SPDFFitMode)fitMode {
    if (!_doc) return;
    if (fitMode == SPDFFitModeCustom)
        _zoom = MAX(kMinZoom, MIN(kMaxZoom, _rememberedCustomZoom > 0 ? _rememberedCustomZoom : _zoom));
    else
        [self rememberCurrentZoomForCustomReturn];
    _fitMode = fitMode;
    BOOL wholePage = fitMode == SPDFFitModePage || fitMode == SPDFFitModeHeight;
    if (wholePage || ![self renderDocumentKeepingVisibleCenter])
        [self renderDocumentAndScrollToPage:_pageIndex alignTop:wholePage];
    [self persistActiveState];
}

- (void)fitModePopupChanged:(id)sender {
    (void)sender;
    NSInteger selectedTag = _fitModePopup.selectedItem.tag;
    SPDFFitMode selected = (SPDFFitMode)MAX(0, MIN(4, selectedTag));
    if ([self isMarkdownActive]) {
        [self markdownApplyFitMode:selected];
    } else if (_doc) {
        [self applyFitModeKeepingPosition:selected];
    } else {
        _fitMode = selected;
    }
}

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

- (CGFloat)zoomForFitMode:(SPDFFitMode)fitMode
                 pageSize:(NSSize)pageSize
                 clipSize:(NSSize)clipSize
             fallbackZoom:(CGFloat)fallbackZoom {
    fallbackZoom = fallbackZoom > 0 ? fallbackZoom : 1.0;
    if (fitMode == SPDFFitModeCustom) return MAX(kMinZoom, MIN(kMaxZoom, fallbackZoom));
    if (fitMode == SPDFFitModeActual) return 1.0;
    if (pageSize.width <= 0.0 || pageSize.height <= 0.0 || clipSize.width <= 0.0 || clipSize.height <= 0.0)
        return MAX(kMinZoom, MIN(kMaxZoom, fallbackZoom));

    CGFloat widthZoom = clipSize.width / pageSize.width;
    CGFloat heightZoom = clipSize.height / pageSize.height;
    if (fitMode == SPDFFitModeWidth) return MAX(kMinZoom, MIN(kMaxZoom, widthZoom));
    if (fitMode == SPDFFitModeHeight) return MAX(kMinZoom, MIN(kMaxZoom, heightZoom));
    return MAX(kMinZoom, MIN(kMaxZoom, MIN(widthZoom, heightZoom)));
}
@end
