#import "SPDFMacWindowPlacement.h"

static const NSWindowStyleMask kSPDFDocumentWindowStyle = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                          NSWindowStyleMaskMiniaturizable |
                                                          NSWindowStyleMaskResizable;

NSRect spdf_window_content_rect_for_saved_frame(NSRect frame) {
    return [NSWindow contentRectForFrameRect:frame styleMask:kSPDFDocumentWindowStyle];
}

NSScreen* spdf_window_screen_for_frame(NSRect frame) {
    NSScreen* best = nil;
    CGFloat bestArea = 0.0;
    for (NSScreen* screen in NSScreen.screens) {
        NSRect overlap = NSIntersectionRect(frame, screen.frame);
        if (NSWidth(overlap) * NSHeight(overlap) > bestArea) {
            bestArea = NSWidth(overlap) * NSHeight(overlap);
            best = screen;
        }
    }
    return best ?: NSScreen.mainScreen ?: NSScreen.screens.firstObject;
}

NSWindow* spdf_window_create_document_window(Class windowClass, NSRect frame) {
    NSScreen* screen = spdf_window_screen_for_frame(frame);
    NSRect content = spdf_window_content_rect_for_saved_frame(frame);
    // With a screen, the content rect is given from that screen's origin.
    if (screen) content = NSOffsetRect(content, -NSMinX(screen.frame), -NSMinY(screen.frame));
    return [[windowClass alloc] initWithContentRect:content
                                          styleMask:kSPDFDocumentWindowStyle
                                            backing:NSBackingStoreBuffered
                                              defer:NO
                                             screen:screen];
}

// The frame the reader left, and whether the window is sitting somewhere else
// for a reason that is not theirs (see the header). One document window per
// process, so this state belongs here.
static NSRect gSPDFDesiredFrame;
static BOOL gSPDFHasDesiredFrame;
static BOOL gSPDFDisplaced;
// Until when a move nobody asked for during the launch is undone, and how many
// times it may be: a safety net only, the window is created on its own display
// (spdf_window_create_document_window) and the launch does not move it.
static CFAbsoluteTime gSPDFLaunchGuardUntil;
static NSUInteger gSPDFLaunchPutBacks;
static const NSUInteger kSPDFMaximumLaunchPutBacks = 4;
// The frame before native full screen: a full-screen window's frame is its
// display's, which is not where the reader left the window.
static NSRect gSPDFFrameBeforeFullScreen;
static BOOL gSPDFFullScreenTransition;

// The smallest overlap worth calling "on screen": a sliver is not reachable.
static const CGFloat kSPDFMinimumVisibleArea = 80.0 * 80.0;

BOOL spdf_window_frame_is_usable_on_screens(NSRect frame, NSArray<NSValue*>* visibleFrames) {
    for (NSValue* value in visibleFrames) {
        NSRect intersection = NSIntersectionRect(frame, value.rectValue);
        if (NSWidth(intersection) * NSHeight(intersection) >= kSPDFMinimumVisibleArea) return YES;
    }
    return NO;
}

// Where to park a window whose own display is not attached: centred on the
// main screen, at no more than that screen's size. Centred rather than clamped
// into a corner, which is what produced a window pinned at the screen's exact
// visible frame.
static NSRect spdf_window_fallback_frame(NSRect desired) {
    NSScreen* screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect visible = screen.visibleFrame;
    NSSize size = NSMakeSize(MIN(NSWidth(desired), NSWidth(visible)), MIN(NSHeight(desired), NSHeight(visible)));
    return NSMakeRect(floor(NSMidX(visible) - size.width / 2.0), floor(NSMidY(visible) - size.height / 2.0),
                      size.width, size.height);
}

static NSArray<NSValue*>* spdf_window_screen_visible_frames(void) {
    NSMutableArray<NSValue*>* frames = [NSMutableArray array];
    for (NSScreen* screen in NSScreen.screens) [frames addObject:[NSValue valueWithRect:screen.visibleFrame]];
    return frames;
}

static BOOL spdf_window_desired_frame_is_reachable(void) {
    return gSPDFHasDesiredFrame &&
           spdf_window_frame_is_usable_on_screens(gSPDFDesiredFrame, spdf_window_screen_visible_frames());
}

BOOL spdf_window_event_is_the_readers(NSEvent* event, BOOL mouseButtonDown) {
    if (mouseButtonDown) return YES; // a drag of the title bar or an edge, wherever the event stream is
    static const NSEventMask readerInput =
        NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDown |
        NSEventMaskRightMouseUp | NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp | NSEventMaskKeyDown |
        NSEventMaskKeyUp | NSEventMaskFlagsChanged | NSEventMaskMagnify | NSEventMaskSwipe | NSEventMaskRotate |
        NSEventMaskSmartMagnify;
    return event && (NSEventMaskFromType(event.type) & readerInput) != 0;
}

static void spdf_window_put_back(NSWindow* window) {
    gSPDFDisplaced = NO;
    [window setFrame:gSPDFDesiredFrame display:YES];
}

