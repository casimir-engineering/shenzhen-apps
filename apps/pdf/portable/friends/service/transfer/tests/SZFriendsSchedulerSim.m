// The scheduler's simulator (SZFriendsSchedulerSim.h), event for event the Rust core's transfer/sim.rs.

#import "SZFriendsSchedulerSimInternal.h"


NSString *SZFSimRouteName(SZFriendsRouteMethod route) {
    switch (route) {
    case SZFriendsRouteMethodLAN: return @"lan";
    case SZFriendsRouteMethodPeerToPeerWiFi: return @"direct-wifi";
    case SZFriendsRouteMethodInternet: return @"internet";
    case SZFriendsRouteMethodRelay: return @"relay";
    case SZFriendsRouteMethodBluetooth: return @"bluetooth";
    default: return @"none";
    }
}

static SZFriendsRouteMethod SZFRouteNamed(NSString *name) {
    for (SZFriendsRouteMethod route = SZFriendsRouteMethodLAN; route <= SZFriendsRouteMethodRelay; route++) {
        if ([SZFSimRouteName(route) isEqualToString:name]) return route;
    }
    return SZFriendsRouteMethodNone;
}

@implementation SZFSimLaneProfile

+ (instancetype)profileWithJSON:(NSDictionary *)json {
    SZFriendsRouteMethod route = SZFRouteNamed(json[@"route"]);
    if (route == SZFriendsRouteMethodNone || json[@"mbit"] == nil || json[@"rtt_ms"] == nil) return nil;
    SZFSimLaneProfile *lane = [[self alloc] init];
    lane.route = route;
    lane.rate = [json[@"mbit"] doubleValue] * 1e6 / 8.0;
    lane.rtt = [json[@"rtt_ms"] doubleValue] / 1000.0;
    lane.loss = [json[@"loss"] doubleValue];
    lane.partBytes = json[@"part_bytes"] ? [json[@"part_bytes"] unsignedLongLongValue]
                                         : (route == SZFriendsRouteMethodBluetooth ? 16 << 10 : 60 << 10);
    id up = json[@"up_ms"];
    lane.upAt = up == nil ? 0 : (up == [NSNull null] ? -1 : [up doubleValue] / 1000.0);
    lane.dial = json[@"dial_ms"] ? [json[@"dial_ms"] doubleValue] / 1000.0
                                 : (route == SZFriendsRouteMethodBluetooth ? 1.0 : 0.1);
    lane.buffer = [json[@"buffer_kib"] unsignedLongLongValue] << 10;
    lane.cutAt = json[@"cut_ms"] ? [json[@"cut_ms"] doubleValue] / 1000.0 : -1;
    lane.detect = json[@"detect_ms"] ? [json[@"detect_ms"] doubleValue] / 1000.0 : 0.4;
    lane.silences = [NSMutableArray array];
    for (NSArray *window in json[@"silences_ms"]) {
        [lane.silences addObject:@[ @([window[0] doubleValue] / 1000.0), @([window[1] doubleValue] / 1000.0) ]];
    }
    NSDictionary *flapping = json[@"flapping_ms"];
    if (flapping) {
        double from = [flapping[@"from"] doubleValue] / 1000, period = [flapping[@"period"] doubleValue] / 1000;
        double off = [flapping[@"off"] doubleValue] / 1000, until = [flapping[@"until"] doubleValue] / 1000;
        for (double t = from; t < until; t += period) [lane.silences addObject:@[ @(t), @(t + off) ]];
    }
    [lane.silences sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [a[0] compare:b[0]];
    }];
    return lane;
}

- (instancetype)copyUpFromStart {
    SZFSimLaneProfile *lane = [[SZFSimLaneProfile alloc] init];
    lane.route = _route, lane.rate = _rate, lane.rtt = _rtt, lane.loss = _loss, lane.partBytes = _partBytes;
    lane.upAt = 0, lane.dial = _dial, lane.cutAt = _cutAt, lane.detect = _detect, lane.buffer = _buffer;
    lane.silences = [_silences mutableCopy];
    return lane;
}

