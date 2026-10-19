// friends-driver-check: the hard-NAT step through the driver (the prober aimed only at what the signalling
// presented, then a probe handover connection on both sides), and network changes (debounced, acting only when the
// default routes moved). Transports are fakes; the probers are real, on 127.0.0.1 ports the test holds.

#import "SZFODriverTestSupport.h"

#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#import "service/online/nat/SZFriendsNATClassifier.h"
#import "service/online/nat/SZFriendsNATProber.h"

@interface SZFriendsOnlineContext (SZFODNetworkTests)
@property(nonatomic, readonly) SZFriendsNATClassCache *classCache; // its ivar, through key-value coding
@end

@interface SZFriendsOnlineDriver (SZFODNetworkTests)
- (BOOL)backedOff:(NSData *)identityKey;
@end

enum { kProbePorts = 16 };

static SZFODWorld *FakeWorld(void) {
    return [[SZFODWorld alloc] initWithTransportFactory:^id<SZFriendsOnlineTransport> {
        return [SZFODFakeTransport new];
    }];
}

static void SetNATClass(SZFriendsOnlineDriver *driver, int32_t step) {
    SZFriendsNATEndpoint *primary = [SZFriendsNATEndpoint endpointWithHost:@"203.0.113.7" port:40000];
    SZFriendsNATEndpoint *secondary = [primary endpointWithPort:(uint16_t)(40000 + step)];
    SZFriendsNATClassCache *cache = [driver.onlineContext valueForKey:@"classCache"];
    [cache setClassification:[SZFriendsNATClassification classificationWithPrimary:primary secondary:secondary]
                  forNetwork:@"loopback"];
}

