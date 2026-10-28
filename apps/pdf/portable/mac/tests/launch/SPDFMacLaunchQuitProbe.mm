// The launch probe's second half (SPDFMacLaunchPerformanceProbe.mm inserts both): what a person waits for at either end
// of a session, timed against the reader's real code with nothing on screen.
//
// Launch, relative to the kernel's spawn time:
//   first_page_ms   the selected tab's current page has pixels to show (any resolution: what the window draws)
//   sharp_page_ms   ... at the zoom the window shows it (renderedPageImage:matchesZoom:displayScale:)
//   interactive_ms  first frame drawn and first page shown, and the main thread answered a ping within 16 ms
//   max_stall_ms    the longest the main thread kept a ping waiting in the 2 s after the first frame
// Quit (PROBE_MODE=quit-cmdq | quit-close | quit-lasttab), after the launch settled, relative to the trigger:
//   hidden_ms       the window left the screen (orderOut, close) -- or the process ended, whichever came first
//   exit_ms         exit() began (atexit); the harness adds when the process was gone (reaped_ms)
//   modals          alerts the quit ran (none may: every change is already saved)
// quit-integrity runs a quit-and-relaunch round's checks and edits (SPDFMacLaunchIntegrityProbe.mm), then quits.
// quit-cmdq presses Cmd+Q, quit-close clicks the window's close button, quit-lasttab closes every tab
// with the File menu's Close (Cmd+W) in a window that has another window beside it, which closes only that window.
// PROBE_REOPEN=<ms> sends the reader a reopen Apple event that long after the trigger, as a Dock click while it is
// finishing does: relaunch_requested reports that it asked Launch Services for a fresh launch (never started here).

#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <pthread.h>
#include <unistd.h>

void SPDFProbeFinish(NSDictionary* extra);
void SPDFProbeRunIntegrityRound(id reader); // SPDFMacLaunchIntegrityProbe.mm
static double gSpawn, gFrame = -1, gFirstPage = -1, gSharpPage = -1, gInteractive = -1, gMaxStall = 0;
static double gQuit = -1, gHidden = -1, gExit = -1, gModalAt = -1;
static int gModals, gModalsWhileShown;
static BOOL gShown = YES; // the reader's window, as far as the reader asked: refused on screen, never ordered out yet
static id gReader;
static NSMutableDictionary* gQuitExtra;

static double Now(void) { return CFAbsoluteTimeGetCurrent() * 1000.0; }
static id IvarObject(id object, const char* name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}
static NSInteger IvarInteger(id object, const char* name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? *(NSInteger*)((uint8_t*)(__bridge void*)object + ivar_getOffset(ivar)) : -1;
}
static CGFloat IvarFloat(id object, const char* name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? *(CGFloat*)((uint8_t*)(__bridge void*)object + ivar_getOffset(ivar)) : 0;
}
static NSWindow* ReaderWindow(void) { return gReader ? IvarObject(gReader, "_window") : nil; }

// The current page of the selected tab: drawn at all, and drawn at its zoom.
static void CheckFirstPage(void) {
    if (gSharpPage >= 0 || !gReader) return;
    NSArray* pages = IvarObject(gReader, "_renderedPages");
    NSInteger index = IvarInteger(gReader, "_pageIndex");
    if (index < 0 || index >= (NSInteger)pages.count) return;
    id page = pages[(NSUInteger)index];
    if (![page respondsToSelector:@selector(image)]) return;
    BOOL shown = [page valueForKey:@"image"] || [page valueForKey:@"baseImage"];
    if (shown && gFirstPage < 0) gFirstPage = Now();
    SEL matches = NSSelectorFromString(@"renderedPageImage:matchesZoom:displayScale:");
    if (shown && [gReader respondsToSelector:matches] &&
        ((BOOL(*)(id, SEL, id, CGFloat, CGFloat))objc_msgSend)(gReader, matches, page, IvarFloat(gReader, "_zoom"), 2.0))
        gSharpPage = Now();
}

void SPDFProbeTrackLaunch(id reader, double spawnMs) {
    gReader = reader;
    gSpawn = spawnMs;
    CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(
        NULL, kCFRunLoopBeforeWaiting | kCFRunLoopAfterWaiting | kCFRunLoopBeforeSources, true, 0,
        ^(CFRunLoopObserverRef, CFRunLoopActivity) { CheckFirstPage(); });
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
}

// From the first frame: a ping every 4 ms on a background thread, answered by the main run loop in any mode.
static void* Pinger(void*) {
    double until = gFrame + 2000.0;
    while (Now() < until) {
        double sent = Now();
        __block volatile double answered = -1;
        CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{ answered = Now(); });
        CFRunLoopWakeUp(CFRunLoopGetMain());
        while (answered < 0 && Now() < until + 5000.0) usleep(500);
        double latency = answered - sent;
        if (latency > gMaxStall) gMaxStall = latency;
        if (gInteractive < 0 && gFirstPage >= 0 && sent >= gFirstPage && latency <= 16.0) gInteractive = answered;
        usleep(4000);
    }
    return NULL;
}

