#import "SPDFMacMarkdownPagedViewPrivate.h"

#import "SPDFMacFitGeometry.h"

static const CGFloat kSPDFMarkdownFitInset = 48.0;

// The scroll/clip background behind the sheets. The dark theme names its own
// #121212 gutter (clearly below the #1E1E1E paper); light keeps
// windowBackgroundColor exactly as before.
static NSColor* SPDFMacMarkdownGutterColor(SPDFMarkdownPaginationPlan* plan) {
    SPDFMarkdownTheme* theme = [SPDFMarkdownTheme themeForVariant:plan.configuration.themeVariant];
    return theme.viewportBackgroundColor ?: NSColor.windowBackgroundColor;
}

@implementation SPDFMacMarkdownPagedView

- (instancetype)initWithPaginationPlan:(SPDFMarkdownPaginationPlan*)plan
                      attributedString:(NSAttributedString*)attributedString {
    self = [super initWithFrame:NSZeroRect];
    if (!self) return nil;
    _plan = plan;
    _attributedString = [attributedString copy];
    _currentPageIndex = 0;
    _fitMode = SPDFMacMarkdownPageFitPage;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.borderType = NSNoBorder;
    self.drawsBackground = YES;
    self.backgroundColor = SPDFMacMarkdownGutterColor(plan);
    self.hasVerticalScroller = YES;
    // Same find-marker scroller as the PDF document scroll view: the trough
    // draws [reader findScrollbarMarkers] (delegate-routed to this session's
    // matches while a Markdown tab is active).
    SPDFFindMarkerScroller* markerScroller = [[SPDFFindMarkerScroller alloc] initWithFrame:NSZeroRect];
    self.verticalScroller = markerScroller;
    self.hasHorizontalScroller = NO;
    self.autohidesScrollers = NO;
    self.usesPredominantAxisScrolling = NO;
    self.verticalScrollElasticity = NSScrollElasticityAllowed;
    self.horizontalScrollElasticity = NSScrollElasticityAllowed;
    self.allowsMagnification = YES;
    self.minMagnification = kSPDFMarkdownMinimumZoom;
    self.maxMagnification = kSPDFMarkdownMaximumZoom;
    // Custom clip view so horizontal panning can be locked on pages that fit the
    // viewport — same mechanism as the PDF document scroll view (see
    // updateHorizontalScrollLock) — and so every scroll origin lands on a whole
    // device pixel, which is what keeps live CoreText from wobbling as it moves
    // (see SPDFMacMarkdownClipView.h).
    SPDFDocumentClipView* clipView = [[SPDFMacMarkdownClipView alloc] init];
    clipView.drawsBackground = YES;
    clipView.backgroundColor = self.backgroundColor;
    self.contentView = clipView;
    _canvas = [[SPDFMacMarkdownPageCanvas alloc] initWithPaginationPlan:plan attributedString:attributedString];
    self.documentView = _canvas;
    self.contentView.postsBoundsChangedNotifications = YES;
    self.postsFrameChangedNotifications = YES;
    __weak SPDFMacMarkdownPagedView* weakSelf = self;
    _canvas.selectionChangedHandler = ^(NSRange range) {
      (void)range;
      SPDFMacMarkdownPagedView* strongSelf = weakSelf;
      if (strongSelf.viewportChangedHandler)
          strongSelf.viewportChangedHandler(strongSelf.currentPageIndex, strongSelf.magnification);
    };
    _canvas.activateDestinationHandler = ^(NSString* destination, BOOL wikiLink) {
      SPDFMacMarkdownPagedView* strongSelf = weakSelf;
      if (strongSelf.activateDestinationHandler) strongSelf.activateDestinationHandler(destination, wikiLink);
    };
    _canvas.chooseCodeLanguageHandler = ^(NSUInteger blockIndex) {
      SPDFMacMarkdownPagedView* strongSelf = weakSelf;
      if (strongSelf.chooseCodeLanguageHandler) strongSelf.chooseCodeLanguageHandler(blockIndex);
    };
    _canvas.copyCodeBlockHandler = ^BOOL(NSUInteger blockIndex) {
      SPDFMacMarkdownPagedView* strongSelf = weakSelf;
      return strongSelf.copyCodeBlockHandler ? strongSelf.copyCodeBlockHandler(blockIndex) : NO;
    };
    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    [center addObserver:self
               selector:@selector(viewportDidChange:)
                   name:NSViewBoundsDidChangeNotification
                 object:self.contentView];
    [center addObserver:self
               selector:@selector(viewportFrameDidChange:)
                   name:NSViewFrameDidChangeNotification
                 object:self];
    [center addObserver:self
               selector:@selector(liveMagnifyWillStart:)
                   name:NSScrollViewWillStartLiveMagnifyNotification
                 object:self];
    [center addObserver:self
               selector:@selector(magnificationDidChange:)
                   name:NSScrollViewDidEndLiveMagnifyNotification
                 object:self];
    [self updateCanvasGeometryPreservingCenter:NO];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)setReader:(id<SPDFMacUIReader>)reader {
    [super setReader:reader];
    _canvas.reader = reader;
    if ([self.verticalScroller isKindOfClass:SPDFFindMarkerScroller.class])
        ((SPDFFindMarkerScroller*)self.verticalScroller).reader = reader;
}
- (NSUInteger)pageCount {
    return _canvas.pageCount;
}
- (NSInteger)currentPageIndex {
    return _currentPageIndex;
}
- (NSUInteger)visibleAttributedLocation {
    NSRect visible = self.documentVisibleRect;
    // Sample just below the top edge so a heading revealed with its 12pt
    // lead-in counts as visible; sampling the exact edge lands in the lead-in
    // and makes the chapter sidebar highlight the preceding section.
    CGFloat probeY = NSMinY(visible) + MIN(16.0, NSHeight(visible) * 0.5);
    return [_canvas attributedLocationNearestToPoint:NSMakePoint(NSMidX(visible), probeY)];
}
- (NSArray<NSValue*>*)documentPageRects {
    NSMutableArray<NSValue*>* rects = [NSMutableArray arrayWithCapacity:self.pageCount];
    for (NSUInteger pageIndex = 0; pageIndex < self.pageCount; ++pageIndex)
        [rects addObject:[NSValue valueWithRect:[_canvas frameForPageAtIndex:pageIndex]]];
    return rects;
}
- (NSSize)documentCanvasSize {
    return _canvas.bounds.size;
}
- (NSRange)selectedRange {
    return _canvas.selectedRange;
}
- (void)setSelectedRange:(NSRange)selectedRange {
    _canvas.selectedRange = selectedRange;
}
- (NSArray<NSValue*>*)searchRanges {
    return _canvas.searchRanges;
}
- (void)setSearchRanges:(NSArray<NSValue*>*)searchRanges {
    _canvas.searchRanges = searchRanges;
}
- (NSRange)activeSearchRange {
    return _canvas.activeSearchRange;
}
- (void)setActiveSearchRange:(NSRange)activeSearchRange {
    _canvas.activeSearchRange = activeSearchRange;
}
- (CGFloat)activeSearchAlpha {
    return _canvas.activeSearchAlpha;
}
- (void)setActiveSearchAlpha:(CGFloat)activeSearchAlpha {
    _canvas.activeSearchAlpha = activeSearchAlpha;
}
- (NSDictionary<NSNumber*, NSArray<NSValue*>*>*)pageLocalRectsForRanges:(NSArray<NSValue*>*)ranges {
    return [_canvas pageLocalRectsForRanges:ranges];
}
- (NSRect)firstRectForRange:(NSRange)range {
    return [_canvas firstRectForRange:range];
}
- (NSString*)selectedText {
    NSRange range = self.selectedRange;
    if (!range.length || NSMaxRange(range) > _attributedString.length) return @"";
    return [_attributedString.string substringWithRange:range];
}
- (BOOL)selectionContainsImage {
    return [_canvas selectionContainsImageAttachment];
}
- (BOOL)writeSelectionToPasteboard:(NSPasteboard*)pasteboard plainTextTransform:(NSString* (^)(NSString*))transform {
    return [_canvas writeSelectionToPasteboard:pasteboard plainTextTransform:transform];
}

