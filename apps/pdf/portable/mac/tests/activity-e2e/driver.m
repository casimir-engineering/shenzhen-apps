// driver.m: inserted (DYLD_INSERT_LIBRARIES, after tools/updater-e2e/szut.m, which keeps every window off screen,
// refuses the Keychain and sends the model's requests to activity_stub.py) into a test copy of ShenzhenPDF.app by
// run_activity_e2e.py. It opens and switches documents the way the reader's menus and tab strip do, and plays the
// part of the window server: whether the app is frontmost and its window key and visible (SetFront), and how long
// since the last key or mouse input (a fixed 0.5 s). It types into the assistant chat and presses Return, and saves
// pictures of the reader and the chat after each step.
//
// Environment: SPDF_E2E_PLAN, a JSON file {"phase": "record" | "relaunch" | "aged", "documents": [paths],
// "questions": {...}}; SPDF_E2E_OUT, the folder for pictures and result.json.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSDictionary* gPlan;
static NSString* gOut;
static NSMutableDictionary* gResult;
static BOOL gFront;

// The person is at the Mac: their last input was half a second ago, whatever the owner of this Mac is doing.
static CFTimeInterval E2EIdle(CGEventSourceStateID state, CGEventType type) {
    (void)state, (void)type;
    return 0.5;
}
__attribute__((used)) static const struct { const void* replacement; const void* replacee; } gInterpose[]
    __attribute__((section("__DATA,__interpose"))) = {{(const void*)E2EIdle, (const void*)CGEventSourceSecondsSinceLastEventType}};

static id Main(id (^block)(void)) {
    if (NSThread.isMainThread) return block();
    __block id value = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{ value = block(); });
    return value;
}
static void Log(NSString* text) {
    fprintf(stderr, "[e2e] %s\n", text.UTF8String);
    [gResult[@"log"] addObject:text];
}
static double Now(void) { return NSDate.date.timeIntervalSince1970; }
static void Event(NSString* name) {
    gResult[@"events"][name] = @(Now());
    Log([NSString stringWithFormat:@"%@ at %.3f", name, Now()]);
}
static id Reader(void) { return NSApp.delegate; }
static NSWindow* ReaderWindow(void) { return [Reader() valueForKey:@"window"]; }

// The window server, as the reader asks it.
static IMP gOrigKey, gOrigMain, gOrigVisible, gOrigOcclusion;
static BOOL IsActive(id self, SEL _cmd) { (void)self, (void)_cmd; return gFront; }
static BOOL IsKey(NSWindow* self, SEL _cmd) {
    return self == ReaderWindow() ? gFront : ((BOOL (*)(id, SEL))gOrigKey)(self, _cmd);
}
static BOOL IsMain(NSWindow* self, SEL _cmd) {
    return self == ReaderWindow() ? gFront : ((BOOL (*)(id, SEL))gOrigMain)(self, _cmd);
}
static BOOL IsVisible(NSWindow* self, SEL _cmd) {
    return self == ReaderWindow() ? gFront : ((BOOL (*)(id, SEL))gOrigVisible)(self, _cmd);
}
static NSWindowOcclusionState Occlusion(NSWindow* self, SEL _cmd) {
    if (self == ReaderWindow()) return gFront ? NSWindowOcclusionStateVisible : 0;
    return ((NSWindowOcclusionState (*)(id, SEL))gOrigOcclusion)(self, _cmd);
}
static void Swap(Class cls, SEL selector, IMP imp, IMP* original) {
    Method method = class_getInstanceMethod(cls, selector);
    *original = method_setImplementation(method, imp);
}

// The person brings the app forward (its window becomes key) or switches to another app.
static void SetFront(BOOL front) {
    Main(^id {
        gFront = front;
        NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
        [center postNotificationName:front ? NSApplicationDidBecomeActiveNotification : NSApplicationDidResignActiveNotification
                              object:NSApp];
        [center postNotificationName:front ? NSWindowDidBecomeKeyNotification : NSWindowDidResignKeyNotification
                              object:ReaderWindow()];
        return nil;
    });
    Log(front ? @"app frontmost, reader window key" : @"another app frontmost");
}

