// The online order's phases with a scripted clock (ADR 0011 § The direct phase): the plain checks, the hard-NAT
// step, the relay as last resort only, Standby beside another route, the answerer following the offerer.

#import "SZFriendsOrderTestSupport.h"

int SZFOrderFailures = 0;

@implementation SZFOrderClock
- (instancetype)init {
    if ((self = [super init])) _random = 0.5;
    return self;
}
@end

SZFriendsOnlineOrder *SZFOrderMake(SZFriendsOnlineRole role, SZFOrderClock *clock) {
    return [[SZFriendsOnlineOrder alloc] initWithRole:role
        purpose:SZFriendsOnlinePurposeFriend
        clock:^NSTimeInterval {
            return clock.now;
        }
        random:^double {
            return clock.random;
        }];
}

SZFriendsOnlineOrderActions SZFOrderAdvance(SZFriendsOnlineOrder *order, SZFOrderClock *clock) {
    if (isfinite(order.nextDeadline)) clock.now = order.nextDeadline;
    return [order fireDueTimers];
}

SZFriendsOnlineRoute SZFOrderRoute(SZFriendsOnlineTechnique technique) {
    return SZFriendsOnlineRouteMake(technique, NO);
}

static const SZFriendsNATClass Easy = SZFriendsNATClassEndpointIndependent;
static const SZFriendsNATClass Hard = SZFriendsNATClassPerDestination;

// Easy NATs, no direct path: 5 s of plain checks, then the relay; a direct path later replaces it.
static void TestPlainChecksThenRelay(void) {
    SZFOrderClock *clock = [SZFOrderClock new];
    clock.now = 100;
    SZFriendsOnlineOrder *order =
        SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    CHECK(order.phase == SZFriendsOnlinePhaseSignalling && isinf(order.nextDeadline), "no timer before both");
    CHECK([order fireDueTimers] == SZFriendsOnlineOrderActionNone);
    clock.now = 101;
    CHECK([order descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Easy] == SZFriendsOnlineOrderActionNone);
    CHECK(order.phase == SZFriendsOnlinePhasePlainChecks &&
          order.nextDeadline == 101 + SZFriendsOnlinePlainChecksBudget);
    CHECK(SZFriendsOnlinePlainChecksBudget == 5 && SZFriendsOnlineHardNATBudget == 12, "ADR 0011, provisional");
    [order noteTechniqueTried:SZFriendsOnlineTechniqueHostIPv6];
    [order noteTechniqueTried:SZFriendsOnlineTechniqueServerReflexive];
    clock.now = 105.9;
    CHECK([order fireDueTimers] == SZFriendsOnlineOrderActionNone, "nothing before the budget ends");
    CHECK(SZFOrderAdvance(order, clock) == SZFriendsOnlineOrderActionOpenRelay && clock.now == 106);
    CHECK(order.phase == SZFriendsOnlinePhaseRelay && isinf(order.nextDeadline));
    clock.now = 108;
    CHECK([order streamOpenedOnConnection:SZFriendsOnlineConnectionRelay
                                    route:SZFOrderRoute(SZFriendsOnlineTechniqueRelay)] ==
          SZFriendsOnlineOrderActionNone);
    CHECK(order.phase == SZFriendsOnlinePhaseRelayed && order.nextDeadline == 108 + SZFriendsOnlineRelayedRetryGap);
    SZFriendsTechniqueLogEntry *entry = order.logEntry;
    CHECK(entry.relayRequested && entry.relayNeeded && entry.firstTechnique == SZFriendsOnlineTechniqueRelay &&
          entry.secondsToFirstStream == 7 && !entry.leftRelay);
    NSUInteger tried = (1u << SZFriendsOnlineTechniqueHostIPv6) | (1u << SZFriendsOnlineTechniqueServerReflexive) |
                       (1u << SZFriendsOnlineTechniqueRelay);
    CHECK(entry.techniquesTried == tried, "tried %lx", (unsigned long)entry.techniquesTried);

    // The first retry, a second later (ADR 0020): a new direct connection (the first one is closed if it is still
    // checking).
    SZFriendsOnlineOrderActions actions = SZFOrderAdvance(order, clock);
    CHECK(actions == (SZFriendsOnlineOrderActionCloseDirect | SZFriendsOnlineOrderActionOpenDirect) &&
          clock.now == 109);
    clock.now = 109.5;
    [order descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Easy];
    clock.now = 110;
    // It connects: the relay closes, and ADR 0001 resumes the transfer on the direct session.
    actions = [order streamOpenedOnConnection:SZFriendsOnlineConnectionDirect
                                        route:SZFOrderRoute(SZFriendsOnlineTechniqueServerReflexive)];
    CHECK(actions == SZFriendsOnlineOrderActionCloseRelay && order.phase == SZFriendsOnlinePhaseDirect);
    CHECK(isinf(order.nextDeadline), "no retries once direct");
    entry = order.logEntry;
    CHECK(entry.leftRelay && entry.finalTechnique == SZFriendsOnlineTechniqueServerReflexive &&
          entry.directRetries == 1);
    CHECK([order streamClosedOnConnection:SZFriendsOnlineConnectionRelay] == SZFriendsOnlineOrderActionNone,
          "the relay's stream closing is not the carrier's");
    CHECK([order streamClosedOnConnection:SZFriendsOnlineConnectionDirect] == SZFriendsOnlineOrderActionEnd &&
          order.endReason == SZFriendsOnlineEndStreamClosed);
    CHECK([order close] == SZFriendsOnlineOrderActionNone, "idempotent");
}