// `d` of transmission starting at `t`, stretched over the silences.
- (double)advance:(double)t by:(double)d {
    for (NSArray<NSNumber *> *window in _silences) {
        double from = window[0].doubleValue, to = window[1].doubleValue;
        if (to <= t) continue;
        if (t >= from) {
            t = to;
            continue;
        }
        if (t + d <= from) return t + d;
        d -= from - t;
        t = to;
    }
    return t + d;
}

@end

@implementation SZFSimScenario
+ (instancetype)scenarioWithJSON:(NSDictionary *)json {
    SZFSimScenario *scenario = [[self alloc] init];
    scenario.name = json[@"name"];
    scenario.size = (uint64_t)([json[@"mib"] doubleValue] * (1 << 20));
    scenario.phone = [json[@"phone"] boolValue];
    scenario.directWiFiKeepsInternet = [json[@"direct_wifi_keeps_internet"] boolValue];
    NSMutableArray *lanes = [NSMutableArray array];
    for (NSDictionary *lane in json[@"lanes"]) {
        SZFSimLaneProfile *profile = [SZFSimLaneProfile profileWithJSON:lane];
        if (profile == nil) return nil;
        [lanes addObject:profile];
    }
    scenario.lanes = lanes;
    scenario.seed = json[@"seed"] ? [json[@"seed"] unsignedLongLongValue] : 1;
    scenario.limit = json[@"limit_s"] ? [json[@"limit_s"] doubleValue] : 3600;
    uint64_t unit = [json[@"unit_kib"] unsignedLongLongValue] << 10;
    scenario.unitShift = unit ? (uint8_t)__builtin_ctzll(unit) : 0;
    return scenario.name && scenario.lanes.count ? scenario : nil;
}

- (instancetype)copyWithLanes:(NSArray<SZFSimLaneProfile *> *)lanes {
    SZFSimScenario *scenario = [[SZFSimScenario alloc] init];
    scenario.name = _name, scenario.size = _size, scenario.phone = _phone;
    scenario.directWiFiKeepsInternet = _directWiFiKeepsInternet, scenario.lanes = lanes, scenario.seed = _seed;
    scenario.limit = _limit, scenario.unitShift = _unitShift;
    return scenario;
}
@end

@implementation SZFSimOutcome
- (double)tailFor:(SZFSimScenario *)scenario {
    if (_doneAt < 0) return INFINITY;
    double fastest = -1, last = 0;
    for (NSUInteger i = 0; i < scenario.lanes.count; i++) {
        if (![_laneUp[i] boolValue] || [_laneSentBytes[i] unsignedLongLongValue] == 0) continue;
        // max_by: the last of equal rates
        if (scenario.lanes[i].rate >= fastest) fastest = scenario.lanes[i].rate, last = [_laneLastWrite[i] doubleValue];
    }
    return fastest < 0 ? 0 : MAX(_doneAt - last, 0);
}
@end

@implementation SZFSimLane
- (NSUInteger)queued {
    return queue.length / sizeof(SZFPart) - head;
}
@end


@implementation SZFSim

- (void)dealloc {
    free(_heap);
}

#pragma mark Events

static BOOL SZFBefore(const SZFEvent *a, const SZFEvent *b) {
    return a->t < b->t || (a->t == b->t && a->seq < b->seq);
}

- (void)at:(double)t event:(SZFEvent)event {
    event.t = t;
    event.seq = ++_seq;
    if (_count == _capacity) {
        _capacity = _capacity ? _capacity * 2 : 1024;
        _heap = realloc(_heap, _capacity * sizeof(SZFEvent));
    }
    NSUInteger i = _count++;
    _heap[i] = event;
    while (i > 0 && SZFBefore(&_heap[i], &_heap[(i - 1) / 2])) {
        SZFEvent swap = _heap[i];
        _heap[i] = _heap[(i - 1) / 2];
        _heap[(i - 1) / 2] = swap;
        i = (i - 1) / 2;
    }
}

