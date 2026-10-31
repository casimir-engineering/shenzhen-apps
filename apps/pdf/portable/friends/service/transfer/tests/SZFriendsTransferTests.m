// The transfer area's suite: the scheduler's scenario table (friends/fixtures/scheduler/scenarios.json, ADR 0018 § 7,
// the same expectations the Rust scheduler meets) through the simulator, and the lane group's rules.
//
// Usage: SZFriendsTransferTests <scenarios.json>

#import <Foundation/Foundation.h>

#import "SZFriendsSchedulerSim.h"
#import "service/transfer/SZFriendsPull.h"

static int failures = 0;
int SZFriendsDirectWiFiBoostTests(void); // SZFriendsDirectWiFiBoostTests.m
#define CHECK(condition, ...)                                                                                         \
    do {                                                                                                              \
        if (!(condition)) {                                                                                           \
            failures++;                                                                                               \
            fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, [NSString stringWithFormat:__VA_ARGS__].UTF8String); \
        }                                                                                                             \
    } while (0)

// The best any one of the scenario's lanes does alone, up from the start with everything else it does (silences,
// flapping, a cut): what "never slower than without the extra lanes" compares with. Negative when none finishes.
// The relay counts only when no lane is direct: ADR 0020 keeps it unused beside a direct one.
static double BestAlone(SZFSimScenario *scenario) {
    double best = -1;
    BOOL anyDirect = NO;
    for (SZFSimLaneProfile *lane in scenario.lanes) anyDirect |= lane.route != SZFriendsRouteMethodRelay;
    for (SZFSimLaneProfile *lane in scenario.lanes) {
        if (anyDirect && lane.route == SZFriendsRouteMethodRelay) continue;
        double done = SZFSimRun([scenario copyWithLanes:@[ [lane copyUpFromStart] ]]).doneAt;
        if (done >= 0 && (best < 0 || done < best)) best = done;
    }
    return best;
}

