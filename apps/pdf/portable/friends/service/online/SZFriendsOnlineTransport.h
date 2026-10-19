// Shenzhen Friends online transport: Internet connections to a peer, between the helper and the WebRTC stack.
//
// Helper-only. ADR 0009 (portable/friends/docs/adr/0009-online-transport.md) is the stack, ADR 0011
// (0011-nat-traversal.md) the techniques and their timers, ADR 0010 the host that forwards signalling and issues
// relay credentials; this header is their interface. Frozen for M2: change it only with the ADRs, in one change.
//
// Who does what:
//   - The order component (service/online/order/) decides when to open which connection, runs the direct-phase
//     timer, starts the relay and leaves it, and logs which technique connected.
//   - The signalling layer (service/session/SZFriendsSignaling*, over the host's sig_open/sig_msg) carries every
//     description and candidate below inside an authenticated exchange: Noise IK for friends and own devices, Noise
//     NN then acceptance for Add by ID online, payloads sealed under the link secret for download links.
//   - The transport (service/online/transport/, with the NAT techniques in service/online/nat/) implements
//     SZFriendsOnlineTransport: libdatachannel with libjuice, usrsctp and Mbed TLS, data channels only, plus our own
//     TCP simultaneous-open path.
//
// One connection is one attempt toward one peer:
//   - a direct connection: one peer connection (global IPv6, host, server-reflexive, port-mapped and predicted
//     candidates) and, beside it, the TCP simultaneous-open path, which carries the ADR 0001 stream with no DTLS;
//   - a probe handover connection: a peer connection bound to the port the hard-NAT prober found (ADR 0011);
//   - a relay connection: a new peer connection with relay candidates only, opened with TURN credentials from the
//     host. A running peer connection cannot gain a relay (libjuice takes no TURN server later and has no ICE
//     restart), so the relay is always a new connection, a new DTLS handshake and a new ADR 0001 session; ADR 0001
//     resumes transfers from the recipient's verified offset.
// Every stream a connection opens is a new ADR 0001 session on its own path; the session race (explicit rank: LAN,
// peer-to-peer Wi-Fi, Internet, Bluetooth, relay) keeps the best.
//
// PRE-AUTHENTICATION GATING (ADR 0009 § Who may reach the stack; mandatory, lead decision 6). ICE, DTLS and SCTP
// parse a remote party's bytes before Noise authenticates anyone, so a connection exists only toward a peer the
// signalling has established, and applies only what that signalling authenticated:
//   1. Friends and own devices (SZFriendsOnlinePurposeFriend; signalling is Noise IK under its own prologue).
//      - Offerer = IK initiator. Opens a connection only to dial a friend or own device whose identity key it
//        stores (request.peer is that key). Its offer and fingerprint travel only inside IK message 1, sealed to
//        that peer's static key. It applies nothing remote (answer, candidate) until IK message 2 has authenticated
//        the responder.
//      - Answerer = IK responder. Opens a connection only after IK message 1 decrypted, its certificate verified,
//        the replay cache found it fresh and the key policy accepted the initiator (never a removed or blocked key).
//        The offer and fingerprint from that message are in the request and applied before any gathering.
//   2. Add by ID online (SZFriendsOnlinePurposeFirstContact; Noise NN, which authenticates nobody). Neither side
//      opens a connection until the recipient has accepted the request. Sending and receiving requests never
//      reaches the stack.
//   3. Download links (SZFriendsOnlinePurposeLink). The sender's helper opens a connection only after the opener has
//      proved the link secret (HMAC over the sender's challenge, compared in constant time); descriptions and
//      candidates travel sealed under a key derived from the link secret. The opener's own helper may open its
//      offer once it holds the link (it only dials).
//   4. Fingerprints. Each side's DTLS certificate fingerprint travels inside the authenticated exchange beside its
//      description (the offerer's in IK message 1, the answerer's in IK message 2, and likewise sealed for links),
//      and is passed to the transport separately from the SDP. The transport refuses a description whose
//      a=fingerprint differs from the authenticated one and a DTLS peer whose certificate does not match it, so a
//      host that swaps fingerprints is caught instead of becoming a DTLS man in the middle.
//   5. Candidates. Remote candidates are added only when they arrived in the same authenticated exchange (Noise
//      transport messages of the signalling session, or link-sealed payloads), never from the host in the clear.
//   6. Relay and probe handover connections follow the rule of the direct connection that came first: same peer,
//      same purpose, new descriptions through the same authenticated signalling (the same sid while it lives, or a new
//      one that must be answered again before the host issues credentials).
// Until its answer is applied, the only remote bytes an offerer's peer connection parses are STUN messages on its
// socket, which pass only with the offer's ICE credentials (which only the peer read); DTLS and SCTP cannot start
// before a checked pair exists.
//
// Threading: every method is called, and every delegate callback arrives, on the queue given to -openConnection:.
// All addresses, candidates and descriptions stay in memory; none is logged or stored (ADR 0011 § Technique log).

