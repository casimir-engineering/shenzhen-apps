// A lane that degrades while it carries a file (ADR 0018 § 7.2): the Rust core's transfer/scheduler_health.rs, ported.
// A network lane under half its 10 s peak for 3 s while it had blocks to move gives its blocks to the others and the
// scheduler tries one alternative (another LAN interface, the Internet, Bluetooth under 4 MB/s); a lossy LAN lane
// (2 % retransmitted) under 70 % of its peak gets a second connection, within the LAN's lane limits. A lane whose
// acknowledgements come too far apart for a 1 s rate is read from its last one before that to now. A spell is acted
// on once, until the lane recovers or has nothing to move for 3 s; a trial whose lane the helper cannot open ends at
// once. A trial lane is kept only when the group then moves 10 % more. Change both together.

#import "service/transfer/SZFriendsScheduler.h"
#import "service/transfer/SZFriendsSchedulerInternal.h"

static const double SZFDegradedBelow = 0.5, SZFLossyBelow = 0.7, SZFLossyRetransmits = 0.02;
static const double SZFDegradedFor = 3, SZFRecent = 1, SZFTrialSettle = 2, SZFTrialJudgedAfter = 7;
static const double SZFTrialHelpsBy = 1.1, SZFTrialGiveUp = 20, SZFTryAgainAfter = 60, SZFBeforeSpan = 3;
static const double SZFKeepAcked = 12;
static const double SZFSampleEvery = 0.02; // dense acknowledgements keep one exact sample per 20 ms
static const double SZFWatchEvery = 0.1;   // lanes looked at no more often than this from acknowledgements

@implementation SZFriendsLaneVerdict
@end

// Bytes per second between the first sample at or after `from` and the last at or before `to`; negative without
// half a second between them.
static double SZFRateOver(NSArray<NSArray<NSNumber *> *> *samples, double from, double to) {
    NSArray<NSNumber *> *first = nil, *last = nil;
    for (NSArray<NSNumber *> *s in samples) {
        if (first == nil && s[0].doubleValue >= from) first = s;
        if (s[0].doubleValue <= to) last = s;
    }
    if (first == nil || last == nil) return -1;
    double span = last[0].doubleValue - first[0].doubleValue;
    if (span < 0.5) return -1;
    return (double)(last[1].unsignedLongLongValue - MIN(first[1].unsignedLongLongValue, last[1].unsignedLongLongValue)) /
           span;
}

// Bytes per second from the last sample at or before `from` (the oldest kept when none is that old) to `now`, with
// `delivered` the lane's total now: a lane whose acknowledgements are too far apart for SZFRateOver. Negative without
// half a second.
static double SZFRateUntilNow(NSArray<NSArray<NSNumber *> *> *samples, double from, double now, uint64_t delivered) {
    NSArray<NSNumber *> *base = samples.firstObject;
    for (NSArray<NSNumber *> *s in samples) {
        if (s[0].doubleValue <= from) base = s;
    }
    if (base == nil || now - base[0].doubleValue < 0.5) return -1;
    return (double)(delivered - MIN(base[1].unsignedLongLongValue, delivered)) / (now - base[0].doubleValue);
}

static void SZFKeep(NSMutableArray<NSArray<NSNumber *> *> *samples, double now, uint64_t delivered) {
    if (samples.count && now - samples.lastObject[0].doubleValue < SZFSampleEvery) return;
    [samples addObject:@[ @(now), @(delivered) ]];
    while (samples.count && now - samples.firstObject[0].doubleValue > SZFKeepAcked) [samples removeObjectAtIndex:0];
}

@implementation SZFriendsScheduler (Health)

- (void)retransmits:(SZFriendsLaneID)laneID share:(double)share now:(double)now {
    SZFLane *lane = _lanes[@(laneID)];
    if (lane) lane->retransmits = MIN(MAX(share, 0), 1);
    [self watchHealth:now];
}

- (double)groupRateOver:(double)span now:(double)now {
    return MAX(SZFRateOver(_groupAcked, now - span, now), 0);
}

- (NSArray<SZFriendsLaneVerdict *> *)takeVerdicts {
    NSArray *out = [_verdicts copy] ?: @[];
    [_verdicts removeAllObjects];
    return out;
}

- (void)noteCPUBound:(SZFriendsLaneID)laneID now:(double)now {
    SZFLane *lane = _lanes[@(laneID)];
    if (lane) lane->cpuBoundAt = now;
}