// A window of consecutive free UDP ports on 127.0.0.1, found by binding them all, then released for the hard prober.
static uint16_t FreePortWindow(NSUInteger count) {
    for (int round = 0; round < 50; round++) {
        uint16_t base = (uint16_t)(20000 + arc4random_uniform(20000)); // below the ephemeral range
        int sockets[kProbePorts];
        NSUInteger bound = 0;
        for (; bound < count; bound++) {
            sockets[bound] = socket(AF_INET, SOCK_DGRAM, 0);
            struct sockaddr_in address = {.sin_len = sizeof address, .sin_family = AF_INET,
                                          .sin_port = htons((uint16_t)(base + bound)),
                                          .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
            if (sockets[bound] < 0 || bind(sockets[bound], (struct sockaddr *)&address, sizeof address) != 0) break;
        }
        for (NSUInteger i = 0; i <= bound && i < count; i++) {
            if (sockets[i] >= 0) close(sockets[i]);
        }
        if (bound == count) return base;
    }
    return 0;
}

static BOOL OpenedProbeHandover(SZFODFakeTransport *transport) {
    for (id<SZFriendsOnlineConnectionRequest> request in transport.requests) {
        if (request.kind == SZFriendsOnlineConnectionProbeHandover) return YES;
    }
    return NO;
}

// 7b-C1: the driver must hand the prober what the peer presented, or the prober refuses (AddressRefused) and the
// hard-NAT step never runs.
void SZFODTestProbing(void) {
    SZFODWorld *world = FakeWorld();
    [world befriend];
    uint16_t base = FreePortWindow(kProbePorts);
    EXPECT(base != 0, "a free window of loopback ports");
    if (base == 0) return;
    NSMutableArray<SZFriendsNATProberConfiguration *> *configurations = [NSMutableArray array];
    id (^factory)(id) = ^id(SZFriendsNATProberConfiguration *configuration) {
        [configurations addObject:configuration];
        // Both probers share this process: each gets its own budget. Probes stay inside the held window.
        configuration.budget = [[SZFriendsNATProbeBudget alloc] initWithInterval:600 clock:nil];
        NSMutableArray<NSNumber *> *ports = [NSMutableArray array];
        for (NSUInteger i = 0; i < kProbePorts; i++) [ports addObject:@(base + i)];
        configuration.localPorts = ports;
        configuration.socketCount = kProbePorts;
        configuration.portRangeLow = base;
        configuration.portRangeHigh = (uint16_t)(base + kProbePorts - 1);
        return [[SZFriendsNATProber alloc] initWithConfiguration:configuration];
    };
    world.a.onlineContext.proberFactory = factory;
    world.b.onlineContext.proberFactory = factory;
    SetNATClass(world.a, 0);    // A maps independently: the easy side
    SetNATClass(world.b, 1000); // B maps per destination, unpredictably: the hard side
    [world.a reachFriend:world.identityB.publicKey];
    __block SZFriendsOnlineAttempt *offerer = nil, *answerer = nil;
    EXPECT(SZFODWaitUntil(5, ^BOOL {
               offerer = world.a.attempts.firstObject;
               answerer = world.b.attempts.firstObject;
               return offerer.answered && offerer->_direct.remoteReady && answerer != nil;
           }),
           "the friends' attempts meet");
    if (offerer == nil || answerer == nil) return;
    // B's direct candidate as its signalling would carry it: the public address the easy prober aims at.
    NSString *line = [NSString stringWithFormat:@"candidate:1 1 UDP 1694498815 127.0.0.1 %u typ srflx raddr 0.0.0.0 "
                                                 @"rport 0",
                                                 (unsigned)base];
    [offerer applyRemoteCandidate:[SZFriendsSignalItem candidateWithConnection:offerer->_direct.number
                                                                     technique:SZFriendsOnlineTechniqueServerReflexive
                                                                          line:line]
                           toSlot:offerer->_direct];
    EXPECT(offerer->_direct.remoteEndpoints.count == 1, "the presented candidate is remembered");
    [answerer startProbing];
    [offerer startProbing];
    SZFODFakeTransport *fakeA = (SZFODFakeTransport *)world.a.onlineContext.transport;
    SZFODFakeTransport *fakeB = (SZFODFakeTransport *)world.b.onlineContext.transport;
    EXPECT(SZFODWaitUntil(10, ^BOOL { return OpenedProbeHandover(fakeA) && OpenedProbeHandover(fakeB); }),
           "a probe handover connection on both sides: %@ %@", offerer->_probeHit, answerer->_probeHit);
    EXPECT(configurations.count == 2, "both sides probed: %lu", (unsigned long)configurations.count);
    for (SZFriendsNATProberConfiguration *configuration in configurations) {
        EXPECT(configuration.presented.count == 1 &&
                   (configuration.role == SZFriendsNATProbeRoleEasy
                        ? configuration.presented[0].port == base
                        : [configuration.presented[0] isEqual:configuration.remote]),
               "only what the signalling presented: %@", configuration.presented);
    }
    [world stop];
}

// 7b-C1: VPN or second-interface churn must not end every friend's backoff; a real move must, once per burst.
void SZFODTestNetworkChange(void) {
    SZFODWorld *world = FakeWorld();
    world.delegateA.friends[world.identityB.publicKey] = SZFODFriendFor(world.identityB, SZFODRandom(32));
    __block NSString *signature = @"en0|192.168.1.1|192.168.1.20 none";
    world.a.testNetworkSignature = ^NSString * { return signature; };
    [world.a watchNetwork];
    // B does not hold A: the attempt goes unanswered and A backs off.
    [world.a reachFriend:world.identityB.publicKey];
    EXPECT(SZFODWaitUntil(2, ^BOOL { return world.sids.count == 1 && world.sids[0][1].closed; }));
    SZFriendsOnlineContext *context = world.a.onlineContext;
    NSTimeInterval later = context.clock() + SZFriendsOnlineAnswerTimeout + 1;
    context.clock = ^NSTimeInterval { return later; };
    [world.a.attempts.firstObject fireTimers];
    NSData *peer = world.identityB.publicKey;
    EXPECT([world.a backedOff:peer], "unanswered: backed off");
    NSUInteger calls = world.delegateA.availabilityCalls;

    for (int i = 0; i < 3; i++) {
        [world.a scheduleNetworkChange];
        SZFODSpin(0.3);
    }
    SZFODSpin(1.2);
    EXPECT([world.a backedOff:peer] && world.delegateA.availabilityCalls == calls,
           "notifications with the same default route change nothing");

    signature = @"en0|10.0.0.1|10.0.0.20 none";
    for (int i = 0; i < 3; i++) {
        [world.a scheduleNetworkChange];
        SZFODSpin(0.6); // closer together than the settle time: one burst, though it lasts longer than 1 s
    }
    EXPECT(world.delegateA.availabilityCalls == calls, "nothing while the burst goes on");
    SZFODSpin(1.0);
    EXPECT(![world.a backedOff:peer] && world.delegateA.availabilityCalls == calls + 1,
           "a new default route: one change, backoffs end (%lu calls)",
           (unsigned long)(world.delegateA.availabilityCalls - calls));
    [world stop];
}