#import <Foundation/Foundation.h>

#include <string.h>
#include <sys/socket.h>

#include <net/if.h>

#import "service/discovery/SZFriendsDiscovery.h"
#import "service/session/SZFriendsSession.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Limits (ADR 0009, ADR 0010, ADR 0011)

enum {
    // SHA-256 of the DTLS certificate (DER), as a=fingerprint carries it.
    SZFriendsOnlineFingerprintLength = 32,
    // Largest data-channel message the transport sends: every browser accepts 64 KiB (ADR 0009 § Configuration).
    SZFriendsOnlineMessageMax = 65536,
    // Largest signalling payload the host forwards (HOST-PROTOCOL.md protocol 2, sig_msg, before base64url). One
    // description with its fingerprint, or a batch of candidates, must fit after the signalling layer's sealing.
    SZFriendsOnlineSignalPayloadMax = 4096,
    // Remote candidates one peer connection accepts, every source together (libjuice ICE_MAX_CANDIDATES_COUNT).
    SZFriendsOnlineRemoteCandidateMax = 30,
    // Predicted-port candidates added for a per-destination NAT, within the cap above (ADR 0011 § Hard NATs).
    SZFriendsOnlinePredictedCandidateMax = 25,
};

#pragma mark - Purposes, kinds and techniques

// Why the connection exists; it fixes the gating rule above and which local candidates may be sent.
typedef NS_ENUM(NSInteger, SZFriendsOnlinePurpose) {
    SZFriendsOnlinePurposeFriend = 1,       // a friend or one's own device; signalling was Noise IK
    SZFriendsOnlinePurposeFirstContact = 2, // Add by ID online, after the recipient accepted; signalling was NN
    SZFriendsOnlinePurposeLink = 3,         // a download link, after the opener proved the link secret
};

// Offerer: creates the offer and opens the data channel; on the stream it is the ADR 0001 initiator and sends the
// preamble. Answerer: applies the offer before gathering (otherwise libjuice starts both sides as controlling and
// each connection pays a 487 role conflict and a 500 ms retransmission: 450 to 500 ms, NAT spike).
typedef NS_ENUM(NSInteger, SZFriendsOnlineRole) {
    SZFriendsOnlineRoleOfferer = 1,
    SZFriendsOnlineRoleAnswerer = 2,
};

typedef NS_ENUM(NSInteger, SZFriendsOnlineConnectionKind) {
    SZFriendsOnlineConnectionDirect = 1,        // ICE without relay candidates, plus TCP simultaneous open
    SZFriendsOnlineConnectionProbeHandover = 2, // bound to request.localPort; the prober's pair is the only one
    SZFriendsOnlineConnectionRelay = 3,         // relay candidates only, with request.relay's credentials
};

