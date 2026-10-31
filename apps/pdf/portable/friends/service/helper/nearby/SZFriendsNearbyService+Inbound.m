// Frames from the other side: requests and their answers, messages, offers, presence secrets and profiles. Each is
// committed before its ACK goes back, so an ACK always means the item is on this Mac (ADR 0001 § Messages).

#import "service/helper/nearby/SZFriendsNearbyDevices.h"

#import "service/identity/SZFriendsDeviceChain.h"
#import "service/store/SZFriendsStoreDevices.h"
#import "service/helper/nearby/SZFriendsNearbyJoin.h"

void SZFriendsNearbyRecordEvent(SZFriendsStore *store, NSString *eventKind, NSString *conversationID) {
    SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
    item.itemID = SZFriendsNewIdentifier();
    item.conversationID = conversationID;
    item.kind = SZFriendsItemKindEvent;
    item.direction = SZFriendsDirectionOutgoing;
    item.sentAt = [NSDate date];
    item.receivedAt = item.sentAt;
    item.eventKind = eventKind;
    NSError *error = nil;
    if (![store insertItem:item error:&error]) {
        SZFriendsHelperLog(@"could not record a %@ event: %@", eventKind, error.localizedDescription);
    }
}

@implementation SZFriendsNearbyService (Inbound)

- (void)enqueueKind:(SZFriendsOutboxKind)kind
     conversationID:(NSString *)conversationID
            payload:(nullable NSDictionary *)payload {
    SZFriendsOutboxEntry *entry = [[SZFriendsOutboxEntry alloc] init];
    entry.entryID = SZFriendsNewIdentifier();
    entry.conversationID = conversationID;
    entry.kind = kind;
    entry.createdAt = [NSDate date];
    if (payload != nil) entry.payload = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    NSError *error = nil;
    if (![self.services.outbox enqueue:entry error:&error]) {
        SZFriendsHelperLog(@"could not queue an outbox entry: %@", error.localizedDescription);
    }
}

// A session let in by our Add by ID token alone carries friendship creation only until that person is a friend:
// anyone who heard the broadcast can answer it, so their key earns nothing more than a request row.
static BOOL SZFriendsCreatesFriendship(SZFriendsFrameType type) {
    // CHAIN: an answer from a device other than their first says whose device it is before ACCEPT (+Chain).
    return type == SZFriendsFrameTypeProfile || type == SZFriendsFrameTypeAccept ||
           type == SZFriendsFrameTypeDecline || type == SZFriendsFrameTypeAck || type == SZFriendsFrameTypeChain;
}

- (void)link:(SZFriendsPeerLink *)link meterFrame:(SZFriendsFrame *)frame {
    if (frame.type != SZFriendsFrameTypePart && frame.type != SZFriendsFrameTypeChunk) return;
    NSData *wire = [frame dataForTag:SZFriendsFieldID], *data = [frame dataForTag:SZFriendsFieldData];
    if (wire.length == 0 || data.length == 0) return;
    if (self.routeMeter == nil) self.routeMeter = [SZFriendsRouteMeter new];
    [self.routeMeter carried:data.length
                       route:link.raceRoute
                    transfer:SZFriendsLinkHex(wire)
                         now:NSProcessInfo.processInfo.systemUptime];
}

