// Fast transfers on one friend's group of sessions (SZFriendsBlockExchange.h).

#import "service/transfer/SZFriendsBlockExchange.h"

#import <time.h>

#import "service/transfer/SZFriendsBlockFlow.h"
#import "service/transfer/SZFriendsScheduler.h"
#import "service/transfer/SZFriendsSlices.h"

const SZFriendsLaneID SZFriendsHeadLane = 0;

// Parts queued in a lane's channel ahead of its link, as for CHUNKs: a message still overtakes them.
static const NSUInteger SZFriendsBulkDepth = 4;

static NSString *SZFriendsBlockHex(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

static NSData *_Nullable SZFriendsBlockBytes(NSString *hex) {
    if (hex.length != 32) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:16];
    uint8_t *bytes = out.mutableBytes;
    for (NSUInteger i = 0; i < 16; i++) {
        unichar high = [hex characterAtIndex:2 * i], low = [hex characterAtIndex:2 * i + 1];
        if (!isxdigit(high) || !isxdigit(low)) return nil;
        bytes[i] = (uint8_t)(digittoint(high) << 4 | digittoint(low));
    }
    return out;
}

// What each route's PARTs carry (§ 9.8: 16 KiB on Bluetooth).
static NSUInteger SZFriendsPartBytesFor(SZFriendsRouteMethod route) {
    return route == SZFriendsRouteMethodBluetooth ? 16 << 10 : SZFriendsPartBytesMax;
}

// A session of the group: how to send on it and how much waits in it.
@interface SZFriendsLaneLink : NSObject
@property(nonatomic) SZFriendsRouteMethod route;
@property(nonatomic, copy) BOOL (^send)(SZFriendsFrame *);
@property(nonatomic, copy, nullable) NSUInteger (^queued)(void);
@end
@implementation SZFriendsLaneLink
@end

// One part waiting for its lane's queue.
@interface SZFriendsQueuedPart : NSObject
@property(nonatomic) uint32_t block;
@property(nonatomic, strong) SZFriendsFrame *frame;
@property(nonatomic) BOOL last;
@end
@implementation SZFriendsQueuedPart
@end

// One of our files going by blocks on this group.
@interface SZFriendsBlockSend : NSObject
@property(nonatomic, strong) SZFriendsBlockServe *serve; // the leaves, the leaf check and what was acknowledged
@property(nonatomic, strong) SZFriendsSliceSend *slices; // the scheduler's units, acknowledged pieces, checked blocks
@property(nonatomic, strong) SZFriendsTransferRecord *record;
@property(nonatomic) SZFriendsTransferKey key;
@property(nonatomic) BOOL resumed; // began on an earlier session
// The friend's helper has the leaves (a HAVE or WANT came back): parts may go on lanes, which could otherwise
// overtake HASHES on the head.
@property(nonatomic) BOOL lanesOK;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableArray<SZFriendsQueuedPart *> *> *lanes;
@end
@implementation SZFriendsBlockSend
@end

@implementation SZFriendsBlockExchange {
    SZFriendsTransfers *_transfers;
    NSString *_conversationID;
    NSMutableDictionary<NSNumber *, SZFriendsLaneLink *> *_links; // live sessions of the group, the head included
    SZFriendsScheduler *_scheduler;
    SZFriendsTransferKey _nextKey;
    NSMutableDictionary<NSString *, SZFriendsBlockSend *> *_senders;
    NSMutableSet<NSString *> *_receivers;
    NSMutableSet<NSString *> *_lateAnswered; // "lane:transfer:block"
    SZFriendsLaneID _control;                // the lane control frames go on: the head, or once it closed, -group.first
    NSMutableDictionary<NSString *, NSNumber *> *_finishing; // transfer id -> when its check began (clock)
    NSMutableDictionary<NSString *, NSNumber *> *_pieceBytes; // transfer id -> part bytes since its last piece HAVE
}

// Pieces are reported at least every 256 KiB of parts, after every part on Bluetooth (ADR 0018 § 3).
static const NSUInteger SZFriendsPieceHaveBytes = 256 << 10;

// Packed pairs merged into sorted, disjoint pairs.
static NSData *SZFriendsMergedRanges(NSArray<NSData *> *lists) {
    NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
    for (NSData *list in lists) {
        const uint32_t *pairs = list.bytes;
        for (NSUInteger i = 0; i < list.length / 8; i++) [set addIndexesInRange:NSMakeRange(pairs[2 * i], pairs[2 * i + 1])];
    }
    return SZFriendsIndexesAsRanges(set);
}

// A check shorter than this shows nothing: the row goes from the last block straight to saved.
static const double SZFriendsFinishingAfter = 1.0;

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
    case SZFriendsBlockPartRefused: return NO;
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

- (BOOL)offerTakenByBlocks:(NSString *)transferID {
    if ([self startSending:transferID] == nil) return NO;
    [self pump];
    return YES;
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
    send.lanesOK = YES;
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

- (BOOL)handleFrame:(SZFriendsFrame *)frame {
    return [self handleFrame:frame lane:_control];
}

- (BOOL)handleFrame:(SZFriendsFrame *)frame lane:(SZFriendsLaneID)lane {
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

- (double)nextTimer {
    return _scheduler ? [_scheduler nextTimer] : -1;
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

@end
