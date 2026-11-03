#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacPresentationViewport.h"

// Presentation mode: entering and leaving it, the window it takes over, and the
// clicks and keys that turn its pages. Zooming and panning the presented page
// follow the rules in SPDFMacPresentationViewport.mm.
@interface ShenzhenMacDelegate (SPDFMacPresentationIntegrationAccess)
- (BOOL)windowIsFullScreen;
- (void)applyPresentationChrome;
- (void)rememberCurrentZoomForCustomReturn;
- (void)stopKeyboardScrollAnimation;
- (void)rebuildSidebar;
- (void)renderDocumentAndScrollToPage:(NSInteger)pageIndex alignTop:(BOOL)alignTop;
- (void)markdownApplyFitMode:(SPDFFitMode)fitMode;
@end

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
    // A press on a page zoomed past the screen may become a drag that pans it.
    if ([self handlePresentationPanEvent:event]) return YES;
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

- (NSRect)presentationScreenFrame {
    NSScreen* screen = _window.screen ?: NSScreen.mainScreen;
    return screen ? screen.frame : _window.frame;
}

- (void)enterPresentationWindowChrome {
    if (_presentationUsingBorderlessWindow || !_window) return;
    if ([self windowIsFullScreen]) {
        [_window makeKeyAndOrderFront:nil];
        [_window makeMainWindow];
        [NSApp activateIgnoringOtherApps:YES];
        return;
    }

    _presentationPreviousWindowFrame = _window.frame;
    _presentationPreviousWindowStyleMask = _window.styleMask;
    _presentationPreviousWindowLevel = _window.level;
    _presentationPreviousCollectionBehavior = _window.collectionBehavior;
    _presentationPreviousTitleVisibility = _window.titleVisibility;
    _presentationPreviousTitlebarAppearsTransparent = _window.titlebarAppearsTransparent;
    _presentationPreviousMovable = _window.movable;
    _presentationPreviousMovableByWindowBackground = _window.movableByWindowBackground;
    _presentationPreviousHasShadow = _window.hasShadow;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
      context.duration = 0.0;
      _window.styleMask = NSWindowStyleMaskBorderless;
      _window.titleVisibility = NSWindowTitleHidden;
      _window.titlebarAppearsTransparent = YES;
      _window.movable = NO;
      _window.movableByWindowBackground = NO;
      _window.hasShadow = NO;
      _window.level = NSPopUpMenuWindowLevel;
      _window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                   NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary;
      [_window setFrame:[self presentationScreenFrame] display:YES animate:NO];
    }];
    [_window makeKeyAndOrderFront:nil];
    [_window makeMainWindow];
    [NSApp activateIgnoringOtherApps:YES];
    _presentationUsingBorderlessWindow = YES;
}

- (void)restorePresentationWindowChrome {
    if (!_presentationUsingBorderlessWindow || !_window) return;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
      context.duration = 0.0;
      _window.level = _presentationPreviousWindowLevel;
      _window.collectionBehavior = _presentationPreviousCollectionBehavior;
      _window.styleMask = _presentationPreviousWindowStyleMask;
      _window.titleVisibility = _presentationPreviousTitleVisibility;
      _window.titlebarAppearsTransparent = _presentationPreviousTitlebarAppearsTransparent;
      _window.movable = _presentationPreviousMovable;
      _window.movableByWindowBackground = _presentationPreviousMovableByWindowBackground;
      _window.hasShadow = _presentationPreviousHasShadow;
      [_window setFrame:_presentationPreviousWindowFrame display:YES animate:NO];
    }];
    _presentationUsingBorderlessWindow = NO;
    [_window makeKeyAndOrderFront:nil];
    [_window makeMainWindow];
}

- (void)installPresentationEventMonitor {
    if (_presentationEventMonitor) return;
    __weak ShenzhenMacDelegate* weakSelf = self;
    NSEventMask mask = NSEventMaskKeyDown;
    if (!_presentationEventMonitor) {
        _presentationEventMonitor =
            [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                                  handler:^NSEvent*(NSEvent* event) {
                                                    ShenzhenMacDelegate* strongSelf = weakSelf;
                                                    if (!strongSelf || !strongSelf->_presentationMode ||
                                                        ![strongSelf hasActiveDocument])
                                                        return event;
                                                    if (event.window && event.window != strongSelf->_window)
                                                        return event;

                                                    if ([strongSelf handlePresentationEvent:event]) return nil;

                                                    return event;
                                                  }];
    }
}

- (void)removePresentationEventMonitor {
    if (_presentationEventMonitor) {
        [NSEvent removeMonitor:_presentationEventMonitor];
        _presentationEventMonitor = nil;
    }
    if (_presentationGlobalEventMonitor) {
        [NSEvent removeMonitor:_presentationGlobalEventMonitor];
        _presentationGlobalEventMonitor = nil;
    }
}

