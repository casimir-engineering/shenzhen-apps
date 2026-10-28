// driver.m: inserted (DYLD_INSERT_LIBRARIES, after tools/updater-e2e/szut.m, which keeps every window off screen,
// refuses the Keychain and sends the model's requests to titles_stub.py) into a test copy of ShenzhenPDF.app by
// run_titles_e2e.py. It looks through the restored tabs as a person would (selecting each), types the owner's
// requests into the assistant chat and presses Return, closes and reopens a document the way the tab strip and Open
// do, and saves pictures of the reader and the chat. After each step it records what the tab strip shows for every
// tab, with its file, group and read-only state.
//
// Environment: SPDF_E2E_PLAN, a JSON file {"phase": "sort" | "relaunch", "questions": {...}, "reopen": path};
// SPDF_E2E_OUT, the folder for pictures and <phase>.json.
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSDictionary* gPlan;
static NSString* gOut;
static NSMutableDictionary* gResult;

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
static void Wait(double seconds) { [NSThread sleepForTimeInterval:seconds]; }
static id Reader(void) { return NSApp.delegate; }
static NSWindow* ReaderWindow(void) { return [Reader() valueForKey:@"window"]; }
static void Send(NSString* selector, id argument) {
    Main(^id { ((void (*)(id, SEL, id))objc_msgSend)(Reader(), NSSelectorFromString(selector), argument); return nil; });
}

// What the person sees for each tab: the tab strip's own title, and what is behind it.
static NSArray* Rows(void) {
    return Main(^id {
        NSArray* tabs = [Reader() valueForKey:@"tabs"];
        id strip = [Reader() valueForKey:@"tabStrip"];
        NSMutableArray* rows = [NSMutableArray array];
        for (NSUInteger i = 0; i < tabs.count; i++) {
            id tab = tabs[i], group = [tab valueForKey:@"group"];
            NSString* shown = ((id (*)(id, SEL, NSInteger))objc_msgSend)(strip, NSSelectorFromString(@"titleForTabAtIndex:"), (NSInteger)i);
            NSString* full = ((id (*)(id, SEL, NSInteger))objc_msgSend)(strip, NSSelectorFromString(@"fullTitleForTabAtIndex:"), (NSInteger)i);
            [rows addObject:@{@"path" : [tab valueForKey:@"path"] ?: @"", @"strip" : shown ?: @"", @"stripFull" : full ?: @"",
                              @"displayName" : ([tab respondsToSelector:NSSelectorFromString(@"displayName")] ? [tab valueForKey:@"displayName"] : nil) ?: @"",
                              @"readOnly" : [tab valueForKey:@"readOnly"] ?: @NO,
                              @"group" : group ? ([group valueForKey:@"displayName"] ?: @"") : @"General",
                              @"general" : @(!group || [[group valueForKey:@"general"] boolValue])}];
        }
        return rows;
    });
}
static NSString* WindowTitle(void) { return Main(^id { return ReaderWindow().title ?: @""; }); }

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
        NSView* strip = [Reader() valueForKey:@"tabStrip"];
        Save(strip, [name stringByAppendingString:@"-tabs"]);
        NSView* chat = ChatView();
        if (chat) Save(chat, [name stringByAppendingString:@"-chat"]);
        return nil;
    });
}

static id Session(void) {
    return [((id (*)(id, SEL))objc_msgSend)(Reader(), NSSelectorFromString(@"readerAIState")) valueForKey:@"session"];
}
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
// Types `text` into the composer and presses Return, as the keyboard would; records what the assistant did.
static void Ask(NSString* text, NSString* name) {
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
    BOOL ended = WaitFor(180, ^BOOL { return ![[Session() valueForKey:@"running"] boolValue]; });
    Wait(1);
    Main(^id {
        NSArray* messages = [Session() valueForKey:@"chat"][@"messages"];
        NSMutableArray* tools = [NSMutableArray array], *calls = [NSMutableArray array];
        NSString* answer = @"";
        for (NSDictionary* message in messages.reverseObjectEnumerator) {
            if ([message[@"role"] isEqual:@"user"]) break;
            if ([message[@"role"] isEqual:@"tool"]) [tools insertObject:message[@"content"] ?: @"" atIndex:0];
            for (NSDictionary* call in [message[@"tool_calls"] reverseObjectEnumerator] ?: @[])
                [calls insertObject:call[@"function"] ?: @{} atIndex:0];
            if ([message[@"role"] isEqual:@"assistant"] && [message[@"content"] length] && !answer.length)
                answer = message[@"content"];
        }
        gResult[name] = @{@"answer" : answer, @"tools" : tools, @"calls" : calls, @"ended" : @(ended)};
        return nil;
    });
    gResult[[name stringByAppendingString:@"Tabs"]] = Rows();
}

