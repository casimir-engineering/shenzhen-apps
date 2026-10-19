// Hard-NAT probing on loopback: both sides in this process, the hard side's 256 sockets inside a port window the test
// holds (its other ports stay bound and silent, like ports a NAT never opened), the easy side probing that window.
// Then the handover: two libjuice agents bound to exactly the winning ports connect with only each other's winning
// address as remote candidate. Also the budget, the address rules, the rate and the cap.

#import "SZFriendsNATTestSupport.h"

#import "service/online/nat/SZFriendsNATPrediction.h"
#import "service/online/nat/SZFriendsNATProber.h"

#include <juice/juice.h>
#include <netinet/in.h>
#include <stdatomic.h>
#include <unistd.h>

static SZFriendsNATProberConfiguration *Side(SZFriendsNATProbeRole role, SZFriendsNATEndpoint *remote) {
    SZFriendsNATProberConfiguration *c = [SZFriendsNATProberConfiguration new];
    BOOL hard = role == SZFriendsNATProbeRoleHard;
    c.role = role;
    c.peer = [(hard ? @"easy peer" : @"hard peer") dataUsingEncoding:NSUTF8StringEncoding];
    c.remote = remote;
    c.presented = remote != nil ? @[ remote ] : nil; // as the peer's signalling would have named it
    c.localUfrag = hard ? @"hardUfrag0123456" : @"easyUfrag0123456";
    c.remoteUfrag = hard ? @"easyUfrag0123456" : @"hardUfrag0123456";
    c.localPassword = hard ? @"hardPassword/hardPassword+1" : @"easyPassword/easyPassword+2";
    c.remotePassword = hard ? @"easyPassword/easyPassword+2" : @"hardPassword/hardPassword+1";
    c.budget = [[SZFriendsNATProbeBudget alloc] initWithInterval:600 clock:nil];
    c.loopbackOnly = YES;
    return c;
}

typedef struct {
    SZFriendsNATProbeHit *hit;
    NSError *error;
    BOOL done;
    BOOL portFree; // the winning port could be bound from inside the completion, as the probe handover does
} ProbeOutcome;

static BOOL CanBindUDP(uint16_t port) {
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    struct sockaddr_in address = {.sin_len = sizeof address, .sin_family = AF_INET, .sin_port = htons(port)};
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL bound = fd >= 0 && bind(fd, (struct sockaddr *)&address, sizeof address) == 0;
    if (fd >= 0) close(fd);
    return bound;
}

static void Start(SZFriendsNATProber *prober, dispatch_queue_t queue, ProbeOutcome *outcome,
                  dispatch_semaphore_t done) {
    [prober startOnQueue:queue
              completion:^(SZFriendsNATProbeHit *hit, NSError *error) {
                  outcome->hit = hit;
                  outcome->error = error;
                  outcome->portFree = hit != nil && CanBindUDP(hit.localPort);
                  outcome->done = YES;
                  dispatch_semaphore_signal(done);
              }];
}

static SZFriendsNATEndpoint *Prepare(SZFriendsNATProber *easy, dispatch_queue_t queue) {
    __block SZFriendsNATEndpoint *reflexive = nil;
    dispatch_semaphore_t prepared = dispatch_semaphore_create(0);
    [easy prepareOnQueue:queue
              completion:^(SZFriendsNATEndpoint *endpoint, NSError *error) {
                  (void)error;
                  reflexive = endpoint;
                  dispatch_semaphore_signal(prepared);
              }];
    CHECK(SZFTestWait(prepared, 3) && reflexive != nil);
    return reflexive;
}

#pragma mark libjuice handover

typedef struct {
    atomic_int state;
    atomic_int received;
} JuicePeer;

