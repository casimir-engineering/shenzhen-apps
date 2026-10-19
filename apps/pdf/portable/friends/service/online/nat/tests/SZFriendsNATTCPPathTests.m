// TCP simultaneous open on loopback (crossing SYNs, no listener), with one side late, over IPv4 and IPv6; the ADR
// 0001 Noise IK handshake and a message over the resulting stream; STUN over TCP from the path's own port; the
// candidate rules; and the budget.

#import "SZFriendsNATTestSupport.h"

#import "service/identity/SZFriendsIdentity.h"
#import "service/online/nat/SZFriendsNATPrediction.h"
#import "service/online/nat/SZFriendsNATStun.h"
#import "service/online/nat/SZFriendsNATTCPPath.h"
#import "service/online/nat/SZFriendsNATTCPSidePath.h"

#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <unistd.h>

@interface PathRecorder : NSObject <SZFriendsNATTCPPathDelegate>
@property(nonatomic, strong) NSMutableArray<NSString *> *candidates;
@property(nonatomic, strong) id<SZFriendsByteStream> stream;
@property(nonatomic) BOOL ipv6, gathered;
@property(nonatomic, strong) NSError *error;
@property(nonatomic, strong) dispatch_semaphore_t ended, gathering;
@end

@implementation PathRecorder
- (instancetype)init {
    if ((self = [super init])) {
        _candidates = [NSMutableArray array];
        _ended = dispatch_semaphore_create(0);
        _gathering = dispatch_semaphore_create(0);
    }
    return self;
}
- (void)tcpPath:(SZFriendsNATTCPPath *)path didGatherLocalCandidate:(NSString *)candidate {
    (void)path;
    [_candidates addObject:candidate];
}
- (void)tcpPathDidFinishGathering:(SZFriendsNATTCPPath *)path {
    (void)path;
    _gathered = YES;
    dispatch_semaphore_signal(_gathering);
}
- (void)tcpPath:(SZFriendsNATTCPPath *)path didOpenStream:(id<SZFriendsByteStream>)stream ipv6:(BOOL)ipv6 {
    (void)path;
    _stream = stream;
    _ipv6 = ipv6;
    dispatch_semaphore_signal(_ended);
}
- (void)tcpPath:(SZFriendsNATTCPPath *)path didFailWithError:(NSError *)error {
    (void)path;
    _error = error;
    dispatch_semaphore_signal(_ended);
}
@end

static SZFriendsNATTCPPath *Path(PathRecorder *recorder, dispatch_queue_t queue, SZFriendsOnlinePurpose purpose,
                                 BOOL loopbackOnly) {
    SZFriendsNATTCPPathConfiguration *configuration = [SZFriendsNATTCPPathConfiguration new];
    configuration.purpose = purpose;
    configuration.loopbackOnly = loopbackOnly;
    configuration.budget = 4;
    return [[SZFriendsNATTCPPath alloc] initWithConfiguration:configuration delegate:recorder queue:queue];
}

static NSArray<NSString *> *Candidates(PathRecorder *recorder, dispatch_queue_t queue, sa_family_t family) {
    __block NSArray<NSString *> *lines;
    SZFTestSync(queue, ^{
        lines = [recorder.candidates copy];
    });
    NSMutableArray<NSString *> *matching = [NSMutableArray array];
    for (NSString *line in lines) {
        if ([SZFriendsNATCandidate candidateWithLine:line].endpoint.family == family) [matching addObject:line];
    }
    return matching;
}

static void AddAll(SZFriendsNATTCPPath *path, dispatch_queue_t queue, NSArray<NSString *> *lines) {
    SZFTestSync(queue, ^{
        for (NSString *line in lines) CHECK([path addRemoteCandidate:line error:NULL], "%@", line);
    });
}

