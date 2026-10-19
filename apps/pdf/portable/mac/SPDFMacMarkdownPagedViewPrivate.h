#import "SPDFMacMarkdownPagedView.h"

#import "SPDFMacMarkdownClipView.h"
#import "SPDFMacMarkdownPageCanvas.h"
#import "markdown/SPDFMarkdownPaginator.h"

// The zoom range, shared by the fit category and the pinch/wheel paths.
static const CGFloat kSPDFMarkdownMinimumZoom = 0.10;
static const CGFloat kSPDFMarkdownMaximumZoom = 5.00;

// The paged view's storage and the seams its categories reach. The fit logic
// lives in SPDFMacMarkdownPagedView+Fit.mm; everything it touches is declared
// here rather than in the class's own @implementation block so that file can
// see it. _fitMode is named for the `fitMode` property so the property's
// auto-synthesis binds to it and the main file keeps owning -setFitMode:.
@interface SPDFMacMarkdownPagedView () {
  @protected
    SPDFMacMarkdownPageCanvas* _canvas;
    SPDFMarkdownPaginationPlan* _plan;
    NSAttributedString* _attributedString;
    NSInteger _currentPageIndex;
    SPDFMacMarkdownPageFitMode _fitMode;
    BOOL _updatingGeometry;
    BOOL _updatingScrollLock;
    BOOL _liveMagnifying;
}

// Re-lays the canvas out against the current magnification and viewport,
// keeping the viewport's center where it was when asked to.
- (void)updateCanvasGeometryPreservingCenter:(BOOL)preserveCenter;
// The scroll position moved: re-derive the current page, the locks, the cursor,
// and tell the session.
- (void)viewportDidChange:(NSNotification* _Nullable)notification;
- (void)updateHorizontalScrollLock;

@end
