// The outbox on a live session: entries become frames, and only the recipient's ACK, sent after its own commit,
// makes one Delivered (brief § Outbox and delivery, ADR 0001 § Messages).

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

static uint64_t SZFriendsMilliseconds(NSDate *date) {
    double ms = date.timeIntervalSince1970 * 1000.0;
    return ms > 0 ? (uint64_t)ms : 0;
}

static NSDictionary *SZFriendsAnswerPayload(SZFriendsOutboxEntry *entry) {
    if (entry.payload == nil) return @{};
    id object = [NSJSONSerialization JSONObjectWithData:entry.payload options:0 error:NULL];
    return [object isKindOfClass:[NSDictionary class]] ? object : @{};
}

// accept, decline and the withdrawal of our own request: answers about the friendship itself, which must reach the
// other person even after we removed them (they are still waiting on the request).
static BOOL SZFriendsIsRequestAnswer(SZFriendsOutboxEntry *entry) {
    if (entry.kind != SZFriendsOutboxKindAnswer) return NO;
    NSDictionary *payload = SZFriendsAnswerPayload(entry);
    NSString *frame = payload[@"frame"];
    return payload[@"transfer_id"] == nil &&
           ([frame isEqual:@"accept"] || [frame isEqual:@"decline"] || [frame isEqual:@"cancel"]);
}

@implementation SZFriendsNearbyService (Delivery)

#pragma mark - What may go to whom

- (BOOL)entry:(SZFriendsOutboxEntry *)entry isDeliverableTo:(SZFriendsPersonRecord *)person {
    switch (person.relation) {
    case SZFriendsRelationBlocked:
    case SZFriendsRelationIncomingRequest:
        return NO;
    case SZFriendsRelationFriend:
        return YES;
    case SZFriendsRelationOutgoingRequest:
        // An Add by ID request whose holder we do not know yet travels over NN (+RequestByID), not a session.
        return entry.kind == SZFriendsOutboxKindRequest && person.identityKey != nil;
    case SZFriendsRelationRemoved:
        // Removing someone tells them nothing: only a decline or a withdrawn request still goes.
        return SZFriendsIsRequestAnswer(entry);
    }
    return NO;
}

- (BOOL)hasDeliverableEntriesForPerson:(SZFriendsPersonRecord *)person {
    for (SZFriendsOutboxEntry *entry in [self.services.outbox pendingEntriesForConversation:person.conversationID]) {
        if ([self entry:entry isDeliverableTo:person]) return YES;
    }
    return NO;
}

#pragma mark - Sending

- (void)deliverPendingForConversation:(NSString *)conversationID {
    SZFriendsPeerLink *link = [self liveLinkForConversation:conversationID];
    if (link != nil) [self deliverPendingOnLink:link];
}