static void OnState(juice_agent_t *agent, juice_state_t state, void *user) {
    (void)agent;
    atomic_store(&((JuicePeer *)user)->state, (int)state);
}
static void OnCandidate(juice_agent_t *agent, const char *sdp, void *user) {
    (void)agent, (void)sdp, (void)user;
}
static void OnGathered(juice_agent_t *agent, void *user) {
    (void)agent, (void)user;
}
static void OnReceive(juice_agent_t *agent, const char *data, size_t size, void *user) {
    (void)agent, (void)data, (void)size;
    atomic_fetch_add(&((JuicePeer *)user)->received, 1);
}

static juice_agent_t *Agent(JuicePeer *peer, uint16_t port) {
    juice_config_t config = {0};
    config.concurrency_mode = JUICE_CONCURRENCY_MODE_POLL;
    config.bind_address = "127.0.0.1";
    config.local_port_range_begin = port;
    config.local_port_range_end = port;
    config.cb_state_changed = OnState;
    config.cb_candidate = OnCandidate;
    config.cb_gathering_done = OnGathered;
    config.cb_recv = OnReceive;
    config.user_ptr = peer;
    return juice_create(&config);
}

// The description without its candidates: the handover connection's only remote candidate is the prober's pair.
static NSString *WithoutCandidates(const char *sdp) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *line in [@(sdp) componentsSeparatedByString:@"\n"]) {
        if (![line hasPrefix:@"a=candidate:"] && ![line hasPrefix:@"a=end-of-candidates"]) [lines addObject:line];
    }
    return [lines componentsJoinedByString:@"\n"];
}

static BOOL Connected(JuicePeer *peer) {
    int state = atomic_load(&peer->state);
    return state == JUICE_STATE_CONNECTED || state == JUICE_STATE_COMPLETED;
}

static void TestHandover(SZFriendsNATProbeHit *easyHit, SZFriendsNATProbeHit *hardHit) {
    juice_set_log_level(JUICE_LOG_LEVEL_NONE);
    JuicePeer easyPeer = {0}, hardPeer = {0};
    juice_agent_t *easy = Agent(&easyPeer, easyHit.localPort), *hard = Agent(&hardPeer, hardHit.localPort);
    CHECK(easy != NULL && hard != NULL, "both agents bind exactly the winning ports");
    if (easy == NULL || hard == NULL) return;
    char sdp[JUICE_MAX_SDP_STRING_LEN];
    juice_get_local_description(easy, sdp, sizeof sdp);
    // The answerer applies the offer before it gathers (ADR 0011), so no role conflict.
    juice_set_remote_description(hard, WithoutCandidates(sdp).UTF8String);
    juice_get_local_description(hard, sdp, sizeof sdp);
    juice_set_remote_description(easy, WithoutCandidates(sdp).UTF8String);
    juice_gather_candidates(easy);
    juice_gather_candidates(hard);
    NSString *toHard = [NSString stringWithFormat:@"a=candidate:1 1 UDP 2130706431 %@ %u typ host",
                                                  easyHit.remote.host, easyHit.remote.port];
    NSString *toEasy = [NSString stringWithFormat:@"a=candidate:1 1 UDP 2130706431 %@ %u typ host",
                                                  hardHit.remote.host, hardHit.remote.port];
    CHECK(juice_add_remote_candidate(easy, toHard.UTF8String) == 0);
    CHECK(juice_add_remote_candidate(hard, toEasy.UTF8String) == 0);
    juice_set_remote_gathering_done(easy);
    juice_set_remote_gathering_done(hard);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!(Connected(&easyPeer) && Connected(&hardPeer)) && deadline.timeIntervalSinceNow > 0) usleep(2000);
    CHECK(Connected(&easyPeer) && Connected(&hardPeer), "the handover connection connects on the prober's pair");
    juice_send(easy, "ping", 4);
    juice_send(hard, "pong", 4);
    deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while ((atomic_load(&easyPeer.received) == 0 || atomic_load(&hardPeer.received) == 0) &&
           deadline.timeIntervalSinceNow > 0) {
        usleep(2000);
    }
    CHECK(atomic_load(&easyPeer.received) > 0 && atomic_load(&hardPeer.received) > 0);
    juice_destroy(easy);
    juice_destroy(hard);
}

