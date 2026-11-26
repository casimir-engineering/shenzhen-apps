#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacAnnotateIntegration.h"
#import "SPDFMacAnnotateIntegrationPrivate.h"
#import "SPDFMacAnnotateOperations.h"
#import "SPDFMacAnnotateSessionPrivate.h"
#import "SPDFMacAnnotateCanvasView.h"
#import "SPDFMacFillController.h"
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

// The zoom that 100% means: 1 for a PDF page point per screen point; a picture or canvas with Annotate on, one picture
// pixel per screen point (Paint's actual size), where the reader lays a picture out at 96 pixels to the inch.
- (CGFloat)actualZoom {
    SPDFAnnotateDocumentKind kind = [self annotateShowing] ? [self annotateActiveDocumentKind] : SPDFAnnotateDocumentNone;
    if (!_doc || (kind != SPDFAnnotateDocumentPicture && kind != SPDFAnnotateDocumentCanvas)) return 1.0;
    float width = 0, height = 0;
    char err[256];
    NSSize pixels = [self annotateActiveSession].readerPixelSize;
    if (!spdf_page_size(_doc, 0, &width, &height, err, sizeof(err)) || width <= 0 || pixels.width <= 0) return 1.0;
    return pixels.width / width;
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

// The room a fit fills: a picture or canvas with Annotate on keeps clear of the palette above (topReserve) and the
// status bar below, with a small margin, so its edges and canvas handles stay in view.
- (NSSize)fitClipSizeForLayout {
    NSSize size = [self documentClipSizeForLayout];
    SPDFAnnotateDocumentKind kind = [self annotateShowing] ? [self annotateActiveDocumentKind] : SPDFAnnotateDocumentNone;
    if (kind != SPDFAnnotateDocumentPicture && kind != SPDFAnnotateDocumentCanvas) return size;
    CGFloat below = SPDFAnnotateSettings.shared.showsStatusBar ? SPDFAnnotateStatusBarHeight : 0;
    // The page is centred below the palette, so the bar's room is kept on both sides: 12 pt clear of it.
    size.height = MAX(1, size.height - _pageView.topReserve - 2 * below - 24);
    // The Layers panel is in the minimap's place, beside the page area, not over it.
    size.width = MAX(1, size.width - 32);
    return size;
}

// Annotate came on or went off: a fitted picture fits the room it has now.
- (void)annotateRefit {
    SPDFAnnotateDocumentKind kind = [self annotateActiveDocumentKind];
    if (kind != SPDFAnnotateDocumentPicture && kind != SPDFAnnotateDocumentCanvas) return;
    if (_fitMode == SPDFFitModePage || _fitMode == SPDFFitModeWidth || _fitMode == SPDFFitModeHeight)
        [self applyFitModeKeepingPosition:_fitMode];
}

- (CGFloat)zoomForFitMode:(SPDFFitMode)fitMode pageIndex:(NSInteger)pageIndex {
    if (!_doc) return _zoom;
    if (fitMode == SPDFFitModeCustom)
        return MAX(kMinZoom, MIN(kMaxZoom, _rememberedCustomZoom > 0 ? _rememberedCustomZoom : _zoom));
    if (fitMode == SPDFFitModeActual) return [self actualZoom];

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
        NSSize clip = [self fitClipSizeForLayout];
        CGFloat fitted = [self zoomForFitMode:fitMode pageSize:page clipSize:clip fallbackZoom:_zoom];
        // Presentation mode never shows a scroller, even on a page that pans.
        BOOL needsScroller = !_presentationMode && (heightFit ? pageWidth*fitted > clip.width+.5 :
            pageHeight*fitted > clip.height+.5);
        if (needsScroller) {
            if (heightFit) _pageScrollView.hasHorizontalScroller = YES;
            else _pageScrollView.hasVerticalScroller = YES;
            [_pageScrollView tile];
            NSSize reduced = [self fitClipSizeForLayout];
            fitted = [self zoomForFitMode:fitMode pageSize:page clipSize:reduced fallbackZoom:_zoom];
            BOOL stillNeeds = heightFit ? pageWidth*fitted > reduced.width+.5 : pageHeight*fitted > reduced.height+.5;
            if (!stillNeeds && spdf_page_count(_doc)==1) {
                // A legacy scroller can make itself unnecessary near the
                // aspect-ratio boundary. Fit both axes to avoid oscillation.
                _pageScrollView.hasHorizontalScroller = NO;
                _pageScrollView.hasVerticalScroller = NO; [_pageScrollView tile];
                return [self zoomForFitMode:SPDFFitModePage pageSize:page
                                  clipSize:[self fitClipSizeForLayout] fallbackZoom:_zoom];
            }
        }
    }
    return [self zoomForFitMode:fitMode
                       pageSize:NSMakeSize(pageWidth, pageHeight)
                       clipSize:[self fitClipSizeForLayout]
                   fallbackZoom:_zoom];
}

