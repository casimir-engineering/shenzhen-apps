// The technique log (ADR 0011 § Technique log): numbers only, nothing that identifies a peer; a bounded log that
// reads back only what it wrote. And probing always stops when the attempt moves on.

#import "SZFriendsOrderTestSupport.h"

static SZFriendsTechniqueLogEntry *SampleEntry(void) {
    SZFriendsTechniqueLogEntry *entry = [SZFriendsTechniqueLogEntry new];
    entry.purpose = SZFriendsOnlinePurposeFriend;
    entry.role = SZFriendsOnlineRoleOfferer;
    entry.localNATClass = SZFriendsNATClassPerDestination;
    entry.remoteNATClass = SZFriendsNATClassEndpointIndependent;
    entry.techniquesTried = (1u << SZFriendsOnlineTechniqueServerReflexive) | (1u << SZFriendsOnlineTechniqueRelay);
    entry.firstTechnique = SZFriendsOnlineTechniqueRelay;
    entry.finalTechnique = SZFriendsOnlineTechniqueServerReflexive;
    entry.secondsToFirstStream = 5.84;
    entry.relayRequested = entry.relayNeeded = entry.leftRelay = YES;
    entry.directRetries = 3;
    entry.endReason = SZFriendsOnlineEndStreamClosed;
    return entry;
}

static void TestEntries(void) {
    NSDictionary<NSString *, NSNumber *> *plist = [SampleEntry() propertyList];
    NSSet *keys = [NSSet setWithArray:@[
        @"purpose", @"role", @"local_nat", @"remote_nat", @"tried", @"first", @"final", @"seconds_to_first_stream",
        @"relay_requested", @"relay_needed", @"left_relay", @"direct_retries", @"end"
    ]];
    CHECK([[NSSet setWithArray:plist.allKeys] isEqualToSet:keys], "exactly these keys: %@", plist.allKeys);
    for (NSString *key in plist) CHECK([plist[key] isKindOfClass:[NSNumber class]], "%@ is a number", key);
    CHECK([plist[@"seconds_to_first_stream"] doubleValue] == 5.8, "tenths of a second");
    SZFriendsTechniqueLogEntry *back = [SZFriendsTechniqueLogEntry entryWithPropertyList:plist];
    CHECK(back && [[back propertyList] isEqual:plist], "round trip");
    CHECK(back.leftRelay && back.directRetries == 3 && back.localNATClass == SZFriendsNATClassPerDestination);

    NSMutableDictionary *extra = [plist mutableCopy];
    extra[@"address"] = @"192.0.2.7";
    CHECK([SZFriendsTechniqueLogEntry entryWithPropertyList:extra] == nil, "no other key is ever read back");
    NSMutableDictionary *text = [plist mutableCopy];
    text[@"first"] = @"relay";
    CHECK([SZFriendsTechniqueLogEntry entryWithPropertyList:text] == nil);
    NSMutableDictionary *range = [plist mutableCopy];
    range[@"first"] = @(SZFriendsOnlineTechniqueRelay + 1);
    CHECK([SZFriendsTechniqueLogEntry entryWithPropertyList:range] == nil);
    range[@"first"] = @(1.5);
    CHECK([SZFriendsTechniqueLogEntry entryWithPropertyList:range] == nil, "whole numbers only");
    NSMutableDictionary *missing = [plist mutableCopy];
    [missing removeObjectForKey:@"end"];
    CHECK([SZFriendsTechniqueLogEntry entryWithPropertyList:missing] == nil);
    CHECK([SZFriendsTechniqueLogEntry entryWithPropertyList:@[]] == nil);
    CHECK([SZFriendsTechniqueLogEntry new].secondsToFirstStream == -1, "none opened yet");
}

