// The multi-route scheduler (SZFriendsScheduler.h), line for line the Rust core's transfer/scheduler.rs.

#import "service/transfer/SZFriendsSchedulerInternal.h"

const double SZFriendsBluetoothHelpsBelow = 4e6;
const double SZFriendsDirectWiFiHelpsBelow = 25e6;

@implementation SZFriendsScheduleAction
+ (instancetype)kind:(SZFriendsScheduleKind)kind lane:(SZFriendsLaneID)lane transfer:(SZFriendsTransferKey)transfer
               block:(uint32_t)block route:(SZFriendsRouteMethod)route {
    SZFriendsScheduleAction *action = [[self alloc] init];
    action->_kind = kind;
    action->_lane = lane;
    action->_transfer = transfer;
    action->_block = block;
    action->_route = route;
    return action;
}
@end

@implementation SZFPlacement
@end

@implementation SZFTransfer
- (uint64_t)bytes:(uint32_t)block {
    uint64_t offset = 0;
    NSUInteger length = 0;
    SZFriendsGeometrySpan(geometry, block, &offset, &length);
    return length;
}
- (BOOL)isWanted:(uint32_t)block {
    return ((const uint8_t *)wanted.bytes)[block] != 0;
}
- (void)setWanted:(uint32_t)block to:(BOOL)value {
    ((uint8_t *)wanted.mutableBytes)[block] = value;
}
@end

@implementation SZFLane
- (double)eta:(uint64_t)bytes {
    return (double)(inFlight + bytes) / rate + rtt;
}
- (double)silentAfter {
    double floor = route == SZFriendsRouteMethodBluetooth ? SZFSilentAfterBluetooth : SZFSilentAfter;
    return MAX(floor, rtt * 3);
}
- (BOOL)working {
    return !silent && !closing && !unused;
}
// Silent by what it hears: both ends of a fast session ping every second while a file moves (ADR 0018 § 7), so a lane
// holding blocks that hears nothing for this long has lost its route, however long its measured round trip.
- (double)unheardAfter {
    return route == SZFriendsRouteMethodBluetooth ? SZFUnheardAfterBluetooth : SZFUnheardAfter;
}
static void SZFPrune(NSMutableArray<NSArray<NSNumber *> *> *samples, double now) {
    while (samples.count && now - samples.firstObject[0].doubleValue > SZFSampleWindow) [samples removeObjectAtIndex:0];
}
- (void)sampleRate:(double)value now:(double)now {
    [rates addObject:@[ @(now), @(MIN(value, 1e11)) ]];
    SZFPrune(rates, now);
    double best = 1e3;
    for (NSArray *sample in rates) best = MAX(best, [sample[1] doubleValue]);
    rate = best;
    measured = YES;
}
- (void)sampleRTT:(double)value now:(double)now {
    [rtts addObject:@[ @(now), @(value) ]];
    SZFPrune(rtts, now);
    double best = value;
    for (NSArray *sample in rtts) best = MIN(best, [sample[1] doubleValue]);
    rtt = best;
}
- (NSArray<NSNumber *> *)holdSeqs {
    return [holds.allKeys sortedArrayUsingSelector:@selector(compare:)];
}
@end

@implementation SZFriendsScheduler

