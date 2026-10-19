// cancel_message: withdrawing an outgoing message that has not left this Mac (PROTOCOL.md § Intents, helper capability
// messages.cancel). Kept apart from +Content, which holds sending, transfers and search.

#import "service/helper/SZFriendsIntentRouter.h"

#import "service/helper/nearby/SZFriendsNearbyService.h"

static NSString *SZFriendsCancelledStateName(NSInteger state) {
    // Queued again after a session dropped before the friend's Mac acknowledged it: that Mac may have it.
    if (state == SZFriendsOutboxCancelStateWritten) return @"sent";
    switch (state) {
    case SZFriendsOutboxStateSending: return @"sending";
    case SZFriendsOutboxStateDelivered: return @"delivered";
    case SZFriendsOutboxStateFailed: return @"failed";
    default: return nil;
    }
}

@implementation SZFriendsIntentRouter (Cancel)

// Ids are unique per conversation, not across them, and the friend chooses the ids of what they send: the store looks
// for this person's own outgoing message, so a friend's message that reuses one of our ids is never touched.
- (void)intent_cancel_message:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                        reply:(SZFriendsIntentReply)reply {
    NSString *messageID = [self requiredString:@"message_id" in:intent maxLength:64 reply:reply
                                    connection:connection];
    if (messageID == nil) return;
    SZFriendsItemRecord *message = [self.services.store outgoingMessagesWithIDs:@[ messageID ]].firstObject;
    if (message == nil) {
        [self fail:reply code:@"not_found" details:@{@"field" : @"message_id"} connection:connection];
        return;
    }
    NSInteger state = -1;
    NSError *error = nil;
    if (![self.services.outbox cancelMessage:messageID inConversation:message.conversationID state:&state
                                       error:&error]) {
        NSString *code = SZFriendsStoreProtocolErrorCode(error);
        NSString *stateName = SZFriendsCancelledStateName(state);
        if (![code isEqualToString:@"stale"] || stateName == nil) {
            [self fail:reply code:code details:@{@"field" : @"message_id"} connection:connection];
            return;
        }
        // Cancel lost the race: it is on its way, already on their Mac, or may be (written, then the session dropped),
        // and stays so. details.state says which, and the message says it in words naming the friend, who is in the
        // words only.
        NSDictionary *details = @{@"field" : @"message_id", @"state" : stateName};
        SZFriendsPersonRecord *person = [self.services.store personWithConversationID:message.conversationID];
        NSMutableDictionary *forMessage = [details mutableCopy];
        if (person.name.length) forMessage[@"name"] = person.name;
        if (person.friendsID.length) forMessage[@"friends_id"] = person.friendsID;
        SZFriendsStrings *strings = [self.publisher stateForConnection:connection].strings;
        reply(nil, code, [strings messageForErrorCode:code details:forMessage], details);
        return;
    }
    // Nothing new to send; this lets the dialer stop for a friend with nothing else waiting, and publishes the change.
    [self.services.nearby outboxChangedForConversation:message.conversationID];
    [self succeed:reply result:nil];
}

@end
