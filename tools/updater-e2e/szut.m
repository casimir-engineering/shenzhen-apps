// szut.m: inserted (DYLD_INSERT_LIBRARIES) into ad hoc copies of released ShenzhenPDF / Shenzhen Files builds under
// $SZUT_ROOT, so their own updater code runs end to end against a local copy of GitHub, hidden, and touching nothing
// outside $SZUT_ROOT:
//   - every http(s) request is answered from $SZUT_ROUTES (a JSON map "METHOD URL" -> {status, headers, file,
//     location}); anything else fails as offline, so the app reaches no real server;
//   - no window is ordered on screen, the app never activates, no Dock icon (TransformProcessType refused);
//     NSApp.isActive reads YES so the silent daily path shows its prompt at once instead of waiting;
//   - NSAlert answers its first button (Install / Install Now), logging what it would have said;
//   - distributed notifications are dropped (a QuitForUpdate would quit the owner's running app);
//   - NSRunningApplication only sees and only terminates processes whose bundle is under $SZUT_ROOT;
//   - NSWorkspace launches, reveals and opens nothing: openApplicationAtURL: reports a running app at the URL asked
//     for (the updater checks its bundleURL); /usr/bin/open is refused;
//   - LSRegisterURL, keychain item calls and the Friends helper's spawn are refused and logged.
// Everything it sees or refuses is a JSON line in $SZUT_LOG. Outside $SZUT_ROOT it does nothing.
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static BOOL gActive;
static NSString *gRoot, *gRealRoot;
static NSDictionary *gRoutes;
static NSString *gRoutesDir;

static void SZLog(NSDictionary *event) {
    const char *path = getenv("SZUT_LOG");
    if (!path) return;
    NSMutableDictionary *e = [event mutableCopy];
    e[@"pid"] = @(getpid());
    e[@"t"] = @([NSDate date].timeIntervalSince1970);
    char exe[PATH_MAX]; uint32_t size = sizeof exe;
    if (_NSGetExecutablePath(exe, &size) == 0) e[@"exe"] = [@(exe) lastPathComponent];
    NSData *json = [NSJSONSerialization dataWithJSONObject:e options:NSJSONWritingSortedKeys error:nil];
    if (!json) return;
    FILE *f = fopen(path, "a");
    if (!f) return;
    fwrite(json.bytes, 1, json.length, f);
    fputc('\n', f);
    fclose(f);
}

static BOOL UnderRoot(NSString *path) {
    if (!path.length) return NO;
    NSString *p = path.stringByStandardizingPath;
    NSString *r = p.stringByResolvingSymlinksInPath;
    return [p hasPrefix:gRoot] || [p hasPrefix:gRealRoot] || [r hasPrefix:gRoot] || [r hasPrefix:gRealRoot];
}

#pragma mark - Network

@interface SZUTURLProtocol : NSURLProtocol
@end