- (void)link:(SZFriendsPeerLink *)link receivedFrame:(SZFriendsFrame *)frame {
    if (link.closed) return;
    [self link:link meterFrame:frame]; // on the session it came on, a lane's own route included
    if (link.lane) {
        // Any application frame may come on any lane of a group; it counts as the first session's (ADR 0018 § 6),
        // except that block frames keep their lane, so a PART's HAVE goes back where it came from.
        SZFriendsPeerLink *head = link.laneHead;
        if (head == nil || head.closed) return;
        [head.blocks heard:link.laneSerial];
        if (frame.type == SZFriendsFrameTypeHashes || frame.type == SZFriendsFrameTypeWant ||
            frame.type == SZFriendsFrameTypePart || frame.type == SZFriendsFrameTypeHave) {
            [self link:link receivedBlockFrame:frame];
            return;
        }
        link = head;
    }
    [link.blocks heard:link.blocks.controlLane];
    [self noteFrame:frame onLink:link];
    // A HAVE for a file this side gives again or copies to another of our devices by blocks (+Copies).
    if (frame.type == SZFriendsFrameTypeHave && [self link:link receivedCopyHave:frame]) return;
    // HASHES and PARTs of a copy this side asked for by blocks (+Copies).
    if ((frame.type == SZFriendsFrameTypeHashes || frame.type == SZFriendsFrameTypePart) &&
        [self link:link receivedCopyFrame:frame]) {
        return;
    }
    if (link.ownDevice) {
        [self link:link receivedOwnDeviceFrame:frame]; // CHAIN and SYNC between our own devices (+Sync)
        return;
    }
    if (link.tokenAdmitted) {
        if ([self linkIsWithFriend:link]) link.tokenAdmitted = NO;
        else if (!SZFriendsCreatesFriendship(frame.type)) return;
    }
    switch (frame.type) {
    case SZFriendsFrameTypeReceived:
        // Our Add by ID request was received; every device says so alike, so there is nothing more to learn.
        link.byIDAnswered = YES;
        [link.channel close];
        return;
    case SZFriendsFrameTypeRequestByID:
        [self link:link receivedRequestByID:frame];
        return;
    case SZFriendsFrameTypeJoin: // NN only (the channel refuses it elsewhere): joining a profile (+Join)
        [self link:link receivedJoinFrame:frame];
        return;
    case SZFriendsFrameTypeAck:
        [self handleAck:frame onLink:link];
        return;
    case SZFriendsFrameTypeProfile:
        [self link:link receivedProfile:frame];
        return;
    case SZFriendsFrameTypeRequest:
        [self link:link receivedRequest:frame];
        return;
    default:
        break;
    }
    // Everything else comes from someone in the list, never from a stranger's request session.
    NSString *conversationID = link.conversationID;
    SZFriendsPersonRecord *person =
        conversationID ? [self.services.store personWithConversationID:conversationID] : nil;
    if (person == nil && frame.type == SZFriendsFrameTypeChain) {
        [self link:link receivedFirstContactChain:frame]; // before a stranger's request (+Chain)
        return;
    }
    if (person == nil || person.relation == SZFriendsRelationBlocked) return;
    switch (frame.type) {
    case SZFriendsFrameTypeAccept:
    case SZFriendsFrameTypeDecline:
        [self link:link person:person receivedAnswer:frame];
        break;
    case SZFriendsFrameTypeCancel:
        [self link:link person:person receivedCancel:frame];
        break;
    case SZFriendsFrameTypeMessage:
        [self link:link person:person receivedMessage:frame];
        break;
    case SZFriendsFrameTypeOffer:
        [self link:link person:person receivedOffer:frame];
        break;
    case SZFriendsFrameTypeOfferReply:
        [self link:link person:person receivedOfferReply:frame];
        break;
    case SZFriendsFrameTypePresenceSecret:
        [self link:link person:person receivedPresenceSecret:frame];
        break;
    case SZFriendsFrameTypeChunk:
        [self link:link receivedChunkFrame:frame];
        break;
    case SZFriendsFrameTypeAgain: // a file asked for again, either way (+Again)
        [self link:link person:person receivedAgainFrame:frame];
        break;
    case SZFriendsFrameTypeProgress:
        [self link:link receivedProgressFrame:frame];
        break;
    case SZFriendsFrameTypeDone:
        [self link:link receivedDoneFrame:frame];
        break;
    case SZFriendsFrameTypeThumbnail:
        [self link:link person:person receivedThumbnail:frame];
        break;
    case SZFriendsFrameTypeChain:
        [self link:link person:person receivedChain:frame];
        break;
    case SZFriendsFrameTypeHashes:
    case SZFriendsFrameTypeWant:
    case SZFriendsFrameTypePart:
    case SZFriendsFrameTypeHave:
        [self link:link receivedBlockFrame:frame]; // only on a fast session: the channel refuses them elsewhere
        break;
    case SZFriendsFrameTypeBoost:
        [self link:link receivedBoostFrame:frame]; // only where both set bit 5: the channel refuses it elsewhere
        break;
    default:
        break;
    }
}

#pragma mark - Requests

