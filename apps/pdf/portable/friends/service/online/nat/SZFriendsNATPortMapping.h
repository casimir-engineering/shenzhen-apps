// Router port mapping for a connection's local UDP port (ADR 0011 § Port mapping; lead decision 7).
//
// One SZFriendsNATPortMapping per connection, started as soon as the connection's UDP port is bound and only when
// the default route's interface is a physical one (SZFriendsNATRoute). In order:
//   1. PCP MAP (RFC 6887) for UDP to the IPv4 gateway, suggested external port equal to the internal one, lifetime
//      7,200 s; and, at the same time, to the IPv6 default router for the global IPv6 address (a firewall pinhole).
//   2. A version-0 "unsupported version" answer over IPv4 falls back to NAT-PMP (RFC 6886): external address, then
//      the mapping.
//   Each exchange retransmits at 250, 500 and 1,000 ms and gives up at 2 s; "port unreachable" ends it at once.
//   Answers count only from the gateway's address and port 5351, with our nonce, parsed strictly.
//   3. UPnP IGD (miniupnpc, SZFriendsNATUPnP.h), only when PCP and NAT-PMP both failed over IPv4: 3 s for the step.
// Every mapping is renewed at half its lifetime while this object lives, deleted (lifetime 0, or DeletePortMapping)
// by -close, and dropped without a word to the router after -networkDidChange or a PCP/NAT-PMP epoch that went
// backwards (the router lost it; it is requested once more). MAP only: no PEER, no THIRD_PARTY, no ANNOUNCE.
//
// Each mapped address goes to the delegate, which hands it to the transport as a local candidate with technique
// PortMapping (SZFriendsNATCandidateForPortMapping in SZFriendsNATPrediction.h).

#import "service/online/nat/SZFriendsNAT.h"

@class SZFriendsNATUPnP;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SZFriendsNATMappingProtocol) {
    SZFriendsNATMappingProtocolPCP = 1,
    SZFriendsNATMappingProtocolNATPMP = 2,
    SZFriendsNATMappingProtocolUPnP = 3,
};

@interface SZFriendsNATPortMappingConfiguration : NSObject <NSCopying>
@property(nonatomic) uint16_t internalPort; // the connection's bound UDP port; required
// The IPv4 gateway and this side's address on its network (port ignored). Nil skips IPv4. Normally from
// +configurationForPort:, which reads them from the route toward the Internet.
@property(nonatomic, strong, nullable) SZFriendsNATEndpoint *gatewayIPv4;
@property(nonatomic, strong, nullable) SZFriendsNATEndpoint *localIPv4;
// The IPv6 default router (link-local, with scope) and the global IPv6 address to open a pinhole for. Nil skips it.
@property(nonatomic, strong, nullable) SZFriendsNATEndpoint *gatewayIPv6;
@property(nonatomic, strong, nullable) SZFriendsNATEndpoint *globalIPv6;
// Where PCP and NAT-PMP are asked: 5351. Tests point it at a scripted gateway on loopback.
@property(nonatomic) uint16_t serverPort;
@property(nonatomic) uint32_t lifetime;                      // 7,200 s
@property(nonatomic, copy) NSArray<NSNumber *> *retransmits; // seconds after the first send: 0.25, 0.5, 1.0
@property(nonatomic) NSTimeInterval exchangeBudget;          // 2 s
// The UPnP step, or nil to leave UPnP out (tests of PCP alone; a network whose route is not physical).
@property(nonatomic, strong, nullable) SZFriendsNATUPnP *upnp;
// Tests: refuse every gateway that is not a loopback address (SZFriendsNAT.h).
@property(nonatomic) BOOL loopbackOnly;

// Defaults for `port` on the current network: gateways and addresses from the route toward the Internet, UPnP on
// its interface. Nil when that route is not physical (a VPN or TUN proxy holds it) or has no gateway.
+ (nullable instancetype)configurationForPort:(uint16_t)port;
@end

@class SZFriendsNATPortMapping;

@protocol SZFriendsNATPortMappingDelegate <NSObject>
// A router now forwards `external` to the internal port (IPv4), or opened a pinhole for it (IPv6). Also after a
// renewal or a remap that changed the external address or port.
- (void)portMapping:(SZFriendsNATPortMapping *)mapping
       didMapExternal:(SZFriendsNATEndpoint *)external
             protocol:(SZFriendsNATMappingProtocol)protocol;
// A mapping reported earlier is gone (the router lost it, a renewal was refused, the network changed).
- (void)portMapping:(SZFriendsNATPortMapping *)mapping didLoseExternal:(SZFriendsNATEndpoint *)external;
// Every protocol has answered or given up for both families; `mapped` is how many mappings exist. Once.
- (void)portMapping:(SZFriendsNATPortMapping *)mapping didFinishWithMappings:(NSUInteger)mapped;
@end

// Every method is called on `queue`, and the delegate hears everything there.
@interface SZFriendsNATPortMapping : NSObject
- (instancetype)initWithConfiguration:(SZFriendsNATPortMappingConfiguration *)configuration
                             delegate:(id<SZFriendsNATPortMappingDelegate>)delegate
                                queue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)start;
// The current mappings.
@property(nonatomic, readonly) NSArray<SZFriendsNATEndpoint *> *externalEndpoints;
// What the first IPv4 exchange learnt, for the technique log and the gateway probe: answered at all, refused
// with "port unreachable", or fell back from PCP to NAT-PMP.
@property(nonatomic, readonly) BOOL gatewayRefusedPort;
@property(nonatomic, readonly) BOOL fellBackToNATPMP;
// Forget every mapping without telling the router (it is on another network now). The delegate hears
// -didLoseExternal: for each, then nothing more.
- (void)networkDidChange;
// Deletes every mapping on its router and stops. Idempotent; the delegate hears nothing after it returns.
- (void)close;
@end

NS_ASSUME_NONNULL_END
