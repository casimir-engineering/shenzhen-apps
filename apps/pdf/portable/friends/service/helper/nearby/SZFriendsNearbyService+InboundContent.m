// Frames from the other side once it is a friend: messages, offers and their replies, presence secrets and profiles
// (SZFriendsNearbyService+Inbound.m receives every frame and sends these here). Each is committed before its ACK goes
// back, so an ACK always means the item is on this Mac (ADR 0001 § Messages).

#import "service/helper/nearby/SZFriendsNearbyDevices.h"

#import "service/identity/SZFriendsDeviceChain.h"
#import "service/store/SZFriendsStoreDevices.h"
#import "service/helper/nearby/SZFriendsNearbyJoin.h"

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

@implementation SZFriendsNearbyService (InboundContent)

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
