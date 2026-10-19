// Leaving the relay with a scripted clock (ADR 0011 § The direct phase, step 4): periodic retries from 30 s,
// doubling to 5 minutes with 20% jitter; a retry at once after a network change; libjuice settling the relay
// connection on a direct pair; probing again only when a NAT class changed; a long sleep.

#import "SZFriendsOrderTestSupport.h"

static const SZFriendsNATClass Easy = SZFriendsNATClassEndpointIndependent;
static const SZFriendsNATClass Hard = SZFriendsNATClassPerDestination;

static const SZFriendsOnlineOrderActions CloseAndOpen =
    SZFriendsOnlineOrderActionCloseDirect | SZFriendsOnlineOrderActionOpenDirect;

// An offerer whose relay carries the stream at clock.now, with its first direct connection already given up.
static SZFriendsOnlineOrder *Relayed(SZFOrderClock *clock, SZFriendsNATClass local, SZFriendsNATClass remote) {
    SZFriendsOnlineOrder *order = SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    [order descriptionsAppliedWithLocalNATClass:local remoteNATClass:remote];
    while (order.phase != SZFriendsOnlinePhaseRelay) SZFOrderAdvance(order, clock);
    [order connectionFailed:SZFriendsOnlineConnectionDirect];
    [order streamOpenedOnConnection:SZFriendsOnlineConnectionRelay route:SZFOrderRoute(SZFriendsOnlineTechniqueRelay)];
    return order;
}

static void TestPeriodicSchedule(void) {
    SZFOrderClock *clock = [SZFOrderClock new];
    SZFriendsOnlineOrder *order = Relayed(clock, Easy, Easy);
    CHECK(order.phase == SZFriendsOnlinePhaseRelayed && clock.now == 5);
    CHECK(SZFriendsOnlineRetryFirst == 30 && SZFriendsOnlineRetryMax == 300 && SZFriendsOnlineRetryJitter == 0.2);
    // Retry 1 at 35: no descriptions within the signalling limit, so it ends at 45 and the wait doubles.
    CHECK(SZFOrderAdvance(order, clock) == SZFriendsOnlineOrderActionOpenDirect && clock.now == 35,
          "the first direct connection is gone, so nothing to close");
    CHECK(SZFOrderAdvance(order, clock) == SZFriendsOnlineOrderActionCloseDirect && clock.now == 45);
    NSTimeInterval expectedWait = 60, waits[6];
    for (int i = 0; i < 6; i++) {
        NSTimeInterval ended = clock.now;
        CHECK(SZFOrderAdvance(order, clock) == SZFriendsOnlineOrderActionOpenDirect);
        waits[i] = clock.now - ended;
        CHECK(waits[i] == expectedWait, "retry %d waited %.0f s, expected %.0f", i + 2, waits[i], expectedWait);
        clock.now += 1;
        [order descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Easy];
        CHECK(order.nextDeadline == clock.now + SZFriendsOnlinePlainChecksBudget, "a retry's plain checks");
        CHECK(SZFOrderAdvance(order, clock) == SZFriendsOnlineOrderActionCloseDirect);
        expectedWait = MIN(expectedWait * 2, 300);
    }
    CHECK(waits[3] == 300 && waits[5] == 300, "never more than 5 minutes");
    CHECK(order.logEntry.directRetries == 7 && order.phase == SZFriendsOnlinePhaseRelayed);

    // Jitter: each wait is drawn from 80% to 120% of the step.
    clock.random = 0;
    SZFriendsOnlineOrder *low = Relayed(clock, Easy, Easy);
    NSTimeInterval relayedAt = clock.now;
    CHECK(fabs(low.nextDeadline - (relayedAt + 24)) < 1e-9, "%.3f", low.nextDeadline - relayedAt);
    clock.random = 0.999999;
    SZFriendsOnlineOrder *high = Relayed(clock, Easy, Easy);
    relayedAt = clock.now;
    CHECK(high.nextDeadline - relayedAt > 35.99 && high.nextDeadline - relayedAt <= 36);
    clock.random = 7; // a broken source is clamped, never a wait outside the band
    SZFriendsOnlineOrder *odd = Relayed(clock, Easy, Easy);
    CHECK(odd.nextDeadline - clock.now <= 36);
}

