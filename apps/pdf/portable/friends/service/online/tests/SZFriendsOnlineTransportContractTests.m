// Contract of the frozen online transport header (service/online/SZFriendsOnlineTransport.h; ADR 0009 to 0011).
// The header's inline policies are behaviour every transport shares, so they are tested here rather than in one
// implementation: the route class each technique reports, the logged technique numbers, the interfaces that never
// offer host candidates (lead decision 9: utun and other tunnels, virtual networks), host candidates following the
// default route over injected interface and route tables, and which purposes may offer private addresses (friends
// only). The limits are checked against the ADRs and HOST-PROTOCOL.md, and a request object is built against the
// protocols so a change to their shape fails here first.

#import "service/online/SZFriendsOnlineTransport.h"

#include <stdio.h>
#include <stdlib.h>

static int failures = 0;

#define CHECK(condition, ...)                                                                                        \
    do {                                                                                                             \
        if (!(condition)) {                                                                                          \
            failures++;                                                                                              \
            fprintf(stderr, "%s:%d: CHECK failed: %s %s\n", __FILE__, __LINE__, #condition,                          \
                    [[NSString stringWithFormat:@"" __VA_ARGS__] UTF8String]);                                       \
        }                                                                                                            \
    } while (0)

// The caller implements the request; this is the smallest one, an answerer for a friend.
@interface SZFTestOnlineRequest : NSObject <SZFriendsOnlineConnectionRequest>
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

@implementation SZFTestOnlineRequest
@end

static void TestRouteClassPerTechnique(void) {
    CHECK(SZFriendsOnlineRouteMethodForTechnique(SZFriendsOnlineTechniqueNone) == SZFriendsRouteMethodNone);
    CHECK(SZFriendsOnlineRouteMethodForTechnique(SZFriendsOnlineTechniqueRelay) == SZFriendsRouteMethodRelay,
          "only the relay reports route class 5");
    for (NSInteger t = SZFriendsOnlineTechniqueHostIPv6; t <= SZFriendsOnlineTechniqueTCPSimultaneousOpen; t++) {
        CHECK(SZFriendsOnlineRouteMethodForTechnique((SZFriendsOnlineTechnique)t) == SZFriendsRouteMethodInternet,
              "every direct technique is route class 4");
    }
    CHECK(SZFriendsRouteMethodInternet == 4 && SZFriendsRouteMethodRelay == 5, "ADR 0001 wire numbers");

    SZFriendsOnlineRoute relayed = SZFriendsOnlineRouteMake(SZFriendsOnlineTechniqueRelay, NO);
    CHECK(relayed.method == SZFriendsRouteMethodRelay && relayed.technique == SZFriendsOnlineTechniqueRelay &&
          !relayed.ipv6);
    SZFriendsOnlineRoute tcp = SZFriendsOnlineRouteMake(SZFriendsOnlineTechniqueTCPSimultaneousOpen, YES);
    CHECK(tcp.method == SZFriendsRouteMethodInternet && tcp.ipv6, "the TCP path is direct");
}

static void TestTechniqueNumbersAreTheLoggedOnes(void) {
    // The technique log records these numbers; a renumbering would misread every earlier entry.
    CHECK(SZFriendsOnlineTechniqueNone == 0 && SZFriendsOnlineTechniqueHostIPv6 == 1 &&
          SZFriendsOnlineTechniqueHostPrivate == 2 && SZFriendsOnlineTechniqueServerReflexive == 3 &&
          SZFriendsOnlineTechniquePeerReflexive == 4 && SZFriendsOnlineTechniquePortMapping == 5 &&
          SZFriendsOnlineTechniquePredictedPort == 6 && SZFriendsOnlineTechniqueProbeHandover == 7 &&
          SZFriendsOnlineTechniqueTCPSimultaneousOpen == 8 && SZFriendsOnlineTechniqueRelay == 9);
}

