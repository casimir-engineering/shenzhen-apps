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
        _pieceLane = [NSMutableDictionary dictionary];
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

// The owner's route order (SZFriendsDiscovery.h's SZFriendsRouteRank): LAN, direct Wi-Fi, Internet, Bluetooth, relay.
static NSInteger SZFLeavesRank(SZFriendsRouteMethod route) {
    switch (route) {
    case SZFriendsRouteMethodLAN: return 0;
    case SZFriendsRouteMethodPeerToPeerWiFi: return 1;
    case SZFriendsRouteMethodInternet: return 2;
    case SZFriendsRouteMethodBluetooth: return 3;
    case SZFriendsRouteMethodRelay: return 4;
    default: return 5;
    }
}

- (SZFriendsLaneID)leavesLane {
    SZFriendsLaneID best = _control;
    NSInteger bestRank = _links[@(_control)] ? SZFLeavesRank(_links[@(_control)].route) : NSIntegerMax;
    uint8_t bestIndex = [_group indexOf:_control];
    for (NSNumber *lane in _links) {
        NSInteger rank = SZFLeavesRank(_links[lane].route);
        uint8_t index = [_group indexOf:lane.unsignedLongLongValue];
        if (rank < bestRank || (rank == bestRank && index < bestIndex)) {
            best = lane.unsignedLongLongValue, bestRank = rank, bestIndex = index;
        }
    }
    return best;
}

- (void)leavesAgainAfter:(SZFriendsLaneID)gone {
    SZFriendsLaneID lane = self.leavesLane;
    for (SZFriendsBlockSend *send in _senders.allValues) {
        if (send.leavesLane != gone || send.lanesOK) continue;
        send.leavesLane = lane;
        for (SZFriendsFrame *frame in send.serve.hashesFrames) [self sendOn:lane frame:frame];
    }
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
    [self leavesAgainAfter:lane];
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
    return [self startIncoming:record want:YES];
}

- (BOOL)beginIncoming:(SZFriendsTransferRecord *)record {
    return [self startIncoming:record want:NO];
}

- (BOOL)showsFinishing:(NSString *)transferID {
    NSNumber *since = _finishing[transferID];
    return since != nil && self.clock() - since.doubleValue >= SZFriendsFinishingAfter;
}

#pragma mark - Durability and endings

- (void)flushDue {
    for (NSString *transferID in [_transfers flushDueBlocks:NO]) {
        if ([_receivers containsObject:transferID]) [self progressed:transferID lane:_control];
    }
    // Pieces still unreported below the 256 KiB threshold (§ 3 says "at least every 256 KiB").
    for (NSString *transferID in _pieceBytes.allKeys) {
        if (_pieceBytes[transferID].unsignedIntegerValue == 0 || ![_receivers containsObject:transferID]) continue;
        [self sendPieceHave:transferID lane:_pieceLane[transferID].unsignedLongLongValue];
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

- (NSDictionary *)debugState {
    NSMutableDictionary *lanes = [NSMutableDictionary dictionary];
    for (NSNumber *lane in _links) {
        SZFriendsLaneLink *link = _links[lane];
        lanes[lane.stringValue] = @{@"route" : @(link.route), @"queued" : @(link.queued ? link.queued() : 0),
                                    @"in_flight" : @([_scheduler inFlightOfLane:lane.unsignedLongLongValue]),
                                    @"scheduled" : @([_scheduler hasLane:lane.unsignedLongLongValue])};
    }
    NSMutableDictionary *receiving = [NSMutableDictionary dictionary];
    for (NSString *transferID in _receivers) {
        NSData *pieces = [NSData data];
        NSData *missing = [_transfers blocksMissing:transferID pieces:&pieces];
        receiving[transferID] = @{@"missing_block_ranges" : @(missing.length / 8),
                                  @"first_missing" : missing.length ? @(((const uint32_t *)missing.bytes)[0]) : @(-1),
                                  @"missing_piece_ranges" : @(pieces.length / 8),
                                  @"partial_blocks" : @([_transfers blocksPartlyReceived:transferID]),
                                  @"all_durable" : @([_transfers blocksAllDurable:transferID]),
                                  @"early" : @(_early[transferID].count)};
    }
    NSMutableDictionary *sending = [NSMutableDictionary dictionary];
    for (NSString *transferID in _senders) {
        SZFriendsBlockSend *send = _senders[transferID];
        uint64_t bytes = 0;
        NSUInteger open = [_scheduler openBlocks:send.key bytes:&bytes];
        NSMutableDictionary *queues = [NSMutableDictionary dictionary];
        for (NSNumber *lane in send.lanes) queues[lane.stringValue] = @(send.lanes[lane].count);
        sending[transferID] = @{@"open_units" : @(open), @"open_bytes" : @(bytes), @"lanes_ok" : @(send.lanesOK),
                                @"queued_parts" : queues, @"done" : @([_scheduler isDone:send.key]),
                                @"all_acknowledged" : @(send.serve.allAcknowledged)};
    }
    return @{@"control" : @(_control), @"lanes" : lanes, @"receiving" : receiving, @"sending" : sending,
             @"finishing" : _finishing.allKeys, @"next_timer" : @([self nextTimer])};
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
            if (lane.unsignedLongLongValue != send.leavesLane && !send.lanesOK) continue;
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

- (uint64_t)acknowledgedBytesOfTransfer:(NSString *)transferID {
    return _senders[transferID].serve.acknowledgedBytes;
}

- (double)rateOfRoute:(SZFriendsRouteMethod)route {
    return _scheduler ? [_scheduler rateOfRoute:route] : 0;
}

@end
