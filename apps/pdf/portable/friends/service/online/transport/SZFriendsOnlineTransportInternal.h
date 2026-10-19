// Internal to service/online/transport/ and its tests: the candidate and description rules, the peer connection
// class, and the transport's testing configuration. Nothing here includes rtc.h, so tests of the pure rules compile
// without the stack's headers.

#import <Foundation/Foundation.h>

#import "service/online/transport/SZFriendsOnlineDataChannelTransport.h"

NS_ASSUME_NONNULL_BEGIN

NSError *SZFriendsOnlineMakeError(SZFriendsOnlineError code, NSString *reason);

#pragma mark - Addresses and candidates (SZFriendsOnlineCandidate.m)

typedef NS_ENUM(NSInteger, SZFriendsOnlineAddressClass) {
    // Never sent or dialled: unspecified, multicast, broadcast, link-local, reserved, IPv4-mapped or -compatible
    // IPv6, site-local, anything outside 2000::/3 and fc00::/7, and names (mDNS or DNS) rather than numbers.
    SZFriendsOnlineAddressUnusable = 0,
    SZFriendsOnlineAddressLoopback = 1,   // tests only (SZFriendsOnlineDataChannelTransport testing initializer)
    SZFriendsOnlineAddressPrivate = 2,    // 10/8, 172.16/12, 192.168/16, 100.64/10 (CGNAT), fc00::/7 (ULA)
    SZFriendsOnlineAddressPublicIPv4 = 3, // every other unicast IPv4
    SZFriendsOnlineAddressGlobalIPv6 = 4, // 2000::/3
};

SZFriendsOnlineAddressClass SZFriendsOnlineClassifyAddress(NSString *address);

typedef NS_ENUM(NSInteger, SZFriendsOnlineCandidateType) {
    SZFriendsOnlineCandidateHost = 1,
    SZFriendsOnlineCandidateServerReflexive = 2,
    SZFriendsOnlineCandidatePeerReflexive = 3,
    SZFriendsOnlineCandidateRelay = 4,
};

// One RFC 8839 candidate, parsed strictly: component 1, UDP or TCP with tcptype so, a numeric address, a port above
// 0. Re-serialised without "a=", related address or extensions, so nothing local leaks through raddr.
@interface SZFriendsOnlineCandidate : NSObject
+ (nullable instancetype)candidateWithLine:(NSString *)line; // "candidate:..." or "a=candidate:..."
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly, copy) NSString *foundation;
@property(nonatomic, readonly) BOOL tcp;
@property(nonatomic, readonly) uint32_t priority;
@property(nonatomic, readonly, copy) NSString *address; // canonical numeric form
@property(nonatomic, readonly) uint16_t port;
@property(nonatomic, readonly) SZFriendsOnlineCandidateType type;
@property(nonatomic, readonly) uint16_t relatedPort; // rport: a reflexive candidate's base port, 0 when absent
@property(nonatomic, readonly) SZFriendsOnlineAddressClass addressClass;
@property(nonatomic, readonly) BOOL ipv6;
@property(nonatomic, readonly, copy) NSString *line;     // canonical, what is sent and applied
@property(nonatomic, readonly, copy) NSString *endpoint; // "UDP address port", to match a selected pair
@end

// Friends only, never first contacts or links (lead decision for M2; the frozen header's
// SZFriendsOnlinePurposeMayOfferPrivateHostCandidates).
BOOL SZFriendsOnlineMayUsePrivateAddresses(SZFriendsOnlinePurpose purpose);
// The technique a local candidate is offered with, or SZFriendsOnlineTechniqueNone when it is never sent: by type
// and connection kind (a relay connection offers relay candidates only), address class and purpose, and for host
// candidates the interface it belongs to (SZFriendsOnlineInterfaceMayOfferHostCandidates; NULL: unknown, dropped).
// `allowLoopback` is the testing configuration's, which accepts 127.0.0.1 and ::1 whatever their interface.
SZFriendsOnlineTechnique SZFriendsOnlineLocalCandidateTechnique(SZFriendsOnlineCandidate *candidate,
                                                                SZFriendsOnlinePurpose purpose,
                                                                SZFriendsOnlineConnectionKind kind,
                                                                const char *_Nullable interfaceName,
                                                                BOOL allowLoopback);
// Whether the transport dials a remote candidate (SZFriendsOnlineErrorCandidateRefused otherwise).
BOOL SZFriendsOnlineMayDialRemoteCandidate(SZFriendsOnlineCandidate *candidate, SZFriendsOnlinePurpose purpose,
                                           SZFriendsOnlineConnectionKind kind, BOOL allowLoopback);
