// Fast transfers on one friend's group of sessions (SZFriendsBlockExchange.h).

#import "service/transfer/SZFriendsBlockExchangeInternal.h"


const SZFriendsLaneID SZFriendsHeadLane = 0;

@implementation SZFriendsLaneLink
@end
@implementation SZFriendsQueuedPart
@end
@implementation SZFriendsBlockSend
@end

@implementation SZFriendsBlockExchange

- (instancetype)initWithTransfers:(SZFriendsTransfers *)transfers
                   conversationID:(NSString *)conversationID
                            route:(SZFriendsRouteMethod)route
                             send:(BOOL (^)(SZFriendsFrame *))send
                           queued:(NSUInteger (^)(void))queued {
    if ((self = [super init])) {
        _transfers = transfers;
        _conversationID = [conversationID copy];
        SZFriendsLaneLink *head = [[SZFriendsLaneLink alloc] init];
        head.route = route;
        head.send = send;
        head.queued = queued;
        _links = [NSMutableDictionary dictionaryWithObject:head forKey:@(SZFriendsHeadLane)];
        _senders = [NSMutableDictionary dictionary];
        _receivers = [NSMutableSet set];
        _lateAnswered = [NSMutableSet set];
        _finishing = [NSMutableDictionary dictionary];
        _pieceBytes = [NSMutableDictionary dictionary];
        _early = [NSMutableDictionary dictionary];
        _directWiFiKeepsInternet = YES;
        _clock = ^double {
            return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9;
        };
    }
    return self;
}

- (void)changed {
    if (self.onChanged) self.onChanged();
}

- (BOOL)sendOn:(SZFriendsLaneID)lane frame:(SZFriendsFrame *)frame {
    SZFriendsLaneLink *link = _links[@(lane)] ?: _links[@(_control)];
    return link.send != nil && link.send(frame);
}

- (BOOL)sendOnHead:(SZFriendsFrame *)frame {
    return [self sendOn:_control frame:frame];
}

- (SZFriendsLaneID)controlLane {
    return _control;
}

- (NSSet<NSString *> *)receiving {
    return [_receivers copy];
}

- (NSSet<NSString *> *)sending {
    return [NSSet setWithArray:_senders.allKeys];
}

- (BOOL)carriesTransfers {
    return _senders.count > 0 || _receivers.count > 0;
}

- (BOOL)awaitingPeer {
    if (_receivers.count > 0) return YES; // blocks are wanted: their parts are due
    for (SZFriendsBlockSend *send in _senders.allValues) {
        if ([_scheduler openBlocks:send.key bytes:NULL] > 0) return YES;
    }
    return NO;
}

#pragma mark - Lanes

- (void)formGroupWithHandshakeHash:(NSData *)h initiator:(BOOL)initiator {
    if (_group != nil) return;
    _group = [[SZFriendsLaneGroup alloc] initWithFirst:SZFriendsHeadLane handshakeHash:h initiator:initiator
                                                 route:_links[@(SZFriendsHeadLane)].route];
}

- (uint8_t)reserveLane:(SZFriendsLaneID)lane route:(SZFriendsRouteMethod)route token:(NSData **)token {
    return [_group reserve:lane route:route token:token];
}

- (SZFriendsLaneRefusal)admitLane:(SZFriendsLaneID)lane token:(NSData *)token route:(SZFriendsRouteMethod)route {
    if (_group == nil) return SZFriendsLaneRefusedToken;
    uint8_t index = 0;
    return [_group admit:lane token:token route:route index:&index];
}

- (void)laneUp:(SZFriendsLaneID)lane send:(BOOL (^)(SZFriendsFrame *))send queued:(NSUInteger (^)(void))queued {
    if (_group == nil || ![_group contains:lane]) return;
    SZFriendsLaneLink *link = [[SZFriendsLaneLink alloc] init];
    link.route = [_group routeOf:lane];
    link.send = send;
    link.queued = queued;
    _links[@(lane)] = link;
    [_group laneUp:lane];
    [self feedScheduler];
    [self pump];
}

- (BOOL)laneDown:(SZFriendsLaneID)lane {
    if (_group == nil || ![_group contains:lane]) return lane == _control;
    [_links removeObjectForKey:@(lane)];
    for (SZFriendsBlockSend *send in _senders.allValues) [send.lanes removeObjectForKey:@(lane)];
    NSString *prefix = [NSString stringWithFormat:@"%llu:", lane];
    for (NSString *answered in _lateAnswered.allObjects) {
        if ([answered hasPrefix:prefix]) [_lateAnswered removeObject:answered];
    }
    BOOL ended = [_group laneDown:lane];
    if (ended) return YES;
    // ADR 0018 § 6: the group goes on without its first session; the lowest live lane carries control frames now.
    if (lane == _control) _control = _group.first;
    [self feedScheduler];
    [self pump];
    return NO;
}

