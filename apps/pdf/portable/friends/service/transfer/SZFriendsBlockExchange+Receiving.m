// Our downloads by blocks on one friend's group of sessions (SZFriendsBlockExchange.h): a download begun or resumed
// (WANT for what is missing), the leaves and the parts taken into the store, HAVE as blocks and pieces arrive, and the
// check before a file is saved.

#import "service/transfer/SZFriendsBlockExchangeInternal.h"

@implementation SZFriendsBlockExchange (Receiving)

- (BOOL)startIncoming:(SZFriendsTransferRecord *)record want:(BOOL)want {
    NSString *transferID = record.transferID;
    if (![_transfers hasOfferedTree:transferID]) return NO;
    NSError *error = nil;
    if (![_transfers beginBlocks:transferID conversation:_conversationID error:&error]) {
        // Taken by CHUNK after all: the CHUNK flow resumes from the prefix, and the map would lie.
        [_transfers dropBlocks:transferID];
        return NO;
    }
    [_receivers addObject:transferID];
    [_transfers claimBlocks:transferID forSession:self];
    NSData *wire = SZFriendsBlockBytes(transferID);
    // With pieces, partly received blocks are wanted by their missing pieces; to a peer without, whole (§ 3).
    NSData *pieces = [NSData data];
    NSData *missing = self.pieces ? [_transfers blocksMissing:transferID pieces:&pieces]
                                  : [_transfers blocksMissing:transferID];
    if (want) {
        for (SZFriendsFrame *frame in SZFriendsWantFramesWithPieces(wire, missing, pieces)) [self sendOnHead:frame];
    }
    // Every block arrived before the last session ended: the check and the ACK are all that is left.
    if (missing.length == 0 && pieces.length == 0) [self progressed:transferID lane:_control];
    return YES;
}

// After blocks were written or made durable: HAVE for what changed, on the lane that carried the parts (so it follows
// them and the sender measures that lane's round trip), and once every block is durable, the check and the ACK.
- (void)progressed:(NSString *)transferID lane:(SZFriendsLaneID)lane {
    NSData *complete = nil, *durable = nil;
    [_transfers takeBlockHave:transferID complete:&complete durable:&durable];
    NSData *wire = SZFriendsBlockBytes(transferID);
    for (SZFriendsFrame *frame in SZFriendsHaveFrames(wire, complete, durable)) [self sendOn:lane frame:frame];
    if (complete.length || durable.length) [self changed];
    if (![_transfers blocksAllDurable:transferID]) return;
    [_receivers removeObject:transferID];
    if (_finishing[transferID] != nil) return;
    NSError *error = nil;
    if (self.queue == nil) {
        BOOL saved = [_transfers finishBlockTransfer:transferID fromConversation:_conversationID error:&error];
        [self checked:transferID saved:saved error:error];
        return;
    }
    // The check reads the whole file: off the store's queue and this one; past a second the row says "Finishing…".
    SZFriendsBlockCheck *check = [_transfers beginBlockCheck:transferID fromConversation:_conversationID error:&error];
    if (check == nil) {
        if (error.code != SZFriendsStoreErrorStale) [self checked:transferID saved:NO error:error];
        return;
    }
    _finishing[transferID] = @(self.clock());
    dispatch_queue_t queue = self.queue;
    SZFriendsTransfers *transfers = _transfers;
    __weak SZFriendsBlockExchange *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsFinishingAfter * NSEC_PER_SEC)), queue, ^{
        [weakSelf changed];
    });
    // The exchange lives until its check completes, so the file is announced (and acknowledged, when its session
    // still lives) even if the session ended meanwhile.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [check run];
        dispatch_async(queue, ^{
            NSError *failure = nil;
            BOOL saved = [transfers completeBlockCheck:check error:&failure];
            [self->_finishing removeObjectForKey:transferID];
            [self checked:transferID saved:saved error:failure];
        });
    });
    [self changed];
}

// The check before saving finished: saved and acknowledged, or deleted and failed.
- (void)checked:(NSString *)transferID saved:(BOOL)saved error:(nullable NSError *)error {
    if (saved) {
        NSData *wire = SZFriendsBlockBytes(transferID);
        [self sendOnHead:[SZFriendsFrame frameWithType:SZFriendsFrameTypeAck fields:@{@(SZFriendsFieldID) : wire}]];
        if (self.onReceived) self.onReceived(transferID);
    } else {
        NSLog(@"Friends: a file received by blocks did not check: %@", error.localizedDescription);
    }
    [self changed];
}

- (BOOL)hashes:(SZFriendsFrame *)frame transfer:(NSString *)transferID {
    NSData *index = [frame dataForTag:SZFriendsFieldIndex], *hashes = [frame dataForTag:SZFriendsFieldHashes];
    const uint8_t *bytes = index.bytes;
    uint32_t first = ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3];
    NSError *error = nil;
    if ([_transfers acceptBlockHashes:hashes index:first forTransfer:transferID fromConversation:_conversationID
                                error:&error]) {
        if (![_receivers containsObject:transferID]) {
            [_receivers addObject:transferID];
            [_transfers claimBlocks:transferID forSession:self];
        }
        NSMutableIndexSet *early = _early[transferID];
        if (early.count > 0 && [_transfers blockLeavesKnown:transferID]) {
            [_early removeObjectForKey:transferID];
            for (SZFriendsFrame *want in SZFriendsWantFrames(SZFriendsBlockBytes(transferID),
                                                            SZFriendsIndexesAsRanges(early))) {
                [self sendOnHead:want];
            }
        }
        [self progressed:transferID lane:_control];
        return YES;
    }
    return error.code == SZFriendsStoreErrorStale; // cancelled or finished meanwhile
}

