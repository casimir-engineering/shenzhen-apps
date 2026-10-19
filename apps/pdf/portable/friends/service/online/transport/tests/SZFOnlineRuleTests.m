// The transport's pure rules: candidate parsing and the filters on what is offered and dialled, technique naming,
// and the direct-phase timer on a scripted clock. No peer connection is made here.

#import "SZFOnlineTestSupport.h"

#include <arpa/inet.h>
#include <ifaddrs.h>

static SZFriendsOnlineCandidate *C(NSString *line) {
    return [SZFriendsOnlineCandidate candidateWithLine:line];
}

static NSString *Host(NSString *address) {
    return [NSString stringWithFormat:@"candidate:1 1 UDP 2122317823 %@ 54321 typ host", address];
}

static void TestParsing(void) {
    SZFriendsOnlineCandidate *host = C(@"a=candidate:1 1 udp 2122317823 192.168.1.10 54321 typ host generation 0");
    SZFO_CHECK(host != nil && host.type == SZFriendsOnlineCandidateHost && host.port == 54321 && !host.tcp);
    SZFO_CHECK([host.line isEqualToString:@"candidate:1 1 UDP 2122317823 192.168.1.10 54321 typ host"], "%@",
               host.line);
    SZFO_CHECK([host.endpoint isEqualToString:@"UDP 192.168.1.10 54321"]);

    // The related address is the local base: it never travels on, so a reflexive candidate cannot leak it.
    SZFriendsOnlineCandidate *srflx =
        C(@"candidate:2 1 UDP 1686052607 203.0.113.5 40000 typ srflx raddr 192.168.1.10 rport 54321");
    SZFO_CHECK(srflx.type == SZFriendsOnlineCandidateServerReflexive && srflx.relatedPort == 54321);
    SZFO_CHECK(![srflx.line containsString:@"192.168"] && ![srflx.line containsString:@"raddr"], "%@", srflx.line);

    SZFriendsOnlineCandidate *v6 = C(@"candidate:3 1 UDP 1 2001:DB8:0:0::1 9000 typ host");
    SZFO_CHECK(v6.ipv6 && [v6.address isEqualToString:@"2001:db8::1"], "canonical numeric form: %@", v6.address);
    SZFriendsOnlineCandidate *tcp = C(@"candidate:4 1 TCP 1 2001:db8::1 9000 typ host tcptype so");
    SZFO_CHECK(tcp.tcp && [tcp.line hasSuffix:@" typ host tcptype so"]);

    NSArray<NSString *> *refused = @[
        @"candidate:1 2 UDP 1 192.168.1.10 5000 typ host",           // RTCP component
        @"candidate:1 1 UDP 1 192.168.1.10 0 typ host",              // port 0
        @"candidate:1 1 UDP 1 192.168.1.10 65536 typ host",          // port overflow
        @"candidate:1 1 UDP 1 192.168.1.10 54x21 typ host",          // not a number
        @"candidate:1 1 UDP 4294967296 192.168.1.10 5000 typ host",  // priority overflow
        @"candidate:1 1 UDP 1 3b1c-41.local 5000 typ host",          // a browser's mDNS name
        @"candidate:1 1 UDP 1 relay.example 5000 typ relay",         // a DNS name
        @"candidate:1 1 UDP 1 fe80::1%en0 5000 typ host",            // a scope
        @"candidate:1 1 UDP 1 192.168.1.10 5000 typ magic",          // unknown type
        @"candidate:1 1 UDP 1 192.168.1.10 5000 kind host",          // no typ
        @"candidate:1 1 UDP 1 192.168.1.10 5000 typ host raddr",     // dangling extension
        @"candidate:1 1 SCTP 1 192.168.1.10 5000 typ host",          // transport
        @"candidate:1 1 TCP 1 192.168.1.10 9 typ host",              // TCP without tcptype
        @"candidate:1 1 TCP 1 192.168.1.10 9 typ host tcptype active", // libjuice's own, which never pairs helpers
        @"candidate:1 1 UDP 1 192.168.1.10 5000 typ host tcptype so", // tcptype on UDP
        @"candidate:a-b 1 UDP 1 192.168.1.10 5000 typ host",         // foundation characters
        @"candidate:123456789012345678901234567890123 1 UDP 1 192.168.1.10 5000 typ host", // foundation length
        @"cand:1 1 UDP 1 192.168.1.10 5000 typ host", @"",
        [@"candidate:1 1 UDP 1 10.0.0.1 5000 typ host x " stringByPaddingToLength:600
                                                                         withString:@"y"
                                                                    startingAtIndex:0],
    ];
    for (NSString *line in refused) SZFO_CHECK(C(line) == nil, "refused: %@", line);
}