- (void)deliverPendingOnLink:(SZFriendsPeerLink *)link {
    NSString *conversationID = link.conversationID;
    // Our traffic goes on the one link carrying the conversation; a standby copy only answers what arrives on it.
    if (!link.live || !link.adopted || link.closed || link.superseded || conversationID == nil) return;
    SZFriendsPersonRecord *person = [self.services.store personWithConversationID:conversationID];
    if (person == nil) return;
    // A request accepted on this session: the friend gets our chain now, so it knows our other computers (+Chain).
    if (!link.chainSent) [self sendChainOnLink:link];
    // Entries still waiting for an ACK on another link (a superseded one draining) go again only once it ends.
    NSMutableSet<NSString *> *busy = [NSMutableSet set];
    for (SZFriendsPeerLink *other in self.links) {
        if (!other.closed) [busy unionSet:other.inFlightEntries];
    }
    BOOL moved = NO; // an entry changed state, so the views hear of it
    for (SZFriendsOutboxEntry *entry in [self.services.outbox pendingEntriesForConversation:conversationID]) {
        if ([busy containsObject:entry.entryID] || ![self entry:entry isDeliverableTo:person]) continue;
        // A request or an answer may be the first they hear of us: our chain goes first (+Chain).
        if (entry.kind == SZFriendsOutboxKindRequest || entry.kind == SZFriendsOutboxKindAnswer) {
            [self sendFirstContactChainOnLink:link];
        }
        NSString *wireID = nil;
        SZFriendsFrame *frame = [self frameForEntry:entry person:person wireID:&wireID];
        if (frame == nil || wireID == nil) continue;
        // Written (attempts + 1) is committed before the frame goes: Cancel trusts attempts alone, so a failed commit
        // or a crash between the two must never leave a message that reached the friend reading as never written
        // (security review, wave 6a). A frame the channel then refuses goes back to Queued for the next session, and
        // keeps the count: Cancel says it may have been sent, the safe side when unsure what the channel took.
        NSError *error = nil;
        if (![self.services.outbox applyEvent:SZFriendsOutboxEventWritten toEntry:entry.entryID error:&error]) {
            SZFriendsHelperLog(@"outbox kind %ld not marked written, so not sent: %@", (long)entry.kind,
                               error.localizedDescription);
            continue;
        }
        if (![link.channel sendFrame:frame]) {
            SZFriendsHelperLog(@"a frame for outbox kind %ld was refused", (long)entry.kind);
            [self applyEvent:SZFriendsOutboxEventSessionLost toEntry:entry.entryID];
            moved = YES;
            continue;
        }
        [link.inFlightEntries addObject:entry.entryID];
        [link expectAckForID:wireID token:entry.entryID];
        moved = YES;
    }
    // Previews last: each after its offer, and behind everything queued above (+Thumbnails).
    [self sendThumbnailsOnLink:link];
    if (moved) [self changed];
}