// Which technique carried a connected path, and which technique produced a candidate. Recorded by number in the
// local technique log (ADR 0011): never renumber. For a selected ICE pair the first that applies, in this order:
// Relay if either side is a relay candidate; ProbeHandover for a probe handover connection; PortMapping or
// PredictedPort if either side is such a candidate; ServerReflexive if either side is server-reflexive;
// PeerReflexive if either side was learnt during checks; HostIPv6 for two global IPv6 host candidates; HostPrivate
// otherwise (a private IPv4 or ULA pair: the same network seen online, or one public address shared by both).
typedef NS_ENUM(NSInteger, SZFriendsOnlineTechnique) {
    SZFriendsOnlineTechniqueNone = 0,
    SZFriendsOnlineTechniqueHostIPv6 = 1,            // global IPv6, no NAT on the path
    SZFriendsOnlineTechniqueHostPrivate = 2,         // private IPv4 or ULA host addresses (friends only)
    SZFriendsOnlineTechniqueServerReflexive = 3,     // UDP hole punching through the host's STUN (3478)
    SZFriendsOnlineTechniquePeerReflexive = 4,       // a mapping learnt from the peer's checks
    SZFriendsOnlineTechniquePortMapping = 5,         // a router mapping from PCP, NAT-PMP or UPnP IGD
    SZFriendsOnlineTechniquePredictedPort = 6,       // a predicted port of a per-destination NAT
    SZFriendsOnlineTechniqueProbeHandover = 7,       // the port pair hard-NAT probing found (birthday technique)
    SZFriendsOnlineTechniqueTCPSimultaneousOpen = 8, // our own TCP path: crossing SYNs, no listener
    SZFriendsOnlineTechniqueRelay = 9,               // the host's TURN relay, last resort, 5 Mbit/s
};

// Route class of a connected path: Relay for the relay technique, Internet (direct) for every other, None for
// None. These are the ADR 0001 route class numbers (SZFriendsDiscovery.h), never renumbered.
static inline SZFriendsRouteMethod SZFriendsOnlineRouteMethodForTechnique(SZFriendsOnlineTechnique technique) {
    if (technique == SZFriendsOnlineTechniqueNone) return SZFriendsRouteMethodNone;
    return technique == SZFriendsOnlineTechniqueRelay ? SZFriendsRouteMethodRelay : SZFriendsRouteMethodInternet;
}

// A connected path as the transport reports it: what the session's route class becomes and what the technique log
// records. A relayed connection can later settle on a shorter pair by itself (libjuice keeps pairing host and
// server-reflexive candidates under the relay-only policy), so a route can change while its stream stays open.
typedef struct {
    SZFriendsRouteMethod method;        // SZFriendsOnlineRouteMethodForTechnique(technique)
    SZFriendsOnlineTechnique technique; // never None once a stream is open
    BOOL ipv6;                          // the selected pair's address family
} SZFriendsOnlineRoute;

static inline SZFriendsOnlineRoute SZFriendsOnlineRouteMake(SZFriendsOnlineTechnique technique, BOOL ipv6) {
    SZFriendsOnlineRoute route = {SZFriendsOnlineRouteMethodForTechnique(technique), technique, ipv6};
    return route;
}

#pragma mark - Local candidates (ADR 0011 § VPN and tunnels)

// Online routes follow the system's default route, whichever interface holds it (no bypass of a VPN or TUN proxy;
// lead decision 9), and no address that would reach the peer around it is offered. Host candidates are never
// gathered from loopback; peer-to-peer Wi-Fi (awdl, llw: nearby's); tunnels (utun: every Network Extension VPN and
// TUN proxy; ipsec; ppp; gif and stf; tun and tap; wg); or virtual and overlay networks (feth: ZeroTier and other
// fake-Ethernet pairs; bridge: Internet Sharing and virtual machines; vmenet: Virtualization framework machines;
// anpi: internal interfaces of Apple silicon Macs), whose addresses would describe a private network to the peer.
static inline BOOL SZFriendsOnlineInterfaceMayOfferHostCandidates(const char *_Nullable name) {
    static const char *const refused[] = {"lo",  "awdl", "llw", "utun", "ipsec", "ppp",    "gif",    "stf",
                                          "tun", "tap",  "wg",  "feth", "bridge", "vmenet", "anpi"};
    if (name == NULL || name[0] == '\0') return NO;
    for (size_t i = 0; i < sizeof refused / sizeof refused[0]; i++) {
        size_t length = strlen(refused[i]);
        if (strncmp(name, refused[i], length) == 0) return NO;
    }
    return YES;
}

