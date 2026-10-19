// File previews between friends (brief § Transfers, Thumbnails before acceptance; PROTOCOL.md § Thumbnails): ours is
// made when a file is offered and follows its OFFER until the friend's Mac acknowledges it; theirs is kept once per
// offer and only while the file has not arrived; once it arrives and its digest checks, our own preview of the real
// file replaces theirs. Making and checking pictures is the thumbnails area's; keeping them is the store's.

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

#import <unistd.h>

#import "service/store/SZFriendsTransferThumbnails.h"

NSString *const SZFriendsThumbnailAckPrefix = @"thumb:";

@implementation SZFriendsNearbyService (Thumbnails)

- (SZFriendsThumbnailMaker *)thumbnails {
    if (self.thumbnailMaker == nil) self.thumbnailMaker = [[SZFriendsThumbnailMaker alloc] init];
    return self.thumbnailMaker;
}

#pragma mark - Ours

- (void)makeThumbnailsForTransfers:(NSArray<NSString *> *)transferIDs {
    __weak SZFriendsNearbyService *weakSelf = self;
    for (NSString *transferID in transferIDs) {
        SZFriendsTransferRecord *transfer = [self.services.transfers transferWithID:transferID];
        if (transfer == nil || !transfer.outgoing || transfer.stagedPath.length == 0) continue;
        // The snapshot is stored without an extension; the name the friend sees says what it is.
        NSString *type = transfer.uniformType ?: SZFriendsTypeIdentifierForFileName(transfer.fileName);
        [[self thumbnails] makeThumbnailOfFileAtPath:transfer.stagedPath
                                      typeIdentifier:type
                                               queue:self.queue
                                          completion:^(SZFriendsThumbnail *thumbnail) {
                                              [weakSelf keepOutgoingThumbnail:thumbnail forTransfer:transferID];
                                          }];
    }
}

- (void)keepOutgoingThumbnail:(nullable SZFriendsThumbnail *)thumbnail forTransfer:(NSString *)transferID {
    if (thumbnail == nil || self.shutDown) return;
    SZFriendsTransfers *transfers = self.services.transfers;
    NSError *error = nil;
    NSString *path = SZFriendsWriteThumbnailFile(thumbnail.png, transfers.thumbnailDirectory, &error);
    if (path == nil) {
        SZFriendsHelperLog(@"could not write a preview: %@", error.localizedDescription);
        return;
    }
    // Stale when the offer was answered or withdrawn while QuickLook worked: then nobody needs the picture.
    if (![transfers setOutgoingThumbnailForTransfer:transferID path:path width:thumbnail.width
                                             height:thumbnail.height qoi:thumbnail.qoi error:&error]) {
        unlink(path.fileSystemRepresentation);
        return;
    }
    NSString *conversationID = [transfers transferWithID:transferID].conversationID;
    if (conversationID != nil) [self deliverPendingForConversation:conversationID];
    [self changed];
}

- (void)sendThumbnailsOnLink:(SZFriendsPeerLink *)link {
    // A peer that negotiated minor 0 does not know THUMBNAIL and would close the session on it (ADR 0001).
    if (link.channel.negotiatedMinor < 1 || !link.live || !link.adopted || link.closed || link.superseded ||
        link.conversationID == nil) {
        return;
    }
    NSArray<SZFriendsThumbnailRecord *> *waiting =
        [self.services.transfers thumbnailsToSendInConversation:link.conversationID];
    if (waiting.count == 0) return;
    // Each preview goes after its OFFER: only once the offer is on this link, or already acknowledged.
    NSMutableDictionary<NSString *, NSString *> *offerEntries = [NSMutableDictionary dictionary];
    for (SZFriendsOutboxEntry *entry in [self.services.outbox pendingEntriesForConversation:link.conversationID]) {
        if (entry.kind == SZFriendsOutboxKindOffer && entry.itemID != nil) offerEntries[entry.itemID] = entry.entryID;
    }
    for (SZFriendsThumbnailRecord *record in waiting) {
        NSData *wire = SZFriendsLinkBytesFromHex(record.transferID);
        if (wire == nil || record.qoi == nil || [link.thumbnailsSent containsObject:record.transferID]) continue;
        SZFriendsTransferRecord *transfer = [self.services.transfers transferWithID:record.transferID];
        NSString *entryID = offerEntries[record.transferID];
        BOOL offerSent = transfer.state == SZFriendsTransferStateOffered ||
                         (entryID != nil && [link.inFlightEntries containsObject:entryID]);
        if (!offerSent) continue;
        NSDictionary *fields = @{
            @(SZFriendsFieldID) : wire,
            @(SZFriendsFieldWidth) : [SZFriendsFrame fieldWithUInt64:record.width tag:SZFriendsFieldWidth],
            @(SZFriendsFieldHeight) : [SZFriendsFrame fieldWithUInt64:record.height tag:SZFriendsFieldHeight],
            @(SZFriendsFieldData) : record.qoi,
        };
        // The channel queues it with file data, so messages sent meanwhile overtake it.
        if (![link.channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeThumbnail fields:fields]]) {
            continue;
        }
        [link.thumbnailsSent addObject:record.transferID];
        NSString *token = [SZFriendsThumbnailAckPrefix stringByAppendingString:record.transferID];
        [link expectAckForID:record.transferID token:token];
    }
}