- (nullable SZFriendsFrame *)frameForEntry:(SZFriendsOutboxEntry *)entry
                                    person:(SZFriendsPersonRecord *)person
                                    wireID:(NSString *_Nullable *_Nonnull)wireID {
    NSData *entryWire = SZFriendsLinkBytesFromHex(entry.entryID);
    switch (entry.kind) {
    case SZFriendsOutboxKindMessage: {
        SZFriendsItemRecord *item = entry.itemID ? [self.services.store itemWithID:entry.itemID
                                                                    inConversation:person.conversationID]
                                                 : nil;
        NSData *wire = SZFriendsLinkBytesFromHex(item.itemID);
        if (item == nil || wire == nil) return nil;
        *wireID = item.itemID;
        NSMutableDictionary *fields = [NSMutableDictionary dictionary];
        fields[@(SZFriendsFieldID)] = wire;
        fields[@(SZFriendsFieldSentAt)] = [SZFriendsFrame fieldWithUInt64:SZFriendsMilliseconds(item.sentAt)
                                                                      tag:SZFriendsFieldSentAt];
        fields[@(SZFriendsFieldText)] = [item.text ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
        // The friend sees that the assistant sent it too (PROTOCOL.md via_assistant); absent means the person did.
        if (item.viaAssistant) {
            fields[@(SZFriendsFieldViaAssistant)] = [SZFriendsFrame fieldWithUInt64:1 tag:SZFriendsFieldViaAssistant];
        }
        return [SZFriendsFrame frameWithType:SZFriendsFrameTypeMessage fields:fields];
    }
    case SZFriendsOutboxKindOffer:
        return [self offerFrameForEntry:entry wireID:wireID];
    case SZFriendsOutboxKindAnswer:
        return [self answerFrameForEntry:entry wireID:wireID];
    case SZFriendsOutboxKindRequest:
        if (entryWire == nil) return nil;
        *wireID = entry.entryID;
        return [SZFriendsFrame frameWithType:SZFriendsFrameTypeRequest
                                      fields:@{
                                          @(SZFriendsFieldID) : entryWire,
                                          @(SZFriendsFieldSentAt) :
                                              [SZFriendsFrame fieldWithUInt64:SZFriendsMilliseconds(entry.createdAt)
                                                                          tag:SZFriendsFieldSentAt],
                                      }];
    case SZFriendsOutboxKindPresenceSecret: {
        // Only to someone who is a friend at this moment, whatever was queued for them earlier: a removed or blocked
        // person must never receive the secret that replaced the one they knew (review: presence secret rotation).
        if (person.relation != SZFriendsRelationFriend) {
            [self applyEvent:SZFriendsOutboxEventRefused toEntry:entry.entryID];
            return nil;
        }
        // The current secret, not the one at queueing time, so a later rotation is never undone.
        NSData *secret = self.services.store.ownPresenceSecret;
        if (entryWire == nil || secret.length != 32) return nil;
        *wireID = entry.entryID;
        return [SZFriendsFrame frameWithType:SZFriendsFrameTypePresenceSecret
                                      fields:@{@(SZFriendsFieldID) : entryWire, @(SZFriendsFieldSecret) : secret}];
    }
    }
    return nil;
}

- (nullable SZFriendsFrame *)offerFrameForEntry:(SZFriendsOutboxEntry *)entry wireID:(NSString **)wireID {
    SZFriendsTransferRecord *transfer = entry.itemID ? [self.services.transfers transferWithID:entry.itemID] : nil;
    NSData *wire = SZFriendsLinkBytesFromHex(transfer.transferID);
    if (transfer == nil || wire == nil) return nil;
    switch (transfer.state) {
    case SZFriendsTransferStateQueued:
    case SZFriendsTransferStateOffered:
        break;
    case SZFriendsTransferStateSending:
    case SZFriendsTransferStateDelivered:
        // They answered it, so it arrived: the ACK was lost with an earlier session.
        [self applyEvent:SZFriendsOutboxEventAcknowledged toEntry:entry.entryID];
        return nil;
    default:
        // Withdrawn or failed before it went out: nothing to offer any more.
        [self applyEvent:SZFriendsOutboxEventRefused toEntry:entry.entryID];
        return nil;
    }
    *wireID = transfer.transferID;
    NSString *type = transfer.uniformType.length ? transfer.uniformType : transfer.fileName.pathExtension;
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    fields[@(SZFriendsFieldID)] = wire;
    fields[@(SZFriendsFieldName)] = [transfer.fileName dataUsingEncoding:NSUTF8StringEncoding];
    if (type.length > 0) fields[@(SZFriendsFieldFileType)] = [type dataUsingEncoding:NSUTF8StringEncoding];
    fields[@(SZFriendsFieldSize)] = [SZFriendsFrame fieldWithUInt64:transfer.size tag:SZFriendsFieldSize];
    fields[@(SZFriendsFieldDigest)] = transfer.contentDigest;
    SZFriendsItemRecord *item = [self.services.store itemWithID:transfer.transferID
                                                 inConversation:transfer.conversationID];
    if (item.viaAssistant) {
        fields[@(SZFriendsFieldViaAssistant)] = [SZFriendsFrame fieldWithUInt64:1 tag:SZFriendsFieldViaAssistant];
    }
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeOffer fields:fields];
}