static void TestAddressClasses(void) {
    NSDictionary<NSString *, NSNumber *> *expected = @{
        @"127.0.0.1" : @(SZFriendsOnlineAddressLoopback), @"::1" : @(SZFriendsOnlineAddressLoopback),
        @"10.1.2.3" : @(SZFriendsOnlineAddressPrivate), @"172.16.0.1" : @(SZFriendsOnlineAddressPrivate),
        @"172.31.255.1" : @(SZFriendsOnlineAddressPrivate), @"172.32.0.1" : @(SZFriendsOnlineAddressPublicIPv4),
        @"192.168.0.1" : @(SZFriendsOnlineAddressPrivate), @"100.64.0.1" : @(SZFriendsOnlineAddressPrivate),
        @"100.128.0.1" : @(SZFriendsOnlineAddressPublicIPv4), @"8.8.8.8" : @(SZFriendsOnlineAddressPublicIPv4),
        @"169.254.1.1" : @(SZFriendsOnlineAddressUnusable), @"224.0.0.251" : @(SZFriendsOnlineAddressUnusable),
        @"255.255.255.255" : @(SZFriendsOnlineAddressUnusable), @"0.0.0.0" : @(SZFriendsOnlineAddressUnusable),
        @"2001:db8::1" : @(SZFriendsOnlineAddressGlobalIPv6), @"240e:1::1" : @(SZFriendsOnlineAddressGlobalIPv6),
        @"fd00::1" : @(SZFriendsOnlineAddressPrivate), @"fe80::1" : @(SZFriendsOnlineAddressUnusable),
        @"ff02::fb" : @(SZFriendsOnlineAddressUnusable), @"::" : @(SZFriendsOnlineAddressUnusable),
        @"::ffff:127.0.0.1" : @(SZFriendsOnlineAddressUnusable), @"::ffff:10.0.0.1" : @(SZFriendsOnlineAddressUnusable),
        @"64:ff9b::7f00:1" : @(SZFriendsOnlineAddressUnusable), @"fec0::1" : @(SZFriendsOnlineAddressUnusable),
        @"host.example" : @(SZFriendsOnlineAddressUnusable),
    };
    [expected enumerateKeysAndObjectsUsingBlock:^(NSString *address, NSNumber *addressClass, BOOL *stop) {
        (void)stop;
        SZFO_CHECK(SZFriendsOnlineClassifyAddress(address) == addressClass.integerValue, "%@", address);
    }];
}

static SZFriendsOnlineTechnique Local(NSString *line, SZFriendsOnlinePurpose purpose,
                                      SZFriendsOnlineConnectionKind kind, const char *interface, BOOL loopback) {
    return SZFriendsOnlineLocalCandidateTechnique(C(line), purpose, kind, interface, loopback);
}

