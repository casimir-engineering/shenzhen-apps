#import "SPDFMacDocumentOpening.h"
#import "SPDFMacOpenRouting.h"
#import "SPDFMacTabGroupIntegration.h"
#import <objc/runtime.h>
#include <unistd.h>

extern "C" BOOL spdf_is_sandboxed(void); // SPDFUpdater.mm
void spdf_launch_profile_log(NSString* format, ...) NS_FORMAT_FUNCTION(1, 2);

@interface ShenzhenMacDelegate (SPDFMacDocumentOpeningHost)
- (void)retargetLaunchPrerenderToOpenedPath:(NSString*)path;
- (id)stateObjectFromFile:(NSString*)name;
- (NSArray<NSRunningApplication*>*)otherRunningShenzhenApplications;
- (NSInteger)indexOfTabForPath:(NSString*)path;
- (SPDFDocumentTab*)newTabForPath:(NSString*)path;
- (void)captureSecurityBookmarkForPath:(NSString*)path;
- (void)collectionWillOpenPaths:(NSArray<NSString*>*)paths;
- (void)collectionDidOpenPath:(NSString*)path;
- (void)aiDocumentDidOpen:(NSString*)path;
- (void)loadSelectedTab;
- (BOOL)hasActiveDocument;
- (void)ensureActiveMarkdownTabHasContent;
- (void)rememberRecentlyOpenedPath:(NSString*)path;
- (void)focusActiveDocumentViewAfterTabSelection;
- (void)rememberActiveTabState;
- (void)selectTabAtIndex:(NSInteger)index;
- (void)savePersistentState;
- (void)finishTabGroupChange;
- (NSDictionary*)aiNavigateDocument:(NSString*)path page:(NSInteger)page;
@end

static char kSPDFShowDocumentObserverKey, kSPDFPendingHandOffsKey;

@implementation ShenzhenMacDelegate (SPDFMacDocumentOpening)

- (BOOL)application:(NSApplication*)sender openFile:(NSString*)filename {
    (void)sender;
    if (!_uiReady) {
        if (!_pendingOpenPath.length) _pendingOpenPath = [filename copy];
        if (filename.length && ![_pendingOpenPaths containsObject:filename]) [_pendingOpenPaths addObject:filename];
        [self retargetLaunchPrerenderToOpenedPath:_pendingOpenPath];
        return YES;
    }
    if ([self canOpenDocumentAtPath:filename showError:YES]) [self showDocumentsAtPaths:@[ filename ]];
    else [self activateWindowForExternalOpen];
    return YES;
}

