// Shenzhen Friends online order: when an Internet attempt opens which connection, and when it leaves the relay.
//
// Helper-only. ADR 0011 § Decision (the direct phase, its timers, leaving the relay, the technique log) is the
// decision; SZFriendsOnlineTransport.h is the transport this drives. The owner's words: "direct connection then p2p
// then bluetooth then server"; "Use peer to peer, hole-punching, anything before relay"; the relay "only in last
// resort for online friends if everything fails". Pure: no sockets, no queues. The clock and the jitter are injected,
// so every phase and timer is tested with a scripted clock.
//
// One order per attempt toward one peer (one sid; with several devices the host gives the attempt to the first one
// that answers, ADR 0010). The helper feeds it what happened and carries out the actions each call returns, in this
// order: StopProbing, CloseDirect, CloseRelay, then OpenDirect, OpenRelay, StartPrediction, StartProbing, then
// SignalNetworkChange. End means: close everything this attempt holds, append its log entry, drop the order. The
// helper also asks it -nextDeadline after every call and calls -fireDueTimers then.
//
// Phases, as the offerer runs them (the offerer's timer rules; the answerer never starts the relay or probing
// itself, it follows the offerer's signalling and has no timers):
//   Signalling   until both descriptions are applied (offerer: the authenticated answer; answerer: its answer sent).
//   PlainChecks  the direct connection checks every plain technique at once, for SZFriendsOnlinePlainChecksBudget.
//   HardNAT      only when exactly one side's NAT maps per destination: prediction and probing, for up to
//                SZFriendsOnlineHardNATBudget more.
//   Relay        the budget ran out with no direct path and no other route working: the relay connection opens
//                (credentials, then a new peer connection). The direct connection keeps checking meanwhile.
//   Relayed      the relay carries the stream. A new direct connection is tried after every network change and
//                periodically (SZFriendsOnlineRetryFirst after the relay connected, doubling to
//                SZFriendsOnlineRetryMax, with SZFriendsOnlineRetryJitter); the first one to connect replaces the
//                relay, and ADR 0001 resumes transfers from the verified offset on the new session.
//   Standby      the budget ran out while another route carries the session (Bluetooth, or another attempt's relay):
//                no relay of our own; direct is retried as while relayed, since Internet ranks before Bluetooth.
//   Direct       a direct path carries the stream.
//   Ended        see endReason.
// The relay is never used while another route works: a working route outside this attempt (-otherRouteChanged:)
// keeps the relay closed or closes it, and one that ranks before Internet (or a second Internet session that came
// first) ends the attempt.

#import <Foundation/Foundation.h>

#import "service/online/SZFriendsOnlineTransport.h"
#import "service/online/nat/SZFriendsNAT.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Timers (ADR 0011; provisional values for tests, lead decision 8; the M0 matrix sets the real ones)

extern const NSTimeInterval SZFriendsOnlinePlainChecksBudget;     // 5 s from both descriptions
extern const NSTimeInterval SZFriendsOnlineHardNATBudget;         // 12 s more, with exactly one hard side
extern const NSTimeInterval SZFriendsOnlineRetryFirst;            // 30 s after the relay connected
extern const NSTimeInterval SZFriendsOnlineRetryMax;              // 300 s: doubling stops here
extern const double SZFriendsOnlineRetryJitter;                   // 0.2: each wait is drawn from +/-20%
extern const NSTimeInterval SZFriendsOnlineRetrySignallingLimit;  // 10 s for a retry's descriptions to arrive

// Whether an Internet attempt could still improve on the route carrying the session now: only when that route ranks
// after Internet (none, Bluetooth, the relay). Never beside a LAN or peer-to-peer Wi-Fi session, nor a second one
// beside an Internet session (within the class the first path keeps the session).
BOOL SZFriendsOnlineAttemptWorthStarting(SZFriendsRouteMethod current);

#pragma mark - Inputs and outputs

// Each side's NAT class (SZFriendsNAT.h: the two-port classifier's reading, sent with each description). The hard-NAT
// techniques run only when exactly one side maps per destination and the other is known to map independently (both
// hard: about 0.0003 at 1,024 probes each, not worth the packets; unknown: the plain checks were all there was).
BOOL SZFriendsOnlineHardNATWorthTrying(SZFriendsNATClass local, SZFriendsNATClass remote);

