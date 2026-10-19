// Shenzhen Friends dropdown internals: the view stack, the presenter seam and the title button (internal).

#import "mac/SZFriendsDropdownController.h"
#import "mac/SZFriendsListPage.h"

NS_ASSUME_NONNULL_BEGIN

// The dropdown's height for the space between the button and the bottom of the window: it fits the window, up to
// `maxHeight` (brief § Interface: about 400 pt wide, as tall as the window allows up to 640 pt).
CGFloat SZFriendsDropdownHeight(CGFloat spaceBelowButton, CGFloat maxHeight);

// "Send 2 files to…" for the send picker: welcome.strings drop_send_file / drop_send_file_and_more with the first
// file's name, or drop_send_one / drop_send_many when the helper has no named form; nil without either.
NSString *_Nullable SZFriendsSendPickerTitle(SZFriendsContext *context, NSArray<NSString *> *names, NSUInteger count);

// The inline confirmation over the dropdown (PROTOCOL.md confirm object; `destructive` draws its button red).
// Escape cancels it.
@interface SZFriendsConfirmView : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context confirm:(NSDictionary *)confirm
                      onConfirm:(void (^)(void))onConfirm;
@property(nonatomic, strong, readonly) SZFriendsButton *confirmButton;
@property(nonatomic, strong, readonly) SZFriendsButton *cancelButton;
@property(nonatomic, copy, nullable) void (^onFinish)(void);
@end

// The dropdown's root view: the stack of pages (list -> conversation -> details, or list -> profile), the
// confirmation overlay, Escape and Cmd+[.
@interface SZFriendsDropdownContent : SZFriendsFlippedView <SZFriendsNavigator, SZFriendsEscapeHandling>
- (instancetype)initWithContext:(SZFriendsContext *)context;
@property(nonatomic, strong, readonly) SZFriendsContext *context;
@property(nonatomic, strong, readonly) SZFriendsListPage *listPage;
@property(nonatomic, copy, readonly) NSArray<SZFriendsPage *> *stack;
@property(nonatomic, strong, readonly) SZFriendsPage *topPage;
// On screen or not: the top page subscribes when presented and releases everything when not.
@property(nonatomic) BOOL presented;
@property(nonatomic, strong, readonly, nullable) SZFriendsConfirmView *confirmation;
@property(nonatomic, copy, nullable) void (^onClose)(void);
// The client library's line while the helper is not answering ("Starting Friends…"); nil when connected.
@property(nonatomic, copy, readonly, nullable) NSString *statusText;
- (void)popToList;
- (void)beginSendPickerWithFiles:(NSArray<NSDictionary *> *)files;
// The link page on top of the list (SZFriendsLinkPage.h).
- (void)openLinkPayload:(NSString *)payload;
- (void)setDropHint:(nullable NSString *)hint;
// `refusing`: the hint says why the dragged files cannot be sent, so rows show only the refuse style.
- (void)setDropHint:(nullable NSString *)hint refusing:(BOOL)refusing;
@end

// How the dropdown appears: an NSPopover in the app, a recorder in tests (no window ever reaches the screen).
@protocol SZFriendsDropdownPresenter <NSObject>
@property(nonatomic, copy, nullable) void (^onDismiss)(void);
@property(nonatomic, readonly, getter=isPresented) BOOL presented;
- (void)presentView:(NSView *)view size:(NSSize)size fromButton:(NSView *)button;
- (void)resizeTo:(NSSize)size;
- (void)dismiss;
@end

@interface SZFriendsPopoverPresenter : NSObject <SZFriendsDropdownPresenter>
@end

// The title-bar button: two people, the badge, and a spring-loading drop target.
@interface SZFriendsTitleButton : SZFriendsButton <NSSpringLoadingDestination>
- (instancetype)initWithContext:(SZFriendsContext *)context;
@property(nonatomic, readonly) SZFriendsDropHighlight dropHighlight;
@property(nonatomic, copy, nullable) void (^onSpringLoad)(SZFriendsDropVerdict verdict);
@property(nonatomic, copy, nullable) void (^onDropItems)(NSArray<SZFriendsAttachableItem *> *items);
// Where the people icon and the waiting count are drawn (tests check the count never covers the second figure).
- (NSRect)iconRect;
- (NSRect)badgeRect;
@end

@interface SZFriendsDropdownController ()
- (instancetype)initWithHost:(id<SZFriendsHost>)host
                        link:(SZFriendsHelperLink *)link
                   presenter:(id<SZFriendsDropdownPresenter>)presenter NS_DESIGNATED_INITIALIZER;
@property(nonatomic, strong, readonly) SZFriendsContext *context;
@property(nonatomic, strong, readonly) SZFriendsDropdownContent *content; // created on first open
@end

// Friends' services for the host (Cmd+K search, citations, scoped chat access), backed by the link.
@interface SZFriendsServicesProvider : NSObject <SZFriendsServices>
- (instancetype)initWithContext:(SZFriendsContext *)context controller:(SZFriendsDropdownController *)controller;
@end

NS_ASSUME_NONNULL_END

#import "mac/SZFriendsSettingsSection.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsSettingsSection ()
@property(nonatomic, strong, readonly) SZFriendsContext *context;
@property(nonatomic, copy, readonly) NSArray<SZFriendsButton *> *buttons;  // Copy, Show in Finder, Change…, …
// The Nearby line's one button (Allow, Open Privacy Settings, Try Again); hidden without one.
@property(nonatomic, strong, readonly) SZFriendsButton *nearbyButton;
@property(nonatomic, copy, readonly) NSArray<NSSwitch *> *autoAcceptSwitches;
@property(nonatomic, strong, readonly) NSTextField *nameField;
@property(nonatomic, readonly) BOOL holdsSubscription;
- (void)applySnapshot:(NSDictionary *)data;
// The alert a confirmation shows, marked hidden from the host's assistant (SZFriendsUI.h).
+ (NSAlert *)alertForConfirm:(NSDictionary *)confirm;
@end

NS_ASSUME_NONNULL_END