static NSArray<NSString*>* Tabs(void) {
    return Main(^id { return ((id (*)(id, SEL))objc_msgSend)(Reader(), NSSelectorFromString(@"openTabPaths")); });
}
static NSString* Selected(void) {
    return Main(^id {
        id tab = ((id (*)(id, SEL))objc_msgSend)(Reader(), NSSelectorFromString(@"selectedTab"));
        return [tab valueForKey:@"path"] ?: @"";
    });
}
static void Open(NSString* path) {
    Main(^id { ((void (*)(id, SEL, id))objc_msgSend)(Reader(), NSSelectorFromString(@"openPath:"), path); return nil; });
    Event([@"open " stringByAppendingString:path.lastPathComponent]);
}
static void Select(NSString* path) {
    Main(^id {
        NSUInteger index = [Tabs() indexOfObject:path];
        if (index != NSNotFound)
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(Reader(), NSSelectorFromString(@"selectTabAtIndex:"), (NSInteger)index);
        return nil;
    });
    Event([@"select " stringByAppendingString:path.lastPathComponent]);
}
static void Wait(double seconds) { [NSThread sleepForTimeInterval:seconds]; }

static NSView* FindView(NSView* root, NSString* className) {
    if ([NSStringFromClass(root.class) isEqual:className]) return root;
    for (NSView* sub in root.subviews) { NSView* found = FindView(sub, className); if (found) return found; }
    return nil;
}
static NSView* ChatView(void) {
    return Main(^id {
        for (NSWindow* window in NSApp.windows) {
            NSView* found = window.contentView ? FindView(window.contentView.superview ?: window.contentView,
                                                          @"SPDFMacAIChatView") : nil;
            if (found) return found;
        }
        return nil;
    });
}
static void Save(NSView* view, NSString* name) {
    if (!view || NSIsEmptyRect(view.bounds)) return;
    [view layoutSubtreeIfNeeded];
    [view displayIfNeeded];
    NSBitmapImageRep* rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    NSString* file = [gOut stringByAppendingPathComponent:[name stringByAppendingString:@".png"]];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:file atomically:YES];
}
static void Shot(NSString* name) {
    Main(^id {
        NSView* reader = ReaderWindow().contentView;
        Save(reader.superview ?: reader, [name stringByAppendingString:@"-reader"]);
        NSView* chat = ChatView();
        if (chat) Save(chat, [name stringByAppendingString:@"-chat"]);
        return nil;
    });
}