// ADR 0001 over the path's stream: Noise IK with the offerer as initiator, then one message each way.
static void RunNoise(id<SZFriendsByteStream> initiatorStream, id<SZFriendsByteStream> responderStream) {
    SZFriendsIdentity *alice = [SZFriendsIdentity identityWithSigningSeed:[NSMutableData dataWithLength:32]
                                                         staticPrivateKey:[NSMutableData dataWithLength:32]];
    NSMutableData *seed = [NSMutableData dataWithLength:32], *staticKey = [NSMutableData dataWithLength:32];
    arc4random_buf(seed.mutableBytes, 32), arc4random_buf(staticKey.mutableBytes, 32);
    SZFriendsIdentity *bob = [SZFriendsIdentity identityWithSigningSeed:seed staticPrivateKey:staticKey];
    SZFriendsHandshakeOptions *options = [SZFriendsHandshakeOptions new];
    options.pattern = SZFriendsHandshakeIK;
    options.route = SZFriendsRouteMethodInternet;
    options.remoteStaticKey = bob.staticPublicKey;
    options.expectedIdentityKey = bob.publicKey;
    dispatch_queue_t queue = SZFTestQueue("szf.test.noise");
    SZFriendsSecureChannel *initiator = [[SZFriendsSecureChannel alloc] initAsInitiatorWithStream:initiatorStream
                                                                                         identity:alice
                                                                                          options:options
                                                                                            queue:queue];
    SZFriendsSecureChannel *responder =
        [[SZFriendsSecureChannel alloc] initAsResponderWithStream:responderStream
                                                         identity:bob
                                                    publicProfile:nil
                                                        keyPolicy:^BOOL(NSData *key, SZFriendsHandshakePattern p,
                                                                        NSData *token) {
                                                            (void)p, (void)token;
                                                            return [key isEqualToData:alice.publicKey];
                                                        }
                                                            queue:queue];
    responder.replayCache = [SZFriendsReplayCache new];
    dispatch_semaphore_t established = dispatch_semaphore_create(0), received = dispatch_semaphore_create(0);
    __block NSString *text = nil;
    initiator.onEstablished = ^{
        dispatch_semaphore_signal(established);
    };
    responder.onFrame = ^(SZFriendsFrame *frame) {
        text = [frame stringForTag:SZFriendsFieldText];
        dispatch_semaphore_signal(received);
    };
    dispatch_sync(queue, ^{
        [responder start];
        [initiator start];
    });
    CHECK(SZFTestWait(established, 5), "Noise IK completes over the simultaneous-open stream");
    SZFriendsFrame *message = [SZFriendsFrame
        frameWithType:SZFriendsFrameTypeMessage
               fields:@{
                   @(SZFriendsFieldID) : [NSMutableData dataWithLength:16],
                   @(SZFriendsFieldSentAt) : [SZFriendsFrame fieldWithUInt64:1760251668000 tag:SZFriendsFieldSentAt],
                   @(SZFriendsFieldText) : [@"over TCP, no relay" dataUsingEncoding:NSUTF8StringEncoding]
               }];
    dispatch_sync(queue, ^{
        CHECK([initiator sendFrame:message]);
    });
    CHECK(SZFTestWait(received, 5) && [text isEqualToString:@"over TCP, no relay"]);
    dispatch_sync(queue, ^{
        [initiator close];
        [responder close];
    });
}

// Two paths on loopback; `lateBy` delays the second side's dialling, as a peer whose signalling arrives later.
static void TestPair(sa_family_t family, NSTimeInterval lateBy, BOOL noise) {
    dispatch_queue_t qa = SZFTestQueue("szf.test.tcp.a"), qb = SZFTestQueue("szf.test.tcp.b");
    PathRecorder *ra = [PathRecorder new], *rb = [PathRecorder new];
    SZFriendsNATTCPPath *a = Path(ra, qa, SZFriendsOnlinePurposeFriend, YES);
    SZFriendsNATTCPPath *b = Path(rb, qb, SZFriendsOnlinePurposeFriend, YES);
    __block BOOL started = NO;
    SZFTestSync(qa, ^{
        started = [a start:NULL];
    });
    SZFTestSync(qb, ^{
        started = started && [b start:NULL];
    });
    CHECK(started && SZFTestWait(ra.gathering, 2) && SZFTestWait(rb.gathering, 2));
    NSArray<NSString *> *fromA = Candidates(ra, qa, family), *fromB = Candidates(rb, qb, family);
    if (fromA.count == 0 || fromB.count == 0) {
        fprintf(stderr, "    skipped: TCP over %s (no loopback address)\n", family == AF_INET6 ? "IPv6" : "IPv4");
        SZFTestSync(qa, ^{ [a close]; });
        SZFTestSync(qb, ^{ [b close]; });
        return;
    }
    NSDate *start = [NSDate date];
    AddAll(a, qa, fromB);
    if (lateBy > 0) usleep((useconds_t)(lateBy * 1e6));
    AddAll(b, qb, fromA);
    CHECK(SZFTestWait(ra.ended, 4) && SZFTestWait(rb.ended, 4) && ra.stream != nil && rb.stream != nil,
          "crossing SYNs connect (%s, late by %.0f ms): %@ %@", family == AF_INET6 ? "IPv6" : "IPv4", lateBy * 1000,
          ra.error, rb.error);
    CHECK(ra.ipv6 == (family == AF_INET6));
    fprintf(stderr, "    %s, late by %3.0f ms: connected after %.0f ms\n", family == AF_INET6 ? "IPv6" : "IPv4",
            lateBy * 1000, -start.timeIntervalSinceNow * 1000);
    if (noise && ra.stream != nil && rb.stream != nil) RunNoise(ra.stream, rb.stream);
    [ra.stream close];
    [rb.stream close];
}