// The group's lane events since the last call, to the scheduler (made when the first file goes by blocks).
- (void)feedScheduler {
    NSArray<SZFriendsLaneEvent *> *events = [_group takeEvents];
    if (_scheduler == nil) return;
    for (SZFriendsLaneEvent *event in events) [_scheduler laneEvent:event now:self.clock()];
    [self runActions];
}

- (SZFriendsScheduler *)scheduler {
    if (_scheduler) return _scheduler;
    _scheduler = [[SZFriendsScheduler alloc] initWithPhone:NO directWiFiKeepsInternet:_directWiFiKeepsInternet];
    double now = self.clock();
    // Seeded with the sessions live now (without a group, the head alone): their events may have gone by already.
    [_group takeEvents];
    for (NSNumber *lane in _links.allKeys) {
        [_scheduler laneEvent:[SZFriendsLaneEvent up:lane.unsignedLongLongValue
                                               index:[_group indexOf:lane.unsignedLongLongValue]
                                               route:_links[lane].route] now:now];
    }
    return _scheduler;
}

- (void)runActions {
    for (SZFriendsScheduleAction *action in [_scheduler takeActions]) {
        switch (action.kind) {
        case SZFriendsScheduleSend: [self assignBlock:action.block transfer:action.transfer lane:action.lane]; break;
        case SZFriendsScheduleCancel:
            for (SZFriendsBlockSend *send in _senders.allValues) {
                if (send.key != action.transfer) continue;
                NSMutableArray<SZFriendsQueuedPart *> *queue = send.lanes[@(action.lane)];
                [queue filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SZFriendsQueuedPart *part, id b) {
                           (void)b;
                           return part.block != action.block;
                       }]];
            }
            break;
        case SZFriendsScheduleOpenLane:
            if (_group != nil && self.onOpenLane) self.onOpenLane(action.route);
            break;
        case SZFriendsScheduleCloseLane:
            if (action.lane != _control && self.onCloseLane) self.onCloseLane(action.lane);
            break;
        }
    }
}

#pragma mark - Offers and replies

+ (void)addTreeOfTransfer:(SZFriendsTransferRecord *)record
                 toFields:(NSMutableDictionary<NSNumber *, NSData *> *)fields
                transfers:(SZFriendsTransfers *)transfers {
    SZFriendsBlockGeometry geometry;
    NSData *root = nil, *leaves = nil;
    if (![transfers senderTreeForTransfer:record compute:NO geometry:&geometry root:&root leaves:&leaves]) return;
    fields[@(SZFriendsFieldTreeRoot)] = root;
    fields[@(SZFriendsFieldBlockShift)] = [NSData dataWithBytes:&geometry.shift length:1];
}

- (void)noteOffer:(SZFriendsFrame *)offer transferID:(NSString *)transferID {
    SZFriendsBlockGeometry geometry;
    NSData *root = nil;
    if (SZFriendsOfferedTree(offer, &geometry, &root)) {
        [_transfers recordOfferedTree:transferID conversation:_conversationID geometry:geometry root:root];
    }
}

+ (void)addBlocksToReply:(NSMutableDictionary<NSNumber *, NSData *> *)fields
             forTransfer:(NSString *)transferID
               transfers:(SZFriendsTransfers *)transfers {
    if (![transfers hasOfferedTree:transferID]) return;
    // Filled locally from the same file held here (§ 9.5): the CHUNK reply at its full size, and only DONE follows.
    SZFriendsTransferRecord *record = [transfers transferWithID:transferID];
    if (record != nil && !record.outgoing && record.verifiedBytes == record.size) {
        [transfers dropBlocks:transferID];
        return;
    }
    uint8_t one = 1;
    fields[@(SZFriendsFieldBlocks)] = [NSData dataWithBytes:&one length:1];
}

#pragma mark - Receiving