// The interfaces holding this Mac's routes toward the Internet, one per family, as the routing table answers for a
// destination (the question `route -n get` asks; nothing is sent): "" where a family has no such route or the table
// could not be read. Each family is asked for SZFriendsOnlineInternetRouteProbeCount destinations, one in each half
// of its address space, because a TUN proxy holds split default routes (0/1 and 128/1 on the owner's Mac) above a
// plain default route that still points at the LAN; when the answers differ, an interface that is never offered
// wins (SZFriendsOnlineDefaultRoutesAdd).
typedef struct {
    char ipv4[IFNAMSIZ];
    char ipv6[IFNAMSIZ];
} SZFriendsOnlineDefaultRoutes;

enum {
    SZFriendsOnlineInternetRouteProbeCount = 2,
};

// The destinations the routing table is asked about, by family and index. Only the kernel is asked; nothing is ever
// sent to them. IPv4: a documentation address (128/1) and a public one (0/1); IPv6: the two documentation prefixes,
// 2001:db8::/32 in 2000::/4 and 3fff::/20 in 3000::/4.
static inline const char *SZFriendsOnlineInternetRouteProbe(sa_family_t family, unsigned index) {
    static const char *const ipv4[SZFriendsOnlineInternetRouteProbeCount] = {"192.0.2.1", "8.8.8.8"};
    static const char *const ipv6[SZFriendsOnlineInternetRouteProbeCount] = {"2001:db8::1", "3fff::1"};
    return (family == AF_INET6 ? ipv6 : ipv4)[index % SZFriendsOnlineInternetRouteProbeCount];
}

// Records one answer: `name` holds the route toward one probe of that family (NULL or "": none). The first route
// found sets the family; a later one replaces it only when it is an interface that is never offered, so a tunnel
// holding either half of the address space holds the family.
static inline void SZFriendsOnlineDefaultRoutesAdd(SZFriendsOnlineDefaultRoutes *routes, BOOL ipv6,
                                                   const char *_Nullable name) {
    char *slot = ipv6 ? routes->ipv6 : routes->ipv4;
    if (name == NULL || name[0] == '\0') return;
    if (slot[0] != '\0' && SZFriendsOnlineInterfaceMayOfferHostCandidates(name)) return;
    strlcpy(slot, name, IFNAMSIZ);
}

// Tests build route tables with this; production code reads the routing table instead.
static inline SZFriendsOnlineDefaultRoutes SZFriendsOnlineDefaultRoutesMake(const char *_Nullable ipv4,
                                                                           const char *_Nullable ipv6) {
    SZFriendsOnlineDefaultRoutes routes;
    memset(&routes, 0, sizeof routes);
    SZFriendsOnlineDefaultRoutesAdd(&routes, NO, ipv4);
    SZFriendsOnlineDefaultRoutesAdd(&routes, YES, ipv6);
    return routes;
}

// Whether a family offers host candidates at all: only when an interface that may offer them holds its route toward
// the Internet. While a tunnel holds it, the other interfaces' addresses of that family (en0's stable global IPv6
// address, say) would reach the peer around the tunnel the person chose and tell it where they are; the
// server-reflexive address, learnt through the tunnel, is then this side's only address of that family. A family
// with no route toward the Internet offers none either.
static inline BOOL SZFriendsOnlineDefaultRouteAllowsHostCandidates(const SZFriendsOnlineDefaultRoutes *routes,
                                                                   BOOL ipv6) {
    return SZFriendsOnlineInterfaceMayOfferHostCandidates(ipv6 ? routes->ipv6 : routes->ipv4);
}

