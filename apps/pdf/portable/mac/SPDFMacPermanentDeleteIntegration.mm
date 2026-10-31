// Move to Trash and Remove from Collection (SPDFMacPermanentDeleteIntegration.h). Order matters: the files go first,
// then the Collection entries, then the tabs. A tab closed first would end this window's process when it was the last
// one, cutting the work short; and a Collection entry forgotten while its file is still there could be captured again.
// Until its tab closes, a tab whose file just went may show "File moved or deleted" for a moment, as for any deletion
// made elsewhere; Collection no longer offers to reopen it from history, since that history is gone too.
#import "SPDFMacPermanentDeleteIntegration.h"
#import "SPDFMacAIDocumentAvailability.h"
#import "SPDFMacCollectionPermanentDelete.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacCollectionThumbnailLoader.h"
#import "SPDFMacDocumentActivity.h"
#import "SPDFMacStateDirectory.h"
#import "SPDFMacUIHelpers.h"
#import <objc/runtime.h>
#include <unistd.h>

extern "C" BOOL spdf_is_sandboxed(void); // SPDFUpdater.mm
static NSString* const kDeletedElsewhere = @"com.intuition.shenzhenpdf.DocumentsDeletedPermanently";
static char kDeleteObserverKey;

@interface ShenzhenMacDelegate (SPDFMacPermanentDeleteHost)
- (NSInteger)indexOfTabForPath:(NSString*)path;
- (void)closeTabAtIndex:(NSInteger)index;
- (void)savePersistentState;
- (void)collectionRefreshHistory;
@end

@implementation ShenzhenMacDelegate (SPDFMacPermanentDelete)

- (void)addPermanentDeleteItemToMenu:(NSMenu*)menu path:(NSString*)path {
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem* item = [menu addItemWithTitle:@"Move to Trash and Remove from Collection…"
                                       action:@selector(removeFromDiskAndCollection:) keyEquivalent:@""];
    item.target = self;
    item.representedObject = path;
    NSInteger index = path.length ? [self indexOfTabForPath:path] : -1;
    SPDFDocumentTab* tab = index >= 0 ? _tabs[(NSUInteger)index] : nil;
    // Nothing on disk to move: a pasted image not saved yet, or a file already moved or deleted.
    item.enabled = path.length && !tab.unsavedPastedImage && !tab.missingFile;
    if (!item.enabled) item.action = nil;
    spdf_set_menu_item_system_symbol(item, @"trash");
}

- (void)removeFromDiskAndCollection:(id)sender {
    id chosen = [sender respondsToSelector:@selector(representedObject)] ? [sender representedObject] : nil;
    NSString* path = [chosen isKindOfClass:NSString.class] ? chosen : _path;
    if (!path.length) return;
    NSDictionary* targets = SPDFPermanentDeleteTargets(SPDFMacCollectionStore.defaultStore, @[ path ], @[]);
    __weak ShenzhenMacDelegate* weakSelf = self;
    SPDFPermanentDeleteAsk(_window, targets[@"names"], targets[@"files"], ^{
        [weakSelf permanentlyDeletePaths:@[ path ] documentIDs:@[] completion:nil];
    });
}

- (void)permanentlyDeletePaths:(NSArray<NSString*>*)paths documentIDs:(NSArray<NSString*>*)documentIDs
                    completion:(void (^)(NSArray<NSString*>*))completion {
    SPDFMacCollectionStore* store = SPDFMacCollectionStore.defaultStore;
    NSDictionary* targets = SPDFPermanentDeleteTargets(store, paths ?: @[], documentIDs ?: @[]);
    NSArray* names = targets[@"names"];
    NSUInteger trashed = 0;
    for (NSString* file in targets[@"files"]) trashed += SPDFPermanentDeleteTrashes(file);
    NSURL* thumbnails = SPDFCollectionThumbnailDirectory();
    _statusLabel.stringValue = trashed ? @"Moving to the Trash…" : @"Removing…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary* result = SPDFPermanentDeletePerform(targets, store, thumbnails);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDictionary* removed = result[@"removed"];
            NSArray* failures = result[@"failures"];
            // Told before this window's own tabs close: closing the last one may end this process.
            [self tellOtherWindowsDocumentsWereDeleted:removed];
            NSString* what = names.count == 1 ? [NSString stringWithFormat:@"“%@”", names.firstObject]
                                              : [NSString stringWithFormat:@"%lu documents", (unsigned long)names.count];
            NSString* done = [NSString stringWithFormat:trashed ? @"Moved %@ to the Trash." : @"Removed %@ from your Collection.",
                                                        what];
            self->_statusLabel.stringValue = failures.count ? @"" : done;
            [self collectionRefreshHistory];
            if (completion) completion(failures ?: @[]);
            else if (failures.count) [SPDFPermanentDeleteFailure(failures) beginSheetModalForWindow:self->_window
                                                                                  completionHandler:nil];
            [self forgetPermanentlyDeleted:removed];
        });
    });
}

