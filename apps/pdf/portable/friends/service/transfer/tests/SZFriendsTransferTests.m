// The transfer area's suite: the scheduler's scenario table (friends/fixtures/scheduler/scenarios.json, ADR 0018 § 7,
// the same expectations the Rust scheduler meets) through the simulator, and the lane group's rules.
//
// Usage: SZFriendsTransferTests <scenarios.json>

#import <Foundation/Foundation.h>

#import "SZFriendsSchedulerSim.h"

static int failures = 0;
#define CHECK(condition, ...)                                                                                         \
    do {                                                                                                              \
        if (!(condition)) {                                                                                           \
            failures++;                                                                                               \
            fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, [NSString stringWithFormat:__VA_ARGS__].UTF8String); \
        }                                                                                                             \
    } while (0)

static void TestScenarios(NSString *path) {
    NSDictionary *table = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0
                                                            error:NULL];
    CHECK([table[@"scenarios"] count] > 0, @"the scenario table at %@", path);
    printf("| Scenario | Lanes (Mbit/s) | Time | MB/s | Of the lanes' sum | Per route (MiB sent) | Sent twice | "
           "Fastest lane idle at the end |\n|---|---|---|---|---|---|---|---|\n");
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
        printf("| %s | %s | %.2f s | %.1f | %.0f %% | %s | %.1f MiB | %.0f ms |\n", name.UTF8String,
               [lanes componentsJoinedByString:@", "].UTF8String, out.doneAt, mbit / 8, 100 * mbit / sum,
               [perRoute componentsJoinedByString:@", "].UTF8String, (double)out.wastedBytes / (1 << 20), tail * 1000);
        CHECK(wall < 10, @"%@: the simulator took %.1f s", name, wall);
        CHECK(out.maxOpenBlocks <= 64 && out.maxOpenBytes <= (64ull << 20) && !out.laneCapExceeded,
              @"%@: § 3 or a lane's cap exceeded", name);
        NSDictionary *expect = entry[@"expect"];
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

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: %s <scenarios.json>\n", argv[0]);
            return 2;
        }
        TestLaneGroup();
        TestScenarios(@(argv[1]));
        if (failures) {
            fprintf(stderr, "SZFriendsTransferTests: %d check(s) failed\n", failures);
            return 1;
        }
        printf("SZFriendsTransferTests passed\n");
    }
    return 0;
}