- (void)noteAcked:(SZFriendsLaneID)laneID bytes:(uint64_t)bytes now:(double)now {
    if (_groupAcked == nil) _groupAcked = [NSMutableArray array];
    _groupDelivered += bytes;
    SZFKeep(_groupAcked, now, _groupDelivered);
    SZFLane *lane = _lanes[@(laneID)];
    if (lane == nil) return;
    if (lane->acked == nil) lane->acked = [NSMutableArray array];
    SZFKeep(lane->acked, now, lane->delivered);
}

- (void)healthLaneUp:(SZFriendsLaneID)laneID route:(SZFriendsRouteMethod)route now:(double)now {
    if (_trialOn && !_trialHasLane && _trialRoute == route) {
        _trialHasLane = YES;
        _trialLane = laneID;
        _trialUpAt = now;
    }
}

- (uint64_t)unitBytes {
    return _transfers.count ? 1ull << _transfers.firstObject->geometry.shift : (1ull << 20);
}

- (void)watchHealthSoon:(double)now {
    if (_healthWatched && now - _healthWatchedAt < SZFWatchEvery) return;
    [self watchHealth:now];
}

- (void)watchHealth:(double)now {
    _healthWatched = YES;
    _healthWatchedAt = now;
    [self judgeTrial:now];
    BOOL waiting = [self unassignedBytes] > 0;
    for (NSNumber *laneID in self.laneIDs) {
        SZFLane *lane = _lanes[laneID];
        if (lane->route == SZFriendsRouteMethodBluetooth || lane->route == SZFriendsRouteMethodRelay ||
            !lane.working || !lane->measured) {
            continue;
        }
        uint64_t cap = [self cap:lane blockBytes:[self unitBytes]];
        BOOL cpu = lane->cpuBoundAt > 0 && now - lane->cpuBoundAt < SZFDegradedFor;
        BOOL offered = waiting && lane->inFlight * 2 >= cap && !cpu;
        if (!offered) {
            // The clocks measure a lane with blocks to move; the spell ends only after a long gap without any.
            lane->lowSince = lane->lossySince = -1;
            if (lane->unofferedSince < 0) lane->unofferedSince = now;
            if (now - lane->unofferedSince >= SZFDegradedFor) lane->healthHandled = NO;
            continue;
        }
        lane->unofferedSince = -1;
        double recent = SZFRateOver(lane->acked, now - SZFRecent, now);
        if (recent < 0) recent = SZFRateUntilNow(lane->acked, now - SZFRecent, now, lane->delivered);
        if (recent < 0) continue; // no reading yet: the clocks run on
        double ratio = recent / MAX(lane->rate, 1.0);
        if (ratio >= SZFLossyBelow) {
            lane->lowSince = lane->lossySince = -1;
            lane->healthHandled = NO;
            continue;
        }
        BOOL lossy = lane->route == SZFriendsRouteMethodLAN && lane->retransmits >= SZFLossyRetransmits;
        if (!lossy) lane->lossySince = -1;
        else if (lane->lossySince < 0) lane->lossySince = now;
        if (ratio >= SZFDegradedBelow) lane->lowSince = -1;
        else if (lane->lowSince < 0) lane->lowSince = now;
        if (lane->healthHandled) continue;
        BOOL degraded = lane->lowSince >= 0 && now - lane->lowSince >= SZFDegradedFor;
        BOOL lossyLong = lane->lossySince >= 0 && now - lane->lossySince >= SZFDegradedFor;
        // A second connection on a lossy LAN only within the LAN's limits; otherwise asked again later.
        BOOL second = lossyLong && [self anotherLANAllowed:now];
        if (!degraded && !second) continue;
        lane->healthHandled = YES;
        if (degraded) [self degrade:laneID.unsignedLongLongValue recent:recent now:now];
        if (second) {
            [self tryRoute:SZFriendsRouteMethodLAN beside:NO lane:0 now:now];
        } else {
            [self tryAlternativeTo:laneID.unsignedLongLongValue route:lane->route now:now];
        }
    }
}

- (void)laneRefused:(SZFriendsRouteMethod)route {
    if (_trialOn && !_trialHasLane && _trialRoute == route) _trialOn = NO;
}