// Prediction against libjuice: the "hard" agent is bound to the port a sequential NAT (step 2) would map next but
// two, the "easy" agent gets only the 25 predicted candidates from the reflexive port, and they connect. The other
// predicted ports are held by this test, so the checks sent to them reach nothing else on this Mac.
static void TestPredictionConnects(void) {
    uint16_t base = 0;
    NSArray<NSNumber *> *held = SZFTestHoldUDPPortWindow(54, &base);
    CHECK(held.count == 54);
    if (held.count != 54) return;
    uint16_t reflexive = base, actual = (uint16_t)(base + 3 * 2);
    close(held[6].intValue);
    juice_set_log_level(JUICE_LOG_LEVEL_NONE);
    JuicePeer easyPeer = {0}, hardPeer = {0};
    juice_agent_t *easy = Agent(&easyPeer, 0), *hard = Agent(&hardPeer, actual);
    CHECK(easy != NULL && hard != NULL);
    char sdp[JUICE_MAX_SDP_STRING_LEN];
    juice_get_local_description(easy, sdp, sizeof sdp);
    juice_set_remote_description(hard, WithoutCandidates(sdp).UTF8String);
    juice_get_local_description(hard, sdp, sizeof sdp);
    juice_set_remote_description(easy, WithoutCandidates(sdp).UTF8String);
    // The hard agent binds its port first, so the easy agent's system-chosen port can never be that one.
    juice_gather_candidates(hard);
    juice_gather_candidates(easy);
    SZFriendsNATEndpoint *mapped = [SZFriendsNATEndpoint endpointWithHost:@"127.0.0.1" port:reflexive];
    NSArray<NSString *> *predicted = SZFriendsNATPredictedCandidates(mapped, 2, 0);
    CHECK(predicted.count == 25);
    int accepted = 0;
    for (NSString *line in predicted) {
        if (juice_add_remote_candidate(easy, [@"a=" stringByAppendingString:line].UTF8String) == 0) accepted++;
    }
    CHECK(accepted == 25, "libjuice takes every predicted candidate (%d)", accepted);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!(Connected(&easyPeer) && Connected(&hardPeer)) && deadline.timeIntervalSinceNow > 0) usleep(2000);
    CHECK(Connected(&easyPeer) && Connected(&hardPeer), "a predicted port connects (the third of 25)");
    juice_destroy(easy);
    juice_destroy(hard);
    for (NSUInteger i = 0; i < held.count; i++) {
        if (i != 6) close(held[i].intValue);
    }
}

#pragma mark Runs