- (void)updateCanvasGeometryPreservingCenter:(BOOL)preserveCenter {
    if (_updatingGeometry) return;
    _updatingGeometry = YES;
    NSPoint center = NSMakePoint(NSMidX(self.contentView.bounds), NSMidY(self.contentView.bounds));
    // contentView.bounds is expressed in canvas/magnified coordinates (its width
    // is contentSize.width / magnification), so this stays correct at any zoom.
    // The canvas needs the viewport size in the same space for the exact-fit
    // vertical inset (collapsed at fit, centering a single short page).
    _canvas.layoutViewportSize = self.contentView.bounds.size;
    CGFloat width = MAX(_plan.configuration.paperSize.width + kSPDFMarkdownFitInset, NSWidth(self.contentView.bounds));
    [_canvas resizeForWidth:width];
    if (preserveCenter) {
        NSRect bounds = self.contentView.bounds;
        NSSize canvas = _canvas.frame.size;
        NSPoint origin = NSMakePoint(center.x - NSWidth(bounds) * 0.5, center.y - NSHeight(bounds) * 0.5);
        origin.x = MAX(0.0, MIN(origin.x, MAX(0.0, canvas.width - NSWidth(bounds))));
        origin.y = MAX(0.0, MIN(origin.y, MAX(0.0, canvas.height - NSHeight(bounds))));
        [self.contentView scrollToPoint:origin];
        [self reflectScrolledClipView:self.contentView];
    }
    _updatingGeometry = NO;
    [self updateHorizontalScrollLock];
}