static void TestLocalCandidates(void) {
    const SZFriendsOnlineConnectionKind direct = SZFriendsOnlineConnectionDirect;
    const SZFriendsOnlinePurpose friend = SZFriendsOnlinePurposeFriend;
    const SZFriendsOnlinePurpose contact = SZFriendsOnlinePurposeFirstContact;
    const SZFriendsOnlinePurpose link = SZFriendsOnlinePurposeLink;
    // Private addresses go to friends only: never to an accepted stranger or whoever holds a link (lead decision).
    SZFO_CHECK(Local(Host(@"192.168.1.10"), friend, direct, "en0", NO) == SZFriendsOnlineTechniqueHostPrivate);
    SZFO_CHECK(Local(Host(@"192.168.1.10"), contact, direct, "en0", NO) == SZFriendsOnlineTechniqueNone);
    SZFO_CHECK(Local(Host(@"192.168.1.10"), link, direct, "en0", NO) == SZFriendsOnlineTechniqueNone);
    SZFO_CHECK(Local(Host(@"fd12::1"), contact, direct, "en0", NO) == SZFriendsOnlineTechniqueNone, "ULA");
    SZFO_CHECK(Local(Host(@"8.8.8.8"), link, direct, "en0", NO) == SZFriendsOnlineTechniqueNone,
               "links offer global IPv6 host addresses only");
    for (SZFriendsOnlinePurpose purpose = friend; purpose <= link; purpose++) {
        SZFO_CHECK(Local(Host(@"240e:1::5"), purpose, direct, "en0", NO) == SZFriendsOnlineTechniqueHostIPv6);
        // utun4 held the default route on the owner's Mac (NAT spike): a tunnel's addresses are never offered.
        SZFO_CHECK(Local(Host(@"240e:1::5"), purpose, direct, "utun4", NO) == SZFriendsOnlineTechniqueNone);
        SZFO_CHECK(Local(Host(@"240e:1::5"), purpose, direct, NULL, NO) == SZFriendsOnlineTechniqueNone);
        SZFO_CHECK(Local(Host(@"fe80::1"), purpose, direct, "en0", NO) == SZFriendsOnlineTechniqueNone);
        SZFO_CHECK(Local(@"candidate:2 1 UDP 1 203.0.113.5 4000 typ srflx raddr 10.0.0.2 rport 5000", purpose,
                         direct, NULL, NO) == SZFriendsOnlineTechniqueServerReflexive);
        SZFO_CHECK(Local(@"candidate:5 1 UDP 1 203.0.113.9 4000 typ relay", purpose, direct, NULL, NO) ==
                   SZFriendsOnlineTechniqueNone, "a direct connection sends no relay candidate");
    }
    SZFO_CHECK(Local(Host(@"172.19.0.1"), friend, direct, "utun4", NO) == SZFriendsOnlineTechniqueNone, "a VPN's");
    SZFO_CHECK(Local(@"candidate:2 1 UDP 1 10.9.0.1 4000 typ srflx", link, direct, NULL, NO) ==
               SZFriendsOnlineTechniqueNone, "a private reflexive address is still private");
    // Loopback only under the testing configuration, whatever its interface.
    SZFO_CHECK(Local(Host(@"127.0.0.1"), friend, direct, "lo0", NO) == SZFriendsOnlineTechniqueNone);
    SZFO_CHECK(Local(Host(@"127.0.0.1"), friend, direct, "lo0", YES) == SZFriendsOnlineTechniqueHostPrivate);
    // A relay connection offers relay candidates only.
    const SZFriendsOnlineConnectionKind relay = SZFriendsOnlineConnectionRelay;
    SZFO_CHECK(Local(@"candidate:5 1 UDP 1 203.0.113.9 4000 typ relay", link, relay, NULL, NO) ==
               SZFriendsOnlineTechniqueRelay);
    SZFO_CHECK(Local(Host(@"240e:1::5"), friend, relay, "en0", NO) == SZFriendsOnlineTechniqueNone);
    SZFO_CHECK(Local(@"candidate:2 1 UDP 1 203.0.113.5 4000 typ srflx", friend, relay, NULL, NO) ==
               SZFriendsOnlineTechniqueNone);
    // TCP simultaneous-open endpoints belong to direct connections.
    NSString *so = @"candidate:9 1 TCP 1 240e:1::5 9000 typ host tcptype so";
    SZFO_CHECK(Local(so, link, direct, "en0", NO) == SZFriendsOnlineTechniqueTCPSimultaneousOpen);
    SZFO_CHECK(Local(so, friend, relay, "en0", NO) == SZFriendsOnlineTechniqueNone);
    SZFO_CHECK(Local(so, friend, SZFriendsOnlineConnectionProbeHandover, "en0", NO) == SZFriendsOnlineTechniqueNone);
    // The frozen header's helper says the same.
    SZFO_CHECK(!SZFriendsOnlineMayUsePrivateAddresses(contact) && SZFriendsOnlineMayUsePrivateAddresses(friend));
}

