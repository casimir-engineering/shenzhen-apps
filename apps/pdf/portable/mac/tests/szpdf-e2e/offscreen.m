// Inserted into the szpdf end-to-end test's own copy of the app (szpdf_e2e.py; DYLD_INSERT_LIBRARIES through its
// LSEnvironment). Its windows order in for real, but far off every display; every request to activate the app is
// logged with its stack and refused, so a regression is caught and can never take the keyboard from whoever is
// typing; the keychain, the Friends helper and distributed notifications are refused.
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#include <spawn.h>

static void Log(NSDictionary* event) {
    const char* path = getenv("OFFSCREEN_LOG");
    if (!path) return;
    NSMutableDictionary* entry = [event mutableCopy];
    entry[@"pid"] = @(getpid());
    entry[@"t"] = @(NSDate.date.timeIntervalSince1970);
    NSData* data = [NSJSONSerialization dataWithJSONObject:entry options:NSJSONWritingSortedKeys error:nil];
    FILE* file = fopen(path, "a");
    if (!file) return;
    fwrite(data.bytes, 1, data.length, file);
    fputc('\n', file);
    fclose(file);
}

static NSArray* Stack(void) {
    NSArray* stack = [NSThread callStackSymbols];
    return stack.count > 14 ? [stack subarrayWithRange:NSMakeRange(1, 13)] : stack;
}

static NSRect Off(NSRect rect) {
    if (rect.origin.x < 30000) rect.origin.x += 40000;
    return rect;
}

static IMP oSetFrame, oSetFrameAnimate, oSetOrigin, oSetTopLeft, oOrderFront, oMakeKeyFront, oOrderRegardless;
static void SetFrame(id s, SEL c, NSRect r, BOOL d) { ((void (*)(id, SEL, NSRect, BOOL))oSetFrame)(s, c, Off(r), d); }
static void SetFrameAnimate(id s, SEL c, NSRect r, BOOL d, BOOL a) {
    (void)a;
    ((void (*)(id, SEL, NSRect, BOOL, BOOL))oSetFrameAnimate)(s, c, Off(r), d, NO);
}
static void SetOrigin(id s, SEL c, NSPoint p) {
    if (p.x < 30000) p.x += 40000;
    ((void (*)(id, SEL, NSPoint))oSetOrigin)(s, c, p);
}
static NSPoint SetTopLeft(id s, SEL c, NSPoint p) {
    if (p.x < 30000) p.x += 40000;
    return ((NSPoint (*)(id, SEL, NSPoint))oSetTopLeft)(s, c, p);
}
static NSRect Constrain(id s, SEL c, NSRect r, NSScreen* screen) { (void)s, (void)c, (void)screen; return Off(r); }
static void Note(id window, NSString* what) {
    Log(@{@"event" : what, @"window" : @([window windowNumber]), @"title" : [window title] ?: @"", @"stack" : Stack()});
}
static void OrderFront(id s, SEL c, id x) { Note(s, @"orderFront"); ((void (*)(id, SEL, id))oOrderFront)(s, c, x); }
static void MakeKeyFront(id s, SEL c, id x) { Note(s, @"makeKeyAndOrderFront"); ((void (*)(id, SEL, id))oMakeKeyFront)(s, c, x); }
static void OrderRegardless(id s, SEL c) { Note(s, @"orderFrontRegardless"); ((void (*)(id, SEL))oOrderRegardless)(s, c); }
static void Refuse(NSString* selector) { Log(@{@"event" : @"refused_activate", @"sel" : selector, @"stack" : Stack()}); }
static void RefuseIgnoring(id s, SEL c, BOOL b) { (void)s, (void)b; Refuse(NSStringFromSelector(c)); }
static void RefuseActivate(id s, SEL c) { (void)s; Refuse(NSStringFromSelector(c)); }
static BOOL RefuseRunning(id s, SEL c, NSUInteger o) { (void)s, (void)c, (void)o; Refuse(@"activateWithOptions:"); return NO; }
static void RefuseUnhide(id s, SEL c, id x) { (void)s, (void)c, (void)x; Refuse(@"unhide:"); }
static NSInteger RefuseModal(id s, SEL c, id w) { (void)s, (void)c, (void)w; Refuse(@"runModalForWindow:"); return NSModalResponseCancel; }
static NSInteger RefuseAlert(id s, SEL c) { (void)s, (void)c; Refuse(@"NSAlert runModal"); return NSAlertSecondButtonReturn; }
static void DropDistributed(id s, SEL c, NSString* n, id o, id u, BOOL d) { (void)s, (void)c, (void)n, (void)o, (void)u, (void)d; }

