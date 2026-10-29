// The multi-route scheduler (SZFriendsScheduler.h), line for line the Rust core's transfer/scheduler.rs.

#import "service/transfer/SZFriendsScheduler.h"

const double SZFriendsBluetoothHelpsBelow = 4e6;
const double SZFriendsDirectWiFiHelpsBelow = 25e6;

// How far back rate and round-trip samples count.
static const double SZFSampleWindow = 10;
// A silent lane: no block completed and no write finished for this long, or 3 round trips if longer.
static const double SZFSilentAfter = 1, SZFSilentAfterBluetooth = 2;
// A lane holding blocks that hears nothing from the peer this long is silent (the peer pings every second).
static const double SZFUnheardAfter = 2.5, SZFUnheardAfterBluetooth = 3.5;
// A lane slower than this many seconds per block holds one block at a time.
static const double SZFSlowBlockSeconds = 1.0;
// A silent lane is closed after this long without a byte from the peer.
static const double SZFCloseSilentAfter = 10;
// In flight per lane at most.
static const uint64_t SZFLaneBytesMax = 32ull << 20, SZFLaneBytesMaxPhone = 8ull << 20;
// The same lane request is not repeated sooner than this.
static const double SZFRequestAgainAfter = 10;
// A lane is worth asking for only when the work left would take the current lanes longer than this.
static const double SZFWorthALane = 4.0;

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

// What a route typically does, until a lane on it has measured itself.
static void SZFTypical(SZFriendsRouteMethod route, double *rate, double *rtt) {
    switch (route) {
    case SZFriendsRouteMethodLAN: *rate = 40e6, *rtt = 0.005; return;
    case SZFriendsRouteMethodPeerToPeerWiFi: *rate = 20e6, *rtt = 0.005; return;
    case SZFriendsRouteMethodInternet: *rate = 4e6, *rtt = 0.050; return;
    case SZFriendsRouteMethodRelay: *rate = 0.5e6, *rtt = 0.100; return;
    case SZFriendsRouteMethodBluetooth: *rate = 0.15e6, *rtt = 0.040; return;
    default: *rate = 1e6, *rtt = 0.100; return;
    }
}

@interface SZFPlacement : NSObject {
  @public
    SZFriendsLaneID lane;
    uint64_t seq;
    uint64_t bytes;
    BOOL hasSent;
    double sentAt;
    uint64_t delivered; // the lane's delivered bytes and its last delivery's time when assigned (BBR's sample)
    double deliveredAt;
}
@end
@implementation SZFPlacement
@end

@interface SZFTransfer : NSObject {
  @public
    SZFriendsTransferKey key;
    SZFriendsBlockGeometry geometry;
    NSMutableData *wanted; // one byte per block
    uint32_t wantedCount;
    NSMutableIndexSet *unassigned; // wanted, with no live placement
    // Open blocks (assigned since last wanted, not complete) and their placements; one whose lane went away stays
    // open with none, as the receiver may hold parts of it (§ 3 counts it).
    NSMutableDictionary<NSNumber *, NSMutableArray<SZFPlacement *> *> *open;
    uint64_t openBytes;
}
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