- (BOOL)pop:(SZFEvent *)out {
    if (_count == 0) return NO;
    *out = _heap[0];
    _heap[0] = _heap[--_count];
    NSUInteger i = 0;
    while (YES) {
        NSUInteger l = 2 * i + 1, r = l + 1, m = i;
        if (l < _count && SZFBefore(&_heap[l], &_heap[m])) m = l;
        if (r < _count && SZFBefore(&_heap[r], &_heap[m])) m = r;
        if (m == i) break;
        SZFEvent swap = _heap[i];
        _heap[i] = _heap[m];
        _heap[m] = swap;
        i = m;
    }
    return YES;
}

- (double)nextRandom {
    _random += 0x9e3779b97f4a7c15ull;
    uint64_t z = _random;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
    return (double)(z ^ (z >> 31)) / (double)UINT64_MAX;
}

#pragma mark Running

- (void)start {
    _lanes[0]->state = SZFUp;
    [self at:1 event:SZFMake(SZFEvPing, 0)];
    for (NSUInteger i = 1; i < _lanes.count; i++) {
        if (_lanes[i]->profile.upAt >= 0) [self at:_lanes[i]->profile.upAt event:SZFMake(SZFEvUp, (int)i)];
    }
    for (NSUInteger i = 0; i < _lanes.count; i++) {
        if (_lanes[i]->profile.cutAt >= 0) [self at:_lanes[i]->profile.cutAt event:SZFMake(SZFEvCut, (int)i)];
    }
    [self feedGroup];
    [_scheduler addTransfer:SZFKey geometry:_geometry];
    [_scheduler want:SZFKey ranges:SZFriendsRange(0, _geometry.blocks) now:_now];
    [self act];
}

- (void)feedGroup {
    for (SZFriendsLaneEvent *event in [_group takeEvents]) [_scheduler laneEvent:event now:_now];
}

- (void)armTimer {
    double t = [_scheduler nextTimer];
    if (t < 0) return;
    t = MAX(t, _now);
    if (!_timerArmed || t < _timerAt) {
        _timerArmed = YES;
        _timerAt = t;
        [self at:t event:SZFMake(SZFEvTimer, 0)];
    }
}

- (void)checkLimits {
    uint64_t bytes = 0;
    NSUInteger blocks = [_scheduler openBlocks:SZFKey bytes:&bytes];
    _out.maxOpenBlocks = MAX(_out.maxOpenBlocks, blocks);
    _out.maxOpenBytes = MAX(_out.maxOpenBytes, bytes);
}

- (int)laneOf:(SZFriendsLaneID)lane {
    for (NSUInteger i = 0; i < _lanes.count; i++) {
        if (_lanes[i]->lane == lane) return (int)i;
    }
    return -1;
}

- (void)act {
    while (YES) {
        NSArray<SZFriendsScheduleAction *> *actions = [_scheduler takeActions];
        if (actions.count == 0) return;
        [self actOn:actions];
    }
}

