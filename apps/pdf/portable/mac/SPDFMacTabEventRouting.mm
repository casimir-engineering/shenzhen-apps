#import "SPDFMacDelegatePrivate.h"

@interface ShenzhenMacDelegate (TabEventRoutingHost)
- (BOOL)eventHitsTopChromeResizeCorner:(NSEvent*)event;
- (BOOL)eventHitsStandardWindowButton:(NSEvent*)event;
- (void)performTopChromeWindowDragWithEvent:(NSEvent*)event;
@end

@implementation ShenzhenMacDelegate (TabEventRouting)
- (BOOL)handleTabStripMouseEvent:(NSEvent*)event {
    NSEventType type = event.type;
    // A popup or native tracking loop may consume the previous mouse-up. A new
    // press starts a new gesture; never let stale tab capture steal another view's drag.
    if (type == NSEventTypeLeftMouseDown) _tabStripCapturingMouse = NO;
    if (type == NSEventTypeOtherMouseDown && event.buttonNumber == 2) _tabStripCapturingMiddleMouse = NO;
    if (!_tabStrip || !_window || _presentationMode) return NO;
    if (type == NSEventTypeRightMouseDown) {
        if (_tabStripHeightConstraint.constant <= 0.0) return NO;
        NSPoint point = [_tabStrip convertPoint:event.locationInWindow fromView:nil];
        if (!NSPointInRect(point, _tabStrip.bounds)) return NO;
        [_tabStrip rightMouseDown:event];
        return YES;
    }

    // Middle-click (button 2) on a tab closes it. The strip sits under the
    // transparent title bar, so it never receives these events through normal
    // hit-testing — forward them like the left/right-click paths above/below.
    if (type == NSEventTypeOtherMouseDown || type == NSEventTypeOtherMouseUp) {
        if (event.buttonNumber != 2) return NO;
        if (type == NSEventTypeOtherMouseDown) {
            _tabStripCapturingMiddleMouse = NO;
            if (_tabStripHeightConstraint.constant <= 0.0) return NO;
            NSPoint point = [_tabStrip convertPoint:event.locationInWindow fromView:nil];
            if (!NSPointInRect(point, _tabStrip.bounds)) return NO;
            _tabStripCapturingMiddleMouse = YES;
            [_tabStrip otherMouseDown:event];
            return YES;
        }
        if (!_tabStripCapturingMiddleMouse) return NO;
        _tabStripCapturingMiddleMouse = NO;
        [_tabStrip otherMouseUp:event];
        return YES;
    }

    if (type == NSEventTypeLeftMouseDown) {
        if ([self eventHitsTopChromeResizeCorner:event]) return NO;
        if ([self eventHitsStandardWindowButton:event]) {
            [self dismissTabHoverPanel];
            return NO;
        }
        if (_tabStripHeightConstraint.constant > 0.0) {
            NSPoint point = [_tabStrip convertPoint:event.locationInWindow fromView:nil];
            if (NSPointInRect(point, _tabStrip.bounds)) {
                if ([_tabStrip containsTabOrControlAtPoint:point]) {
                    _tabStripCapturingMouse = YES;
                    [_tabStrip mouseDown:event];
                } else {
                    _tabStripCapturingMouse = NO;
                    [self dismissTabHoverPanel];
                    [self performTopChromeWindowDragWithEvent:event];
                }
                return YES;
            }
        }
        return NO;
    }

    if (!_tabStripCapturingMouse) return NO;
    if (type == NSEventTypeLeftMouseDragged) {
        [_tabStrip mouseDragged:event];
        return YES;
    }
    if (type == NSEventTypeLeftMouseUp) {
        _tabStripCapturingMouse = NO;
        [_tabStrip mouseUp:event];
        return YES;
    }
    return NO;
}
@end
