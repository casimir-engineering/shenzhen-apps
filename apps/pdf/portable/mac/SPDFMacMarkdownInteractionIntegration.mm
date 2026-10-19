#import "SPDFMacMarkdownDelegatePrivate.h"

#import "SPDFMacMarkdownKeyboardPolicy.h"
#import "SPDFMacMarkdownMinimapModel.h"
#import "SPDFMacMarkdownSidebarModel.h"
#import "SPDFMacMinimapView.h"

@implementation ShenzhenMacDelegate (SPDFMacMarkdownInteractionIntegration)

- (NSDictionary*)currentMarkdownChapterItem {
    SPDFMacMarkdownSession* session = self.activeMarkdownSession;
    return [session.sidebarModel chapterItemPrecedingAttributedLocation:session.visibleAttributedLocation
                                                      fallbackPageIndex:session.currentPageIndex];
}

- (BOOL)markdownArrowKeyDown:(NSEvent*)event {
    SPDFMacMarkdownSession* session = self.activeMarkdownSession;
    // Gate horizontal arrow-key scrolling on the current PAGE width, not the
    // canvas width: a page that fits the viewport is center-locked, so left and
    // right arrows should page instead of attempting a no-op horizontal scroll.
    NSArray<NSValue*>* pageRects = session.documentPageRects;
    NSUInteger pageIndex = (NSUInteger)MAX(session.currentPageIndex, 0);
    NSRect pageRect = pageIndex < pageRects.count ? pageRects[pageIndex].rectValue : NSZeroRect;
    BOOL horizontallyScrollable = NSWidth(pageRect) > NSWidth(session.documentVisibleRect) + 1.0;
    SPDFMacMarkdownKeyAction action =
        spdf_mac_markdown_key_action(event.keyCode, event.modifierFlags, _presentationMode, horizontallyScrollable);
    switch (action) {
        case SPDFMacMarkdownKeyActionEscape:
            return [self documentEscapeKeyDown:event];
        case SPDFMacMarkdownKeyActionExitPresentation:
            [self leavePresentationModeAndExitFullScreen:YES sender:nil];
            return YES;
        case SPDFMacMarkdownKeyActionPreviousTab:
            [self selectPreviousTab:nil];
            return YES;
        case SPDFMacMarkdownKeyActionNextTab:
            [self selectNextTab:nil];
            return YES;
        case SPDFMacMarkdownKeyActionPreviousPage:
            [self markdownPreviousPage];
            return YES;
        case SPDFMacMarkdownKeyActionNextPage:
            [self markdownNextPage];
            return YES;
        case SPDFMacMarkdownKeyActionFirstPage:
            [self markdownFirstPage];
            return YES;
        case SPDFMacMarkdownKeyActionLastPage:
            [self markdownLastPage];
            return YES;
        case SPDFMacMarkdownKeyActionScrollLeft:
        case SPDFMacMarkdownKeyActionScrollRight:
            [self beginOrSustainKeyboardScrollInDirection:action == SPDFMacMarkdownKeyActionScrollRight ? 1.0 : -1.0
                                                     axis:1
                                                  keyCode:event.keyCode
                                                 isRepeat:event.isARepeat];
            return YES;
        case SPDFMacMarkdownKeyActionScrollUp:
        case SPDFMacMarkdownKeyActionScrollDown:
            [self beginOrSustainKeyboardScrollInDirection:action == SPDFMacMarkdownKeyActionScrollDown ? 1.0 : -1.0
                                                     axis:0
                                                  keyCode:event.keyCode
                                                 isRepeat:event.isARepeat];
            return YES;
        case SPDFMacMarkdownKeyActionUnhandled:
            return NO;
    }
}

- (BOOL)markdownZoomWithScrollWheelEvent:(NSEvent*)event centeredAtWindowPoint:(NSPoint)windowPoint {
    return [self.activeMarkdownSession zoomWithScrollWheelEvent:event centeredAtWindowPoint:windowPoint];
}

- (void)markdownZoomWithMagnifyDelta:(CGFloat)delta centeredAtWindowPoint:(NSPoint)windowPoint {
    [self.activeMarkdownSession magnifyByDelta:delta centeredAtWindowPoint:windowPoint];
}

- (void)markdownDocumentScrollPositionChanged {
    [self.activeMarkdownSession noteExternalScrollPositionChanged];
    [self updateMarkdownMinimap];
}

