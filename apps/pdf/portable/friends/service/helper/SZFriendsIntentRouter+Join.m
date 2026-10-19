// Intents of joining a profile (PROTOCOL.md § Joining): on the new computer join_profile, enter_join_code and
// cancel_join; on the person's other computers approve_join and deny_join. The work is the nearby service's
// (SZFriendsNearbyService+Join.m); here the fields are checked and the reply carries words for the person.

#import "service/helper/SZFriendsIntentRouter.h"

#import "service/helper/nearby/SZFriendsNearbyJoin.h"
#import "service/presentation/SZFriendsPresentationJoin.h"

@implementation SZFriendsIntentRouter (Join)

// Replies with the outcome of a join intent: nil succeeds, a code fails with the join words when there are some.
- (void)finishJoinIntent:(nullable NSString *)code
                   field:(nullable NSString *)field
                   reply:(SZFriendsIntentReply)reply
              connection:(SZFriendsIPCConnection *)connection {
    if (code == nil) {
        [self succeed:reply result:nil];
        return;
    }
    NSDictionary *details = field ? @{@"field" : field} : @{};
    NSString *message = [[self.publisher stateForConnection:connection].strings joinMessageForErrorCode:code
                                                                                                  field:field];
    if (message != nil) reply(nil, code, message, details);
    else [self fail:reply code:code details:details connection:connection];
}

- (nullable SZFriendsNearbyService *)joinNearbyReplying:(SZFriendsIntentReply)reply
                                             connection:(SZFriendsIPCConnection *)connection {
    SZFriendsNearbyService *nearby = self.services.nearby;
    if (nearby == nil) [self fail:reply code:@"not_allowed" details:nil connection:connection];
    return nearby;
}

- (void)intent_join_profile:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                      reply:(SZFriendsIntentReply)reply {
    NSString *typed = [self requiredString:@"friends_id" in:intent maxLength:100 reply:reply connection:connection];
    SZFriendsNearbyService *nearby = typed ? [self joinNearbyReplying:reply connection:connection] : nil;
    if (nearby == nil) return;
    NSString *code = [nearby startJoiningFriendsID:typed];
    [self finishJoinIntent:code field:[code isEqualToString:@"id_invalid"] ? @"friends_id" : nil reply:reply
                connection:connection];
}

- (void)intent_enter_join_code:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                         reply:(SZFriendsIntentReply)reply {
    id typed = intent[@"code"];
    if (!SZFriendsJSONIsString(typed) || [typed length] > 32) {
        [self finishJoinIntent:@"invalid_field" field:@"code" reply:reply connection:connection];
        return;
    }
    SZFriendsNearbyService *nearby = [self joinNearbyReplying:reply connection:connection];
    if (nearby == nil) return;
    NSString *code = [nearby tryJoinCode:typed];
    [self finishJoinIntent:code field:[code isEqualToString:@"invalid_field"] ? @"code" : nil reply:reply
                connection:connection];
}

- (void)intent_cancel_join:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                     reply:(SZFriendsIntentReply)reply {
    (void)intent;
    SZFriendsNearbyService *nearby = [self joinNearbyReplying:reply connection:connection];
    if (nearby == nil) return;
    [nearby cancelJoining];
    [self succeed:reply result:nil];
}

- (void)intent_approve_join:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                      reply:(SZFriendsIntentReply)reply {
    NSString *joinID = [self requiredString:@"join_id" in:intent maxLength:64 reply:reply connection:connection];
    SZFriendsNearbyService *nearby = joinID ? [self joinNearbyReplying:reply connection:connection] : nil;
    if (nearby == nil) return;
    [self finishJoinIntent:[nearby approveJoinID:joinID] field:nil reply:reply connection:connection];
}

- (void)intent_deny_join:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                   reply:(SZFriendsIntentReply)reply {
    NSString *joinID = [self requiredString:@"join_id" in:intent maxLength:64 reply:reply connection:connection];
    SZFriendsNearbyService *nearby = joinID ? [self joinNearbyReplying:reply connection:connection] : nil;
    if (nearby == nil) return;
    [self finishJoinIntent:[nearby denyJoinID:joinID] field:nil reply:reply connection:connection];
}

@end
