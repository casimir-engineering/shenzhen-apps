#import "SPDFMacPresentationViewport.h"

#import "SPDFMacMarkdownDelegatePrivate.h"
#import <objc/runtime.h>

@interface ShenzhenMacDelegate (SPDFMacPresentationViewportAccess)
- (void)renderDocumentAndScrollToPage:(NSInteger)pageIndex alignTop:(BOOL)alignTop;
- (void)renderDocumentAndScrollToPage:(NSInteger)pageIndex
                             alignTop:(BOOL)alignTop
                        restoreOrigin:(NSValue*)restoreOrigin;
- (void)stopKeyboardScrollAnimation;
@end

// The reader's view when presentation began, and the gesture in progress.
@interface SPDFMacPresentationViewState : NSObject
@property(nonatomic, weak) SPDFDocumentTab* tab;
@property(nonatomic) BOOL valid;
@property(nonatomic) BOOL markdown;
@property(nonatomic) NSInteger pageIndex;
@property(nonatomic) NSInteger fitPageIndex;
@property(nonatomic) CGFloat zoom;
@property(nonatomic) CGFloat customZoom;
@property(nonatomic) NSPoint origin;
// The scroll gesture under way: 0 not yet decided, 1 it turns pages, 2 it pans.
@property(nonatomic) NSInteger wheelMode;
@property(nonatomic) NSTimeInterval lastWheelTimestamp;
// A left press on a zoomed page: a click turns the page, a drag pans it.
@property(nonatomic) BOOL pressActive;
@property(nonatomic) BOOL pressDragged;
@property(nonatomic) NSTimeInterval pressTimestamp;
@property(nonatomic) NSPoint pressWindowPoint;
@property(nonatomic) NSPoint pressOrigin;
@end

@implementation SPDFMacPresentationViewState
@end

static char kSPDFPresentationViewStateKey;

// Whether the view can still move toward the page's edge on an axis (0 vertical,
// 1 horizontal) in a direction (+1 toward the bottom or the right).
static BOOL SPDFPresentationCanPan(NSRect visible, NSRect page, NSInteger axis, CGFloat direction) {
    if (axis == 1) {
        if (NSWidth(page) <= NSWidth(visible) + 0.5) return NO;
        return direction > 0 ? NSMaxX(visible) < NSMaxX(page) - 0.5 : NSMinX(visible) > NSMinX(page) + 0.5;
    }
    if (NSHeight(page) <= NSHeight(visible) + 0.5) return NO;
    return direction > 0 ? NSMaxY(visible) < NSMaxY(page) - 0.5 : NSMinY(visible) > NSMinY(page) + 0.5;
}

static BOOL SPDFPresentationPageFits(NSRect visible, NSRect page) {
    return NSWidth(page) <= NSWidth(visible) + 0.5 && NSHeight(page) <= NSHeight(visible) + 0.5;
}

@implementation ShenzhenMacDelegate (SPDFMacPresentationViewport)

