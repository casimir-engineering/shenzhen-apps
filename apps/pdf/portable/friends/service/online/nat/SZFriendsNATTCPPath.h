// TCP simultaneous open, our own path, carrying the ADR 0001 stream directly (ADR 0011 § TCP simultaneous open;
// lead decision 4). libjuice's ICE-TCP is active only, so two helpers never form a TCP pair through it; macOS
// completes crossing SYNs with no listener on either side (50 of 50 rounds in the NAT spike).
//
// Each side binds TCP sockets to one fixed local port with address and port reuse, learns that port's mapped address
// from STUN over TCP to the host's 3478 (the STUN connection stays open while the path runs, so the NAT keeps the
// mapping), and sends its global IPv6 addresses and that mapped address as RFC 6544 candidates with tcptype so;
// private IPv4 and ULA addresses too, for friends only (lead decision for M2: never to first contacts or download
// links). Then each side calls connect() from the same local port to every remote endpoint the authenticated
// signalling brought, again after a refusal (10 ms later; once a second after 20 refusals) or 1 s of silence
// (through a NAT the first SYN is usually dropped), until the budget ends. The first socket to connect becomes the
// stream; every other attempt stops. The offerer is the ADR 0001 initiator on it and sends the preamble; Noise
// authenticates, as on the LAN, and the first bytes are bounded as ADR 0001 bounds every responder.
//
// There is no listener: a connect() in progress accepts only a SYN from the exact endpoint it is calling, so nobody
// but an endpoint from the signalling can complete it. A path dials only the endpoints the peer presented as
// candidates in this attempt (-addRemoteCandidate:), never one it derives itself.
//
// Addresses follow the system's default route (lead decision 9). Every socket is bound to the unspecified address,
// never to an interface or one of its addresses, so each connect() and the STUN connection take the route the system
// picks, a VPN's or a TUN proxy's included; the mapped address is therefore learnt through the default route. Host
// candidates obey SZFriendsOnlineMayOfferHostCandidate: none from an interface that never offers them, and none of a
// family whose route toward the Internet a tunnel holds.

#import "service/online/SZFriendsOnlineTransport.h"
#import "service/online/nat/SZFriendsNAT.h"

NS_ASSUME_NONNULL_BEGIN

enum {
    SZFriendsNATTCPRemoteEndpointsMax = 8, // remote TCP candidates one path dials
};

@interface SZFriendsNATTCPPathConfiguration : NSObject <NSCopying>
@property(nonatomic) SZFriendsOnlinePurpose purpose; // Friend or FirstContact; links have no TCP path
@property(nonatomic) uint16_t localPort;             // 0: the system picks one, then every socket reuses it
// The host's STUN server for TCP (3478), numeric, from the signed host list; nil gathers no mapped address.
@property(nonatomic, strong, nullable) SZFriendsNATEndpoint *stunServer;
@property(nonatomic) NSTimeInterval budget;          // until the direct phase's budget ends: 5 s (provisional)
@property(nonatomic) NSTimeInterval redialAfterSilence; // 1 s
@property(nonatomic) NSTimeInterval redialAfterRefusal; // 10 ms
@property(nonatomic) NSTimeInterval stunBudget;      // 2 s for the mapped address
// Tests: bind and dial on loopback only, offering 127.0.0.1 and ::1 as host candidates.
@property(nonatomic) BOOL loopbackOnly;
@end

@class SZFriendsNATTCPPath;

@protocol SZFriendsNATTCPPathDelegate <NSObject>
// A local candidate line for the peer, with technique SZFriendsOnlineTechniqueTCPSimultaneousOpen.
- (void)tcpPath:(SZFriendsNATTCPPath *)path didGatherLocalCandidate:(NSString *)candidate;
- (void)tcpPathDidFinishGathering:(SZFriendsNATTCPPath *)path;
// The stream, not started: the session layer starts it on its queue. Once; nothing else follows.
- (void)tcpPath:(SZFriendsNATTCPPath *)path didOpenStream:(id<SZFriendsByteStream>)stream ipv6:(BOOL)ipv6;
// The budget ended with no connection, or the path could not start. Once; nothing else follows.
- (void)tcpPath:(SZFriendsNATTCPPath *)path didFailWithError:(NSError *)error;
@end

// Every method is called on `queue`, and the delegate hears everything there.
@interface SZFriendsNATTCPPath : NSObject
- (instancetype)initWithConfiguration:(SZFriendsNATTCPPathConfiguration *)configuration
                             delegate:(id<SZFriendsNATTCPPathDelegate>)delegate
                                queue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Binds the port, gathers host candidates at once and the mapped one when STUN answers. NO with an
// SZFriendsNATErrorDomain error when the purpose has no TCP path or no port could be bound.
- (BOOL)start:(NSError *_Nullable *_Nullable)error;
@property(nonatomic, readonly) uint16_t localPort; // bound port, 0 before -start
// A remote candidate line from the authenticated exchange, dialled at once. NO, dialling nothing, for anything but a
// TCP "tcptype so" candidate on an address the purpose may dial (global; private only for friends; loopback only in
// tests), or past SZFriendsNATTCPRemoteEndpointsMax.
- (BOOL)addRemoteCandidate:(NSString *)candidate error:(NSError *_Nullable *_Nullable)error;
// Stops every attempt and closes every socket the path still holds (not a stream it already handed over).
// Idempotent; the delegate hears nothing after it returns.
- (void)close;
@end

// The host addresses a path offers (ports 0), from an interface table as getifaddrs builds it and this Mac's routes
// toward the Internet: up, global or (friends only) private, and allowed by SZFriendsOnlineMayOfferHostCandidate. A
// loopback-only path offers its loopback addresses whatever the routes.
struct ifaddrs;
NSArray<SZFriendsNATEndpoint *> *SZFriendsNATTCPHostAddresses(const struct ifaddrs *_Nullable list,
                                                             SZFriendsOnlinePurpose purpose,
                                                             const SZFriendsOnlineDefaultRoutes *routes,
                                                             BOOL loopbackOnly);
// This Mac's routes toward the Internet, read from the routing table now (SZFriendsNATRoute; nothing is sent).
SZFriendsOnlineDefaultRoutes SZFriendsNATReadDefaultRoutes(void);

NS_ASSUME_NONNULL_END
