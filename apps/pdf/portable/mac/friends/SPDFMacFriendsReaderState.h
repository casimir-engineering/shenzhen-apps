// Private to the host adapter's reader categories: one window's Friends objects, kept on the coordinator as an
// associated object so the capped SPDFMacDelegatePrivate.h gains no ivar.

#import "SPDFMacFriendsIntegration.h"
#import "mac/SZFriendsHost.h"
#import "mac/SZFriendsHelperLink.h"
#import "mac/SZFriendsDropdownController.h"
#import "mac/SZFriendsSettingsSection.h"
#import "SPDFMacFriendsChatScope.h"
#import "SPDFMacFriendsCollectionSource.h"
#import "SPDFMacFriendsComposerText.h"
#import "SPDFMacFriendsComposerScope.h"
#import "SPDFMacFriendsGrantBar.h"
#import "SPDFMacFriendsHost.h"
#import "SPDFMacFriendsLaunch.h"
#import "SPDFMacFriendsSendProvider.h"
#import "SPDFMacFriendsSettingsPane.h"
#import "SPDFMacFriendsTitleBar.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMacFriendsReaderState : NSObject
@property(nonatomic) SPDFMacFriendsLifecycle* lifecycle;
// Present only while attached (Friends on, after first paint).
@property(nonatomic, nullable) SPDFMacFriendsHost* host;
@property(nonatomic, nullable) SZFriendsHelperLink* link;
@property(nonatomic, nullable) SZFriendsDropdownController* dropdown;
@property(nonatomic, nullable) SZFriendsSettingsSection* settingsSection;
@property(nonatomic, nullable) SPDFMacFriendsTitleBarPlacement* placement;
// Search's hidden state is mirrored onto the Friends button (presentation mode hides the title-bar actions).
@property(nonatomic, nullable) NSButton* searchButton;
@property(nonatomic, nullable) id<SZFriendsServices> services;
@property(nonatomic, nullable) SPDFMacFriendsCollectionSource* collection;
@property(nonatomic, nullable) id settingsObserver;
// The AI chat's pieces; created with the chat, whether or not Friends is on.
@property(nonatomic, nullable) SPDFMacFriendsChatScopeGate* gate;
@property(nonatomic, nullable) SPDFMacFriendsChatRequestScoper* scoper;
@property(nonatomic, nullable) SPDFMacFriendsComposerScope* composerScope;
// The bar over the AI chat while the assistant may read all Friends chats for a while; the grant itself is the
// gate's (SPDFMacFriendsChatGrant.h), in memory only.
@property(nonatomic, nullable) SPDFMacFriendsGrantBar* grantBar;
// The assistant behind `/` in friend conversations (SPDFMacFriendsSendIntegration.mm), made when hello first asks.
@property(nonatomic, nullable) id<SZFriendsAssistant> slashAssistant;
// The AI chat's friends_send_message provider: its cards outlive requests, so the chat hands it every change
// (SPDFMacFriendsAssistantIntegration.mm) to give a reopened card back its Send, Discard and Show.
@property(nonatomic, nullable) SPDFMacFriendsSendProvider* chatSendProvider;
// A link opened before the dropdown existed (a launch by the link, or Friends just turned on), shown once it does.
@property(nonatomic, copy, nullable) NSString* pendingLinkPayload;
// The target of the Copy Download Link items (SPDFMacFriendsLinkIntegration.mm); menu items hold targets weakly.
@property(nonatomic, nullable) id shareTarget;
- (void)stopMirroringSearch;
@end

// SPDFMacFriendsIntegration.mm: the state, the host adapter's bridge and the Settings pane's source.
@interface ShenzhenMacDelegate (SPDFMacFriendsState) <SPDFMacFriendsReaderBridge, SPDFMacFriendsSettingsPaneSource>
- (SPDFMacFriendsReaderState*)friendsState;
@end

// SPDFMacFriendsAssistantIntegration.mm.
@interface ShenzhenMacDelegate (SPDFMacFriendsAssistantState)
- (SPDFMacFriendsChatScopeGate*)friendsGate;
// Services, link readiness or capabilities changed: the `@` picker follows.
- (void)friendsAssistantAvailabilityDidChange;
@end

// SPDFMacFriendsLinkIntegration.mm: links (portable/friends/PROTOCOL.md § Links).
@interface ShenzhenMacDelegate (SPDFMacFriendsLinks)
// URLs the system hands the app: documents go on to -application:openFiles:, shenzhenpdf: links are checked here.
- (void)application:(NSApplication*)application openURLs:(NSArray<NSURL*>*)urls;
- (void)friendsShowPendingLink;
- (void)friendsInstallShareMenu;
- (void)friendsRemoveShareMenu;
- (void)friendsAddItemsToTabMenu:(NSMenu*)menu path:(NSString*)path;
- (void)friendsBridgeCopyDownloadLinkForItem:(SZFriendsAttachableItem*)item days:(NSInteger)days;
@end

NS_ASSUME_NONNULL_END