// "keep trying direct routes after network changes": at once, and the waits start again from the first step.
static void TestNetworkChange(void) {
    SZFOrderClock *clock = [SZFOrderClock new];
    SZFriendsOnlineOrder *order = Relayed(clock, Easy, Easy);
    for (int i = 0; i < 3; i++) {
        SZFOrderAdvance(order, clock);
        SZFOrderAdvance(order, clock);
    }
    CHECK(order.nextDeadline - clock.now == 240, "three failed retries: the fourth waits 240 s");
    clock.now += 7;
    CHECK([order networkChanged] == SZFriendsOnlineOrderActionOpenDirect, "a direct retry at once");
    CHECK([order networkChanged] == CloseAndOpen, "another change replaces the running retry");
    [order descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Easy];
    CHECK(SZFOrderAdvance(order, clock) == SZFriendsOnlineOrderActionCloseDirect);
    CHECK(order.nextDeadline - clock.now == SZFriendsOnlineRetryFirst, "the waits start again from 30 s");

    // While the relay is still connecting a network change retries direct too, but no periodic retry runs.
    SZFriendsOnlineOrder *connecting =
        SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    [connecting descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Easy];
    SZFOrderAdvance(connecting, clock);
    CHECK(connecting.phase == SZFriendsOnlinePhaseRelay && isinf(connecting.nextDeadline));
    CHECK([connecting networkChanged] == CloseAndOpen && connecting.phase == SZFriendsOnlinePhaseRelay);
    CHECK(SZFOrderAdvance(connecting, clock) == SZFriendsOnlineOrderActionCloseDirect &&
          isinf(connecting.nextDeadline));
}

// libjuice settles a relayed connection on a shorter pair by itself: direct without a new connection.
static void TestRelaySettlesDirect(void) {
    SZFOrderClock *clock = [SZFOrderClock new];
    SZFriendsOnlineOrder *order = Relayed(clock, Easy, Easy);
    SZFOrderAdvance(order, clock); // a periodic retry is running
    SZFriendsOnlineRoute settled = SZFOrderRoute(SZFriendsOnlineTechniqueServerReflexive);
    SZFriendsOnlineOrderActions actions = [order routeChangedOnConnection:SZFriendsOnlineConnectionRelay
                                                                    route:settled];
    CHECK(actions == SZFriendsOnlineOrderActionCloseDirect, "the retry closes; the relay connection carries on");
    CHECK(order.phase == SZFriendsOnlinePhaseDirect && isinf(order.nextDeadline) && order.logEntry.leftRelay);
    CHECK(order.logEntry.finalTechnique == SZFriendsOnlineTechniqueServerReflexive);
    // Back on the relay pair: relayed again, and retries resume.
    [order routeChangedOnConnection:SZFriendsOnlineConnectionRelay route:SZFOrderRoute(SZFriendsOnlineTechniqueRelay)];
    CHECK(order.phase == SZFriendsOnlinePhaseRelayed && order.nextDeadline == clock.now + SZFriendsOnlineRetryFirst);
    // A route change on a connection that carries nothing is ignored.
    CHECK([order routeChangedOnConnection:SZFriendsOnlineConnectionDirect
                                    route:SZFOrderRoute(SZFriendsOnlineTechniqueHostIPv6)] ==
          SZFriendsOnlineOrderActionNone && order.phase == SZFriendsOnlinePhaseRelayed);
    // The relay's stream closing ends the attempt; the helper dials again.
    CHECK([order streamClosedOnConnection:SZFriendsOnlineConnectionRelay] == SZFriendsOnlineOrderActionEnd &&
          order.endReason == SZFriendsOnlineEndStreamClosed);
}