// `filtered`: the hard side's own probes go to a silent port, as through an easy NAT that filters by port, so only
// the easy side's random probes can find the pair.
static void TestPair(BOOL filtered) {
    uint16_t base = 0;
    NSArray<NSNumber *> *held = SZFTestHoldUDPPortWindow(512, &base);
    CHECK(held.count == 512, "a free window of 512 loopback ports");
    if (held.count != 512) return;
    dispatch_queue_t easyQueue = SZFTestQueue("szf.test.easy"), hardQueue = SZFTestQueue("szf.test.hard");
    SZFriendsNATEndpoint *loopback = [SZFriendsNATEndpoint endpointWithHost:@"127.0.0.1" port:0];
    SZFriendsNATProberConfiguration *easyConfiguration = Side(SZFriendsNATProbeRoleEasy, loopback);
    easyConfiguration.portRangeLow = base;
    easyConfiguration.portRangeHigh = (uint16_t)(base + 511);
    SZFriendsNATProber *easy = [[SZFriendsNATProber alloc] initWithConfiguration:easyConfiguration];
    // Bound before the window opens, so the system cannot give the easy side a port the hard side needs.
    SZFriendsNATEndpoint *reflexive = Prepare(easy, easyQueue);
    NSMutableArray<NSNumber *> *hardPorts = [NSMutableArray array];
    for (NSUInteger i = 0; i < 256; i++) {
        close(held[i * 2].intValue); // every other port: the hard side's sockets interleave with silent ones
        [hardPorts addObject:@(base + i * 2)];
    }
    SZFriendsNATEndpoint *hardTarget = filtered ? [loopback endpointWithPort:(uint16_t)(base + 1)] : reflexive;
    SZFriendsNATProberConfiguration *hardConfiguration = Side(SZFriendsNATProbeRoleHard, hardTarget);
    hardConfiguration.localPorts = hardPorts;
    SZFriendsNATProber *hard = [[SZFriendsNATProber alloc] initWithConfiguration:hardConfiguration];

    __block ProbeOutcome easyOutcome = {nil, nil, NO, NO}, hardOutcome = {nil, nil, NO, NO};
    dispatch_semaphore_t easyDone = dispatch_semaphore_create(0), hardDone = dispatch_semaphore_create(0);
    NSDate *start = [NSDate date];
    Start(hard, hardQueue, &hardOutcome, hardDone);
    Start(easy, easyQueue, &easyOutcome, easyDone);
    CHECK(SZFTestWait(easyDone, 10) && SZFTestWait(hardDone, 10), "both sides finish");
    SZFriendsNATProbeHit *easyHit = easyOutcome.hit, *hardHit = hardOutcome.hit;
    CHECK(easyHit != nil && hardHit != nil, "%s: %@ %@", filtered ? "filtered" : "open", easyOutcome.error,
          hardOutcome.error);
    CHECK(easyHit.remote.port == hardHit.localPort && [hardPorts containsObject:@(hardHit.localPort)],
          "both sides agree on the hard side's port");
    CHECK([hardHit.remote isEqual:reflexive] && easyHit.localPort == reflexive.port, "and on the easy side's");
    CHECK(easyOutcome.portFree && hardOutcome.portFree, "each winning port is free when the hit is reported");
    CHECK(hardHit.probesSent == 256 && easyHit.probesSent <= SZFriendsNATProbeMax, "%lu and %lu probes",
          (unsigned long)hardHit.probesSent, (unsigned long)easyHit.probesSent);
    fprintf(stderr, "    %s: pair after %.2f s, %lu random probes\n", filtered ? "filtered" : "open",
            -start.timeIntervalSinceNow, (unsigned long)easyHit.probesSent);
    if (easyHit != nil && hardHit != nil) TestHandover(easyHit, hardHit);
    for (NSUInteger i = 0; i < 256; i++) close(held[i * 2 + 1].intValue);
}

static void TestWrongCredentialsNeverHit(void) {
    SZFriendsNATEndpoint *loopback = [SZFriendsNATEndpoint endpointWithHost:@"127.0.0.1" port:0];
    dispatch_queue_t queue = SZFTestQueue("szf.test.creds");
    SZFriendsNATProberConfiguration *easyConfiguration = Side(SZFriendsNATProbeRoleEasy, loopback);
    easyConfiguration.duration = 1;
    SZFriendsNATProber *easy = [[SZFriendsNATProber alloc] initWithConfiguration:easyConfiguration];
    SZFriendsNATEndpoint *reflexive = Prepare(easy, queue);
    SZFriendsNATProberConfiguration *hardConfiguration = Side(SZFriendsNATProbeRoleHard, reflexive);
    hardConfiguration.remotePassword = @"someoneElsesPassword12345"; // a stranger's probes
    hardConfiguration.socketCount = 16;
    hardConfiguration.duration = 1;
    SZFriendsNATProber *hard = [[SZFriendsNATProber alloc] initWithConfiguration:hardConfiguration];
    __block ProbeOutcome easyOutcome = {nil, nil, NO, NO}, hardOutcome = {nil, nil, NO, NO};
    dispatch_semaphore_t easyDone = dispatch_semaphore_create(0), hardDone = dispatch_semaphore_create(0);
    Start(hard, queue, &hardOutcome, hardDone);
    Start(easy, queue, &easyOutcome, easyDone);
    CHECK(SZFTestWait(easyDone, 3) && SZFTestWait(hardDone, 3));
    CHECK(easyOutcome.hit == nil && easyOutcome.error.code == SZFriendsNATErrorTimedOut &&
          hardOutcome.hit == nil, "probes that fail integrity never win");
    CHECK(easy.probesSent >= 90 && easy.probesSent <= 102, "100 probes a second (%lu in 1 s)",
          (unsigned long)easy.probesSent);
}