// Lead decision 9 over injected interface and route tables: while a tunnel holds a family's route toward the
// Internet, no other interface's address of that family is offered. Then the same rule on this Mac's own tables.
static void TestHostCandidatesFollowTheDefaultRoute(void) {
    enum { kEntries = 5 };
    const char *names[kEntries] = {"lo0", "en0", "en0", "utun4", "utun4"};
    const char *addresses[kEntries] = {"127.0.0.1", "192.168.1.10", "240e:1::5", "198.18.0.1", "fd00::1"};
    struct ifaddrs entries[kEntries];
    struct sockaddr_storage storage[kEntries];
    memset(entries, 0, sizeof entries);
    memset(storage, 0, sizeof storage);
    for (int i = 0; i < kEntries; i++) {
        struct sockaddr_in *in = (struct sockaddr_in *)&storage[i];
        struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)&storage[i];
        if (inet_pton(AF_INET, addresses[i], &in->sin_addr) == 1) {
            in->sin_family = AF_INET;
            in->sin_len = sizeof *in;
        } else if (inet_pton(AF_INET6, addresses[i], &in6->sin6_addr) == 1) {
            in6->sin6_family = AF_INET6;
            in6->sin6_len = sizeof *in6;
        }
        entries[i].ifa_name = (char *)names[i];
        entries[i].ifa_addr = (struct sockaddr *)&storage[i];
        entries[i].ifa_next = i + 1 < kEntries ? &entries[i + 1] : NULL;
    }
    const SZFriendsOnlineDefaultRoutes lan = SZFriendsOnlineDefaultRoutesMake("en0", "en0");
    const SZFriendsOnlineDefaultRoutes tunnel = SZFriendsOnlineDefaultRoutesMake("utun4", "utun4");
    const SZFriendsOnlineDefaultRoutes ipv4Tunnel = SZFriendsOnlineDefaultRoutesMake("utun4", "en0");
    const struct ifaddrs *table = entries;
    NSString *(^offeredFrom)(NSString *, SZFriendsOnlineDefaultRoutes) =
        ^NSString *(NSString *address, SZFriendsOnlineDefaultRoutes routes) {
            return SZFriendsOnlineOfferingInterfaceForAddress(address, table, &routes);
        };
    SZFO_CHECK([offeredFrom(@"240e:1::5", lan) isEqualToString:@"en0"] &&
               [offeredFrom(@"192.168.1.10", lan) isEqualToString:@"en0"]);
    // The owner's Mac: utun4 holds both routes and en0 has a stable global IPv6 address.
    SZFO_CHECK(offeredFrom(@"240e:1::5", tunnel) == nil, "en0's global IPv6 never reaches the peer around the tunnel");
    SZFO_CHECK(offeredFrom(@"192.168.1.10", tunnel) == nil);
    SZFO_CHECK(offeredFrom(@"240e:1::5", ipv4Tunnel) != nil && offeredFrom(@"192.168.1.10", ipv4Tunnel) == nil,
               "each family follows its own route");
    SZFO_CHECK([offeredFrom(@"127.0.0.1", tunnel) isEqualToString:@"lo0"], "loopback is for the testing setup only");
    SZFO_CHECK(offeredFrom(@"192.0.2.77", lan) == nil && SZFriendsOnlineOfferingInterfaceForAddress(@"240e:1::5", NULL,
                                                                                                    &lan) == nil);
    const char *throughTunnel = offeredFrom(@"240e:1::5", tunnel).UTF8String;
    const char *throughLAN = offeredFrom(@"240e:1::5", lan).UTF8String;
    const SZFriendsOnlineConnectionKind direct = SZFriendsOnlineConnectionDirect;
    for (SZFriendsOnlinePurpose purpose = SZFriendsOnlinePurposeFriend; purpose <= SZFriendsOnlinePurposeLink;
         purpose++) {
        for (NSString *line in @[ Host(@"240e:1::5"), @"candidate:9 1 TCP 1 240e:1::5 9000 typ host tcptype so" ]) {
            SZFO_CHECK(Local(line, purpose, direct, throughTunnel, NO) == SZFriendsOnlineTechniqueNone, "%@", line);
            SZFO_CHECK(Local(line, purpose, direct, throughLAN, NO) != SZFriendsOnlineTechniqueNone, "%@", line);
        }
    }

    // This Mac (its routing table and interfaces, read only): an address of a family whose route a tunnel holds is
    // never offered. On the owner's Mac utun4 holds both families and en0 has global IPv6 addresses.
    SZFriendsOnlineDefaultRoutes live = SZFriendsOnlineReadDefaultRoutes();
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return;
    NSUInteger withheld = 0;
    for (struct ifaddrs *entry = list; entry != NULL; entry = entry->ifa_next) {
        if (entry->ifa_addr == NULL) continue;
        BOOL ipv6 = entry->ifa_addr->sa_family == AF_INET6;
        if (!ipv6 && entry->ifa_addr->sa_family != AF_INET) continue;
        char text[INET6_ADDRSTRLEN];
        const void *raw = ipv6 ? (const void *)&((struct sockaddr_in6 *)(void *)entry->ifa_addr)->sin6_addr
                               : (const void *)&((struct sockaddr_in *)(void *)entry->ifa_addr)->sin_addr;
        if (inet_ntop(ipv6 ? AF_INET6 : AF_INET, raw, text, sizeof text) == NULL) continue;
        NSString *address = @(text);
        SZFriendsOnlineAddressClass addressClass = SZFriendsOnlineClassifyAddress(address);
        if (addressClass == SZFriendsOnlineAddressLoopback || addressClass == SZFriendsOnlineAddressUnusable) continue;
        if (!SZFriendsOnlineDefaultRouteAllowsHostCandidates(&live, ipv6)) {
            SZFO_CHECK(SZFriendsOnlineInterfaceForAddress(address) == nil, "an address on %s goes around %s",
                       entry->ifa_name, ipv6 ? live.ipv6 : live.ipv4);
            withheld++;
        }
    }
    freeifaddrs(list);
    fprintf(stderr, "    routes toward the Internet: IPv4 %s, IPv6 %s; %lu local addresses withheld\n",
            live.ipv4[0] ? live.ipv4 : "none", live.ipv6[0] ? live.ipv6 : "none", (unsigned long)withheld);
}