// Closes this window's tabs of the removed documents, without a question (every change is already saved), and drops
// them from Recently Closed, recent files, the viewing dates and the assistant's open-document list.
- (void)forgetPermanentlyDeleted:(NSDictionary*)removed {
    NSMutableArray* gone = [NSMutableArray arrayWithArray:removed[@"matchPaths"] ?: @[]];
    for (SPDFDocumentTab* tab in _tabs)
        if (SPDFPermanentDeleteMatchesTab(removed, tab.path, tab.collectionHistoryDocumentID) && tab.path)
            [gone addObject:tab.path];
    if (!gone.count && ![removed[@"documentIDs"] count]) return;
    [_recentlyOpenedPaths removeObjectsInArray:gone];
    BOOL closed = NO;
    for (NSInteger index = (NSInteger)_tabs.count - 1; index >= 0; index--) {
        if (index >= (NSInteger)_tabs.count) continue;
        SPDFDocumentTab* tab = _tabs[(NSUInteger)index];
        if (!SPDFPermanentDeleteMatchesTab(removed, tab.path, tab.collectionHistoryDocumentID)) continue;
        BOOL last = _tabs.count == 1;
        [self closeTabAtIndex:index];
        closed = YES;
        // The window's last tab: it closes, and its process ends once this turn of the run loop is over.
        if (last) break;
    }
    [_closedDocumentPaths removeObjectsInArray:gone];
    // After the tabs closed: closing one stamps the time it was last viewed.
    [SPDFMacDocumentActivityStore.sharedStore forgetPaths:gone];
    [self aiDocumentsWereDeleted];
    if (!closed) [self savePersistentState];
}

- (void)tellOtherWindowsDocumentsWereDeleted:(NSDictionary*)removed {
    if (spdf_is_sandboxed() || (![removed[@"matchPaths"] count] && ![removed[@"documentIDs"] count])) return;
    NSMutableDictionary* info = [removed mutableCopy];
    info[@"from"] = @(getpid());
    // Scoped to this profile: a test profile's deletions never reach the person's own windows.
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:kDeletedElsewhere
                                                                 object:SPDFMacStateDirectoryPath()
                                                               userInfo:info
                                                     deliverImmediately:YES];
}

- (void)listenForPermanentDeletesInOtherWindows {
    if (objc_getAssociatedObject(self, &kDeleteObserverKey) || spdf_is_sandboxed()) return;
    __weak ShenzhenMacDelegate* weakSelf = self;
    id observer = [NSDistributedNotificationCenter.defaultCenter addObserverForName:kDeletedElsewhere
        object:SPDFMacStateDirectoryPath() queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification* note) {
            NSDictionary* removed = note.userInfo;
            if ([removed[@"from"] intValue] == getpid()) return;
            NSMutableDictionary* clean = [NSMutableDictionary dictionary];
            for (NSString* key in @[ @"matchPaths", @"matchPrefixes", @"documentIDs" ])
                clean[key] = [removed[key] isKindOfClass:NSArray.class] ? removed[key] : @[];
            [weakSelf forgetPermanentlyDeleted:clean];
        }];
    objc_setAssociatedObject(self, &kDeleteObserverKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