- (SPDFMacPresentationViewState*)presentationViewState {
    SPDFMacPresentationViewState* state = objc_getAssociatedObject(self, &kSPDFPresentationViewStateKey);
    if (!state) {
        state = [SPDFMacPresentationViewState new];
        objc_setAssociatedObject(self, &kSPDFPresentationViewStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

// The part of the presented page on screen and the page itself, both in the
// presented view's document coordinates.
- (BOOL)presentationVisibleRect:(NSRect*)visible pageRect:(NSRect*)page {
    if ([self isMarkdownActive]) {
        SPDFMacMarkdownSession* session = self.activeMarkdownSession;
        NSArray<NSValue*>* pages = session.documentPageRects;
        NSInteger index = session.currentPageIndex;
        if (index < 0 || index >= (NSInteger)pages.count) return NO;
        *visible = session.documentVisibleRect;
        *page = pages[(NSUInteger)index].rectValue;
        return !NSIsEmptyRect(*page);
    }
    if (!_doc || _renderedPages.count == 0 || !_pageScrollView) return NO;
    *visible = _pageScrollView.contentView.bounds;
    *page = [_pageView rectForPageAtIndex:_pageIndex];
    return !NSIsEmptyRect(*page);
}

- (NSScrollView*)presentationEventTargetView {
    if (![self isMarkdownActive]) return _doc ? _pageScrollView : nil;
    for (NSView* subview in self.activeMarkdownSession.rootView.subviews)
        if ([subview isKindOfClass:NSScrollView.class]) return (NSScrollView*)subview;
    return nil;
}

- (void)scrollPresentationViewToOrigin:(NSPoint)origin {
    if ([self isMarkdownActive]) {
        NSPoint current = self.activeMarkdownSession.documentVisibleRect.origin;
        [self.activeMarkdownSession scrollByDocumentDeltaX:origin.x - current.x deltaY:origin.y - current.y];
        return;
    }
    [self documentViewPanToProposedOrigin:origin];
}

- (void)rememberViewForPresentation {
    SPDFMacPresentationViewState* state = self.presentationViewState;
    state.valid = NO;
    state.tab = [self selectedTab];
    state.markdown = [self isMarkdownActive];
    if (state.markdown) {
        SPDFMacMarkdownSession* session = self.activeMarkdownSession;
        state.pageIndex = session.currentPageIndex;
        state.zoom = session.zoom;
        state.origin = session.documentVisibleRect.origin;
    } else {
        if (!_doc) return;
        state.pageIndex = _pageIndex;
        state.zoom = _zoom;
        state.customZoom = _rememberedCustomZoom;
        state.fitPageIndex = _fitPageIndex;
        state.origin = _pageScrollView.contentView.bounds.origin;
    }
    state.valid = YES;
}

- (BOOL)restoreViewAfterPresentation {
    SPDFMacPresentationViewState* state = self.presentationViewState;
    BOOL valid = state.valid;
    state.valid = NO;
    state.pressActive = NO;
    if (!valid || state.tab != [self selectedTab] || state.markdown != [self isMarkdownActive]) return NO;
    if (state.markdown) {
        SPDFMacMarkdownSession* session = self.activeMarkdownSession;
        BOOL samePage = session.currentPageIndex == state.pageIndex;
        if (_presentationPreviousFitMode == SPDFFitModeCustom) [session setZoom:state.zoom];
        else [session applyFitMode:(SPDFMacMarkdownPageFitMode)_presentationPreviousFitMode];
        if (samePage) {
            NSSize size = session.documentVisibleRect.size;
            [session centerAtDocumentPoint:NSMakePoint(state.origin.x + size.width / 2.0,
                                                       state.origin.y + size.height / 2.0)];
        } else {
            [session goToPageAtIndex:session.currentPageIndex];
        }
        [self updateControlsForActiveMarkdown];
        return YES;
    }
    if (!_doc) return NO;
    _rememberedCustomZoom = state.customZoom;
    if (state.pageIndex == _pageIndex) {
        _fitPageIndex = state.fitPageIndex;
        [self renderDocumentAndScrollToPage:_pageIndex
                                   alignTop:NO
                              restoreOrigin:[NSValue valueWithPoint:state.origin]];
    } else {
        [self renderDocumentAndScrollToPage:_pageIndex alignTop:YES];
    }
    return YES;
}

- (void)keepNormalViewInPresentedTab:(SPDFDocumentTab*)tab {
    SPDFMacPresentationViewState* state = self.presentationViewState;
    if (!_presentationMode || !state.valid || state.tab != tab) return;
    tab.zoom = state.zoom;
    tab.fitMode = _presentationPreviousFitMode;
    if (!state.markdown) {
        tab.customZoom = state.customZoom;
        tab.fitPageIndex = state.fitPageIndex;
    } else if (_presentationPreviousFitMode == SPDFFitModeCustom) {
        tab.customZoom = state.zoom;
    }
    tab.scrollOrigin = state.origin;
    tab.hasScrollOrigin = tab.pageIndex == state.pageIndex;
}

- (void)refitPresentedPage:(SPDFFitMode)fitMode zoom:(CGFloat)zoom {
    _fitMode = fitMode;
    if (fitMode == SPDFFitModeCustom) _rememberedCustomZoom = zoom;
    [self renderDocumentAndScrollToPage:_pageIndex alignTop:YES];
}

- (BOOL)presentationArrowKeyDown:(NSEvent*)event {
    if (!_presentationMode) return NO;
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) return NO;
    unsigned short key = event.keyCode;
    if (key < 123 || key > 126) return NO;
    NSInteger axis = key == 123 || key == 124 ? 1 : 0;
    CGFloat direction = key == 124 || key == 125 ? 1.0 : -1.0;
    NSRect visible, page;
    if (![self presentationVisibleRect:&visible pageRect:&page]) return NO;
    BOOL overflows = axis == 1 ? NSWidth(page) > NSWidth(visible) + 0.5 : NSHeight(page) > NSHeight(visible) + 0.5;
    if (!overflows) return NO;
    if (SPDFPresentationCanPan(visible, page, axis, direction)) {
        [self beginOrSustainKeyboardScrollInDirection:direction axis:axis keyCode:key isRepeat:event.isARepeat];
        return YES;
    }
    if (event.isARepeat) return YES;
    [self stopKeyboardScrollAnimation];
    return NO;
}

// Asked for every wheel event while presenting; YES lets the scroll view count
// it toward a page turn, NO lets it scroll. A gesture is decided by where it
// starts: on a page that fits it turns pages, as it always has; on a zoomed
// page, a vertical gesture starting at the edge it moves toward turns the page
// and any other pans, so momentum carried into an edge stops there.
- (BOOL)presentationWheelTurnsPage:(NSEvent*)event {
    if (!_presentationMode || ![self hasActiveDocument]) return NO;
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) return NO;
    SPDFMacPresentationViewState* state = self.presentationViewState;
    BOOL began = (event.phase & (NSEventPhaseBegan | NSEventPhaseMayBegin)) != 0;
    BOOL momentum = event.momentumPhase != NSEventPhaseNone;
    BOOL phaseless = event.phase == NSEventPhaseNone && !momentum;
    // A mouse wheel has no phases: a pause starts a new gesture.
    if (began || (phaseless && event.timestamp - state.lastWheelTimestamp > 0.35)) state.wheelMode = 0;
    state.lastWheelTimestamp = event.timestamp;
    NSRect visible, page;
    if (![self presentationVisibleRect:&visible pageRect:&page]) return YES;
    if (SPDFPresentationPageFits(visible, page)) return YES;
    if (state.wheelMode == 0 && !momentum) {
        CGFloat dx = event.scrollingDeltaX, dy = event.scrollingDeltaY;
        if (fabs(dx) < 0.0001 && fabs(dy) < 0.0001) return NO;
        BOOL vertical = fabs(dy) >= fabs(dx);
        BOOL atEdge = vertical && !SPDFPresentationCanPan(visible, page, 0, dy < 0 ? 1.0 : -1.0);
        state.wheelMode = atEdge ? 1 : 2;
    }
    return state.wheelMode == 1;
}

- (BOOL)handlePresentationPanEvent:(NSEvent*)event {
    SPDFMacPresentationViewState* state = self.presentationViewState;
    switch (event.type) {
        case NSEventTypeLeftMouseDown: {
            if (event.modifierFlags & NSEventModifierFlagControl) return NO;
            if (state.pressActive && event.timestamp == state.pressTimestamp) return YES;
            NSRect visible, page;
            if (![self presentationVisibleRect:&visible pageRect:&page] || SPDFPresentationPageFits(visible, page))
                return NO;
            [NSApp activateIgnoringOtherApps:YES];
            [_window makeKeyWindow];
            state.pressActive = YES;
            state.pressDragged = NO;
            state.pressTimestamp = event.timestamp;
            state.pressWindowPoint = event.locationInWindow;
            state.pressOrigin = visible.origin;
            return YES;
        }
        case NSEventTypeLeftMouseDragged: {
            if (!state.pressActive) return NO;
            NSPoint point = event.locationInWindow;
            CGFloat dx = point.x - state.pressWindowPoint.x, dy = point.y - state.pressWindowPoint.y;
            if (!state.pressDragged && hypot(dx, dy) < 3.0) return YES;
            if (!state.pressDragged) [[NSCursor closedHandCursor] set];
            state.pressDragged = YES;
            // The page follows the pointer; Markdown's canvas is in magnified units.
            CGFloat scale = [self isMarkdownActive] ? MAX(0.01, self.activeMarkdownSession.zoom) : 1.0;
            [self scrollPresentationViewToOrigin:NSMakePoint(state.pressOrigin.x - dx / scale,
                                                             state.pressOrigin.y + dy / scale)];
            return YES;
        }
        case NSEventTypeLeftMouseUp: {
            if (!state.pressActive) return NO;
            state.pressActive = NO;
            if (state.pressDragged) [[NSCursor arrowCursor] set];
            else [self nextPage:nil];
            return YES;
        }
        default:
            return NO;
    }
}

@end
