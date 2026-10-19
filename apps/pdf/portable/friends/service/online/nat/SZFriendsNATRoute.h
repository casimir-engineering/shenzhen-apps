// Which interface and gateway carry this Mac's traffic to the Internet, read from the routing table (ADR 0011
// § Port mapping, § NAT class). Nothing is sent: the kernel is asked which route a packet to a destination would
// take (RTM_GET), the question `route -n get` asks.
//
// The answer follows lead decision 9: online routes follow the system's default route, whichever interface holds
// it. Behind a TUN proxy that holds split default routes (0/1 and 128/1, as on the owner's Mac), the route is the
// tunnel's, so port mapping is skipped (a mapping on the LAN gateway is useless while the tunnel carries the
// traffic), even though a plain 0/0 route to the LAN gateway still exists underneath.

#import "service/online/nat/SZFriendsNAT.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsNATRoute : NSObject
@property(nonatomic, readonly, copy) NSString *interfaceName; // "en0", "utun4"
// The next hop when the route goes through a gateway (port 0; an IPv6 router is link-local, with its scope), or nil
// for a directly connected destination or a point-to-point tunnel.
@property(nonatomic, readonly, nullable) SZFriendsNATEndpoint *gateway;
// The source address the kernel picks on that route, port 0; nil when the route gives none.
@property(nonatomic, readonly, nullable) SZFriendsNATEndpoint *localAddress;
// NO for the interfaces that never offer host candidates (SZFriendsOnlineInterfaceMayOfferHostCandidates: loopback,
// tunnels, peer-to-peer Wi-Fi): port mapping runs only when this is YES.
@property(nonatomic, readonly, getter=isPhysical) BOOL physical;
// Identifies the network for the NAT class kept per network: the interface and the gateway. In memory only.
@property(nonatomic, readonly, copy) NSString *networkKey;

// The route toward `destination` (only its address counts). Nil when the table has none or cannot be read.
+ (nullable instancetype)routeToDestination:(SZFriendsNATEndpoint *)destination;
// The route toward the Internet in a family, AF_INET or AF_INET6: asked for a documentation address
// (192.0.2.1, 2001:db8::1), which every default route covers and no more specific route on a real network does.
+ (nullable instancetype)defaultRouteForFamily:(sa_family_t)family;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
