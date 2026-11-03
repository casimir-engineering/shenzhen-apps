#import "SPDFMacMarkdownPagedViewPrivate.h"

// Presentation mode on the paged view. The canvas lays every page out, but only
// the presented one is drawn, and the clip view is held to it: centered on an
// axis where the page is smaller than the viewport, free to pan within it on an
// axis where it is zoomed past it, as the PDF view lays out its one presented
// page. Next and previous page swap the page and open it at its top left,
// keeping the zoom. All math is in canvas coordinates, the clip view's space.

@implementation SPDFMacMarkdownPagedView (Presentation)

- (NSInteger)presentedPageIndex {
    return MAX(0, MIN(_currentPageIndex, (NSInteger)self.pageCount - 1));
}

- (void)updatePresentationScrollLock {
    SPDFDocumentClipView* clip = (SPDFDocumentClipView*)self.contentView;
    _canvas.presentationPageIndex = [self presentedPageIndex];
    NSRect page = [_canvas frameForPageAtIndex:(NSUInteger)[self presentedPageIndex]];
    NSRect bounds = clip.bounds;
    BOOL fitsWidth = NSWidth(page) <= NSWidth(bounds) + 0.5;
    BOOL fitsHeight = NSHeight(page) <= NSHeight(bounds) + 0.5;
    clip.horizontalLockMinX = fitsWidth ? NSMidX(page) - NSWidth(bounds) / 2.0 : NSMinX(page);
    clip.horizontalLockMaxX = fitsWidth ? clip.horizontalLockMinX : NSMaxX(page) - NSWidth(bounds);
    clip.verticalLockMinY = fitsHeight ? NSMidY(page) - NSHeight(bounds) / 2.0 : NSMinY(page);
    clip.verticalLockMaxY = fitsHeight ? clip.verticalLockMinY : NSMaxY(page) - NSHeight(bounds);
    self.horizontalScrollElasticity = NSScrollElasticityNone;
    self.verticalScrollElasticity = NSScrollElasticityNone;
    NSPoint origin = NSMakePoint(MAX(clip.horizontalLockMinX, MIN(NSMinX(bounds), clip.horizontalLockMaxX)),
                                 MAX(clip.verticalLockMinY, MIN(NSMinY(bounds), clip.verticalLockMaxY)));
    if (fabs(origin.x - NSMinX(bounds)) <= 0.01 && fabs(origin.y - NSMinY(bounds)) <= 0.01) return;
    _updatingScrollLock = YES;
    [clip scrollToPoint:origin];
    [self reflectScrolledClipView:clip];
    _updatingScrollLock = NO;
}

// A zoom keeps the point of the page under the pointer where it is on screen,
// as far as the page's edges allow. Steps of one gesture (a pinch, a held key)
// keep the point the gesture started on, as the PDF view's live zoom does, so a
// page that stays centred while it is still narrower than the screen does not
// drift the point away.
static __weak SPDFMacMarkdownPagedView* gZoomAnchorView;
static NSPoint gZoomAnchorFraction, gZoomAnchorOnScreen;
static NSTimeInterval gZoomAnchorTime;

- (void)presentationZoom:(CGFloat)zoom keepingPoint:(NSPoint)point {
    SPDFDocumentClipView* clip = (SPDFDocumentClipView*)self.contentView;
    NSRect page = [_canvas frameForPageAtIndex:(NSUInteger)[self presentedPageIndex]];
    NSRect bounds = clip.bounds;
    CGFloat magnification = MAX(0.01, self.magnification);
    NSPoint onScreen = NSMakePoint((point.x - NSMinX(bounds)) * magnification, (point.y - NSMinY(bounds)) * magnification);
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (gZoomAnchorView != self || now - gZoomAnchorTime > 0.35 ||
        hypot(onScreen.x - gZoomAnchorOnScreen.x, onScreen.y - gZoomAnchorOnScreen.y) > 2.0)
        gZoomAnchorFraction = NSMakePoint((point.x - NSMinX(page)) / MAX(1.0, NSWidth(page)),
                                          (point.y - NSMinY(page)) / MAX(1.0, NSHeight(page)));
    gZoomAnchorView = self;
    gZoomAnchorTime = now;
    gZoomAnchorOnScreen = onScreen;
    clip.horizontalLockMinX = clip.horizontalLockMaxX = NAN;
    clip.verticalLockMinY = clip.verticalLockMaxY = NAN;
    [self setMagnification:zoom centeredAtPoint:point];
    [self updateCanvasGeometryPreservingCenter:NO];
    page = [_canvas frameForPageAtIndex:(NSUInteger)[self presentedPageIndex]];
    magnification = MAX(0.01, self.magnification);
    [clip scrollToPoint:NSMakePoint(NSMinX(page) + gZoomAnchorFraction.x * NSWidth(page) - onScreen.x / magnification,
                                    NSMinY(page) + gZoomAnchorFraction.y * NSHeight(page) - onScreen.y / magnification)];
    [self reflectScrolledClipView:clip];
}

- (void)presentPageAtIndex:(NSInteger)pageIndex {
    _currentPageIndex = MAX(0, MIN(pageIndex, (NSInteger)self.pageCount - 1));
    [_canvas setNeedsDisplay:YES];
    [self updatePresentationScrollLock];
    SPDFDocumentClipView* clip = (SPDFDocumentClipView*)self.contentView;
    [clip scrollToPoint:NSMakePoint(clip.horizontalLockMinX, clip.verticalLockMinY)];  // its top left
    [self reflectScrolledClipView:clip];
    [self viewportDidChange:nil];
}

@end
