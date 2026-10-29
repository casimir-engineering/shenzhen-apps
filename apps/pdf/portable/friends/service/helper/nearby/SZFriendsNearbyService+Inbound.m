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

// A friend's name as other people chose it: plain text, but no control or direction-override characters (which
// could make it display as something else) and no more than the 40 characters a name may have.
static NSString *_Nullable SZFriendsCleanName(NSData *_Nullable bytes) {
    NSString *name = bytes ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : nil;
    if (name == nil) return nil;
    NSMutableCharacterSet *forbidden = [NSMutableCharacterSet controlCharacterSet];
    [forbidden addCharactersInRange:NSMakeRange(0x202a, 5)];
    [forbidden addCharactersInRange:NSMakeRange(0x2066, 4)];
    [forbidden addCharactersInRange:NSMakeRange(0x2028, 2)];
    name = [[name componentsSeparatedByCharactersInSet:forbidden] componentsJoinedByString:@""];
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    __block NSUInteger count = 0, cut = name.length;
    [name enumerateSubstringsInRange:NSMakeRange(0, name.length)
                             options:NSStringEnumerationByComposedCharacterSequences |
                                     NSStringEnumerationSubstringNotRequired
                          usingBlock:^(NSString *s, NSRange range, NSRange enclosing, BOOL *stop) {
                              (void)s, (void)enclosing;
                              if (++count > 40) {
                                  cut = range.location;
                                  *stop = YES;
                              }
                          }];
    name = [name substringToIndex:cut];
    return name.length > 0 ? name : nil;
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

- (void)link:(SZFriendsPeerLink *)link receivedFrame:(SZFriendsFrame *)frame {
    if (link.closed) return;
    [self noteFrame:frame onLink:link];
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

#pragma mark - Content

- (void)link:(SZFriendsPeerLink *)link person:(SZFriendsPersonRecord *)person receivedMessage:(SZFriendsFrame *)frame {
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    uint64_t sentAt = 0;
    if (wire == nil || person.relation != SZFriendsRelationFriend) return; // not friends: never stored, never ACKed
    [frame getUInt64:&sentAt forTag:SZFriendsFieldSentAt];
    SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
    item.itemID = SZFriendsLinkHex(wire);
    item.conversationID = person.conversationID;
    item.kind = SZFriendsItemKindMessage;
    item.direction = SZFriendsDirectionIncoming;
    item.receivedAt = [NSDate date];
    // The sender's clock, clamped by the store to the receive time so a fast clock cannot pin it to the bottom.
    item.sentAt = [NSDate dateWithTimeIntervalSince1970:(double)sentAt / 1000.0];
    // Only well-formed mentions stay links; anything else pointing at szfriends: is stored as plain text (ADR 0007).
    item.text = [self textWithCheckedMentions:[frame stringForTag:SZFriendsFieldText] ?: @""];
    uint64_t assistant = 0;
    item.viaAssistant = [frame getUInt64:&assistant forTag:SZFriendsFieldViaAssistant] && assistant == 1;
    NSError *error = nil;
    // A duplicate (the ACK was lost) returns YES without a second copy, and is acknowledged again.
    BOOL known = [self.services.store itemWithID:item.itemID inConversation:item.conversationID] != nil;
    if (![self.services.store insertItem:item error:&error]) {
        SZFriendsHelperLog(@"could not store a message: %@", error.localizedDescription);
        return;
    }
    [self sendAckForID:wire onLink:link];
    if (!known) [self.services.notifier noteMessage:item]; // decided once, when it first reaches this Mac
    [self changed];
}

- (void)link:(SZFriendsPeerLink *)link person:(SZFriendsPersonRecord *)person receivedOffer:(SZFriendsFrame *)frame {
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    uint64_t size = 0;
    if (wire == nil || ![frame getUInt64:&size forTag:SZFriendsFieldSize]) return;
    NSString *transferID = SZFriendsLinkHex(wire);
    NSString *name = [frame stringForTag:SZFriendsFieldName] ?: @"";
    NSError *error = nil;
    BOOL known = [self.services.transfers transferWithID:transferID inConversation:person.conversationID] != nil;
    SZFriendsTransferRecord *record =
        [self.services.transfers recordIncomingOfferWithID:transferID
                                            conversationID:person.conversationID
                                                  fileName:name
                                               uniformType:[frame stringForTag:SZFriendsFieldFileType]
                                                      size:size
                                             contentDigest:[frame dataForTag:SZFriendsFieldDigest] ?: [NSData data]
                                                    sentAt:[NSDate date]
                                                     error:&error];
    // The tree it announced, kept for when the person accepts (ADR 0018 § 2).
    if (record != nil) [[self blocksOnLink:link] noteOffer:frame transferID:transferID];
    // Marked before the ACK, so a crash between the two writes leaves the sender to offer it again and mark it then.
    uint64_t assistant = 0;
    if (record != nil && [frame getUInt64:&assistant forTag:SZFriendsFieldViaAssistant] && assistant == 1) {
        [self.services.store markItemSentByAssistant:transferID inConversation:person.conversationID error:NULL];
    }
    [self sendAckForID:wire onLink:link];
    if (record == nil) {
        // Refused before anything was allocated (not a friend, malformed, a flood): it is declined, so the sender
        // stops offering it rather than retrying for 30 days.
        NSDictionary *fields = @{@(SZFriendsFieldID) : wire,
                                 @(SZFriendsFieldAccept) : [SZFriendsFrame fieldWithUInt64:0 tag:SZFriendsFieldAccept]};
        [link.channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeOfferReply fields:fields]];
        return;
    }
    // Automatic acceptance gets every check a manual one gets; low disk falls back to asking (the store decides).
    BOOL automatic = [self.services.transfers applyAutomaticAcceptanceToTransfer:transferID error:NULL] ==
                     SZFriendsAutoAcceptDownload;
    if (!known) [self.services.notifier noteOffer:record automatic:automatic];
    if (automatic) {
        [self enqueueKind:SZFriendsOutboxKindAnswer conversationID:person.conversationID
                  payload:@{@"frame" : @"offer_reply", @"transfer_id" : transferID, @"accept" : @YES}];
        // The answer first, then where the download stands: the sender starts on the PROGRESS that follows.
        [self deliverPendingForConversation:person.conversationID];
        SZFriendsPeerLink *active = [self liveLinkForConversation:person.conversationID];
        if (active != nil) [self startTransfersOnLink:active];
    }
    [self changed];
}

- (void)link:(SZFriendsPeerLink *)link
                person:(SZFriendsPersonRecord *)person
    receivedOfferReply:(SZFriendsFrame *)frame {
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    uint64_t accept = 0, offset = 0;
    if (wire == nil || ![frame getUInt64:&accept forTag:SZFriendsFieldAccept]) return;
    [frame getUInt64:&offset forTag:SZFriendsFieldOffset];
    NSString *transferID = SZFriendsLinkHex(wire);
    uint64_t blocks = 0;
    if (accept == 1 && [frame getUInt64:&blocks forTag:SZFriendsFieldBlocks] && blocks == 1 &&
        [[self blocksOnLink:link] offerTakenByBlocks:transferID]) {
        // By blocks (ADR 0018): every block is checked against its leaf as it is read, so no whole-file hash first.
        [self sendAckForID:wire onLink:link];
        [self changed];
        return;
    }
    // A late or replayed answer is stale and changes nothing; the snapshot is checked against the digest here.
    BOOL done = [self.services.transfers peerAnsweredTransfer:transferID accepted:accept == 1 offset:offset
                                             fromConversation:person.conversationID error:NULL];
    if (!done || accept != 1) [self stopTransfer:transferID];
    [self sendAckForID:wire onLink:link];
    [self changed];
}

- (void)link:(SZFriendsPeerLink *)link person:(SZFriendsPersonRecord *)person
    receivedPresenceSecret:(SZFriendsFrame *)frame {
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    NSData *secret = [frame dataForTag:SZFriendsFieldSecret];
    if (wire == nil || secret.length != 32) return;
    if (person.relation == SZFriendsRelationFriend && ![person.presenceSecret isEqualToData:secret]) {
        person.presenceSecret = secret;
        if (![self.services.store savePerson:person error:NULL]) return;
        [self rebuildTagMatcher];
    }
    [self sendAckForID:wire onLink:link];
}

#pragma mark - Profiles

- (void)link:(SZFriendsPeerLink *)link receivedProfile:(SZFriendsFrame *)frame {
    SZFriendsPersonRecord *person =
        link.conversationID ? [self.services.store personWithConversationID:link.conversationID] : nil;
    if (person == nil) {
        link.pendingProfile = frame.fields; // a stranger's request session: kept for the REQUEST that follows
        return;
    }
    [self applyProfile:frame.fields toPerson:person];
}

- (void)applyProfile:(NSDictionary<NSNumber *, NSData *> *)fields toPerson:(SZFriendsPersonRecord *)person {
    if (person.relation != SZFriendsRelationFriend && person.relation != SZFriendsRelationIncomingRequest &&
        person.relation != SZFriendsRelationOutgoingRequest) {
        return;
    }
    [self updatePerson:person withProfile:fields];
    if ([self.services.store savePerson:person error:NULL]) [self changed];
}

- (void)updatePerson:(SZFriendsPersonRecord *)person withProfile:(NSDictionary<NSNumber *, NSData *> *)fields {
    person.name = SZFriendsCleanName(fields[@(SZFriendsFieldName)]);
    NSData *idBytes = fields[@(SZFriendsFieldFriendsID)];
    NSString *typed = idBytes ? [[NSString alloc] initWithData:idBytes encoding:NSUTF8StringEncoding] : nil;
    NSString *friendsID = typed ? [self.services.codec normalizedID:typed] : nil;
    if (friendsID != nil) person.friendsID = friendsID;
    SZFriendsFrame *probe = [SZFriendsFrame frameWithType:SZFriendsFrameTypeProfile fields:fields];
    uint64_t set = 0, index = 0;
    NSData *jpeg = fields[@(SZFriendsFieldData)];
    if ([probe getUInt64:&set forTag:SZFriendsFieldPictureSet] &&
        [probe getUInt64:&index forTag:SZFriendsFieldPictureIndex]) {
        // Stored even when this copy lacks that animal: it draws as a placeholder until an update brings it.
        person.picture = [SZFriendsPicture animalWithSet:(NSInteger)set index:(NSInteger)index];
    } else if (jpeg != nil) {
        // Never trusted as sent: validated, then re-encoded, so the views only decode JPEGs this helper wrote.
        NSData *normalized = [SZFriendsPicturePipeline normalizedReceivedImage:jpeg error:NULL];
        SZFriendsPicture *picture =
            normalized ? [SZFriendsPicturePipeline storeImage:normalized
                                                  inDirectory:self.services.paths.picturesDirectory
                                                        error:NULL]
                       : nil;
        person.picture = picture ?: [SZFriendsPicture placeholder];
    } else {
        person.picture = [SZFriendsPicture placeholder];
    }
}

@end
