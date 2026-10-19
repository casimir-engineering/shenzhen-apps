// Intents about mentions (PROTOCOL.md § Mentions, ADR 0007): writing into a message the mentions its composer's @
// chips name, and Add from a mention, an Add by ID that only the mentioned key may answer.
//
// Views never write IDs or keys. They send the friends a message names by conversation id, with U+FFFC where each
// chip sits, and this helper writes each mention from its own store, so a mention always carries the key this Mac
// knows for that friend.

#import "service/helper/SZFriendsIntentRouter.h"

#import "service/helper/nearby/SZFriendsNearbyService.h"
#import "service/presentation/SZFriendsMentions.h"

// PROTOCOL.md § Limits: one session frame (ADR 0001), counted on the text this helper writes.
static const NSUInteger SZFriendsMentionTextBytesMax = 32768;

@implementation SZFriendsIntentRouter (Mentions)

#pragma mark - send_message

// The mention of a friend `entry` names, or nil after replying: an unknown conversation, or anyone who is not a friend
// with a Friends ID and a key.
- (nullable NSString *)mentionLinkFor:(id)entry
                                field:(NSString *)field
                                reply:(SZFriendsIntentReply)reply
                           connection:(SZFriendsIPCConnection *)connection {
    NSString *conversationID = [entry isKindOfClass:[NSDictionary class]] ? entry[@"conversation_id"] : nil;
    if (!SZFriendsJSONIsString(conversationID) || conversationID.length == 0 || conversationID.length > 64) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : field} connection:connection];
        return nil;
    }
    SZFriendsPersonRecord *person = [self.services.store personWithConversationID:conversationID];
    if (person == nil) {
        [self fail:reply code:@"not_found" details:@{@"field" : field} connection:connection];
        return nil;
    }
    NSString *link = nil;
    if (person.relation == SZFriendsRelationFriend && person.friendsID.length > 0) {
        link = SZFriendsMentionLink(SZFriendsMentionName(person.name, person.friendsID), person.friendsID,
                                    person.identityKey);
    }
    if (link == nil) [self fail:reply code:@"not_allowed" details:@{@"field" : field} connection:connection];
    return link;
}

- (nullable NSString *)textWithMentionsIn:(NSDictionary *)intent
                                     text:(NSString *)text
                                    reply:(SZFriendsIntentReply)reply
                               connection:(SZFriendsIPCConnection *)connection {
    // Nothing the person typed is a mention, however it looks: only what `mentions` names becomes one.
    NSString *typed = SZFriendsMentionsNeutralized(text);
    id mentions = intent[@"mentions"];
    if (mentions == nil || mentions == [NSNull null]) return typed;
    NSArray<NSString *> *pieces = [typed componentsSeparatedByString:SZFriendsMentionPlaceholder];
    if (![mentions isKindOfClass:[NSArray class]] || [mentions count] > SZFriendsMentionsMax ||
        pieces.count != [mentions count] + 1) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"mentions"} connection:connection];
        return nil;
    }
    NSMutableString *written = [pieces.firstObject mutableCopy];
    for (NSUInteger i = 0; i < [mentions count]; i++) {
        NSString *field = [NSString stringWithFormat:@"mentions[%lu]", (unsigned long)i];
        NSString *link = [self mentionLinkFor:mentions[i] field:field reply:reply connection:connection];
        if (link == nil) return nil;
        [written appendString:link];
        [written appendString:pieces[i + 1]];
    }
    if ([written lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > SZFriendsMentionTextBytesMax) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"text"} connection:connection];
        return nil;
    }
    return written;
}

#pragma mark - add_from_mention

// Whether this person's own data gives `friendsID` to another key than the mention's: their own ID, a friend's (whose
// ID is what their profile says), or one the Friends host vouched for. Then Add would reach someone else.
- (BOOL)friendsID:(NSString *)friendsID belongsToKeyOtherThan:(NSData *)identityKey {
    SZFriendsStore *store = self.services.store;
    if ([friendsID isEqualToString:store.friendsID]) return YES;
    for (SZFriendsPersonRecord *person in [store peopleByLatestInteraction]) {
        if (![person.friendsID isEqualToString:friendsID] || person.identityKey.length != 32 ||
            [person.identityKey isEqualToData:identityKey]) {
            continue;
        }
        if (person.relation == SZFriendsRelationFriend || person.friendsIDConfirmed) return YES;
    }
    return NO;
}

- (void)failMention:(NSString *)code
               name:(NSString *)name
              reply:(SZFriendsIntentReply)reply
         connection:(SZFriendsIPCConnection *)connection {
    // The message names the person as the mention did; the wire details stay machine-readable.
    SZFriendsStrings *strings = [self.publisher stateForConnection:connection].strings;
    reply(nil, code, [strings messageForErrorCode:code details:@{@"name" : name}], @{});
}