- (BOOL)part:(SZFriendsFrame *)frame transfer:(NSString *)transferID lane:(SZFriendsLaneID)lane {
    // Compressed parts are capability bit 2, which this build does not set.
    if ([frame dataForTag:SZFriendsFieldCodec] != nil) return NO;
    uint64_t offset = 0;
    NSData *data = [frame dataForTag:SZFriendsFieldData];
    if (![frame getUInt64:&offset forTag:SZFriendsFieldOffset] || data == nil) return NO;
    if (![_receivers containsObject:transferID]) {
        // ADR 0018 § 3: late for a transfer that just ended here (a block sent on two lanes, a part already on its
        // way when the file was complete or cancelled); unsolicited otherwise.
        SZFriendsTransferRecord *record = [_transfers transferWithID:transferID];
        return record != nil && !record.outgoing && [record.conversationID isEqualToString:_conversationID];
    }
    uint32_t block = 0;
    NSError *error = nil;
    switch ([_transfers acceptBlockPart:data atOffset:offset forTransfer:transferID fromConversation:_conversationID
                                  block:&block error:&error]) {
    case SZFriendsBlockPartRefused:
        _lastRefusal = [NSString stringWithFormat:@"PART refused at %llu (%lu bytes) on lane %llu: %@; %lu blocks partly "
                                                  @"received",
                                                  offset, (unsigned long)data.length, lane,
                                                  error.localizedDescription ?: @"?",
                                                  (unsigned long)[_transfers blocksPartlyReceived:transferID]];
        return NO;
    case SZFriendsBlockPartPending: [self piecesArrived:transferID lane:lane bytes:data.length]; return YES;
    case SZFriendsBlockPartLate: {
        // The first late part of a block on each lane is answered with a HAVE naming it, on that lane (§ 3): when the
        // lane that completed it went silent with its HAVE, the copy sent again elsewhere would otherwise wait forever.
        NSString *answered = [NSString stringWithFormat:@"%llu:%@:%u", lane, transferID, block];
        if (![_lateAnswered containsObject:answered]) {
            [_lateAnswered addObject:answered];
            for (SZFriendsFrame *have in SZFriendsHaveFrames(SZFriendsBlockBytes(transferID), SZFriendsRange(block, 1),
                                                             [NSData data])) {
                [self sendOn:lane frame:have];
            }
        }
        return YES;
    }
    case SZFriendsBlockPartStale: [_receivers removeObject:transferID]; return YES;
    case SZFriendsBlockPartEarly: {
        // A part on a lane overtook HASHES on the first session (a sender that took a WANT for the leaves' arrival):
        // dropped, and its block wanted again once the leaves check, so the transfer goes on rather than ending.
        NSMutableIndexSet *early = _early[transferID];
        if (early == nil) _early[transferID] = early = [NSMutableIndexSet indexSet];
        [early addIndex:block];
        return YES;
    }
    case SZFriendsBlockPartCorrupt: {
        // Fetched again alone; the file does not restart.
        for (SZFriendsFrame *want in SZFriendsWantFrames(SZFriendsBlockBytes(transferID), SZFriendsRange(block, 1))) {
            [self sendOnHead:want];
        }
        return YES;
    }
    case SZFriendsBlockPartWritten:
        [self progressed:transferID lane:lane];
        if (_transfers.blocksPending && self.onFlushNeeded) self.onFlushNeeded();
        return YES;
    }
    return NO;
}

// Pieces that arrived in blocks not yet complete, reported on the lane that carried them at least every 256 KiB of
// parts, after every part on Bluetooth (§ 3), so a lost lane or route costs only what was in flight.
- (void)piecesArrived:(NSString *)transferID lane:(SZFriendsLaneID)lane bytes:(NSUInteger)bytes {
    if (!self.pieces) return;
    BOOL bluetooth = _links[@(lane)].route == SZFriendsRouteMethodBluetooth;
    NSUInteger count = _pieceBytes[transferID].unsignedIntegerValue + bytes;
    _pieceLane[transferID] = @(lane);
    if (!bluetooth && count < SZFriendsPieceHaveBytes) {
        // Below the threshold: sent anyway at the next flush, so a stream that pauses (a few pieces sent again after
        // a cut) is still acknowledged, and its sender, which waits for them, goes on.
        _pieceBytes[transferID] = @(count);
        if (self.onFlushNeeded) self.onFlushNeeded();
        return;
    }
    [self sendPieceHave:transferID lane:lane];
}

- (void)sendPieceHave:(NSString *)transferID lane:(SZFriendsLaneID)lane {
    _pieceBytes[transferID] = @0;
    NSData *pieces = [_transfers takePieceHave:transferID];
    for (SZFriendsFrame *have in SZFriendsHaveFramesWithPieces(SZFriendsBlockBytes(transferID), [NSData data],
                                                               [NSData data], pieces)) {
        [self sendOn:lane frame:have];
    }
}

@end
