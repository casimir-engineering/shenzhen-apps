// Secure channels: starting links, which link carries a conversation, and what happens when one ends (ADR 0001
// § Session race, ADR 0004 § Hidden listeners, § Public visibility). Who may connect at all is +KeyPolicy.

#import "service/helper/nearby/SZFriendsNearbyDevices.h"
#import "service/sync/SZFriendsAgain.h"
#import "service/helper/nearby/SZFriendsNearbyJoin.h"

#import "service/identity/SZFriendsIdentity.h"

@implementation SZFriendsNearbyService (Sessions)

#pragma mark - Starting links

- (void)acceptStream:(id<SZFriendsByteStream>)stream route:(SZFriendsRouteMethod)route publicEntry:(BOOL)publicEntry {
    // The public profile only on the public entry, and only while the 5 minutes last: a connection that arrives
    // just after the deadline meets a hidden listener (ADR 0004 § Public visibility).
    BOOL visible = publicEntry && [self.visibility isVisibleAt:SZFriendsInstantNow()];
    NSDictionary<NSNumber *, NSData *> *profile = visible ? [self profileFields] : nil;
    __weak SZFriendsNearbyService *weakSelf = self;
    // The policy exists before its link does; the link fills this in so the policy can mark it a stranger.
    __block __weak SZFriendsPeerLink *weakLink = nil;
    SZFriendsRemoteKeyPolicy policy = ^BOOL(NSData *key, SZFriendsHandshakePattern pattern, NSData *token) {
        return [weakSelf allowRemoteKey:key pattern:pattern token:token link:weakLink publicEntry:visible];
    };
    SZFriendsSecureChannel *channel = [[SZFriendsSecureChannel alloc] initAsResponderWithStream:stream
                                                                                       identity:self.services.identity
                                                                                  publicProfile:profile
                                                                                      keyPolicy:policy
                                                                                          queue:self.queue];
    SZFriendsPeerLink *link = [[SZFriendsPeerLink alloc] initWithChannel:channel
                                                                 purpose:SZFriendsLinkPurposeIncoming
                                                                   route:route];
    weakLink = link;
    link.publicEntry = visible;
    [self startLink:link];
}

- (SZFriendsPeerLink *)linkForInitiatorStream:(id<SZFriendsByteStream>)stream plan:(SZFriendsDialPlan *)plan {
    SZFriendsSecureChannel *channel = [[SZFriendsSecureChannel alloc] initAsInitiatorWithStream:stream
                                                                                       identity:self.services.identity
                                                                                        options:plan.options
                                                                                          queue:self.queue];
    // Our IK callback answering an Add by ID shows the host's word that we hold our ID, so the requester can tell us
    // from anyone else who heard the broadcast (+Attestation). Only the callback that carries our ACCEPT, the one
    // place it decides anything: a decline's callback would hand someone we turned down a signed statement of our ID,
    // our host and the day we last checked in (wave-4 re-check).
    NSString *callbackTo = plan.conversationID;
    SZFriendsPersonRecord *callee = callbackTo ? [self.services.store personWithConversationID:callbackTo] : nil;
    if (plan.options.requestToken != nil && callee.relation == SZFriendsRelationFriend) {
        channel.localAttestation = [self attestationForOurAnswer];
    }
    SZFriendsPeerLink *link = [[SZFriendsPeerLink alloc] initWithChannel:channel
                                                                 purpose:plan.purpose
                                                                   route:plan.sighting.route];
    link.endpointID = plan.sighting.endpointID;
    link.discoveryMethod = plan.sighting.method;
    link.probe = plan.probe;
    BOOL personal = plan.purpose == SZFriendsLinkPurposeFriend || plan.purpose == SZFriendsLinkPurposeRequest;
    link.conversationID = personal ? plan.conversationID : nil;
    link.requestToken = plan.requestToken ?: plan.options.requestToken;
    link.syncDeviceHex = plan.ownDeviceHex;
    // The session that creates a friendship runs the code exchange: our XX request, or our IK callback after
    // accepting someone's Add by ID (ADR 0001 § Comparison codes).
    link.createsFriendship = plan.purpose == SZFriendsLinkPurposeRequest ||
                             (plan.purpose == SZFriendsLinkPurposeFriend && plan.options.requestToken != nil);
    return link;
}