// The rule for one host address of this Mac, by its interface (getifaddrs) and family. The transport applies it to
// every host candidate before the delegate hears of it, and the TCP path to its own; both read the routing table
// again for each gathering, so a VPN that comes up or goes down between attempts is followed. Neither binds a socket
// to an interface or a specific address: every packet takes the route the system picks.
static inline BOOL SZFriendsOnlineMayOfferHostCandidate(const char *_Nullable name, BOOL ipv6,
                                                        const SZFriendsOnlineDefaultRoutes *routes) {
    return SZFriendsOnlineInterfaceMayOfferHostCandidates(name) &&
           SZFriendsOnlineDefaultRouteAllowsHostCandidates(routes, ipv6);
}

// Which host addresses a purpose may offer, beside server-reflexive, port-mapped and relay candidates, and which
// private addresses it may dial. Friends and one's own devices may also be offered private IPv4 and ULA addresses
// (nearby already shows them those). First contacts and download links are offered global IPv6 host addresses only:
// an accepted Add by ID request authenticates nobody, libdatachannel does not hide local addresses behind mDNS names
// as browsers do, and anyone holding a link would otherwise learn them. Never link-local, never loopback, never an
// address the rules above refuse.
static inline BOOL SZFriendsOnlinePurposeMayOfferPrivateHostCandidates(SZFriendsOnlinePurpose purpose) {
    return purpose == SZFriendsOnlinePurposeFriend;
}

#pragma mark - Errors

extern NSErrorDomain const SZFriendsOnlineErrorDomain; // defined by the transport area

// Reported by -openConnection:..., the apply and add methods, and -onlineConnection:didFailWithError:. None is
// shown to people; the order component maps them to its next phase and the technique log.
typedef NS_ERROR_ENUM(SZFriendsOnlineErrorDomain, SZFriendsOnlineError) {
    SZFriendsOnlineErrorNotAuthorized = 1,       // the request breaks the gating rule (no peer, an answerer
                                                 // without an authenticated offer, a relay without credentials)
    SZFriendsOnlineErrorDescriptionInvalid = 2,  // malformed SDP, no data channel, wrong type, applied twice
    SZFriendsOnlineErrorFingerprintMismatch = 3, // a=fingerprint or the DTLS certificate is not the authenticated one
    SZFriendsOnlineErrorCandidateRefused = 4,    // malformed, over SZFriendsOnlineRemoteCandidateMax, or an address
                                                 // the purpose never dials (private for links, loopback, multicast)
    SZFriendsOnlineErrorConnectivityFailed = 5,  // every path of this connection failed (libjuice gave up after
                                                 // 39.55 s, the TCP path's budget ran out)
    SZFriendsOnlineErrorRelayRefused = 6,        // TURN refused the credentials (401), the peer (403) or the quota
    SZFriendsOnlineErrorPeerClosed = 7,          // the peer ended DTLS or SCTP
    SZFriendsOnlineErrorUnavailable = 8,         // the stack could not start: no socket, request.localPort taken
};

#pragma mark - Connections

@protocol SZFriendsOnlineConnection;

// TURN credentials from the host's relay_credentials_result (ADR 0010; HOST-PROTOCOL.md protocol 2).
@protocol SZFriendsOnlineRelayCredentials <NSObject>
@property(nonatomic, readonly, copy) NSString *turnURI;    // turn:host:3478?transport=udp, from the signed list
@property(nonatomic, readonly, copy) NSString *username;   // "<expires>:<attempt id>"
@property(nonatomic, readonly, copy) NSString *credential; // base64 HMAC-SHA1, the TURN REST scheme
@property(nonatomic, readonly) NSDate *expires;            // an allocation must start before this
@end