// Mirror of the PDF path's updateHorizontalScrollLockAnimated: — a page that
// fits the viewport is pinned centered (min==max, no horizontal elasticity); a
// page wider than the viewport pans within its own bounds only; presentation
// mode and live pinch-zoom release the lock. All math is in canvas/magnified
// coordinates, the space of both the clip view's bounds and the page frames.
// The vertical axis gets the same treatment for the fits-vertically case: a
// canvas that fits the viewport (a one-page document at or below Fit Page —
// the canvas centers the page vertically) is pinned at y=0 with no elastic
// bounce and shows no vertical scroller, since there is nothing to scroll.
- (void)updateHorizontalScrollLock {
    if (_updatingScrollLock) return;
    if (![self.contentView isKindOfClass:SPDFDocumentClipView.class]) return;
    SPDFDocumentClipView* clip = (SPDFDocumentClipView*)self.contentView;
    if (_presentationMode || _liveMagnifying || !self.pageCount) {
        clip.horizontalLockMinX = NAN;
        clip.horizontalLockMaxX = NAN;
        clip.verticalLockMinY = NAN;
        clip.verticalLockMaxY = NAN;
        self.horizontalScrollElasticity = NSScrollElasticityAllowed;
        self.verticalScrollElasticity = NSScrollElasticityAllowed;
        return;
    }
    _updatingScrollLock = YES;
    NSUInteger pageIndex = MIN((NSUInteger)MAX(_currentPageIndex, 0), self.pageCount - 1);
    NSRect page = [_canvas frameForPageAtIndex:pageIndex];
    CGFloat clipWidth = NSWidth(clip.bounds);
    CGFloat maxOriginX = MAX(0.0, NSWidth(_canvas.frame) - clipWidth);
    if (NSWidth(page) <= clipWidth + 0.5) {
        CGFloat x = MAX(0.0, MIN(NSMidX(page) - clipWidth * 0.5, maxOriginX));
        self.horizontalScrollElasticity = NSScrollElasticityNone;
        clip.horizontalLockMinX = x;
        clip.horizontalLockMaxX = x;
    } else {
        self.horizontalScrollElasticity = NSScrollElasticityAllowed;
        clip.horizontalLockMinX = MAX(0.0, MIN(NSMinX(page), maxOriginX));
        clip.horizontalLockMaxX = MAX(clip.horizontalLockMinX, MAX(0.0, MIN(NSMaxX(page) - clipWidth, maxOriginX)));
    }
    BOOL fitsVertically = NSHeight(_canvas.frame) <= NSHeight(clip.bounds) + 0.5;
    self.verticalScrollElasticity = fitsVertically ? NSScrollElasticityNone : NSScrollElasticityAllowed;
    clip.verticalLockMinY = fitsVertically ? 0.0 : NAN;
    clip.verticalLockMaxY = fitsVertically ? 0.0 : NAN;
    if (self.hasVerticalScroller != !fitsVertically) self.hasVerticalScroller = !fitsVertically;
    CGFloat clamped = MAX(clip.horizontalLockMinX, MIN(NSMinX(clip.bounds), clip.horizontalLockMaxX));
    CGFloat clampedY = fitsVertically ? 0.0 : NSMinY(clip.bounds);
    if (fabs(clamped - NSMinX(clip.bounds)) > 0.01 || fabs(clampedY - NSMinY(clip.bounds)) > 0.01) {
        [clip scrollToPoint:NSMakePoint(clamped, clampedY)];
        [self reflectScrolledClipView:clip];
    }
    _updatingScrollLock = NO;
}