@implementation SZUTURLProtocol {
    BOOL _stopped;
}
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *scheme = request.URL.scheme.lowercaseString;
    return [scheme isEqual:@"https"] || [scheme isEqual:@"http"];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSURLRequest *req = self.request;
    NSString *key = [NSString stringWithFormat:@"%@ %@", req.HTTPMethod ?: @"GET", req.URL.absoluteString];
    NSDictionary *route = gRoutes[key];
    NSMutableDictionary *headers = [req.allHTTPHeaderFields mutableCopy] ?: [NSMutableDictionary dictionary];
    if (headers[@"Authorization"]) headers[@"Authorization"] = @"(present)";
    SZLog(@{@"event" : @"request", @"key" : key, @"headers" : headers, @"routed" : @(route != nil)});
    if (!route) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil];
        [self.client URLProtocol:self didFailWithError:error];
        return;
    }
    NSInteger status = [route[@"status"] integerValue] ?: 200;
    NSMutableDictionary *outHeaders = [route[@"headers"] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (route[@"location"]) {
        outHeaders[@"Location"] = route[@"location"];
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:req.URL statusCode:status
                                                             HTTPVersion:@"HTTP/1.1" headerFields:outHeaders];
        NSMutableURLRequest *next = [req mutableCopy];
        next.URL = [NSURL URLWithString:route[@"location"]];
        [next setValue:nil forHTTPHeaderField:@"Authorization"];
        [self.client URLProtocol:self wasRedirectedToRequest:next redirectResponse:resp];
        return;
    }
    NSData *body = nil;
    if (route[@"file"]) {
        NSString *file = [gRoutesDir stringByAppendingPathComponent:route[@"file"]];
        body = [NSData dataWithContentsOfFile:file options:NSDataReadingMappedIfSafe error:nil];
    } else if (route[@"body"]) {
        body = [route[@"body"] dataUsingEncoding:NSUTF8StringEncoding];
    }
    body = body ?: [NSData data];
    outHeaders[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)body.length];
    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:req.URL statusCode:status
                                                         HTTPVersion:@"HTTP/1.1" headerFields:outHeaders];
    [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    const NSUInteger chunk = 4 << 20;
    for (NSUInteger offset = 0; offset < body.length && !_stopped; offset += chunk) {
        NSRange range = NSMakeRange(offset, MIN(chunk, body.length - offset));
        [self.client URLProtocol:self didLoadData:[body subdataWithRange:range]];
    }
    if (!_stopped) [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading { _stopped = YES; }
@end

static IMP origDefaultConfig, origEphemeralConfig;
static NSURLSessionConfiguration *WithProtocol(NSURLSessionConfiguration *config) {
    NSMutableArray *classes = [NSMutableArray arrayWithObject:SZUTURLProtocol.class];
    for (Class c in config.protocolClasses ?: @[]) if (c != SZUTURLProtocol.class) [classes addObject:c];
    config.protocolClasses = classes;
    return config;
}
static id DefaultConfig(id self, SEL _cmd) {
    return WithProtocol(((id (*)(id, SEL))origDefaultConfig)(self, _cmd));
}
static id EphemeralConfig(id self, SEL _cmd) {
    return WithProtocol(((id (*)(id, SEL))origEphemeralConfig)(self, _cmd));
}

#pragma mark - AppKit

// Arguments are taken as raw pointers: ARC must not retain a register that a no-argument selector left as garbage.
static void RefuseVoid(void *self, SEL _cmd, void *arg) {
    (void)self, (void)arg;
    SZLog(@{@"event" : @"refused", @"selector" : NSStringFromSelector(_cmd)});
}
static void RefuseVoid2(void *self, SEL _cmd, long a, long b) {
    (void)self, (void)a, (void)b;
    SZLog(@{@"event" : @"refused", @"selector" : NSStringFromSelector(_cmd)});
}
static BOOL RefuseBool(void *self, SEL _cmd, long arg) {
    (void)self, (void)arg;
    SZLog(@{@"event" : @"refused", @"selector" : NSStringFromSelector(_cmd)});
    return NO;
}
static BOOL YesActive(void *self, SEL _cmd) {
    (void)self, (void)_cmd;
    return YES;
}
static NSModalResponse AlertRunModal(NSAlert *self, SEL _cmd) {
    (void)_cmd;
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSButton *b in self.buttons) [buttons addObject:b.title ?: @""];
    SZLog(@{@"event" : @"alert", @"message" : self.messageText ?: @"", @"informative" : self.informativeText ?: @"",
            @"buttons" : buttons, @"answer" : buttons.firstObject ?: @"OK"});
    return NSAlertFirstButtonReturn;
}
static void AlertSheet(NSAlert *self, SEL _cmd, NSWindow *window, void (^handler)(NSModalResponse)) {
    (void)window;
    NSModalResponse r = AlertRunModal(self, _cmd);
    if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(r); });
}
static NSModalResponse RefuseModal(void *self, SEL _cmd, void *window) {
    (void)self, (void)window;
    SZLog(@{@"event" : @"refused", @"selector" : NSStringFromSelector(_cmd)});
    return NSModalResponseAbort;
}

static void DropDistributed4(void *self, SEL _cmd, NSString *name, void *object, void *info, long flag) {
    (void)self, (void)_cmd, (void)object, (void)info, (void)flag;
    SZLog(@{@"event" : @"distributed_notification_dropped", @"name" : name ?: @""});
}
static void DropDistributed2(void *self, SEL _cmd, NSString *name, void *object) {
    (void)self, (void)_cmd, (void)object;
    SZLog(@{@"event" : @"distributed_notification_dropped", @"name" : name ?: @""});
}