- (void)link:(SZFriendsPeerLink *)link receivedRequest:(SZFriendsFrame *)frame {
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    NSData *key = link.channel.remoteIdentityKey;
    SZFriendsStore *store = self.services.store;
    if (wire == nil || key.length != 32) return;
    SZFriendsPersonRecord *person = link.conversationID ? [store personWithConversationID:link.conversationID]
                                                        : [store personWithIdentityKey:key];
    // Another device of someone already in the list, whose chain came first: the same person.
    if (person == nil && link.pendingChain != nil) person = [store personWithIdentityKey:link.pendingChain.rootKey];
    if (person.relation == SZFriendsRelationBlocked) return; // dropped; blocked people cannot ask
    NSDate *now = [NSDate date];
    if (person != nil && person.relation == SZFriendsRelationFriend) {
        // Still a friend here: they removed us, which we are never told, and ask again (PROTOCOL.md remove_friend),
        // or they repeat a request we accepted. Either way they wait for an answer: it is an acceptance, as
        // accept_request sends, and the conversation goes on. Queued before the ACK, so the answer is durable first.
        if (store.ownPresenceSecret == nil) store.ownPresenceSecret = SZFriendsNewPresenceSecret();
        [self enqueueKind:SZFriendsOutboxKindAnswer
           conversationID:person.conversationID
                  payload:@{@"frame" : @"accept"}];
        [self enqueueKind:SZFriendsOutboxKindPresenceSecret conversationID:person.conversationID payload:nil];
        [self sendAckForID:wire onLink:link];
        if (link.conversationID == nil) [self attachLink:link toConversation:person.conversationID];
        [self deliverAcceptanceThenResendOnLink:link];
        [self changed];
        return;
    }
    if (person != nil && person.relation == SZFriendsRelationIncomingRequest) {
        // The same request again in a new session: one row, which comes back to the top of the list as a new event.
        // Its code is never replaced; a code is exchanged here only if the earlier session ended before one was. (The
        // store keeps when the request began, which bounds IK from them and the request's life.)
        person.requestAt = now;
        person.lastInteractionAt = now;
        if (![store savePerson:person error:NULL]) return; // no ACK: the requester's outbox tries again
        [self sendAckForID:wire onLink:link];
        if (link.conversationID == nil) [self attachLink:link toConversation:person.conversationID];
        [self runCodeExchangeOnLink:link];
        [self changed];
        return;
    }
    BOOL mutual = person != nil && person.relation == SZFriendsRelationOutgoingRequest;
    if (mutual) {
        // We asked them too: two requests are two acceptances. An Add by ID request of ours stays until it expires,
        // so a second holder of the ID can still answer it (ADR 0004 step 5).
        person.relation = SZFriendsRelationFriend;
        person.lastInteractionAt = now;
        if (![store savePerson:person error:NULL]) return;
        SZFriendsNearbyRecordEvent(store, SZFriendsEventNowFriends, person.conversationID);
        [self enqueueKind:SZFriendsOutboxKindAnswer
           conversationID:person.conversationID
                  payload:@{@"frame" : @"accept"}];
        [self enqueueKind:SZFriendsOutboxKindPresenceSecret conversationID:person.conversationID payload:nil];
    } else {
        if (person == nil) {
            person = [[SZFriendsPersonRecord alloc] init];
            person.conversationID = SZFriendsNewIdentifier();
            person.picture = [SZFriendsPicture placeholder];
        }
        // A device other than their first sent its chain first: the person is its root, dialed at their first one.
        NSData *rootStatic = nil;
        NSData *root = person.identityKey == nil ? [self firstContactRootOnLink:link staticKey:&rootStatic] : nil;
        person.identityKey = root ?: key;
        // A stored static key changes only through review (the store refuses a silent swap; Sessions).
        if (person.staticKey == nil) person.staticKey = root ? rootStatic : link.channel.remoteStaticKey;
        person.relation = SZFriendsRelationIncomingRequest;
        person.requestAt = now;
        person.requestFoundNearby = YES; // XX on a public entry: they found us nearby
        person.lastInteractionAt = now;
        person.comparisonCode = nil; // a new request gets its own code, exchanged once it is stored (below)
        if (link.pendingProfile != nil) [self updatePerson:person withProfile:link.pendingProfile];
        NSError *error = nil;
        if (![store savePerson:person error:&error]) {
            SZFriendsHelperLog(@"could not store a friend request: %@", error.localizedDescription);
            return; // no ACK: the requester's outbox tries again
        }
        if (root != nil) [store mergeDeviceChainData:link.pendingChain.encodedData forRootKey:root error:NULL];
    }
    link.pendingProfile = nil;
    [self sendAckForID:wire onLink:link];
    if (link.conversationID == nil) [self attachLink:link toConversation:person.conversationID];
    // Only now, with the request durable and on the list, does this side commit to a code (ADR 0001 § Comparison
    // codes): each attempt at matching codes is a request the person sees.
    [self runCodeExchangeOnLink:link];
    [self rebuildTagMatcher];
    [self deliverPendingForConversation:person.conversationID];
    if (mutual) [self.services.notifier noteAcceptedBy:person];
    else [self.services.notifier noteRequestFrom:person];
    [self changed];
}

- (void)acknowledgeRequestEntriesOfConversation:(NSString *)conversationID {
    for (SZFriendsOutboxEntry *entry in [self.services.outbox pendingEntriesForConversation:conversationID]) {
        if (entry.kind == SZFriendsOutboxKindRequest) {
            [self applyEvent:SZFriendsOutboxEventAcknowledged toEntry:entry.entryID];
        }
    }
}