- (void)actOn:(NSArray<SZFriendsScheduleAction *> *)actions {
    for (SZFriendsScheduleAction *action in actions) {
        switch (action.kind) {
        case SZFriendsScheduleSend: {
            int i = [self laneOf:action.lane];
            if (i < 0) break;
            uint64_t start = 0;
            NSUInteger length = 0;
            SZFriendsGeometrySpan(_geometry, action.block, &start, &length);
            uint64_t cap = [_scheduler capOfLane:action.lane blockBytes:1ull << _geometry.shift];
            if ([_scheduler inFlightOfLane:action.lane] > MAX(cap, (uint64_t)length)) _out.laneCapExceeded = YES;
            SZFSimLane *lane = _lanes[i];
            if (lane->state != SZFUp) break;
            uint64_t step = lane->profile.partBytes, from = start;
            while (YES) {
                uint64_t to = MIN(from + step, start + length);
                SZFPart part = {action.block, from, to, to == start + length};
                [lane->queue appendBytes:&part length:sizeof part];
                if (to == start + length) break;
                from = to;
            }
            if (!lane->busy || lane->profile.buffer > 0) [self transmit:i];
            break;
        }
        case SZFriendsScheduleCancel: {
            int i = [self laneOf:action.lane];
            if (i < 0) break;
            SZFSimLane *lane = _lanes[i];
            NSMutableData *kept = [NSMutableData data];
            const SZFPart *parts = lane->queue.bytes;
            for (NSUInteger p = lane->head; p < lane->queue.length / sizeof(SZFPart); p++) {
                if (parts[p].block != action.block) [kept appendBytes:&parts[p] length:sizeof(SZFPart)];
            }
            lane->queue = kept;
            lane->head = 0;
            break;
        }
        case SZFriendsScheduleOpenLane: {
            [_out.requests addObject:[@"open " stringByAppendingString:SZFSimRouteName(action.route)]];
            for (NSUInteger i = 0; i < _lanes.count; i++) {
                SZFSimLane *lane = _lanes[i];
                if (lane->profile.route != action.route || lane->profile.upAt >= 0 || lane->state != SZFIdle) continue;
                if ([_group reserve:lane->lane route:action.route token:NULL] != 0) {
                    lane->state = SZFDialing;
                    [self at:_now + lane->profile.dial event:SZFMake(SZFEvUp, (int)i)];
                }
                break;
            }
            break;
        }
        case SZFriendsScheduleCloseLane: {
            [_out.requests addObject:@"close"];
            int i = [self laneOf:action.lane];
            if (i >= 0) {
                [self cut:i];
                [self notice:i];
            }
            break;
        }
        }
    }
}

- (void)transmit:(int)i {
    SZFSimLane *lane = _lanes[i];
    if (lane->profile.buffer > 0) {
        [self transmitBuffered:i];
        return;
    }
    if (lane.queued == 0) {
        lane->busy = NO;
        lane->queue = [NSMutableData data];
        lane->head = 0;
        return;
    }
    SZFPart part = ((const SZFPart *)lane->queue.bytes)[lane->head++];
    double seconds = (double)(part.to - part.from) / lane->profile.rate;
    if (lane->profile.loss > 0 && [self nextRandom] < lane->profile.loss) seconds += lane->profile.rtt;
    double done = [lane->profile advance:_now by:seconds];
    lane->busy = YES;
    lane->current = part;
    SZFEvent event = SZFMake(SZFEvTxDone, i);
    event.epoch = lane->epoch;
    [self at:done event:event];
}

// With a socket buffer: parts go into it while it has room, each a completed write, and cross one by one.
- (void)transmitBuffered:(int)i {
    SZFSimLane *lane = _lanes[i];
    while (lane.queued > 0) {
        SZFPart part = ((const SZFPart *)lane->queue.bytes)[lane->head];
        uint64_t bytes = part.to - part.from;
        if (lane->bufferedBytes > 0 && lane->bufferedBytes + bytes > lane->profile.buffer) break;
        lane->head++;
        lane->bufferedBytes += bytes;
        [lane->buffered appendBytes:&part length:sizeof part];
        [_scheduler written:lane->lane now:_now];
        if (part.last) [_scheduler sent:lane->lane transfer:SZFKey block:part.block now:_now];
    }
    if (lane.queued == 0) {
        lane->queue = [NSMutableData data];
        lane->head = 0;
    }
    if (lane->busy || lane->bufferedHead == lane->buffered.length / sizeof(SZFPart)) return;
    SZFPart part = ((const SZFPart *)lane->buffered.bytes)[lane->bufferedHead];
    double seconds = (double)(part.to - part.from) / lane->profile.rate;
    if (lane->profile.loss > 0 && [self nextRandom] < lane->profile.loss) seconds += lane->profile.rtt;
    double done = [lane->profile advance:_now by:seconds];
    lane->busy = YES;
    lane->current = part;
    SZFEvent event = SZFMake(SZFEvTxDone, i);
    event.epoch = lane->epoch;
    [self at:done event:event];
}

- (void)cut:(int)i {
    SZFSimLane *lane = _lanes[i];
    if (lane->state != SZFUp) return;
    lane->state = SZFGone;
    lane->epoch++;
    lane->queue = [NSMutableData data];
    lane->head = 0;
    lane->busy = NO;
    lane->buffered = [NSMutableData data];
    lane->bufferedHead = 0;
    lane->bufferedBytes = 0;
}

