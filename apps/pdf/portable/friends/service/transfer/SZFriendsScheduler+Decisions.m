// The scheduler's decisions (SZFriendsScheduler.h's rules), line for line the Rust core's transfer/scheduler_decisions.rs:
// a lane's room, where the next block goes, the endgame's second copies, which lanes to ask for, and what a silent
// lane gives back.

#import "service/transfer/SZFriendsSchedulerInternal.h"

NS_ASSUME_NONNULL_BEGIN

@implementation SZFriendsScheduler (Decisions)

#pragma mark - The decisions

- (uint64_t)cap:(SZFLane *)lane blockBytes:(uint64_t)blockBytes {
    uint64_t max = _phone ? SZFLaneBytesMaxPhone : SZFLaneBytesMax;
    double fastest = 0;
    for (SZFLane *other in _lanes.allValues) {
        if (other.working) fastest = MAX(fastest, other->rate);
    }
    if (lane->rate < fastest) max = MIN(max, MAX((uint64_t)(fastest * SZFSlowerLaneSeconds), blockBytes));
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

// Lanes that may take blocks now: working ones; the relay only when no direct lane reaches the peer (ADR 0020);
// Bluetooth only alone or while the others measure below 4 MB/s together; none under 3 % of the fastest.
- (NSArray<NSNumber *> *)eligible:(double)now {
    NSMutableArray<NSNumber *> *working = [NSMutableArray array], *direct = [NSMutableArray array];
    for (NSNumber *laneID in self.laneIDs) {
        SZFLane *lane = _lanes[laneID];
        if (!lane.working) continue;
        [working addObject:laneID];
        if (lane->route != SZFriendsRouteMethodRelay) [direct addObject:laneID];
    }
    NSArray<NSNumber *> *lanes = [self directReaches:now] ? direct : working;
    double others = 0, fastest = 0;
    BOOL onlyBluetooth = YES;
    for (NSNumber *laneID in lanes) {
        SZFLane *lane = _lanes[laneID];
        fastest = MAX(fastest, lane->rate);
        if (lane->route != SZFriendsRouteMethodBluetooth) {
            others += lane->rate;
            onlyBluetooth = NO;
        }
    }
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    for (NSNumber *laneID in lanes) {
        SZFLane *lane = _lanes[laneID];
        BOOL bluetoothOK =
            lane->route != SZFriendsRouteMethodBluetooth || onlyBluetooth || others < SZFriendsBluetoothHelpsBelow;
        if (bluetoothOK && lane->rate >= fastest * SZFHelpsFromShare) [out addObject:laneID];
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
    [self relayStepsAside:now];
    NSArray<NSNumber *> *eligible = [self eligible:now];
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

// Nothing unassigned: lanes with room take second copies of the blocks that would otherwise finish last. The fastest
// lane takes them whatever it expects to gain: it has nothing else to do, and a lane that went quiet with a block all
// written (in its socket's buffer, as far as this side can tell) looks on time until its silence is noticed, seconds
// later. So the transfer ends no later than on the fastest lane alone.
- (void)endgame:(NSArray<NSNumber *> *)eligible now:(double)now {
    NSNumber *fastest = nil;
    for (NSNumber *laneID in eligible) {
        if (fastest == nil || _lanes[laneID]->rate > _lanes[fastest]->rate) fastest = laneID;
    }
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
                    BOOL worth = gain > MAX(lane->rtt, 0.005) || [laneID isEqual:fastest];
                    if (worth && (bestLane == nil || gain > bestGain)) {
                        bestGain = gain, bestTransfer = transfer, bestBlock = block.unsignedIntValue, bestLane = laneID;
                    }
                }
            }
        }
        if (bestLane == nil) return;
        [self assign:bestTransfer block:bestBlock lane:bestLane.unsignedLongLongValue now:now];
    }
}

// A lane other than the relay reaches the peer (ADR 0020).
- (BOOL)directReaches:(double)now {
    for (SZFLane *lane in _lanes.allValues) {
        if (lane->route != SZFriendsRouteMethodRelay && [lane reaches:now]) return YES;
    }
    return NO;
}

// The relay carries the transfer: it works and no direct lane reaches the peer (ADR 0020).
- (BOOL)relayed:(double)now {
    BOOL relay = NO;
    for (SZFLane *lane in _lanes.allValues) relay |= lane->route == SZFriendsRouteMethodRelay && lane.working;
    return relay && ![self directReaches:now];
}

- (void)request:(SZFriendsRouteMethod)route now:(double)now {
    NSNumber *last = _requested[@(route)];
    double again = [self relayed:now] ? SZFRequestWhileRelayed : SZFRequestAgainAfter;
    if (last == nil || now - last.doubleValue >= again) {
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

// The owner's relay rule (ADR 0020): while a direct lane works, the relay carries nothing. What it holds goes back at
// once to be sent on the direct lanes (its parts not yet written are dropped); it keeps its session, for when every
// direct lane is gone again.
- (void)relayStepsAside:(double)now {
    if (![self directReaches:now]) return;
    for (NSNumber *laneID in self.laneIDs) {
        SZFLane *lane = _lanes[laneID];
        if (lane->route != SZFriendsRouteMethodRelay || lane->holds.count == 0) continue;
        NSArray<NSNumber *> *seqs = lane.holdSeqs;
        NSDictionary<NSNumber *, NSArray<NSNumber *> *> *holds = lane->holds;
        lane->holds = [NSMutableDictionary dictionary];
        lane->inFlight = 0;
        for (NSNumber *seq in seqs) {
            NSArray<NSNumber *> *hold = holds[seq];
            SZFTransfer *transfer = [self transfer:hold[0].unsignedLongLongValue];
            if (transfer) {
                NSMutableArray<SZFPlacement *> *placements = transfer->open[hold[1]];
                for (NSInteger i = (NSInteger)placements.count - 1; i >= 0; i--) {
                    if (placements[i]->seq == seq.unsignedLongLongValue) [placements removeObjectAtIndex:i];
                }
            }
            [self act:SZFriendsScheduleCancel lane:laneID.unsignedLongLongValue transfer:hold[0].unsignedLongLongValue
                block:hold[1].unsignedIntValue];
            if (transfer) [self releaseIfUnplaced:transfer block:hold[1].unsignedIntValue];
        }
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

NS_ASSUME_NONNULL_END
