// Searching messages and deleting history (PROTOCOL.md § Intents), moved from SZFriendsIntentRouter+Content.m as
// they were.

#import "service/helper/SZFriendsIntentRouter.h"

#import <sodium.h>

#import "service/helper/SZFriendsHostCheckIn.h"
#import "service/helper/nearby/SZFriendsNearbyDevices.h"

static const NSUInteger SZFriendsSearchLimitDefault = 20;
static const NSUInteger SZFriendsSearchLimitMax = 50;

@implementation SZFriendsIntentRouter (History)

#pragma mark - Search, delete, reset

- (void)intent_search_messages:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                         reply:(SZFriendsIntentReply)reply {
    NSString *query = intent[@"query"];
    if (!SZFriendsJSONIsString(query) || query.length > 200) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"query"} connection:connection];
        return;
    }
    id conversationID = intent[@"conversation_id"];
    NSArray<NSString *> *scope = nil;
    if (conversationID != nil && conversationID != [NSNull null]) {
        if ([self personForIntent:intent reply:reply connection:connection] == nil) return;
        scope = @[ conversationID ];
    }
    id limitValue = intent[@"limit"];
    NSUInteger limit = SZFriendsSearchLimitDefault;
    if (limitValue != nil) {
        if (!SZFriendsJSONIsInteger(limitValue)) {
            [self fail:reply code:@"invalid_field" details:@{@"field" : @"limit"} connection:connection];
            return;
        }
        limit = (NSUInteger)MAX(1, MIN((long long)SZFriendsSearchLimitMax, [limitValue longLongValue]));
    }
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // One more than asked, so the reply can say whether there are more. Never touches the network.
    NSArray<SZFriendsSearchHit *> *hits =
        trimmed.length > 0 ? [self.services.store searchFor:trimmed conversationIDs:scope limit:limit + 1] : @[];
    NSMutableArray<SZFriendsSearchHitFacts *> *facts = [NSMutableArray array];
    for (SZFriendsSearchHit *hit in hits) {
        if (facts.count == limit) break;
        SZFriendsSearchHitFacts *fact = [[SZFriendsSearchHitFacts alloc] init];
        fact.conversationID = hit.conversationID;
        fact.itemID = hit.itemID;
        fact.sentAt = hit.sentAt;
        fact.outgoing = hit.direction == SZFriendsDirectionOutgoing;
        fact.text = hit.text;
        fact.matchRanges = hit.matchRanges;
        [facts addObject:fact];
    }
    SZFriendsFactsPass *pass = [[SZFriendsFactsPass alloc] initWithServices:self.services now:[NSDate date]];
    NSMutableDictionary *people = [NSMutableDictionary dictionary];
    for (SZFriendsPersonFacts *person in pass.people) people[person.conversationID] = person;
    SZFriendsSnapshotBuilder *builder = [self.publisher stateForConnection:connection].builder;
    builder.mentionDirectory = pass.mentionDirectory; // excerpts show each mention as "@Name"
    reply([builder searchResultWithHits:facts people:people more:hits.count > limit now:pass.now], nil, nil, nil);
}

- (void)intent_delete_history:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                        reply:(SZFriendsIntentReply)reply {
    id conversationID = intent[@"conversation_id"];
    if (conversationID == [NSNull null]) conversationID = nil;
    if (conversationID != nil && [self personForIntent:intent reply:reply connection:connection] == nil) return;
    if (![self eraseHistoryInConversation:conversationID]) {
        [self fail:reply code:@"internal" details:nil connection:connection];
        return;
    }
    [self succeed:reply result:nil];
}

// delete_history, and remove_friend's delete_history: one conversation's history, or all of it for nil.
- (BOOL)eraseHistoryInConversation:(nullable NSString *)conversationID {
    // With another device of ours, the deletion reaches every one of them (sync); otherwise it is the store's alone.
    SZFriendsNearbyService *nearby = self.services.nearby;
    BOOL erased = nearby ? [nearby eraseHistoryInConversation:conversationID]
                         : [self.services.store deleteHistoryInConversation:conversationID error:NULL];
    if (erased) [self.services.nearby historyDeleted];
    return erased;
}

@end