static BOOL Dial(NSString *line, SZFriendsOnlinePurpose purpose, SZFriendsOnlineConnectionKind kind, BOOL loopback) {
    return SZFriendsOnlineMayDialRemoteCandidate(C(line), purpose, kind, loopback);
}

static void TestRemoteCandidates(void) {
    const SZFriendsOnlineConnectionKind direct = SZFriendsOnlineConnectionDirect;
    const SZFriendsOnlineConnectionKind relay = SZFriendsOnlineConnectionRelay;
    SZFO_CHECK(Dial(Host(@"192.168.1.20"), SZFriendsOnlinePurposeFriend, direct, NO));
    SZFO_CHECK(!Dial(Host(@"192.168.1.20"), SZFriendsOnlinePurposeFirstContact, direct, NO),
               "a stranger cannot point this helper at its own LAN");
    SZFO_CHECK(!Dial(Host(@"10.0.0.1"), SZFriendsOnlinePurposeLink, direct, NO));
    SZFO_CHECK(Dial(Host(@"203.0.113.7"), SZFriendsOnlinePurposeLink, direct, NO));
    SZFO_CHECK(Dial(Host(@"240e:1::7"), SZFriendsOnlinePurposeLink, direct, NO));
    for (NSString *address in @[ @"127.0.0.1", @"::1", @"169.254.3.3", @"224.0.0.251", @"ff02::1", @"0.0.0.0",
                                 @"::ffff:127.0.0.1", @"fe80::2" ]) {
        SZFO_CHECK(!Dial(Host(address), SZFriendsOnlinePurposeFriend, direct, NO), "never dialled: %@", address);
    }
    SZFO_CHECK(Dial(Host(@"127.0.0.1"), SZFriendsOnlinePurposeFriend, direct, YES), "tests only");
    SZFO_CHECK(!Dial(@"candidate:7 1 UDP 1 203.0.113.7 5000 typ prflx", SZFriendsOnlinePurposeFriend, direct, NO));
    SZFO_CHECK(Dial(@"candidate:7 1 UDP 1 203.0.113.7 5000 typ relay", SZFriendsOnlinePurposeLink, relay, NO));
    SZFO_CHECK(!Dial(Host(@"203.0.113.7"), SZFriendsOnlinePurposeFriend, relay, NO), "relay connections: relay only");
    SZFO_CHECK(!Dial(@"candidate:7 1 UDP 1 10.0.0.9 5000 typ relay", SZFriendsOnlinePurposeLink, relay, NO));
    NSString *so = @"candidate:9 1 TCP 1 203.0.113.7 9000 typ host tcptype so";
    SZFO_CHECK(Dial(so, SZFriendsOnlinePurposeFriend, direct, NO));
    SZFO_CHECK(!Dial(so, SZFriendsOnlinePurposeFriend, relay, NO));
}