// What the order component asks for. Implemented by the caller; read once, by -openConnection:..., which copies
// what it keeps.
@protocol SZFriendsOnlineConnectionRequest <NSObject>
@property(nonatomic, readonly) SZFriendsOnlinePurpose purpose;
@property(nonatomic, readonly) SZFriendsOnlineRole role;
@property(nonatomic, readonly) SZFriendsOnlineConnectionKind kind;
// The peer as the signalling established it (gating rule): for friends, own devices and first contacts the
// 32-byte Ed25519 identity key; for links the 16-byte link id.
@property(nonatomic, readonly, copy) NSData *peer;
// The host's STUN URI from the signed host list's turn_uris (stun:host:3478). One per peer connection (ADR 0009);
// the two-port NAT classification runs outside the connection (ADR 0011). Nil gathers no server-reflexive
// candidate. Never a third-party server.
@property(nonatomic, readonly, copy, nullable) NSString *stunURI;
// Required for SZFriendsOnlineConnectionRelay, nil otherwise.
@property(nonatomic, readonly, nullable) id<SZFriendsOnlineRelayCredentials> relay;
// The local UDP port to bind exactly (portRangeBegin = portRangeEnd): the prober's port for a probe handover
// connection; 0 lets the system choose. The bound port is reported as localPort either way.
@property(nonatomic, readonly) uint16_t localPort;
// Answerer only, required: the offer and the offerer's fingerprint (SZFriendsOnlineFingerprintLength bytes) from
// the authenticated exchange. Applied before gathering. Nil for an offerer.
@property(nonatomic, readonly, copy, nullable) NSString *remoteOfferSDP;
@property(nonatomic, readonly, copy, nullable) NSData *remoteFingerprint;
@end

// Callbacks on the connection's queue, in this order for one connection: one local description; local candidates
// (any number, interleaved with the rest) and at most one -onlineConnectionDidFinishGathering:; then streams and
// route changes; at most one -onlineConnection:didFailWithError:, after which nothing arrives. Nothing arrives
// after -close returns.
@protocol SZFriendsOnlineConnectionDelegate <NSObject>
// The local description for the signalling layer to send inside the authenticated exchange: the offer (offerer)
// or the answer (answerer), with this side's fingerprint carried beside it, never only inside the SDP. The SDP has
// no candidates (they trickle) and one data-channel section.
- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
    didCreateLocalDescription:(NSString *)sdp
                  fingerprint:(NSData *)fingerprint;
// One local candidate for the peer: an RFC 8839 candidate attribute value without "a=" ("candidate:1 1 UDP ...").
// Already filtered by the purpose and interface rules above. TCP simultaneous-open endpoints arrive here too, as
// TCP candidates with tcptype so (RFC 6544), with SZFriendsOnlineTechniqueTCPSimultaneousOpen. The signalling layer
// sends the technique with the candidate so the peer's route report can name it.
- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
    didGatherLocalCandidate:(NSString *)candidate
                  technique:(SZFriendsOnlineTechnique)technique;
// Local gathering ended (host, server-reflexive, and relay for a relay connection). Injected candidates may still
// follow through -addLocalCandidate:technique:.
- (void)onlineConnectionDidFinishGathering:(id<SZFriendsOnlineConnection>)connection;
// A path connected and its stream is open: a reliable, ordered data channel (or the TCP path) for one new ADR 0001
// session, the offerer as initiator. May be called once for the data channel and once for the TCP path; each stream
// is its own session and the session race keeps the better one. The stream:
//   - preferredWriteSize is SZFriendsOnlineMessageMax;
//   - -writeData: sends the bytes as one data-channel message when they fit in SZFriendsOnlineMessageMax, otherwise
//     as consecutive messages of that size; onData delivers one message at a time. ADR 0001 reads a byte stream
//     and ignores the boundaries; the links protocol writes one sealed record of at most SZFriendsOnlineMessageMax
//     per write, so a browser receives one record per message;
//   - a write's completion is held while the channel's buffered amount is above its high-water mark and runs at its
//     low-water callback, so ADR 0001's send window, not the channel, bounds memory;
//   - closing the stream closes that path only.
- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
           didOpenStream:(id<SZFriendsByteStream>)stream
                   route:(SZFriendsOnlineRoute)route;