static id State(void) { return ((id (*)(id, SEL))objc_msgSend)(Reader(), NSSelectorFromString(@"readerAIState")); }
static id Session(void) { return [State() valueForKey:@"session"]; }
static BOOL WaitFor(NSTimeInterval seconds, BOOL (^done)(void)) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (deadline.timeIntervalSinceNow > 0) {
        if ([Main(^id { return @(done()); }) boolValue]) return YES;
        [NSThread sleepForTimeInterval:0.2];
    }
    return NO;
}
static void OpenChat(void) {
    Main(^id { [NSApp sendAction:NSSelectorFromString(@"showAIChat:") to:nil from:nil]; return nil; });
    if (!WaitFor(20, ^BOOL { return ChatView() != nil; })) Log(@"no chat view");
    Wait(1);
}
// Types `text` into the composer and presses Return, as the keyboard would; returns what the person then sees.
static NSDictionary* Ask(NSString* text, NSString* name) {
    Log([@"ask: " stringByAppendingString:text]);
    Main(^id {
        NSTextView* composer = [ChatView() valueForKey:@"composer"];
        [composer.window makeFirstResponder:composer];
        [composer insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
        NSEvent* enter = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
            timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:composer.window.windowNumber context:nil
            characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
        [composer keyDown:enter];
        return nil;
    });
    WaitFor(10, ^BOOL { return [[Session() valueForKey:@"running"] boolValue]; });
    BOOL ended = WaitFor(120, ^BOOL { return ![[Session() valueForKey:@"running"] boolValue]; });
    Wait(0.5);
    return Main(^id {
        NSArray* messages = [Session() valueForKey:@"chat"][@"messages"];
        NSMutableArray* tools = [NSMutableArray array], *calls = [NSMutableArray array];
        NSString* answer = @"";
        for (NSDictionary* message in messages.reverseObjectEnumerator) {
            if ([message[@"role"] isEqual:@"user"]) break;
            if ([message[@"role"] isEqual:@"tool"]) [tools insertObject:message[@"content"] ?: @"" atIndex:0];
            for (NSDictionary* call in message[@"tool_calls"] ?: @[]) [calls insertObject:call[@"function"] ?: @{} atIndex:0];
            if ([message[@"role"] isEqual:@"assistant"] && [message[@"content"] length] && !answer.length)
                answer = message[@"content"];
        }
        NSDictionary* exchange = @{@"answer" : answer, @"tools" : tools, @"calls" : calls, @"ended" : @(ended),
                                   @"tabs" : Tabs(), @"selected" : Selected()};
        gResult[name] = exchange;
        return exchange;
    });
}

static void Record(NSArray* documents) {
    // A new profile: nothing open. The person opens five documents, looking at some, flicking past one, and opening
    // two while another app is in front.
    SetFront(YES);
    Open(documents[0]); Wait(3);      // A: in front 3 s, viewed
    Open(documents[1]); Wait(0.8);    // B: in front under a second, not viewed
    Open(documents[2]); Wait(3);      // C: viewed
    Shot(@"1-record-front");
    SetFront(NO);
    Open(documents[3]); Wait(3);      // D: opened while another app is in front: not viewed
    Open(documents[4]); Wait(0.5);    // E: the same
    Select(documents[2]); Wait(0.5);  // back to C, still in the background
    SetFront(YES); Wait(2.6);         // C in front again: viewed again
    Event(@"quit");
    gResult[@"tabs"] = Tabs();
}

static void Relaunch(void) {
    // The same profile relaunched: the tabs come back and C is in front. The others are restored but unseen.
    Wait(1);
    gResult[@"restored"] = Tabs();
    gResult[@"restoredSelected"] = Selected();
    SetFront(YES); Event(@"front"); Wait(3);
    Shot(@"2-relaunch");
    OpenChat();
    Ask(gPlan[@"questions"][@"when"], @"when");
    Shot(@"3-when-viewed");
    Event(@"quit");
}

static void Aged(void) {
    // About a hundred tabs whose dates were aged by the test: the owner's request, Undo, and Reopen Last Closed.
    Wait(1);
    gResult[@"restored"] = Tabs();
    SetFront(YES); Wait(1);
    Shot(@"4-aged-before");
    OpenChat();
    Ask(gPlan[@"questions"][@"close"], @"close");
    Shot(@"5-aged-closed");
    Ask(gPlan[@"questions"][@"undo"], @"undo");
    Shot(@"6-aged-undone");
    Ask(gPlan[@"questions"][@"close"], @"closeAgain");
    // File > Reopen Last Closed, as the menu sends it.
    Main(^id { [NSApp sendAction:NSSelectorFromString(@"reopenLastClosedDocument:") to:nil from:nil]; return nil; });
    Wait(1.5);
    gResult[@"reopened"] = @{@"tabs" : Tabs(), @"selected" : Selected()};
    Shot(@"7-aged-reopened");
}

static NSString* StubKey(id self, SEL _cmd, BOOL authorize, NSError** error) {
    (void)self, (void)_cmd, (void)authorize;
    if (error) *error = nil;
    return @"sk-or-v1-e2e-stub-key-not-real-0000000000";
}

__attribute__((constructor)) static void E2EInit(void) {
    const char* plan = getenv("SPDF_E2E_PLAN"), *out = getenv("SPDF_E2E_OUT");
    if (!plan || !out) return;
    gPlan = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(plan)] options:0 error:nil];
    gOut = @(out);
    gResult = [@{@"log" : [NSMutableArray array], @"events" : [NSMutableDictionary dictionary]} mutableCopy];
    Method active = class_getInstanceMethod(NSApplication.class, @selector(isActive));
    method_setImplementation(active, (IMP)IsActive);
    Swap(NSWindow.class, @selector(isKeyWindow), (IMP)IsKey, &gOrigKey);
    Swap(NSWindow.class, @selector(isMainWindow), (IMP)IsMain, &gOrigMain);
    Swap(NSWindow.class, @selector(isVisible), (IMP)IsVisible, &gOrigVisible);
    Swap(NSWindow.class, @selector(occlusionState), (IMP)Occlusion, &gOrigOcclusion);
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil
                                                     queue:nil usingBlock:^(NSNotification* note) {
        (void)note;
        Class credentials = NSClassFromString(@"SPDFMacAICredentials");
        Method read = class_getInstanceMethod(credentials, NSSelectorFromString(@"readAPIKeyWithAuthorization:error:"));
        if (read) method_setImplementation(read, (IMP)StubKey);
        [NSThread detachNewThreadWithBlock:^{
            Wait(2);
            Event(@"start");
            NSString* phase = gPlan[@"phase"];
            @try {
                if ([phase isEqual:@"record"]) Record(gPlan[@"documents"]);
                else if ([phase isEqual:@"relaunch"]) Relaunch();
                else Aged();
            } @catch (NSException* exception) { Log([@"exception: " stringByAppendingString:exception.reason]); }
            NSData* json = [NSJSONSerialization dataWithJSONObject:gResult options:NSJSONWritingPrettyPrinted error:nil];
            [json writeToFile:[gOut stringByAppendingPathComponent:[phase stringByAppendingString:@".json"]] atomically:YES];
            Log(@"done");
            // Quit the way Command-Q does: the session and the dates are written on the way out.
            dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        }];
    }];
}
