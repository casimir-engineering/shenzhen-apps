// Shenzhen Friends views: the context every view shares, the page base class and the header bar (internal).

#import <AppKit/AppKit.h>

#import "mac/SZFriendsDropdownController.h"
#import "mac/SZFriendsHelperLink.h"
#import "mac/SZFriendsHost.h"
#import "mac/SZFriendsUI.h"

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsPage;

// What a page asks of the dropdown around it. The view stack is the dropdown's business, never the helper's.
@protocol SZFriendsNavigator <NSObject>
- (void)openConversation:(NSString *)conversationID highlightMessage:(nullable NSString *)messageID;
- (void)openDetails:(NSString *)conversationID;
- (void)openProfile;
// A new computer's side of joining an existing profile (the name prompt's "Use my existing profile").
- (void)openJoin;
- (void)goBack;
// Back to the list, whatever is open above it.
- (void)popToList;
- (void)closeDropdown;
// The send picker's files, while "Send 2 files to…" is showing; nil otherwise.
- (nullable NSArray<NSDictionary *> *)pendingSendFiles;
- (void)finishSendPicker;
@end

// One press of a button: when (the NSEvent timestamp clock, system uptime) and how many clicks in a row.
typedef struct {
    NSTimeInterval time;
    NSInteger clickCount;
} SZFriendsPress;

// The press `event` describes when it is a mouse or key event from within a second of `now`; otherwise a single
// press at `now`. WHY the age check: VoiceOver's press and performClick: leave NSApp.currentEvent at whatever came
// last, possibly minutes old, and two presses read from one stale event would look simultaneous.
SZFriendsPress SZFriendsPressFromEvent(NSEvent *_Nullable event, NSTimeInterval now);

// One draft per conversation, kept in this process across navigation and reopening (brief § Interface).
@interface SZFriendsDraft : NSObject
@property(nonatomic, copy) NSString *text;
// The composer's text with its `@` chips (SZFriendsMentionViews.h), kept only while it holds one; it counts only while
// its string is still `text`, since a `/` result replaces `text` without knowing about chips.
@property(nonatomic, copy, nullable) NSAttributedString *richText;
@property(nonatomic, copy) NSArray<SZFriendsAttachableItem *> *items;
@property(nonatomic) BOOL command; // `text` is a `/` command for the host's assistant, not a message
@end