- (void)application:(NSApplication*)application openFiles:(NSArray<NSString*>*)filenames {
    (void)application;
    spdf_launch_profile_log(@"application:openFiles: uiReady=%d n=%lu", (int)_uiReady, (unsigned long)filenames.count);
    if (filenames.count > 0) {
        if (!_uiReady) {
            _pendingOpenPath = [filenames.firstObject copy];
            [_pendingOpenPaths addObjectsFromArray:filenames];
            // This is the launch's real target — the prerender was started from
            // main() before the Apple Event arrived and is aimed at the wrong
            // document until now. -performStartupDocumentWork opens
            // _pendingOpenPath first, so that is the one to prewarm.
            [self retargetLaunchPrerenderToOpenedPath:_pendingOpenPath];
        } else {
            NSArray<NSString*>* pathsToOpen = [self openableDocumentPathsFromPaths:filenames showErrors:YES];
            if (pathsToOpen.count) [self showDocumentsAtPaths:pathsToOpen];
            else [self activateWindowForExternalOpen];
        }
    }
    [NSApp replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

- (void)openPaths:(NSArray<NSString*>*)paths {
    if (!_uiReady || !_window) {
        if (paths.count > 0) _pendingOpenPath = [paths.firstObject copy];
        for (NSString* path in paths) {
            if (path.length && ![_pendingOpenPaths containsObject:path]) [_pendingOpenPaths addObject:path];
        }
        return;
    }

    if (paths.count == 0) return;
    if (!_suspendPersistentStateSaves) {
        [self performWithBatchedPersistentStateSaves:^{
          [self openPaths:paths];
        }];
        return;
    }

    [self rememberActiveTabState]; [self collectionWillOpenPaths:paths];
    NSInteger targetIndex = -1;
    for (NSString* path in paths) {
        if (![path isKindOfClass:NSString.class] || path.length == 0) continue;
        [self captureSecurityBookmarkForPath:path];
        NSInteger existing = [self indexOfTabForPath:path];
        if (existing >= 0) {
            targetIndex = existing;
            continue;
        }
        SPDFDocumentTab* tab = [self newTabForPath:path];
        targetIndex = [self appendNewTabToActiveGroup:tab];
    }

    if (targetIndex >= 0) {
        // Reopening a document from Finder while the strip browses another group,
        // or while its group is hidden, left the strip showing the wrong group and
        // the document's tab out of sight. An open always shows its own tab.
        BOOL revealed = spdf_tab_groups_reveal(_tabs, _tabs[(NSUInteger)targetIndex]);
        if (targetIndex == _selectedTabIndex && [self hasActiveDocument]) {
            // A stranded Loading markdown session still counts as an active
            // document: re-kick it instead of early-returning into the strand.
            SPDFDocumentTab* existingTab = [self selectedTab];
            if (existingTab.readOnly && existingTab.workingPath.length && !existingTab.readOnlyCopyBinding.count)
                [self loadSelectedTab]; // Explicit reopen renews legacy provenance after launch.
            else {
                [self ensureActiveMarkdownTabHasContent];
                [self collectionDidOpenPath:_path];
                [self aiDocumentDidOpen:_path];
            }
            if (_path.length > 0) [self rememberRecentlyOpenedPath:_path];
            if (revealed) [self finishTabGroupChange];
            else [self savePersistentState];
            [self focusActiveDocumentViewAfterTabSelection];
            return;
        }
        [self selectTabAtIndex:targetIndex];
        if ([self hasActiveDocument] && _path.length > 0) [self rememberRecentlyOpenedPath:_path];
        if (revealed) [self finishTabGroupChange];
        else [self savePersistentState];
    }
}

- (void)openPath:(NSString*)path {
    if (!path.length) return;
    [self openPaths:@[ path ]];
}

- (void)openRecentDocument:(id)sender {
    if (![sender isKindOfClass:NSMenuItem.class]) return;
    NSString* path = ((NSMenuItem*)sender).representedObject;
    if (![path isKindOfClass:NSString.class] || path.length == 0) return;
    [self showDocumentsAtPaths:@[ path ]];
}

- (void)showDocumentsAtPaths:(NSArray<NSString*>*)paths {
    NSMutableArray<NSString*>* here = [NSMutableArray array];
    for (NSString* path in paths) {
        if (![path isKindOfClass:NSString.class] || !path.length) continue;
        pid_t owner = [self indexOfTabForPath:path] >= 0 ? 0 : [self otherWindowProcessShowingPath:path];
        if (owner > 0 && [self handOffDocumentAtPath:path page:nil toProcess:owner]) continue;
        [here addObject:path];
    }
    if (!here.count) return;
    [self openPaths:here];
    // The request may come from Finder, the Dock or the assistant's window:
    // the document's window is the one that must end up in front.
    [self activateWindowForExternalOpen];
}

- (void)showDocumentAtPath:(NSString*)path page:(NSNumber*)page {
    if (![path isKindOfClass:NSString.class] || !path.length) return;
    pid_t owner = [self indexOfTabForPath:path] >= 0 ? 0 : [self otherWindowProcessShowingPath:path];
    if (owner > 0 && [self handOffDocumentAtPath:path page:page toProcess:owner]) return;
    [self openDocumentHereAtPath:path page:page];
}

- (void)openDocumentHereAtPath:(NSString*)path page:(NSNumber*)page {
    [self openPaths:@[ path ]];
    if (page.integerValue >= 1 && [[self selectedTab].path isEqual:path])
        [self aiNavigateDocument:path page:page.integerValue];
    [self activateWindowForExternalOpen];
}

- (pid_t)otherWindowProcessShowingPath:(NSString*)path {
    // A sandboxed build cannot carry the path to another process.
    if (spdf_is_sandboxed()) return 0;
    NSArray<NSRunningApplication*>* others = [self otherRunningShenzhenApplications];
    if (!others.count) return 0; // The usual single window reads nothing.
    NSMutableSet<NSNumber*>* running = [NSMutableSet set];
    for (NSRunningApplication* app in others) [running addObject:@(app.processIdentifier)];
    return SPDFMacOtherWindowShowingPath([self stateObjectFromFile:@"session.yaml"], path, getpid(),
                                         ^BOOL(pid_t pid) { return [running containsObject:@(pid)]; });
}

- (NSMutableDictionary<NSString*, NSDictionary*>*)pendingShowDocumentHandOffs {
    NSMutableDictionary* pending = objc_getAssociatedObject(self, &kSPDFPendingHandOffsKey);
    if (!pending) {
        pending = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &kSPDFPendingHandOffsKey, pending, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return pending;
}

- (NSTimeInterval)showDocumentHandOffTimeout { return 1.5; }

- (BOOL)handOffDocumentAtPath:(NSString*)path page:(NSNumber*)page toProcess:(pid_t)pid {
    [self listenForDocumentsOpenedInOtherWindows]; // the answer arrives through the same listener
    NSString* requestID = NSUUID.UUID.UUIDString;
    NSMutableDictionary* request =
        [@{@"pid" : @(pid), @"path" : path, @"request" : requestID, @"from" : @(getpid())} mutableCopy];
    if (page) request[@"page"] = page;
    if (![self sendShowDocumentRequest:request toProcess:pid]) return NO;
    [self pendingShowDocumentHandOffs][requestID] = request;
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([self showDocumentHandOffTimeout] * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [weakSelf showDocumentHandOffTimedOut:requestID]; });
    return YES;
}

// The other window did not answer: it may be busy or gone without its session
// entry being cleared. The reader asked for the document, so it opens here.
- (void)showDocumentHandOffTimedOut:(NSString*)requestID {
    NSDictionary* request = [self pendingShowDocumentHandOffs][requestID];
    if (!request) return;
    [[self pendingShowDocumentHandOffs] removeObjectForKey:requestID];
    [self openDocumentHereAtPath:request[@"path"] page:SPDFMacShowDocumentRequestPage(request)];
}

- (void)handleShowDocumentConfirmation:(NSDictionary*)userInfo {
    NSString* requestID = SPDFMacShowDocumentConfirmedRequest(userInfo, getpid());
    if (requestID) [[self pendingShowDocumentHandOffs] removeObjectForKey:requestID];
}

- (BOOL)sendShowDocumentRequest:(NSDictionary*)userInfo toProcess:(pid_t)pid {
    NSRunningApplication* owner = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!owner) return NO;
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:SPDFMacShowDocumentNotification
                                                                 object:nil
                                                               userInfo:userInfo
                                                     deliverImmediately:YES];
    // macOS activated this process for the open; pass that on so the owning
    // window can come to the front instead of being refused as a background app.
    if (@available(macOS 14.0, *)) [NSApp yieldActivationToApplication:owner];
    [owner activateWithOptions:0];
    return YES;
}