static void TestStunOverTCP(void) {
    __block uint16_t seenPort = 0;
    SZFTestTCPServer *server = [[SZFTestTCPServer alloc] initWithHost:@"127.0.0.1" handler:^(int fd) {
        NSData *request = SZFTestReadSocket(fd, 28, 3); // a plain request with FINGERPRINT
        SZFriendsStunMessage message;
        struct sockaddr_storage peer;
        socklen_t length = sizeof peer;
        getpeername(fd, (struct sockaddr *)&peer, &length);
        seenPort = [SZFriendsNATEndpoint endpointWithSockaddr:(struct sockaddr *)&peer length:length].port;
        if (SZFriendsStunParse(request.bytes, request.length, &message)) {
            uint8_t answer[128];
            size_t answerLength = SZFriendsStunWriteBindingSuccess(answer, sizeof answer, message.transaction,
                                                                   (struct sockaddr *)&peer, NULL, 0);
            write(fd, answer, answerLength / 2); // in two pieces: the framing must reassemble it
            usleep(20 * 1000);
            write(fd, answer + answerLength / 2, answerLength - answerLength / 2);
        }
        SZFTestReadSocket(fd, 1, 3); // the path keeps the connection open while it runs
        close(fd);
    }];
    dispatch_queue_t queue = SZFTestQueue("szf.test.tcpstun");
    PathRecorder *recorder = [PathRecorder new];
    SZFriendsNATTCPPathConfiguration *configuration = [SZFriendsNATTCPPathConfiguration new];
    configuration.loopbackOnly = YES;
    configuration.stunServer = server.endpoint;
    configuration.budget = 3;
    SZFriendsNATTCPPath *path = [[SZFriendsNATTCPPath alloc] initWithConfiguration:configuration
                                                                          delegate:recorder
                                                                             queue:queue];
    SZFTestSync(queue, ^{
        CHECK([path start:NULL]);
    });
    CHECK(SZFTestWait(recorder.gathering, 3));
    __block BOOL sawMapped = NO;
    SZFTestSync(queue, ^{
        for (NSString *line in recorder.candidates) {
            SZFriendsNATCandidate *candidate = [SZFriendsNATCandidate candidateWithLine:line];
            if (candidate.type == SZFriendsNATCandidateTypeServerReflexive && candidate.tcp &&
                candidate.endpoint.port == path.localPort) {
                sawMapped = YES;
            }
        }
    });
    CHECK(sawMapped && seenPort == path.localPort, "STUN over TCP from the path's own port gives its mapped address");
    SZFTestSync(queue, ^{
        [path close];
    });
    [server close];
}

static NSString *InterfaceOf(SZFriendsNATEndpoint *address) {
    struct ifaddrs *list = NULL;
    NSString *name = nil;
    if (getifaddrs(&list) != 0) return nil;
    for (struct ifaddrs *entry = list; entry != NULL && name == nil; entry = entry->ifa_next) {
        if (entry->ifa_addr == NULL) continue;
        BOOL v4 = entry->ifa_addr->sa_family == AF_INET;
        socklen_t length = v4 ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6);
        SZFriendsNATEndpoint *own = [SZFriendsNATEndpoint endpointWithSockaddr:entry->ifa_addr length:length];
        if ([own hasSameAddressAs:address]) name = @(entry->ifa_name);
    }
    freeifaddrs(list);
    return name;
}