- (void)startLink:(SZFriendsPeerLink *)link {
    [self.links addObject:link];
    SZFriendsSecureChannel *channel = link.channel;
    __weak SZFriendsNearbyService *weakSelf = self;
    // The link is captured strongly: the channel drops every callback when it terminates, which breaks the cycle.
    channel.onEstablished = ^{ [weakSelf linkWentLive:link]; };
    channel.onFrame = ^(SZFriendsFrame *frame) { [weakSelf link:link receivedFrame:frame]; };
    channel.onClose = ^(NSError *error) { [weakSelf link:link closedWithError:error]; };
    if (link.purpose == SZFriendsLinkPurposeBrowse) {
        channel.onPublicProfile = ^BOOL(NSDictionary<NSNumber *, NSData *> *profile) {
            [weakSelf link:link browsedProfile:profile];
            return NO; // browsing ends before message 3 would reveal who we are
        };
    }
    [channel start];
}

// What the racer knows a dialed peer by: a friend's conversation, or "dev-" and the key of one of our devices.
- (nullable NSString *)raceNameOfLink:(SZFriendsPeerLink *)link {
    if (link.purpose != SZFriendsLinkPurposeOwnDevice) return link.conversationID;
    return link.syncDeviceHex ? [@"dev-" stringByAppendingString:link.syncDeviceHex] : nil;
}

#pragma mark - Handshake outcomes

- (void)link:(SZFriendsPeerLink *)link browsedProfile:(NSDictionary<NSNumber *, NSData *> *)profile {
    NSData *key = link.channel.remoteIdentityKey;
    if (key.length != 32 || [key isEqualToData:[self localIdentityKey]] || link.endpointID == nil) return;
    NSString *hex = SZFriendsLinkHex(key);
    // Without the photo bytes: nothing decodes a stranger's photo, so nothing keeps it (+Facts).
    NSMutableDictionary<NSNumber *, NSData *> *kept = [profile mutableCopy];
    [kept removeObjectForKey:@(SZFriendsFieldData)];
    self.publicProfiles[hex] = kept;
    [self.publicPictures removeObjectForKey:hex]; // a new picture is worked out again on the next snapshot
    if (link.channel.remoteStaticKey != nil) self.publicStaticKeys[hex] = link.channel.remoteStaticKey;
    SZFriendsPersonRecord *person = [self.services.store personWithIdentityKey:key];
    if (person.relation == SZFriendsRelationBlocked) return; // blocked people never appear in Nearby
    // A removed person is identified like a stranger, so Nearby offers a new request (either side may ask again).
    NSString *conversationID = person.relation == SZFriendsRelationRemoved ? nil : person.conversationID;
    [self.coordinator.merger identifyEndpoint:link.endpointID
                                       method:(SZFriendsDiscoveryMethod)link.discoveryMethod
                                  identityKey:key
                               conversationID:conversationID];
    [self scheduleReconsider];
    [self changed];
}