static SZFriendsOnlineTechnique Pair(NSString *local, SZFriendsOnlineTechnique lt, NSString *remote,
                                     SZFriendsOnlineTechnique rt, SZFriendsOnlineConnectionKind kind) {
    return SZFriendsOnlineTechniqueForPair(C(local), lt, C(remote), rt, kind);
}

static void TestPairTechniques(void) {
    const SZFriendsOnlineConnectionKind direct = SZFriendsOnlineConnectionDirect;
    NSString *v4 = Host(@"192.168.1.10"), *v6 = Host(@"240e:1::5"), *v6b = Host(@"2001:db8::9");
    NSString *relay = @"candidate:5 1 UDP 1 203.0.113.9 4000 typ relay";
    NSString *srflx = @"candidate:2 1 UDP 1 203.0.113.5 4000 typ srflx";
    NSString *prflx = @"candidate:6 1 UDP 1 203.0.113.6 4000 typ prflx";
    SZFO_CHECK(Pair(v4, 0, relay, 0, direct) == SZFriendsOnlineTechniqueRelay, "relay first");
    SZFO_CHECK(Pair(relay, 9, v4, 0, SZFriendsOnlineConnectionRelay) == SZFriendsOnlineTechniqueRelay);
    SZFO_CHECK(Pair(v4, 0, v4, 0, SZFriendsOnlineConnectionProbeHandover) == SZFriendsOnlineTechniqueProbeHandover);
    SZFO_CHECK(Pair(v4, 0, srflx, SZFriendsOnlineTechniquePortMapping, direct) == SZFriendsOnlineTechniquePortMapping);
    SZFO_CHECK(Pair(v4, SZFriendsOnlineTechniquePredictedPort, srflx, 3, direct) ==
               SZFriendsOnlineTechniquePredictedPort);
    SZFO_CHECK(Pair(v4, 0, srflx, 0, direct) == SZFriendsOnlineTechniqueServerReflexive);
    SZFO_CHECK(Pair(v4, 0, prflx, 0, direct) == SZFriendsOnlineTechniquePeerReflexive);
    SZFO_CHECK(Pair(v6, 1, v6b, 1, direct) == SZFriendsOnlineTechniqueHostIPv6);
    SZFO_CHECK(Pair(v4, 2, v4, 2, direct) == SZFriendsOnlineTechniqueHostPrivate);
    SZFO_CHECK([SZFriendsOnlineInterfaceForAddress(@"127.0.0.1") hasPrefix:@"lo"], "loopback's interface");
    SZFO_CHECK(SZFriendsOnlineInterfaceForAddress(@"192.0.2.77") == nil, "a documentation address is nobody's");
}