static void TestScenarios(NSString *path) {
    NSDictionary *table = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0
                                                            error:NULL];
    CHECK([table[@"scenarios"] count] > 0, @"the scenario table at %@", path);
    printf("| Scenario | Lanes (Mbit/s) | Time | MB/s | Of the lanes' sum | Of the best lane alone | Per route (MiB sent) | "
           "Sent twice | Fastest lane idle at the end |\n|---|---|---|---|---|---|---|---|---|\n");
    for (NSDictionary *entry in table[@"scenarios"]) {
        SZFSimScenario *scenario = [SZFSimScenario scenarioWithJSON:entry];
        CHECK(scenario != nil, @"a scenario: %@", entry);
        if (scenario == nil) continue;
        NSDate *started = [NSDate date];
        SZFSimOutcome *out = SZFSimRun(scenario);
        NSTimeInterval wall = -started.timeIntervalSinceNow;
        NSString *name = scenario.name;
        CHECK(out.doneAt >= 0, @"%@: did not finish", name);
        if (out.doneAt < 0) continue;
        double mbit = (double)scenario.size * 8.0 / out.doneAt / 1e6, sum = 0;
        NSMutableArray *lanes = [NSMutableArray array], *perRoute = [NSMutableArray array];
        for (NSUInteger i = 0; i < scenario.lanes.count; i++) {
            SZFSimLaneProfile *lane = scenario.lanes[i];
            sum += lane.rate * 8 / 1e6;
            [lanes addObject:[NSString stringWithFormat:@"%@ %g", SZFSimRouteName(lane.route), lane.rate * 8 / 1e6]];
            [perRoute addObject:[NSString stringWithFormat:@"%@ %.1f", SZFSimRouteName(lane.route),
                                                           [out.laneSentBytes[i] doubleValue] / (1 << 20)]];
        }
        double tail = [out tailFor:scenario];
        NSDictionary *expect = entry[@"expect"];
        // Time alone over time with every lane: 1.000 or more is never slower.
        double alone = expect[@"max_of_alone"] ? BestAlone(scenario) : -1, speed = alone / out.doneAt;
        NSString *ofAlone = alone >= 0 ? [NSString stringWithFormat:@"%.3f", speed] : @"—";
        printf("| %s | %s | %.2f s | %.1f | %.0f %% | %s | %s | %.1f MiB | %.0f ms |\n", name.UTF8String,
               [lanes componentsJoinedByString:@", "].UTF8String, out.doneAt, mbit / 8, 100 * mbit / sum,
               ofAlone.UTF8String, [perRoute componentsJoinedByString:@", "].UTF8String,
               (double)out.wastedBytes / (1 << 20), tail * 1000);
        CHECK(wall < 10, @"%@: the simulator took %.1f s", name, wall);
        CHECK(out.maxOpenBlocks <= 64 && out.maxOpenBytes <= (64ull << 20) && !out.laneCapExceeded,
              @"%@: § 3 or a lane's cap exceeded", name);
        if (alone >= 0) {
            CHECK(1 / speed <= [expect[@"max_of_alone"] doubleValue],
                  @"%@: %.3f of the best lane alone's speed, at least %.3f", name, speed,
                  1 / [expect[@"max_of_alone"] doubleValue]);
        }
        if (expect[@"mbit"]) CHECK(mbit >= [expect[@"mbit"] doubleValue], @"%@: %.1f Mbit/s, expected at least %@", name, mbit, expect[@"mbit"]);
        if (expect[@"max_s"]) CHECK(out.doneAt <= [expect[@"max_s"] doubleValue], @"%@: %.2f s, at most %@", name, out.doneAt, expect[@"max_s"]);
        if (expect[@"max_tail_ms"]) CHECK(tail * 1000 <= [expect[@"max_tail_ms"] doubleValue], @"%@: idle %.0f ms at the end", name, tail * 1000);
        if (expect[@"max_wasted_mib"]) CHECK((double)out.wastedBytes <= [expect[@"max_wasted_mib"] doubleValue] * (1 << 20), @"%@: %llu bytes sent twice", name, out.wastedBytes);
        for (NSString *route in expect[@"idle"]) {
            for (NSUInteger i = 0; i < scenario.lanes.count; i++) {
                if ([SZFSimRouteName(scenario.lanes[i].route) isEqualToString:route]) {
                    CHECK([out.laneSentBytes[i] unsignedLongLongValue] == 0, @"%@: %@ carried bytes", name, route);
                }
            }
        }
        for (NSString *request in expect[@"requests"]) {
            CHECK([out.requests containsObject:request], @"%@: no %@ request (%@)", name, request, out.requests);
        }
        for (NSString *route in expect[@"carried"]) {
            BOOL carried = NO;
            for (NSUInteger i = 0; i < scenario.lanes.count; i++) {
                carried |= [SZFSimRouteName(scenario.lanes[i].route) isEqualToString:route] &&
                           [out.laneSentBytes[i] unsignedLongLongValue] > 0;
            }
            CHECK(carried, @"%@: %@ carried nothing", name, route);
        }
        // The owner's relay rule (ADR 0020): the relay beside a working direct lane, and how soon a lane that came up
        // later (a route that appeared) carried its first part.
        if (expect[@"max_relay_beside_direct_kib"]) {
            CHECK(out.relayBesideDirectBytes <= [expect[@"max_relay_beside_direct_kib"] unsignedLongLongValue] << 10,
                  @"%@: the relay wrote %llu bytes beside a working direct lane", name, out.relayBesideDirectBytes);
        }
        if (expect[@"max_first_part_ms"]) {
            for (NSUInteger i = 0; i < scenario.lanes.count; i++) {
                SZFSimLaneProfile *profile = scenario.lanes[i];
                double up = [out.laneUpAt[i] doubleValue], first = [out.laneFirstWrite[i] doubleValue];
                if (profile.route == SZFriendsRouteMethodRelay || profile.upAt == 0 || up < 0) continue;
                double waited = first < 0 ? INFINITY : (first - up) * 1000;
                printf("%s: %s up at %.0f ms, its first part %.0f ms later\n", name.UTF8String,
                       SZFSimRouteName(profile.route).UTF8String, up * 1000, waited);
                CHECK(waited <= [expect[@"max_first_part_ms"] doubleValue],
                      @"%@: %@ carried its first part %.0f ms after it came up", name, SZFSimRouteName(profile.route), waited);
            }
        }
    }
}