@interface SZFLane : NSObject {
  @public
    uint8_t index;
    SZFriendsRouteMethod route;
    NSMutableArray<NSArray<NSNumber *> *> *rates, *rtts; // (time, value)
    double rate, rtt;
    BOOL measured;
    uint64_t inFlight, delivered;
    double deliveredAt, progressAt, heardAt;
    BOOL silent, closing, unused;
    // Placements in the order they were assigned: seq -> (transfer, block).
    NSMutableDictionary<NSNumber *, NSArray<NSNumber *> *> *holds;
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

@implementation SZFriendsScheduler {
    BOOL _phone, _keepsInternet;
    NSMutableDictionary<NSNumber *, SZFLane *> *_lanes;
    NSMutableArray<SZFTransfer *> *_transfers; // in the order they were added: earlier transfers' blocks go first
    NSMutableArray<SZFriendsScheduleAction *> *_actions;
    NSMutableDictionary<NSNumber *, NSNumber *> *_requested;
    uint64_t _seq;
}

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

#pragma mark - The decisions

- (uint64_t)cap:(SZFLane *)lane blockBytes:(uint64_t)blockBytes {
    uint64_t max = _phone ? SZFLaneBytesMaxPhone : SZFLaneBytesMax;
    uint64_t bdp2 = (uint64_t)(2.0 * lane->rate * lane->rtt);
    // A lane beside a faster one that needs longer than a second per block (Bluetooth beside a slow LAN) holds one: a
    // second one queued behind it would push its expected finish past what the faster lanes need for the rest.
    BOOL faster = NO;
    for (SZFLane *other in _lanes.allValues) faster |= other.working && other->rate > lane->rate * 2.0;
    BOOL slow = faster && (double)blockBytes / MAX(lane->rate, 1.0) > SZFSlowBlockSeconds;
    return MIN(MAX(bdp2, (slow ? 1 : 2) * blockBytes), max);
}

- (BOOL)room:(SZFLane *)lane bytes:(uint64_t)bytes blockBytes:(uint64_t)blockBytes {
    return lane->inFlight == 0 || lane->inFlight + bytes <= [self cap:lane blockBytes:blockBytes];
}

- (uint64_t)unassignedBytes {
    uint64_t total = 0;
    // Every unit is whole but the file's last: counted, not walked (slices make thousands of them).
    for (SZFTransfer *transfer in _transfers) {
        NSUInteger count = transfer->unassigned.count;
        if (count == 0) continue;
        uint64_t unit = 1ull << transfer->geometry.shift;
        uint32_t last = transfer->geometry.blocks - 1;
        total += count * unit;
        if ([transfer->unassigned containsIndex:last]) total -= unit - [transfer bytes:last];
    }
    return total;
}

// Lanes that may take blocks now: working ones; the relay only when nothing else works; Bluetooth only alone or while
// the others measure below 4 MB/s together.
- (NSArray<NSNumber *> *)eligible {
    NSMutableArray<NSNumber *> *working = [NSMutableArray array], *direct = [NSMutableArray array];
    for (NSNumber *laneID in self.laneIDs) {
        SZFLane *lane = _lanes[laneID];
        if (!lane.working) continue;
        [working addObject:laneID];
        if (lane->route != SZFriendsRouteMethodRelay) [direct addObject:laneID];
    }
    NSArray<NSNumber *> *lanes = direct.count ? direct : working;
    double others = 0;
    BOOL onlyBluetooth = YES;
    for (NSNumber *laneID in lanes) {
        SZFLane *lane = _lanes[laneID];
        if (lane->route != SZFriendsRouteMethodBluetooth) {
            others += lane->rate;
            onlyBluetooth = NO;
        }
    }
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    for (NSNumber *laneID in lanes) {
        SZFLane *lane = _lanes[laneID];
        if (lane->route != SZFriendsRouteMethodBluetooth || onlyBluetooth || others < SZFriendsBluetoothHelpsBelow) {
            [out addObject:laneID];
        }
    }
    return out;
}

// When `lanes` would finish `bytes` more between them, beyond what each holds (seconds from now).
- (double)finishTime:(NSArray<NSNumber *> *)lanes bytes:(uint64_t)bytes {
    if (lanes.count == 0) return INFINITY;
    NSMutableArray<NSArray<NSNumber *> *> *starts = [NSMutableArray array];
    for (NSNumber *laneID in lanes) {
        SZFLane *lane = _lanes[laneID];
        [starts addObject:@[ @((double)lane->inFlight / lane->rate + lane->rtt), @(lane->rate) ]];
    }
    [starts sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [a[0] compare:b[0]];
    }];
    double left = (double)bytes, slope = 0, time = [starts[0][0] doubleValue];
    for (NSUInteger i = 0; i < starts.count; i++) {
        double start = [starts[i][0] doubleValue], rate = [starts[i][1] doubleValue];
        if (slope > 0 && left <= slope * (start - time)) return time + left / slope;
        left -= slope * (start - time);
        time = start;
        slope += rate;
        if (i == starts.count - 1) return time + left / slope;
    }
    return INFINITY;
}

// The lane for a block of `bytes`, if one should take it now.
- (nullable NSNumber *)pick:(NSArray<NSNumber *> *)eligible bytes:(uint64_t)bytes blockBytes:(uint64_t)blockBytes
                 unassigned:(uint64_t)unassigned {
    NSNumber *best = nil, *candidate = nil;
    double bestETA = 0, candidateETA = 0;
    for (NSNumber *laneID in eligible) {
        SZFLane *lane = _lanes[laneID];
        double eta = [lane eta:bytes];
        if (best == nil || eta < bestETA) best = laneID, bestETA = eta;
        if ([self room:lane bytes:bytes blockBytes:blockBytes] && (candidate == nil || eta < candidateETA)) {
            candidate = laneID, candidateETA = eta;
        }
    }
    if (best == nil || candidate == nil) return nil;
    if ([candidate isEqual:best]) return candidate;
    NSMutableArray *others = [eligible mutableCopy];
    [others removeObject:candidate];
    return candidateETA <= [self finishTime:others bytes:unassigned] ? candidate : nil;
}