// Gathering on this Mac's real interfaces and routing table (nothing is sent): never a tunnel's, loopback or
// link-local address, nor any address of a family whose route a tunnel holds (on the owner's Mac, utun4 holds both
// and en0 has global IPv6 addresses); private addresses for friends only. Then what a path refuses to dial.
static void TestCandidateRules(void) {
    SZFriendsOnlineDefaultRoutes live = SZFriendsNATReadDefaultRoutes();
    for (NSNumber *purpose in @[ @(SZFriendsOnlinePurposeFriend), @(SZFriendsOnlinePurposeFirstContact) ]) {
        dispatch_queue_t queue = SZFTestQueue("szf.test.rules");
        PathRecorder *recorder = [PathRecorder new];
        SZFriendsNATTCPPath *path = Path(recorder, queue, (SZFriendsOnlinePurpose)purpose.integerValue, NO);
        SZFTestSync(queue, ^{
            CHECK([path start:NULL]);
        });
        CHECK(SZFTestWait(recorder.gathering, 2), "no STUN server: gathering ends at once");
        SZFTestSync(queue, ^{
            for (NSString *line in recorder.candidates) {
                SZFriendsNATEndpoint *endpoint = [SZFriendsNATCandidate candidateWithLine:line].endpoint;
                NSString *interface = InterfaceOf(endpoint);
                CHECK(SZFriendsOnlineMayOfferHostCandidate(interface.UTF8String, endpoint.family == AF_INET6, &live),
                      "%@ on %@ (routes: %s, %s)", line, interface, live.ipv4, live.ipv6);
                CHECK(endpoint.scope == SZFriendsNATAddressScopeGlobal ||
                          (endpoint.scope == SZFriendsNATAddressScopePrivate &&
                           purpose.integerValue == SZFriendsOnlinePurposeFriend), "%@", line);
                CHECK(endpoint.port == path.localPort && [line hasSuffix:@"tcptype so"]);
            }
            NSError *error = nil;
            NSString *privateLine = @"candidate:1 1 TCP 2130706431 192.168.77.5 40000 typ host tcptype so";
            if (purpose.integerValue == SZFriendsOnlinePurposeFirstContact) {
                CHECK(![path addRemoteCandidate:privateLine error:&error], "no private addresses with a first contact");
                CHECK(error.code == SZFriendsNATErrorAddressRefused);
            }
            for (NSString *bad in @[ @"candidate:1 1 UDP 2130706431 8.8.8.8 40000 typ host",
                                     @"candidate:1 1 TCP 2130706431 8.8.8.8 40000 typ host",
                                     @"candidate:1 1 TCP 2130706431 127.0.0.1 40000 typ host tcptype so",
                                     @"candidate:1 1 TCP 2130706431 fe80::1 40000 typ host tcptype so",
                                     @"candidate:1 1 TCP 2130706431 224.0.0.1 40000 typ host tcptype so" ]) {
                CHECK(![path addRemoteCandidate:bad error:NULL], "%@ refused", bad);
            }
            [path close];
        });
    }
    dispatch_queue_t linkQueue = SZFTestQueue("szf.test.link");
    SZFriendsNATTCPPath *link = Path([PathRecorder new], linkQueue, SZFriendsOnlinePurposeLink, YES);
    NSError *error = nil;
    CHECK(![link start:&error] && error.code == SZFriendsNATErrorUnsupported, "download links have no TCP path");
}