static void TestDirectWithinPlainChecks(void) {
    SZFOrderClock *clock = [SZFOrderClock new];
    SZFriendsOnlineOrder *order =
        SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    [order descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Easy];
    clock.now = 1.5;
    CHECK([order streamOpenedOnConnection:SZFriendsOnlineConnectionDirect
                                    route:SZFOrderRoute(SZFriendsOnlineTechniqueHostIPv6)] ==
          SZFriendsOnlineOrderActionNone);
    CHECK(order.phase == SZFriendsOnlinePhaseDirect && isinf(order.nextDeadline));
    clock.now = 100;
    CHECK([order fireDueTimers] == SZFriendsOnlineOrderActionNone && !order.logEntry.relayRequested,
          "the relay is never asked for");
    // The TCP path connecting second is a duplicate of the same class: the session race keeps the first.
    CHECK([order streamOpenedOnConnection:SZFriendsOnlineConnectionDirect
                                    route:SZFOrderRoute(SZFriendsOnlineTechniqueTCPSimultaneousOpen)] ==
          SZFriendsOnlineOrderActionNone);
    CHECK(order.logEntry.finalTechnique == SZFriendsOnlineTechniqueHostIPv6 &&
          order.logEntry.secondsToFirstStream == 1.5);
}

// Exactly one hard side: prediction and probing for up to 12 s more, then the relay. Otherwise no probing at all.
static void TestHardNAT(void) {
    SZFOrderClock *clock = [SZFOrderClock new];
    SZFriendsOnlineOrder *order = SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    [order descriptionsAppliedWithLocalNATClass:Hard remoteNATClass:Easy];
    SZFriendsOnlineOrderActions actions = SZFOrderAdvance(order, clock);
    CHECK(actions == (SZFriendsOnlineOrderActionStartPrediction | SZFriendsOnlineOrderActionStartProbing));
    CHECK(order.phase == SZFriendsOnlinePhaseHardNAT && order.nextDeadline == 17, "relay at 17 s with a hard side");
    actions = SZFOrderAdvance(order, clock);
    CHECK(actions == (SZFriendsOnlineOrderActionStopProbing | SZFriendsOnlineOrderActionOpenRelay));
    NSUInteger tried = order.logEntry.techniquesTried;
    CHECK((tried & (1u << SZFriendsOnlineTechniquePredictedPort)) &&
          (tried & (1u << SZFriendsOnlineTechniqueProbeHandover)));

    // The prober's budget refused the run (this peer within 10 minutes): prediction alone, and the log says so.
    SZFriendsOnlineOrder *again = SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    [again descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Hard];
    CHECK(SZFOrderAdvance(again, clock) & SZFriendsOnlineOrderActionStartProbing);
    CHECK([again probingEndedRefused:YES] == SZFriendsOnlineOrderActionNone, "the direct connection still checks");
    CHECK(!(again.logEntry.techniquesTried & (1u << SZFriendsOnlineTechniqueProbeHandover)));
    CHECK(SZFOrderAdvance(again, clock) == SZFriendsOnlineOrderActionOpenRelay, "nothing to stop at 17 s");
    // Probing found nothing and the direct connection had already failed: the relay at once, not at 17 s.
    SZFriendsOnlineOrder *spent = SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    [spent descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Hard];
    SZFOrderAdvance(spent, clock);
    CHECK([spent connectionFailed:SZFriendsOnlineConnectionDirect] == SZFriendsOnlineOrderActionNone,
          "probing may still hand over");
    CHECK([spent probingEndedRefused:NO] == SZFriendsOnlineOrderActionOpenRelay);
    CHECK(spent.logEntry.techniquesTried & (1u << SZFriendsOnlineTechniqueProbeHandover), "it ran");
    // A probe handover connecting ends probing and closes the direct connection it outran.
    SZFriendsOnlineOrder *other = SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    [other descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Hard];
    SZFOrderAdvance(other, clock);
    actions = [other streamOpenedOnConnection:SZFriendsOnlineConnectionProbeHandover
                                        route:SZFOrderRoute(SZFriendsOnlineTechniqueProbeHandover)];
    CHECK(actions == (SZFriendsOnlineOrderActionStopProbing | SZFriendsOnlineOrderActionCloseDirect));

    // Both hard, or a class unknown: the plain checks were all there was.
    SZFriendsNATClass pairs[][2] = {{Hard, Hard}, {Hard, SZFriendsNATClassUnknown}, {Easy, Easy}};
    for (size_t i = 0; i < 3; i++) {
        SZFriendsOnlineOrder *plain = SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
        NSTimeInterval start = clock.now;
        [plain descriptionsAppliedWithLocalNATClass:pairs[i][0] remoteNATClass:pairs[i][1]];
        CHECK(SZFOrderAdvance(plain, clock) == SZFriendsOnlineOrderActionOpenRelay && clock.now == start + 5,
              "pair %zu: relay at 5 s", i);
    }
    CHECK(!SZFriendsOnlineHardNATWorthTrying(Hard, Hard) && SZFriendsOnlineHardNATWorthTrying(Easy, Hard));
}

