// Intents about people: requests and their answers, Add by ID, block, remove, verification, key changes.
//
// Each changes the store and queues what the other side must learn in the outbox; the session layer delivers it
// when a route exists. Removing or blocking someone tells them nothing (brief § Outbox and delivery): only our
// presence secret changes, so they can no longer recognise us nearby.

#import "service/helper/SZFriendsIntentRouter.h"

#import "service/discovery/SZFriendsDiscovery.h"
#import "service/helper/nearby/SZFriendsNearbyService.h"

@implementation SZFriendsIntentRouter (People)

- (BOOL)savePerson:(SZFriendsPersonRecord *)person
             reply:(SZFriendsIntentReply)reply
        connection:(SZFriendsIPCConnection *)connection {
    NSError *error = nil;
    if ([self.services.store savePerson:person error:&error]) return YES;
    [self fail:reply code:SZFriendsStoreProtocolErrorCode(error) details:nil connection:connection];
    return NO;
}

// Remove and block: nothing still waiting for this person goes out any more, not the answer they wait for and not a
// presence secret queued at acceptance or at an earlier rotation, which the session would fill with our current one
// (review: presence secret rotation). Removing someone tells them nothing.
- (void)refusePendingEntriesOfConversation:(NSString *)conversationID {
    for (SZFriendsOutboxEntry *entry in [self.services.outbox pendingEntriesForConversation:conversationID]) {
        [self.services.outbox applyEvent:SZFriendsOutboxEventRefused toEntry:entry.entryID error:NULL];
    }
}

// Remove and block: their offers still waiting for an answer are declined, quietly like the rest (nothing tells them),
// so the pictures that came with them go now, with the offer's state in one transaction, rather than when the offers
// expire (security review, wave 6a). None of them could arrive now anyway: no session opens to them.
- (void)declineWaitingOffersOfConversation:(NSString *)conversationID {
    for (SZFriendsTransferRecord *transfer in [self.services.transfers transfersInConversation:conversationID]) {
        if (transfer.outgoing || transfer.state != SZFriendsTransferStateWaitingForYou) continue;
        [self.services.transfers declineTransfer:transfer.transferID error:NULL];
    }
}

// A new presence secret, sent to every friend who remains, after a remove or block (ADR 0004): the person removed
// keeps only the old secret, whose tags stop matching anything.
- (void)rotatePresenceSecretExcept:(NSString *)conversationID {
    SZFriendsStore *store = self.services.store;
    store.ownPresenceSecret = SZFriendsNewPresenceSecret();
    for (SZFriendsPersonRecord *friend in [store peopleByLatestInteraction]) {
        // You (no keys) is nobody to tell.
        if (friend.relation != SZFriendsRelationFriend || friend.identityKey == nil ||
            [friend.conversationID isEqualToString:conversationID]) {
            continue;
        }
        [self enqueueKind:SZFriendsOutboxKindPresenceSecret conversationID:friend.conversationID payload:nil];
    }
}

- (void)intent_accept_request:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                        reply:(SZFriendsIntentReply)reply {
    SZFriendsPersonRecord *person = [self personForIntent:intent reply:reply connection:connection];
    if (person == nil) return;
    if (person.relation != SZFriendsRelationIncomingRequest) {
        [self fail:reply code:@"stale" details:nil connection:connection];
        return;
    }
    SZFriendsStore *store = self.services.store;
    if (store.ownPresenceSecret == nil) store.ownPresenceSecret = SZFriendsNewPresenceSecret();
    person.relation = SZFriendsRelationFriend;
    person.lastInteractionAt = [NSDate date];
    if (![self savePerson:person reply:reply connection:connection]) return;
    [self recordEvent:SZFriendsEventNowFriends inConversation:person.conversationID];
    // The answer, then our presence secret, so the new friend can find us privately from now on.
    [self enqueueKind:SZFriendsOutboxKindAnswer conversationID:person.conversationID payload:@{@"frame" : @"accept"}];
    [self enqueueKind:SZFriendsOutboxKindPresenceSecret conversationID:person.conversationID payload:nil];
    [self.services.nearby peopleChanged];
    [self succeed:reply result:nil];
}

