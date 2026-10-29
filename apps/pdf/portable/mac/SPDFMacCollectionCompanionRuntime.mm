#import "SPDFMacCollectionCompanion.h"
#import "SPDFMacCollectionPipe.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacCollectionWindowPrivate.h"
#import "SPDFMacPassword.h"
#import "SPDFMacPasteboardOwnership.h"
#import <QuartzCore/QuartzCore.h>
static SPDFCollectionCompanionRuntime* activeRuntime;
@interface SPDFCollectionCompanionRuntime () <NSApplicationDelegate>
@property(nonatomic) SPDFCollectionPipe* pipe;
@property(nonatomic) SPDFMacCollectionWindow* manager;
@property(nonatomic) NSCondition* credentialsReady;
@property(nonatomic) NSMutableDictionary* credentialReplies;
@property(nonatomic) NSMutableSet* credentialRequests;
@end
@implementation SPDFCollectionCompanionRuntime
+ (instancetype)activeRuntime { return activeRuntime; }
- (instancetype)init {
    if ((self=[super init])) { _credentialsReady=[NSCondition new]; _credentialReplies=[NSMutableDictionary dictionary]; _credentialRequests=[NSMutableSet set]; }
    return self;
}
- (SPDFPasswordCredential*)credentialForPaths:(NSArray<NSString*>*)paths {
    // Invoked only by the thumbnail worker, never by the UI/launch thread.
    if (NSThread.isMainThread) return nil;
    NSString* request=NSUUID.UUID.UUIDString;
    [_credentialsReady lock]; [_credentialRequests addObject:request];
    if (![_pipe send:@{@"kind":@"credential",@"request":request,@"paths":paths}]) {
        [_credentialRequests removeObject:request]; [_credentialsReady unlock]; return nil;
    }
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:3];
    while (!_credentialReplies[request] && [_credentialsReady waitUntilDate:deadline]) {}
    id reply=_credentialReplies[request]; [_credentialReplies removeObjectForKey:request]; [_credentialRequests removeObject:request];
    [_credentialsReady unlock];
    return [reply isKindOfClass:NSString.class] ? [[SPDFPasswordCredential alloc] initWithPassword:reply] : nil;
}
- (void)receive:(NSDictionary*)message {
    if ([message[@"kind"] isEqual:@"credential"]) {
        NSString* request=message[@"request"];
        if (![request isKindOfClass:NSString.class]) return;
        [_credentialsReady lock];
        // Discard late replies rather than retaining a password after a timeout.
        if ([_credentialRequests containsObject:request]) _credentialReplies[request]=message[@"password"] ?: NSNull.null;
        [_credentialsReady broadcast]; [_credentialsReady unlock]; return;
    }
    if ([message[@"kind"] isEqual:@"refresh"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self.manager refreshFromStore]; });
        return;
    }
    if ([message[@"kind"] isEqual:@"destination"]) {
        // Explicit navigation from unified Settings also works in an already-open
        // companion; its saved/default destination must not override this action.
        if (![message[@"destination"] isEqual:@"Settings"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.manager showDestination:@"Settings"]; [self.manager persistManagerPreferences];
        });
        return;
    }
    if (![message[@"kind"] isEqual:@"show"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* root=message[@"root"];
        if (![root isKindOfClass:NSString.class] || !root.isAbsolutePath) return;
        if (!self.manager) {
            SPDFMacCollectionStore* store=[[SPDFMacCollectionStore alloc] initWithRootURL:[NSURL fileURLWithPath:root]];
            __weak SPDFCollectionCompanionRuntime* weakSelf=self;
            self.manager=[[SPDFMacCollectionWindow alloc] initWithStore:store open:^(NSString* path,BOOL archived) {
                [weakSelf.pipe send:@{@"kind":@"open",@"path":path,@"archived":@(archived)}];
            }];
            self.manager.returnHandler=^{ [weakSelf.pipe send:@{@"kind":@"activateReader"}]; };
            self.manager.navigateHandler=^(NSDictionary* document,NSDictionary* version,NSUInteger page,NSString* query,BOOL history) {
                [weakSelf.pipe send:@{@"kind":@"navigate",@"documentID":document[@"id"] ?: @"",
                    @"versionID":version[@"id"] ?: @"",@"page":@(page),@"query":query ?: @"",@"history":@(history)}];
            };
        }
        [self.manager showDocumentID:[message[@"documentID"] length] ? message[@"documentID"] : nil
                              query:[message[@"query"] isKindOfClass:NSString.class] ? message[@"query"] : nil];
        [NSApp activateIgnoringOtherApps:YES];
    });
}
- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;
    NSMenu* menu=[NSMenu new]; NSMenuItem* application=[NSMenuItem new]; [menu addItem:application];
    NSMenu* actions=[NSMenu new];
    [actions addItemWithTitle:@"Quit Collection" action:@selector(terminate:) keyEquivalent:@"q"];
    application.submenu=actions;
    NSMenuItem* edit=[NSMenuItem new]; edit.title=@"Edit"; [menu addItem:edit];
    NSMenu* editing=[[NSMenu alloc] initWithTitle:@"Edit"];
    NSArray* titles=@[@"Undo",@"Cut",@"Copy",@"Paste",@"Select All"];
    NSArray* selectors=@[@"undo:",@"cut:",@"copy:",@"paste:",@"selectAll:"];
    NSArray* keys=@[@"z",@"x",@"c",@"v",@"a"];
    for (NSUInteger index=0;index<titles.count;index++)
        [editing addItemWithTitle:titles[index] action:NSSelectorFromString(selectors[index]) keyEquivalent:keys[index]];
    edit.submenu=editing; NSApp.mainMenu=menu;
    self.pipe=[[SPDFCollectionPipe alloc] initWithReader:NSFileHandle.fileHandleWithStandardInput
                                                writer:NSFileHandle.fileHandleWithStandardOutput];
    __weak SPDFCollectionCompanionRuntime* weakSelf=self;
    self.pipe.messageHandler=^(NSDictionary* message) { [weakSelf receive:message]; };
    self.pipe.closedHandler=^{ dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; }); };
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsChanged:)
        name:@"SPDFCollectionSettingsChanged" object:nil];
    [self.pipe start];
}
- (void)applicationDidBecomeActive:(NSNotification*)notification {
    (void)notification; [self.manager reload:nil];
}
- (void)settingsChanged:(NSNotification*)notification {
    [_pipe send:@{@"kind":@"settings",@"storageLimitOnly":@([notification.userInfo[@"storageLimitOnly"] boolValue])}];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)application { (void)application; return YES; }