// "Relay: only in last resort ... if everything fails": never while another route carries the session.
static void TestRelayOnlyAsLastResort(void) {
    CHECK(SZFriendsOnlineAttemptWorthStarting(SZFriendsRouteMethodNone));
    CHECK(SZFriendsOnlineAttemptWorthStarting(SZFriendsRouteMethodBluetooth), "Internet ranks before Bluetooth");
    CHECK(SZFriendsOnlineAttemptWorthStarting(SZFriendsRouteMethodRelay));
    CHECK(!SZFriendsOnlineAttemptWorthStarting(SZFriendsRouteMethodLAN));
    CHECK(!SZFriendsOnlineAttemptWorthStarting(SZFriendsRouteMethodPeerToPeerWiFi));
    CHECK(!SZFriendsOnlineAttemptWorthStarting(SZFriendsRouteMethodInternet));

    SZFOrderClock *clock = [SZFOrderClock new];
    SZFriendsOnlineOrder *order =
        SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    [order descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Easy];
    CHECK([order otherRouteChanged:SZFriendsRouteMethodBluetooth] == SZFriendsOnlineOrderActionNone,
          "Bluetooth works; direct keeps checking");
    CHECK(SZFOrderAdvance(order, clock) == SZFriendsOnlineOrderActionNone && order.phase == SZFriendsOnlinePhaseStandby,
          "the budget ends without the relay");
    CHECK(order.nextDeadline == 5 + SZFriendsOnlineRetryFirst, "direct is retried while on Bluetooth");
    CHECK(SZFOrderAdvance(order, clock) ==
          (SZFriendsOnlineOrderActionCloseDirect | SZFriendsOnlineOrderActionOpenDirect));
    // Bluetooth is lost: the direct try running finishes first (ADR 0020), then the relay is the last resort.
    CHECK([order otherRouteChanged:SZFriendsRouteMethodNone] == SZFriendsOnlineOrderActionNone &&
          order.phase == SZFriendsOnlinePhaseStandby);
    [order descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Easy];
    CHECK(SZFOrderAdvance(order, clock) ==
              (SZFriendsOnlineOrderActionCloseDirect | SZFriendsOnlineOrderActionOpenRelay) &&
          order.phase == SZFriendsOnlinePhaseRelay);
    [order streamOpenedOnConnection:SZFriendsOnlineConnectionRelay route:SZFOrderRoute(SZFriendsOnlineTechniqueRelay)];
    CHECK(order.phase == SZFriendsOnlinePhaseRelayed);
    // Bluetooth comes back: it outranks the relay, which closes.
    CHECK([order otherRouteChanged:SZFriendsRouteMethodBluetooth] == SZFriendsOnlineOrderActionCloseRelay &&
          order.phase == SZFriendsOnlinePhaseStandby);
    // A LAN session ends the attempt.
    CHECK([order otherRouteChanged:SZFriendsRouteMethodLAN] == SZFriendsOnlineOrderActionEnd &&
          order.endReason == SZFriendsOnlineEndSuperseded && isinf(order.nextDeadline));

    // A relay stream that opens while another route works is closed at once.
    SZFriendsOnlineOrder *late =
        SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    [late descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Easy];
    CHECK(SZFOrderAdvance(late, clock) == SZFriendsOnlineOrderActionOpenRelay);
    [late otherRouteChanged:SZFriendsRouteMethodNone];
    CHECK([late otherRouteChanged:SZFriendsRouteMethodBluetooth] == SZFriendsOnlineOrderActionCloseRelay,
          "a relay still connecting is dropped too");
    // Another attempt's Internet session came first: within the class the first path keeps the session.
    SZFriendsOnlineOrder *second =
        SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    CHECK([second otherRouteChanged:SZFriendsRouteMethodInternet] == SZFriendsOnlineOrderActionEnd);
    SZFriendsOnlineOrder *first =
        SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    [first streamOpenedOnConnection:SZFriendsOnlineConnectionDirect
                              route:SZFOrderRoute(SZFriendsOnlineTechniqueHostIPv6)];
    CHECK([first otherRouteChanged:SZFriendsRouteMethodInternet] == SZFriendsOnlineOrderActionNone,
          "a direct attempt that is up leaves it to the session race");
}

