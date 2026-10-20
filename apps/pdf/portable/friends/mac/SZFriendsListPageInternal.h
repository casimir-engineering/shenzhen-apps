// Shenzhen Friends list page: what its implementation files share (internal): the page's state, and the methods
// SZFriendsListPageNotices.m and SZFriendsListPageActions.m add to it.

#import "mac/SZFriendsListPage.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsListPage () {
@package

    NSTextField *_titleLabel;
    SZFriendsFlippedView *_betaTag;
    NSTextField *_betaLabel;
    SZFriendsFlippedView *_tabTrack;
    SZFriendsNoticeView *_sendNotice;
    SZFriendsNoticeView *_banner;
    SZFriendsNoticeView *_namePrompt;
    SZFriendsFlippedView *_rowsView;
    NSScrollView *_nearbyScroll;
    NSTextField *_emptyTitle;
    NSTextField *_emptyBody;
    NSMutableArray<SZFriendsRowView *> *_rowViews;
    NSDictionary *_listData;
    NSDictionary *_nearbyData;
    NSString *_listToken;
    NSString *_nearbyToken;
    NSString *_sendTitle;
    NSString *_dropHint;
    BOOL _dropHintRefuses;
    BOOL _namePromptSaved;       // the card says the name was saved, and goes in a moment
    NSUInteger _namePromptRound; // which "saved" the pending hide belongs to
    // People taken off the list here (Remove): hidden at once, before the helper's next list. Sent and not yet
    // answered, and whether a list without them came meanwhile; answered yes, until a list without them comes.
    NSMutableSet<NSString *> *_leaving;
    NSMutableSet<NSString *> *_leavingSeenGone;
    NSMutableSet<NSString *> *_left;
}
- (void)applyRows:(NSArray *)snapshotRows; // the snapshot's rows, less anyone just removed here
@end

// The name prompt's card ("Saved" included) and the strip above the rows for files on their way in
// (SZFriendsListPageNotices.m).
@interface SZFriendsListPage (Notices)
- (void)applyNamePrompt:(nullable NSDictionary *)prompt;
- (void)endNameSaved;
- (void)dimRowsThatRefuseFiles;
- (void)updateSendNotice;
@end

// What a row does when pressed, dropped on, or asked to Accept, Decline, Block or Remove
// (SZFriendsListPageActions.m).
@interface SZFriendsListPage (Actions)
- (void)rowPressed:(SZFriendsRowView *)row;
- (void)sendItems:(NSArray<SZFriendsAttachableItem *> *)items toConversation:(NSString *)conversationID;
- (void)performRowAction:(NSDictionary *)action onRow:(SZFriendsRowView *)row;
- (void)performMenuAction:(NSDictionary *)action conversation:(NSString *)conversationID;
@end

NS_ASSUME_NONNULL_END