// Answers carry their verdict in the entry's payload (SZFriendsIntentRouter.h): request answers are identified by
// the entry's own id, transfer answers by the transfer's.
- (nullable SZFriendsFrame *)answerFrameForEntry:(SZFriendsOutboxEntry *)entry wireID:(NSString **)wireID {
    NSDictionary *payload = SZFriendsAnswerPayload(entry);
    NSString *frame = payload[@"frame"];
    NSString *transferID = [payload[@"transfer_id"] isKindOfClass:[NSString class]] ? payload[@"transfer_id"] : nil;
    NSString *idHex = transferID ?: entry.entryID;
    NSData *wire = SZFriendsLinkBytesFromHex(idHex);
    if (wire == nil) return nil;
    *wireID = idHex;
    if ([frame isEqual:@"accept"] && transferID == nil) {
        return [SZFriendsFrame frameWithType:SZFriendsFrameTypeAccept fields:@{@(SZFriendsFieldID) : wire}];
    }
    if ([frame isEqual:@"decline"] && transferID == nil) {
        return [SZFriendsFrame frameWithType:SZFriendsFrameTypeDecline fields:@{@(SZFriendsFieldID) : wire}];
    }
    if ([frame isEqual:@"cancel"]) {
        return [SZFriendsFrame frameWithType:SZFriendsFrameTypeCancel fields:@{@(SZFriendsFieldID) : wire}];
    }
    if ([frame isEqual:@"offer_reply"] && transferID != nil) {
        BOOL accept = [payload[@"accept"] boolValue];
        SZFriendsTransferRecord *transfer = [self.services.transfers transferWithID:transferID];
        NSMutableDictionary *fields = [NSMutableDictionary dictionary];
        fields[@(SZFriendsFieldID)] = wire;
        fields[@(SZFriendsFieldAccept)] = [SZFriendsFrame fieldWithUInt64:accept ? 1 : 0 tag:SZFriendsFieldAccept];
        if (accept) {
            fields[@(SZFriendsFieldOffset)] = [SZFriendsFrame fieldWithUInt64:transfer.verifiedBytes
                                                                          tag:SZFriendsFieldOffset];
        }
        return [SZFriendsFrame frameWithType:SZFriendsFrameTypeOfferReply fields:fields];
    }
    SZFriendsHelperLog(@"an outbox answer has no frame this helper knows");
    [self applyEvent:SZFriendsOutboxEventRefused toEntry:entry.entryID];
    return nil;
}

#pragma mark - Waiting states

// The person's entries say "Connecting" while a dial is under way, and go back to "Queued" if none connects.
- (void)markConnectingForConversation:(NSString *)conversationID {
    SZFriendsPersonRecord *person = [self.services.store personWithConversationID:conversationID];
    if (person == nil) return;
    BOOL marked = NO;
    for (SZFriendsOutboxEntry *entry in [self.services.outbox pendingEntriesForConversation:conversationID]) {
        if (entry.state != SZFriendsOutboxStateQueued || ![self entry:entry isDeliverableTo:person]) continue;
        [self applyEvent:SZFriendsOutboxEventRouteAvailable toEntry:entry.entryID];
        marked = YES;
    }
    if (!marked) return;
    [self changed];
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsNearbyConnectingTimeout * NSEC_PER_SEC)),
                   self.queue, ^{ [weakSelf connectingTimedOutForConversation:conversationID]; });
}

- (void)connectingTimedOutForConversation:(NSString *)conversationID {
    if (self.shutDown || [self liveLinkForConversation:conversationID] != nil) return;
    BOOL changed = NO;
    for (SZFriendsOutboxEntry *entry in [self.services.outbox pendingEntriesForConversation:conversationID]) {
        if (entry.state != SZFriendsOutboxStateConnecting) continue;
        [self applyEvent:SZFriendsOutboxEventSessionLost toEntry:entry.entryID];
        changed = YES;
    }
    if (changed) [self changed];
}

- (void)requeueEntriesOfLink:(SZFriendsPeerLink *)link {
    // Back to Queued with the same id: the recipient deduplicates if it did commit one of them (ADR 0001).
    for (NSString *entryID in link.inFlightEntries) [self applyEvent:SZFriendsOutboxEventSessionLost toEntry:entryID];
    [link.inFlightEntries removeAllObjects];
}

- (void)deliverAcceptanceThenResendOnLink:(SZFriendsPeerLink *)link {
    NSString *conversationID = link.conversationID;
    if (conversationID == nil) return;
    // What this link wrote before their REQUEST arrived reached someone still waiting for our answer, who drops it
    // unacknowledged. The acceptance goes first, then those entries again, with the same ids (repeats are recognised).
    NSSet<NSString *> *dropped = [link.inFlightEntries copy];
    [self deliverPendingForConversation:conversationID];
    for (NSString *entryID in dropped) [self applyEvent:SZFriendsOutboxEventSessionLost toEntry:entryID];
    [link.inFlightEntries minusSet:dropped];
    [self deliverPendingForConversation:conversationID];
}