- (void)updateMarkdownMinimap {
    if (![self isMarkdownActive] || !_minimapView) return;
    SPDFMacMarkdownSession* session = self.activeMarkdownSession;
    SPDFMacMarkdownMinimapModel* model = session.minimapModel;
    if (!model) {
        _minimapView.pages = @[];
        [_minimapView setNeedsDisplay:YES];
        return;
    }
    [model updateViewportPageRects:session.documentPageRects
                       visibleRect:session.documentVisibleRect
                      documentSize:session.documentCanvasSize
                     documentScale:1.0];
    _minimapView.liveViewportOnly = NO;
    _minimapView.themeVariant = self.markdownThemeVariant;
    if (_minimapView.pages != model.pages) _minimapView.pages = model.pages;
    _minimapView.documentPageRects = model.documentPageRects;
    _minimapView.documentVisibleRect = model.documentVisibleRect;
    _minimapView.documentWidth = MAX(1.0, model.documentSize.width);
    _minimapView.documentHeight = MAX(1.0, model.documentSize.height);
    _minimapView.documentScale = 1.0;
    _minimapView.currentPageIndex = session.currentPageIndex;
    [_minimapView setNeedsDisplay:YES];
    if (!_minimapVisible || _windowLiveResizing) return;

    NSArray<NSNumber*>* visiblePages = [_minimapView visiblePageIndexesWithPaddingScreens:1.5];
    CGFloat backingScale = MAX(1.0, _window.backingScaleFactor);
    __weak ShenzhenMacDelegate* weakSelf = self;
    __weak SPDFMacMarkdownSession* weakSession = session;
    __weak SPDFMacMarkdownMinimapModel* weakModel = model;
    for (NSNumber* pageNumber in visiblePages) {
        NSInteger pageIndex = pageNumber.integerValue;
        if (pageIndex < 0 || pageIndex >= (NSInteger)model.pages.count) continue;
        SPDFRenderedPage* page = model.pages[(NSUInteger)pageIndex];
        CGFloat renderZoom = [_minimapView thumbnailRenderZoomForPage:page];
        if (renderZoom <= 0.0) continue;
        NSSize pixelSize =
            NSMakeSize(page.pageWidth * renderZoom * backingScale, page.pageHeight * renderZoom * backingScale);
        [model requestThumbnailForPageIndex:(NSUInteger)pageIndex
                            targetPixelSize:pixelSize
                                 completion:^(SPDFRenderedPage* loadedPage, NSImage* image) {
                                   ShenzhenMacDelegate* strongSelf = weakSelf;
                                   if (!strongSelf || !image || strongSelf.activeMarkdownSession != weakSession ||
                                       weakSession.minimapModel != weakModel)
                                       return;
                                   [strongSelf->_minimapView noteThumbnailLoadedForPageIndex:loadedPage.pageIndex];
                                 }];
    }
}

- (void)markdownMinimapViewportTopFraction:(CGFloat)yFraction documentCenterX:(CGFloat)documentCenterX {
    SPDFMacMarkdownSession* session = self.activeMarkdownSession;
    NSRect visible = session.documentVisibleRect;
    NSSize canvas = session.documentCanvasSize;
    yFraction = MAX(0.0, MIN(1.0, yFraction));
    CGFloat top = yFraction * MAX(0.0, canvas.height - NSHeight(visible));
    CGFloat centerX = isfinite(documentCenterX) ? documentCenterX : NSMidX(visible);
    [session centerAtDocumentPoint:NSMakePoint(centerX, top + NSHeight(visible) * 0.5)];
}

- (void)markdownMinimapViewportTopDocumentY:(CGFloat)documentTopY documentCenterX:(CGFloat)documentCenterX {
    SPDFMacMarkdownSession* session = self.activeMarkdownSession;
    NSRect visible = session.documentVisibleRect;
    CGFloat centerX = isfinite(documentCenterX) ? documentCenterX : NSMidX(visible);
    [session centerAtDocumentPoint:NSMakePoint(centerX, documentTopY + NSHeight(visible) * 0.5)];
}

- (void)markdownMinimapCenterAtDocumentPoint:(NSPoint)documentPoint {
    [self.activeMarkdownSession centerAtDocumentPoint:documentPoint];
}

- (void)markdownMinimapCenterOnPage:(NSInteger)pageIndex
                    xFractionInPage:(CGFloat)xFraction
                    yFractionInPage:(CGFloat)yFraction {
    [self.activeMarkdownSession centerOnPageAtIndex:pageIndex xFraction:xFraction yFraction:yFraction];
}

- (void)markdownMinimapReceiveScrollWheel:(NSEvent*)event {
    [self.activeMarkdownSession forwardScrollWheelEvent:event];
}

- (void)markdownMinimapReceiveZoomScrollWheel:(NSEvent*)event documentPoint:(NSPoint)documentPoint {
    CGFloat delta = event.hasPreciseScrollingDeltas ? -event.scrollingDeltaY * 0.012 : -event.deltaY * 0.08;
    [self.activeMarkdownSession magnifyByDelta:delta centeredAtDocumentPoint:documentPoint];
}

- (void)markdownMinimapReceiveMagnifyDelta:(CGFloat)delta documentPoint:(NSPoint)documentPoint {
    [self.activeMarkdownSession magnifyByDelta:delta centeredAtDocumentPoint:documentPoint];
}

- (void)markdownPreviousPage {
    [self.activeMarkdownSession goToPageAtIndex:_pageIndex - 1];
}
- (void)markdownNextPage {
    [self.activeMarkdownSession goToPageAtIndex:_pageIndex + 1];
}
- (void)markdownFirstPage {
    [self.activeMarkdownSession goToPageAtIndex:0];
}
- (void)markdownLastPage {
    NSInteger last = MAX(0, (NSInteger)self.activeMarkdownSession.pageCount - 1);
    [self.activeMarkdownSession goToPageAtIndex:last];
}
- (void)markdownGoToPage:(NSInteger)pageIndex {
    [self.activeMarkdownSession goToPageAtIndex:pageIndex];
}
- (void)markdownZoomByFactor:(CGFloat)factor {
    [self.activeMarkdownSession zoomByFactor:factor];
    [self updateControlsForActiveMarkdown];
}
- (void)markdownApplyFitMode:(SPDFFitMode)fitMode {
    SPDFMacMarkdownSession* session = self.activeMarkdownSession;
    if (fitMode == SPDFFitModeCustom)
        [session setZoom:_rememberedCustomZoom > 0 ? _rememberedCustomZoom : _zoom];
    else
        [session applyFitMode:(SPDFMacMarkdownPageFitMode)fitMode];
    [self updateControlsForActiveMarkdown];
    [self persistActiveState];
}
- (void)relayoutActiveMarkdownForViewportChange {
    SPDFMacMarkdownSession* session = self.activeMarkdownSession;
    if (session.fitMode != SPDFMacMarkdownPageFitCustom && session.fitMode != SPDFMacMarkdownPageFitActual)
        [session applyFitMode:session.fitMode];
}

@end