- (void)intent_decline_request:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                         reply:(SZFriendsIntentReply)reply {
    SZFriendsPersonRecord *person = [self personForIntent:intent reply:reply connection:connection];
    if (person == nil) return;
    if (person.relation != SZFriendsRelationIncomingRequest) {
        [self fail:reply code:@"stale" details:nil connection:connection];
        return;
    }
    if (![self declineRequestOf:person reply:reply connection:connection]) return;
    [self.services.nearby peopleChanged];
    [self succeed:reply result:nil];
}

// Removed, not blocked: the person can ask again later (PROTOCOL.md decline_request). Also remove_friend's first step
// for an incoming request.
- (BOOL)declineRequestOf:(SZFriendsPersonRecord *)person
                   reply:(SZFriendsIntentReply)reply
              connection:(SZFriendsIPCConnection *)connection {
    person.relation = SZFriendsRelationRemoved;
    if (![self savePerson:person reply:reply connection:connection]) return NO;
    [self enqueueKind:SZFriendsOutboxKindAnswer conversationID:person.conversationID payload:@{@"frame" : @"decline"}];
    return YES;
}

- (void)intent_cancel_request:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                        reply:(SZFriendsIntentReply)reply {
    SZFriendsPersonRecord *person = [self personForIntent:intent reply:reply connection:connection];
    if (person == nil) return;
    if (person.relation != SZFriendsRelationOutgoingRequest) {
        [self fail:reply code:@"stale" details:nil connection:connection];
        return;
    }
    if (![self cancelRequestTo:person reply:reply connection:connection]) return;
    [self.services.nearby peopleChanged];
    [self succeed:reply result:nil];
}

// Also remove_friend's first step for an outgoing request.
- (BOOL)cancelRequestTo:(SZFriendsPersonRecord *)person
                  reply:(SZFriendsIntentReply)reply
             connection:(SZFriendsIPCConnection *)connection {
    person.relation = SZFriendsRelationRemoved;
    if (![self savePerson:person reply:reply connection:connection]) return NO;
    [self.services.store deleteIDRequestForConversation:person.conversationID error:NULL];
    // A request still waiting in the outbox must not go out after the person withdrew it; one already delivered is
    // withdrawn with a CANCEL.
    for (SZFriendsOutboxEntry *entry in [self.services.outbox pendingEntriesForConversation:person.conversationID]) {
        if (entry.kind == SZFriendsOutboxKindRequest) {
            [self.services.outbox applyEvent:SZFriendsOutboxEventRefused toEntry:entry.entryID error:NULL];
        }
    }
    [self enqueueKind:SZFriendsOutboxKindAnswer conversationID:person.conversationID payload:@{@"frame" : @"cancel"}];
    return YES;
}

- (void)intent_send_request:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                      reply:(SZFriendsIntentReply)reply {
    NSString *nearbyID = [self requiredString:@"nearby_id" in:intent maxLength:64 reply:reply connection:connection];
    if (nearbyID == nil) return;
    // Only someone a browse identified: their key came from their own public entry's handshake.
    SZFriendsNearbyStranger *stranger = [self.services.nearby strangerWithNearbyID:nearbyID];
    if (stranger == nil) {
        [self fail:reply code:@"not_found" details:@{@"field" : @"nearby_id"} connection:connection];
        return;
    }
    SZFriendsStore *store = self.services.store;
    SZFriendsPersonRecord *person = [store personWithIdentityKey:stranger.identityKey];
    if (person.relation == SZFriendsRelationFriend) {
        [self fail:reply code:@"already_friends" details:nil connection:connection];
        return;
    }
    if (person.relation == SZFriendsRelationBlocked) {
        [self fail:reply code:@"blocked" details:nil connection:connection];
        return;
    }
    // (A nil person's relation reads as 0, IncomingRequest: only an existing row is "already asked".)
    if (person != nil && (person.relation == SZFriendsRelationOutgoingRequest ||
                          person.relation == SZFriendsRelationIncomingRequest)) {
        [self succeed:reply result:nil]; // already asked, or they asked us: the row exists
        return;
    }
    NSDate *now = [NSDate date];
    if (person == nil) {
        person = [[SZFriendsPersonRecord alloc] init];
        person.conversationID = SZFriendsNewIdentifier();
    }
    person.identityKey = stranger.identityKey;
    // A stored static key changes only through review (the store refuses a silent swap); the request itself goes to
    // their public entry with XX, which needs none.
    if (person.staticKey == nil) person.staticKey = stranger.staticKey;
    person.name = stranger.name;
    person.friendsID = stranger.friendsID;
    person.picture = stranger.picture;
    person.relation = SZFriendsRelationOutgoingRequest;
    person.requestAt = now;
    person.requestFoundNearby = YES;
    person.lastInteractionAt = now;
    if (![self savePerson:person reply:reply connection:connection]) return;
    // Delivered over XX to their public entry while they are visible; the outbox keeps it until then.
    [self enqueueKind:SZFriendsOutboxKindRequest conversationID:person.conversationID payload:nil];
    [self.services.nearby peopleChanged];
    [self succeed:reply result:nil];
}

