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
// finishing does, and no earlier than the finishing step (a timer on a busy machine could fire after the process had
// gone, a click that never happened while it was finishing): relaunch_requested reports that it asked Launch Services
// for a fresh launch (never started here).
// quit-appleevent waits for a Quit Apple event (below).

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
// A Dock click while the reader finishes: Launch Services sends the running process a reopen Apple event, queued on
// the main thread's event port as Launch Services' is. Sent from another thread once the quit is that old, and before
// the finishing step goes on.
static IMP gFinishQuit;
static double gReopenAfter = -1;
static void FinishQuitAfterReopen(id reader, SEL sel) {
    if (gReopenAfter >= 0) {
        double after = gReopenAfter;
        gReopenAfter = -1;
        dispatch_semaphore_t sent = dispatch_semaphore_create(0);
        __block double sentAt = -1;
        __block OSStatus status = 0;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            while (Now() - gQuit < after) usleep(500);
            NSAppleEventDescriptor* event = [NSAppleEventDescriptor
                appleEventWithEventClass:kCoreEventClass eventID:kAEReopenApplication
                        targetDescriptor:[NSAppleEventDescriptor descriptorWithProcessIdentifier:getpid()]
                                returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
            sentAt = Now() - gQuit;
            status = AESendMessage(event.aeDesc, NULL, kAENoReply | kAENeverInteract, kAEDefaultTimeout);
            dispatch_semaphore_signal(sent);
        });
        dispatch_semaphore_wait(sent, DISPATCH_TIME_FOREVER);
        gQuitExtra[@"reopen_sent_ms"] = @(sentAt);
        gQuitExtra[@"reopen_send_status"] = @(status);
    }
    ((void (*)(id, SEL))gFinishQuit)(reader, sel);
}
static NSWindow* RestorableWindow(void);
static NSWindow* InvisibleWindow(Class cls, NSString* identifier);
static IMP gShouldTerminate;
static void SendOpenDuringQuit(void);
static NSApplicationTerminateReply TimedShouldTerminate(id reader, SEL sel, id app) {
    if (gQuit < 0) { // quit-appleevent: the quit came from outside; said at once, should the process end by _exit
        gQuit = Now();
        fprintf(stdout, "PROBE_QUIT_AT %.3f\n", gQuit);
        fflush(stdout);
    }
    if (!gQuitExtra[@"should_terminate_ms"]) gQuitExtra[@"should_terminate_ms"] = @(Now() - gQuit);
    gQuitExtra[@"should_terminate_calls"] = @([gQuitExtra[@"should_terminate_calls"] integerValue] + 1);
    // PROBE_SECOND_ASK: window state still to write when the quit starts, as after a person used the window, so
    // AppKit's terminate: spins the run loop to write it (NSPersistentUIManager).
    if (getenv("PROBE_SECOND_ASK")) [RestorableWindow() invalidateRestorableState];
    if (getenv("PROBE_SECOND_ASK")) [InvisibleWindow(NSWindow.class, @"SPDFProbeTransientWindow") close]; // see below
    NSApplicationTerminateReply reply = ((NSApplicationTerminateReply(*)(id, SEL, id))gShouldTerminate)(reader, sel, app);
    SendOpenDuringQuit();
    return reply;
}
static void InstallQuitHooks(id reader) {
    gReader = reader;
    if (!gQuitExtra) gQuitExtra = [NSMutableDictionary dictionary];
    atexit(AtExit);
    method_setImplementation(class_getInstanceMethod(NSWorkspace.class,
                                 @selector(openApplicationAtURL:configuration:completionHandler:)), (IMP)RecordLaunch);
    method_setImplementation(class_getInstanceMethod(NSWorkspace.class,
                                 @selector(openURLs:withApplicationAtURL:configuration:completionHandler:)), (IMP)RecordOpen);
    gShouldTerminate = method_setImplementation(
        class_getInstanceMethod(object_getClass(reader), @selector(applicationShouldTerminate:)), (IMP)TimedShouldTerminate);
}