- (void)viewportDidChange:(NSNotification*)notification {
    (void)notification;
    if (_updatingGeometry) return;
    NSInteger page = [_canvas pageIndexForVisibleRect:_canvas.visibleRect];
    if (page >= 0) _currentPageIndex = page;
    [self updateHorizontalScrollLock];
    // Content moved under a stationary pointer (scroll wheel, zoom, reveal):
    // re-resolve the hover cursor without waiting for a mouse move, matching
    // the PDF path's refreshCursorForMouseLocation calls.
    [_canvas refreshCursorForMouseLocation];
    if (self.viewportChangedHandler) self.viewportChangedHandler(_currentPageIndex, self.magnification);
}

- (void)viewportFrameDidChange:(NSNotification*)notification {
    (void)notification;
    // Apply the fit mode first so the canvas is resized against the final
    // magnification — resizing first left the canvas width one step stale after
    // every window resize.
    if (_fitMode != SPDFMacMarkdownPageFitCustom && _fitMode != SPDFMacMarkdownPageFitActual)
        [self applyFitMode:_fitMode];
    [self updateCanvasGeometryPreservingCenter:YES];
}

- (void)liveMagnifyWillStart:(NSNotification*)notification {
    (void)notification;
    _liveMagnifying = YES;
    [self updateHorizontalScrollLock]; // release the lock while pinching
}

- (void)magnificationDidChange:(NSNotification*)notification {
    (void)notification;
    _liveMagnifying = NO;
    _fitMode = SPDFMacMarkdownPageFitCustom;
    [self updateCanvasGeometryPreservingCenter:YES];
    [self viewportDidChange:nil];
}

- (void)setPresentationMode:(BOOL)presentationMode {
    if (_presentationMode == presentationMode) return;
    _presentationMode = presentationMode;
    self.hasVerticalScroller = !presentationMode;
    self.autohidesScrollers = presentationMode;
    self.backgroundColor = presentationMode ? NSColor.blackColor : SPDFMacMarkdownGutterColor(_plan);
    self.contentView.backgroundColor = self.backgroundColor;
    _canvas.presentationMode = presentationMode;
    [_canvas setNeedsDisplay:YES];
    [self updateHorizontalScrollLock];
}

- (void)redrawPages {
    [_canvas setNeedsDisplay:YES];
}

- (void)setZoom:(CGFloat)zoom centeredAtPoint:(NSPoint)point {
    _fitMode = fabs(zoom - 1.0) < 0.0001 ? SPDFMacMarkdownPageFitActual : SPDFMacMarkdownPageFitCustom;
    [self setMagnification:MAX(kSPDFMarkdownMinimumZoom, MIN(kSPDFMarkdownMaximumZoom, zoom)) centeredAtPoint:point];
    [self updateCanvasGeometryPreservingCenter:YES];
    [self viewportDidChange:nil];
}