// "Probing runs again only if a side's NAT class changed."
static void TestProbingAgainOnlyAfterAClassChange(void) {
    SZFOrderClock *clock = [SZFOrderClock new];
    SZFriendsOnlineOrder *order = Relayed(clock, Easy, Hard);
    CHECK(order.logEntry.techniquesTried & (1u << SZFriendsOnlineTechniqueProbeHandover), "probed the first time");
    SZFOrderAdvance(order, clock);
    [order descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Hard];
    CHECK(SZFOrderAdvance(order, clock) == SZFriendsOnlineOrderActionCloseDirect, "same classes: plain checks only");
    // A new network: this side is hard now and the peer easy. Prediction and probing again.
    clock.now += 600;
    [order localNATClassChanged:Hard];
    CHECK([order networkChanged] == SZFriendsOnlineOrderActionOpenDirect);
    [order descriptionsAppliedWithLocalNATClass:Hard remoteNATClass:Easy];
    SZFriendsOnlineOrderActions actions = SZFOrderAdvance(order, clock);
    CHECK(actions == (SZFriendsOnlineOrderActionStartPrediction | SZFriendsOnlineOrderActionStartProbing));
    CHECK(order.nextDeadline == clock.now + SZFriendsOnlineHardNATBudget);
    CHECK(SZFOrderAdvance(order, clock) ==
          (SZFriendsOnlineOrderActionStopProbing | SZFriendsOnlineOrderActionCloseDirect));
    CHECK(order.logEntry.localNATClass == Hard && order.logEntry.remoteNATClass == Easy);
    // The next retry on the same network: no probing.
    SZFOrderAdvance(order, clock);
    [order descriptionsAppliedWithLocalNATClass:Hard remoteNATClass:Easy];
    CHECK(SZFOrderAdvance(order, clock) == SZFriendsOnlineOrderActionCloseDirect);
}

// After a long sleep the clock jumps: one retry, not a burst of every one missed.
static void TestSleep(void) {
    SZFOrderClock *clock = [SZFOrderClock new];
    SZFriendsOnlineOrder *order = Relayed(clock, Easy, Easy);
    clock.now += 86400;
    CHECK([order fireDueTimers] == SZFriendsOnlineOrderActionOpenDirect && order.nextDeadline > clock.now);
    CHECK([order fireDueTimers] == SZFriendsOnlineOrderActionNone);
}

// Standby retries like Relayed, and a direct path found there ends Standby.
static void TestStandbyRetries(void) {
    SZFOrderClock *clock = [SZFOrderClock new];
    SZFriendsOnlineOrder *order =
        SZFOrderMake(SZFriendsOnlineRoleOfferer, clock);
    [order otherRouteChanged:SZFriendsRouteMethodBluetooth];
    [order descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Easy];
    SZFOrderAdvance(order, clock);
    [order connectionFailed:SZFriendsOnlineConnectionDirect];
    CHECK(order.phase == SZFriendsOnlinePhaseStandby && order.nextDeadline == 35);
    CHECK(SZFOrderAdvance(order, clock) == SZFriendsOnlineOrderActionOpenDirect);
    [order descriptionsAppliedWithLocalNATClass:Easy remoteNATClass:Easy];
    CHECK([order streamOpenedOnConnection:SZFriendsOnlineConnectionDirect
                                    route:SZFOrderRoute(SZFriendsOnlineTechniquePortMapping)] ==
          SZFriendsOnlineOrderActionNone && order.phase == SZFriendsOnlinePhaseDirect,
          "Internet now carries the session; the session race supersedes Bluetooth");
    CHECK(!order.logEntry.relayRequested, "the relay was never asked for");
}

void SZFriendsRunOrderRetryTests(void) {
    TestPeriodicSchedule();
    TestNetworkChange();
    TestRelaySettlesDirect();
    TestProbingAgainOnlyAfterAClassChange();
    TestSleep();
    TestStandbyRetries();
}