- (void)intent_add_from_mention:(NSDictionary *)intent
                     connection:(SZFriendsIPCConnection *)connection
                          reply:(SZFriendsIntentReply)reply {
    NSString *typedID = [self requiredString:@"friends_id" in:intent maxLength:100 reply:reply connection:connection];
    NSString *keyText = typedID ? [self requiredString:@"identity_key" in:intent maxLength:64 reply:reply
                                            connection:connection]
                                : nil;
    NSString *typedName = keyText ? [self requiredString:@"name" in:intent maxLength:512 reply:reply
                                              connection:connection]
                                  : nil;
    if (typedName == nil) return;
    NSString *friendsID = [self.services.codec normalizedID:typedID];
    if (friendsID == nil) {
        [self fail:reply code:@"id_invalid" details:@{@"field" : @"friends_id"} connection:connection];
        return;
    }
    NSData *key = SZFriendsMentionKeyFromString(keyText);
    NSString *name = SZFriendsMentionName(typedName, nil);
    if (key == nil || SZFriendsMentionLink(name, friendsID, key) == nil) {
        NSString *field = key == nil ? @"identity_key" : @"name";
        [self fail:reply code:@"invalid_field" details:@{@"field" : field} connection:connection];
        return;
    }
    SZFriendsStore *store = self.services.store;
    if ([key isEqualToData:self.services.identity.publicKey]) {
        [self fail:reply code:@"id_is_yours" details:nil connection:connection];
        return;
    }
    SZFriendsPersonRecord *known = [store personWithIdentityKey:key];
    // (A nil person's relation reads as 0, IncomingRequest: each case asks for a row first.)
    NSString *refusal = known == nil                                          ? nil
                        : known.relation == SZFriendsRelationFriend          ? @"already_friends"
                        : known.relation == SZFriendsRelationBlocked         ? @"blocked"
                        : known.relation == SZFriendsRelationIncomingRequest ? @"stale" // the card offers Accept
                                                                             : nil;
    if (refusal == nil && [self friendsID:friendsID belongsToKeyOtherThan:key]) refusal = @"mention_mismatch";
    if (refusal != nil) {
        [self failMention:refusal name:name reply:reply connection:connection];
        return;
    }
    SZFriendsStrings *strings = [self.publisher stateForConnection:connection].strings;
    BOOL online = self.services.nearby.reachesFriendsOnline; // the request also goes through the host
    NSDictionary *sent = @{@"conversation_id" : known.conversationID ?: @"",
                           @"message" : [strings addFromMentionSentMessageForName:name online:online]};
    NSDate *now = [NSDate date];
    NSArray<SZFriendsIDRequestRecord *> *pending = [store pendingIDRequestsAtDate:now];
    if (known.relation == SZFriendsRelationOutgoingRequest) {
        // Asked already, and still waiting: the same request, as add_by_id answers.
        BOOL waiting = known.requestFoundNearby;
        for (SZFriendsIDRequestRecord *request in pending)
            waiting = waiting || [request.conversationID isEqualToString:known.conversationID];
        if (waiting) {
            reply(sent, nil, nil, nil);
            return;
        }
    }
    // At most four pending (ADR 0004); checked before the row exists, so a refusal leaves no "Request sent" behind.
    if (pending.count >= SZFriendsIDRequestMaxPending) {
        [self fail:reply code:@"rate_limited" details:nil connection:connection];
        return;
    }
    [self startMentionRequestFor:known friendsID:friendsID key:key name:name now:now reply:reply
                      connection:connection];
}

// The "Request sent" row, holding the mentioned key from the start (so their answer comes back to it, and the card
// shows Request sent), and its Add by ID request, whose token binds it to that key.
- (void)startMentionRequestFor:(nullable SZFriendsPersonRecord *)known
                     friendsID:(NSString *)friendsID
                           key:(NSData *)key
                          name:(NSString *)name
                           now:(NSDate *)now
                         reply:(SZFriendsIntentReply)reply
                    connection:(SZFriendsIPCConnection *)connection {
    SZFriendsStore *store = self.services.store;
    SZFriendsPersonRecord *person = known;
    if (person == nil) {
        person = [[SZFriendsPersonRecord alloc] init];
        person.conversationID = SZFriendsNewIdentifier();
        person.identityKey = key;
        person.friendsID = friendsID;
        person.name = name; // until their own profile says otherwise
        person.picture = [SZFriendsPicture placeholder];
    }
    person.relation = SZFriendsRelationOutgoingRequest;
    person.requestAt = now;
    person.requestFoundNearby = NO;
    person.lastInteractionAt = now;
    // What an old friendship earned does not come back with a new request (SZFriendsStore (AddByID)).
    person.comparisonCode = nil;
    person.autoAccept = NO;
    NSError *error = nil;
    if (![store savePerson:person error:&error]) {
        [self fail:reply code:SZFriendsStoreProtocolErrorCode(error) details:nil connection:connection];
        return;
    }
    SZFriendsIDRequestRecord *request = [[SZFriendsIDRequestRecord alloc] init];
    request.conversationID = person.conversationID;
    request.targetFriendsID = friendsID;
    request.callbackSecret = SZFriendsNewPresenceSecret();
    request.requestToken = SZFriendsMentionRequestToken(request.callbackSecret, key);
    request.createdAt = now;
    request.expiresAt = [now dateByAddingTimeInterval:SZFriendsIDRequestLifetime];
    if (![store saveIDRequest:request error:&error]) {
        // A row left asking with no request would say "Request sent" untruly: lapsing takes it back at once.
        [store expireOutgoingRequestsAtDate:now error:NULL];
        BOOL limit = [error.domain isEqualToString:SZFriendsStoreErrorDomain] &&
                     error.code == SZFriendsStoreErrorConstraint;
        [self fail:reply code:limit ? @"rate_limited" : SZFriendsStoreProtocolErrorCode(error) details:nil
            connection:connection];
        return;
    }
    [self enqueueKind:SZFriendsOutboxKindRequest conversationID:person.conversationID payload:nil];
    // Its callback tags go on the air and the NN request goes to every device nearby, as for add_by_id (ADR 0004).
    [self.services.nearby peopleChanged];
    SZFriendsStrings *strings = [self.publisher stateForConnection:connection].strings;
    BOOL online = self.services.nearby.reachesFriendsOnline;
    [self succeed:reply result:@{@"conversation_id" : person.conversationID,
                                 @"message" : [strings addFromMentionSentMessageForName:name online:online]}];
}

@end