static void TestLaneGroup(void) {
    NSMutableData *h = [NSMutableData dataWithLength:64];
    memset(h.mutableBytes, 0x5a, 64);
    SZFriendsLaneGroup *dialer = [[SZFriendsLaneGroup alloc] initWithFirst:1 handshakeHash:h initiator:YES
                                                                     route:SZFriendsRouteMethodLAN];
    SZFriendsLaneGroup *listener = [[SZFriendsLaneGroup alloc] initWithFirst:9 handshakeHash:h initiator:NO
                                                                       route:SZFriendsRouteMethodLAN];
    NSData *token = nil;
    uint8_t index = [dialer reserve:2 route:SZFriendsRouteMethodPeerToPeerWiFi token:&token];
    CHECK(index == 1 && [token isEqualToData:SZFriendsLaneToken(h, 1)], @"the dialer opens odd indexes: %u", index);
    uint8_t admitted = 0;
    CHECK([listener admit:10 token:token route:SZFriendsRouteMethodPeerToPeerWiFi index:&admitted] ==
              SZFriendsLaneAdmitted && admitted == 1, @"the other side admits the same index");
    CHECK([listener admit:11 token:token route:SZFriendsRouteMethodLAN index:&admitted] == SZFriendsLaneRefusedInUse,
          @"once");
    CHECK([listener admit:11 token:[NSMutableData dataWithLength:16] route:SZFriendsRouteMethodLAN index:&admitted] ==
              SZFriendsLaneRefusedToken, @"a wrong token");
    CHECK([listener reserve:12 route:SZFriendsRouteMethodLAN token:NULL] == 2, @"the listener opens even indexes");
    CHECK([dialer reserve:3 route:SZFriendsRouteMethodBluetooth token:NULL] != 0 &&
              [dialer reserve:4 route:SZFriendsRouteMethodBluetooth token:NULL] == 0, @"one Bluetooth lane at most");
    for (SZFriendsLaneID lane = 5; lane < 9; lane++) [dialer reserve:lane route:SZFriendsRouteMethodLAN token:NULL];
    CHECK([dialer reserve:20 route:SZFriendsRouteMethodLAN token:NULL] == 0, @"four per route");
    [dialer laneUp:2];
    NSArray<SZFriendsLaneEvent *> *events = [dialer takeEvents];
    CHECK(events.count == 2 && events[0].index == 0 && events[1].up && events[1].lane == 2, @"up events");
    CHECK(![dialer laneDown:2] && [dialer laneDown:1], @"the last live lane's end ends the group");
    SZFriendsLaneGroup *group = [[SZFriendsLaneGroup alloc] initWithFirst:1 handshakeHash:h initiator:YES
                                                                    route:SZFriendsRouteMethodLAN];
    [group reserve:7 route:SZFriendsRouteMethodPeerToPeerWiFi token:NULL];
    [group laneUp:7];
    CHECK(![group laneDown:1] && group.first == 7, @"the group outlives its first session: lane 7 leads it");
}

