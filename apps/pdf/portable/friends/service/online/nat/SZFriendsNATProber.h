// Hard-NAT probing, the birthday technique (ADR 0011 § Hard NATs, § Probing budget; lead decision 12), as a side
// channel beside libjuice, which has one socket per agent and room for 30 remote candidates.
//
// It runs only when exactly one side's NAT maps per destination, and only one side probes:
//   - the hard side opens up to 256 UDP sockets and sends one probe from each to the easy side's server-reflexive
//     address, opening 256 mappings on its NAT;
//   - the easy side sends probes from its one socket to random ports of the hard side's public address, 100 a second,
//     at most 1,148 (99% for 256 open ports), within 12 s.
// So at most 1,404 probes of at most 96 bytes per attempt. Probes are STUN Binding requests under short-term
// credentials from this attempt's authenticated signalling (USERNAME "<their ufrag>:<our ufrag>", MESSAGE-INTEGRITY
// with the receiver's password, FINGERPRINT); a request or answer counts only if its integrity checks and it comes
// from the peer's address, so a stray packet cannot win. Both sides answer every valid request (at most 64 a run).
// The easy side decides the pair, as ICE's controlling side does: the first of its requests whose answer comes back
// (a random probe, or a request back to a hard-side socket whose probe reached it) selects that pair, and it
// nominates it with a request carrying USE-CANDIDATE, sent up to 5 times 100 ms apart. The nomination is the hard
// side's hit, so both sides always agree on the pair. A side with a pair stops probing, closes every other socket,
// keeps answering on the winning one for the linger (500 ms; the easy side stops early once its nomination is
// answered), closes it, and reports the pair. The order component then opens a probe handover connection bound to
// exactly the winning local port, with the winning remote address as its only remote candidate (the handover
// worked 20 of 20 rounds on loopback; whether a NAT keeps the mapping across it is a release gate).
//
// Probes go only to the public address the authenticated peer reported, and only when the peer presented it in this
// attempt (`presented`): never a private, shared, loopback, link-local, multicast or reserved address, nor one of this
// Mac's own, nor one the caller names on its own, so the prober cannot be aimed at a third party. Its sockets are
// bound to the unspecified address, never to an interface, so probes take the system's default route (lead decision
// 9), through a VPN or TUN proxy that holds it. At most one run per peer per 10 minutes and one at a time per helper
// (SZFriendsNATProbeBudget).

#import "service/online/nat/SZFriendsNAT.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SZFriendsNATProbeRole) {
    SZFriendsNATProbeRoleHard = 1, // this side's NAT maps per destination: open many sockets
    SZFriendsNATProbeRoleEasy = 2, // this side's NAT maps independently: probe random ports from one socket
};

enum {
    SZFriendsNATProbeSockets = 256,
    SZFriendsNATProbeMax = 1148,
    SZFriendsNATProbesPerSecond = 100,
    SZFriendsNATProbeUfragMin = 4,
    SZFriendsNATProbeUfragMax = 16,
    SZFriendsNATProbePasswordMin = 22, // as ICE (RFC 8839 § 5.4): at least 128 bits
};

// One run per peer per 10 minutes and one at a time per helper. Thread-safe.
@interface SZFriendsNATProbeBudget : NSObject
@property(class, nonatomic, readonly) SZFriendsNATProbeBudget *sharedBudget;
// `clock` counts seconds (nil: CLOCK_MONOTONIC); tests inject one.
- (instancetype)initWithInterval:(NSTimeInterval)interval
                           clock:(nullable NSTimeInterval (^)(void))clock NS_DESIGNATED_INITIALIZER;
- (instancetype)init; // 600 s
// YES, starting a run, when no run is going and `peer` has not run within the interval.
- (BOOL)beginRunForPeer:(NSData *)peer;
- (void)endRun;
@end

