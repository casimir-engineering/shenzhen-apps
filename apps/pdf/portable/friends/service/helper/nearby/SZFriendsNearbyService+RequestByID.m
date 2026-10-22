// Add by ID nearby (ADR 0004 § Add by ID nearby): the requester's NN session to every device, the uniform reply
// every device gives, the holder's request row, and the IK callback that presents the requester's token.
//
// Anyone who hears the broadcast can answer it (the token proves only that), so: at most three distinct keys may
// answer one request, the last of them only with the host's attestation (+Attestation), each becomes its own
// unverified person and is never merged into another; a session let in by
// the token alone carries friendship creation only (+Inbound); and the callback secret behind the advertised
// callback tags changes every day and its tags are on the air only for hours after a broadcast carried it, and only
// while nobody has answered (review: Add by ID and callback tags).

#import "service/helper/nearby/SZFriendsNearbyInternal.h"
#import "service/helper/nearby/SZFriendsNearbyInvites.h"

#import <sodium.h>

// ADR 0004 step 2: per sender key, one request an hour (the listener-wide rate is the adapters', Limits.h).
static const NSTimeInterval SZFriendsByIDSenderInterval = 3600;
static const NSTimeInterval SZFriendsCallbackDayLength = 86400;

int64_t SZFriendsCallbackDay(NSDate *createdAt, NSDate *now) {
    NSTimeInterval age = [now timeIntervalSinceDate:createdAt];
    return age > 0 ? (int64_t)floor(age / SZFriendsCallbackDayLength) : 0;
}

NSData *SZFriendsCallbackSecretForDay(NSData *masterSecret, int64_t day) {
    NSUInteger length = masterSecret.length;
    if (length < crypto_generichash_KEYBYTES_MIN || length > crypto_generichash_KEYBYTES_MAX) {
        return [NSData data];
    }
    static const char domain[] = "SZFriends callback day v1";
    uint8_t message[sizeof(domain) - 1 + 8];
    memcpy(message, domain, sizeof(domain) - 1);
    uint64_t value = day > 0 ? (uint64_t)day : 0;
    for (int i = 0; i < 8; i++) message[sizeof(domain) - 1 + i] = (uint8_t)(value >> (56 - 8 * i));
    uint8_t secret[32];
    crypto_generichash(secret, sizeof secret, message, sizeof message, masterSecret.bytes, masterSecret.length);
    return [NSData dataWithBytes:secret length:sizeof secret];
}

@implementation SZFriendsNearbyService (RequestByID)

#pragma mark - Requester

- (NSArray<SZFriendsPendingCallback *> *)advertisedCallbacksAtDate:(NSDate *)now {
    NSMutableArray<SZFriendsPendingCallback *> *callbacks = [NSMutableArray array];
    // Pending means nobody answered yet; an answered request still admits its token but goes on the air no more.
    for (SZFriendsIDRequestRecord *request in [self.services.store pendingIDRequestsAtDate:now]) {
        int64_t day = SZFriendsCallbackDay(request.createdAt, now);
        NSDate *dayStart = [request.createdAt dateByAddingTimeInterval:(double)day * SZFriendsCallbackDayLength];
        // Read back from the store a date can land a hair after the moment it was taken; never in our future.
        if ([dayStart compare:now] == NSOrderedDescending) dayStart = now;
        NSDate *broadcast = self.callbackBroadcasts[SZFriendsLinkHex(request.requestToken)];
        // A broadcast on an earlier day carried an earlier secret: today's tags wait for today's first broadcast.
        if (broadcast != nil && SZFriendsCallbackDay(request.createdAt, broadcast) != day) broadcast = nil;
        NSData *secret = SZFriendsCallbackSecretForDay(request.callbackSecret, day);
        if (secret.length != SZFriendsPresenceSecretLength) continue;
        [callbacks addObject:[[SZFriendsPendingCallback alloc] initWithCallbackSecret:secret
                                                                            createdAt:request.createdAt
                                                                            expiresAt:request.expiresAt
                                                                       secretIssuedAt:dayStart
                                                                      lastBroadcastAt:broadcast]];
    }
    [self scheduleCallbackRefreshAt:SZFriendsCallbackNextChange(callbacks, now)];
    return callbacks;
}

