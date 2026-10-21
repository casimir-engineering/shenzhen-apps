#import "SPDFMacFriendsHost.h"
#import "SPDFMacFriendsAttachItems.h"
#import "SPDFMacFriendsLaunch.h"
#import "SPDFMacFriendsShareMenu.h"
#import "SPDFMacFriendsTabPasteboard.h"
#import "SPDFMacStateDirectory.h"
#include <sys/stat.h>

// Records which expiry the person picked from the menu popped up under "Copy link instead".
@interface SPDFMacFriendsExpiryChoice : NSObject
@property(nonatomic, strong) NSMenuItem* chosen;
@end

@implementation SPDFMacFriendsExpiryChoice
- (void)choose:(NSMenuItem*)sender {
    self.chosen = sender;
}
@end

@implementation SPDFMacFriendsHost {
    __weak id<SPDFMacFriendsReaderBridge> _bridge;
    NSBundle* _bundle;
    NSSet<NSString*>* _formats;
    id<SZFriendsServices> _services;
}

- (instancetype)initWithBridge:(id<SPDFMacFriendsReaderBridge>)bridge bundle:(NSBundle*)bundle
                       formats:(NSSet<NSString*>*)formats {
    if (!(self = [super init])) return nil;
    _bridge = bridge;
    _bundle = bundle;
    NSMutableSet* lowercase = [NSMutableSet set];
    for (NSString* format in formats) [lowercase addObject:format.lowercaseString];
    _formats = [lowercase copy];
    _attachQueue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    _presentExpiryMenu = ^NSMenuItem*(NSMenu* menu, NSView* view) {
        SPDFMacFriendsExpiryChoice* choice = [SPDFMacFriendsExpiryChoice new];
        for (NSMenuItem* item in menu.itemArray) {
            item.target = choice;
            item.action = @selector(choose:);
        }
        [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(view.bounds) + 4) inView:view];
        return choice.chosen;
    };
    return self;
}

#pragma mark - Identity (hello.client)

