#import "SPDFMacWindowPlacement.h"

NSRect spdf_window_content_rect_for_saved_frame(NSRect frame) {
    static const NSWindowStyleMask mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                          NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    return [NSWindow contentRectForFrameRect:frame styleMask:mask];
}

// The frame the reader left, and whether the window is currently sitting
// somewhere else because that frame's display was missing at launch. One
// document window per process, so this state belongs here.
static NSRect gSPDFDesiredFrame;
static BOOL gSPDFHasDesiredFrame;
static BOOL gSPDFShowingFallbackFrame;

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

// The reader moved or resized the window, so what is on screen is now their
// choice and supersedes whatever was remembered.
static void spdf_window_note_user_placed(NSNotification* note) {
    (void)note;
    gSPDFShowingFallbackFrame = NO;
}

// A display arrived (or the arrangement changed). If the window is still parked
// at a fallback and the remembered frame is reachable again, put it back.
static void spdf_window_screens_changed(NSNotification* note) {
    NSWindow* window = (NSWindow*)note.object;
    if (![window isKindOfClass:NSWindow.class]) return;
    if (!gSPDFHasDesiredFrame || !gSPDFShowingFallbackFrame) return;
    if (!spdf_window_frame_is_usable_on_screens(gSPDFDesiredFrame, spdf_window_screen_visible_frames())) return;
    [window setFrame:gSPDFDesiredFrame display:YES];
    gSPDFShowingFallbackFrame = NO;
}

NSRect spdf_window_frame_to_persist(NSWindow* window, NSRect liveFrame) {
    (void)window;
    // Still parked at a fallback: keep the reader's frame, not our stand-in.
    if (gSPDFHasDesiredFrame && gSPDFShowingFallbackFrame) return gSPDFDesiredFrame;
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
    if (!hasSavedFrame) return;
    gSPDFDesiredFrame = savedFrame;
    gSPDFHasDesiredFrame = YES;
    // Usable where it is? Then it is not a fallback, whatever screen it is on.
    NSRect display = savedFrame;
    if (!spdf_window_frame_is_usable_on_screens(savedFrame, spdf_window_screen_visible_frames())) {
        display = spdf_window_fallback_frame(savedFrame);
        gSPDFShowingFallbackFrame = !NSEqualRects(display, savedFrame);
    }
    [window setFrame:display display:NO];
    // Recover the remembered frame if its display shows up later, and stop
    // treating the frame as a fallback the moment the reader places the window.
    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:NSApplicationDidChangeScreenParametersNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification* note) {
                      (void)note;
                      spdf_window_screens_changed(
                          [NSNotification notificationWithName:@"screens" object:window]);
                    }];
    [center addObserverForName:NSWindowDidMoveNotification object:window queue:nil usingBlock:^(NSNotification* n) {
      spdf_window_note_user_placed(n);
    }];
    [center addObserverForName:NSWindowDidResizeNotification object:window queue:nil usingBlock:^(NSNotification* n) {
      spdf_window_note_user_placed(n);
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