- (void)linkWentLive:(SZFriendsPeerLink *)link {
    if (link.closed) return;
    link.live = YES;
    link.liveAt = [NSDate date];
    if (link.dialKey != nil) [self.dialing removeObject:link.dialKey];
    [self armIdleCheckForLink:link];
    SZFriendsSecureChannel *channel = link.channel;
    if (channel.isInitiator && (link.purpose == SZFriendsLinkPurposeFriend ||
                                link.purpose == SZFriendsLinkPurposeOwnDevice)) {
        [self noteDialToEndpoint:link.endpointID method:link.discoveryMethod conversation:[self raceNameOfLink:link]
                       succeeded:YES];
    }
    if (channel.pattern == SZFriendsHandshakeNN) {
        if (channel.isInitiator && link.purpose == SZFriendsLinkPurposeJoin) [self joinLinkWentLive:link];
        else if (channel.isInitiator) [self sendRequestByIDOnLink:link];
        else [self closeLink:link after:SZFriendsByIDSessionLife]; // a responder waits briefly for REQUEST_BY_ID
        return;
    }
    if ([self chainRefusesLiveLink:link]) return; // a device its owner removed, whichever side dialed (+Chain)
    if ([self syncAdoptsLiveLink:link]) return;   // another device of ours: it carries sync, nothing else (+Sync)
    NSData *remoteKey = channel.remoteIdentityKey;
    SZFriendsStore *store = self.services.store;
    NSString *conversationID = link.conversationID;
    if (channel.isInitiator) {
        // An XX request must reach the person whose public entry we browsed, not whoever answers there now.
        SZFriendsPersonRecord *person = conversationID ? [store personWithConversationID:conversationID] : nil;
        if (link.purpose == SZFriendsLinkPurposeRequest && ![person.identityKey isEqualToData:remoteKey]) {
            [channel closeWithReason:SZFriendsCloseReasonNormal];
            return;
        }
    } else {
        SZFriendsPersonRecord *person = [store personWithIdentityKey:remoteKey];
        conversationID = person.conversationID;
        if (channel.presentedRequestToken != nil) {
            NSString *callback = [self conversationForCallbackLink:link];
            if (callback == nil) {
                [channel closeWithReason:SZFriendsCloseReasonNormal];
                return;
            }
            conversationID = callback;
            // They call back with our token, so the request reached them; it is not sent again on this session,
            // where a REQUEST would read as a new request to someone who has just declined it.
            [self acknowledgeRequestEntriesOfConversation:callback];
            link.createsFriendship = YES;
            // Let in by the token alone: an unknown key, or a removed person answering our request for their ID.
            link.tokenAdmitted = person == nil || person.relation == SZFriendsRelationRemoved;
        }
        // XX completed on a public entry is a friend request; its session creates the friendship.
        if (channel.pattern == SZFriendsHandshakeXX && person.relation != SZFriendsRelationFriend) {
            link.createsFriendship = YES;
        }
    }
    if (conversationID == nil) return; // a stranger's request session: REQUEST will say who they are
    if ([self keyChangedOnLink:link conversationID:conversationID]) return;
    [self attachLink:link toConversation:conversationID];
    if (!link.chainSent) [self sendChainOnLink:link]; // adopting it may have sent it already
    // The initiator's side only waits for the responder's commitment. A responder commits only once the friendship's
    // first step is durable and visible: the IK callback's row is saved by now; an XX request commits after REQUEST
    // is stored (+Inbound), so a session that never asks never yields a code (review: code grinding).
    BOOL responderXX = !channel.isInitiator && channel.pattern == SZFriendsHandshakeXX;
    if (!responderXX) [self runCodeExchangeOnLink:link];
    if (channel.presentedRequestToken != nil || (channel.isInitiator && link.requestToken != nil)) {
        [self callbackLinkWentLive:link];
    }
}

- (void)runCodeExchangeOnLink:(SZFriendsPeerLink *)link {
    if (!link.createsFriendship || link.codeExchangeStarted || link.closed || link.conversationID == nil) return;
    SZFriendsPersonRecord *person = [self.services.store personWithConversationID:link.conversationID];
    // A stored code is never replaced: another session with the same key gets no second attempt, so every attempt
    // at steering the codes leaves a request row of its own.
    if (person == nil || person.comparisonCode != nil) return;
    link.codeExchangeStarted = YES;
    __weak SZFriendsNearbyService *weakSelf = self;
    [link.channel runComparisonCodeExchange:^(NSString *code, NSError *error) {
        (void)error; // a failed commitment already closed the channel; nothing is stored
        if (code == nil) return;
        link.comparisonCode = code;
        [weakSelf storeComparisonCodeOfLink:link];
    }];
}

