// SZFriendsListPage's row actions: a press (opens the conversation, or sends the files waiting in the send picker),
// files dropped on a row, and Accept, Decline, Block and Remove.

#import "mac/SZFriendsListPageInternal.h"

#import "mac/SZFriendsConversationCache.h"
#import "mac/SZFriendsPromiseCopies.h"

@implementation SZFriendsListPage (Actions)

- (void)rowPressed:(SZFriendsRowView *)row {
    if (!row.conversationID) return;
    NSArray *files = [self.context.navigator pendingSendFiles];
    if (files) {
        // The send picker: the next friend clicked receives one offer per file. Rows that refuse drops (requests,
        // blocked people) cannot receive files this way either.
        if (!row.dropLabel) return;
        [self.context.link sendIntent:@"send_files"
                               fields:@{@"conversation_id" : row.conversationID, @"files" : files,
                                        @"client_token" : [SZFriendsContext clientToken]}
                                reply:^(NSDictionary *result, SZFriendsLinkError *error) {
                                    (void)result;
                                    // The helper copied them before it answered (SZFriendsPromiseCopies.h).
                                    if (!error) [SZFriendsPromiseCopies discardCopiesForFileObjects:files];
                                }];
        [self.context.navigator finishSendPicker];
        [self.context.navigator openConversation:row.conversationID highlightMessage:nil];
        return;
    }
    [self.context.navigator openConversation:row.conversationID highlightMessage:nil];
}

- (void)rowHovered:(SZFriendsRowView *)row inside:(BOOL)inside {
    [self noteRowHovered:row inside:inside];
    NSString *conversationID = row.conversationID;
    if (!conversationID) return;
    if (inside) [self.context.conversations follow:conversationID];
    else [self.context.conversations stopFollowing:conversationID];
    if (inside) [self prepareConversation:conversationID onRow:row attempt:0];
}

// Once the pointer has rested on the row a moment (not while it crosses the list), and what is kept of the
// conversation has come, its page is built ahead of the click.
- (void)prepareConversation:(NSString *)conversationID onRow:(SZFriendsRowView *)row attempt:(NSUInteger)attempt {
    __weak SZFriendsListPage *weakSelf = self;
    __weak SZFriendsRowView *weakRow = row;
    if (!self.context.scheduleAfter || attempt > 10) return;
    self.context.scheduleAfter(0.05, ^{
        SZFriendsListPage *page = weakSelf;
        SZFriendsRowView *rested = weakRow;
        if (!page || !rested.hovered || ![rested.conversationID isEqualToString:conversationID]) return;
        id<SZFriendsNavigator> navigator = page.context.navigator;
        if (![page.context.conversations snapshotFor:conversationID])
            [page prepareConversation:conversationID onRow:rested attempt:attempt + 1];
        else if ([navigator respondsToSelector:@selector(prepareConversation:)])
            [navigator prepareConversation:conversationID];
    });
}

// About a dropdown's worth: the people a click most likely goes to.
static const NSUInteger SZFPrefetchedRows = 6;

- (void)prefetchFirstRows {
    NSMutableArray<NSString *> *conversationIDs = [NSMutableArray array];
    for (SZFriendsRowView *row in self.rows) {
        if (conversationIDs.count >= SZFPrefetchedRows) break;
        if (row.conversationID) [conversationIDs addObject:row.conversationID];
    }
    [self.context.conversations prefetch:conversationIDs];
}

- (void)sendItems:(NSArray<SZFriendsAttachableItem *> *)items toConversation:(NSString *)conversationID {
    if (!conversationID.length || !items.count) return;
    NSMutableArray *files = [NSMutableArray array];
    for (SZFriendsAttachableItem *item in items) [files addObject:[SZFriendsContext fileObjectForItem:item]];
    [self.context.link sendIntent:@"send_files"
                           fields:@{@"conversation_id" : conversationID, @"files" : files,
                                    @"client_token" : [SZFriendsContext clientToken]}
                            reply:^(NSDictionary *result, SZFriendsLinkError *error) {
                                (void)result;
                                if (!error) [SZFriendsPromiseCopies discardCopiesForItems:items after:0];
                            }];
    [self setDropHint:nil];
}

// Accept, Decline or Block from the row: the intent with the row's conversation. The buttons rest until the reply,
// so a double click sends one answer; a success brings the new list (without the buttons) before its reply.
- (void)performRowAction:(NSDictionary *)action onRow:(SZFriendsRowView *)row {
    NSString *conversationID = row.conversationID;
    if (!conversationID) return;
    SZFriendsRowActionsView *actions = row.actionsView;
    actions.busy = YES;
    [self.context performAction:action ids:@{@"conversation_id" : conversationID}
                           done:^(SZFriendsLinkError *error) {
                               (void)error;
                               if ([row.conversationID isEqualToString:conversationID]) actions.busy = NO;
                           }];
}

// A row's menu (Remove): asked first as the action says; once confirmed the row goes at once, and comes back with
// the helper's reason if the helper refuses.
- (void)performMenuAction:(NSDictionary *)action conversation:(NSString *)conversationID {
    if (!conversationID.length) return;
    __weak SZFriendsListPage *weakSelf = self;
    [self.context performAction:action ids:@{@"conversation_id" : conversationID}
        sending:^{ [weakSelf hidePerson:conversationID]; }
        reply:^(NSDictionary *result, SZFriendsLinkError *error) {
            (void)result;
            [weakSelf person:conversationID leftWithError:error];
        }];
}

- (void)hidePerson:(NSString *)conversationID {
    if (!_leaving) {
        _leaving = [NSMutableSet set];
        _leavingSeenGone = [NSMutableSet set];
        _left = [NSMutableSet set];
    }
    [_leaving addObject:conversationID];
    [_leavingSeenGone removeObject:conversationID];
    [self applyRows:SZFArr(_listData, @"rows")];
}

- (void)person:(NSString *)conversationID leftWithError:(SZFriendsLinkError *)error {
    if (![_leaving containsObject:conversationID]) return;
    [_leaving removeObject:conversationID];
    BOOL seenGone = [_leavingSeenGone containsObject:conversationID];
    [_leavingSeenGone removeObject:conversationID];
    if (!error && !seenGone) [_left addObject:conversationID];
    [self applyRows:SZFArr(_listData, @"rows")];
    if (error) [self.context announce:error.message];
}

@end