static void TestTunnelsNeverOfferHostCandidates(void) {
    const char *offered[] = {"en0", "en1", "en7", "en10"};
    for (size_t i = 0; i < sizeof offered / sizeof offered[0]; i++) {
        CHECK(SZFriendsOnlineInterfaceMayOfferHostCandidates(offered[i]), "a physical interface offers: %s",
              offered[i]);
    }
    // utun4 is the TUN proxy that held the default route on the owner's Mac in the NAT spike. feth is ZeroTier's,
    // bridge100 Internet Sharing's, vmenet a virtual machine's: their private addresses describe networks the peer
    // has no business knowing.
    const char *refused[] = {"utun0", "utun4", "ipsec0", "ppp0", "gif0", "stf0", "tun0", "tap1", "wg0", "lo0",
                             "awdl0", "llw0", "feth2741", "bridge100", "bridge0", "vmenet0", "anpi0", "anpi1", ""};
    for (size_t i = 0; i < sizeof refused / sizeof refused[0]; i++) {
        CHECK(!SZFriendsOnlineInterfaceMayOfferHostCandidates(refused[i]), "never offered: '%s'", refused[i]);
    }
    CHECK(!SZFriendsOnlineInterfaceMayOfferHostCandidates(NULL), "an unknown interface offers nothing");
}

// One address of an injected interface table: what getifaddrs would list.
typedef struct {
    const char *name;
    BOOL ipv6;
} InterfaceAddress;

static const InterfaceAddress kTable[] = {
    {"en0", NO},    // 192.168.1.10
    {"en0", YES},   // 240e:...: global, stable, the home network's
    {"en7", YES},   // a second physical interface
    {"utun4", NO},  // the TUN proxy's 198.18.0.1
    {"utun4", YES}, // and its fd00:... address
    {"bridge100", NO},
};

// The table filtered by the rule: one bit per entry, set when it is offered.
static unsigned Offered(SZFriendsOnlineDefaultRoutes routes) {
    unsigned offered = 0;
    for (unsigned i = 0; i < sizeof kTable / sizeof kTable[0]; i++) {
        if (SZFriendsOnlineMayOfferHostCandidate(kTable[i].name, kTable[i].ipv6, &routes)) offered |= 1u << i;
    }
    return offered;
}

static void TestHostCandidatesFollowTheDefaultRoute(void) {
    // No tunnel: every physical interface's addresses, never a tunnel's or a bridge's.
    CHECK(Offered(SZFriendsOnlineDefaultRoutesMake("en0", "en0")) == 0x7, "%x",
          Offered(SZFriendsOnlineDefaultRoutesMake("en0", "en0")));
    // The owner's Mac: utun4 holds both default routes, and en0 has a global IPv6 address. Nothing is offered: en0's
    // addresses would reach the peer around the tunnel and say where the person is.
    CHECK(Offered(SZFriendsOnlineDefaultRoutesMake("utun4", "utun4")) == 0, "a tunnel holds both families");
    // A VPN that carries IPv4 only: IPv6 follows en0 as the system's own traffic does, IPv4 offers nothing.
    CHECK(Offered(SZFriendsOnlineDefaultRoutesMake("utun4", "en0")) == 0x6, "%x",
          Offered(SZFriendsOnlineDefaultRoutesMake("utun4", "en0")));
    CHECK(Offered(SZFriendsOnlineDefaultRoutesMake("en0", "utun4")) == 0x1, "IPv6 through the tunnel");
    for (const char *const *tunnel = (const char *const[]){"ipsec0", "ppp0", "tun0", "tap0", "wg0", "feth1", NULL};
         *tunnel != NULL; tunnel++) {
        CHECK(Offered(SZFriendsOnlineDefaultRoutesMake(*tunnel, *tunnel)) == 0, "%s holds the routes", *tunnel);
    }
    // A family with no route toward the Internet, or a routing table that could not be read, offers nothing.
    CHECK(Offered(SZFriendsOnlineDefaultRoutesMake(NULL, "en0")) == 0x6);
    CHECK(Offered(SZFriendsOnlineDefaultRoutesMake("", NULL)) == 0);

    // Split default routes: the tunnel holding either half holds the family, whichever answer came first.
    SZFriendsOnlineDefaultRoutes routes = SZFriendsOnlineDefaultRoutesMake(NULL, NULL);
    SZFriendsOnlineDefaultRoutesAdd(&routes, NO, "en0");
    SZFriendsOnlineDefaultRoutesAdd(&routes, NO, "utun4");
    SZFriendsOnlineDefaultRoutesAdd(&routes, YES, "utun4");
    SZFriendsOnlineDefaultRoutesAdd(&routes, YES, "en0");
    SZFriendsOnlineDefaultRoutesAdd(&routes, YES, NULL);
    CHECK(strcmp(routes.ipv4, "utun4") == 0 && strcmp(routes.ipv6, "utun4") == 0, "%s %s", routes.ipv4, routes.ipv6);
    routes = SZFriendsOnlineDefaultRoutesMake(NULL, NULL);
    SZFriendsOnlineDefaultRoutesAdd(&routes, NO, NULL);
    SZFriendsOnlineDefaultRoutesAdd(&routes, NO, "en0");
    SZFriendsOnlineDefaultRoutesAdd(&routes, NO, "en1");
    CHECK(strcmp(routes.ipv4, "en0") == 0 && routes.ipv6[0] == '\0', "the first physical answer stays");
    routes = SZFriendsOnlineDefaultRoutesMake("an-interface-name-far-too-long", NULL);
    CHECK(strlen(routes.ipv4) == IFNAMSIZ - 1, "names are cut to IFNAMSIZ");

    // The probes cover both halves of each family and are never sent to: documentation addresses where they exist.
    CHECK(SZFriendsOnlineInternetRouteProbeCount == 2);
    CHECK(strcmp(SZFriendsOnlineInternetRouteProbe(AF_INET, 0), "192.0.2.1") == 0 &&
          strcmp(SZFriendsOnlineInternetRouteProbe(AF_INET, 1), "8.8.8.8") == 0, "128/1 and 0/1");
    CHECK(strcmp(SZFriendsOnlineInternetRouteProbe(AF_INET6, 0), "2001:db8::1") == 0 &&
          strcmp(SZFriendsOnlineInternetRouteProbe(AF_INET6, 1), "3fff::1") == 0, "2000::/4 and 3000::/4");
}