static IMP origRunningWithBundleID, origForceTerminate, origTerminate;
static NSArray *RunningWithBundleID(id self, SEL _cmd, NSString *bundleID) {
    NSArray *all = ((NSArray * (*)(id, SEL, NSString *)) origRunningWithBundleID)(self, _cmd, bundleID);
    NSMutableArray *ours = [NSMutableArray array];
    for (NSRunningApplication *app in all)
        if (UnderRoot(app.bundleURL.path) || UnderRoot(app.executableURL.path)) [ours addObject:app];
    if (ours.count != all.count)
        SZLog(@{@"event" : @"running_apps_filtered", @"bundle_id" : bundleID ?: @"", @"seen" : @(all.count),
                @"kept" : @(ours.count)});
    return ours;
}
static BOOL GuardedTerminate(NSRunningApplication *self, SEL _cmd) {
    if (!UnderRoot(self.bundleURL.path)) {
        SZLog(@{@"event" : @"refused_terminate", @"selector" : NSStringFromSelector(_cmd),
                @"bundle" : self.bundleURL.path ?: @""});
        return NO;
    }
    IMP orig = _cmd == @selector(forceTerminate) ? origForceTerminate : origTerminate;
    return ((BOOL (*)(id, SEL))orig)(self, _cmd);
}

@interface SZUTLaunchedApp : NSObject
@property(nonatomic, copy) NSURL *bundleURL;
@property(nonatomic, copy) NSURL *executableURL;
@property(nonatomic) pid_t processIdentifier;
@property(nonatomic, getter=isTerminated) BOOL terminated;
@property(nonatomic, getter=isFinishedLaunching) BOOL finishedLaunching;
@end
@implementation SZUTLaunchedApp
@end

static void OpenApplication(id self, SEL _cmd, NSURL *url, NSWorkspaceOpenConfiguration *config,
                            void (^handler)(NSRunningApplication *, NSError *)) {
    (void)self, (void)_cmd;
    SZLog(@{@"event" : @"relaunch_requested", @"url" : url.path ?: @"",
            @"new_instance" : @(config.createsNewApplicationInstance), @"under_root" : @(UnderRoot(url.path))});
    SZUTLaunchedApp *app = [SZUTLaunchedApp new];
    app.bundleURL = url;
    app.processIdentifier = -1;
    app.finishedLaunching = YES;
    if (handler) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        handler((NSRunningApplication *)app, nil);
    });
}
static BOOL RefuseOpenURL(id self, SEL _cmd, id url) {
    (void)self;
    SZLog(@{@"event" : @"refused", @"selector" : NSStringFromSelector(_cmd), @"arg" : [url description] ?: @""});
    return YES;
}
static void RefuseReveal(id self, SEL _cmd, id urls) {
    (void)self;
    SZLog(@{@"event" : @"refused", @"selector" : NSStringFromSelector(_cmd), @"arg" : [urls description] ?: @""});
}
static BOOL RefuseSelectFile(id self, SEL _cmd, NSString *path, NSString *root) {
    (void)self, (void)root;
    SZLog(@{@"event" : @"refused", @"selector" : NSStringFromSelector(_cmd), @"arg" : path ?: @""});
    return YES;
}

static IMP origTaskLaunchErr, origTaskLaunch;
static BOOL IsOpenTool(NSTask *task) {
    NSString *path = task.executableURL.path ?: task.launchPath;
    return [path isEqual:@"/usr/bin/open"];
}
static BOOL TaskLaunchErr(NSTask *self, SEL _cmd, NSError **error) {
    if (IsOpenTool(self)) {
        SZLog(@{@"event" : @"refused_open_tool", @"args" : self.arguments ?: @[]});
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:nil];
        return NO;
    }
    SZLog(@{@"event" : @"task", @"path" : self.executableURL.path ?: self.launchPath ?: @"", @"args" : self.arguments ?: @[]});
    return ((BOOL (*)(id, SEL, NSError **))origTaskLaunchErr)(self, _cmd, error);
}
static void TaskLaunch(NSTask *self, SEL _cmd) {
    if (IsOpenTool(self)) {
        SZLog(@{@"event" : @"refused_open_tool", @"args" : self.arguments ?: @[]});
        return;
    }
    SZLog(@{@"event" : @"task", @"path" : self.executableURL.path ?: self.launchPath ?: @"", @"args" : self.arguments ?: @[]});
    ((void (*)(id, SEL))origTaskLaunch)(self, _cmd);
}

static void Replace(const char *className, SEL selector, IMP imp, IMP *original) {
    Class cls = objc_getClass(className);
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, selector);
    if (!m) return;
    IMP old = class_replaceMethod(cls, selector, imp, method_getTypeEncoding(m));
    if (original && !*original) *original = old ?: method_getImplementation(m);
}
static void ReplaceClass(const char *className, SEL selector, IMP imp, IMP *original) {
    Class cls = objc_getClass(className);
    if (!cls) return;
    Class meta = object_getClass(cls);
    Method m = class_getClassMethod(cls, selector);
    if (!m) return;
    IMP old = class_replaceMethod(meta, selector, imp, method_getTypeEncoding(m));
    if (original && !*original) *original = old ?: method_getImplementation(m);
}

