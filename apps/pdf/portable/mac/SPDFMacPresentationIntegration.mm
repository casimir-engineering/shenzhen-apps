#import "SPDFMacMarkdownDelegatePrivate.h"

@implementation ShenzhenMacDelegate (SPDFMacPresentationIntegration)

- (BOOL)documentViewHandlePresentationMouseDown:(NSEvent*)event {
    if (!_presentationMode || ![self hasActiveDocument]) return NO;
    NSInteger action = [self presentationMouseActionForEvent:event];
    if (action < 0) {
        [self previousPage:nil];
        return YES;
    }
    if (action > 0) {
        [self nextPage:nil];
        return YES;
    }
    return NO;
}

- (NSInteger)presentationMouseActionForEvent:(NSEvent*)event {
    if (!event) return 0;
    if (event.type == NSEventTypeLeftMouseDown) return (event.modifierFlags & NSEventModifierFlagControl) != 0 ? -1 : 1;
    if (event.type == NSEventTypeRightMouseDown) return -1;
    if (event.type == NSEventTypeOtherMouseDown) {
        // AppKit uses 0/1 for left/right. Middle and forward buttons advance;
        // the common back side-button goes to the previous page.
        return event.buttonNumber == 3 ? -1 : 1;
    }
    return 0;
}

- (BOOL)handlePresentationEvent:(NSEvent*)event {
    if (!_presentationMode || ![self hasActiveDocument] || !event) return NO;
    NSInteger keyCode = event.type == NSEventTypeKeyDown ? event.keyCode : -1;
    BOOL mouseEvent = event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeRightMouseDown ||
                      event.type == NSEventTypeOtherMouseDown;
    NSInteger buttonNumber = mouseEvent ? event.buttonNumber : -1;
    if (_lastPresentationEventType == event.type && _lastPresentationEventKeyCode == keyCode &&
        _lastPresentationEventButtonNumber == buttonNumber &&
        fabs(event.timestamp - _lastPresentationEventTimestamp) < 0.03)
        return YES;

    BOOL handled = event.type == NSEventTypeKeyDown ? [self documentArrowKeyDown:event] : NO;
    if (mouseEvent) {
        [NSApp activateIgnoringOtherApps:YES];
        [_window makeKeyWindow];
        [_window makeMainWindow];
        handled = [self documentViewHandlePresentationMouseDown:event];
    }
    if (!handled) return NO;
    _lastPresentationEventType = event.type;
    _lastPresentationEventKeyCode = keyCode;
    _lastPresentationEventButtonNumber = buttonNumber;
    _lastPresentationEventTimestamp = event.timestamp;
    NSView* responder =
        _presentationOverlayView ?: ([self isMarkdownActive] ? self.activeMarkdownSession.rootView : _pageView);
    [_window makeFirstResponder:responder];
    return YES;
}

- (BOOL)documentViewInPresentationMode {
    return _presentationMode;
}

@end