// The next block to place: open blocks that lost their lane first, then the lowest unassigned one of the first
// transfer within § 3's limits.
- (nullable SZFTransfer *)nextBlock:(uint32_t *)blockOut {
    for (SZFTransfer *transfer in _transfers) {
        // The lowest open block with no live placement: through the open ones (64 at most), not every unassigned.
        NSUInteger found = NSNotFound;
        for (NSNumber *open in transfer->open) {
            NSUInteger block = open.unsignedIntegerValue;
            if (block < found && [transfer->unassigned containsIndex:block]) found = block;
        }
        if (found != NSNotFound) {
            *blockOut = (uint32_t)found;
            return transfer;
        }
    }
    for (SZFTransfer *transfer in _transfers) {
        NSUInteger first = transfer->unassigned.firstIndex;
        if (first == NSNotFound) continue;
        if (transfer->open.count < SZFriendsBlocksInFlightMax &&
            transfer->openBytes + [transfer bytes:(uint32_t)first] <= SZFriendsBytesInFlightMax) {
            *blockOut = (uint32_t)first;
            return transfer;
        }
    }
    return nil;
}

- (void)fill:(double)now {
    NSArray<NSNumber *> *eligible = self.eligible;
    uint64_t unassigned = [self unassignedBytes];
    uint32_t block = 0;
    SZFTransfer *transfer = nil;
    while ((transfer = [self nextBlock:&block]) != nil) {
        uint64_t bytes = [transfer bytes:block];
        NSNumber *lane = [self pick:eligible bytes:bytes blockBytes:1ull << transfer->geometry.shift
                         unassigned:unassigned];
        if (lane == nil) break;
        [self assign:transfer block:block lane:lane.unsignedLongLongValue now:now];
        unassigned -= bytes;
    }
    BOOL allAssigned = YES;
    for (SZFTransfer *t in _transfers) allAssigned &= t->unassigned.count == 0;
    if (allAssigned) [self endgame:eligible now:now];
    [self askForLanes:eligible now:now];
}

- (void)assign:(SZFTransfer *)transfer block:(uint32_t)block lane:(SZFriendsLaneID)laneID now:(double)now {
    uint64_t bytes = [transfer bytes:block];
    _seq++;
    SZFLane *lane = _lanes[@(laneID)];
    if (lane->inFlight == 0) {
        // From idle, measure from now, not from the last delivery.
        lane->deliveredAt = now;
        lane->progressAt = now;
    }
    SZFPlacement *placement = [[SZFPlacement alloc] init];
    placement->lane = laneID;
    placement->seq = _seq;
    placement->bytes = bytes;
    placement->delivered = lane->delivered;
    placement->deliveredAt = lane->deliveredAt;
    lane->inFlight += bytes;
    lane->holds[@(_seq)] = @[ @(transfer->key), @(block) ];
    if (transfer->open[@(block)] == nil) {
        transfer->openBytes += bytes;
        transfer->open[@(block)] = [NSMutableArray array];
    }
    [transfer->open[@(block)] addObject:placement];
    [transfer->unassigned removeIndex:block];
    [self act:SZFriendsScheduleSend lane:laneID transfer:transfer->key block:block];
}

// When the copy `p` should complete, as its lane stands now.
- (double)expected:(SZFPlacement *)p now:(double)now {
    SZFLane *lane = _lanes[@(p->lane)];
    if (p->hasSent) return MAX(p->sentAt + lane->rtt, now);
    uint64_t ahead = 0;
    for (NSNumber *seq in lane.holdSeqs) {
        if (seq.unsignedLongLongValue > p->seq) break;
        NSArray<NSNumber *> *hold = lane->holds[seq];
        SZFTransfer *transfer = [self transfer:hold[0].unsignedLongLongValue];
        if (transfer == nil) continue;
        for (SZFPlacement *q in transfer->open[hold[1]]) {
            if (q->seq == seq.unsignedLongLongValue && !q->hasSent) ahead += q->bytes;
        }
    }
    return now + (double)ahead / lane->rate + lane->rtt;
}