// ---- quit-appleevent: `quit app` ----------------------------------------------------------------------------------
// Once the launch settled the probe prints "PROBE_READY <pid>" and takes events until the quit arrives as
// `osascript -e 'tell application id "<this copy's id>" to quit'` delivers it: an Apple event, handled by AppKit
// between two events. PROBE_QUIT_SELF=<ms> has osascript send that Apple event to this process id that long
// after the launch settled. PROBE_OPEN_DURING_QUIT=<path> sends an
// open-documents Apple event for <path> the moment applicationShouldTerminate has answered, as a double-click in the
// Finder on a process that is still finishing does. PROBE_OWN_PASTEBOARD=1: the reader copied something last.
// PROBE_SECOND_ASK=1: AppKit asks applicationShouldTerminate: a second time during the quit, as it did on a person's
// Mac (below). PROBE_MD_COMMENT=<text>: PROBE_DOCUMENT (a Markdown file) gets a comment through the reader's own Add
// Comment, its editor answered, right before the quit can arrive.
static BOOL gOpenSent;
static void SendAppleEvent(AEEventClass eventClass, AEEventID eventID, NSAppleEventDescriptor* directObject) {
    NSAppleEventDescriptor* event = [NSAppleEventDescriptor
        appleEventWithEventClass:eventClass eventID:eventID
                targetDescriptor:[NSAppleEventDescriptor descriptorWithProcessIdentifier:getpid()]
                        returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    if (directObject) [event setParamDescriptor:directObject forKeyword:keyDirectObject];
    AESendMessage(event.aeDesc, NULL, kAENoReply | kAENeverInteract, kAEDefaultTimeout);
}
static void SendOpenDuringQuit(void) {
    const char* path = getenv("PROBE_OPEN_DURING_QUIT");
    if (!path || gOpenSent) return;
    gOpenSent = YES;
    NSString* file = [NSString stringWithUTF8String:path];
    gQuitExtra[@"open_sent_ms"] = @(Now() - gQuit);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        NSAppleEventDescriptor* list = [NSAppleEventDescriptor listDescriptor];
        [list insertDescriptor:[NSAppleEventDescriptor descriptorWithFileURL:[NSURL fileURLWithPath:file]] atIndex:0];
        SendAppleEvent(kCoreEventClass, kAEOpenDocuments, list);
    });
}
static void AnswerCommentEditor(id, SEL, NSString*, NSString*, NSString*, NSString*, void (^done)(NSString*)) {
    done([NSString stringWithUTF8String:getenv("PROBE_MD_COMMENT")]);
}
static void AnswerCommentEditorWithDraft(id, SEL, NSString*, NSString*, NSString*, NSString*, NSString*,
                                         void (^done)(NSString*)) {
    done([NSString stringWithUTF8String:getenv("PROBE_MD_COMMENT")]);
}
static BOOL AddMarkdownCommentNow(id reader) {
    NSString* path = getenv("PROBE_DOCUMENT") ? [NSString stringWithUTF8String:getenv("PROBE_DOCUMENT")] : nil;
    if (!path) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(reader, NSSelectorFromString(@"openPaths:"), @[ path ]);
    SEL session = NSSelectorFromString(@"activeMarkdownSession");
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:15];
    while (![((id (*)(id, SEL))objc_msgSend)(reader, session) valueForKey:@"renderedDocument"] &&
           until.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    // The comment editor, answered at once (its draft-keeping form, and the one before it).
    Class cls = object_getClass(reader);
    Method editor = class_getInstanceMethod(cls,
        NSSelectorFromString(@"openCommentEditorWithTitle:button:author:text:draftKey:completion:"));
    if (editor) method_setImplementation(editor, (IMP)AnswerCommentEditorWithDraft);
    else if ((editor = class_getInstanceMethod(cls,
                  NSSelectorFromString(@"openCommentEditorWithTitle:button:author:text:completion:"))))
        method_setImplementation(editor, (IMP)AnswerCommentEditor);
    else return NO;
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(reader, NSSelectorFromString(@"noteMarkdownContextMenuAtLocation:"), 2);
    ((void (*)(id, SEL, id))objc_msgSend)(reader, NSSelectorFromString(@"addMarkdownComment:"), nil);
    return ((NSInteger (*)(id, SEL))objc_msgSend)(reader, NSSelectorFromString(@"markdownCommentCount")) > 0;
}