- (instancetype)initWithPhone:(BOOL)phone directWiFiKeepsInternet:(BOOL)keepsInternet {
    if ((self = [super init])) {
        _phone = phone;
        _keepsInternet = keepsInternet;
        _lanes = [NSMutableDictionary dictionary];
        _transfers = [NSMutableArray array];
        _actions = [NSMutableArray array];
        _requested = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSArray<SZFriendsScheduleAction *> *)takeActions {
    NSArray *actions = [_actions copy];
    [_actions removeAllObjects];
    return actions;
}

- (void)act:(SZFriendsScheduleKind)kind lane:(SZFriendsLaneID)lane transfer:(SZFriendsTransferKey)key
      block:(uint32_t)block {
    [_actions addObject:[SZFriendsScheduleAction kind:kind lane:lane transfer:key block:block
                                                 route:SZFriendsRouteMethodNone]];
}

- (NSArray<NSNumber *> *)laneIDs {
    return [_lanes.allKeys sortedArrayUsingSelector:@selector(compare:)];
}

- (nullable SZFTransfer *)transfer:(SZFriendsTransferKey)key {
    for (SZFTransfer *transfer in _transfers) {
        if (transfer->key == key) return transfer;
    }
    return nil;
}

#pragma mark - Inputs

- (void)laneEvent:(SZFriendsLaneEvent *)event now:(double)now {
    if (event.up) {
        SZFLane *lane = [[SZFLane alloc] init];
        lane->index = event.index;
        lane->route = event.route;
        SZFTypical(event.route, &lane->rate, &lane->rtt);
        lane->rates = [NSMutableArray array];
        lane->rtts = [NSMutableArray array];
        lane->deliveredAt = lane->progressAt = lane->heardAt = now;
        lane->holds = [NSMutableDictionary dictionary];
        // The first session is wherever the route racer put it; only a lane can be refused.
        lane->unused = event.route == SZFriendsRouteMethodPeerToPeerWiFi && !_keepsInternet && event.index != 0;
        lane->closing = lane->unused;
        if (lane->unused) {
            [_actions addObject:[SZFriendsScheduleAction kind:SZFriendsScheduleCloseLane lane:event.lane transfer:0
                                                        block:0 route:SZFriendsRouteMethodNone]];
        }
        _lanes[@(event.lane)] = lane;
    } else {
        SZFLane *gone = _lanes[@(event.lane)];
        if (gone) {
            [_lanes removeObjectForKey:@(event.lane)];
            for (NSNumber *seq in gone.holdSeqs) {
                NSArray<NSNumber *> *hold = gone->holds[seq];
                SZFTransfer *transfer = [self transfer:hold[0].unsignedLongLongValue];
                if (transfer == nil) continue;
                NSMutableArray<SZFPlacement *> *placements = transfer->open[hold[1]];
                for (NSInteger i = (NSInteger)placements.count - 1; i >= 0; i--) {
                    if (placements[i]->lane == event.lane) [placements removeObjectAtIndex:i];
                }
                [self releaseIfUnplaced:transfer block:hold[1].unsignedIntValue];
            }
        }
    }
    [self fill:now];
}

- (void)addTransfer:(SZFriendsTransferKey)key geometry:(SZFriendsBlockGeometry)geometry {
    if ([self transfer:key]) return;
    SZFTransfer *transfer = [[SZFTransfer alloc] init];
    transfer->key = key;
    transfer->geometry = geometry;
    transfer->wanted = [NSMutableData dataWithLength:geometry.blocks];
    transfer->unassigned = [NSMutableIndexSet indexSet];
    transfer->open = [NSMutableDictionary dictionary];
    [_transfers addObject:transfer];
}

- (BOOL)hasTransfer:(SZFriendsTransferKey)key {
    return [self transfer:key] != nil;
}

- (void)removeTransfer:(SZFriendsTransferKey)key {
    SZFTransfer *transfer = [self transfer:key];
    if (transfer == nil) return;
    [_transfers removeObject:transfer];
    for (NSNumber *block in [transfer->open.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        for (SZFPlacement *p in transfer->open[block]) {
            SZFLane *lane = _lanes[@(p->lane)];
            if (lane == nil) continue;
            [lane->holds removeObjectForKey:@(p->seq)];
            lane->inFlight -= p->bytes;
            [self act:SZFriendsScheduleCancel lane:p->lane transfer:key block:block.unsignedIntValue];
        }
    }
}

static BOOL SZFRangesFit(NSData *ranges, uint32_t blocks) {
    const uint32_t *pairs = ranges.bytes;
    for (NSUInteger i = 0; i < ranges.length / 8; i++) {
        if ((uint64_t)pairs[2 * i] + pairs[2 * i + 1] > blocks) return NO;
    }
    return YES;
}

- (BOOL)want:(SZFriendsTransferKey)key ranges:(NSData *)ranges now:(double)now {
    SZFTransfer *transfer = [self transfer:key];
    if (transfer == nil || !SZFRangesFit(ranges, transfer->geometry.blocks)) return NO;
    const uint32_t *pairs = ranges.bytes;
    for (NSUInteger i = 0; i < ranges.length / 8; i++) {
        for (uint32_t block = pairs[2 * i]; block < pairs[2 * i] + pairs[2 * i + 1]; block++) {
            if (![transfer isWanted:block]) {
                [transfer setWanted:block to:YES];
                transfer->wantedCount++;
            }
            // A block already open is wanted again because it failed its check: its copies are cancelled.
            NSMutableArray<SZFPlacement *> *placements = transfer->open[@(block)];
            if (placements) transfer->open[@(block)] = [NSMutableArray array];
            [transfer->unassigned addIndex:block];
            for (SZFPlacement *p in placements) {
                SZFLane *lane = _lanes[@(p->lane)];
                if (lane == nil) continue;
                [lane->holds removeObjectForKey:@(p->seq)];
                lane->inFlight -= p->bytes;
                [self act:SZFriendsScheduleCancel lane:p->lane transfer:key block:block];
            }
        }
    }
    [self fill:now];
    return YES;
}

- (BOOL)have:(SZFriendsTransferKey)key ranges:(NSData *)ranges now:(double)now {
    SZFTransfer *transfer = [self transfer:key];
    if (transfer == nil || !SZFRangesFit(ranges, transfer->geometry.blocks)) return NO;
    const uint32_t *pairs = ranges.bytes;
    for (NSUInteger i = 0; i < ranges.length / 8; i++) {
        for (uint32_t block = pairs[2 * i]; block < pairs[2 * i] + pairs[2 * i + 1]; block++) {
            if (![transfer isWanted:block]) continue;
            [transfer setWanted:block to:NO];
            transfer->wantedCount--;
            [transfer->unassigned removeIndex:block];
            NSMutableArray<SZFPlacement *> *placements = transfer->open[@(block)];
            if (placements == nil) continue;
            [transfer->open removeObjectForKey:@(block)];
            transfer->openBytes -= [transfer bytes:block];
            // The copy that finished: the one whose last part was written first, else the first assigned.
            SZFPlacement *winner = nil;
            for (SZFPlacement *p in placements) {
                if (winner == nil) {
                    winner = p;
                    continue;
                }
                BOOL better = (p->hasSent && !winner->hasSent) ||
                              (p->hasSent == winner->hasSent &&
                               ((p->hasSent && p->sentAt < winner->sentAt) ||
                                ((!p->hasSent || p->sentAt == winner->sentAt) && p->seq < winner->seq)));
                if (better) winner = p;
            }
            for (SZFPlacement *p in placements) {
                SZFLane *lane = _lanes[@(p->lane)];
                if (lane == nil) continue;
                [lane->holds removeObjectForKey:@(p->seq)];
                lane->inFlight -= p->bytes;
                if (p != winner) {
                    [self act:SZFriendsScheduleCancel lane:p->lane transfer:key block:block];
                    continue;
                }
                lane->delivered += p->bytes;
                double elapsed = MAX(now - p->deliveredAt, 0.0001);
                [lane sampleRate:(double)(lane->delivered - p->delivered) / elapsed now:now];
                if (p->hasSent) [lane sampleRTT:MAX(now - p->sentAt, 0) now:now];
                lane->deliveredAt = now;
                lane->progressAt = now;
                if (lane->silent) [self recover:p->lane];
            }
        }
    }
    [self fill:now];
    return YES;
}

- (void)written:(SZFriendsLaneID)laneID now:(double)now {
    SZFLane *lane = _lanes[@(laneID)];
    if (lane == nil || lane->inFlight == 0) return;
    lane->progressAt = now;
    if (lane->silent) {
        [self recover:laneID];
        [self fill:now];
    }
}

- (void)sent:(SZFriendsLaneID)laneID transfer:(SZFriendsTransferKey)key block:(uint32_t)block now:(double)now {
    SZFTransfer *transfer = [self transfer:key];
    if (transfer == nil) return;
    for (SZFPlacement *p in transfer->open[@(block)]) {
        if (p->lane != laneID) continue;
        if (!p->hasSent) {
            p->hasSent = YES;
            p->sentAt = now;
        }
        break;
    }
    [self written:laneID now:now];
}

- (void)heard:(SZFriendsLaneID)laneID now:(double)now {
    SZFLane *lane = _lanes[@(laneID)];
    if (lane) lane->heardAt = now;
}

- (void)cpuBound:(SZFriendsLaneID)laneID now:(double)now {
    SZFLane *lane = _lanes[@(laneID)];
    if (lane == nil) return;
    NSUInteger onRoute = 0;
    for (SZFLane *other in _lanes.allValues) onRoute += other->route == lane->route;
    if (SZFriendsOneLaneOnly(lane->route) || onRoute >= SZFriendsLanesPerRoute ||
        [self unassignedBytes] < (8ull << 20)) {
        return;
    }
    [self request:lane->route now:now];
}

- (void)tick:(double)now {
    // A timer set for progressAt + silentAfter fires at exactly that sum, which minus progressAt may round below
    // silentAfter: compared with a nanosecond's slack, as the Rust core's integer durations compare exactly.
    now += 1e-9;
    for (NSNumber *laneID in self.laneIDs) {
        SZFLane *lane = _lanes[laneID];
        BOOL unheard = now - lane->heardAt >= lane.unheardAfter;
        if (!lane->silent && lane->inFlight > 0 && (now - lane->progressAt >= lane.silentAfter || unheard)) {
            [self goSilent:laneID.unsignedLongLongValue];
        }
        if (lane->silent && !lane->closing && lane->index != 0 && now - lane->heardAt >= SZFCloseSilentAfter) {
            lane->closing = YES;
            [_actions addObject:[SZFriendsScheduleAction kind:SZFriendsScheduleCloseLane
                                                         lane:laneID.unsignedLongLongValue transfer:0 block:0
                                                        route:SZFriendsRouteMethodNone]];
        }
    }
    [self fill:now];
}

- (double)nextTimer {
    double next = -1;
    for (SZFLane *lane in _lanes.allValues) {
        double at = -1;
        if (!lane->silent && lane->inFlight > 0) {
            at = MIN(lane->progressAt + lane.silentAfter, lane->heardAt + lane.unheardAfter);
        }
        else if (lane->silent && !lane->closing && lane->index != 0) at = lane->heardAt + SZFCloseSilentAfter;
        if (at >= 0 && (next < 0 || at < next)) next = at;
    }
    return next;
}

#pragma mark - Queries

- (BOOL)isDone:(SZFriendsTransferKey)key {
    SZFTransfer *transfer = [self transfer:key];
    return transfer != nil && transfer->wantedCount == 0;
}

- (NSUInteger)openBlocks:(SZFriendsTransferKey)key bytes:(uint64_t *)bytes {
    SZFTransfer *transfer = [self transfer:key];
    if (bytes) *bytes = transfer ? transfer->openBytes : 0;
    return transfer ? transfer->open.count : 0;
}

- (double)rateOfRoute:(SZFriendsRouteMethod)route {
    double sum = 0;
    for (SZFLane *lane in _lanes.allValues) {
        if (lane->route == route && lane->measured && [lane working]) sum += lane->rate;
    }
    return sum;
}

- (uint64_t)inFlightOfLane:(SZFriendsLaneID)laneID {
    SZFLane *lane = _lanes[@(laneID)];
    return lane ? lane->inFlight : 0;
}

- (uint64_t)capOfLane:(SZFriendsLaneID)laneID blockBytes:(uint64_t)blockBytes {
    SZFLane *lane = _lanes[@(laneID)];
    return lane ? [self cap:lane blockBytes:blockBytes] : 0;
}

- (BOOL)hasLane:(SZFriendsLaneID)lane {
    return _lanes[@(lane)] != nil;
}

@end