static void TestLog(void) {
    SZFriendsTechniqueLog *log = [[SZFriendsTechniqueLog alloc] initWithCapacity:3];
    for (NSUInteger i = 0; i < 5; i++) {
        SZFriendsTechniqueLogEntry *entry = SampleEntry();
        entry.directRetries = i;
        [log appendEntry:entry];
    }
    CHECK(log.entries.count == 3 && log.entries[0].directRetries == 2 && log.entries[2].directRetries == 4,
          "the newest, oldest first");
    NSData *json = [log JSONData];
    SZFriendsTechniqueLog *read = [[SZFriendsTechniqueLog alloc] initWithJSONData:json capacity:10];
    CHECK(read.entries.count == 3 && [[read JSONData] isEqual:json], "reads back what it wrote");
    CHECK([[SZFriendsTechniqueLog alloc] initWithJSONData:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]
                                                 capacity:3] == nil);
    NSData *mixed = [@"[{\"purpose\":1},5,\"x\"]" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK([[SZFriendsTechniqueLog alloc] initWithJSONData:mixed capacity:3].entries.count == 0, "bad entries skipped");

    // A real attempt's entry: the order never holds the peer's key, ID or addresses, and its JSON is numbers only.
    SZFOrderClock *clock = [SZFOrderClock new];
    SZFriendsOnlineOrder *order = SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    [order descriptionsAppliedWithLocalNATClass:SZFriendsNATClassEndpointIndependent
                                 remoteNATClass:SZFriendsNATClassPerDestination];
    while (order.phase != SZFriendsOnlinePhaseRelay) SZFOrderAdvance(order, clock);
    [order streamOpenedOnConnection:SZFriendsOnlineConnectionRelay route:SZFOrderRoute(SZFriendsOnlineTechniqueRelay)];
    [order close];
    [log appendEntry:order.logEntry];
    NSArray *written = [NSJSONSerialization JSONObjectWithData:[log JSONData] options:0 error:NULL];
    for (NSDictionary *item in written) {
        for (id value in item.allValues) CHECK([value isKindOfClass:[NSNumber class]], "a number: %@", value);
    }
    SZFriendsTechniqueLogEntry *last = log.entries.lastObject;
    CHECK(last.endReason == SZFriendsOnlineEndClosed && last.relayNeeded && last.secondsToFirstStream == 17 &&
          last.remoteNATClass == SZFriendsNATClassPerDestination && last.purpose == SZFriendsOnlinePurposeFriend);
}

// Probing stops whenever the attempt moves on, so the prober (and the helper's one probing run) is never left going.
static void TestProbingStops(void) {
    SZFOrderClock *clock = [SZFOrderClock new];
    SZFriendsOnlineOrder *order = SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    [order descriptionsAppliedWithLocalNATClass:SZFriendsNATClassPerDestination
                                 remoteNATClass:SZFriendsNATClassEndpointIndependent];
    CHECK(SZFOrderAdvance(order, clock) & SZFriendsOnlineOrderActionStartProbing);
    CHECK([order networkChanged] & SZFriendsOnlineOrderActionStopProbing, "a network change stops it");
    [order descriptionsAppliedWithLocalNATClass:SZFriendsNATClassPerDestination
                                 remoteNATClass:SZFriendsNATClassEndpointIndependent];
    CHECK(SZFOrderAdvance(order, clock) & SZFriendsOnlineOrderActionStartProbing, "and the new budget probes again");
    CHECK([order streamOpenedOnConnection:SZFriendsOnlineConnectionDirect
                                    route:SZFOrderRoute(SZFriendsOnlineTechniqueHostIPv6)] ==
          SZFriendsOnlineOrderActionStopProbing, "a direct path stops it");
    CHECK([order probingEndedRefused:NO] == SZFriendsOnlineOrderActionNone, "a late report changes nothing");
    SZFriendsOnlineOrder *other = SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    [other descriptionsAppliedWithLocalNATClass:SZFriendsNATClassEndpointIndependent
                                 remoteNATClass:SZFriendsNATClassPerDestination];
    CHECK(SZFOrderAdvance(other, clock) & SZFriendsOnlineOrderActionStartProbing);
    CHECK([other otherRouteChanged:SZFriendsRouteMethodLAN] == SZFriendsOnlineOrderActionEnd,
          "superseded mid-run: End closes the prober with everything else");
}

void SZFriendsRunTechniqueLogTests(void) {
    TestEntries();
    TestLog();
    TestProbingStops();
}
