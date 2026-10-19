// Shenzhen Friends NAT techniques: the shared types of service/online/nat/ (ADR 0011).
//
// Helper-only. The order component (service/online/order/) and the transport (service/online/transport/) use the
// techniques through the headers beside this one:
//   - SZFriendsNATStun.h         STUN Binding messages (RFC 8489), the codec every technique below shares;
//   - SZFriendsNATClassifier.h   the two-port classifier (host's 3478 and 3479) and the class kept per network;
//   - SZFriendsNATPrediction.h   predicted ports of a per-destination NAT, and the candidates every technique sends;
//   - SZFriendsNATPortMapping.h  router port mapping: PCP, then NAT-PMP (our own client), then UPnP IGD (miniupnpc);
//   - SZFriendsNATProber.h       hard-NAT probing (the birthday technique) and its budget;
//   - SZFriendsNATTCPPath.h      TCP simultaneous open carrying the ADR 0001 stream.
// Every one of them sends only to addresses the caller names (the host from the signed list, the gateway from the
// routing table, the peer from authenticated signalling), checks what comes back strictly, and logs no address,
// port or key. Tests run them on loopback only, through the loopback-only mode each object offers: that mode
// refuses every address that is not loopback, so it can narrow where packets go but never widen it.

#import <Foundation/Foundation.h>

#include <sys/socket.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Errors

extern NSErrorDomain const SZFriendsNATErrorDomain;

// None is shown to people: the order component maps them to its next phase and the technique log.
typedef NS_ERROR_ENUM(SZFriendsNATErrorDomain, SZFriendsNATError) {
    SZFriendsNATErrorRefused = 1,        // the other end answered "port unreachable", or a PCP/NAT-PMP/UPnP refusal
    SZFriendsNATErrorTimedOut = 2,       // no acceptable answer within the technique's budget
    SZFriendsNATErrorUnsupported = 3,    // not available here: a tunnel holds the default route, no gateway, no IGD
    SZFriendsNATErrorAddressRefused = 4, // an address this technique never sends to (ADR 0011 § Probing budget)
    SZFriendsNATErrorBudget = 5,         // a probing run for this peer or this helper is already used up
    SZFriendsNATErrorSocket = 6,         // the system refused a socket, a bind or a send
    SZFriendsNATErrorCancelled = 7,      // -cancel or -close ran first
};

#pragma mark - NAT class (ADR 0011 § NAT class)

typedef NS_ENUM(NSInteger, SZFriendsNATClass) {
    SZFriendsNATClassUnknown = 0,             // 3479 did not answer, or the two answers disagree on the address
    SZFriendsNATClassEndpointIndependent = 1, // one mapped port for both server ports: hole punching works
    SZFriendsNATClassPerDestination = 2,      // a new mapping per destination: prediction and probing may help
};

#pragma mark - Addresses

// What an address is for the purposes of ADR 0011: which ones a technique may send to or offer.
typedef NS_ENUM(NSInteger, SZFriendsNATAddressScope) {
    SZFriendsNATAddressScopeUnspecified = 0, // 0.0.0.0, ::
    SZFriendsNATAddressScopeLoopback = 1,    // 127/8, ::1
    SZFriendsNATAddressScopeLinkLocal = 2,   // 169.254/16, fe80::/10
    SZFriendsNATAddressScopeMulticast = 3,   // 224/4 and broadcast, ff00::/8
    SZFriendsNATAddressScopePrivate = 4,     // 10/8, 172.16/12, 192.168/16, fc00::/7 (ULA)
    SZFriendsNATAddressScopeShared = 5,      // 100.64/10, carrier-grade NAT: never reachable from outside
    SZFriendsNATAddressScopeReserved = 6,    // documentation, benchmarking, 0/8, 240/4, NAT64, Teredo, 6to4, the rest
    SZFriendsNATAddressScopeGlobal = 7,      // routable on the Internet
};

// An IPv4 or IPv6 address with a port. Immutable. Built only from numeric forms: nothing here resolves a name.
// IPv4-mapped IPv6 addresses (::ffff:a.b.c.d) become IPv4, so one address never has two spellings.
@interface SZFriendsNATEndpoint : NSObject <NSCopying>
@property(nonatomic, readonly) sa_family_t family; // AF_INET or AF_INET6
@property(nonatomic, readonly) NSData *address;    // 4 or 16 bytes, network order
@property(nonatomic, readonly) uint16_t port;
@property(nonatomic, readonly) uint32_t scopeID;   // IPv6 link-local only, else 0
@property(nonatomic, readonly) SZFriendsNATAddressScope scope;
@property(nonatomic, readonly) NSString *host;     // numeric, without the port ("192.0.2.1", "2001:db8::1")

+ (nullable instancetype)endpointWithSockaddr:(const struct sockaddr *)sockaddr length:(socklen_t)length;
// `host` must be a numeric IPv4 or IPv6 address (an IPv6 link-local one may carry "%en0" or "%4").
+ (nullable instancetype)endpointWithHost:(NSString *)host port:(uint16_t)port;
+ (nullable instancetype)endpointWithAddress:(NSData *)address port:(uint16_t)port;
- (instancetype)init NS_UNAVAILABLE;

- (instancetype)endpointWithPort:(uint16_t)port;
// Fills `storage` and returns the sockaddr length.
- (socklen_t)getSockaddr:(struct sockaddr_storage *)storage;
// Same address, ignoring the port.
- (BOOL)hasSameAddressAs:(SZFriendsNATEndpoint *)other;
@end

// Classifies a raw address (4 or 16 bytes, network order); Reserved for any other length.
SZFriendsNATAddressScope SZFriendsNATScopeOfAddress(const uint8_t *bytes, size_t length);

// Where packets may go in a loopback-only test: loopback addresses only, never anything else.
static inline BOOL SZFriendsNATLoopbackOnlyAllows(SZFriendsNATEndpoint *endpoint) {
    return endpoint.scope == SZFriendsNATAddressScopeLoopback;
}

// This Mac's own addresses on every interface, up or not, ports 0: what a prober must never send to.
NSArray<SZFriendsNATEndpoint *> *SZFriendsNATOwnAddresses(void);

NS_ASSUME_NONNULL_END