// An ACCEPT on the IK callback answering our Add by ID, from someone the host did not vouch for: anyone nearby who
// heard the broadcast could have sent it. Taking it as a friendship gave a bystander our presence secret and a place
// in our list under whatever name their PROFILE claimed (wave-4 security re-check). It becomes a request the person
// accepts, with the ID we asked for named on its card; only that acceptance makes a friend and sends our secret.
- (BOOL)link:(SZFriendsPeerLink *)link holdsUnconfirmedAcceptanceFrom:(SZFriendsPersonRecord *)person {
    NSData *token = link.channel.presentedRequestToken;
    // A request from a mention or a friend link admits only the key it named: that answer is no bystander's.
    return token != nil && !link.answerAttested && !person.friendsIDConfirmed &&
           ![self requestToken:token isBoundToIdentityKey:person.identityKey atDate:[NSDate date]];
}

- (void)link:(SZFriendsPeerLink *)link person:(SZFriendsPersonRecord *)person receivedAnswer:(SZFriendsFrame *)frame {
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    if (wire == nil) return;
    SZFriendsStore *store = self.services.store;
    BOOL acceptedByFriend = person.relation == SZFriendsRelationFriend && frame.type == SZFriendsFrameTypeAccept;
    if (person.relation == SZFriendsRelationOutgoingRequest && frame.type == SZFriendsFrameTypeAccept &&
        [self link:link holdsUnconfirmedAcceptanceFrom:person]) {
        NSDate *now = [NSDate date];
        person.relation = SZFriendsRelationIncomingRequest;
        person.unconfirmedAnswerID = link.answerForID;
        person.requestAt = now;
        person.requestFoundNearby = NO;
        person.lastInteractionAt = now;
        if (![store savePerson:person error:NULL]) return; // no ACK: their outbox sends the answer again
        [self acknowledgeRequestEntriesOfConversation:person.conversationID];
        [self refreshAdvertisement];
        [self rebuildTagMatcher];
        [self sendAckForID:wire onLink:link];
        [self.services.notifier noteRequestFrom:person]; // a request card the person answers
        [self changed];
        return;
    }
    if (person.relation == SZFriendsRelationOutgoingRequest) {
        BOOL accepted = frame.type == SZFriendsFrameTypeAccept;
        person.relation = accepted ? SZFriendsRelationFriend : SZFriendsRelationRemoved;
        if (accepted) person.lastInteractionAt = [NSDate date];
        if (![store savePerson:person error:NULL]) return;
        // Either way the request reached them. An Add by ID request stays until it expires, so a second holder of an
        // unreserved ID can still answer (ADR 0004 step 5); its callback tags stop now that someone answered.
        [self acknowledgeRequestEntriesOfConversation:person.conversationID];
        if (accepted) {
            SZFriendsNearbyRecordEvent(store, SZFriendsEventNowFriends, person.conversationID);
            if (store.ownPresenceSecret == nil) store.ownPresenceSecret = SZFriendsNewPresenceSecret();
            [self enqueueKind:SZFriendsOutboxKindPresenceSecret conversationID:person.conversationID payload:nil];
            [self.services.notifier noteAcceptedBy:person];
        }
        [self refreshAdvertisement];
        [self rebuildTagMatcher];
    }
    [self sendAckForID:wire onLink:link];
    if (acceptedByFriend) {
        // They accept someone already our friend: they had removed us and asked again by Friends ID, and took our
        // acceptance, which no host vouched for, as a request to accept. What this link wrote before reached them as
        // a stranger and was dropped unacknowledged: it goes again, with the same ids.
        [self deliverAcceptanceThenResendOnLink:link];
        [self changed];
        return;
    }
    [self deliverPendingOnLink:link];
    [self changed];
}

- (void)link:(SZFriendsPeerLink *)link person:(SZFriendsPersonRecord *)person receivedCancel:(SZFriendsFrame *)frame {
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    if (wire == nil) return;
    NSString *idHex = SZFriendsLinkHex(wire);
    // Only a transfer of this conversation: an id another friend's transfer has is not theirs to cancel.
    SZFriendsTransferRecord *transfer = [self.services.transfers transferWithID:idHex
                                                                 inConversation:person.conversationID];
    if (transfer != nil) {
        // What already arrived stays; anything still moving stops (the store refuses a settled transfer as stale).
        [self.services.transfers peerCancelledTransfer:idHex fromConversation:person.conversationID error:NULL];
        [self stopTransfer:idHex];
    } else if (person.relation == SZFriendsRelationIncomingRequest) {
        // They withdrew their request; either side may ask again later.
        person.relation = SZFriendsRelationRemoved;
        [self.services.store savePerson:person error:NULL];
        [self rebuildTagMatcher];
    }
    [self sendAckForID:wire onLink:link];
    [self changed];
}

@end