typedef NS_ENUM(NSInteger, SZFriendsOnlinePhase) {
    SZFriendsOnlinePhaseSignalling = 0,
    SZFriendsOnlinePhasePlainChecks = 1,
    SZFriendsOnlinePhaseHardNAT = 2,
    SZFriendsOnlinePhaseRelay = 3,
    SZFriendsOnlinePhaseRelayed = 4,
    SZFriendsOnlinePhaseStandby = 5,
    SZFriendsOnlinePhaseDirect = 6,
    SZFriendsOnlinePhaseEnded = 7,
};

// Why an attempt ended. Recorded in the technique log by number: never renumber.
typedef NS_ENUM(NSInteger, SZFriendsOnlineEndReason) {
    SZFriendsOnlineEndNone = 0,         // not ended
    SZFriendsOnlineEndClosed = 1,       // -close: the person cancelled, the signalling ended, the helper stopped
    SZFriendsOnlineEndSuperseded = 2,   // a better route, or an earlier Internet session, carries the session
    SZFriendsOnlineEndUnreachable = 3,  // every path failed: direct, probing and the relay
    SZFriendsOnlineEndStreamClosed = 4, // the stream that carried the session closed (the helper may dial again)
};

typedef NS_OPTIONS(NSUInteger, SZFriendsOnlineOrderActions) {
    SZFriendsOnlineOrderActionNone = 0,
    // Close the prober and any probe handover connection that has no stream yet.
    SZFriendsOnlineOrderActionStopProbing = 1 << 0,
    // Close the attempt's direct connection (with its TCP path) unless it carries the stream.
    SZFriendsOnlineOrderActionCloseDirect = 1 << 1,
    SZFriendsOnlineOrderActionCloseRelay = 1 << 2,
    // A new direct connection: the offerer offers it through the signalling; the answerer answers the peer's offer.
    SZFriendsOnlineOrderActionOpenDirect = 1 << 3,
    // Offerer: ask the host for TURN credentials, open a relay connection and offer it. Answerer: ask for its own
    // credentials and answer the peer's relay offer.
    SZFriendsOnlineOrderActionOpenRelay = 1 << 4,
    // Port prediction (ADR 0011 § Port prediction): the easy side adds the hard side's predicted ports. On the
    // offerer this also tells the answerer, whose order hears -peerStartedHardNAT.
    SZFriendsOnlineOrderActionStartPrediction = 1 << 5,
    // One probing run (ADR 0011 § Probing budget). The prober admits it against the helper's one budget
    // (SZFriendsNATProbeBudget: one run at a time, one per peer per 10 minutes) and reports a refusal through
    // -probingEndedRefused:.
    SZFriendsOnlineOrderActionStartProbing = 1 << 6,
    // Answerer: tell the offerer this side's network changed, so it tries direct again (-peerNetworkChanged).
    SZFriendsOnlineOrderActionSignalNetworkChange = 1 << 7,
    // The attempt is over (endReason): close every connection and the prober, record the log entry.
    SZFriendsOnlineOrderActionEnd = 1 << 8,
};

#pragma mark - Technique log (ADR 0011 § Technique log)

// What one attempt tried and what connected, for the support matrix. Numbers only: no address, port, key, ID or
// name, and no wall time.
@interface SZFriendsTechniqueLogEntry : NSObject
@property(nonatomic) SZFriendsOnlinePurpose purpose;
@property(nonatomic) SZFriendsOnlineRole role;
@property(nonatomic) SZFriendsNATClass localNATClass;
@property(nonatomic) SZFriendsNATClass remoteNATClass;
@property(nonatomic) NSUInteger techniquesTried;               // bit (1 << SZFriendsOnlineTechnique) per technique
@property(nonatomic) SZFriendsOnlineTechnique firstTechnique;  // what carried the first stream; None when none did
@property(nonatomic) SZFriendsOnlineTechnique finalTechnique;  // what carried the stream last
@property(nonatomic) NSTimeInterval secondsToFirstStream;      // from the first descriptions; -1 when none opened
@property(nonatomic) BOOL relayRequested;
@property(nonatomic) BOOL relayNeeded;                         // the relay carried a stream
@property(nonatomic) BOOL leftRelay;                           // and a direct path replaced it later
@property(nonatomic) NSUInteger directRetries;                 // new direct connections after the first
@property(nonatomic) SZFriendsOnlineEndReason endReason;
// The entry as JSON-ready numbers, and back. A dictionary with any other key, or a value out of range, is refused.
- (NSDictionary<NSString *, NSNumber *> *)propertyList;
+ (nullable instancetype)entryWithPropertyList:(id)propertyList;
@end

