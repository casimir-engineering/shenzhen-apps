// Our files going by blocks on one friend's group of sessions (SZFriendsBlockExchange.h): started from an offer they
// took, WANT and HAVE answered, each block the scheduler assigns cut into its lane's parts, and the parts pumped while
// the lanes' queues are shallow.

#import "service/transfer/SZFriendsBlockExchangeInternal.h"

@implementation SZFriendsBlockExchange (Sending)

#pragma mark - Sending

- (nullable SZFriendsBlockSend *)startSending:(NSString *)transferID {
    SZFriendsBlockSend *send = _senders[transferID];
    if (send) return send;
    BOOL first = NO;
    NSError *error = nil;
    SZFriendsTransferRecord *record = [_transfers peerTookBlocks:transferID fromConversation:_conversationID
                                                           first:&first error:&error];
    if (record == nil) {
        if (error.code == SZFriendsStoreErrorFileMissing) [self changed];
        return nil;
    }
    SZFriendsBlockGeometry geometry;
    NSData *root = nil, *leaves = nil;
    if (![_transfers senderTreeForTransfer:record compute:YES geometry:&geometry root:&root leaves:&leaves]) {
        [_transfers failTransfer:transferID reason:SZFriendsTransferFailureSourceMissing error:NULL];
        [self changed];
        return nil;
    }
    send = [[SZFriendsBlockSend alloc] init];
    send.record = record;
    send.resumed = !first;
    send.lanes = [NSMutableDictionary dictionary];
    send.serve = [[SZFriendsBlockServe alloc] initWithTransferID:SZFriendsBlockBytes(transferID)
                                                        geometry:geometry
                                                          leaves:leaves
                                                       partBytes:SZFriendsPartBytesMax
                                                     windowBytes:SZFriendsBytesInFlightMax];
    // The scheduler works in slices with a peer that has pieces, in whole blocks otherwise (§ 3, § 7).
    send.slices = [[SZFriendsSliceSend alloc] initWithGeometry:geometry pieces:self.pieces];
    send.key = ++_nextKey;
    for (SZFriendsFrame *frame in send.serve.hashesFrames) [self sendOnHead:frame];
    _senders[transferID] = send;
    SZFriendsBlockGeometry units = send.slices.units;
    [self.scheduler addTransfer:send.key geometry:units];
    if (first) [_scheduler want:send.key ranges:SZFriendsRange(0, units.blocks) now:self.clock()];
    if (self.onSending) self.onSending(transferID);
    [self runActions];
    [self changed];
    return send;
}
- (BOOL)want:(SZFriendsFrame *)frame transfer:(NSString *)transferID {
    NSData *ranges = SZFriendsFrameRanges(frame, SZFriendsFieldRanges);
    NSData *pieces = SZFriendsFrameRanges(frame, SZFriendsFieldPieces);
    if (ranges == nil || pieces == nil || ranges.length + pieces.length == 0) return NO;
    // A WANT only for an offer this side made to that person and they accepted (§ 8).
    SZFriendsTransferRecord *record = [_transfers transferWithID:transferID];
    if (record == nil || !record.outgoing || ![record.conversationID isEqualToString:_conversationID] ||
        (record.state != SZFriendsTransferStateSending && record.state != SZFriendsTransferStateOffered)) {
        // Late for a transfer of ours that ended meanwhile (delivered, cancelled): nothing to send.
        return record != nil && record.outgoing && [record.conversationID isEqualToString:_conversationID];
    }
    SZFriendsBlockSend *send = [self startSending:transferID];
    if (send == nil) return YES; // the transfer failed here (snapshot gone); it says so itself
    SZFriendsBlockGeometry geometry = send.serve.geometry;
    if (ranges.length > 0 && ![send.serve want:ranges]) return NO;
    // Pieces past the file are refused, as blocks past it are.
    uint64_t pieceCount = MAX((geometry.size + (1u << 14) - 1) >> 14, 1);
    const uint32_t *piecePairs = pieces.bytes;
    for (NSUInteger i = 0; i < pieces.length / 8; i++) {
        if ((uint64_t)piecePairs[2 * i] + piecePairs[2 * i + 1] > pieceCount) return NO;
    }
    [send.slices wantBlocks:ranges pieces:pieces];
    if (self.onWanted) {
        // The first byte wanted, whether a block's or a piece's.
        uint64_t offset = UINT64_MAX;
        if (ranges.length) offset = (uint64_t)((const uint32_t *)ranges.bytes)[0] << geometry.shift;
        if (pieces.length) offset = MIN(offset, (uint64_t)piecePairs[0] << 14);
        self.onWanted(transferID, offset, send.resumed);
    }
    // Copies of a slice wanted again are cancelled by the scheduler (it failed its check, or a restart lost it).
    NSData *units = SZFriendsMergedRanges(@[ [send.slices unitsOfBlocks:ranges], [send.slices unitsOfPieces:pieces] ]);
    if (![_scheduler want:send.key ranges:units now:self.clock()]) return NO;
    [self runActions];
    [self pump];
    return YES;
}
- (BOOL)have:(SZFriendsFrame *)frame transfer:(NSString *)transferID {
    NSData *complete = SZFriendsFrameRanges(frame, SZFriendsFieldRanges);
    NSData *pieces = SZFriendsFrameRanges(frame, SZFriendsFieldPieces);
    if (complete == nil || pieces == nil || SZFriendsFrameRanges(frame, SZFriendsFieldDurable) == nil) return NO;
    SZFriendsBlockSend *send = _senders[transferID];
    if (send == nil) {
        // ADR 0018 § 3: a HAVE for one of our transfers that ended here meanwhile is late; for anything else it is
        // unsolicited.
        SZFriendsTransferRecord *record = [_transfers transferWithID:transferID];
        return record != nil && record.outgoing && [record.conversationID isEqualToString:_conversationID];
    }
    if (complete.length > 0 && ![send.serve have:complete]) return NO;
    send.lanesOK = YES;
    [send.slices haveBlocks:complete];
    NSData *done = SZFriendsMergedRanges(@[ [send.slices unitsOfBlocks:complete], [send.slices havePieces:pieces] ]);
    [_scheduler have:send.key ranges:done now:self.clock()];
    [self runActions];
    [self changed];
    [self pump];
    return YES;
}
// The scheduler gave `block` of transfer `key` to `lane`: read it, check it against its leaf, cut it into the lane's
// parts. A block that fails its leaf means the snapshot changed: the transfer fails, as a missing source does.
// The scheduler gave `unit` (a slice, or a whole block) of transfer `key` to `lane`: its block read and checked
// against its leaf once and kept for its other slices, its pieces not yet acknowledged cut into the lane's parts.
- (void)assignBlock:(uint32_t)unit transfer:(SZFriendsTransferKey)key lane:(SZFriendsLaneID)lane {
    SZFriendsBlockSend *send = nil;
    NSString *transferID = nil;
    for (NSString *candidate in _senders) {
        if (_senders[candidate].key == key) send = _senders[candidate], transferID = candidate;
    }
    if (send == nil) return;
    uint32_t block = [send.slices blockOfUnit:unit];
    NSData *data = [send.slices cachedBlock:block];
    if (data == nil) {
        data = [_transfers readOutgoingBlock:block ofTransfer:send.record geometry:send.serve.geometry];
        if (data != nil && [send.serve checkBlock:block data:data]) [send.slices keepBlock:block data:data];
        else data = nil;
    }
    if (data == nil) {
        [_senders removeObjectForKey:transferID];
        [_scheduler removeTransfer:key];
        [_scheduler takeActions];
        [_transfers failTransfer:transferID reason:SZFriendsTransferFailureSourceMissing error:NULL];
        [self changed];
        return;
    }
    NSMutableArray<SZFriendsQueuedPart *> *queue = send.lanes[@(lane)];
    if (queue == nil) send.lanes[@(lane)] = queue = [NSMutableArray array];
    NSArray<SZFriendsFrame *> *parts = [send.slices partsOfUnit:unit transferID:SZFriendsBlockBytes(transferID)
                                                      partBytes:SZFriendsPartBytesFor(_links[@(lane)].route)];
    for (SZFriendsFrame *frame in parts) {
        SZFriendsQueuedPart *part = [[SZFriendsQueuedPart alloc] init];
        part.block = unit;
        part.frame = frame;
        [queue addObject:part];
    }
    if (parts.count == 0) {
        // Every piece of it acknowledged already, or an empty file's one block (complete at the receiver as soon as
        // the leaves check): nothing to send.
        [_scheduler sent:lane transfer:key block:unit now:self.clock()];
        return;
    }
    queue.lastObject.last = YES;
}
- (double)nextTimer {
    return _scheduler ? [_scheduler nextTimer] : -1;
}

@end