@interface SZFriendsContext : NSObject
- (instancetype)initWithHost:(nullable id<SZFriendsHost>)host link:(SZFriendsHelperLink *)link;
@property(nonatomic, weak, readonly, nullable) id<SZFriendsHost> host;
@property(nonatomic, strong, readonly) SZFriendsHelperLink *link;
@property(nonatomic, strong, readonly) SZFriendsAppearance *appearance;
@property(nonatomic, weak, nullable) id<SZFriendsNavigator> navigator;
@property(nonatomic, strong, readonly) NSMutableDictionary<NSString *, SZFriendsDraft *> *drafts;
// `/` requests still running, one per conversation id (SZFriendsComposerInternal.h): they outlive their composer.
@property(nonatomic, strong, readonly) NSMutableDictionary<NSString *, id> *assistantRuns;
// Messages a `/` command proposed, waiting for the person's Send or Edit, one per conversation id: like a draft,
// one survives going Back and closing the dropdown.
@property(nonatomic, strong, readonly) NSMutableDictionary<NSString *, id> *assistantProposals;
// Runs `layout` as one Markdown render pass of the host (SZFriendsHost.h § Optional Markdown rendering): the host's
// begin and end around it when it has both, never nested, so a layout inside a layout stays in the outer pass.
- (void)markdownPass:(void (^)(void))layout;
// YES while the shown conversation's width keeps changing (SZFriendsConversationPage sets and clears it): bubbles lay
// the host's last answer out again at each new width, and the host is asked again only once the width settles.
@property(nonatomic) BOOL reusesMarkdownRenders;
// welcome.strings; "" when absent, so a view shows nothing rather than inventing text.
- (NSString *)string:(NSString *)key;
// Injectable for tests and probes, so nothing reaches System Settings, Finder or the general pasteboard.
@property(nonatomic, copy) void (^openURL)(NSURL *url);
// Shows `menu` at `point` in `view` (a link's address and its open item); defaults to popping it up there. Tests
// record the menu instead, since a popped-up menu runs its own loop until it closes.
@property(nonatomic, copy) void (^presentMenu)(NSMenu *menu, NSView *view, NSPoint point);
@property(nonatomic, strong) NSPasteboard *pasteboard;
@property(nonatomic, copy, nullable) NSString *promiseDirectory; // where dropped file promises are received
// Asks for an image file (Use your own picture…); defaults to an open panel. Tests answer it directly.
@property(nonatomic, copy) void (^chooseImage)(void (^completion)(NSString *_Nullable path));
// Runs `block` on the main queue after `seconds`; Block's armed pill times out through it. Tests replace it to fire
// the timer on demand instead of waiting.
@property(nonatomic, copy) void (^scheduleAfter)(NSTimeInterval seconds, dispatch_block_t block);
// The press being handled, from NSApp.currentEvent (SZFriendsPressFromEvent): an armed action reads its time and
// click count, so the second click of a double-click never confirms what the first one armed. Tests supply presses.
@property(nonatomic, copy) SZFriendsPress (^currentPress)(void);
// Posts an accessibility notification (NSAccessibilityPostNotificationWithUserInfo). Tests record them instead.
@property(nonatomic, copy) void (^postAccessibility)(id element, NSAccessibilityNotificationName name,
                                                     NSDictionary *_Nullable userInfo);
// Speaks `text` to VoiceOver at once, interrupting (high priority): something changed that is shown only visually,
// such as an armed "Block?", "Copied" or an inline error. Nothing for an empty text.
- (void)announce:(nullable NSString *)text;
// Shows a PROTOCOL.md confirm object (inline over the dropdown; a sheet in Settings); `onConfirm` runs only on its
// confirm button. Unset: the action is not performed, because an unconfirmed destructive action must not run. A
// confirm with `option` shows it as a checkbox, unticked; `optionTicked` says whether it was ticked at the confirm.
@property(nonatomic, copy, nullable) void (^presentConfirmation)(NSDictionary *confirm,
                                                                  void (^onConfirm)(BOOL optionTicked));
// Actions a view may show: a view hides an action it does not know (PROTOCOL.md § Principles).
+ (BOOL)knowsAction:(nullable NSString *)action;
// Performs a PROTOCOL.md action object: an intent named by `action` with the id it needs from `ids`
// (conversation_id, transfer_id, item_id, nearby_id, kind) or, for add_from_mention, the action's own friends_id,
// identity_key and name; or a client-side action (open_file, show_file, open_settings). Asks first when the action
// carries `confirm`. `done` runs once with the reply's error or nil; `reply` gets the reply's result too.
- (void)performAction:(NSDictionary *)action
                  ids:(nullable NSDictionary<NSString *, NSString *> *)ids
                 done:(nullable void (^)(SZFriendsLinkError *_Nullable error))done;
- (void)performAction:(NSDictionary *)action
                  ids:(nullable NSDictionary<NSString *, NSString *> *)ids
                reply:(nullable SZFriendsReplyHandler)reply;
// The same; `sending` runs just before the intent goes (after its confirmation, if it asks one), never when the
// person cancels. A confirm `option` ticked adds its field as true (PROTOCOL.md confirm_option).
- (void)performAction:(NSDictionary *)action
                  ids:(nullable NSDictionary<NSString *, NSString *> *)ids
              sending:(nullable void (^)(void))sending
                reply:(nullable SZFriendsReplyHandler)reply;
// Puts `text` on the pasteboard and announces the static string `copied`, since Copy's only feedback is visual.
- (void)copyText:(NSString *)text;
// A random client_token for one press of Send (PROTOCOL.md § Intents, idempotency).
+ (NSString *)clientToken;
// SZFriendsAttachableItem -> PROTOCOL.md file object.
+ (NSDictionary *)fileObjectForItem:(SZFriendsAttachableItem *)item;
@end