@interface SZFriendsNATProberConfiguration : NSObject <NSCopying>
@property(nonatomic) SZFriendsNATProbeRole role;
@property(nonatomic, copy) NSData *peer; // whom the budget counts against: the identity key or link id
// Hard side: the easy side's prober address and port (from the easy side's -prepare..., through the signalling).
// Easy side: the hard side's public address (its port is ignored: the probes go to random ports).
@property(nonatomic, strong) SZFriendsNATEndpoint *remote;
// What the peer presented in this attempt's authenticated signalling: its candidates' addresses and ports, and the
// easy prober's reflexive address. The hard side probes only a `remote` equal to one of them, address and port; the
// easy side only a `remote` whose address one of them has (its probes go to random ports of that address). Empty or
// nil: the prober refuses to start (SZFriendsNATErrorAddressRefused).
@property(nonatomic, copy, nullable) NSArray<SZFriendsNATEndpoint *> *presented;
// Easy side: the host's STUN server (3478), through which -prepare... learns the prober socket's own public
// address. In loopback tests a loopback server, or nil when no NAT is emulated and that address is the socket's own.
@property(nonatomic, strong, nullable) SZFriendsNATEndpoint *stunServer;
// Short-term credentials from the authenticated signalling: ufrags of 4 to 16 ICE characters, passwords of at
// least 22.
@property(nonatomic, copy) NSString *localUfrag;
@property(nonatomic, copy) NSString *localPassword;
@property(nonatomic, copy) NSString *remoteUfrag;
@property(nonatomic, copy) NSString *remotePassword;
@property(nonatomic, strong) SZFriendsNATProbeBudget *budget; // sharedBudget unless a test gives its own
@property(nonatomic) NSTimeInterval duration;                 // 12 s
@property(nonatomic) NSUInteger socketCount;                  // hard side: 256
@property(nonatomic) NSUInteger probeMax;                     // easy side: 1,148
@property(nonatomic) NSTimeInterval linger;                   // 0.5 s after a hit
// The ports the easy side picks from: 1024 to 65535.
@property(nonatomic) uint16_t portRangeLow;
@property(nonatomic) uint16_t portRangeHigh;
// Tests: probe and bind on loopback only (every non-loopback remote is refused), and optionally bind the hard side's
// sockets to these ports instead of letting the system choose, so a test can keep the probes inside ports it holds.
@property(nonatomic) BOOL loopbackOnly;
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *localPorts;
// Within ADR 0011's bounds: a role, a peer, a remote, well-formed credentials, at most 256 sockets, 1,148 probes,
// 12 s and a 1 s linger. A prober refuses to start otherwise.
@property(nonatomic, readonly, getter=isValid) BOOL valid;
@end

// The pair a hit found: the local UDP port to bind the handover connection to, and the peer's address and port.
@interface SZFriendsNATProbeHit : NSObject
@property(nonatomic, readonly) uint16_t localPort;
@property(nonatomic, readonly) SZFriendsNATEndpoint *remote;
@property(nonatomic, readonly) NSUInteger probesSent; // for the technique log
- (instancetype)init NS_UNAVAILABLE;
@end

// Its sockets and timers run on the queue given to the first of -prepare... or -start...; -cancel may come from any
// thread. The hard side raises the process's soft limit on open descriptors to 1,024 when it is lower (macOS starts
// processes at 256), since 256 sockets would not fit beside the helper's own.
@interface SZFriendsNATProber : NSObject
- (instancetype)initWithConfiguration:(SZFriendsNATProberConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Easy side, before -start...: binds the one prober socket and learns its public address through the STUN server,
// which the signalling sends to the hard side as its `remote`. The hard side's initial probes must reach this
// socket's mapping, not the connection's: a NAT that filters by port drops anything else. Runs once; the
// completion runs once on `queue`. The hard side needs no preparation.
- (void)prepareOnQueue:(dispatch_queue_t)queue
            completion:(void (^)(SZFriendsNATEndpoint *_Nullable reflexive, NSError *_Nullable error))completion;
// Runs once. The completion runs once on `queue`: a hit, with every prober socket already closed so the handover
// connection can bind its port; or an error (SZFriendsNATErrorBudget; AddressRefused; Unsupported for a
// configuration that is not valid; TimedOut; Socket; Cancelled).
- (void)startOnQueue:(dispatch_queue_t)queue
          completion:(void (^)(SZFriendsNATProbeHit *_Nullable hit, NSError *_Nullable error))completion;
// Closes every socket; the completion runs with SZFriendsNATErrorCancelled unless it already ran.
- (void)cancel;
@property(nonatomic, readonly) NSUInteger probesSent;
@end

NS_ASSUME_NONNULL_END