static void Replace(Class cls, SEL selector, IMP imp, IMP* original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    IMP old = class_replaceMethod(cls, selector, imp, method_getTypeEncoding(method));
    if (original && !*original) *original = old ?: method_getImplementation(method);
}

static OSStatus NoCopy(CFDictionaryRef q, CFTypeRef* r) { (void)q; if (r) *r = NULL; return errSecItemNotFound; }
static OSStatus NoAdd(CFDictionaryRef q, CFTypeRef* r) { (void)q; if (r) *r = NULL; return errSecInteractionNotAllowed; }
static OSStatus NoUpdate(CFDictionaryRef q, CFDictionaryRef a) { (void)q, (void)a; return errSecInteractionNotAllowed; }
static OSStatus NoDelete(CFDictionaryRef q) { (void)q; return errSecItemNotFound; }
static int Spawn(pid_t* pid, const char* path, const posix_spawn_file_actions_t* a, const posix_spawnattr_t* at,
                 char* const argv[], char* const envp[]) {
    if (path && strstr(path, "Shenzhen Friends")) return EPERM;
    return posix_spawn(pid, path, a, at, argv, envp);
}
__attribute__((used, section("__DATA,__interpose"))) static const struct { const void *replacement, *original; } kInterpose[] = {
    {(const void*)NoCopy, (const void*)SecItemCopyMatching}, {(const void*)NoAdd, (const void*)SecItemAdd},
    {(const void*)NoUpdate, (const void*)SecItemUpdate},     {(const void*)NoDelete, (const void*)SecItemDelete},
    {(const void*)Spawn, (const void*)posix_spawn},
};

__attribute__((constructor)) static void Install(void) {
    Class window = NSWindow.class;
    Replace(window, @selector(setFrame:display:), (IMP)SetFrame, &oSetFrame);
    Replace(window, @selector(setFrame:display:animate:), (IMP)SetFrameAnimate, &oSetFrameAnimate);
    Replace(window, @selector(setFrameOrigin:), (IMP)SetOrigin, &oSetOrigin);
    Replace(window, @selector(setFrameTopLeftPoint:), (IMP)SetTopLeft, &oSetTopLeft);
    Replace(window, @selector(constrainFrameRect:toScreen:), (IMP)Constrain, NULL);
    Replace(window, @selector(orderFront:), (IMP)OrderFront, &oOrderFront);
    Replace(window, @selector(makeKeyAndOrderFront:), (IMP)MakeKeyFront, &oMakeKeyFront);
    Replace(window, @selector(orderFrontRegardless), (IMP)OrderRegardless, &oOrderRegardless);
    Replace(NSApplication.class, @selector(activateIgnoringOtherApps:), (IMP)RefuseIgnoring, NULL);
    Replace(NSApplication.class, sel_registerName("activate"), (IMP)RefuseActivate, NULL);
    Replace(NSApplication.class, @selector(unhide:), (IMP)RefuseUnhide, NULL);
    Replace(NSApplication.class, @selector(runModalForWindow:), (IMP)RefuseModal, NULL);
    Replace(NSAlert.class, @selector(runModal), (IMP)RefuseAlert, NULL);
    Replace(NSRunningApplication.class, @selector(activateWithOptions:), (IMP)RefuseRunning, NULL);
    Replace(NSDistributedNotificationCenter.class, @selector(postNotificationName:object:userInfo:deliverImmediately:),
            (IMP)DropDistributed, NULL);
    Log(@{@"event" : @"inserted"});
}