- (void)storeComparisonCodeOfLink:(SZFriendsPeerLink *)link {
    if (link.comparisonCode == nil || link.conversationID == nil) return;
    SZFriendsPersonRecord *person = [self.services.store personWithConversationID:link.conversationID];
    // Never replaced silently: the first code of a friendship is the one both people compare.
    if (person == nil || person.comparisonCode != nil) return;
    person.comparisonCode = link.comparisonCode;
    if (![self.services.store savePerson:person error:NULL]) SZFriendsHelperLog(@"could not store a comparison code");
    [self changed];
}

- (nullable SZFriendsPersonRecord *)notePresentedStaticKey:(NSData *)staticKey
                                               certificate:(nullable NSData *)certificate
                                                    person:(SZFriendsPersonRecord *)person {
    SZFriendsStore *store = self.services.store;
    NSString *conversationID = person.conversationID;
    BOOL wasPending = person.keyChangePending;
    BOOL kept = certificate.length > 0 && [store notePresentedStaticKey:staticKey certificate:certificate
                                                         forConversation:conversationID error:NULL];
    if (!kept && !wasPending) {
        // No certificate to check (or it names someone else): still never accepted, but marked for review so
        // automatic acceptance stops and the person is told; IK keeps dialing the key we know.
        SZFriendsPersonRecord *marked = [store personWithConversationID:conversationID];
        marked.keyChangePending = YES;
        if (marked != nil) [store savePerson:marked error:NULL];
    }
    SZFriendsPersonRecord *now = [store personWithConversationID:conversationID];
    if (!wasPending && now.keyChangePending) {
        SZFriendsNearbyRecordEvent(store, SZFriendsEventKeyChanged, conversationID);
    }
    [self changed];
    return now;
}

// A known identity presenting another static key: never accepted silently (brief § Identity and keys). The friend
// is marked for review, automatic acceptance turns off (the store does that), and the session ends; after
// accept_key_change the reviewed key is the one we dial.
- (BOOL)keyChangedOnLink:(SZFriendsPeerLink *)link conversationID:(NSString *)conversationID {
    SZFriendsStore *store = self.services.store;
    SZFriendsPersonRecord *person = [store personWithConversationID:conversationID];
    NSData *staticKey = link.channel.remoteStaticKey;
    if (person == nil || staticKey == nil) return NO;
    // Another of their devices has its own static key, from their chain; one that differs is refused, not reviewed.
    BOOL otherDevice = NO;
    BOOL matches = [self otherDeviceOfPerson:person matchesStaticKeyOnLink:link handled:&otherDevice];
    if (otherDevice) {
        if (!matches) [link.channel closeWithReason:SZFriendsCloseReasonNormal];
        return !matches;
    }
    if (person.staticKey == nil) {
        person.staticKey = staticKey; // the first static key a handshake revealed: nothing to review
        [store savePerson:person error:NULL];
        return NO;
    }
    if ([person.staticKey isEqualToData:staticKey]) return NO;
    // The certificate the handshake verified for this static key: the store keeps the key for review only when it
    // names this person's identity key.
    [self notePresentedStaticKey:staticKey certificate:link.channel.remoteCertificate person:person];
    [link.channel closeWithReason:SZFriendsCloseReasonNormal];
    return YES;
}

#pragma mark - The session race

- (nullable SZFriendsPeerLink *)liveLinkForConversation:(NSString *)conversationID {
    SZFriendsPeerLink *link = self.activeLinks[conversationID];
    return (link.live && !link.closed && !link.superseded) ? link : nil;
}

- (void)attachLink:(SZFriendsPeerLink *)link toConversation:(NSString *)conversationID {
    link.conversationID = conversationID;
    SZFriendsPeerLink *current = self.activeLinks[conversationID];
    if (current == nil || current.closed || current == link) {
        [self adoptLink:link];
        return;
    }
    // Another of this person's devices (ADR 0016): both sessions stay. The one carrying the conversation keeps it;
    // the other carries what its own device sends and asks for (Get again), and takes over if the first ends.
    NSData *newRemote = link.channel.remoteIdentityKey, *oldRemote = current.channel.remoteIdentityKey;
    if (newRemote != nil && oldRemote != nil && ![newRemote isEqualToData:oldRemote]) return;
    switch ([self raceOfLink:link against:current]) {
    case SZFriendsRaceKeepsNew:
        [self supersedeLink:current];
        [self adoptLink:link];
        return;
    case SZFriendsRaceKeepsCurrent:
        [self supersedeLink:link];
        return;
    case SZFriendsRaceWaits:
        return; // the responder's copy of a double dial waits for the initiator's CLOSE
    }
}