// A page in the dropdown's stack. Pages render snapshots and send intents; a page subscribes in -pageWillAppear
// and releases every subscription in -pageDidDisappear, so nothing is held while it is off screen.
@interface SZFriendsPage : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@property(nonatomic, strong, readonly) SZFriendsContext *context;
@property(nonatomic, readonly) SZFriendsDropdownView kind;
@property(nonatomic, readonly, getter=isOnScreen) BOOL onScreen;
- (void)pageWillAppear;
- (void)pageDidDisappear;
// Renders one snapshot's `data`; tests drive pages straight from fixture files through this.
- (void)applySnapshot:(NSDictionary *)data;
// Escape: closes the innermost picker or inline editor and returns YES; NO when there is none.
- (BOOL)dismissInnermostPicker;
- (nullable NSView *)preferredFirstResponder;
// Rows waiting elsewhere (the back arrow's badge) changed: the dropdown re-reads -backBadgeLabel.
@property(nonatomic, copy, nullable) void (^onBackBadgeChange)(void);
@end

// The header of every view below the list: back arrow at the top left (with the waiting count), the name or
// title centered, optionally a route line under it, clickable when it opens details.
@interface SZFriendsHeaderView : SZFriendsFlippedView
- (instancetype)initWithAppearance:(SZFriendsAppearance *)appearance;
@property(nonatomic, strong, readonly) SZFriendsButton *backButton;
@property(nonatomic, strong, readonly) SZFriendsButton *titleButton;
- (void)setTitle:(nullable NSString *)title subtitle:(nullable NSString *)subtitle
      subtitleColor:(nullable NSColor *)subtitleColor clickable:(BOOL)clickable
 accessibilityLabel:(nullable NSString *)accessibilityLabel;
- (void)setBack:(nullable NSDictionary *)back fallbackLabel:(NSString *)label; // PROTOCOL.md back object
// The route object behind the route line: its icon (SZFriendsRouteGlyph) before the words, in their colour, and its
// label as the line's tooltip. nil, or kind none, draws no icon.
- (void)setRoute:(nullable NSDictionary *)route;
// Where the icon was last drawn, in the header's coordinates; NSZeroRect without one (tests).
@property(nonatomic, readonly) NSRect routeIconRect;
@end

extern const CGFloat SZFriendsHeaderHeight;

// Escape travels up the view tree to the dropdown, which closes the innermost picker first, then itself, and
// never navigates back (brief § Interface). Text fields forward it here instead of clearing themselves.
@protocol SZFriendsEscapeHandling <NSObject>
- (void)friendsHandleEscape;
@end
void SZFriendsForwardEscape(NSView *from);

// Draws a PROTOCOL.md avatar object in the circle inscribed in `rect` (rows draw it inline so the whole row stays
// one hit target; SZFriendsAvatarView wraps it as a view).
void SZFriendsDrawAvatar(NSDictionary *_Nullable avatar, NSRect rect);
// The same, asking `view` to redraw once a photo still loading off the main thread has loaded.
void SZFriendsDrawAvatarInView(NSDictionary *_Nullable avatar, NSRect rect, NSView *_Nullable view);

// An avatar (PROTOCOL.md avatar object): the bundled animal, the helper's re-encoded photo, or initials on the
// avatar's color when the animal or the photo is not available here.
@interface SZFriendsAvatarView : NSView
@property(nonatomic, copy, nullable) NSDictionary *avatar;
// The animal set drawn from; defaults to +[SZFriendsAnimalSet bundledSet]. Tests point it at the repository copy.
+ (void)setAnimalManifestPath:(nullable NSString *)path;
// What would be drawn: "animal", "image" or "placeholder" (tests and accessibility).
- (NSString *)drawnKind;
@end

NS_ASSUME_NONNULL_END