- (BOOL)resumeIncoming:(SZFriendsTransferRecord *)record {
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
    for (SZFriendsFrame *frame in SZFriendsWantFramesWithPieces(wire, missing, pieces)) [self sendOnHead:frame];
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

- (BOOL)showsFinishing:(NSString *)transferID {
    NSNumber *since = _finishing[transferID];
    return since != nil && self.clock() - since.doubleValue >= SZFriendsFinishingAfter;
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
    if (!bluetooth && count < SZFriendsPieceHaveBytes) {
        _pieceBytes[transferID] = @(count);
        return;
    }
    _pieceBytes[transferID] = @0;
    NSData *pieces = [_transfers takePieceHave:transferID];
    for (SZFriendsFrame *have in SZFriendsHaveFramesWithPieces(SZFriendsBlockBytes(transferID), [NSData data],
                                                               [NSData data], pieces)) {
        [self sendOn:lane frame:have];
    }
}

#pragma mark - Durability and endings

- (void)flushDue {
    for (NSString *transferID in [_transfers flushDueBlocks:NO]) {
        if ([_receivers containsObject:transferID]) [self progressed:transferID lane:_control];
    }
    if (_transfers.blocksPending && self.onFlushNeeded) self.onFlushNeeded();
}

- (void)sessionEnded {
    [_transfers flushDueBlocks:YES];
    [_transfers blocksSessionEnded:_receivers.allObjects session:self];
    [_receivers removeAllObjects];
    [_senders removeAllObjects];
    _scheduler = nil;
}

- (void)endTransfer:(NSString *)transferID {
    [_receivers removeObject:transferID];
    SZFriendsBlockSend *send = _senders[transferID];
    if (send == nil) return;
    [_senders removeObjectForKey:transferID];
    [_scheduler removeTransfer:send.key];
    [_scheduler takeActions]; // its cancels concern parts dropped with it
}

- (BOOL)offerTakenByBlocks:(NSString *)transferID {
    if ([self startSending:transferID] == nil) return NO;
    [self pump];
    return YES;
}

- (BOOL)handleFrame:(SZFriendsFrame *)frame {
    return [self handleFrame:frame lane:_control];
}

- (BOOL)handleFrame:(SZFriendsFrame *)frame lane:(SZFriendsLaneID)lane {
    _lastRefusal = [NSString stringWithFormat:@"frame %u refused on lane %llu", frame.type, lane];
    [self heard:lane];
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    if (wire.length != 16) return NO;
    NSString *transferID = SZFriendsBlockHex(wire);
    switch (frame.type) {
    case SZFriendsFrameTypeHashes: return [self hashes:frame transfer:transferID];
    case SZFriendsFrameTypeWant: return [self want:frame transfer:transferID];
    case SZFriendsFrameTypePart: return [self part:frame transfer:transferID lane:lane];
    case SZFriendsFrameTypeHave: return [self have:frame transfer:transferID];
    default: return NO;
    }
}

- (void)pump {
    if (_senders.count == 0) return;
    double now = self.clock();
    [_scheduler tick:now];
    [self runActions];
    for (NSString *transferID in _senders.allKeys) {
        SZFriendsBlockSend *send = _senders[transferID];
        for (NSNumber *lane in send.lanes.allKeys) {
            SZFriendsLaneLink *link = _links[lane];
            if (link == nil) continue;
            if (lane.unsignedLongLongValue != _control && !send.lanesOK) continue;
            NSMutableArray<SZFriendsQueuedPart *> *queue = send.lanes[lane];
            while (queue.count > 0 && (link.queued == nil || link.queued() < SZFriendsBulkDepth)) {
                SZFriendsQueuedPart *part = queue.firstObject;
                NSData *data = [part.frame dataForTag:SZFriendsFieldData];
                if (self.pace && self.pace(data.length)) return;
                if (!link.send(part.frame)) break;
                [queue removeObjectAtIndex:0];
                if (part.last) [_scheduler sent:lane.unsignedLongLongValue transfer:send.key block:part.block now:now];
            }
        }
        if (send.serve.allAcknowledged) {
            // Every block in a HAVE: the ACK after their check is what is left; nothing more to schedule.
            [send.lanes removeAllObjects];
        }
    }
    [self runActions];
}

- (void)written:(SZFriendsLaneID)lane {
    if (_scheduler == nil) return;
    // A write counts as the lane moving only while it carries parts: a PING's (sent every second while a file moves)
    // would keep a lane whose route went silent looking alive until the session's own 8 or 12 s.
    SZFriendsLaneLink *link = _links[@(lane)];
    BOOL carrying = link.queued != nil && link.queued() > 0;
    for (SZFriendsBlockSend *send in _senders.allValues) carrying |= send.lanes[@(lane)].count > 0;
    if (carrying) {
        [_scheduler written:lane now:self.clock()];
        [self runActions];
    }
    [self pump];
}

- (void)heard:(SZFriendsLaneID)lane {
    [_scheduler heard:lane now:self.clock()];
}

- (void)tick {
    if (_scheduler == nil) return;
    [_scheduler tick:self.clock()];
    [self runActions];
    [self pump];
}

- (double)rateOfRoute:(SZFriendsRouteMethod)route {
    return _scheduler ? [_scheduler rateOfRoute:route] : 0;
}

@end