- (void)intent_add_by_id:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                   reply:(SZFriendsIntentReply)reply {
    NSString *typed = [self requiredString:@"friends_id" in:intent maxLength:100 reply:reply connection:connection];
    if (typed == nil) return;
    SZFriendsStore *store = self.services.store;
    NSString *friendsID = [self.services.codec normalizedID:typed];
    if (friendsID == nil) {
        [self fail:reply code:@"id_invalid" details:@{@"field" : @"friends_id"} connection:connection];
        return;
    }
    if ([friendsID isEqualToString:store.friendsID]) {
        [self fail:reply code:@"id_is_yours" details:nil connection:connection];
        return;
    }
    SZFriendsStrings *strings = [self.publisher stateForConnection:connection].strings;
    BOOL online = self.services.nearby.reachesFriendsOnline; // the request also goes through the host
    // A row's Friends ID is whatever that person's own PROFILE last said, so it proves nothing about who holds the ID
    // now (wave-4 security re-check): only two kinds of row stop a new request. A friend or a blocked person whose ID
    // the host confirmed, and our own keyless "Request sent" row while its request is still out, which is the same
    // request asked again. Any other row with this ID (a request either way, a removed person, a friend who only
    // claimed it) leaves the request to go out to everyone nearby, so the holder's attested answer can arrive and get
    // its own row; startIDRequest reuses a keyless row whose request expired or was answered.
    NSDate *now = [NSDate date];
    NSMutableSet<NSString *> *pending = [NSMutableSet set];
    for (SZFriendsIDRequestRecord *waiting in [store pendingIDRequestsAtDate:now]) {
        [pending addObject:waiting.conversationID];
    }
    for (SZFriendsPersonRecord *candidate in [store peopleByLatestInteraction]) {
        if (![candidate.friendsID isEqualToString:friendsID]) continue;
        BOOL confirmed = candidate.friendsIDConfirmed;
        if (candidate.relation == SZFriendsRelationFriend && confirmed) {
            [self fail:reply code:@"already_friends" details:nil connection:connection];
            return;
        }
        if (candidate.relation == SZFriendsRelationBlocked && confirmed) {
            [self fail:reply code:@"blocked" details:nil connection:connection];
            return;
        }
        if (candidate.relation == SZFriendsRelationOutgoingRequest && candidate.identityKey == nil &&
            [pending containsObject:candidate.conversationID]) {
            reply(@{@"conversation_id" : candidate.conversationID,
                    @"message" : [strings addByIDSentMessageForID:friendsID online:online]},
                  nil, nil, nil);
            return;
        }
    }
    NSString *message = [strings addByIDSentMessageForID:friendsID online:online];
    SZFriendsIDRequestRecord *request = [[SZFriendsIDRequestRecord alloc] init];
    request.targetFriendsID = friendsID;
    request.requestToken = [SZFriendsHelperServices randomBytes:16];
    request.callbackSecret = SZFriendsNewPresenceSecret();
    request.createdAt = now;
    request.expiresAt = [now dateByAddingTimeInterval:SZFriendsIDRequestLifetime];
    // The "Request sent" row and its request in one transaction (a keyless row, reused when one is waiting).
    NSError *error = nil;
    NSString *conversationID = [store startIDRequest:request error:&error];
    if (conversationID == nil) {
        // At most four pending (ADR 0004); a fifth waits until one is answered or expires. Answered requests, which
        // stay so a second holder can answer, do not count (SZFriendsStore (AddByID)).
        BOOL limit = [error.domain isEqualToString:SZFriendsStoreErrorDomain] &&
                     error.code == SZFriendsStoreErrorConstraint;
        [self fail:reply code:limit ? @"rate_limited" : SZFriendsStoreProtocolErrorCode(error) details:nil
            connection:connection];
        return;
    }
    [self enqueueKind:SZFriendsOutboxKindRequest conversationID:conversationID payload:nil];
    // Its callback tags go on the air and the NN request goes to every device nearby (ADR 0004).
    [self.services.nearby peopleChanged];
    [self succeed:reply result:@{@"conversation_id" : conversationID, @"message" : message}];
}