void SPDFProbeFrameDrawn(void) {
    gFrame = Now();
    CheckFirstPage();
    pthread_t thread;
    pthread_create(&thread, NULL, Pinger, NULL);
    pthread_detach(thread);
}

void SPDFProbeOrderedOut(NSWindow* window) {
    if (window != ReaderWindow() || !gShown) return;
    gShown = NO;
    if (gQuit >= 0 && gHidden < 0) gHidden = Now();
}

void SPDFProbeModal(id alert) {
    gModals++;
    // Which question, for the report: a quit or an edit must not ask any.
    if (!gQuitExtra) gQuitExtra = [NSMutableDictionary dictionary];
    NSString* text = [alert respondsToSelector:@selector(messageText)] ? [alert messageText] : @"?";
    gQuitExtra[@"modal_texts"] = [gQuitExtra[@"modal_texts"] ?: @[] arrayByAddingObject:text ?: @""];
    if (gShown) gModalsWhileShown++;
    if (gModalAt < 0) gModalAt = Now();
}

void SPDFProbeAddResults(NSMutableDictionary* out) {
    double frame = gFrame < 0 ? -1 : gFrame - gSpawn;
    out[@"first_page_ms"] = @(gFirstPage < 0 ? -1 : gFirstPage - gSpawn);
    out[@"sharp_page_ms"] = @(gSharpPage < 0 ? -1 : gSharpPage - gSpawn);
    out[@"interactive_ms"] = @(gInteractive < 0 ? -1 : MAX(gInteractive - gSpawn, frame));
    out[@"max_stall_ms"] = @(gMaxStall);
    out[@"tabs"] = @([IvarObject(gReader, "_tabs") count]);
    out[@"selected_tab"] = @(IvarInteger(gReader, "_selectedTabIndex"));
    out[@"page_index"] = @(IvarInteger(gReader, "_pageIndex"));
    if (gQuit < 0) return;
    out[@"quit_hidden_ms"] = @((gHidden < 0 ? (gExit < 0 ? Now() : gExit) : gHidden) - gQuit);
    out[@"quit_hidden_by_exit"] = @(gHidden < 0);
    out[@"quit_exit_ms"] = @(gExit < 0 ? -1 : gExit - gQuit);
    out[@"quit_at_abs_ms"] = @(gQuit);
    out[@"quit_modals"] = @(gModals);
    out[@"quit_modals_while_shown"] = @(gModalsWhileShown);
    [out addEntriesFromDictionary:gQuitExtra ?: @{}];
}

static void AtExit(void) {
    gExit = Now();
    SPDFProbeFinish(@{});
}

static NSMenuItem* MenuItem(NSMenu* menu, SEL action, NSString* key) {
    for (NSMenuItem* item in menu.itemArray) {
        if (item.action == action && (!key || [item.keyEquivalent isEqualToString:key])) return item;
        NSMenuItem* found = item.submenu ? MenuItem(item.submenu, action, key) : nil;
        if (found) return found;
    }
    return nil;
}
static void Perform(NSMenuItem* item) {
    if (!item) {
        fprintf(stderr, "quit probe: menu item not found\n");
        _exit(3);
    }
    [item.menu performActionForItemAtIndex:[item.menu indexOfItem:item]];
}

static BOOL YesOtherWindows(id, SEL) { return YES; }
// A quitting reader asked to reopen starts a fresh launch through Launch Services. A test instance must never start
// one (it would be an ordinary launch, on screen): the request is recorded and answered as launched.
static void RecordLaunch(id, SEL, NSURL* app, NSWorkspaceOpenConfiguration*, void (^done)(NSRunningApplication*, NSError*)) {
    gQuitExtra[@"relaunch_requested"] = @YES;
    gQuitExtra[@"relaunch_ms"] = @(Now() - gQuit);
    gQuitExtra[@"relaunch_app"] = app.path ?: @"";
    if (done) done(nil, nil);
}
static void RecordOpen(id, SEL, NSArray<NSURL*>* urls, NSURL* app, NSWorkspaceOpenConfiguration*,
                       void (^done)(NSRunningApplication*, NSError*)) {
    gQuitExtra[@"relaunch_requested"] = @YES;
    gQuitExtra[@"relaunch_documents"] = @(urls.count);
    gQuitExtra[@"relaunch_app"] = app.path ?: @"";
    if (done) done(nil, nil);
}
// The launch probe's run loop never dequeued AppKit's events: a person's Cmd+Q comes after them (window moved,
// backing scale), so they are handled first, as [NSApp run] would have.
static void DispatchEvents(NSTimeInterval quiet) {
    for (;;) {
        NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                            untilDate:[NSDate dateWithTimeIntervalSinceNow:quiet]
                                               inMode:NSDefaultRunLoopMode dequeue:YES];
        if (!event) return;
        [NSApp sendEvent:event];
    }
}
static IMP gShouldTerminate;
static NSApplicationTerminateReply TimedShouldTerminate(id reader, SEL sel, id app) {
    if (gQuit >= 0 && !gQuitExtra[@"should_terminate_ms"]) gQuitExtra[@"should_terminate_ms"] = @(Now() - gQuit);
    return ((NSApplicationTerminateReply(*)(id, SEL, id))gShouldTerminate)(reader, sel, app);
}

