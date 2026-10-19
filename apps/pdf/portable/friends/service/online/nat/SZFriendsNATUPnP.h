// UPnP IGD port mapping through miniupnpc 2.3.3 (ext/miniupnpc/, ADR 0011 § Port mapping), the last of the
// port-mapping steps: run by SZFriendsNATPortMapping only when PCP and NAT-PMP both failed over IPv4.
//
// miniupnpc parses SSDP answers, device descriptions and SOAP replies from any device on the LAN before anyone is
// authenticated, and has had memory-safety bugs, so it is fuzzed (fuzz/, friends-nat-fuzz) and narrowed here:
//   - discovery is one multicast M-SEARCH round on the default route's interface, waiting 1 s;
//   - only a device whose description lives on the default gateway's own address is used, and only control URLs on
//     that address are called, so no LAN device can send us to fetch or post anywhere else;
//   - the mapped external address must be a global one (a private WAN address means another NAT above it);
//   - the whole step has 3 s; a mapping made after that is deleted at once.
// AddPortMapping asks for the internal port as the external one with a 7,200 s lease (an infinite lease where the
// device accepts no other, error 725; deleted on close), and on IGD v2 also opens an IPv6 pinhole for the global
// address. Mappings are described "Shenzhen Friends", so a later run finds the ones a crashed run left for this
// Mac's LAN address and deletes them first. All miniupnpc calls run one at a time on one helper-wide queue, because
// they block.

#import "service/online/nat/SZFriendsNAT.h"

NS_ASSUME_NONNULL_BEGIN

// What the description of every mapping says; a later run deletes stale ones by it.
extern NSString *const SZFriendsNATUPnPDescription;

typedef void (^SZFriendsNATUPnPCompletion)(NSArray<SZFriendsNATEndpoint *> *mapped, NSError *_Nullable error);

@interface SZFriendsNATUPnP : NSObject
// Production: multicast discovery on `interfaceName`, keeping only a device on `gateway`'s address.
+ (instancetype)discoveryOnInterface:(NSString *)interfaceName gateway:(SZFriendsNATEndpoint *)gateway;
// Tests: no discovery; the device whose root description is at `url`, which must be http on a loopback address.
// Its control URLs must be on that address too, and documentation addresses count as global for its WAN address.
+ (instancetype)deviceAtRootDescriptionURL:(NSString *)url;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic) NSTimeInterval budget; // 3 s for discovery, description, cleanup and mapping together
@property(nonatomic) NSTimeInterval discoveryWait; // 1 s
// Whether a usable device answered at all, for the technique log and the gateway probe.
@property(nonatomic, readonly) BOOL foundDevice;

// Maps UDP `internalPort` for `localAddress` (this Mac's address toward the gateway) and, on IGD v2 with
// `globalIPv6`, opens a pinhole for it. `mapped`: the external IPv4 endpoint, then the IPv6 one, each when made.
// The completion runs once on `queue`, within the budget.
- (void)mapUDPPort:(uint16_t)internalPort
      localAddress:(SZFriendsNATEndpoint *)localAddress
        globalIPv6:(nullable SZFriendsNATEndpoint *)globalIPv6
             queue:(dispatch_queue_t)queue
        completion:(SZFriendsNATUPnPCompletion)completion;
// Extends the leases of what -mapUDPPort: made. The completion gets what is still mapped.
- (void)renewOnQueue:(dispatch_queue_t)queue completion:(SZFriendsNATUPnPCompletion)completion;
// Deletes what -mapUDPPort: made, in the background, without waiting. Idempotent.
- (void)removeMappings;
@end

NS_ASSUME_NONNULL_END