- (void)intent_block:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
               reply:(SZFriendsIntentReply)reply {
    SZFriendsPersonRecord *person = [self personForIntent:intent reply:reply connection:connection];
    if (person == nil) return;
    if (person.relation == SZFriendsRelationBlocked) {
        [self succeed:reply result:nil];
        return;
    }
    BOOL wasFriend = person.relation == SZFriendsRelationFriend;
    person.relation = SZFriendsRelationBlocked;
    person.autoAccept = NO; // turns itself off on block (brief § Product contract)
    if (![self savePerson:person reply:reply connection:connection]) return;
    [self.services.store deleteIDRequestForConversation:person.conversationID error:NULL];
    [self refusePendingEntriesOfConversation:person.conversationID];
    [self declineWaitingOffersOfConversation:person.conversationID];
    [self recordEvent:SZFriendsEventBlocked inConversation:person.conversationID];
    if (wasFriend) [self rotatePresenceSecretExcept:person.conversationID];
    // Their session closes now, our new tag goes on the air, and their tags stop matching.
    [self.services.nearby peopleChanged];
    [self succeed:reply result:nil];
}

- (void)intent_unblock:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                 reply:(SZFriendsIntentReply)reply {
    SZFriendsPersonRecord *person = [self personForIntent:intent reply:reply connection:connection];
    if (person == nil) return;
    if (person.relation != SZFriendsRelationBlocked) {
        [self fail:reply code:@"stale" details:nil connection:connection];
        return;
    }
    // Back to "removed": the block rotated our presence secret away from them, so friendship needs a new
    // request from either side rather than resuming silently.
    person.relation = SZFriendsRelationRemoved;
    if (![self savePerson:person reply:reply connection:connection]) return;
    [self recordEvent:SZFriendsEventUnblocked inConversation:person.conversationID];
    [self.services.nearby peopleChanged];
    [self succeed:reply result:nil];
}

// Takes anyone but You off the list (PROTOCOL.md remove_friend). A friend is removed first, quietly as ever; a request
// is declined or withdrawn exactly as decline_request and cancel_request do; anyone else (a former friend, someone
// who removed us, a link contact, a blocked person, who stays blocked) only leaves the list. The row and its history
// stay unless delete_history asks for that too, and a new request from either side brings them back.
- (void)intent_remove_friend:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                       reply:(SZFriendsIntentReply)reply {
    id deleteHistory = intent[@"delete_history"];
    if (deleteHistory == [NSNull null]) deleteHistory = nil;
    if (deleteHistory != nil && !SZFriendsJSONIsBool(deleteHistory)) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"delete_history"} connection:connection];
        return;
    }
    SZFriendsPersonRecord *person = [self personForIntent:intent reply:reply connection:connection];
    if (person == nil) return;
    if ([self isYou:person]) {
        [self fail:reply code:@"not_allowed" details:nil connection:connection];
        return;
    }
    if (person.leftListAt != nil) {
        [self succeed:reply result:nil]; // already off the list
        return;
    }
    switch (person.relation) {
    case SZFriendsRelationFriend:
        if (![self removeFriend:person reply:reply connection:connection]) return;
        break;
    case SZFriendsRelationIncomingRequest:
        if (![self declineRequestOf:person reply:reply connection:connection]) return;
        break;
    case SZFriendsRelationOutgoingRequest:
        if (![self cancelRequestTo:person reply:reply connection:connection]) return;
        break;
    case SZFriendsRelationRemoved:
    case SZFriendsRelationBlocked:
        break;
    }
    // After any history event above, so the removal is the last thing that happened to them here.
    person.leftListAt = [NSDate date];
    if (![self savePerson:person reply:reply connection:connection]) return;
    [self.services.nearby peopleChanged];
    if ([deleteHistory boolValue] && ![self eraseHistoryInConversation:person.conversationID]) {
        [self fail:reply code:@"internal" details:nil connection:connection];
        return;
    }
    [self succeed:reply result:nil];
}