- (void)applyEvent:(SZFriendsOutboxEvent)event toEntry:(NSString *)entryID {
    NSError *error = nil;
    if (![self.services.outbox applyEvent:event toEntry:entryID error:&error]) {
        SZFriendsHelperLog(@"outbox event %ld not applied: %@", (long)event, error.localizedDescription);
    }
}

#pragma mark - Acknowledgements and profiles

- (void)handleAck:(SZFriendsFrame *)frame onLink:(SZFriendsPeerLink *)link {
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    NSString *token = wire ? [link takeAckForID:SZFriendsLinkHex(wire)] : nil;
    if (token == nil) return; // late, or for something this link never sent: nothing to update
    if ([token hasPrefix:@"done:"]) {
        [self link:link transferAcknowledged:[token substringFromIndex:5]];
        return;
    }
    if ([token hasPrefix:SZFriendsThumbnailAckPrefix]) {
        [self link:link thumbnailAcknowledged:[token substringFromIndex:SZFriendsThumbnailAckPrefix.length]];
        return;
    }
    [link.inFlightEntries removeObject:token];
    SZFriendsOutboxEntry *entry = [self.services.outbox entryWithID:token];
    // Checked against the conversation the ACK arrived on as well as the link's own expectations: one friend's ACK
    // never marks another friend's message delivered.
    NSError *error = nil;
    if (link.conversationID == nil ||
        ![self.services.outbox applyEvent:SZFriendsOutboxEventAcknowledged toEntry:token
                         fromConversation:link.conversationID error:&error]) {
        SZFriendsHelperLog(@"an acknowledgement was not applied: %@", error.localizedDescription);
        return;
    }
    SZFriendsStore *store = self.services.store;
    SZFriendsPersonRecord *person = link.conversationID ? [store personWithConversationID:link.conversationID] : nil;
    if (entry.kind == SZFriendsOutboxKindAnswer && [SZFriendsAnswerPayload(entry)[@"frame"] isEqual:@"accept"] &&
        (person.callbackToken != nil || person.callbackSecret != nil)) {
        // The requester knows our key now: the Add by ID token and its callback tags are spent (ADR 0004 step 4).
        person.callbackToken = nil;
        person.callbackSecret = nil;
        if ([store savePerson:person error:NULL]) [self rebuildTagMatcher];
    }
    // A removed person's link stays only to deliver the answer they are waiting for.
    if (person != nil && person.relation == SZFriendsRelationRemoved && ![self hasDeliverableEntriesForPerson:person] &&
        link.inFlightEntries.count == 0) {
        [link.channel closeWithReason:SZFriendsCloseReasonNormal];
    }
    [self changed];
}

- (void)sendAckForID:(NSData *)wireID onLink:(SZFriendsPeerLink *)link {
    if (SZFriendsHelperTestHooks.withholdAcknowledgements) return;
    NSDictionary *fields = @{@(SZFriendsFieldID) : wireID};
    [link.channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeAck fields:fields]];
}

- (void)sendProfileOnLink:(SZFriendsPeerLink *)link {
    if (link.profileSent || !link.live || link.superseded || link.conversationID == nil) return;
    SZFriendsPersonRecord *person = [self.services.store personWithConversationID:link.conversationID];
    // Friends and requests in either direction see our name and picture; removed and blocked people do not.
    if (person == nil || (person.relation != SZFriendsRelationFriend &&
                          person.relation != SZFriendsRelationOutgoingRequest &&
                          person.relation != SZFriendsRelationIncomingRequest)) {
        return;
    }
    if ([link.channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeProfile fields:[self profileFields]]]) {
        link.profileSent = YES;
    }
}

@end