// Windows of the probe's own, which the launch probe lets on screen (SPDFProbe identifiers): borderless, fully
// transparent, 1 x 1 pt and far outside every screen, so nothing shows.
static NSWindow* InvisibleWindow(Class cls, NSString* identifier) {
    NSWindow* window = [[cls alloc] initWithContentRect:NSMakeRect(-30000, -30000, 1, 1)
                                              styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    window.alphaValue = 0;
    window.ignoresMouseEvents = YES;
    window.identifier = identifier;
    [window orderFront:nil];
    return window;
}
// One that state restoration keeps, as it keeps a window a person used; its state takes a moment to write, as a real
// window's does, so the quit's write of it spins the run loop a while.
@interface SPDFProbeRestorableWindow : NSWindow
@end
@implementation SPDFProbeRestorableWindow
- (void)encodeRestorableStateWithCoder:(NSCoder*)coder {
    [super encodeRestorableStateWithCoder:coder];
    usleep(30000);
}
@end
static NSWindow* RestorableWindow(void) {
    static NSWindow* window;
    if (!window) window = InvisibleWindow(SPDFProbeRestorableWindow.class, @"SPDFProbeRestorableWindow");
    window.restorable = YES;
    return window;
}
// State restoration is off for a process started this way; on, as for an app opened from the Finder.
__attribute__((constructor)) static void QuitProbeDefaults(void) {
    if (getenv("PROBE_SECOND_ASK")) [NSUserDefaults.standardUserDefaults registerDefaults:@{@"ApplePersistence" : @YES}];
}

// PROBE_OWN_PASTEBOARD=1: the reader last wrote the general pasteboard, as after a person copied something from it --
// without touching the person's clipboard: the reader's general pasteboard is a private one, reported under the
// general pasteboard's name, and the reader writes it through its own pasteboard-ownership hooks.
static NSPasteboard* gPrivateGeneral;
static IMP gPasteboardName;
static NSPasteboard* PrivateGeneral(id, SEL) { return gPrivateGeneral; }
static NSPasteboardName PasteboardName(NSPasteboard* pasteboard, SEL sel) {
    if (pasteboard == gPrivateGeneral) return NSPasteboardNameGeneral;
    return ((NSPasteboardName(*)(id, SEL))gPasteboardName)(pasteboard, sel);
}
static void OwnPrivateGeneralPasteboard(void) {
    gPrivateGeneral = [NSPasteboard pasteboardWithUniqueName];
    gPasteboardName = method_setImplementation(class_getInstanceMethod(NSPasteboard.class, @selector(name)),
                                               (IMP)PasteboardName);
    method_setImplementation(class_getClassMethod(NSPasteboard.class, @selector(generalPasteboard)), (IMP)PrivateGeneral);
    [gPrivateGeneral clearContents];
    [gPrivateGeneral setString:@"copied from the reader" forType:NSPasteboardTypeString];
}
// ... and a window closing while the quit is under way, just before the reader answers: AppKit queues a terminate of
// its own for the last window closed, which runs inside that spin and takes back the answer, so terminate: asks again.
static IMP gFinishQuitWindowCloses;
static void FinishQuitWindowCloses(id reader, SEL sel) {
    [InvisibleWindow(NSWindow.class, @"SPDFProbeTransientWindow") close];
    ((void (*)(id, SEL))gFinishQuitWindowCloses)(reader, sel);
}
// PROBE_QUIT_STALL=finish: the reader's finishing step never runs, as a completion that never comes back would leave
// it; PROBE_QUIT_STALL=main: it runs with the main thread stuck for 10 s. The quit must end by its deadline anyway.
static void FinishQuitNever(id, SEL) {}
static IMP gFinishQuitStuck;
static void FinishQuitStuck(id reader, SEL sel) {
    sleep(10);
    ((void (*)(id, SEL))gFinishQuitStuck)(reader, sel);
}
static void ServeAppleEventQuit(id reader) {
    const char* stall = getenv("PROBE_QUIT_STALL") ?: "";
    Method finish = class_getInstanceMethod(object_getClass(reader), NSSelectorFromString(@"quitFinishWhenImageCopyWritten"));
    if (!strcmp(stall, "finish")) method_setImplementation(finish, (IMP)FinishQuitNever);
    if (!strcmp(stall, "main")) gFinishQuitStuck = method_setImplementation(finish, (IMP)FinishQuitStuck);
    if (getenv("PROBE_SECOND_ASK"))
        gFinishQuitWindowCloses = method_setImplementation(
            class_getInstanceMethod(object_getClass(reader), NSSelectorFromString(@"quitFinishWhenImageCopyWritten")),
            (IMP)FinishQuitWindowCloses);
    if (getenv("PROBE_OWN_PASTEBOARD")) OwnPrivateGeneralPasteboard();
    if (getenv("PROBE_SECOND_ASK")) [RestorableWindow() invalidateRestorableState];
    if (getenv("PROBE_MD_COMMENT") && !AddMarkdownCommentNow(reader)) {
        fprintf(stderr, "quit probe: could not add the Markdown comment\n");
        _exit(3);
    }
    DispatchEvents(0.3);
    if (getenv("PROBE_QUIT_SELF")) {
        // From another process, as `quit app` comes: one this process sends itself is handled on the sending thread.
        // NSRunningApplication -terminate sends the Quit Apple event to this process id, and to nothing else.
        NSTask* task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
        task.arguments = @[ @"-l", @"JavaScript", @"-e",
                            [NSString stringWithFormat:@"ObjC.import('AppKit'); delay(%.3f); "
                                                       @"$.NSRunningApplication.runningApplicationWithProcessIdentifier(%d)"
                                                       @".terminate",
                                                       atof(getenv("PROBE_QUIT_SELF")) / 1000.0, getpid()] ];
        task.standardOutput = task.standardError = NSFileHandle.fileHandleWithNullDevice;
        [task launchAndReturnError:nil];
    }
    fprintf(stdout, "PROBE_READY %d\n", getpid());
    fflush(stdout);
    for (;;) DispatchEvents(3600);
}

// Runs once the launch settled; returns NO for modes it does not own.
BOOL SPDFProbeRunQuitMode(const char* mode, id reader) {
    if (strncmp(mode, "quit-", 5) != 0) return NO;
    InstallQuitHooks(reader);
    if (!strcmp(mode, "quit-appleevent")) ServeAppleEventQuit(reader); // does not return: the reader quits itself
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
        gReopenAfter = atof(getenv("PROBE_REOPEN"));
        gFinishQuit = method_setImplementation(
            class_getInstanceMethod(object_getClass(reader), NSSelectorFromString(@"quitFinishWhenImageCopyWritten")),
            (IMP)FinishQuitAfterReopen);
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