// The session race (ADR 0001 § Session race) between a new live link and the one carrying the same peer: the better
// route in the owner's order wins (SZFriendsSessionAWins), then the lower initiator key. Friends' conversations and the
// sync with our own devices settle it here alike, so a profile moves to a better route exactly as a friend's files do.
- (SZFriendsRaceOutcome)raceOfLink:(SZFriendsPeerLink *)link against:(SZFriendsPeerLink *)current {
    NSData *local = [self localIdentityKey];
    NSData *newKey = [link initiatorKeyWithLocalKey:local] ?: [NSData data];
    NSData *oldKey = [current initiatorKeyWithLocalKey:local] ?: [NSData data];
    SZFriendsRouteMethod newRoute = link.raceRoute, oldRoute = current.raceRoute;
    if (newRoute == oldRoute && [newKey isEqualToData:oldKey]) {
        // One side dialed twice on one class: nothing both sides hold tells the sessions apart, so only that
        // initiator acts, keeping the one already carrying traffic; the responder waits for its CLOSE.
        return link.channel.isInitiator ? SZFriendsRaceKeepsCurrent : SZFriendsRaceWaits;
    }
    return SZFriendsSessionAWins(newRoute, newKey, oldRoute, oldKey) ? SZFriendsRaceKeepsNew
                                                                    : SZFriendsRaceKeepsCurrent;
}

- (void)adoptLink:(SZFriendsPeerLink *)link {
    NSString *conversationID = link.conversationID;
    self.activeLinks[conversationID] = link;
    link.adopted = YES;
    [self noteSuccessForConversation:conversationID];
    [self sendProfileOnLink:link];
    [self storeComparisonCodeOfLink:link];
    // Resume and route migration are one mechanism: the new session announces every unfinished download's durable
    // offset and the sender continues from there (ADR 0001 § Resume and route migration).
    [self startTransfersOnLink:link];
    [self deliverPendingOnLink:link];
    [self startAgainOnLink:link]; // files asked for again (+Again)
    [self onlineRoutesChanged];
    [self changed];
}

// The loser closes after its in-flight ACKs (CLOSE follows queued control frames). Its downloads stop at once and
// what they received is made durable first, so the winner resumes exactly where the disk says.
- (void)supersedeLink:(SZFriendsPeerLink *)link {
    link.superseded = YES;
    link.adopted = NO;
    if (link.conversationID != nil && self.activeLinks[link.conversationID] == link) {
        [self.activeLinks removeObjectForKey:link.conversationID];
    }
    [self flushProgressOnLink:link];
    [link.endedTransfers addObjectsFromArray:link.receivers.allKeys];
    [link.endedTransfers addObjectsFromArray:link.senders.allKeys];
    [link.receivers removeAllObjects];
    [link.senders removeAllObjects];
    [link.channel closeWithReason:SZFriendsCloseReasonSuperseded];
}

- (void)closeLinksForConversation:(NSString *)conversationID {
    for (SZFriendsPeerLink *link in self.links.allObjects) {
        if (![link.conversationID isEqualToString:conversationID]) continue;
        [link.channel closeWithReason:SZFriendsCloseReasonNormal];
    }
}

#pragma mark - Ends

// Whether an end says something about reaching this person (a refusal, a timeout, a dead link) rather than a
// decision (the race, our own close, a peer going away on purpose).
static BOOL SZFriendsEndCounts(NSError *error) {
    if (error == nil || ![error.domain isEqualToString:SZFriendsSessionErrorDomain]) return error != nil;
    if (error.code == SZFriendsSessionErrorPeerClosed) {
        NSInteger reason = [error.userInfo[SZFriendsSessionCloseReasonKey] integerValue];
        return reason != SZFriendsCloseReasonSuperseded && reason != SZFriendsCloseReasonExpired;
    }
    return error.code != SZFriendsSessionErrorExpired;
}