void SZFORunCandidateTests(void) {
    TestParsing();
    TestAddressClasses();
    TestLocalCandidates();
    TestHostCandidatesFollowTheDefaultRoute();
    TestRemoteCandidates();
    TestPairTechniques();
}

#pragma mark - Direct-phase timer

void SZFORunTimerTests(void) {
    dispatch_queue_t queue = dispatch_queue_create("szfo.timer", DISPATCH_QUEUE_SERIAL);
    NSMutableArray<NSNumber *> *delays = [NSMutableArray array];
    NSMutableArray<dispatch_block_t> *blocks = [NSMutableArray array];
    void (^scheduler)(NSTimeInterval, dispatch_block_t) = ^(NSTimeInterval delay, dispatch_block_t block) {
        [delays addObject:@(delay)];
        [blocks addObject:block];
    };
    __block NSUInteger expiries = 0;
    void (^fireNext)(void) = ^{
        dispatch_block_t block = blocks.firstObject;
        if (block == nil) return;
        [blocks removeObjectAtIndex:0];
        block();
    };

    SZFriendsOnlineDirectPhaseTimer *plain = [[SZFriendsOnlineDirectPhaseTimer alloc] initWithQueue:queue
                                                                                          scheduler:scheduler];
    plain.onExpire = ^{
        expiries++;
    };
    [plain start];
    [plain start];
    SZFO_CHECK(delays.count == 1 && delays[0].doubleValue == SZFriendsOnlineDirectPlainBudget, "5 s once");
    fireNext();
    SZFO_CHECK(plain.expired && expiries == 1 && blocks.count == 0);

    [delays removeAllObjects];
    SZFriendsOnlineDirectPhaseTimer *hard = [[SZFriendsOnlineDirectPhaseTimer alloc] initWithQueue:queue
                                                                                         scheduler:scheduler];
    hard.onExpire = ^{
        expiries++;
    };
    [hard start];
    hard.hardNATProbing = YES; // learnt during the plain checks
    fireNext();
    SZFO_CHECK(!hard.expired && delays.count == 2 && delays[1].doubleValue == SZFriendsOnlineDirectHardNATBudget,
               "one hard side: 12 s more");
    fireNext();
    SZFO_CHECK(hard.expired && expiries == 2, "then the relay may start: 17 s in all");

    SZFriendsOnlineDirectPhaseTimer *opened = [[SZFriendsOnlineDirectPhaseTimer alloc] initWithQueue:queue
                                                                                           scheduler:scheduler];
    opened.onExpire = ^{
        expiries++;
    };
    [opened start];
    [opened stop]; // a path opened
    fireNext();
    SZFO_CHECK(!opened.expired && expiries == 2, "a stopped phase never expires");
    [opened start];
    SZFO_CHECK(blocks.count == 0, "nor starts again");
}