// Nothing unassigned: lanes with room take second copies of the blocks that would otherwise finish last.
- (void)endgame:(NSArray<NSNumber *> *)eligible now:(double)now {
    BOOL onlyBluetooth = YES;
    for (NSNumber *laneID in eligible) onlyBluetooth &= _lanes[laneID]->route == SZFriendsRouteMethodBluetooth;
    NSMutableArray<NSNumber *> *helpers = [NSMutableArray array];
    for (NSNumber *laneID in eligible) {
        if (onlyBluetooth || _lanes[laneID]->route != SZFriendsRouteMethodBluetooth) [helpers addObject:laneID];
    }
    while (YES) {
        double bestGain = 0;
        SZFTransfer *bestTransfer = nil;
        uint32_t bestBlock = 0;
        NSNumber *bestLane = nil;
        for (SZFTransfer *transfer in _transfers) {
            for (NSNumber *block in [transfer->open.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                SZFPlacement *live = nil;
                NSUInteger liveCount = 0;
                for (SZFPlacement *p in transfer->open[block]) {
                    if (_lanes[@(p->lane)].working) live = p, liveCount++;
                }
                if (liveCount != 1) continue;
                double finish = [self expected:live now:now];
                uint64_t bytes = [transfer bytes:block.unsignedIntValue];
                for (NSNumber *laneID in helpers) {
                    SZFLane *lane = _lanes[laneID];
                    if (laneID.unsignedLongLongValue == live->lane ||
                        ![self room:lane bytes:bytes blockBytes:1ull << transfer->geometry.shift]) {
                        continue;
                    }
                    double gain = finish - (now + [lane eta:bytes]);
                    if (gain > MAX(lane->rtt, 0.005) && (bestLane == nil || gain > bestGain)) {
                        bestGain = gain, bestTransfer = transfer, bestBlock = block.unsignedIntValue, bestLane = laneID;
                    }
                }
            }
        }
        if (bestLane == nil) return;
        [self assign:bestTransfer block:bestBlock lane:bestLane.unsignedLongLongValue now:now];
    }
}

- (void)request:(SZFriendsRouteMethod)route now:(double)now {
    NSNumber *last = _requested[@(route)];
    if (last == nil || now - last.doubleValue >= SZFRequestAgainAfter) {
        _requested[@(route)] = @(now);
        [_actions addObject:[SZFriendsScheduleAction kind:SZFriendsScheduleOpenLane lane:0 transfer:0 block:0
                                                    route:route]];
    }
}

// Bluetooth beside slow lanes; direct Wi-Fi beside a LAN below 25 MB/s, where it keeps the device online.
- (void)askForLanes:(NSArray<NSNumber *> *)eligible now:(double)now {
    uint64_t left = [self unassignedBytes];
    if (left == 0) return;
    double direct = 0, lan = 0;
    for (NSNumber *laneID in eligible) {
        SZFLane *lane = _lanes[laneID];
        if (lane->route != SZFriendsRouteMethodBluetooth && lane->route != SZFriendsRouteMethodRelay) {
            direct += lane->rate;
        }
        if (lane->route == SZFriendsRouteMethodLAN) lan += lane->rate;
    }
    BOOL hasBluetooth = NO, hasDirectWiFi = NO;
    for (SZFLane *lane in _lanes.allValues) {
        hasBluetooth |= lane->route == SZFriendsRouteMethodBluetooth;
        hasDirectWiFi |= lane->route == SZFriendsRouteMethodPeerToPeerWiFi;
    }
    BOOL worth = (double)left > SZFWorthALane * direct;
    if (!hasBluetooth && direct < SZFriendsBluetoothHelpsBelow && worth) {
        [self request:SZFriendsRouteMethodBluetooth now:now];
    }
    if (_keepsInternet && !hasDirectWiFi && lan < SZFriendsDirectWiFiHelpsBelow && worth) {
        [self request:SZFriendsRouteMethodPeerToPeerWiFi now:now];
    }
}

#pragma mark - Lane state

// `block` has no live placement any more: it goes back to the unassigned (it stays open).
- (void)releaseIfUnplaced:(SZFTransfer *)transfer block:(uint32_t)block {
    if (![transfer isWanted:block]) return;
    BOOL live = NO;
    for (SZFPlacement *p in transfer->open[@(block)]) live |= _lanes[@(p->lane)].working;
    if (!live) [transfer->unassigned addIndex:block];
}

- (void)goSilent:(SZFriendsLaneID)laneID {
    SZFLane *lane = _lanes[@(laneID)];
    lane->silent = YES;
    for (NSNumber *seq in lane.holdSeqs) {
        NSArray<NSNumber *> *hold = lane->holds[seq];
        SZFTransfer *transfer = [self transfer:hold[0].unsignedLongLongValue];
        if (transfer) [self releaseIfUnplaced:transfer block:hold[1].unsignedIntValue];
    }
}

- (void)recover:(SZFriendsLaneID)laneID {
    SZFLane *lane = _lanes[@(laneID)];
    lane->silent = NO;
    for (NSNumber *seq in lane.holdSeqs) {
        NSArray<NSNumber *> *hold = lane->holds[seq];
        SZFTransfer *transfer = [self transfer:hold[0].unsignedLongLongValue];
        if (transfer) [transfer->unassigned removeIndex:hold[1].unsignedIntValue];
    }
}

@end