// The local log: the newest entries, oldest first, at most `capacity`. The helper appends an attempt's entry when it
// ends and keeps the JSON in its state directory.
@interface SZFriendsTechniqueLog : NSObject
- (instancetype)initWithCapacity:(NSUInteger)capacity NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)appendEntry:(SZFriendsTechniqueLogEntry *)entry;
@property(nonatomic, readonly) NSArray<SZFriendsTechniqueLogEntry *> *entries;
- (NSData *)JSONData;
// Reads what -JSONData wrote, skipping entries it refuses; nil when the data is not a JSON array.
- (nullable instancetype)initWithJSONData:(NSData *)data capacity:(NSUInteger)capacity;
@end

#pragma mark - The order

@interface SZFriendsOnlineOrder : NSObject
// `clock` reads a clock that never goes back (the helper passes SZFriendsInstantNow().continuous); `random` returns
// a value in [0, 1) for the retry jitter.
- (instancetype)initWithRole:(SZFriendsOnlineRole)role
                     purpose:(SZFriendsOnlinePurpose)purpose
                       clock:(NSTimeInterval (^)(void))clock
                      random:(double (^)(void))random NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) SZFriendsOnlineRole role;
@property(nonatomic, readonly) SZFriendsOnlinePhase phase;
@property(nonatomic, readonly) SZFriendsOnlineEndReason endReason;
// When -fireDueTimers next has something to do; INFINITY when nothing is scheduled.
@property(nonatomic, readonly) NSTimeInterval nextDeadline;
// A snapshot of what this attempt did so far.
@property(nonatomic, readonly) SZFriendsTechniqueLogEntry *logEntry;

// Both descriptions of the current direct connection are applied, with each side's NAT class.
- (SZFriendsOnlineOrderActions)descriptionsAppliedWithLocalNATClass:(SZFriendsNATClass)local
                                                     remoteNATClass:(SZFriendsNATClass)remote;
// A candidate of this technique was sent or added (for the log; the order records its own techniques itself).
- (void)noteTechniqueTried:(SZFriendsOnlineTechnique)technique;
// The transport's callbacks, by the kind of connection they came from.
- (SZFriendsOnlineOrderActions)streamOpenedOnConnection:(SZFriendsOnlineConnectionKind)kind
                                                  route:(SZFriendsOnlineRoute)route;
- (SZFriendsOnlineOrderActions)routeChangedOnConnection:(SZFriendsOnlineConnectionKind)kind
                                                  route:(SZFriendsOnlineRoute)route;
// -onlineConnection:didFailWithError: (the connection is gone; no Close action follows for it).
- (SZFriendsOnlineOrderActions)connectionFailed:(SZFriendsOnlineConnectionKind)kind;
// A stream this attempt opened closed (the session ended or lost the session race).
- (SZFriendsOnlineOrderActions)streamClosedOnConnection:(SZFriendsOnlineConnectionKind)kind;
// The best route carrying a session with this peer outside this attempt (nearby, or another attempt); None when
// none does.
- (SZFriendsOnlineOrderActions)otherRouteChanged:(SZFriendsRouteMethod)route;
// The default route changed (the path monitor), or the classifier measured this network's NAT again.
- (SZFriendsOnlineOrderActions)networkChanged;
- (SZFriendsOnlineOrderActions)localNATClassChanged:(SZFriendsNATClass)local;
// The prober ended without a probe handover connection: no hit within its budget, or (refused) the budget allowed
// no run toward this peer now.
- (SZFriendsOnlineOrderActions)probingEndedRefused:(BOOL)refused;
// The offerer's signalling, as the answerer hears it.
- (SZFriendsOnlineOrderActions)peerStartedHardNAT;
- (SZFriendsOnlineOrderActions)peerOpenedRelay;
- (SZFriendsOnlineOrderActions)peerOpenedDirect;
// The answerer's network changed (offerer only).
- (SZFriendsOnlineOrderActions)peerNetworkChanged;
- (SZFriendsOnlineOrderActions)fireDueTimers;
// Ends the attempt (Closed). Idempotent.
- (SZFriendsOnlineOrderActions)close;
@end

NS_ASSUME_NONNULL_END