// The selected pair under an open stream changed (a relayed connection settling on a direct pair, IPv4 to IPv6).
- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
                  stream:(id<SZFriendsByteStream>)stream
          didChangeRoute:(SZFriendsOnlineRoute)route;
// Terminal: every path failed before a stream opened, the fingerprint did not match, or the peer closed. Streams
// already open report their own onClose; the connection is closed when this arrives.
- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection didFailWithError:(NSError *)error;
@end

@protocol SZFriendsOnlineConnection <NSObject>
@property(nonatomic, readonly) SZFriendsOnlinePurpose purpose;
@property(nonatomic, readonly) SZFriendsOnlineRole role;
@property(nonatomic, readonly) SZFriendsOnlineConnectionKind kind;
@property(nonatomic, readonly, copy) NSData *peer;
// This side's DTLS certificate fingerprint, the one sent with the local description.
@property(nonatomic, readonly, copy) NSData *localFingerprint;
// The UDP port the peer connection is bound to, for a router port mapping and for the hard-NAT prober; 0 until bound.
@property(nonatomic, readonly) uint16_t localPort;
// The best open path, or {None, None, NO} while none is open.
@property(nonatomic, readonly) SZFriendsOnlineRoute route;

// Offerer only, once: the answer and the answerer's fingerprint from the authenticated exchange. NO with
// SZFriendsOnlineErrorDescriptionInvalid or SZFriendsOnlineErrorFingerprintMismatch, and the delegate then hears
// -onlineConnection:didFailWithError: with the same error.
- (BOOL)applyRemoteAnswerSDP:(NSString *)sdp
           remoteFingerprint:(NSData *)fingerprint
                       error:(NSError *_Nullable *_Nullable)error;
// A remote candidate from the authenticated exchange, with the technique the peer named (or PredictedPort for one
// the order component predicted). An offerer accepts candidates only after its answer is applied. NO with
// SZFriendsOnlineErrorCandidateRefused leaves the connection running.
- (BOOL)addRemoteCandidate:(NSString *)candidate
                 technique:(SZFriendsOnlineTechnique)technique
                     error:(NSError *_Nullable *_Nullable)error;
// The peer has sent its last candidate. Predicted candidates may still be added after it.
- (void)remoteCandidatesDidEnd;
// A candidate this side found outside the stack, for the peer: a router mapping of localPort
// (SZFriendsOnlineTechniquePortMapping). Recorded for the route report and passed to the delegate like a gathered
// candidate.
- (void)addLocalCandidate:(NSString *)candidate technique:(SZFriendsOnlineTechnique)technique;
// Ends this connection and everything it started: gathering, checks, the TCP path, any router mapping requested
// for its port, and its open streams, whose onClose runs with no error. This is also how an attempt is cancelled
// (a better route won, the person cancelled, the signalling ended, a budget ran out). Idempotent; once it returns
// the delegate hears nothing more.
- (void)close;
@end

// The transport. One per helper; -openConnection:... never blocks on the network.
@protocol SZFriendsOnlineTransport <NSObject>
// Starts a connection: an offerer creates its offer, an answerer applies request.remoteOfferSDP and creates its
// answer, both then gather. Returns nil with SZFriendsOnlineErrorNotAuthorized when the request breaks the gating
// rule as far as the transport can see it (purpose, role, peer length, a missing offer or fingerprint, a relay
// without credentials), or SZFriendsOnlineErrorUnavailable.
- (nullable id<SZFriendsOnlineConnection>)openConnection:(id<SZFriendsOnlineConnectionRequest>)request
                                                delegate:(id<SZFriendsOnlineConnectionDelegate>)delegate
                                                   queue:(dispatch_queue_t)queue
                                                   error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