// The advertisement changes when a 6-hour window or a day ends, not only at a presence window's boundary.
- (void)scheduleCallbackRefreshAt:(nullable NSDate *)when {
    NSUInteger generation = ++self.callbackRefreshGeneration;
    if (when == nil) return;
    NSTimeInterval wait = MAX(0.05, when.timeIntervalSinceNow + 0.05);
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), self.queue, ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        if (strongSelf != nil && strongSelf.callbackRefreshGeneration == generation) [strongSelf refreshAdvertisement];
    });
}

// REQUEST_BY_ID for our request `token`, signed over `handshakeHash` (an NN session's, nearby or online), with the
// proof of the invite it presents; nil once the request is no longer pending (answered, withdrawn or expired).
- (nullable SZFriendsFrame *)requestByIDFrameForToken:(NSData *)token handshakeHash:(NSData *)handshakeHash {
    NSDate *now = [NSDate date];
    SZFriendsIDRequestRecord *request = nil;
    for (SZFriendsIDRequestRecord *pending in [self.services.store pendingIDRequestsAtDate:now]) {
        if ([pending.requestToken isEqualToData:token]) request = pending;
    }
    // Today's callback secret, never the master: whoever hears this can recognise our callback tags only today.
    NSData *secret = request ? SZFriendsCallbackSecretForDay(request.callbackSecret,
                                                             SZFriendsCallbackDay(request.createdAt, now))
                             : nil;
    SZFriendsFrame *frame = request ? SZFriendsMakeRequestByIDFrame(self.services.identity, request.targetFriendsID,
                                                                    request.requestToken, secret, handshakeHash)
                                    : nil;
    return frame ? [self requestFrame:frame presentingInvite:request handshakeHash:handshakeHash] : nil;
}

- (void)sendRequestByIDOnLink:(SZFriendsPeerLink *)link {
    NSDate *now = [NSDate date];
    SZFriendsFrame *frame = [self requestByIDFrameForToken:link.requestToken handshakeHash:link.channel.handshakeHash];
    if (frame == nil || ![link.channel sendFrame:frame]) {
        [link.channel close];
        return;
    }
    // Its callback tags go on the air for the next hours (SZFriendsCallbackTagsToAdvertise).
    self.callbackBroadcasts[SZFriendsLinkHex(link.requestToken)] = now;
    [self refreshAdvertisement];
    // RECEIVED closes it (+Inbound); a device that never answers is let go.
    [self closeLink:link after:SZFriendsByIDSessionLife];
}

#pragma mark - Every device

- (void)link:(SZFriendsPeerLink *)link receivedRequestByID:(SZFriendsFrame *)frame {
    // RECEIVED before any lookup or check, with the same bytes from every device, and the session closed the same
    // moment after it, so neither content nor timing says whether this device holds the ID (ADR 0004 step 2).
    [link.channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeReceived fields:@{}]];
    [self closeLink:link after:SZFriendsByIDReplyLinger];
    [self receivedRequestByID:frame handshakeHash:link.channel.handshakeHash];
}