// The host addresses a path offers, over an injected interface table and injected routes (lead decision 9).
static void TestHostAddressesFollowTheDefaultRoute(void) {
    enum { kEntries = 10 };
    const char *names[kEntries] = {"lo0", "lo0", "en0", "en0", "en7", "en1", "utun4", "utun4", "bridge100", "feth1"};
    const char *addresses[kEntries] = {"127.0.0.1", "::1", "192.168.1.10", "240e:1::5", "2409:8a00::7",
                                       "240e:2::1", "198.18.0.1", "fd00::1", "192.168.2.1", "10.147.17.1"};
    struct ifaddrs entries[kEntries];
    struct sockaddr_storage storage[kEntries];
    memset(entries, 0, sizeof entries);
    for (int i = 0; i < kEntries; i++) {
        [[SZFriendsNATEndpoint endpointWithHost:@(addresses[i]) port:0] getSockaddr:&storage[i]];
        entries[i].ifa_name = (char *)names[i];
        entries[i].ifa_addr = (struct sockaddr *)&storage[i];
        entries[i].ifa_flags = strcmp(names[i], "en1") == 0 ? 0 : IFF_UP; // en1 is down
        entries[i].ifa_next = i + 1 < kEntries ? &entries[i + 1] : NULL;
    }
    const struct ifaddrs *table = entries;
    NSString *(^offered)(SZFriendsOnlinePurpose, SZFriendsOnlineDefaultRoutes, BOOL) =
        ^NSString *(SZFriendsOnlinePurpose purpose, SZFriendsOnlineDefaultRoutes routes, BOOL loopbackOnly) {
            NSMutableArray<NSString *> *hosts = [NSMutableArray array];
            for (SZFriendsNATEndpoint *address in SZFriendsNATTCPHostAddresses(table, purpose, &routes,
                                                                               loopbackOnly)) {
                [hosts addObject:address.host];
            }
            return [hosts componentsJoinedByString:@" "];
        };
    const SZFriendsOnlinePurpose friend = SZFriendsOnlinePurposeFriend;
    const SZFriendsOnlinePurpose contact = SZFriendsOnlinePurposeFirstContact;
    const SZFriendsOnlineDefaultRoutes lan = SZFriendsOnlineDefaultRoutesMake("en0", "en0");
    const SZFriendsOnlineDefaultRoutes tunnel = SZFriendsOnlineDefaultRoutesMake("utun4", "utun4");
    const SZFriendsOnlineDefaultRoutes ipv4Tunnel = SZFriendsOnlineDefaultRoutesMake("utun4", "en0");
    CHECK([offered(friend, lan, NO) isEqualToString:@"192.168.1.10 240e:1::5 2409:8a00::7"], "%@",
          offered(friend, lan, NO));
    CHECK([offered(contact, lan, NO) isEqualToString:@"240e:1::5 2409:8a00::7"], "%@", offered(contact, lan, NO));
    CHECK(offered(friend, tunnel, NO).length == 0, "utun4 holds both routes: %@", offered(friend, tunnel, NO));
    CHECK([offered(friend, ipv4Tunnel, NO) isEqualToString:@"240e:1::5 2409:8a00::7"], "%@",
          offered(friend, ipv4Tunnel, NO));
    CHECK([offered(friend, tunnel, YES) isEqualToString:@"127.0.0.1 ::1"], "loopback-only: %@",
          offered(friend, tunnel, YES));
    CHECK(SZFriendsNATTCPHostAddresses(NULL, friend, &lan, NO).count == 0);
}

static void TestBudgetAndSelf(void) {
    dispatch_queue_t queue = SZFTestQueue("szf.test.budget");
    PathRecorder *recorder = [PathRecorder new];
    SZFriendsNATTCPPathConfiguration *configuration = [SZFriendsNATTCPPathConfiguration new];
    configuration.loopbackOnly = YES;
    configuration.budget = 1;
    SZFriendsNATTCPPath *path = [[SZFriendsNATTCPPath alloc] initWithConfiguration:configuration
                                                                          delegate:recorder
                                                                             queue:queue];
    SZFTestTCPServer *closed = [[SZFTestTCPServer alloc] initWithHost:@"127.0.0.1" handler:^(int fd) {
        close(fd);
    }];
    SZFriendsNATEndpoint *nobody = closed.endpoint;
    [closed close]; // nothing calls from there: every SYN is refused
    NSDate *start = [NSDate date];
    SZFTestSync(queue, ^{
        CHECK([path start:NULL]);
        NSString *own = SZFriendsNATCandidateLine([nobody endpointWithPort:path.localPort],
                                                  SZFriendsNATCandidateTypeHost, YES, 1);
        CHECK(![path addRemoteCandidate:own error:NULL], "never a connection to its own port");
        CHECK([path addRemoteCandidate:SZFriendsNATCandidateLine(nobody, SZFriendsNATCandidateTypeHost, YES, 1)
                                 error:NULL]);
    });
    CHECK(SZFTestWait(recorder.ended, 3) && recorder.error.code == SZFriendsNATErrorTimedOut && recorder.stream == nil);
    NSTimeInterval elapsed = -start.timeIntervalSinceNow;
    CHECK(elapsed > 0.9 && elapsed < 1.5, "the budget ends it (%.2f s)", elapsed);
}

@interface SideRequest : NSObject <SZFriendsOnlineConnectionRequest>
@property(nonatomic) SZFriendsOnlinePurpose purpose;
@property(nonatomic) SZFriendsOnlineRole role;
@property(nonatomic) SZFriendsOnlineConnectionKind kind;
@property(nonatomic, copy) NSData *peer;
@property(nonatomic, copy, nullable) NSString *stunURI;
@property(nonatomic, nullable) id<SZFriendsOnlineRelayCredentials> relay;
@property(nonatomic) uint16_t localPort;
@property(nonatomic, copy, nullable) NSString *remoteOfferSDP;
@property(nonatomic, copy, nullable) NSData *remoteFingerprint;
@end
@implementation SideRequest
@end

