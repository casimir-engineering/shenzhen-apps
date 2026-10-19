// Shenzhen Friends links in the views: the link page a friend or download link opens on, and the profile's
// "Your links" (internal; PROTOCOL.md § Links).

#import "mac/SZFriendsPage.h"

NS_ASSUME_NONNULL_BEGIN

// The page a link opens on: `open_link` with the payload as the host received it, then the helper's card (avatar,
// title, subtitle, note, its actions) or, when the helper refuses the link, its error's message. Nothing happens
// until the person presses one of the card's actions; while the helper is not answering, the page waits and asks
// again once it does.
@interface SZFriendsLinkPage : SZFriendsPage
- (instancetype)initWithContext:(SZFriendsContext *)context payload:(NSString *)payload;
@property(nonatomic, copy, readonly) NSString *payload;
@property(nonatomic, strong, readonly) SZFriendsHeaderView *header;
@property(nonatomic, strong, readonly) NSTextField *titleLabel;
@property(nonatomic, strong, readonly) NSTextField *subtitleLabel;
@property(nonatomic, strong, readonly) NSTextField *noteLabel;
@property(nonatomic, strong, readonly) NSTextField *messageLabel; // the refusal, or what pressing did
@property(nonatomic, copy, readonly) NSArray<SZFriendsButton *> *actionButtons;
// The card itself (open_link's result.card); tests and probes apply one directly.
- (void)applyCard:(nullable NSDictionary *)card;
- (void)applyError:(nullable NSString *)message;
@end

// The profile's links block: the friend link with Copy and Reset link, then each download link with its file,
// downloads, expiry and Revoke. Hidden (zero height) while the snapshot has no `links`.
@interface SZFriendsYourLinksView : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context;
- (void)applyLinks:(nullable NSDictionary *)links;
- (CGFloat)layoutForWidth:(CGFloat)width; // lays out the subviews and returns the height used
@property(nonatomic, strong, readonly) SZFriendsButton *friendCopyButton;
@property(nonatomic, strong, readonly) SZFriendsButton *friendResetButton;
@property(nonatomic, copy, readonly) NSArray<SZFriendsButton *> *revokeButtons;
@property(nonatomic, copy, readonly) NSArray<NSTextField *> *fileLabels;
@end

NS_ASSUME_NONNULL_END
