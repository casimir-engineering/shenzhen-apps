// ShenzhenPDF's implementation of the Friends host adapter contract (portable/friends/mac/SZFriendsHost.h).
//
// The object answers the views; everything that needs the reader itself (its title bar, its tabs, opening a
// document through Collection consent and capture, Finder) goes through SPDFMacFriendsReaderBridge, which the
// reader's category implements (SPDFMacFriendsIntegration.mm). That keeps this file free of the coordinator, so
// its behaviour is tested headlessly with a fake bridge.

#import <AppKit/AppKit.h>
#import "mac/SZFriendsHost.h"
#import "SPDFMacFriendsRevision.h"

NS_ASSUME_NONNULL_BEGIN

@protocol SPDFMacFriendsReaderBridge <NSObject>
// The title bar: place the views' button between Groups and Search, or take it away again.
- (void)friendsBridgeInstallTitleBarButton:(NSView*)button;
- (void)friendsBridgeRemoveTitleBarButton:(NSView*)button;
// Open documents, most recently focused first, as tab dictionaries plus "inThisWindow" (main thread).
- (NSArray<NSDictionary*>*)friendsBridgeOpenDocuments;
- (id<SPDFMacFriendsCollectionLookup>)friendsBridgeCollectionLookup;
// Opens like a person's own open: tabs, Collection consent and capture (-[ShenzhenMacDelegate openPaths:]).
- (void)friendsBridgeOpenPaths:(NSArray<NSString*>*)paths;
- (void)friendsBridgeRevealFiles:(NSArray<NSURL*>*)fileURLs;
// Friends' exported services appeared (Cmd+K, citations, chat scopes) or went away (nil).
- (void)friendsBridgeServicesChanged:(nullable id<SZFriendsServices>)services;
- (SZFriendsAppearance*)friendsBridgeAppearance;
@optional
// Copy Download Link for one file, valid `days` (portable/friends/PROTOCOL.md § Links): the same path as File ▸ Share,
// with the result in the reader's status line. Absent: the drop panel offers no link.
- (void)friendsBridgeCopyDownloadLinkForItem:(SZFriendsAttachableItem*)item days:(NSInteger)days;
// The assistant for `/` in a friend's composer (SPDFMacFriendsAssistant.h); absent or nil hides `/`.
- (nullable id<SZFriendsAssistant>)friendsBridgeAssistant;
@end

@interface SPDFMacFriendsHost : NSObject <SZFriendsHost>
// `formats`: lowercase extensions ShenzhenPDF opens (SPDFReadableDocumentExtensions()).
- (instancetype)initWithBridge:(id<SPDFMacFriendsReaderBridge>)bridge bundle:(NSBundle*)bundle
                       formats:(NSSet<NSString*>*)formats NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly, nullable) id<SZFriendsServices> services;
// Where `#` items are resolved (they read and hash files). Default: a utility-QoS global queue.
@property(nonatomic) dispatch_queue_t attachQueue;
// The files a drag of reader tabs would send, unresolved and unhashed, links and folders included and gone files
// left out, for the views' drag verdict (proposed optional SZFriendsHost method; the host answers it already).
- (NSArray<NSURL*>*)friendsDraggedFileURLsFromPasteboard:(NSPasteboard*)pasteboard;
// The drop panel's "Copy link instead" shows the expiry choice through this (default: the menu pops up under `view`,
// which runs its own loop until it closes); tests answer it with an item of the menu, or nil for a dismissed one.
@property(nonatomic, copy) NSMenuItem* _Nullable (^presentExpiryMenu)(NSMenu* menu, NSView* view);
@end

NS_ASSUME_NONNULL_END
