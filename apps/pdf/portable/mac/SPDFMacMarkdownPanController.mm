#import "SPDFMacMarkdownPanController.h"

@implementation SPDFMacMarkdownPanController {
    __weak NSView* _documentView;
    NSTimer* _inertiaTimer;
    NSPoint _panStartInWindow;
    NSPoint _panStartOrigin;
    NSPoint _lastPanPoint;
    NSTimeInterval _lastPanTime;
    NSPoint _panVelocity;
    BOOL _panning;
    BOOL _moved;
}

- (instancetype)initWithDocumentView:(NSView*)documentView {
    NSParameterAssert(documentView);
    self = [super init];
    if (!self) return nil;
    _documentView = documentView;
    return self;
}

- (BOOL)isPanning {
    return _panning;
}

- (NSScrollView*)scrollView {
    return _documentView.enclosingScrollView;
}

// Window points per document unit. The Markdown view zooms with the scroll
// view's magnification, so the clip view's bounds stay in UNMAGNIFIED document
// units: a pointer that moves 30 window points at 200% has crossed 15 document
// units, and scrolling the origin by the raw 30 dragged the page twice as far
// as the hand. (The PDF view re-renders at its zoom and keeps magnification at
// 1, which is why the same arithmetic is exact there.)
- (CGFloat)magnification {
    CGFloat magnification = self.scrollView.magnification;
    return magnification > 0.0 ? magnification : 1.0;
}

- (void)scrollToOrigin:(NSPoint)origin {
    NSScrollView* scrollView = self.scrollView;
    NSClipView* clipView = scrollView.contentView;
    if (!scrollView || !clipView) return;
    NSRect bounds = clipView.bounds;
    bounds.origin = origin;
    [clipView scrollToPoint:[clipView constrainBoundsRect:bounds].origin];
    [scrollView reflectScrolledClipView:clipView];
}

- (void)beginAtWindowPoint:(NSPoint)windowPoint timestamp:(NSTimeInterval)timestamp {
    NSScrollView* scrollView = self.scrollView;
    if (!scrollView) return;
    [self cancel];
    _panning = YES;
    _moved = NO;
    _panStartInWindow = windowPoint;
    _panStartOrigin = scrollView.contentView.bounds.origin;
    _lastPanPoint = windowPoint;
    _lastPanTime = timestamp;
    _panVelocity = NSZeroPoint;
    [NSCursor.closedHandCursor set];
}

- (void)continueAtWindowPoint:(NSPoint)windowPoint timestamp:(NSTimeInterval)timestamp {
    if (!_panning) return;
    _moved = YES;
    CGFloat scale = self.magnification;
    NSPoint delta = NSMakePoint((windowPoint.x - _panStartInWindow.x) / scale,
                                (windowPoint.y - _panStartInWindow.y) / scale);
    [self scrollToOrigin:NSMakePoint(_panStartOrigin.x - delta.x, _panStartOrigin.y + delta.y)];
    NSTimeInterval elapsed = MAX(0.001, timestamp - _lastPanTime);
    _panVelocity =
        NSMakePoint((windowPoint.x - _lastPanPoint.x) / elapsed, (windowPoint.y - _lastPanPoint.y) / elapsed);
    _lastPanPoint = windowPoint;
    _lastPanTime = timestamp;
}

- (void)stepInertia:(NSTimer*)timer {
    if (!self.scrollView) {
        [self cancel];
        return;
    }
    NSPoint origin = self.scrollView.contentView.bounds.origin;
    // The velocity is in window points per second; the origin is in document units.
    CGFloat scale = self.magnification;
    [self scrollToOrigin:NSMakePoint(origin.x - _panVelocity.x / 60.0 / scale,
                                     origin.y + _panVelocity.y / 60.0 / scale)];
    _panVelocity.x *= 0.90;
    _panVelocity.y *= 0.90;
    if (hypot(_panVelocity.x, _panVelocity.y) >= 12.0) return;
    [timer invalidate];
    _inertiaTimer = nil;
    _panVelocity = NSZeroPoint;
}

- (void)end {
    if (!_panning) return;
    _panning = NO;
    _moved = NO;
    [NSCursor.arrowCursor set];
    if (self.panDidEndHandler) self.panDidEndHandler();
    if (hypot(_panVelocity.x, _panVelocity.y) <= 90.0) {
        _panVelocity = NSZeroPoint;
        return;
    }
    [_inertiaTimer invalidate];
    _inertiaTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                                     target:self
                                                   selector:@selector(stepInertia:)
                                                   userInfo:nil
                                                    repeats:YES];
}

- (void)cancel {
    BOOL wasPanning = _panning;
    [_inertiaTimer invalidate];
    _inertiaTimer = nil;
    _panning = NO;
    _panVelocity = NSZeroPoint;
    [NSCursor.arrowCursor set];
    if (wasPanning && self.panDidEndHandler) self.panDidEndHandler();
}

- (void)dealloc {
    [_inertiaTimer invalidate];
}

@end