- (void)zoomByFactor:(CGFloat)factor {
    NSRect visible = _canvas.visibleRect;
    [self setZoom:self.magnification * factor centeredAtPoint:NSMakePoint(NSMidX(visible), NSMidY(visible))];
}

- (void)setFitMode:(SPDFMacMarkdownPageFitMode)fitMode {
    if (_fitMode == fitMode && fitMode == SPDFMacMarkdownPageFitCustom) return;
    [self applyFitMode:fitMode];
}

// Deterministic page jump, PDF parity with scrollToPage:alignTop: (page
// stepping and direct page entry both land on the page's top with the PDF
// path's 12pt breathing room, x centered). scrollRectToVisible: performed
// AppKit's MINIMUM scroll — it moved nothing whenever the target page was
// already partially visible, while the toolbar page number still advanced.
// Routing through the page-aware scrollToDocumentOrigin: keeps the horizontal
// center-lock correct and sets _currentPageIndex from the actual scroll
// outcome (viewportDidChange:), so the number always matches the viewport.
- (void)goToPageAtIndex:(NSInteger)pageIndex alignTop:(BOOL)alignTop {
    (void)alignTop;
    if (!self.pageCount) return;
    pageIndex = MAX(0, MIN(pageIndex, (NSInteger)self.pageCount - 1));
    NSRect page = [_canvas frameForPageAtIndex:(NSUInteger)pageIndex];
    NSRect visible = self.documentVisibleRect;
    // The 12pt breathing room belongs to a page TALLER than the viewport; a page
    // that fits is centred, which at exact fit puts its top flush with the
    // viewport top. Subtracting 12 unconditionally left a strip of gutter above
    // every stepped-to sheet -- the PDF path has gone through this helper since
    // the same bug was fixed there (SPDFMacFitGeometry.h).
    CGFloat y = spdf_mac_fit_scroll_origin_y(NSMinY(page), NSHeight(page), NSHeight(visible), 12.0);
    [self scrollToDocumentOrigin:NSMakePoint(NSMidX(page) - NSWidth(visible) * 0.5, y)];
}

- (BOOL)revealRange:(NSRange)range {
    BOOL revealed = [_canvas scrollRangeToVisible:range];
    if (revealed) {
        _currentPageIndex = (NSInteger)[_canvas pageIndexForRange:range];
        if (self.viewportChangedHandler) self.viewportChangedHandler(_currentPageIndex, self.magnification);
    }
    return revealed;
}

// PDF parity with scrollToPageRect: — the find match is CENTERED in the
// viewport (revealRange: stays top-aligned for chapter/anchor navigation).
- (BOOL)centerRange:(NSRange)range {
    NSRect target = [_canvas firstRectForRange:range];
    if (NSIsEmptyRect(target)) return NO;
    NSRect visible = self.documentVisibleRect;
    [self scrollToDocumentOrigin:NSMakePoint(NSMidX(target) - NSWidth(visible) * 0.5,
                                             NSMidY(target) - NSHeight(visible) * 0.5)];
    _currentPageIndex = (NSInteger)[_canvas pageIndexForRange:range];
    if (self.viewportChangedHandler) self.viewportChangedHandler(_currentPageIndex, self.magnification);
    return YES;
}

- (NSUInteger)pageIndexForRange:(NSRange)range {
    return [_canvas pageIndexForRange:range];
}