@interface SideEvents : NSObject <SZFriendsOnlineSidePathEvents>
@property(nonatomic, strong) NSMutableArray<NSString *> *candidates;
@property(nonatomic, strong) id<SZFriendsByteStream> stream;
@property(nonatomic) NSUInteger failures;
@property(nonatomic, strong) dispatch_semaphore_t opened, failed;
@end
@implementation SideEvents
- (instancetype)init {
    if ((self = [super init])) {
        _candidates = [NSMutableArray array];
        _opened = dispatch_semaphore_create(0);
        _failed = dispatch_semaphore_create(0);
    }
    return self;
}
- (void)sidePath:(id<SZFriendsOnlineSidePath>)path didGatherLocalCandidate:(NSString *)candidate {
    (void)path;
    [_candidates addObject:candidate];
}
- (void)sidePath:(id<SZFriendsOnlineSidePath>)path didOpenStream:(id<SZFriendsByteStream>)stream ipv6:(BOOL)ipv6 {
    (void)path, (void)ipv6;
    _stream = stream;
    dispatch_semaphore_signal(_opened);
}
- (void)sidePath:(id<SZFriendsOnlineSidePath>)path didFailWithError:(NSError *)error {
    (void)path, (void)error;
    _failures++;
    dispatch_semaphore_signal(_failed);
}
@end

// The path behind the transport's side-path seam: what the helper's sidePathFactory hands each direct connection.
static void TestSidePath(void) {
    SideRequest *request = [SideRequest new];
    request.purpose = SZFriendsOnlinePurposeLink;
    request.kind = SZFriendsOnlineConnectionDirect;
    CHECK([SZFriendsNATTCPSidePath sidePathForRequest:request stunServer:nil loopbackOnly:YES] == nil, "no links");
    request.purpose = SZFriendsOnlinePurposeFriend;
    request.kind = SZFriendsOnlineConnectionRelay;
    CHECK([SZFriendsNATTCPSidePath sidePathForRequest:request stunServer:nil loopbackOnly:YES] == nil, "no relays");
    request.kind = SZFriendsOnlineConnectionDirect;
    SZFriendsNATTCPSidePath *a = [SZFriendsNATTCPSidePath sidePathForRequest:request stunServer:nil loopbackOnly:YES];
    SZFriendsNATTCPSidePath *b = [SZFriendsNATTCPSidePath sidePathForRequest:request stunServer:nil loopbackOnly:YES];
    CHECK(a.configuration.budget == 5, "the direct phase's plain budget");
    SideEvents *ea = [SideEvents new], *eb = [SideEvents new];
    dispatch_queue_t qa = SZFTestQueue("szf.test.side.a"), qb = SZFTestQueue("szf.test.side.b");
    SZFTestSync(qa, ^{ [a startWithQueue:qa events:ea]; });
    SZFTestSync(qb, ^{ [b startWithQueue:qb events:eb]; });
    usleep(100 * 1000);
    __block NSArray<NSString *> *fromA, *fromB;
    SZFTestSync(qa, ^{ fromA = [ea.candidates copy]; });
    SZFTestSync(qb, ^{ fromB = [eb.candidates copy]; });
    CHECK(fromA.count > 0 && fromB.count > 0);
    SZFTestSync(qa, ^{
        for (NSString *line in fromB) [a addRemoteCandidate:line error:NULL];
    });
    SZFTestSync(qb, ^{
        for (NSString *line in fromA) [b addRemoteCandidate:line error:NULL];
    });
    CHECK(SZFTestWait(ea.opened, 3) && SZFTestWait(eb.opened, 3), "both sides get the stream through the seam");
    SZFTestSync(qa, ^{
        [ea.stream startWithQueue:qa];
        [ea.stream close];
    });
    CHECK(SZFTestWait(ea.failed, 3) && ea.failures == 1, "a stream that ended ends the side path");
    SZFTestSync(qa, ^{ [a close]; });
    SZFTestSync(qb, ^{ [b close]; });
}

void SZFTestTCPPath(void) {
    TestPair(AF_INET, 0, YES);
    TestPair(AF_INET, 0.3, NO);
    TestPair(AF_INET6, 0, NO);
    TestPair(AF_INET6, 1.2, NO);
    TestStunOverTCP();
    TestCandidateRules();
    TestHostAddressesFollowTheDefaultRoute();
    TestBudgetAndSelf();
    TestSidePath();
}
