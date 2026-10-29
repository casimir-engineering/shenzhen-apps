// Quitting hides first, then finishes. Measured on a profile of 100 restored tabs in groups with a 300-document
// Collection (mac/tests/launch/run-quit-performance.py), the window used to stay on screen for about 350 ms after
// Cmd+Q or the close button: the session, settings, documents and bookmarks writes, then AppKit's own terminate, which
// waits about 300 ms in CFPasteboardResolveAllPromisedData even when this process promised the pasteboard nothing.
// Now the windows leave the screen before anything else runs, and the process finishes out of sight:
//
//   applicationShouldTerminate   hide every window, pass the focus on, quit the sibling windows' processes, and
//                                answer NSTerminateLater, so the run loop keeps taking Apple events
//   next run-loop pass           wait for an image copy still being written (Save As of a pasted image), then the
//                                writes and cleanup of applicationWillTerminate, then SPDFMacQuitWillExitNotification
//   exit                         at once -- unless this process last wrote the general pasteboard, which may hold
//                                data AppKit resolves only on its own terminate; then AppKit's path, out of sight
//
// A Dock click or a document opened while the process finishes reaches this process, not a new one: Launch Services
// sees it still running. It is answered with a fresh launch once the writes are done, so the new process reads exactly
// what this one saved; nothing is reopened halfway through a teardown.
#import "SPDFMacQuitFinishing.h"
#import "SPDFMacImageSaveIntegration.h"
#import "SPDFMacSupport.h"
#import "SPDFMacLifecycleSignposts.h"
#import "SPDFMacPasteboardOwnership.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

NSNotificationName const SPDFMacQuitWillExitNotification = @"SPDFMacQuitWillExitNotification";

// ---- after the first paint ------------------------------------------------------------------------------------
// Collection's capture of the restored tab read its 430 KB manifest and settings on the main thread before the first
// frame (about 20 ms on the 100-tab profile); it waits for the frame now. Outside a launch (tests that build a reader
// without one) a block simply runs on the next main-queue pass.
static NSMutableArray<dispatch_block_t>* gAfterFirstPaint;
static BOOL gLaunching, gFirstPaintDone;
static void InstallQuitKeyMonitor(void);
void spdf_mac_launch_began(void) {
    gLaunching = YES;
    SPDF_LIFECYCLE_EVENT("DidFinishLaunching");
    InstallQuitKeyMonitor();
    spdf_launch_profile_log(@"applicationDidFinishLaunching enter");
}
void spdf_mac_after_first_paint(dispatch_block_t block) {
    if (!block) return;
    if (!gLaunching || gFirstPaintDone) {
        dispatch_async(dispatch_get_main_queue(), block);
        return;
    }
    if (!gAfterFirstPaint) gAfterFirstPaint = [NSMutableArray array];
    [gAfterFirstPaint addObject:[block copy]];
}
void spdf_mac_first_paint_done(void) {
    if (gFirstPaintDone) return;
    gFirstPaintDone = YES;
    SPDF_LIFECYCLE_END("Launch");
    NSArray<dispatch_block_t>* blocks = gAfterFirstPaint;
    gAfterFirstPaint = nil;
    for (dispatch_block_t block in blocks) block();
}

