// Shenzhen Friends on several computers in the views (internal; PROTOCOL.md § Devices, § Joining): the join page a new
// computer shows, the join rows and the removed notice above the list, and the profile's "Your computers". Every word
// comes from the helper's snapshot; these views only draw it and send what the person presses.

#import "mac/SZFriendsArming.h"
#import "mac/SZFriendsListPage.h"

NS_ASSUME_NONNULL_BEGIN

// The new computer's side (snapshot.join): the title and message, the Friends ID field while idle, the code field from
// waiting on, why the last code did not work, and the helper's actions (Cancel, Start again). A refused intent's
// message shows where `error` does.
@interface SZFriendsJoinPage : SZFriendsPage
@property(nonatomic, strong, readonly) SZFriendsHeaderView *header;
@property(nonatomic, strong, readonly) NSTextField *titleLabel;
@property(nonatomic, strong, readonly) NSTextField *messageLabel;
@property(nonatomic, strong, readonly) NSTextField *errorLabel;
@property(nonatomic, strong, readonly) NSTextField *idField;   // hidden unless the snapshot has id_field
@property(nonatomic, strong, readonly) NSTextField *codeField; // hidden unless the snapshot has code_field
@property(nonatomic, strong, readonly) SZFriendsButton *idButton;
@property(nonatomic, strong, readonly) SZFriendsButton *codeButton;
@property(nonatomic, copy, readonly) NSArray<SZFriendsActionButton *> *actionButtons;
- (void)submitID;
- (void)submitCode;
@end

// One join request on the person's other computers (type.join_request): what wants to join, Approve and Deny while it
// waits, then the code in large digits with when it stops working.
@interface SZFriendsJoinRequestView : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context;
- (void)applyRequest:(NSDictionary *)request;
- (CGFloat)heightForWidth:(CGFloat)width;
@property(nonatomic, copy, readonly, nullable) NSString *joinID;
@property(nonatomic, strong, readonly) NSTextField *titleLabel;
@property(nonatomic, strong, readonly) NSTextField *subtitleLabel;
@property(nonatomic, strong, readonly) NSTextField *codeLabel; // hidden until the request is approved
@property(nonatomic, strong, readonly) NSTextField *codeNoteLabel;
@property(nonatomic, copy, readonly) NSArray<SZFriendsActionButton *> *actionButtons;
@end

// What the list shows above its rows for several computers: "This computer was removed" with Start Over, then each
// join request. Zero height while there is neither.
@interface SZFriendsListDevicesView : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context;
- (void)applyList:(nullable NSDictionary *)data;
// The name prompt's join_label as a link under its field ("Use my existing profile"), which runs onJoin; nil
// removes it.
- (void)offerJoin:(nullable NSString *)label inPrompt:(SZFriendsNoticeView *)prompt;
@property(nonatomic, copy, nullable) void (^onJoin)(void);
- (CGFloat)heightForWidth:(CGFloat)width;
@property(nonatomic, readonly, getter=isRemoved) BOOL removed; // state device_removed
@property(nonatomic, strong, readonly) SZFriendsNoticeView *removedNotice;
@property(nonatomic, copy, readonly) NSArray<SZFriendsJoinRequestView *> *requestViews;
@end

// The profile's "Your computers" (data.devices): each computer with its name, system and last connection, Rename on
// this computer's row and Remove… on the others (with the helper's confirmation), then how to add one. Hidden (zero
// height) while the snapshot has no `devices`.
@interface SZFriendsYourComputersView : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context;
- (void)applyDevices:(nullable NSDictionary *)devices;
- (CGFloat)layoutForWidth:(CGFloat)width; // lays out the subviews and returns the height used
@property(nonatomic, copy, readonly) NSArray<NSTextField *> *nameLabels;
@property(nonatomic, copy, readonly) NSArray<NSTextField *> *detailLabels;
@property(nonatomic, copy, readonly) NSArray<SZFriendsActionButton *> *removeButtons;
@property(nonatomic, strong, readonly, nullable) SZFriendsButton *renameButton;
@property(nonatomic, strong, readonly) NSTextField *renameField; // shown while renaming
@property(nonatomic, strong, readonly) SZFriendsButton *saveButton;
@property(nonatomic, strong, readonly) NSTextField *renameError;
@property(nonatomic, readonly, getter=isRenaming) BOOL renaming;
- (void)beginRenaming;
- (BOOL)cancelRenaming; // YES when the field was open
- (void)saveName;
@end

NS_ASSUME_NONNULL_END