// Pieces (ADR 0018 § 3), as szfriends-core's frames tests: whole 16 KiB units, the shorter last one, and the blocks
// a WANT's pieces name.
static void TestPieces(void) {
    uint32_t first = 0, count = 0;
    CHECK(SZFriendsWholePieces(0, 16384, 100000, &first, &count) && first == 0 && count == 1, @"one whole piece");
    CHECK(SZFriendsWholePieces(1, 40000, 100000, &first, &count) && first == 1 && count == 1,
          @"a piece counts once every byte of it arrived");
    CHECK(SZFriendsWholePieces(98304, 100000, 100000, &first, &count) && first == 6 && count == 1,
          @"the last piece is shorter");
    CHECK(!SZFriendsWholePieces(10, 20, 100000, &first, &count), @"no whole piece");
    NSData *id_ = [NSMutableData dataWithLength:16];
    uint32_t pieces[] = {4, 2};
    NSArray<SZFriendsFrame *> *want =
        SZFriendsWantFramesWithPieces(id_, [NSData data], [NSData dataWithBytes:pieces length:8]);
    CHECK(want.count == 1 && [want[0] dataForTag:SZFriendsFieldRanges] == nil &&
              [want[0] dataForTag:SZFriendsFieldPieces] != nil,
          @"a WANT with pieces only");
    CHECK(SZFriendsWantFramesWithPieces(id_, [NSData data], [NSData data]).count == 0, @"nothing missing, no WANT");

    SZFriendsBlockGeometry geometry = {3 * (1u << 20) + 7, 20, 4};
    uint32_t blocks[] = {3, 1}, across[] = {63, 2}, last[] = {192, 1}, past[] = {192, 2};
    NSData *merged = SZFriendsBlocksWithPieces(geometry, [NSData dataWithBytes:blocks length:8],
                                               [NSData dataWithBytes:across length:8]);
    const uint32_t *pairs = merged.bytes;
    CHECK(merged.length == 16 && pairs[0] == 0 && pairs[1] == 2 && pairs[2] == 3 && pairs[3] == 1,
          @"pieces 63 and 64 lie in blocks 0 and 1, beside block 3");
    merged = SZFriendsBlocksWithPieces(geometry, [NSData data], [NSData dataWithBytes:last length:8]);
    CHECK(merged.length == 8 && ((const uint32_t *)merged.bytes)[0] == 3, @"the file's last piece is in its last block");
    CHECK(SZFriendsBlocksWithPieces(geometry, [NSData data], [NSData dataWithBytes:past length:8]) == nil,
          @"a piece past the file");
}

// ADR 0018 § 9.6, as pull.rs's tests: the planner in virtual time, each source serving what it was asked in order at
// its rate after a delay each way (block_bytes / rate per block), pinging every half second.
typedef struct {
    SZFriendsRouteMethod route;
    double rate, delay, lostAt; // bytes/s, seconds, seconds (negative: never)
} SZFTPullSource;

static double SimulatePull(uint64_t size, const SZFTPullSource *sources, int count, uint64_t *served, uint64_t *twice) {
    SZFriendsBlockGeometry geometry;
    SZFriendsGeometryForSize(size, &geometry);
    double now = 0, step = 0.001;
    SZFriendsPull *pull = [[SZFriendsPull alloc] initWithGeometry:geometry missing:SZFriendsRange(0, geometry.blocks)
                                                              now:now];
    for (int i = 0; i < count; i++) [pull sourceUp:(uint64_t)i route:sources[i].route now:now];
    NSMutableIndexSet *have = [NSMutableIndexSet indexSet];
    NSMutableArray<NSMutableArray<NSNumber *> *> *queues = [NSMutableArray array];
    NSMutableArray<NSArray *> *requests = [NSMutableArray array]; // (arrives at, action)
    double busyUntil[8] = {0};
    long serving[8];
    BOOL live[8];
    for (int i = 0; i < count; i++) [queues addObject:[NSMutableArray array]], serving[i] = -1, live[i] = YES, served[i] = 0;
    *twice = 0;
    for (long tick = 0; !pull.done; tick++) {
        if (now > 600) return -1;
        for (SZFriendsPullAction *action in [pull takeActions]) {
            [requests addObject:@[ @(now + sources[action.source].delay), action ]];
        }
        NSMutableArray *later = [NSMutableArray array];
        for (NSArray *request in requests) {
            if ([request[0] doubleValue] > now) {
                [later addObject:request];
                continue;
            }
            SZFriendsPullAction *action = request[1];
            NSMutableArray<NSNumber *> *queue = queues[action.source];
            const uint32_t *pairs = action.ranges.bytes;
            for (NSUInteger p = 0; p < action.ranges.length / 8; p++) {
                for (uint32_t b = pairs[2 * p]; b < pairs[2 * p] + pairs[2 * p + 1]; b++) {
                    if (action.want) [queue addObject:@(b)];
                    else [queue removeObject:@(b)];
                }
            }
        }
        requests = later;
        for (int i = 0; i < count; i++) {
            if (!live[i]) continue;
            if (sources[i].lostAt >= 0 && now >= sources[i].lostAt) {
                live[i] = NO;
                [pull sourceDown:(uint64_t)i now:now];
                continue;
            }
            if (serving[i] >= 0 && now >= busyUntil[i] + sources[i].delay) {
                uint32_t block = (uint32_t)serving[i];
                serving[i] = -1;
                served[i]++;
                [pull heard:(uint64_t)i now:now];
                if ([have containsIndex:block]) {
                    (*twice)++;
                } else {
                    [have addIndex:block];
                    [pull arrived:(uint64_t)i block:block now:now];
                }
            }
            if (serving[i] < 0) {
                if (queues[i].count) {
                    uint32_t block = queues[i].firstObject.unsignedIntValue;
                    [queues[i] removeObjectAtIndex:0];
                    uint64_t offset = 0;
                    NSUInteger length = 0;
                    SZFriendsGeometrySpan(geometry, block, &offset, &length);
                    busyUntil[i] = now + (double)length / sources[i].rate;
                    serving[i] = block;
                }
            } else if (tick % 500 == 0) {
                [pull heard:(uint64_t)i now:now]; // its pings
            }
        }
        [pull tick:now];
        now += step;
    }
    return now;
}