// The holder's side of a request, from nearby or online, once RECEIVED is on its way: only the holder of the ID keeps
// anything, and only from someone not blocked and not asking again within the hour.
- (void)receivedRequestByID:(SZFriendsFrame *)frame handshakeHash:(NSData *)handshakeHash {
    NSData *key = SZFriendsVerifyRequestByIDFrame(frame, handshakeHash);
    if (key.length != 32 || [key isEqualToData:[self localIdentityKey]]) return;
    SZFriendsStore *store = self.services.store;
    NSString *typed = [frame stringForTag:SZFriendsFieldFriendsID];
    NSString *target = typed ? [self.services.codec normalizedID:typed] : nil;
    // Non-holders keep nothing.
    if (target == nil || ![target isEqualToString:store.friendsID]) return;
    NSString *keyHex = SZFriendsLinkHex(key);
    NSDate *last = self.byIDSenders[keyHex];
    if (last != nil && -last.timeIntervalSinceNow < SZFriendsByIDSenderInterval) return;
    SZFriendsPersonRecord *person = [store personWithIdentityKey:key];
    // Blocked senders are dropped after the same reply.
    if (person.relation == SZFriendsRelationBlocked) return;
    self.byIDSenders[keyHex] = [NSDate date];
    NSData *token = [frame dataForTag:SZFriendsFieldToken];
    if (person.relation == SZFriendsRelationFriend) {
        [self answerFriend:person askingByIDWithFrame:frame];
        return;
    }
    if (person.relation == SZFriendsRelationIncomingRequest && [person.callbackToken isEqualToData:token]) {
        // The same request broadcast again on a later day: only its callback secret is new. The row stays where it
        // is; nothing new happened from the person's side.
        person.callbackSecret = [frame dataForTag:SZFriendsFieldCallbackSecret];
        if ([store savePerson:person error:NULL]) [self rebuildTagMatcher];
        return;
    }
    NSDate *now = [NSDate date];
    BOOL mutual = person.relation == SZFriendsRelationOutgoingRequest;
    // Made through our friend link: accepted at once, as a request we had sent them would make it (friends-links.md).
    BOOL invited = !mutual && [self requestUsesLiveInvite:frame handshakeHash:handshakeHash];
    BOOL askedBefore = person != nil && person.relation == SZFriendsRelationIncomingRequest;
    if (person == nil) {
        person = [[SZFriendsPersonRecord alloc] init];
        person.conversationID = SZFriendsNewIdentifier();
        person.picture = [SZFriendsPicture placeholder];
    }
    person.identityKey = key;
    NSData *staticKey = [frame dataForTag:SZFriendsFieldStaticKey];
    if (person.staticKey != nil && ![person.staticKey isEqualToData:staticKey]) {
        // Another static key certified by the same identity: kept for review, never swapped in (Sessions).
        person = [self notePresentedStaticKey:staticKey certificate:[frame dataForTag:SZFriendsFieldCertificate]
                                       person:person];
        if (person == nil) return;
    } else {
        person.staticKey = staticKey;
    }
    // Their token lets our IK callback in after Accept; their callback tags tell us when they are nearby.
    person.callbackToken = token;
    person.callbackSecret = [frame dataForTag:SZFriendsFieldCallbackSecret];
    person.relation = mutual || invited ? SZFriendsRelationFriend : SZFriendsRelationIncomingRequest;
    // A new request gets its own comparison code, exchanged on the callback after Accept, as a nearby request does
    // (+Inbound): the requester's row starts without one even when it was ours before (we removed them, or declined),
    // and both sides must run the exchange or neither shows a code.
    if (!mutual && !askedBefore) person.comparisonCode = nil;
    person.requestAt = now;
    person.requestFoundNearby = NO; // by Friends ID: the request card says so
    person.lastInteractionAt = now;
    NSError *error = nil;
    if (![store savePerson:person error:&error]) {
        SZFriendsHelperLog(@"could not store a request by ID: %@", error.localizedDescription);
        return;
    }
    if (mutual || invited) {
        // We had asked them too, or invited them: two requests are two acceptances, and a link is our request.
        SZFriendsNearbyRecordEvent(store, invited ? SZFriendsEventAddedThroughOurLink : SZFriendsEventNowFriends,
                                   person.conversationID);
        [self enqueueKind:SZFriendsOutboxKindAnswer
           conversationID:person.conversationID
                  payload:@{@"frame" : @"accept"}];
        [self enqueueKind:SZFriendsOutboxKindPresenceSecret conversationID:person.conversationID payload:nil];
    }
    // Through our friend link they are friends at once; their request and ours make friends too; otherwise a new
    // request (one asked again on another day is the same request).
    if (invited) [self.services.notifier noteLinkUsedBy:person];
    else if (mutual) [self.services.notifier noteAcceptedBy:person];
    else if (!askedBefore) [self.services.notifier noteRequestFrom:person];
    [self rebuildTagMatcher];
    [self changed];
}