// When the displays last changed, and when a move nobody asked for was last
// taken as the frame to remember (with the frame it replaced): a window moved
// off a vanishing display can be reported before the screen list says so.
static CFAbsoluteTime gSPDFScreensChangedAt, gSPDFSystemFrameTakenAt;
static NSRect gSPDFFrameBeforeSystemMove;

static void spdf_window_remember(NSRect frame, id reader) {
    gSPDFDesiredFrame = frame;
    gSPDFHasDesiredFrame = YES;
    gSPDFDisplaced = NO;
    SEL write = @selector(writeSessionStateForCurrentWindow);
    if (![reader respondsToSelector:write]) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:reader selector:write object:nil];
    [reader performSelector:write withObject:nil afterDelay:0.5];
}

// The window moved or changed size. The reader's own change (a drag, an edge,
// a menu command or shortcut) becomes the frame to remember, and is written
// soon, so no later quit, crash or update can lose it. A change nobody asked
// for is the system's: a move in the first seconds of a launch (put back), or
// a move off a display that went away (shown there, remembered here). A move
// by a window manager while the remembered frame is still reachable and the
// displays did not change is taken as the reader's.
static void spdf_window_frame_changed(NSWindow* window, id reader) {
    if (gSPDFFullScreenTransition || (window.styleMask & NSWindowStyleMaskFullScreen)) return;
    NSRect frame = window.frame;
    if (gSPDFHasDesiredFrame && NSEqualRects(frame, gSPDFDesiredFrame)) {
        gSPDFDisplaced = NO;
        return;
    }
    if (window.inLiveResize || spdf_window_event_is_the_readers(NSApp.currentEvent, NSEvent.pressedMouseButtons != 0)) {
        gSPDFLaunchGuardUntil = 0;
        spdf_window_remember(frame, reader);
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL reachable = spdf_window_desired_frame_is_reachable();
    if (reachable && now < gSPDFLaunchGuardUntil && gSPDFLaunchPutBacks < kSPDFMaximumLaunchPutBacks) {
        gSPDFLaunchPutBacks++;
        gSPDFDisplaced = YES;
        // After AppKit has finished the move it is reporting.
        dispatch_async(dispatch_get_main_queue(), ^{
          if (gSPDFDisplaced && !NSEqualRects(window.frame, gSPDFDesiredFrame)) spdf_window_put_back(window);
        });
        return;
    }
    if (!gSPDFHasDesiredFrame || (reachable && !gSPDFDisplaced && now - gSPDFScreensChangedAt > 2.0)) {
        gSPDFFrameBeforeSystemMove = gSPDFHasDesiredFrame ? gSPDFDesiredFrame : frame;
        gSPDFSystemFrameTakenAt = now;
        spdf_window_remember(frame, reader);
        return;
    }
    gSPDFDisplaced = YES; // its display is gone, or the displays are changing: show it here, remember it there
}

// The displays' frames: the Dock or the menu bar changing size changes visible
// frames only, which is not a display coming or going.
static NSString* spdf_window_display_arrangement(void) {
    NSMutableArray<NSString*>* frames = [NSMutableArray array];
    for (NSScreen* screen in NSScreen.screens) [frames addObject:NSStringFromRect(screen.frame)];
    return [frames componentsJoinedByString:@";"];
}

// The screens changed. If displays came or went just after a move nobody asked
// for was taken as the reader's, that move was this change arriving early:
// undo it. Then, if the window is away from the frame the reader left and that
// frame is reachable again, put it back.
static void spdf_window_screens_changed(NSWindow* window) {
    static NSString* arrangement;
    NSString* current = spdf_window_display_arrangement();
    BOOL displaysChanged = arrangement && ![arrangement isEqualToString:current];
    arrangement = current;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (displaysChanged) gSPDFScreensChangedAt = now;
    if (displaysChanged && now - gSPDFSystemFrameTakenAt < 1.5) {
        gSPDFDesiredFrame = gSPDFFrameBeforeSystemMove;
        gSPDFSystemFrameTakenAt = 0;
        gSPDFDisplaced = !NSEqualRects(window.frame, gSPDFDesiredFrame);
    }
    if (!gSPDFHasDesiredFrame || !gSPDFDisplaced || !spdf_window_desired_frame_is_reachable()) return;
    spdf_window_put_back(window);
}

NSRect spdf_window_frame_to_persist(NSWindow* window, NSRect liveFrame) {
    // In native full screen: the frame it will come back to.
    if (window && (window.styleMask & NSWindowStyleMaskFullScreen) && !NSIsEmptyRect(gSPDFFrameBeforeFullScreen))
        return gSPDFDisplaced && gSPDFHasDesiredFrame ? gSPDFDesiredFrame : gSPDFFrameBeforeFullScreen;
    // Away from where the reader left it, not by their doing: keep their frame.
    if (gSPDFHasDesiredFrame && gSPDFDisplaced) return gSPDFDesiredFrame;
    return liveFrame;
}

void spdf_window_configure_document_window(NSWindow* window, id reader, NSSize minimumSize, NSRect savedFrame,
                                           BOOL hasSavedFrame) {
    if (!window) return;
    // Set through KVC rather than importing SPDFWindow: this file is linked on
    // its own by the placement test, and the reader is the only thing it would
    // need that header for.
    if ([window respondsToSelector:@selector(setReader:)]) [window setValue:reader forKey:@"reader"];
    window.delegate = reader;
    window.title = @"Shenzhen PDF";
    window.minSize = minimumSize;
    gSPDFDesiredFrame = hasSavedFrame ? savedFrame : window.frame;
    gSPDFHasDesiredFrame = YES;
    gSPDFDisplaced = NO;
    gSPDFLaunchPutBacks = 0;
    gSPDFLaunchGuardUntil = CFAbsoluteTimeGetCurrent() + 5.0;
    spdf_window_screens_changed(window); // records the displays as they are now
    if (hasSavedFrame) {
        // Usable where it is? Then it is not a fallback, whatever screen it is on.
        NSRect display = savedFrame;
        if (!spdf_window_frame_is_usable_on_screens(savedFrame, spdf_window_screen_visible_frames())) {
            display = spdf_window_fallback_frame(savedFrame);
            gSPDFDisplaced = !NSEqualRects(display, savedFrame);
        } else {
            // Where AppKit lets it be: shown, a window whose top is above its display's menu bar (left across two
            // displays, mostly on the lower one) is moved down under it. Put there before it is shown, and taken as
            // the frame to remember: put back, it was moved down again, four times in a row. Asked as AppKit asks
            // when it shows the window: at that frame, with no screen named.
            [window setFrame:savedFrame display:NO];
            display = [window constrainFrameRect:savedFrame toScreen:nil];
            gSPDFDesiredFrame = display;
        }
        [window setFrame:display display:NO];
    }
    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    __weak NSWindow* weakWindow = window;
    __weak id weakReader = reader;
    void (^changed)(NSNotification*) = ^(NSNotification* note) {
      (void)note;
      if (weakWindow) spdf_window_frame_changed(weakWindow, weakReader);
    };
    [center addObserverForName:NSWindowDidMoveNotification object:window queue:nil usingBlock:changed];
    [center addObserverForName:NSWindowDidResizeNotification object:window queue:nil usingBlock:changed];
    [center addObserverForName:NSApplicationDidChangeScreenParametersNotification object:nil queue:nil
                    usingBlock:^(NSNotification* note) {
                      (void)note;
                      if (weakWindow) spdf_window_screens_changed(weakWindow);
                    }];
    // The first activation is when macOS may still move a just-launched window:
    // the guard covers it when it comes late (a launch behind, brought forward).
    __block BOOL activated = NO;
    [center addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:nil
                    usingBlock:^(NSNotification* note) {
                      (void)note;
                      if (activated) return;
                      activated = YES;
                      if (gSPDFLaunchGuardUntil > 0)
                          gSPDFLaunchGuardUntil = MAX(gSPDFLaunchGuardUntil, CFAbsoluteTimeGetCurrent() + 2.0);
                    }];
    [center addObserverForName:NSWindowWillEnterFullScreenNotification object:window queue:nil
                    usingBlock:^(NSNotification* note) {
                      gSPDFFullScreenTransition = YES;
                      gSPDFFrameBeforeFullScreen = ((NSWindow*)note.object).frame;
                    }];
    [center addObserverForName:NSWindowDidEnterFullScreenNotification object:window queue:nil
                    usingBlock:^(NSNotification* note) {
                      (void)note;
                      gSPDFFullScreenTransition = NO;
                    }];
    [center addObserverForName:NSWindowWillExitFullScreenNotification object:window queue:nil
                    usingBlock:^(NSNotification* note) {
                      (void)note;
                      gSPDFFullScreenTransition = YES;
                    }];
    [center addObserverForName:NSWindowDidExitFullScreenNotification object:window queue:nil
                    usingBlock:^(NSNotification* note) {
                      (void)note;
                      gSPDFFullScreenTransition = NO;
                      gSPDFFrameBeforeFullScreen = NSZeroRect;
                    }];
}

void spdf_spawn_restored_window_processes(NSArray<NSString*>* windowIDs, NSString* skipWindowID) {
    if (windowIDs.count == 0) return; // the common single-window launch, off in one branch
    NSString* executable = NSBundle.mainBundle.executablePath ?: NSProcessInfo.processInfo.arguments.firstObject;
    if (executable.length == 0) return;
    NSArray<NSString*>* ids = [windowIDs copy];
    NSString* skip = [skipWindowID copy];
    // posix_spawn plus the child's own dyld work has no business on the main
    // thread of a launch that is still assembling its first frame.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      for (NSString* windowID in ids) {
          if (windowID.length == 0 || [windowID isEqualToString:skip]) continue;
          NSTask* task = [[NSTask alloc] init];
          task.executableURL = [NSURL fileURLWithPath:executable];
          task.arguments = @[ @"--restore-window", windowID ];
          task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
          task.standardError = [NSFileHandle fileHandleWithNullDevice];
          [task launchAndReturnError:nil];
      }
    });
}