// ---- Cmd+Q ------------------------------------------------------------------------------------------------------------
// A menu key equivalent first highlights its menu title, and that highlight commits a Core Animation transaction which
// draws whatever the window has pending: right after an edit (a comment, a rotation) that took about 20 ms before
// applicationShouldTerminate was even asked. Seeing Cmd+Q as it is dequeued hides the windows before that draw; the
// event then goes on to the menu as usual. Only when the Quit item would act: no modal session, no sheet, item enabled.
@interface ShenzhenMacDelegate (SPDFMacQuitKey)
- (void)hideWindowsForQuitKey;
@end
static void InstallQuitKeyMonitor(void) {
    static id monitor;
    if (monitor) return;
    monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent* event) {
        NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        if ((flags & ~NSEventModifierFlagCapsLock) != NSEventModifierFlagCommand || NSApp.modalWindow ||
            NSApp.keyWindow.attachedSheet)
            return event;
        NSMenu* menu = NSApp.mainMenu.itemArray.firstObject.submenu; // the application menu
        NSInteger index = [menu indexOfItemWithTarget:nil andAction:@selector(terminate:)];
        NSMenuItem* quit = index >= 0 ? [menu itemAtIndex:index] : nil;
        if (!quit.enabled || quit.keyEquivalentModifierMask != NSEventModifierFlagCommand ||
            ![event.charactersIgnoringModifiers isEqualToString:quit.keyEquivalent])
            return event;
        id reader = NSApp.delegate;
        if ([reader isKindOfClass:ShenzhenMacDelegate.class]) [(ShenzhenMacDelegate*)reader hideWindowsForQuitKey];
        return event;
    }];
}

// ---- quitting -----------------------------------------------------------------------------------------------------
@interface SPDFMacQuitState : NSObject
@property(nonatomic) BOOL hidden, finishing, finalWritesDone, relaunch;
@property(nonatomic) NSUInteger imageCopyWaits;
@end
@implementation SPDFMacQuitState
@end
static char kQuitStateKey;

@implementation ShenzhenMacDelegate (SPDFMacQuitFinishing)

- (SPDFMacQuitState*)quitState {
    SPDFMacQuitState* state = objc_getAssociatedObject(self, &kQuitStateKey);
    if (!state) {
        state = [SPDFMacQuitState new];
        objc_setAssociatedObject(self, &kQuitStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

- (void)hideWindowsForQuit {
    SPDFMacQuitState* state = [self quitState];
    if (state.hidden) return;
    state.hidden = YES;
    SPDF_LIFECYCLE_BEGIN("Quit");
    [self dismissTabHoverPanel];
    // The document window first: it is what the person looks at. Panels, sheets and the AI chat window follow.
    [_window orderOut:nil];
    for (NSWindow* window in NSApp.windows)
        if (window.visible) [window orderOut:nil];
    // Push the ordering to the window server now, not at the end of this run-loop pass.
    [CATransaction flush];
    SPDF_LIFECYCLE_EVENT("WindowsHidden");
    // The focus moves to the app behind, as when the process has ended. Not for a window closing alone (its last tab
    // closed while other windows stay open, each its own process): the focus belongs to one of those, which the system
    // picks when this process ends; hiding would hand it to whatever app is next instead.
    if (!_terminateOnlyThisProcess) [NSApp hide:nil];
    // From here a document opened from the Finder or the Dock is only noted, as during a launch before the window
    // exists (application:openFiles:), and handed to the fresh launch that follows this quit.
    _uiReady = NO;
    _pendingOpenPath = nil;
    [_pendingOpenPaths removeAllObjects];
}

- (void)hideWindowsForQuitKey {
    if ([self quitState].hidden) return;
    [self hideWindowsForQuit];
    // Should something take the key on its way to the menu, the quit never starts: give the windows back. A started
    // quit runs its run loop in NSModalPanelRunLoopMode, where this block does not run.
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ShenzhenMacDelegate* reader = weakSelf;
        SPDFMacQuitState* state = reader ? [reader quitState] : nil;
        if (!state.hidden || state.finishing) return;
        state.hidden = NO;
        reader->_uiReady = YES;
        [NSApp unhide:nil];
        [reader->_window makeKeyAndOrderFront:nil];
    });
}

- (BOOL)beginQuit {
    SPDFMacQuitState* state = [self quitState];
    if (state.finishing) return NO;
    state.finishing = YES;
    [self hideWindowsForQuit];
    return YES;
}

- (NSApplicationTerminateReply)finishQuitAfterHiding {
    // NSTerminateLater keeps the run loop going in NSModalPanelRunLoopMode, where Apple events (a Dock click) are still
    // delivered; a main-queue block would not run there.
    [self performSelector:@selector(quitFinishWhenImageCopyWritten) withObject:nil afterDelay:0
                  inModes:@[ NSModalPanelRunLoopMode, NSDefaultRunLoopMode ]];
    return NSTerminateLater;
}

- (void)quitFinishWhenImageCopyWritten {
    // An image copy being written to the place the person chose (Save As of a pasted image) finishes first. Its
    // completion comes back on the main queue, which the terminate-later run loop mode does not serve: let the default
    // mode run briefly so it can, for up to 30 s.
    SPDFMacQuitState* state = [self quitState];
    if ([self waitForPendingImageSave:nil] && state.imageCopyWaits++ < 600) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        [self performSelector:@selector(quitFinishWhenImageCopyWritten) withObject:nil afterDelay:0
                      inModes:@[ NSModalPanelRunLoopMode, NSDefaultRunLoopMode ]];
        return;
    }
    [self quitFinish];
}