// Still a friend here: they removed us, which we are never told, and ask again by our Friends ID (PROTOCOL.md
// remove_friend), or they repeat a request we accepted. Either way they wait for an answer: an acceptance, as
// accept_request sends, on the callback their token lets in, and the conversation goes on. A request presenting another
// static key is not answered (the key policy reviews key changes); one broadcast again on a later day, while our
// acceptance is still on its way, only renews the callback.
- (void)answerFriend:(SZFriendsPersonRecord *)person askingByIDWithFrame:(SZFriendsFrame *)frame {
    NSData *token = [frame dataForTag:SZFriendsFieldToken];
    NSData *callbackSecret = [frame dataForTag:SZFriendsFieldCallbackSecret];
    NSData *staticKey = [frame dataForTag:SZFriendsFieldStaticKey];
    if (token.length != 16 || callbackSecret.length != 32 || person.keyChangePending) return;
    if (person.staticKey != nil && ![person.staticKey isEqualToData:staticKey]) return;
    BOOL answering = person.callbackToken != nil; // our acceptance of an earlier request has not landed yet
    person.callbackToken = token;
    person.callbackSecret = callbackSecret;
    SZFriendsStore *store = self.services.store;
    NSError *error = nil;
    if (![store savePerson:person error:&error]) {
        SZFriendsHelperLog(@"could not store a friend's request by ID: %@", error.localizedDescription);
        return;
    }
    // They are nearby and waiting now: the backoff our dials earned while they had us removed (refused, every one)
    // no longer holds the answer back.
    [self noteSuccessForConversation:person.conversationID];
    if (!answering) {
        if (store.ownPresenceSecret == nil) store.ownPresenceSecret = SZFriendsNewPresenceSecret();
        [self enqueueKind:SZFriendsOutboxKindAnswer
           conversationID:person.conversationID
                  payload:@{@"frame" : @"accept"}];
        [self enqueueKind:SZFriendsOutboxKindPresenceSecret conversationID:person.conversationID payload:nil];
    }
    [self rebuildTagMatcher];
    [self changed];
}

#pragma mark - The callback

// Which conversation an IK callback presenting our token belongs to, decided and recorded by the store in one
// transaction: the same key again gets its earlier conversation, a known person keeps theirs (the keyless row
// add_by_id made folds into it, and someone we had removed becomes our request again), the request's own row takes
// the first key, and every further key (at most three in all, the last only for an attested holder) gets a person of
// its own, never merged. The answer's attestation (+Attestation) then confirms the holder's ID, or refuses the answer.
- (nullable NSString *)conversationForCallbackLink:(SZFriendsPeerLink *)link {
    NSData *token = link.channel.presentedRequestToken;
    NSData *key = link.channel.remoteIdentityKey, *staticKey = link.channel.remoteStaticKey;
    if (token == nil || key == nil || staticKey == nil) return nil;
    SZFriendsStore *store = self.services.store;
    NSDate *now = [NSDate date];
    // The key policy already refused another key for an Add from a mention; this holds even if a path skips it.
    if ([self requestToken:token refusesIdentityKey:key atDate:now]) return nil;
    SZFriendsHostAttestation *attestation = nil;
    SZFriendsAnswerAttestation said = [self judgeAnswerWithToken:token identityKey:key
                                                       presented:link.channel.remoteAttestation now:now
                                                     attestation:&attestation];
    if (said == SZFriendsAnswerRefused) {
        SZFriendsHelperLog(@"an Add by ID answer showed another key's attestation; refused");
        return nil;
    }
    NSString *requested = [store idRequestWithToken:token atDate:now].targetFriendsID;
    BOOL keyKnown = [store personWithIdentityKey:key] != nil;
    NSError *error = nil;
    NSString *conversationID = [store conversationForIDRequestAnswerWithToken:token
                                                                  identityKey:key
                                                                    staticKey:staticKey
                                                                     attested:said == SZFriendsAnswerAttested
                                                                       atDate:now
                                                                        error:&error];
    if (conversationID == nil) {
        SZFriendsHelperLog(@"an Add by ID answer was not admitted: %ld", (long)error.code);
        return nil;
    }
    [self recordAnswerInConversation:conversationID attestation:attestation requestedID:requested keyKnown:keyKnown];
    if ([self requestTokenCameFromLink:token]) {
        SZFriendsNearbyRecordEvent(store, SZFriendsEventAddedThroughTheirLink, conversationID);
        SZFriendsPersonRecord *person = [store personWithConversationID:conversationID];
        if (person != nil) [self.services.notifier noteLinkAddedWith:person];
    }
    link.answerForID = requested;
    link.answerAttested = said == SZFriendsAnswerAttested;
    return conversationID;
}

- (void)callbackLinkWentLive:(SZFriendsPeerLink *)link {
    (void)link;
    // An answer takes the request off the air: answered requests are no longer pending.
    [self refreshAdvertisement];
    [self changed];
}

@end