static BOOL SZFriendsEndWasSupersededByPeer(NSError *error) {
    return [error.domain isEqualToString:SZFriendsSessionErrorDomain] &&
           error.code == SZFriendsSessionErrorPeerClosed &&
           [error.userInfo[SZFriendsSessionCloseReasonKey] integerValue] == SZFriendsCloseReasonSuperseded;
}

- (void)link:(SZFriendsPeerLink *)link closedWithError:(nullable NSError *)error {
    if (link.closed) return;
    link.closed = YES;
    [link cancelTimers];
    [self.links removeObject:link];
    [self syncLinkClosed:link];
    [link.againExchange stop];
    // Faults only, and never a key, name or address: which kind of session ended, on which route, and why.
    if (error != nil && !link.probe) {
        // The peer's reason when it closed (SZFriendsCloseReason): superseded, shutting down, or a refusal.
        NSNumber *reason = error.userInfo[SZFriendsSessionCloseReasonKey];
        SZFriendsHelperLog(@"session ended (purpose %ld, route %ld, %@): %@ %ld%@", (long)link.purpose,
                           (long)link.raceRoute, link.live ? @"live" : @"handshaking", error.domain, (long)error.code,
                           [reason isKindOfClass:[NSNumber class]]
                               ? [NSString stringWithFormat:@" reason %ld", (long)reason.integerValue]
                               : @"");
    }
    if (link.dialKey != nil) [self.dialing removeObject:link.dialKey];
    NSString *conversationID = link.conversationID;
    BOOL wasActive = conversationID != nil && self.activeLinks[conversationID] == link;
    if (wasActive) [self.activeLinks removeObjectForKey:conversationID];
    // Every received byte durable before anything resumes elsewhere (ADR 0003 § Durable progress).
    if (link.receivers.count > 0) [self.services.transfers flushProgressWithError:NULL];
    [self requeueEntriesOfLink:link];
    if (link.purpose == SZFriendsLinkPurposeBrowse && error != nil && link.endpointID != nil) {
        [self browseOfEndpointFailed:link.endpointID];
    }
    [self joinLinkEnded:link]; // a run of a join code on it is over (+Join)
    if (link.purpose == SZFriendsLinkPurposeByID && !link.byIDAnswered && link.attemptKey != nil) {
        [self byIDAttemptFailed:link.attemptKey];
    }
    // A handshake that ended before going live, other than by our own decision, counts against that endpoint.
    if (link.channel.isInitiator && !link.live && error != nil &&
        (link.purpose == SZFriendsLinkPurposeFriend || link.purpose == SZFriendsLinkPurposeOwnDevice)) {
        [self noteDialToEndpoint:link.endpointID method:link.discoveryMethod conversation:[self raceNameOfLink:link]
                       succeeded:NO];
    }
    if (conversationID != nil && !link.probe && !link.superseded && SZFriendsEndCounts(error)) {
        if (link.live) [self noteEndOfLink:link];
        else if (link.channel.isInitiator) [self noteFailureForConversation:conversationID];
    }
    if (wasActive) {
        // A standby session (the responder's copy of a double dial) takes over at once.
        for (SZFriendsPeerLink *other in self.links) {
            if (other.live && !other.superseded && [other.conversationID isEqualToString:conversationID]) {
                [self adoptLink:other];
                break;
            }
        }
    }
    // The friend superseded this session and nothing here replaces it: it kept one with another of our computers.
    if (conversationID != nil && link.live && !link.probe && SZFriendsEndWasSupersededByPeer(error) &&
        [self liveLinkForConversation:conversationID] == nil) {
        [self noteSessionKeptElsewhereForConversation:conversationID];
    }
    // What this link had in flight is Queued again: the session carrying the conversation now sends it (the
    // recipient recognises anything it already committed).
    if (conversationID != nil) [self deliverPendingForConversation:conversationID];
    [self scheduleReconsider];
    [self changed];
}

@end