// Failures move on at once instead of waiting out the timer; with nothing left the attempt is unreachable.
static void TestFailures(void) {
    SZFOrderClock *clock = [SZFOrderClock new];
    SZFriendsOnlineOrder *order =
        SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    [order descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Easy];
    clock.now = 1;
    CHECK([order connectionFailed:SZFriendsOnlineConnectionDirect] == SZFriendsOnlineOrderActionOpenRelay,
          "every direct path failed: the relay without waiting");
    CHECK([order connectionFailed:SZFriendsOnlineConnectionRelay] == SZFriendsOnlineOrderActionEnd &&
          order.endReason == SZFriendsOnlineEndUnreachable);

    SZFriendsOnlineOrder *early =
        SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    CHECK([early connectionFailed:SZFriendsOnlineConnectionDirect] == SZFriendsOnlineOrderActionEnd &&
          early.endReason == SZFriendsOnlineEndUnreachable, "no answer to signal with: nothing else to try");

    // The relay fails while direct is still checking: wait for direct, then give up.
    SZFriendsOnlineOrder *waiting =
        SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    [waiting descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Easy];
    SZFOrderAdvance(waiting, clock);
    CHECK([waiting connectionFailed:SZFriendsOnlineConnectionRelay] == SZFriendsOnlineOrderActionNone);
    CHECK([waiting connectionFailed:SZFriendsOnlineConnectionDirect] == SZFriendsOnlineOrderActionEnd);

    // Network change before any relay: a new direct connection, and its descriptions start a new budget.
    SZFriendsOnlineOrder *moved =
        SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    clock.now = 50;
    [moved descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Easy];
    clock.now = 53;
    CHECK([moved networkChanged] == (SZFriendsOnlineOrderActionCloseDirect | SZFriendsOnlineOrderActionOpenDirect) &&
          moved.phase == SZFriendsOnlinePhaseSignalling && isinf(moved.nextDeadline));
    clock.now = 54;
    [moved descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Easy];
    CHECK(moved.nextDeadline == 59, "5 s from the new descriptions");
}