static void TestPulls(void) {
    const double MiB = 1 << 20;
    uint64_t served[8], twice = 0;
    SZFTPullSource three[] = {{SZFriendsRouteMethodLAN, 40e6, 0.002, -1}, {SZFriendsRouteMethodLAN, 20e6, 0.002, -1},
                              {SZFriendsRouteMethodLAN, 10e6, 0.003, -1}};
    double seconds = SimulatePull(256 * MiB, three, 3, served, &twice);
    double together = 256 * MiB / 70e6;
    CHECK(seconds > 0 && seconds < together * 1.15 && served[0] && served[1] && served[2] && twice <= 4,
          @"three holders fill one copy at about their sum: %.2f s against %.2f s, %llu/%llu/%llu, %llu twice",
          seconds, together, served[0], served[1], served[2], twice);
    SZFTPullSource leaving[] = {{SZFriendsRouteMethodLAN, 40e6, 0.002, -1}, {SZFriendsRouteMethodLAN, 40e6, 0.002, 1}};
    seconds = SimulatePull(256 * MiB, leaving, 2, served, &twice);
    CHECK(seconds > 0 && seconds < 256 * MiB / 40e6 && served[0] + served[1] >= 256,
          @"a holder that leaves half-way costs only its share: %.2f s", seconds);
    SZFTPullSource slow[] = {{SZFriendsRouteMethodLAN, 2e6, 0.002, -1}, {SZFriendsRouteMethodBluetooth, 0.17e6, 0.03, -1}};
    seconds = SimulatePull(32 * MiB, slow, 2, served, &twice);
    CHECK(seconds > 0 && seconds <= 32 * MiB / 2e6 + 1, @"a slow holder never holds up the end: %.2f s", seconds);
    NSLog(@"pulls: three holders %.2f s (%.2f at their sum)", SimulatePull(256 * MiB, three, 3, served, &twice),
          together);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: %s <scenarios.json>\n", argv[0]);
            return 2;
        }
        TestLaneGroup();
        TestPieces();
        failures += SZFriendsDirectWiFiBoostTests(); // ADR 0019
        TestPulls();
        TestScenarios(@(argv[1]));
        if (failures) {
            fprintf(stderr, "SZFriendsTransferTests: %d check(s) failed\n", failures);
            return 1;
        }
        printf("SZFriendsTransferTests passed\n");
    }
    return 0;
}