static void Install(void) {
    static const char *windows[] = {"NSWindow", "NSPanel", "GdkMacosWindow"};
    SEL orders[] = {@selector(orderFront:), @selector(makeKeyAndOrderFront:), @selector(orderBack:),
                    @selector(setIsVisible:), @selector(deminiaturize:), @selector(toggleFullScreen:)};
    for (size_t c = 0; c < 3; c++) {
        for (size_t s = 0; s < sizeof orders / sizeof *orders; s++) Replace(windows[c], orders[s], (IMP)RefuseVoid, NULL);
        Replace(windows[c], @selector(orderFrontRegardless), (IMP)RefuseVoid, NULL);
        Replace(windows[c], @selector(makeKeyWindow), (IMP)RefuseVoid, NULL);
        Replace(windows[c], @selector(makeMainWindow), (IMP)RefuseVoid, NULL);
        Replace(windows[c], @selector(orderWindow:relativeTo:), (IMP)RefuseVoid2, NULL);
    }
    Replace("GdkMacosWindow", sel_registerName("showAndMakeKey:"), (IMP)RefuseVoid, NULL);
    Replace("NSApplication", @selector(activateIgnoringOtherApps:), (IMP)RefuseVoid, NULL);
    Replace("NSApplication", sel_registerName("activate"), (IMP)RefuseVoid, NULL);
    Replace("NSApplication", @selector(unhide:), (IMP)RefuseVoid, NULL);
    Replace("NSApplication", @selector(unhideWithoutActivation), (IMP)RefuseVoid, NULL);
    Replace("NSApplication", @selector(setActivationPolicy:), (IMP)RefuseBool, NULL);
    Replace("NSApplication", @selector(requestUserAttention:), (IMP)RefuseBool, NULL);
    Replace("NSApplication", @selector(runModalForWindow:), (IMP)RefuseModal, NULL);
    Replace("NSApplication", @selector(isActive), (IMP)YesActive, NULL);
    Replace("NSRunningApplication", @selector(activateWithOptions:), (IMP)RefuseBool, NULL);
    Replace("NSAlert", @selector(runModal), (IMP)AlertRunModal, NULL);
    Replace("NSAlert", @selector(beginSheetModalForWindow:completionHandler:), (IMP)AlertSheet, NULL);
    Replace("NSDistributedNotificationCenter", @selector(postNotificationName:object:userInfo:deliverImmediately:),
            (IMP)DropDistributed4, NULL);
    Replace("NSDistributedNotificationCenter", @selector(postNotificationName:object:userInfo:options:),
            (IMP)DropDistributed4, NULL);
    Replace("NSDistributedNotificationCenter", @selector(postNotificationName:object:), (IMP)DropDistributed2, NULL);
    ReplaceClass("NSRunningApplication", @selector(runningApplicationsWithBundleIdentifier:),
                 (IMP)RunningWithBundleID, &origRunningWithBundleID);
    Replace("NSRunningApplication", @selector(forceTerminate), (IMP)GuardedTerminate, &origForceTerminate);
    Replace("NSRunningApplication", @selector(terminate), (IMP)GuardedTerminate, &origTerminate);
    Replace("NSWorkspace", @selector(openApplicationAtURL:configuration:completionHandler:), (IMP)OpenApplication,
            NULL);
    Replace("NSWorkspace", @selector(openURL:), (IMP)RefuseOpenURL, NULL);
    Replace("NSWorkspace", @selector(activateFileViewerSelectingURLs:), (IMP)RefuseReveal, NULL);
    Replace("NSWorkspace", @selector(selectFile:inFileViewerRootedAtPath:), (IMP)RefuseSelectFile, NULL);
    Replace("NSTask", @selector(launchAndReturnError:), (IMP)TaskLaunchErr, &origTaskLaunchErr);
    Replace("NSTask", @selector(launch), (IMP)TaskLaunch, &origTaskLaunch);
    ReplaceClass("NSURLSessionConfiguration", @selector(defaultSessionConfiguration), (IMP)DefaultConfig,
                 &origDefaultConfig);
    ReplaceClass("NSURLSessionConfiguration", @selector(ephemeralSessionConfiguration), (IMP)EphemeralConfig,
                 &origEphemeralConfig);
    [NSURLProtocol registerClass:SZUTURLProtocol.class];
}

#pragma mark - Interposed C calls