// Its blocks move to the others: its peak is forgotten and what it holds beyond a second of its rate now, not yet
// sent, goes back.
- (void)degrade:(SZFriendsLaneID)laneID recent:(double)recent now:(double)now {
    SZFLane *lane = _lanes[@(laneID)];
    lane->rate = MAX(recent, 1e3);
    SZFSample sample = {now, lane->rate};
    [lane->rates setData:[NSData dataWithBytes:&sample length:sizeof sample]];
    uint64_t keep = (uint64_t)lane->rate;
    for (NSNumber *seq in lane.holdSeqs) {
        NSArray<NSNumber *> *hold = lane->holds[seq];
        SZFTransfer *transfer = [self transfer:hold[0].unsignedLongLongValue];
        NSMutableArray<SZFPlacement *> *placements = transfer->open[hold[1]];
        SZFPlacement *placement = nil;
        for (SZFPlacement *p in placements) {
            if (p->seq == seq.unsignedLongLongValue) placement = p;
        }
        if (placement == nil) continue;
        if (placement->hasSent || keep >= placement->bytes) {
            keep = keep > placement->bytes ? keep - placement->bytes : 0;
            continue;
        }
        [lane->holds removeObjectForKey:seq];
        [placements removeObject:placement];
        lane->inFlight = lane->inFlight > placement->bytes ? lane->inFlight - placement->bytes : 0;
        [self act:SZFriendsScheduleCancel lane:laneID transfer:transfer->key block:hold[1].unsignedIntValue];
        [self releaseIfUnplaced:transfer block:hold[1].unsignedIntValue];
    }
    [self fill:now];
}

- (BOOL)freshRoute:(SZFriendsRouteMethod)route now:(double)now {
    NSNumber *at = _tried[@(route)];
    return at == nil || now - at.doubleValue >= SZFTryAgainAfter;
}

- (NSUInteger)lanesOnRoute:(SZFriendsRouteMethod)route {
    NSUInteger n = 0;
    for (SZFLane *lane in _lanes.allValues) n += lane->route == route && !lane->closing;
    return n;
}

- (BOOL)anotherLANAllowed:(double)now {
    return [self freshRoute:SZFriendsRouteMethodLAN now:now] &&
           [self lanesOnRoute:SZFriendsRouteMethodLAN] < SZFriendsLanesPerRoute;
}

- (void)tryAlternativeTo:(SZFriendsLaneID)laneID route:(SZFriendsRouteMethod)route now:(double)now {
    if (route == SZFriendsRouteMethodLAN && [self anotherLANAllowed:now]) {
        [self tryRoute:SZFriendsRouteMethodLAN beside:YES lane:laneID now:now];
    } else if ([self lanesOnRoute:SZFriendsRouteMethodInternet] == 0 &&
               [self freshRoute:SZFriendsRouteMethodInternet now:now]) {
        [self tryRoute:SZFriendsRouteMethodInternet beside:NO lane:0 now:now];
    } else if ([self lanesOnRoute:SZFriendsRouteMethodBluetooth] == 0 &&
               [self freshRoute:SZFriendsRouteMethodBluetooth now:now] &&
               [self groupRateOver:SZFBeforeSpan now:now] < SZFriendsBluetoothHelpsBelow) {
        [self tryRoute:SZFriendsRouteMethodBluetooth beside:NO lane:0 now:now];
    }
}

- (void)tryRoute:(SZFriendsRouteMethod)route beside:(BOOL)beside lane:(SZFriendsLaneID)laneID now:(double)now {
    if (_trialOn) return;
    if (_tried == nil) _tried = [NSMutableDictionary dictionary];
    _tried[@(route)] = @(now);
    _trialOn = YES;
    _trialHasLane = NO;
    _trialRoute = route;
    _trialAskedAt = now;
    _trialBefore = [self groupRateOver:SZFBeforeSpan now:now];
    [_actions addObject:[SZFriendsScheduleAction kind:beside ? SZFriendsScheduleOpenLaneBeside : SZFriendsScheduleOpenLane
                                                 lane:laneID transfer:0 block:0 route:route]];
}

- (void)judgeTrial:(double)now {
    if (!_trialOn) return;
    if (!_trialHasLane) {
        if (now - _trialAskedAt >= SZFTrialGiveUp) _trialOn = NO;
        return;
    }
    if (_lanes[@(_trialLane)] == nil) {
        _trialOn = NO;
        return;
    }
    if (now - _trialUpAt < SZFTrialJudgedAfter) return;
    _trialOn = NO;
    double with = MAX(SZFRateOver(_groupAcked, _trialUpAt + SZFTrialSettle, now), 0);
    BOOL helps = with >= _trialBefore * SZFTrialHelpsBy;
    SZFriendsLaneVerdict *verdict = [SZFriendsLaneVerdict new];
    verdict.lane = _trialLane;
    verdict.route = _trialRoute;
    verdict.before = _trialBefore;
    verdict.with = with;
    verdict.kept = helps;
    if (_verdicts == nil) _verdicts = [NSMutableArray array];
    [_verdicts addObject:verdict];
    if (!helps) {
        _lanes[@(_trialLane)]->closing = YES;
        [_actions addObject:[SZFriendsScheduleAction kind:SZFriendsScheduleCloseLane lane:_trialLane transfer:0
                                                    block:0 route:SZFriendsRouteMethodNone]];
    }
}

@end
