// The helper's online transport: SZFriendsOnlineTransport over libdatachannel (ADR 0009), with the candidate rules
// of ADR 0011 and the pre-authentication rule of SZFriendsOnlineTransport.h. Helper-only.
//
// What this adds beside the frozen interface, for the order component (service/online/order/) and the NAT techniques
// (service/online/nat/):
//   - SZFriendsOnlineDirectPhaseTimer, the helper's own direct-phase clock (ADR 0011 § The direct phase): libjuice
//     only gives up after 39.55 s, so every direct connection carries this timer, started when both descriptions
//     are applied and stopped when a path opens or the connection ends;
//   - SZFriendsOnlineSidePath, the seam where the TCP simultaneous-open path plugs into a direct connection, so its
//     candidates and its stream reach the delegate like the data channel's;
//   - -addCleanup:, for work that must end with the connection (a router mapping of its port).
//
// Private host addresses (private IPv4, ULA) are offered to friends only, never to first contacts or download links
// (lead decision for M2), which is narrower than SZFriendsOnlinePurposeMayOfferPrivateHostCandidates in the frozen
// header: the transport applies the narrower rule, and dials private remote addresses for friends only too.

#import <Foundation/Foundation.h>

#import "service/online/SZFriendsOnlineTransport.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Direct-phase timer (ADR 0011, provisional values, lead decision 8)

extern const NSTimeInterval SZFriendsOnlineDirectPlainBudget;   // 5 s of plain checks
extern const NSTimeInterval SZFriendsOnlineDirectHardNATBudget; // up to 12 s more when exactly one side is hard

// Runs on the connection's queue. Expires once, after the plain budget, or after both budgets when hard-NAT probing
// was asked for before the plain budget ran out. Stopping it (a path opened, the connection ended) means it never
// expires. The offerer's timer rules (ADR 0011); an answerer's expiry is informational.
@interface SZFriendsOnlineDirectPhaseTimer : NSObject
// `scheduler` runs a block after a delay on `queue` (dispatch_after when nil); tests pass a scripted clock.
- (instancetype)initWithQueue:(dispatch_queue_t)queue
                    scheduler:(nullable void (^)(NSTimeInterval delay, dispatch_block_t block))scheduler
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Set by the order component; called on the queue when the budget runs out with no path open.
@property(nonatomic, copy, nullable) void (^onExpire)(void);
// Exactly one side's NAT maps per destination: extend the phase by SZFriendsOnlineDirectHardNATBudget.
@property(nonatomic) BOOL hardNATProbing;
@property(nonatomic, readonly) BOOL started, stopped, expired;
- (void)start; // idempotent; the transport calls it when both descriptions are applied
- (void)stop;  // idempotent; no expiry afterwards
@end

#pragma mark - Side paths (the TCP simultaneous-open path, ADR 0011)

@protocol SZFriendsOnlineSidePath;

// How a side path reports to its connection, on the connection's queue.
@protocol SZFriendsOnlineSidePathEvents <NSObject>
// An RFC 6544 candidate ("candidate:1 1 TCP ... typ host tcptype so"); filtered like gathered candidates and sent
// to the peer with SZFriendsOnlineTechniqueTCPSimultaneousOpen.
- (void)sidePath:(id<SZFriendsOnlineSidePath>)path didGatherLocalCandidate:(NSString *)candidate;
// A connected socket carrying a new ADR 0001 session; reported with SZFriendsOnlineTechniqueTCPSimultaneousOpen.
- (void)sidePath:(id<SZFriendsOnlineSidePath>)path didOpenStream:(id<SZFriendsByteStream>)stream ipv6:(BOOL)ipv6;
// The path is over: its budget ran out, it failed for good, or the stream it opened ended. It stays silent
// afterwards. The connection fails only once the data channel's path is over too.
- (void)sidePath:(id<SZFriendsOnlineSidePath>)path didFailWithError:(NSError *)error;
@end

@protocol SZFriendsOnlineSidePath <NSObject>
// Once, on the connection's queue, after the local description went to the delegate.
- (void)startWithQueue:(dispatch_queue_t)queue events:(id<SZFriendsOnlineSidePathEvents>)events;
// A remote TCP candidate (tcptype so) from the authenticated exchange, already checked against the purpose's
// address rules. NO refuses it.
- (BOOL)addRemoteCandidate:(NSString *)candidate error:(NSError *_Nullable *_Nullable)error;
// Ends the path and closes its stream; idempotent, silent afterwards.
- (void)close;
@end

#pragma mark - The transport

// Every connection this transport opens also conforms to this. A connection keeps its delegate until it closes or
// fails, so an owner that holds the connection from its delegate is released by -close.
@protocol SZFriendsOnlineConnectionExtras <SZFriendsOnlineConnection>
// The direct-phase timer of a direct connection; nil for relay and probe handover connections.
@property(nonatomic, readonly, nullable) SZFriendsOnlineDirectPhaseTimer *directPhase;
// Runs once on the queue when the connection closes or fails; at once if it already has.
- (void)addCleanup:(dispatch_block_t)cleanup;
@end

@interface SZFriendsOnlineDataChannelTransport : NSObject <SZFriendsOnlineTransport>
// The helper's one transport. Configures the stack on first use: one worker thread for every peer connection.
+ (instancetype)sharedTransport;
- (instancetype)init NS_UNAVAILABLE;
// The NAT area's TCP path, asked once per direct connection after it opens; nil, or a nil result, attaches none.
@property(atomic, copy, nullable) id<SZFriendsOnlineSidePath> _Nullable (^sidePathFactory)(
    id<SZFriendsOnlineConnectionRequest> request);
@end

NS_ASSUME_NONNULL_END