// Runs once the launch settled; returns NO for modes it does not own.
BOOL SPDFProbeRunQuitMode(const char* mode, id reader) {
    if (strncmp(mode, "quit-", 5) != 0) return NO;
    gReader = reader;
    if (!gQuitExtra) gQuitExtra = [NSMutableDictionary dictionary];
    atexit(AtExit);
    method_setImplementation(class_getInstanceMethod(NSWorkspace.class,
                                 @selector(openApplicationAtURL:configuration:completionHandler:)), (IMP)RecordLaunch);
    method_setImplementation(class_getInstanceMethod(NSWorkspace.class,
                                 @selector(openURLs:withApplicationAtURL:configuration:completionHandler:)), (IMP)RecordOpen);
    gShouldTerminate = method_setImplementation(
        class_getInstanceMethod(object_getClass(reader), @selector(applicationShouldTerminate:)), (IMP)TimedShouldTerminate);
    if (!strcmp(mode, "quit-lasttab")) {
        // Another window beside this one: closing the last tab closes this window only (closeTabAtIndex:).
        Class cls = object_getClass(reader);
        method_setImplementation(class_getInstanceMethod(cls, NSSelectorFromString(@"hasOtherShenzhenWindows")),
                                 (IMP)YesOtherWindows);
        NSMutableArray* tabs = IvarObject(reader, "_tabs");
        SEL close = NSSelectorFromString(@"closeTabAtIndex:");
        while (tabs.count > 1) ((void (*)(id, SEL, NSInteger))objc_msgSend)(reader, close, (NSInteger)tabs.count - 1);
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    }
    DispatchEvents(0.3);
    if (!strcmp(mode, "quit-integrity")) SPDFProbeRunIntegrityRound(reader);
    gQuit = Now();
    if (getenv("PROBE_REOPEN")) {
        // A Dock click while the reader finishes: Launch Services sends the running process a reopen Apple event. Sent
        // here from another thread, so it arrives through the main thread's event queue as Launch Services' does.
        double after = atof(getenv("PROBE_REOPEN"));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * NSEC_PER_MSEC)), dispatch_get_global_queue(0, 0), ^{
            NSAppleEventDescriptor* event = [NSAppleEventDescriptor
                appleEventWithEventClass:kCoreEventClass eventID:kAEReopenApplication
                        targetDescriptor:[NSAppleEventDescriptor descriptorWithProcessIdentifier:getpid()]
                                returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
            double sent = Now() - gQuit;
            OSStatus status = AESendMessage(event.aeDesc, NULL, kAENoReply | kAENeverInteract, kAEDefaultTimeout);
            CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
                gQuitExtra[@"reopen_sent_ms"] = @(sent);
                gQuitExtra[@"reopen_send_status"] = @(status);
            });
        });
    }
    // quit-integrity quits as PROBE_QUIT_HOW says: cmdq (default) or close.
    const char* how = getenv("PROBE_QUIT_HOW") ?: "cmdq";
    if (!strcmp(mode, "quit-integrity")) mode = !strcmp(how, "close") ? "quit-close" : "quit-cmdq";
    if (!strcmp(mode, "quit-cmdq")) {
        // Cmd+Q as the keyboard sends it: queued, dequeued by the run loop (local event monitors see it there), then
        // matched to the Quit item's key equivalent.
        if (!MenuItem(NSApp.mainMenu, @selector(terminate:), @"q")) Perform(nil);
        [NSApp postEvent:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                                     modifierFlags:NSEventModifierFlagCommand
                                         timestamp:NSProcessInfo.processInfo.systemUptime
                                      windowNumber:ReaderWindow().windowNumber context:nil characters:@"q"
                       charactersIgnoringModifiers:@"q" isARepeat:NO keyCode:12]
                 atStart:NO];
    }
    else if (!strcmp(mode, "quit-close"))
        [[ReaderWindow() standardWindowButton:NSWindowCloseButton] performClick:nil];
    else if (!strcmp(mode, "quit-lasttab"))
        Perform(MenuItem(NSApp.mainMenu, NSSelectorFromString(@"closeDocument:"), @"w"));
    else {
        fprintf(stderr, "quit probe: unknown mode %s\n", mode);
        _exit(3);
    }
    // The reader quits on its own from here; the probe only keeps the event loop going until it does.
    for (;;) DispatchEvents(3600);
}