// Page-aware scroll, mirroring the PDF path's clampedDocumentScrollOrigin:. A
// page that fits the viewport stays centered (origin.x is overwritten with the
// centered x); a wider page keeps origin.x within its own bounds; both axes are
// finally clamped to the canvas.
- (void)scrollToDocumentOrigin:(NSPoint)origin {
    NSRect visible = self.documentVisibleRect;
    NSSize canvas = self.documentCanvasSize;
    if (self.pageCount) {
        NSRect proposed = NSMakeRect(origin.x, origin.y, NSWidth(visible), NSHeight(visible));
        NSInteger pageIndex = [_canvas pageIndexForVisibleRect:proposed];
        NSRect page = [_canvas frameForPageAtIndex:(NSUInteger)MAX(pageIndex, 0)];
        if (!NSIsEmptyRect(page)) {
            if (NSWidth(page) <= NSWidth(visible) + 0.5)
                origin.x = NSMidX(page) - NSWidth(visible) * 0.5;
            else
                origin.x = MAX(NSMinX(page), MIN(origin.x, NSMaxX(page) - NSWidth(visible)));
        }
    }
    origin.x = MAX(0.0, MIN(origin.x, MAX(0.0, canvas.width - NSWidth(visible))));
    origin.y = MAX(0.0, MIN(origin.y, MAX(0.0, canvas.height - NSHeight(visible))));
    [self.contentView scrollToPoint:origin];
    [self reflectScrolledClipView:self.contentView];
    [self viewportDidChange:nil];
}

- (void)centerAtDocumentPoint:(NSPoint)point {
    NSRect visible = self.documentVisibleRect;
    [self scrollToDocumentOrigin:NSMakePoint(point.x - NSWidth(visible) * 0.5, point.y - NSHeight(visible) * 0.5)];
}

- (void)centerOnPageAtIndex:(NSInteger)pageIndex xFraction:(CGFloat)xFraction yFraction:(CGFloat)yFraction {
    if (!self.pageCount) return;
    pageIndex = MAX(0, MIN(pageIndex, (NSInteger)self.pageCount - 1));
    NSRect page = [_canvas frameForPageAtIndex:(NSUInteger)pageIndex];
    xFraction = MAX(0.0, MIN(1.0, xFraction));
    yFraction = MAX(0.0, MIN(1.0, yFraction));
    [self centerAtDocumentPoint:NSMakePoint(NSMinX(page) + xFraction * NSWidth(page),
                                            NSMinY(page) + yFraction * NSHeight(page))];
}

- (void)scrollByDocumentDeltaX:(CGFloat)deltaX deltaY:(CGFloat)deltaY {
    NSPoint origin = self.documentVisibleRect.origin;
    [self scrollToDocumentOrigin:NSMakePoint(origin.x + deltaX, origin.y + deltaY)];
}

- (void)forwardScrollWheelEvent:(NSEvent*)event {
    [super scrollWheel:event];
}

- (void)magnifyByDelta:(CGFloat)delta {
    [self magnifyByDelta:delta
        centeredAtDocumentPoint:NSMakePoint(NSMidX(self.documentVisibleRect), NSMidY(self.documentVisibleRect))];
}

- (BOOL)zoomWithScrollWheelEvent:(NSEvent*)event centeredAtWindowPoint:(NSPoint)windowPoint {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (!(flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl))) return NO;
    CGFloat delta = event.scrollingDeltaY != 0.0 ? event.scrollingDeltaY : event.deltaY;
    NSPoint documentPoint = [_canvas convertPoint:windowPoint fromView:nil];
    [self setZoom:self.magnification * pow(1.00135, delta) centeredAtPoint:documentPoint];
    return YES;
}

- (void)magnifyByDelta:(CGFloat)delta centeredAtWindowPoint:(NSPoint)windowPoint {
    [self magnifyByDelta:delta centeredAtDocumentPoint:[_canvas convertPoint:windowPoint fromView:nil]];
}

- (void)magnifyByDelta:(CGFloat)delta centeredAtDocumentPoint:(NSPoint)documentPoint {
    CGFloat factor = MAX(0.1, 1.0 + delta * 0.82);
    [self setZoom:self.magnification * factor centeredAtPoint:documentPoint];
}

- (void)noteExternalScrollPositionChanged {
    [self viewportDidChange:nil];
}

- (NSRect)codeLanguageControlFrameInViewForBlockIndex:(NSUInteger)blockIndex {
    NSRect canvasRect = [_canvas codeLanguageControlFrameForBlockIndex:blockIndex];
    if (NSIsEmptyRect(canvasRect)) return NSZeroRect;
    NSRect viewRect = [self convertRect:canvasRect fromView:_canvas];
    return NSIntersectsRect(viewRect, self.bounds) ? viewRect : NSZeroRect;
}

@end