static OSStatus QuietTransform(const ProcessSerialNumber *psn, ProcessApplicationTransformState state) {
    (void)psn, (void)state;
    SZLog(@{@"event" : @"refused", @"selector" : @"TransformProcessType"});
    return noErr;
}
static OSStatus QuietRegister(CFURLRef url, Boolean update) {
    (void)update;
    SZLog(@{@"event" : @"refused_ls_register", @"url" : ((__bridge NSURL *)url).path ?: @""});
    return noErr;
}
static OSStatus NoCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    (void)query;
    if (result) *result = NULL;
    SZLog(@{@"event" : @"keychain_refused", @"call" : @"SecItemCopyMatching"});
    return errSecItemNotFound;
}
static OSStatus NoAdd(CFDictionaryRef attrs, CFTypeRef *result) {
    (void)attrs;
    if (result) *result = NULL;
    SZLog(@{@"event" : @"keychain_refused", @"call" : @"SecItemAdd"});
    return errSecInteractionNotAllowed;
}
static OSStatus NoUpdate(CFDictionaryRef query, CFDictionaryRef attrs) {
    (void)query, (void)attrs;
    SZLog(@{@"event" : @"keychain_refused", @"call" : @"SecItemUpdate"});
    return errSecInteractionNotAllowed;
}
static OSStatus NoDelete(CFDictionaryRef query) {
    (void)query;
    SZLog(@{@"event" : @"keychain_refused", @"call" : @"SecItemDelete"});
    return errSecItemNotFound;
}
static BOOL IsFriendsHelper(const char *path) { return path && strstr(path, "Shenzhen Friends") != NULL; }
static int GuardSpawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                      const posix_spawnattr_t *attrs, char *const argv[], char *const envp[]) {
    if (gActive && IsFriendsHelper(path)) {
        SZLog(@{@"event" : @"refused_friends_helper", @"path" : @(path)});
        return EPERM;
    }
    return posix_spawn(pid, path, actions, attrs, argv, envp);
}
static int GuardSpawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *actions,
                       const posix_spawnattr_t *attrs, char *const argv[], char *const envp[]) {
    if (gActive && IsFriendsHelper(file)) {
        SZLog(@{@"event" : @"refused_friends_helper", @"path" : @(file)});
        return EPERM;
    }
    return posix_spawnp(pid, file, actions, attrs, argv, envp);
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement, *original;
} szut_interposers[] = {
    {(const void *)QuietTransform, (const void *)TransformProcessType},
    {(const void *)QuietRegister, (const void *)LSRegisterURL},
    {(const void *)NoCopyMatching, (const void *)SecItemCopyMatching},
    {(const void *)NoAdd, (const void *)SecItemAdd},
    {(const void *)NoUpdate, (const void *)SecItemUpdate},
    {(const void *)NoDelete, (const void *)SecItemDelete},
    {(const void *)GuardSpawn, (const void *)posix_spawn},
    {(const void *)GuardSpawnp, (const void *)posix_spawnp},
};

__attribute__((constructor)) static void SZUTInit(void) {
    const char *root = getenv("SZUT_ROOT");
    char exe[PATH_MAX];
    uint32_t size = sizeof exe;
    if (!root || _NSGetExecutablePath(exe, &size) != 0) return;
    @autoreleasepool {
        gRoot = [@(root) stringByStandardizingPath];
        gRealRoot = gRoot.stringByResolvingSymlinksInPath;
        NSString *path = @(exe);
        BOOL ours = [path hasPrefix:gRoot] || [path hasPrefix:gRealRoot] ||
                    [path.stringByResolvingSymlinksInPath hasPrefix:gRealRoot];
        if (!ours) return; // hdiutil, ditto, xattr and the rest run untouched
        gActive = YES;
        const char *routes = getenv("SZUT_ROUTES");
        if (routes) {
            gRoutesDir = [@(routes) stringByDeletingLastPathComponent];
            NSData *data = [NSData dataWithContentsOfFile:@(routes)];
            id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            gRoutes = [obj isKindOfClass:NSDictionary.class] ? obj : @{};
        }
        Install();
        // GDK's window class and late AppKit classes load after this constructor: again once the app runs.
        dispatch_async(dispatch_get_main_queue(), ^{ Install(); });
        [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationWillFinishLaunchingNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification *note) {
                                                          (void)note;
                                                          Install();
                                                      }];
        NSMutableArray *args = [NSMutableArray array];
        for (NSString *a in NSProcessInfo.processInfo.arguments) [args addObject:a];
        SZLog(@{@"event" : @"inserted", @"args" : args});
    }
}