- (void)link:(SZFriendsPeerLink *)link thumbnailAcknowledged:(NSString *)transferID {
    [link.thumbnailsSent removeObject:transferID];
    NSError *error = nil;
    if (link.conversationID == nil ||
        ![self.services.transfers markThumbnailDelivered:transferID fromConversation:link.conversationID
                                                   error:&error]) {
        SZFriendsHelperLog(@"a preview acknowledgement was not applied: %@", error.localizedDescription);
    }
}

#pragma mark - Theirs

// Whether this THUMBNAIL is kept: refused, changing nothing, unless it names one of this friend's offers whose file
// has not arrived and that has no preview yet, and passes every check before anything is allocated for its pixels.
- (BOOL)keepThumbnail:(NSData *)qoi width:(uint64_t)width height:(uint64_t)height
          forTransfer:(NSString *)transferID person:(SZFriendsPersonRecord *)person {
    SZFriendsTransfers *transfers = self.services.transfers;
    if (![transfers mayRecordReceivedThumbnailForTransfer:transferID fromConversation:person.conversationID]) {
        SZFriendsHelperLog(@"a preview for an offer that is not waiting, or a second one, was refused");
        return NO;
    }
    NSString *reason = nil;
    NSData *png = SZFriendsPNGFromReceivedThumbnail(qoi, width, height, &reason);
    if (png == nil) {
        SZFriendsHelperLog(@"a preview was refused: %@", reason);
        return NO;
    }
    NSError *error = nil;
    NSString *path = SZFriendsWriteThumbnailFile(png, transfers.thumbnailDirectory, &error);
    if (path == nil) {
        SZFriendsHelperLog(@"could not write a preview: %@", error.localizedDescription);
        return NO;
    }
    if (![transfers recordReceivedThumbnailForTransfer:transferID fromConversation:person.conversationID path:path
                                                 width:(NSUInteger)width height:(NSUInteger)height error:&error]) {
        unlink(path.fileSystemRepresentation);
        return NO;
    }
    return YES;
}

- (void)link:(SZFriendsPeerLink *)link
                person:(SZFriendsPersonRecord *)person
     receivedThumbnail:(SZFriendsFrame *)frame {
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    NSData *qoi = [frame dataForTag:SZFriendsFieldData];
    uint64_t width = 0, height = 0;
    if (wire == nil || qoi == nil || ![frame getUInt64:&width forTag:SZFriendsFieldWidth] ||
        ![frame getUInt64:&height forTag:SZFriendsFieldHeight]) {
        return;
    }
    BOOL kept = [self keepThumbnail:qoi width:width height:height forTransfer:SZFriendsLinkHex(wire) person:person];
    // Acknowledged whatever was decided, after the commit when it was kept: an honest sender stops resending, and the
    // ACKs that share an offer's id keep arriving in the order its frames were sent (SZFriendsPeerLink).
    [self sendAckForID:wire onLink:link];
    if (kept) [self changed];
}

- (void)makeLocalThumbnailForReceivedTransfer:(NSString *)transferID {
    SZFriendsTransferRecord *transfer = [self.services.transfers transferWithID:transferID];
    if (transfer == nil || transfer.outgoing || transfer.state != SZFriendsTransferStateReceived ||
        transfer.receivedPath.length == 0) {
        return;
    }
    __weak SZFriendsNearbyService *weakSelf = self;
    [[self thumbnails] makeThumbnailOfFileAtPath:transfer.receivedPath
                                  typeIdentifier:nil
                                           queue:self.queue
                                      completion:^(SZFriendsThumbnail *thumbnail) {
                                          [weakSelf replaceThumbnail:thumbnail ofReceivedTransfer:transferID];
                                      }];
}

- (void)replaceThumbnail:(nullable SZFriendsThumbnail *)thumbnail ofReceivedTransfer:(NSString *)transferID {
    if (self.shutDown) return;
    SZFriendsTransfers *transfers = self.services.transfers;
    // No picture of the real file means none at all: the sender's picture is not proof of what arrived.
    NSString *path = thumbnail ? SZFriendsWriteThumbnailFile(thumbnail.png, transfers.thumbnailDirectory, NULL) : nil;
    if (![transfers replaceThumbnailOfReceivedTransfer:transferID localPath:path width:thumbnail.width
                                                height:thumbnail.height error:NULL] && path != nil) {
        unlink(path.fileSystemRepresentation);
    }
    [self changed];
}

@end