- (void)beginPresentationSleepActivityIfNeeded {
    if (_presentationSleepActivityToken) return;
    NSActivityOptions options =
        NSActivityIdleSystemSleepDisabled | NSActivityIdleDisplaySleepDisabled | NSActivityUserInitiated;
    _presentationSleepActivityToken =
        [[NSProcessInfo processInfo] beginActivityWithOptions:options reason:@"ShenzhenPDF presentation mode"];
}

- (void)endPresentationSleepActivity {
    if (!_presentationSleepActivityToken) return;
    [[NSProcessInfo processInfo] endActivity:_presentationSleepActivityToken];
    _presentationSleepActivityToken = nil;
}

- (void)enterPresentationMode:(id)sender {
    if (![self hasActiveDocument] || _presentationMode) return;

    BOOL markdown = [self isMarkdownActive];
    [self stopKeyboardScrollAnimation];
    [self rememberCurrentZoomForCustomReturn];
    [self rememberViewForPresentation];
    _presentationPreviousFitMode = _fitMode;
    _presentationPreviousSidebarPreferredVisible = _sidebarPreferredVisible;
    _presentationPreviousMinimapPreferredVisible = _minimapPreferredVisible;
    _presentationEnteredFullScreen = NO;
    _presentationMode = YES;
    _lastPresentationEventTimestamp = 0;
    _lastPresentationEventType = (NSEventType)0;
    _lastPresentationEventKeyCode = -1;
    _lastPresentationEventButtonNumber = -1;

    [self enterPresentationWindowChrome];
    _sidebarPreferredVisible = NO;
    _minimapPreferredVisible = NO;
    _fitMode = SPDFFitModePage;
    if (!markdown) _pageView.currentPageIndex = _pageIndex;
    [self applyPresentationChrome];
    if (markdown) [self.activeMarkdownSession applyFitMode:SPDFMacMarkdownPageFitPage];
    [self rebuildSidebar];
    [self setMinimapActuallyVisible:NO];
    [self setSidebarPaneHiddenForPresentation:YES];
    [self installPresentationEventMonitor];
    [NSApp activateIgnoringOtherApps:YES];
    [_window orderFrontRegardless];
    [_window makeKeyWindow];
    [_window makeMainWindow];
    [_window
        makeFirstResponder:_presentationOverlayView ?: (markdown ? self.activeMarkdownSession.rootView : _pageView)];
    if (markdown)
        [self.activeMarkdownSession goToPageAtIndex:_pageIndex];
    else
        [self renderDocumentAndScrollToPage:_pageIndex alignTop:YES];
    if (_preventSleepInPresentation) [self beginPresentationSleepActivityIfNeeded];
}

- (void)leavePresentationModeAndExitFullScreen:(BOOL)exitFullScreen sender:(id)sender {
    if (!_presentationMode) return;
    [self endPresentationSleepActivity];

    BOOL markdown = [self isMarkdownActive];
    NSInteger presentedPage = _pageIndex;
    BOOL shouldExitFullScreen = exitFullScreen && _presentationEnteredFullScreen && [self windowIsFullScreen];
    _presentationMode = NO;
    _presentationEnteredFullScreen = NO;
    [self removePresentationEventMonitor];
    _sidebarPreferredVisible = _presentationPreviousSidebarPreferredVisible;
    _minimapPreferredVisible = _presentationPreviousMinimapPreferredVisible;
    _fitMode = _presentationPreviousFitMode;
    if (!markdown) _pageView.currentPageIndex = _pageIndex;
    [self setSidebarPaneHiddenForPresentation:NO];
    [self applyPresentationChrome];
    [self restorePresentationWindowChrome];
    [self rebuildSidebar];
    [self setMinimapActuallyVisible:_minimapPreferredVisible];
    // The chrome changes above scroll the one-page layout as if it were the
    // reader's and would read the first page off it.
    if (!markdown) _pageIndex = presentedPage;
    // Back to the zoom and place the reader had before, whatever was zoomed or
    // panned while presenting; a page changed while presenting opens at its top.
    if ([self restoreViewAfterPresentation]) {
        // Restored.
    } else if (markdown) {
        [self markdownApplyFitMode:_presentationPreviousFitMode];
        [self.activeMarkdownSession goToPageAtIndex:_pageIndex];
    } else if (_doc) {
        [self renderDocumentAndScrollToPage:_pageIndex alignTop:YES];
    }
    [self persistActiveState];
    if (shouldExitFullScreen) [_window toggleFullScreen:sender];
}

// The collapsed sidebar pane keeps a one-point divider beside the document; hidden, the split view drops it
// (splitView:shouldHideDividerAtIndex:) and a zoomed page reaches the screen's edge.
- (void)setSidebarPaneHiddenForPresentation:(BOOL)hidden {
    if (!_sidebarContainer || _sidebarContainer.hidden == hidden || (hidden && _sidebarVisible)) return;
    _sidebarContainer.hidden = hidden;
    [_splitView adjustSubviews];
}

- (void)togglePresentation:(id)sender {
    if (_presentationMode)
        [self leavePresentationModeAndExitFullScreen:YES sender:sender];
    else
        [self enterPresentationMode:sender];
}

@end
