// Shenzhen Friends dropdown: the title-bar button and the one popover that holds everything Friends shows.
//
// AppKit views only. They render snapshots from the helper and send intents; they hold no sorting, labelling
// or state logic beyond rendering (brief § Containment and porting). Layout (brief § Interface):
//   - a two-people button (never a speech bubble, which is AI chat) with the badge the helper counts;
//   - one dropdown about 400 pt wide, as tall as the window allows up to 640 pt, holding a stack of views:
//     list (Friends / Nearby) -> conversation -> friend details, list -> profile, or list -> join;
//   - every view below the list has a back arrow at the top left (Cmd+[ too) and its title centered;
//   - Escape closes the innermost `#` picker first, then the dropdown, and never navigates back;
//   - semi-transient: it stays open while another app is active, so files can be dragged in from Finder or
//     Shenzhen Files, and closes on Escape, a click on the button or a click in the window;
//   - reopening returns to the view left, with drafts and scroll position kept (in this process).

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol SZFriendsHost;
@class SZFriendsHelperLink;
@class SZFriendsAttachableItem;

typedef NS_ENUM(NSInteger, SZFriendsDropdownView) {
    SZFriendsDropdownViewList = 0,
    SZFriendsDropdownViewNearby = 1,
    SZFriendsDropdownViewConversation = 2,
    SZFriendsDropdownViewDetails = 3,
    SZFriendsDropdownViewProfile = 4,
    SZFriendsDropdownViewLink = 5, // what a friend or download link says (PROTOCOL.md § Links)
    SZFriendsDropdownViewJoin = 6, // a new computer joining the person's profile (PROTOCOL.md § Joining)
};

@interface SZFriendsDropdownController : NSObject
- (instancetype)initWithHost:(id<SZFriendsHost>)host link:(SZFriendsHelperLink *)link NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// The title-bar button: icon, badge from the `badge` view, and drop target. Spring-loads while a drag hovers
// (opens the list so the drop can land on a row); a drop on the button itself opens "Send 2 files to…" and
// sends to the friend clicked next.
@property(nonatomic, readonly) NSButton *button;

// Creates the button and hands it to -[SZFriendsHost friendsInstallButton:]; subscribes to the badge, and starts
// the link if the host has not started it yet.
- (void)install;
// Friends disabled: closes the dropdown, removes the button, drops every subscription.
- (void)uninstall;

@property(nonatomic, readonly, getter=isShown) BOOL shown;
@property(nonatomic, readonly) SZFriendsDropdownView currentView;
- (void)toggle;
- (void)close;
// Opens the dropdown on a conversation with the message highlighted (Cmd+K results, assistant citations).
- (void)showConversation:(NSString *)conversationID highlightMessage:(nullable NSString *)messageID;
// Opens the list in "Send N files to…" mode; the next friend clicked receives one offer per item. Escape cancels.
- (void)beginSendPickerWithItems:(NSArray<SZFriendsAttachableItem *> *)items;

// Links (PROTOCOL.md § Links). YES while the helper answers and announces `links`: only then may a host show its link
// items (Copy Download Link) or hand the views a link.
@property(nonatomic, readonly) BOOL offersLinks;
// Opens the dropdown on the link page for a payload the host already checked (§ Links, The app's URL): the helper's
// card, and nothing happens until the person presses one of its actions.
- (void)showLinkPayload:(NSString *)payload;

// Posted with the link as its object when a view outside the dropdown (Settings' "Use my existing profile…") needs
// the join page: the dropdown of that link opens on it (PROTOCOL.md § Joining, Offering it).
extern NSNotificationName const SZFriendsShowJoinNotification;
// make_download_link for `item`, valid `days` (1, 7 or 30), then the link on the pasteboard. `completion` runs once
// on the main thread with the words to show: the helper's message, or its error's (nil when it gave none).
- (void)copyDownloadLinkForItem:(SZFriendsAttachableItem *)item
                    expiresDays:(NSInteger)days
                     completion:(void (^)(NSString *_Nullable message, BOOL copied))completion;
@end

NS_ASSUME_NONNULL_END