- (CGFloat)zoomForFitMode:(SPDFFitMode)fitMode
                 pageSize:(NSSize)pageSize
                 clipSize:(NSSize)clipSize
             fallbackZoom:(CGFloat)fallbackZoom {
    fallbackZoom = fallbackZoom > 0 ? fallbackZoom : 1.0;
    if (fitMode == SPDFFitModeCustom) return MAX(kMinZoom, MIN(kMaxZoom, fallbackZoom));
    if (fitMode == SPDFFitModeActual) return [self actualZoom];
    if (pageSize.width <= 0.0 || pageSize.height <= 0.0 || clipSize.width <= 0.0 || clipSize.height <= 0.0)
        return MAX(kMinZoom, MIN(kMaxZoom, fallbackZoom));

    CGFloat widthZoom = clipSize.width / pageSize.width;
    CGFloat heightZoom = clipSize.height / pageSize.height;
    // A very large picture in Annotate still fits whole, edges and canvas handles in view, below the reader's 10 %.
    SPDFAnnotateDocumentKind kind = [self annotateShowing] ? [self annotateActiveDocumentKind] : SPDFAnnotateDocumentNone;
    CGFloat low = kind == SPDFAnnotateDocumentPicture || kind == SPDFAnnotateDocumentCanvas ? 0.01 : kMinZoom;
    if (fitMode == SPDFFitModeWidth) return MAX(low, MIN(kMaxZoom, widthZoom));
    if (fitMode == SPDFFitModeHeight) return MAX(low, MIN(kMaxZoom, heightZoom));
    return MAX(low, MIN(kMaxZoom, MIN(widthZoom, heightZoom)));
}

// Annotate on a picture or a canvas pans past its edges, as Paint and Photoshop do: there is room for every edge and
// corner to come to the middle of the view at any zoom (about half the view on each side). The room is the clip view's
// content insets, which the clip view's own constraint, the scroll bars and the wheel honour; the reader's positions
// (fit, 100 %, a zoom kept around a point) are unchanged, so the canvas shows where it did. The middle is the middle of
// the room under the palette, where a fit centres the canvas.
- (BOOL)annotatePansPastEdges {
    SPDFAnnotateDocumentKind kind = [self annotateShowing] ? [self annotateActiveDocumentKind] : SPDFAnnotateDocumentNone;
    return _doc && !_presentationMode && _renderedPages.count > 0 &&
           (kind == SPDFAnnotateDocumentPicture || kind == SPDFAnnotateDocumentCanvas);
}

- (NSEdgeInsets)annotatePanMargin {
    if (![self annotatePansPastEdges]) return NSEdgeInsetsZero;
    NSSize view = _pageScrollView.contentView.frame.size, document = _pageView.frame.size;
    NSRect page = [_pageView rectForPageAtIndex:0];
    // A canvas resized and not yet saved is larger or smaller than the page the reader lays out: its own edges count.
    SPDFMacAnnotateCanvasView* canvasView = [self existingFillController].annotateCanvasView;
    int width = 0, height = 0;
    if (canvasView.session) spdf_paint_size(canvasView.session.canvas, &width, &height);
    if (width > 0 && height > 0)
        page = [_pageView convertRect:[canvasView viewRectForCanvasRect:NSMakeRect(0, 0, width, height) page:-1]
                             fromView:canvasView];
    CGFloat midX = floor(view.width / 2), midY = floor(_pageView.topReserve + MAX(0.0, view.height - _pageView.topReserve) / 2);
    return NSEdgeInsetsMake(MAX(0.0, midY - NSMinY(page)), MAX(0.0, midX - NSMinX(page)),
                            MAX(0.0, ceil(NSMaxY(page) - midY - document.height + view.height)),
                            MAX(0.0, ceil(NSMaxX(page) - midX - document.width + view.width)));
}

- (BOOL)annotateUpdatePanMargin {
    NSClipView* clip = _pageScrollView.contentView;
    NSEdgeInsets margin = [self annotatePanMargin];
    BOOL on = [self annotatePansPastEdges];
    // Left alone unless Annotate set it: off, the clip view goes back to the insets AppKit gives it.
    if (on ? !clip.automaticallyAdjustsContentInsets && NSEdgeInsetsEqual(margin, clip.contentInsets)
           : clip.automaticallyAdjustsContentInsets)
        return on;
    NSPoint origin = clip.bounds.origin;  // setting the insets would move the view to their top left
    clip.automaticallyAdjustsContentInsets = !on;
    if (on) clip.contentInsets = margin;
    else clip.contentInsets = NSEdgeInsetsZero;
    [clip setBoundsOrigin:[self documentScrollOriginWithinPanRange:origin]];
    [_pageScrollView reflectScrolledClipView:clip];
    return on;
}

// The farthest the view may scroll: the document, and with Annotate on a picture or canvas the room past its edges.
- (NSPoint)documentScrollOriginWithinPanRange:(NSPoint)origin {
    NSClipView* clip = _pageScrollView.contentView;
    NSEdgeInsets m = [self annotatePanMargin];
    CGFloat maxX = MAX(0.0, NSWidth(_pageView.bounds) - NSWidth(clip.bounds)) + m.right;
    CGFloat maxY = MAX(0.0, NSHeight(_pageView.bounds) - NSHeight(clip.bounds)) + m.bottom;
    return NSMakePoint(MAX(-m.left, MIN(origin.x, maxX)), MAX(-m.top, MIN(origin.y, maxY)));
}
@end