// Brings the tab of `path` to the front, as a click on it would, so its group is open in the pictures.
static void Front(NSString* path) {
    Main(^id {
        NSArray* tabs = [Reader() valueForKey:@"tabs"];
        for (NSUInteger i = 0; i < tabs.count; i++) if ([[tabs[i] valueForKey:@"path"] isEqual:path])
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(Reader(), NSSelectorFromString(@"selectTabAtIndex:"), (NSInteger)i);
        return nil;
    });
    Wait(1);
}
static void LookThrough(void) {
    // The person looks through the documents, as the owner had: each read-only one gets the private copy the
    // reader reads it from.
    NSArray* rows = Rows();
    for (NSUInteger i = 0; i < rows.count; i++) {
        Main(^id { ((void (*)(id, SEL, NSInteger))objc_msgSend)(Reader(), NSSelectorFromString(@"selectTabAtIndex:"), (NSInteger)i); return nil; });
        Wait(0.6);
    }
    Main(^id { ((void (*)(id, SEL, NSInteger))objc_msgSend)(Reader(), NSSelectorFromString(@"selectTabAtIndex:"), (NSInteger)0); return nil; });
    Wait(0.6);
}

static void Sort(void) {
    Wait(1);
    LookThrough();
    Front(gPlan[@"focus"]);
    gResult[@"before"] = Rows();
    Shot(@"1-before");
    OpenChat();
    Ask(gPlan[@"questions"][@"sort"], @"sort");
    Front(gPlan[@"focus"]);
    gResult[@"windowTitle"] = WindowTitle();
    Shot(@"2-renamed-and-grouped");
    Ask(gPlan[@"questions"][@"save"], @"save");
    Shot(@"3-read-only-saved");
}

static void Relaunch(void) {
    // The same profile relaunched: the names come back with the tabs. Then the read-only datasheet is closed and
    // opened again from its file, as Open or Finder would: Collection gives it its name back.
    Wait(2);
    gResult[@"restored"] = Rows();
    Front(gPlan[@"reopen"]);
    Shot(@"4-relaunched");
    NSString* reopen = gPlan[@"reopen"];
    Main(^id {
        NSArray* tabs = [Reader() valueForKey:@"tabs"];
        for (NSUInteger i = 0; i < tabs.count; i++) if ([[tabs[i] valueForKey:@"path"] isEqual:reopen]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(Reader(), NSSelectorFromString(@"closeTabAtIndex:"), (NSInteger)i);
            break;
        }
        return nil;
    });
    Wait(1);
    gResult[@"closed"] = Rows();
    Send(@"openPath:", reopen);
    WaitFor(15, ^BOOL {
        for (NSDictionary* row in Rows()) if ([row[@"path"] isEqual:reopen] && [row[@"displayName"] length]) return YES;
        return NO;
    });
    Wait(0.5);
    gResult[@"reopened"] = Rows();
    gResult[@"reopenedWindowTitle"] = WindowTitle();
    Shot(@"5-reopened");
}

static NSString* StubKey(id self, SEL _cmd, BOOL authorize, NSError** error) {
    (void)self, (void)_cmd, (void)authorize;
    if (error) *error = nil;
    return @"sk-or-v1-e2e-stub-key-not-real-0000000000";
}

__attribute__((constructor)) static void E2EInit(void) {
    const char* plan = getenv("SPDF_E2E_PLAN"), *out = getenv("SPDF_E2E_OUT");
    // Only in the reader: its helpers (the Collection window, Friends) inherit DYLD_INSERT_LIBRARIES too.
    if (!plan || !out || strcmp(getprogname(), "ShenzhenPDF") != 0) return;
    gPlan = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(plan)] options:0 error:nil];
    gOut = @(out);
    gResult = [@{@"log" : [NSMutableArray array]} mutableCopy];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil
                                                     queue:nil usingBlock:^(NSNotification* note) {
        (void)note;
        Class credentials = NSClassFromString(@"SPDFMacAICredentials");
        Method read = class_getInstanceMethod(credentials, NSSelectorFromString(@"readAPIKeyWithAuthorization:error:"));
        if (read) method_setImplementation(read, (IMP)StubKey);
        [NSThread detachNewThreadWithBlock:^{
            Wait(2);
            NSString* phase = gPlan[@"phase"];
            @try {
                if ([phase isEqual:@"sort"]) Sort(); else Relaunch();
            } @catch (NSException* exception) { Log([@"exception: " stringByAppendingString:exception.reason]); }
            NSData* json = [NSJSONSerialization dataWithJSONObject:gResult options:NSJSONWritingPrettyPrinted error:nil];
            [json writeToFile:[gOut stringByAppendingPathComponent:[phase stringByAppendingString:@".json"]] atomically:YES];
            Log(@"done");
            // Quit the way Command-Q does: the session is written on the way out.
            dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        }];
    }];
}