// Removing a friend tells them nothing (brief § Outbox and delivery).
- (BOOL)removeFriend:(SZFriendsPersonRecord *)person
               reply:(SZFriendsIntentReply)reply
          connection:(SZFriendsIPCConnection *)connection {
    person.relation = SZFriendsRelationRemoved;
    person.autoAccept = NO;
    if (![self savePerson:person reply:reply connection:connection]) return NO;
    [self refusePendingEntriesOfConversation:person.conversationID];
    [self declineWaitingOffersOfConversation:person.conversationID];
    [self recordEvent:SZFriendsEventRemoved inConversation:person.conversationID];
    [self rotatePresenceSecretExcept:person.conversationID];
    return YES;
}

- (void)intent_mark_verified:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                       reply:(SZFriendsIntentReply)reply {
    SZFriendsPersonRecord *person = [self personForIntent:intent reply:reply connection:connection];
    if (person == nil) return;
    if (person.relation != SZFriendsRelationFriend) {
        [self fail:reply code:@"not_friends" details:nil connection:connection];
        return;
    }
    if (person.verified) {
        [self succeed:reply result:nil];
        return;
    }
    person.verified = YES;
    person.verifiedAt = [NSDate date];
    if (![self savePerson:person reply:reply connection:connection]) return;
    [self recordEvent:SZFriendsEventVerified inConversation:person.conversationID];
    [self succeed:reply result:nil];
}

- (void)intent_accept_key_change:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                           reply:(SZFriendsIntentReply)reply {
    SZFriendsPersonRecord *person = [self personForIntent:intent reply:reply connection:connection];
    if (person == nil) return;
    if (!person.keyChangePending) {
        [self fail:reply code:@"stale" details:nil connection:connection];
        return;
    }
    // The reviewed path: the key they presented becomes the one we dial, and nothing the old key earned carries over
    // (verification and automatic acceptance off). Codes must be compared again.
    NSError *error = nil;
    if (![self.services.store acceptPendingStaticKeyForConversation:person.conversationID error:&error]) {
        BOOL nothingKept = [error.domain isEqualToString:SZFriendsStoreErrorDomain] &&
                           error.code == SZFriendsStoreErrorStale;
        if (!nothingKept) {
            [self fail:reply code:SZFriendsStoreProtocolErrorCode(error) details:nil connection:connection];
            return;
        }
        // Marked without a key the store could check (Sessions): continuing keeps the key we know, unverified.
        SZFriendsPersonRecord *current = [self.services.store personWithConversationID:person.conversationID];
        current.keyChangePending = NO;
        current.verified = NO;
        current.verifiedAt = nil;
        if (current == nil || ![self savePerson:current reply:reply connection:connection]) return;
    }
    [self recordEvent:SZFriendsEventKeyAccepted inConversation:person.conversationID];
    [self.services.nearby keyChangeAccepted:person.conversationID];
    [self succeed:reply result:nil];
}

- (void)intent_set_auto_accept:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                         reply:(SZFriendsIntentReply)reply {
    SZFriendsPersonRecord *person = [self personForIntent:intent reply:reply connection:connection];
    if (person == nil) return;
    id enabled = intent[@"enabled"];
    if (!SZFriendsJSONIsBool(enabled)) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"enabled"} connection:connection];
        return;
    }
    if (person.relation != SZFriendsRelationFriend || ([enabled boolValue] && person.keyChangePending)) {
        [self fail:reply code:@"not_allowed" details:nil connection:connection];
        return;
    }
    person.autoAccept = [enabled boolValue];
    if (![self savePerson:person reply:reply connection:connection]) return;
    [self succeed:reply result:nil];
}

@end