- (NSString*)friendsAppID { return _bundle.bundleIdentifier ?: @"com.intuition.shenzhenpdf"; }
- (NSString*)friendsAppName { return @"ShenzhenPDF"; }
- (NSString*)friendsAppVersion { return [_bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0"; }
- (NSString*)friendsRevealInName { return @"Finder"; }
// Where a Friends notification's click opens this app: shenzhenpdf://friends/conversation/<id> (Info.plist registers it).
- (NSString*)friendsURLScheme { return @"shenzhenpdf"; }
// Empty when this build embeds no helper (a development build), so the client library has nothing to spawn.
- (NSString*)friendsHelperPath { return SPDFMacFriendsHelperExecutablePath(_bundle) ?: @""; }

#pragma mark - Placement

- (void)friendsInstallButton:(NSView*)button { [_bridge friendsBridgeInstallTitleBarButton:button]; }
- (void)friendsRemoveButton:(NSView*)button { [_bridge friendsBridgeRemoveTitleBarButton:button]; }

#pragma mark - Drag and drop

- (NSArray<NSPasteboardType>*)friendsExtraPasteboardTypes { return @[SPDFMacFriendsTabPasteboardType]; }

- (NSArray<SZFriendsAttachableItem*>*)friendsItemsFromPasteboard:(NSPasteboard*)pasteboard {
    NSArray* tabs = SPDFMacFriendsTabDictionariesFromPasteboard(pasteboard);
    if (!tabs.count) return @[];
    return SPDFMacFriendsItemsForTabs(tabs, [_bridge friendsBridgeCollectionLookup], SPDFMacFriendsMainThreadHashLimit,
                                      NSDate.date, SPDFMacStateDirectoryPath());
}

// For the views' drag verdict: the tabs' files unresolved, so a tab whose file is a link is refused with
// drop_not_a_file instead of saying "Send to Mei" and then sending nothing (SPDFMacFriendsHost.h).
- (NSArray<NSURL*>*)friendsDraggedFileURLsFromPasteboard:(NSPasteboard*)pasteboard {
    NSMutableArray* urls = [NSMutableArray array];
    NSArray* tabs = SPDFMacFriendsTabDictionariesFromPasteboard(pasteboard);
    for (NSString* file in SPDFMacFriendsDraggedTabFiles(tabs, SPDFMacStateDirectoryPath()))
        [urls addObject:[NSURL fileURLWithPath:file isDirectory:NO]];
    return urls;
}

- (BOOL)friendsButtonAcceptsDrag:(id<NSDraggingInfo>)draggingInfo {
    NSPasteboard* pasteboard = draggingInfo.draggingPasteboard;
    NSArray* files =
        [@[NSPasteboardTypeFileURL] arrayByAddingObjectsFromArray:NSFilePromiseReceiver.readableDraggedTypes];
    if ([pasteboard availableTypeFromArray:files]) return YES;
    // A tab drag the strip cannot resolve to a file (an empty group) has nothing to send.
    return SPDFMacFriendsPasteboardHasSendableTabs(pasteboard);
}

#pragma mark - `#`

- (NSString*)friendsAttachPlaceholder { return SPDFMacFriendsAttachPlaceholder; }

- (void)friendsAttachableItemsMatching:(NSString*)query
                            completion:(void (^)(NSArray<SZFriendsAttachableItem*>* items))completion {
    id<SPDFMacFriendsReaderBridge> bridge = _bridge;
    // The tab list is read here on the main thread, where the reader owns it; reading and hashing happen off it.
    NSArray* open = [bridge friendsBridgeOpenDocuments] ?: @[];
    id<SPDFMacFriendsCollectionLookup> lookup = [bridge friendsBridgeCollectionLookup];
    NSString* text = [query copy] ?: @"";
    void (^done)(NSArray*) = [completion copy];
    dispatch_async(self.attachQueue, ^{
        NSArray* items = SPDFMacFriendsAttachItems(text, open, lookup, NSDate.date);
        dispatch_async(dispatch_get_main_queue(), ^{ done(items); });
    });
}

#pragma mark - Received files

- (NSSet<NSString*>*)friendsFormatsOpenedInPlace { return _formats; }

- (void)friendsOpenReceivedFileAtURL:(NSURL*)fileURL {
    struct stat st = {};
    if (!fileURL.isFileURL || stat(fileURL.fileSystemRepresentation, &st) != 0) return;
    // Open applies only to formats ShenzhenPDF reads; anything else, and any folder, is shown in Finder instead of
    // being handed to a reader that would fail on it.
    if (!S_ISREG(st.st_mode) || ![_formats containsObject:fileURL.pathExtension.lowercaseString]) {
        [_bridge friendsBridgeRevealFiles:@[fileURL]];
        return;
    }
    [_bridge friendsBridgeOpenPaths:@[fileURL.path]];
}

- (void)friendsRevealFileAtURL:(NSURL*)fileURL {
    if (fileURL.isFileURL) [_bridge friendsBridgeRevealFiles:@[fileURL]];
}

#pragma mark - Appearance and services

#pragma mark - Download links

- (NSString*)friendsCopyLinkInsteadLabel {
    return [_bridge respondsToSelector:@selector(friendsBridgeCopyDownloadLinkForItem:days:)]
               ? SPDFMacFriendsCopyLinkInsteadTitle : @"";
}

- (void)friendsOfferDownloadLinkForItem:(SZFriendsAttachableItem*)item fromView:(NSView*)view {
    id<SPDFMacFriendsReaderBridge> bridge = _bridge;
    if (![bridge respondsToSelector:@selector(friendsBridgeCopyDownloadLinkForItem:days:)] || !self.presentExpiryMenu)
        return;
    NSMenuItem* chosen = self.presentExpiryMenu(SPDFMacFriendsExpiryMenu(self, nil, item), view);
    NSInteger days = SPDFMacFriendsExpiryDays(chosen);
    if (days) [bridge friendsBridgeCopyDownloadLinkForItem:item days:days];
}

- (SZFriendsAppearance*)friendsAppearance { return [_bridge friendsBridgeAppearance] ?: [SZFriendsAppearance new]; }

- (id<SZFriendsServices>)services { return _services; }

- (void)friendsServicesDidBecomeAvailable:(id<SZFriendsServices>)services {
    _services = services;
    [_bridge friendsBridgeServicesChanged:services];
}

- (void)friendsServicesDidBecomeUnavailable {
    _services = nil;
    [_bridge friendsBridgeServicesChanged:nil];
}

// The AI tool layer registers Friends tools for scoped requests (SPDFMacFriendsChatTools.h), so chat access is
// real here; hello then carries "assistant.chats".
- (BOOL)friendsAssistantReadsChats { return YES; }

// `/` in a friend's composer: the reader's assistant, which drafts and, when asked, sends to that friend (hello then
// carries "assistant.drafts", which also lets the assistant's sends carry via_assistant).
- (id<SZFriendsAssistant>)friendsAssistant {
    id<SPDFMacFriendsReaderBridge> bridge = _bridge;
    return [bridge respondsToSelector:@selector(friendsBridgeAssistant)] ? [bridge friendsBridgeAssistant] : nil;
}

@end