static ProbeOutcome RunAlone(SZFriendsNATProberConfiguration *configuration) {
    SZFriendsNATProber *prober = [[SZFriendsNATProber alloc] initWithConfiguration:configuration];
    __block ProbeOutcome outcome = {nil, nil, NO, NO};
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    Start(prober, SZFTestQueue("szf.test.alone"), &outcome, done);
    CHECK(SZFTestWait(done, configuration.duration + 2));
    return outcome;
}

static void TestRefusalsAndBudget(void) {
    SZFriendsNATEndpoint *lan = [SZFriendsNATEndpoint endpointWithHost:@"192.168.1.20" port:5000];
    SZFriendsNATProberConfiguration *c = Side(SZFriendsNATProbeRoleEasy, lan);
    c.loopbackOnly = NO;
    CHECK(RunAlone(c).error.code == SZFriendsNATErrorAddressRefused, "a private address is never probed");
    c = Side(SZFriendsNATProbeRoleEasy, [SZFriendsNATEndpoint endpointWithHost:@"8.8.8.8" port:5000]);
    CHECK(RunAlone(c).error.code == SZFriendsNATErrorAddressRefused, "loopback-only refuses the Internet");
    for (SZFriendsNATEndpoint *own in SZFriendsNATOwnAddresses()) {
        if (own.scope != SZFriendsNATAddressScopeGlobal) continue;
        c = Side(SZFriendsNATProbeRoleEasy, own);
        c.loopbackOnly = NO;
        CHECK(RunAlone(c).error.code == SZFriendsNATErrorAddressRefused, "never this Mac's own address");
        break;
    }
    c = Side(SZFriendsNATProbeRoleEasy, [SZFriendsNATEndpoint endpointWithHost:@"127.0.0.1" port:0]);
    c.localUfrag = @"bad-ufrag";
    CHECK(RunAlone(c).error.code == SZFriendsNATErrorUnsupported, "credentials outside ICE's characters");
    c = Side(SZFriendsNATProbeRoleEasy, [SZFriendsNATEndpoint endpointWithHost:@"127.0.0.1" port:0]);
    c.probeMax = SZFriendsNATProbeMax + 1;
    CHECK(RunAlone(c).error.code == SZFriendsNATErrorUnsupported, "over ADR 0011's probe budget");

    // The cap: 20 probes and no more, wherever they go (a window this test holds, so nothing else receives them).
    uint16_t base = 0;
    NSArray<NSNumber *> *held = SZFTestHoldUDPPortWindow(64, &base);
    c = Side(SZFriendsNATProbeRoleEasy, [SZFriendsNATEndpoint endpointWithHost:@"127.0.0.1" port:0]);
    c.portRangeLow = base;
    c.portRangeHigh = (uint16_t)(base + 63);
    c.probeMax = 20;
    c.duration = 0.6;
    SZFriendsNATProber *capped = [[SZFriendsNATProber alloc] initWithConfiguration:c];
    __block ProbeOutcome outcome = {nil, nil, NO, NO};
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    Start(capped, SZFTestQueue("szf.test.cap"), &outcome, done);
    CHECK(SZFTestWait(done, 3) && capped.probesSent == 20, "probeMax holds (%lu)", (unsigned long)capped.probesSent);
    for (NSNumber *fd in held) close(fd.intValue);

    __block NSTimeInterval now = 0;
    SZFriendsNATProbeBudget *budget = [[SZFriendsNATProbeBudget alloc] initWithInterval:600
                                                                                  clock:^NSTimeInterval {
                                                                                      return now;
                                                                                  }];
    NSData *alice = [@"alice" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *bob = [@"bob" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK([budget beginRunForPeer:alice] && ![budget beginRunForPeer:bob], "one run at a time per helper");
    [budget endRun];
    now = 599;
    CHECK(![budget beginRunForPeer:alice] && [budget beginRunForPeer:bob], "once per peer per 10 minutes");
    [budget endRun];
    now = 600;
    CHECK([budget beginRunForPeer:alice], "ten minutes later");
    [budget endRun];
    c = Side(SZFriendsNATProbeRoleEasy, [SZFriendsNATEndpoint endpointWithHost:@"127.0.0.1" port:0]);
    c.budget = budget;
    c.peer = alice;
    CHECK(RunAlone(c).error.code == SZFriendsNATErrorBudget, "the prober asks the budget first");
}

// The prober aims only at what the peer presented in this attempt, whatever the caller names: nothing is sent
// otherwise, not even to an address that would pass every other rule.
static void TestOnlyPresentedAddresses(void) {
    SZFriendsNATEndpoint *loopback = [SZFriendsNATEndpoint endpointWithHost:@"127.0.0.1" port:40000];
    SZFriendsNATEndpoint *otherPort = [loopback endpointWithPort:40001];
    SZFriendsNATEndpoint *otherAddress = [SZFriendsNATEndpoint endpointWithHost:@"::1" port:40000];
    NSArray *cases = @[
        @[ @(SZFriendsNATProbeRoleEasy), @[] ], @[ @(SZFriendsNATProbeRoleEasy), @[ otherAddress ] ],
        @[ @(SZFriendsNATProbeRoleHard), @[] ], @[ @(SZFriendsNATProbeRoleHard), @[ otherPort, otherAddress ] ],
    ];
    for (NSArray *probeCase in cases) {
        SZFriendsNATProberConfiguration *c = Side((SZFriendsNATProbeRole)[probeCase[0] integerValue], loopback);
        c.presented = probeCase[1];
        c.duration = 0.5;
        SZFriendsNATProber *prober = [[SZFriendsNATProber alloc] initWithConfiguration:c];
        __block ProbeOutcome outcome = {nil, nil, NO, NO};
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        Start(prober, SZFTestQueue("szf.test.presented"), &outcome, done);
        CHECK(SZFTestWait(done, 3) && outcome.error.code == SZFriendsNATErrorAddressRefused && prober.probesSent == 0,
              "role %@, presented %@: %@", probeCase[0], probeCase[1], outcome.error);
    }
    SZFriendsNATProberConfiguration *c = Side(SZFriendsNATProbeRoleEasy, loopback);
    c.presented = nil;
    CHECK(RunAlone(c).error.code == SZFriendsNATErrorAddressRefused, "nothing presented, nothing probed");
    // The easy side probes random ports of a presented address (inside a window this test holds, so nothing else
    // receives them): the presented port does not narrow it.
    uint16_t base = 0;
    NSArray<NSNumber *> *held = SZFTestHoldUDPPortWindow(16, &base);
    c = Side(SZFriendsNATProbeRoleEasy, [loopback endpointWithPort:0]);
    c.presented = @[ otherPort ];
    c.portRangeLow = base;
    c.portRangeHigh = (uint16_t)(base + 15);
    c.probeMax = 5;
    c.duration = 0.3;
    CHECK(held.count == 16 && RunAlone(c).error.code == SZFriendsNATErrorTimedOut, "a presented address is probed");
    for (NSNumber *fd in held) close(fd.intValue);
}

void SZFTestProber(void) {
    TestOnlyPresentedAddresses();
    TestPredictionConnects();
    TestPair(NO);
    TestPair(YES);
    TestWrongCredentialsNeverHit();
    TestRefusalsAndBudget();
}