// The interface a host candidate on `address` is offered from: the one holding the address on this machine
// (getifaddrs), or nil when none does or when its family offers no host candidates because an interface that never
// offers them holds that family's route toward the Internet (a VPN or TUN proxy: lead decision 9,
// SZFriendsOnlineDefaultRouteAllowsHostCandidates). The routing table is read on every call. Loopback addresses keep
// their interface: only the testing configuration offers them, whatever the routes.
NSString *_Nullable SZFriendsOnlineInterfaceForAddress(NSString *address);
// The same over injected tables: `list` as getifaddrs builds it, `routes` as the routing table would answer.
struct ifaddrs;
NSString *_Nullable SZFriendsOnlineOfferingInterfaceForAddress(NSString *address, const struct ifaddrs *_Nullable list,
                                                               const SZFriendsOnlineDefaultRoutes *routes);
// This Mac's routes toward the Internet, read from the routing table now (nothing is sent).
SZFriendsOnlineDefaultRoutes SZFriendsOnlineReadDefaultRoutes(void);
// The technique of a selected pair, by the rule in SZFriendsOnlineTransport.h. `localTechnique` and
// `remoteTechnique` are what each candidate was sent with (None when unknown, as for a peer-reflexive one).
SZFriendsOnlineTechnique SZFriendsOnlineTechniqueForPair(SZFriendsOnlineCandidate *local,
                                                         SZFriendsOnlineTechnique localTechnique,
                                                         SZFriendsOnlineCandidate *remote,
                                                         SZFriendsOnlineTechnique remoteTechnique,
                                                         SZFriendsOnlineConnectionKind kind);

#pragma mark - Descriptions (SZFriendsOnlineDescription.m)

// A session description checked for what the transport accepts: at most SZFriendsOnlineSignalPayloadMax bytes of
// printable ASCII, v=0, exactly one media section and it a data channel, ICE credentials, and at least one
// a=fingerprint, every one SHA-256 and all equal. Candidates are taken out of the SDP so they pass the same rules
// as trickled ones.
@interface SZFriendsOnlineDescription : NSObject
+ (nullable instancetype)descriptionWithSDP:(NSString *)sdp error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly, copy) NSString *sdp; // without candidate or end-of-candidates lines, CRLF endings
@property(nonatomic, readonly, copy) NSArray<NSString *> *candidates; // "candidate:..." values taken out
@property(nonatomic, readonly, copy) NSData *fingerprint;             // SZFriendsOnlineFingerprintLength bytes
@property(nonatomic, readonly, copy) NSString *mid;
@end

// Tests of links on one Mac only (the links suite and its e2e helper): the testing transport then offers a link's
// peers loopback host candidates and accepts a local relay's private relayed address. NO everywhere else, the
// transport's own suite included, which checks that a link never learns such an address.
extern BOOL SZFriendsOnlineTestLinksUseLocalAddresses;

// "AB:CD:..." (32 pairs) to bytes; nil when malformed.
NSData *_Nullable SZFriendsOnlineFingerprintFromHex(NSString *hex);
// "stun:host[:port]" with nothing else.
BOOL SZFriendsOnlineSTUNURIIsValid(NSString *_Nullable uri);
// libdatachannel's ICE server URL for TURN over UDP, credentials percent-encoded (usernames hold a colon). Nil with
// SZFriendsOnlineErrorNotAuthorized for anything but turn:host[:port][?transport=udp], or expired credentials.
NSString *_Nullable SZFriendsOnlineTURNServerURL(id<SZFriendsOnlineRelayCredentials> relay, NSDate *now,
                                                 NSError *_Nullable *_Nullable error);

#pragma mark - The transport's configuration

@interface SZFriendsOnlineDataChannelTransport ()
// Tests only: binds every peer connection to `bindAddress` (127.0.0.1) and accepts loopback candidates both ways,
// the only way two peer connections on one machine meet without leaving it. The helper never uses this.
- (instancetype)initForTestingWithBindAddress:(NSString *)bindAddress;
@property(nonatomic, readonly, copy, nullable) NSString *bindAddress;
@property(nonatomic, readonly) BOOL allowsLoopback;
@end

// Configures the stack once per process (rtcSetThreadPoolSize(1), before any peer connection exists).
void SZFriendsOnlineConfigureStack(void);
// Where blocking libdatachannel teardown runs, off every caller's queue and off the stack's own thread.
dispatch_queue_t SZFriendsOnlineTeardownQueue(void);

NS_ASSUME_NONNULL_END