// The answerer has no timers: it follows the offerer's signalling.
static void TestAnswerer(void) {
    SZFOrderClock *clock = [SZFOrderClock new];
    SZFriendsOnlineOrder *order = SZFOrderMake(SZFriendsOnlineRoleAnswerer, clock);
    [order descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Hard];
    CHECK(order.phase == SZFriendsOnlinePhasePlainChecks && isinf(order.nextDeadline));
    clock.now = 1000;
    CHECK([order fireDueTimers] == SZFriendsOnlineOrderActionNone, "never starts the relay or probing itself");
    CHECK([order peerStartedHardNAT] ==
          (SZFriendsOnlineOrderActionStartPrediction | SZFriendsOnlineOrderActionStartProbing));
    CHECK([order peerOpenedRelay] == (SZFriendsOnlineOrderActionStopProbing | SZFriendsOnlineOrderActionOpenRelay));
    CHECK([order peerOpenedRelay] == SZFriendsOnlineOrderActionNone, "one relay connection");
    [order streamOpenedOnConnection:SZFriendsOnlineConnectionRelay route:SZFOrderRoute(SZFriendsOnlineTechniqueRelay)];
    CHECK(order.phase == SZFriendsOnlinePhaseRelayed && isinf(order.nextDeadline), "the offerer retries");
    CHECK([order networkChanged] == SZFriendsOnlineOrderActionSignalNetworkChange);
    CHECK([order peerNetworkChanged] == SZFriendsOnlineOrderActionNone);
    CHECK([order peerOpenedDirect] == (SZFriendsOnlineOrderActionCloseDirect | SZFriendsOnlineOrderActionOpenDirect));
    CHECK([order streamOpenedOnConnection:SZFriendsOnlineConnectionDirect
                                    route:SZFOrderRoute(SZFriendsOnlineTechniquePredictedPort)] ==
          SZFriendsOnlineOrderActionCloseRelay);
    CHECK(order.phase == SZFriendsOnlinePhaseDirect && order.logEntry.role == SZFriendsOnlineRoleAnswerer);
    CHECK([order networkChanged] == SZFriendsOnlineOrderActionNone && [order close] == SZFriendsOnlineOrderActionEnd);

    // The offerer hears the answerer's network change as its own.
    SZFriendsOnlineOrder *offerer = SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    [offerer descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Easy];
    CHECK([offerer peerNetworkChanged] ==
          (SZFriendsOnlineOrderActionCloseDirect | SZFriendsOnlineOrderActionOpenDirect));
    CHECK([offerer peerOpenedRelay] == SZFriendsOnlineOrderActionNone, "only the answerer answers relay offers");
}

void SZFriendsRunOrderPhaseTests(void) {
    TestPlainChecksThenRelay();
    TestDirectWithinPlainChecks();
    TestHardNAT();
    TestRelayOnlyAsLastResort();
    TestFailures();
    TestAnswerer();
}

int main(void) {
    @autoreleasepool {
        SZFriendsRunOrderPhaseTests();
        SZFriendsRunOrderRetryTests();
        SZFriendsRunTechniqueLogTests();
        if (SZFOrderFailures) {
            fprintf(stderr, "SZFriendsOnlineOrderTests: %d failure(s)\n", SZFOrderFailures);
            return 1;
        }
        printf("SZFriendsOnlineOrderTests passed\n");
        return 0;
    }
}