// Closing the window ends this process. AppKit's terminate held it ~330 ms in CFPasteboardResolveAllPromisedData,
// and a close soon after a scroll often left the window on screen for all of it: its order-out was not committed
// before terminate blocked the main thread. Off screen on a 310-document Collection, closing right after a scroll:
// window gone after ~20 ms or only with the process at ~370 ms (4 runs of 6), process gone ~370 ms. Now the window is
// committed off the screen first (managerWindowWillClose:), and the process saves the list's place and exits at
// once, as the reader's quit does (SPDFMacQuitFinishing.mm).
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)application {
    // Quit Collection with the window open: transparent at once, as a close does (managerWindowWillClose:).
    NSArray<NSWindow*>* shown = [application.windows filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"visible == YES"]];
    for (NSWindow* window in shown) window.alphaValue = 0;
    [CATransaction flush];
    for (NSWindow* window in shown) [window orderOut:nil];
    if (spdf_mac_general_pasteboard_may_hold_our_data()) return NSTerminateNow;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.manager) dispatch_sync(self.manager.preferenceQueue, ^{}); // the browse state written on close
        [self.pipe close];
        exit(0);
    });
    return NSTerminateLater;
}
- (void)applicationWillTerminate:(NSNotification*)notification { (void)notification; [_pipe close]; }
@end
int SPDFRunCollectionCompanion(void) {
    @autoreleasepool {
        NSApplication* app=NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        activeRuntime=[SPDFCollectionCompanionRuntime new]; app.delegate=activeRuntime;
        [app run]; activeRuntime=nil; return 0;
    }
}