- (void)sendShowDocumentConfirmation:(NSDictionary*)userInfo {
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:SPDFMacShowDocumentConfirmedNotification
                                                                 object:nil
                                                               userInfo:userInfo
                                                     deliverImmediately:YES];
}

- (void)listenForDocumentsOpenedInOtherWindows {
    if (objc_getAssociatedObject(self, &kSPDFShowDocumentObserverKey) || spdf_is_sandboxed()) return;
    __weak ShenzhenMacDelegate* weakSelf = self;
    NSDistributedNotificationCenter* center = NSDistributedNotificationCenter.defaultCenter;
    id observer = [center addObserverForName:SPDFMacShowDocumentNotification
                                      object:nil
                                       queue:NSOperationQueue.mainQueue
                                  usingBlock:^(NSNotification* note) {
                                    [weakSelf handleShowDocumentRequest:note.userInfo];
                                  }];
    id answers = [center addObserverForName:SPDFMacShowDocumentConfirmedNotification
                                     object:nil
                                      queue:NSOperationQueue.mainQueue
                                 usingBlock:^(NSNotification* note) {
                                   [weakSelf handleShowDocumentConfirmation:note.userInfo];
                                 }];
    objc_setAssociatedObject(self, &kSPDFShowDocumentObserverKey, @[ observer, answers ],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)handleShowDocumentRequest:(NSDictionary*)userInfo {
    NSString* path = SPDFMacShowDocumentRequestPath(userInfo, getpid());
    if (!path) return;
    id from = userInfo[@"from"], request = userInfo[@"request"];
    if ([from respondsToSelector:@selector(intValue)] && [request isKindOfClass:NSString.class])
        [self sendShowDocumentConfirmation:@{@"pid" : @([from intValue]), @"request" : request}];
    // The tab may have closed since the other window looked; then it opens here.
    if ([self indexOfTabForPath:path] < 0 && ![self canOpenDocumentAtPath:path showError:YES]) return;
    [self openDocumentHereAtPath:path page:SPDFMacShowDocumentRequestPage(userInfo)];
}

@end