static void TestOnlyFriendsAreOfferedPrivateAddresses(void) {
    CHECK(SZFriendsOnlinePurposeMayOfferPrivateHostCandidates(SZFriendsOnlinePurposeFriend));
    CHECK(!SZFriendsOnlinePurposeMayOfferPrivateHostCandidates(SZFriendsOnlinePurposeFirstContact),
          "an accepted Add by ID request authenticates nobody (lead decision for M2)");
    CHECK(!SZFriendsOnlinePurposeMayOfferPrivateHostCandidates(SZFriendsOnlinePurposeLink),
          "a link holder never learns the sender's local addresses");
    CHECK(!SZFriendsOnlinePurposeMayOfferPrivateHostCandidates((SZFriendsOnlinePurpose)0), "unknown purposes refuse");
}

static void TestLimits(void) {
    CHECK(SZFriendsOnlineFingerprintLength == 32, "SHA-256");
    CHECK(SZFriendsOnlineMessageMax == 64 * 1024, "ADR 0009: records of 64 KiB or less");
    CHECK(SZFriendsOnlineSignalPayloadMax == 4096, "HOST-PROTOCOL.md protocol 2: sig_msg payload");
    CHECK(SZFriendsOnlineRemoteCandidateMax == 30, "libjuice ICE_MAX_CANDIDATES_COUNT");
    CHECK(SZFriendsOnlinePredictedCandidateMax == 25 &&
              SZFriendsOnlinePredictedCandidateMax < SZFriendsOnlineRemoteCandidateMax,
          "predicted ports leave room for the usual candidates");
}

static void TestRequestShape(void) {
    SZFTestOnlineRequest *request = [SZFTestOnlineRequest new];
    request.purpose = SZFriendsOnlinePurposeFriend;
    request.role = SZFriendsOnlineRoleAnswerer;
    request.kind = SZFriendsOnlineConnectionDirect;
    request.peer = [NSMutableData dataWithLength:32];
    request.stunURI = @"stun:host.test:3478";
    request.remoteOfferSDP = @"v=0";
    request.remoteFingerprint = [NSMutableData dataWithLength:SZFriendsOnlineFingerprintLength];
    id<SZFriendsOnlineConnectionRequest> asked = request;
    CHECK(asked.role == SZFriendsOnlineRoleAnswerer && asked.remoteOfferSDP != nil && asked.relay == nil &&
          asked.remoteFingerprint.length == SZFriendsOnlineFingerprintLength && asked.localPort == 0);
}

int main(void) {
    @autoreleasepool {
        TestRouteClassPerTechnique();
        TestTechniqueNumbersAreTheLoggedOnes();
        TestTunnelsNeverOfferHostCandidates();
        TestHostCandidatesFollowTheDefaultRoute();
        TestOnlyFriendsAreOfferedPrivateAddresses();
        TestLimits();
        TestRequestShape();
    }
    if (failures != 0) {
        fprintf(stderr, "online transport contract: %d failure(s)\n", failures);
        return EXIT_FAILURE;
    }
    printf("online transport contract: passed\n");
    return EXIT_SUCCESS;
}