- (void)quitFinish {
    if (spdf_mac_general_pasteboard_may_hold_our_data()) {
        // AppKit resolves what this process promised the pasteboard, then calls applicationWillTerminate and exits.
        [NSApp replyToApplicationShouldTerminate:YES];
        return;
    }
    [self applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification
                                                                 object:NSApp]];
    exit(0);
}

- (BOOL)quitClaimFinalWrites {
    SPDFMacQuitState* state = [self quitState];
    if (state.finalWritesDone) return NO;
    state.finalWritesDone = YES;
    SPDF_LIFECYCLE_EVENT("QuitWrites");
    return YES;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)sender hasVisibleWindows:(BOOL)visible {
    (void)sender;
    SPDFMacQuitState* state = objc_getAssociatedObject(self, &kQuitStateKey);
    if (state.hidden) return state.relaunch = YES, NO;
    (void)visible;
    return YES; // not quitting: what AppKit does without this method
}

- (void)quitRelaunchIfRequested {
    SPDFMacQuitState* state = objc_getAssociatedObject(self, &kQuitStateKey);
    if (!state.finishing) return;
    [NSNotificationCenter.defaultCenter postNotificationName:SPDFMacQuitWillExitNotification object:self];
    SPDF_LIFECYCLE_END("Quit");
    // Apple events that arrived during the writes are still queued: take them now, without waiting for more. AppKit
    // handles an Apple event inside -nextEventMatchingMask:; input events for the hidden windows are dropped.
    for (int pass = 0; pass < 16; pass++)
        if (![NSApp nextEventMatchingMask:NSEventMaskAny untilDate:NSDate.distantPast inMode:NSModalPanelRunLoopMode
                                  dequeue:YES])
            break;
    NSMutableOrderedSet<NSString*>* paths = [NSMutableOrderedSet orderedSet];
    if (_pendingOpenPath.length) [paths addObject:_pendingOpenPath];
    for (NSString* path in _pendingOpenPaths) if (path.length) [paths addObject:path];
    if (!state.relaunch && !paths.count) return;
    NSWorkspaceOpenConfiguration* configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.createsNewApplicationInstance = YES;
    configuration.activates = YES;
    NSURL* app = NSBundle.mainBundle.bundleURL;
    dispatch_semaphore_t launched = dispatch_semaphore_create(0);
    void (^done)(NSRunningApplication*, NSError*) = ^(NSRunningApplication* running, NSError* error) {
        (void)running, (void)error;
        dispatch_semaphore_signal(launched);
    };
    NSMutableArray<NSURL*>* urls = [NSMutableArray array];
    for (NSString* path in paths) [urls addObject:[NSURL fileURLWithPath:path]];
    if (urls.count)
        [NSWorkspace.sharedWorkspace openURLs:urls withApplicationAtURL:app configuration:configuration
                            completionHandler:done];
    else
        [NSWorkspace.sharedWorkspace openApplicationAtURL:app configuration:configuration completionHandler:done];
    // Launch Services answers on its own queue once the new process runs; this one must outlive the request.
    dispatch_semaphore_wait(launched, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
}

@end
