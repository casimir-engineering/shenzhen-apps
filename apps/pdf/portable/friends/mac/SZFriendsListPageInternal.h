// Shenzhen Friends list page: what its implementation files share (internal): the page's state, and the methods
// SZFriendsListPageNotices.m, SZFriendsListPageActions.m and SZFriendsListPageKeyboard.m add to it.

#import "mac/SZFriendsKeyFocus.h"
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
    NSDictionary *_bannerDismiss; // the banner's `dismiss` action (notifications: Not Now)
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
    // The keyboard (SZFriendsListPageKeyboard.m): the list's own stop, and the highlighted row, which is the row the
    // pointer hovers or the one Up and Down moved to (-1: none), with whom it shows. From the keyboard, the highlight
    // stays with that person when the rows change; from the pointer, with the place under it.
    SZFriendsListKeyView *_keyList;
    NSInteger _keyRow;
    NSString *_keyRowID;
    BOOL _keyRowByKeyboard;
    BOOL _settingKeyRow;
    NSString *_openedRowID; // opened with Return: highlighted again when the list comes back
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
// The pointer on a row: its conversation's preview follows it, so a click shows the chat at once
// (SZFriendsConversationCache.h).
- (void)rowHovered:(SZFriendsRowView *)row inside:(BOOL)inside;
// The first rows' conversations, fetched once when the list shows them.
- (void)prefetchFirstRows;
- (void)sendItems:(NSArray<SZFriendsAttachableItem *> *)items toConversation:(NSString *)conversationID;
- (void)performRowAction:(NSDictionary *)action onRow:(SZFriendsRowView *)row;
- (void)performMenuAction:(NSDictionary *)action conversation:(NSString *)conversationID;
@end

// Up, Down, Return, Tab and typing in the list (SZFriendsListPageKeyboard.m).
@interface SZFriendsListPage (Keyboard)
- (void)setUpKeyboard;
- (void)layOutKeyList:(NSRect)frame;
- (void)keyRowsChanged;      // after new rows: the highlight follows its person, or the first match
- (void)restoreKeyRow;       // the list shows again: the row opened with Return is highlighted
- (void)noteRowHovered:(SZFriendsRowView *)row inside:(BOOL)inside;
- (BOOL)clearSearch;         // Escape: YES when the search had text, now gone
@end

NS_ASSUME_NONNULL_END
