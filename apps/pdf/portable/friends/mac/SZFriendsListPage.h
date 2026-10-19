// Shenzhen Friends list page: search, Friends / Nearby tabs, rows, the footer (internal).

#import "mac/SZFriendsRowView.h"

NS_ASSUME_NONNULL_BEGIN

// The footer under both tabs: the name friends see (click to edit in place), the ID with Copy, the note while
// the ID is unreserved, and Add by ID.
@interface SZFriendsFooterView : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context;
- (void)applyFooter:(nullable NSDictionary *)footer; // PROTOCOL.md footer
- (CGFloat)heightForWidth:(CGFloat)width;
@property(nonatomic, strong, readonly) SZFriendsButton *nameButton;
@property(nonatomic, strong, readonly) SZFriendsButton *cpyButton; // "copy" is reserved for NSCopying
@property(nonatomic, strong, readonly) SZFriendsButton *addButton;
@property(nonatomic, readonly, getter=isEditingName) BOOL editingName;
- (void)beginEditingName;
- (BOOL)cancelEditingName; // YES when an edit was open
@property(nonatomic, copy, nullable) void (^onAddByID)(void);
// NO on a computer removed from the person's profile, which can add nobody (PROTOCOL.md § Devices); default YES.
@property(nonatomic) BOOL offersAdding;
@end

// The Nearby tab's content: visibility card, the one alert or quiet note, people as each method reports them.
@interface SZFriendsNearbyPane : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context;
- (void)applyNearby:(NSDictionary *)data;
- (CGFloat)heightForWidth:(CGFloat)width;
@property(nonatomic, copy, readonly) NSArray<SZFriendsRowView *> *personRows;
@property(nonatomic, strong, readonly, nullable) SZFriendsButton *visibilityButton;
@property(nonatomic, copy, nullable) void (^onOpenConversation)(NSString *conversationID);
@end

// A card or a quiet line: the ID-changed banner, the name prompt, "Send 2 files to…", the drop hint, Nearby's
// visibility card, alert and note. Text column (title, body, field, note, button) with an optional trailing
// column (the countdown over Stop, or a short action like the banner's OK) and an optional leading icon.
@interface SZFriendsNoticeView : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context;
- (CGFloat)heightForWidth:(CGFloat)width;
@property(nonatomic, strong, readonly) NSTextField *titleLabel;
@property(nonatomic, strong, readonly) NSTextField *bodyLabel;
@property(nonatomic, strong, readonly) NSTextField *noteLabel;
@property(nonatomic, strong, nullable) NSTextField *field;     // the name prompt's input
@property(nonatomic, strong, nullable) SZFriendsButton *button;
@property(nonatomic, strong, nullable) SZFriendsButton *secondaryButton; // a link under the text ("Copy link instead")
@property(nonatomic, strong, nullable) NSTextField *bigLabel;  // the visibility countdown
@property(nonatomic) BOOL buttonTrailing;
@property(nonatomic) BOOL buttonFullWidth;
@property(nonatomic) BOOL buttonFirst; // the button above the text instead of under it
@property(nonatomic) CGFloat padding;
@property(nonatomic, copy, nullable) SZFriendsIconDrawer iconDrawer;
@property(nonatomic, strong, nullable) NSColor *iconColor;
// Replaces the button with one for a PROTOCOL.md action (nil or unknown: no button).
- (void)setAction:(nullable NSDictionary *)action onPress:(nullable void (^)(NSDictionary *action))onPress;
@end

@class SZFriendsListDevicesView;

@interface SZFriendsListPage : SZFriendsPage
@property(nonatomic, strong, readonly) NSSearchField *searchField;
@property(nonatomic, strong, readonly) SZFriendsButton *friendsTab;
@property(nonatomic, strong, readonly) SZFriendsButton *nearbyTab;
@property(nonatomic, readonly) BOOL showingNearby;
- (void)showNearby:(BOOL)nearby;
@property(nonatomic, strong, readonly) SZFriendsFooterView *footer;
@property(nonatomic, strong, readonly) SZFriendsNearbyPane *nearbyPane;
@property(nonatomic, copy, readonly) NSArray<SZFriendsRowView *> *rows;
@property(nonatomic, strong, readonly) NSScrollView *scrollView;
- (void)applyNearbySnapshot:(NSDictionary *)data;
// While files are dragged in through the Friends button: the hint, or why they cannot be sent, above the rows.
- (void)setDropHint:(nullable NSString *)hint;
// `refusing`: the hint is that refusal (drop_folders_refused, drop_not_a_file), so the rows that take files show
// only the refuse style rather than repeating it.
- (void)setDropHint:(nullable NSString *)hint refusing:(BOOL)refusing;
// "Send 2 files to…" (the send picker) above the rows, with Cancel; nil hides it. The tooltip lists every file.
- (void)setSendPickerTitle:(nullable NSString *)title;
- (void)setSendPickerTitle:(nullable NSString *)title toolTip:(nullable NSString *)toolTip;
@property(nonatomic, strong, readonly, nullable) SZFriendsButton *sendPickerCancelButton;
// A second way out of "Send 1 file to…", under its title: the host's "Copy link instead" (SZFriendsHost.h). It goes
// with the picker.
- (void)setSendPickerLinkButton:(nullable SZFriendsButton *)button;
@property(nonatomic, strong, readonly, nullable) SZFriendsButton *sendPickerLinkButton;
// The name prompt's field and the banner's action, for tests and keyboard focus.
@property(nonatomic, strong, readonly, nullable) NSTextField *namePromptField;
@property(nonatomic, strong, readonly, nullable) SZFriendsButton *bannerButton;
// Several computers (SZFriendsDevices.h): the removed notice and join rows, and the name prompt's "Use my existing
// profile" (nil while the prompt or its join_label is absent).
@property(nonatomic, strong, readonly) SZFriendsListDevicesView *devicesView;
@property(nonatomic, strong, readonly, nullable) SZFriendsButton *joinButton;
@end

NS_ASSUME_NONNULL_END