- (void)notice:(int)i {
    [_group laneDown:_lanes[i]->lane];
    [self feedGroup];
    [self act];
}

- (void)sendBack:(int)i block:(uint32_t)block want:(BOOL)want {
    if (_lanes[i]->state != SZFUp) {
        int quickest = -1;
        for (NSUInteger j = 0; j < _lanes.count; j++) {
            if (_lanes[j]->state != SZFUp) continue;
            if (quickest < 0 || _lanes[j]->profile.rtt < _lanes[quickest]->profile.rtt) quickest = (int)j;
        }
        if (quickest < 0) return;
        i = quickest;
    }
    SZFSimLane *lane = _lanes[i];
    double t = [lane->profile advance:_now + 0.0003 by:lane->profile.rtt / 2];
    SZFEvent event = SZFMake(SZFEvBack, i);
    event.epoch = lane->epoch;
    event.block = block;
    event.want = want;
    [self at:t event:event];
}

@end

SZFSimOutcome *SZFSimRun(SZFSimScenario *scenario) {
    SZFSim *sim = [[SZFSim alloc] init];
    SZFriendsGeometryForSize(scenario.size, &sim->_geometry);
    if (scenario.unitShift && scenario.unitShift < sim->_geometry.shift) {
        // Slices: units of 2^unitShift bytes, as SZFriendsSliceSend gives the scheduler.
        sim->_geometry.shift = scenario.unitShift;
        sim->_geometry.blocks = (uint32_t)MAX((scenario.size + (1ull << scenario.unitShift) - 1) >> scenario.unitShift, 1ull);
    }
    sim->_lanes = [NSMutableArray array];
    for (NSUInteger i = 0; i < scenario.lanes.count; i++) {
        SZFSimLane *lane = [[SZFSimLane alloc] init];
        lane->profile = scenario.lanes[i];
        lane->lane = 100 + i;
        lane->queue = [NSMutableData data];
        lane->buffered = [NSMutableData data];
        [sim->_lanes addObject:lane];
    }
    sim->_group = [[SZFriendsLaneGroup alloc] initWithFirst:sim->_lanes[0]->lane
                                              handshakeHash:[NSMutableData dataWithLength:64]
                                                  initiator:YES
                                                      route:scenario.lanes[0].route];
    sim->_scheduler = [[SZFriendsScheduler alloc] initWithPhone:scenario.phone
                                        directWiFiKeepsInternet:scenario.directWiFiKeepsInternet];
    NSUInteger words = (((1ull << sim->_geometry.shift) + SZFGranule - 1) / SZFGranule + 63) / 64;
    sim->_covered = [NSMutableArray array];
    for (uint32_t b = 0; b < sim->_geometry.blocks; b++) [sim->_covered addObject:[NSMutableData dataWithLength:words * 8]];
    sim->_complete = [NSMutableData dataWithLength:sim->_geometry.blocks];
    sim->_answered = [NSMutableSet set];
    sim->_random = scenario.seed;
    SZFSimOutcome *out = [[SZFSimOutcome alloc] init];
    out.doneAt = -1;
    out.laneSentBytes = [NSMutableArray array];
    out.laneLastWrite = [NSMutableArray array];
    out.laneUp = [NSMutableArray array];
    out.requests = [NSMutableArray array];
    for (NSUInteger i = 0; i < scenario.lanes.count; i++) {
        [out.laneSentBytes addObject:@0];
        [out.laneLastWrite addObject:@0];
        [out.laneUp addObject:@NO];
    }
    sim->_out = out;
    [sim start];
    SZFEvent ev;
    while ([sim pop:&ev]) {
        if (ev.t > scenario.limit) break;
        sim->_now = ev.t;
        [sim handle:ev];
        if (out.doneAt >= 0) break;
        [sim checkLimits];
        [sim armTimer];
    }
    for (NSUInteger i = 0; i < scenario.lanes.count; i++) out.laneUp[i] = @(sim->_lanes[i]->state == SZFUp);
    return out;
}
