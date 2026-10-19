// An attempt's private state, split by concern so each file reads on its own: SZFriendsOnlineAttempt.m (signalling:
// IK, items both ways), +Connections (the transport's callbacks, the order's actions and timers) and +NAT (port
// mapping, prediction, probing). Internal to service/online/driver/.

#import "service/online/driver/SZFriendsOnlineDriverInternal.h"

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsNATPortMapping;
@class SZFriendsNATProber;

// One connection of the attempt, by its number in the signalling (SZFriendsSignalTagConnection).
@interface SZFriendsOnlineSlot : NSObject
@property(nonatomic) uint8_t number;
@property(nonatomic) SZFriendsOnlineConnectionKind kind;
@property(nonatomic, strong, nullable) id<SZFriendsOnlineConnection> connection;
// Remote input may be applied: the offerer has applied the authenticated answer; the answerer applied the offer.
@property(nonatomic) BOOL remoteReady;
@property(nonatomic) NSUInteger openStreams;
@property(nonatomic, strong, nullable) SZFriendsOnlineTCPSidePath *sidePath;
@property(nonatomic, strong, nullable) SZFriendsNATPortMapping *portMapping;
@property(nonatomic, strong, nullable) id portMappingSink; // its delegate, which it holds weakly
@property(nonatomic) BOOL portMappingAsked;
// The peer's first server-reflexive candidate on this connection (the hard side's mapping, for prediction and as
// the public address the easy prober aims at), and how many UDP candidates the stack took.
@property(nonatomic, strong, nullable) SZFriendsNATEndpoint *remoteReflexive;
@property(nonatomic) NSUInteger remoteCandidates;
// The endpoints of the peer's UDP candidates the stack took on this connection, in order: what the peer presented
// in this attempt's authenticated signalling, the only addresses the easy prober may aim at.
@property(nonatomic, readonly) NSMutableArray<SZFriendsNATEndpoint *> *remoteEndpoints;
@end

@interface SZFriendsOnlineAttempt () {
  @package
    SZFriendsOnlineContext *_context;
    __weak id<SZFriendsOnlineAttemptOwner> _owner;
    SZFriendsOnlineFriend *_friend;
    SZFriendsOnlineRole _role;
    SZFriendsOnlineOrder *_order;
    SZFriendsSignalingSession *_Nullable _session;
    id<SZFriendsOnlineSignalChannel> _Nullable _channel;
    BOOL _opening;  // offerer: a sid with IK message 1 is being opened
    BOOL _replied;  // answerer: IK message 2 went out on the current sid
    NSArray<SZFriendsSignalItem *> *_Nullable _initialItems;
    NSMutableDictionary<NSNumber *, SZFriendsOnlineSlot *> *_slots;
    SZFriendsOnlineSlot *_Nullable _direct, *_Nullable _relay, *_Nullable _probe;
    NSUInteger _nextNumber; // offerer: the next connection number
    // Remote items for a connection that cannot take them yet (not open, or its answer not applied), by number.
    NSMutableDictionary<NSNumber *, NSMutableArray<SZFriendsSignalItem *> *> *_held;
    // Answerer: the offer of a connection the order has yet to open, by kind.
    NSMutableDictionary<NSNumber *, NSDictionary *> *_offers; // kind -> {offer, number}
    NSMutableArray<SZFriendsSignalItem *> *_outgoing;
    BOOL _flushScheduled;
    SZFriendsNATClass _remoteNAT;
    int16_t _remoteStep;
    SZFriendsOnlinePhase _lastPhase;
    NSTimeInterval _answerDeadline;
    dispatch_source_t _Nullable _timer;
    // Hard-NAT step: the prober, the easy side's prober address (hard side), whether prediction waits for the
    // peer's reflexive candidate, and the pair a hit found.
    SZFriendsNATProber *_Nullable _prober;
    SZFriendsNATEndpoint *_Nullable _probeRemote;
    BOOL _probeWaitsForRemote;
    BOOL _predictionPending;
    SZFriendsNATProbeHit *_Nullable _probeHit;
    BOOL _ended;
    BOOL _answered;
    BOOL _connected;
}
// Signalling (SZFriendsOnlineAttempt.m).
- (void)sendItems:(NSArray<SZFriendsSignalItem *> *)items;
- (void)applyItems:(NSArray<SZFriendsSignalItem *> *)items;
- (void)applyHeldItemsForSlot:(SZFriendsOnlineSlot *)slot;
- (void)openSidWithDescription:(nullable SZFriendsSignalItem *)description;
- (void)replyWithDescription:(nullable SZFriendsSignalItem *)description;
- (SZFriendsSignalItem *)natItem;
@end

// Connections, the order's actions, timers and the driver's inputs (+Connections).
@interface SZFriendsOnlineAttempt (Connections) <SZFriendsOnlineConnectionDelegate>
- (nullable SZFriendsOnlineSlot *)openSlotOfKind:(SZFriendsOnlineConnectionKind)kind
                                          number:(uint8_t)number
                                           offer:(nullable SZFriendsSignalItem *)offer
                                           relay:(nullable id<SZFriendsOnlineRelayCredentials>)relay
                                       localPort:(uint16_t)localPort;
- (nullable SZFriendsOnlineSlot *)slotForConnection:(id<SZFriendsOnlineConnection>)connection;
- (void)closeSlot:(nullable SZFriendsOnlineSlot *)slot;
- (void)perform:(SZFriendsOnlineOrderActions)actions;
- (void)answererOfferArrived:(SZFriendsSignalItem *)offer
                       number:(uint8_t)number
                         kind:(SZFriendsOnlineConnectionKind)kind;
- (void)applyRemoteCandidate:(SZFriendsSignalItem *)item toSlot:(SZFriendsOnlineSlot *)slot;
- (void)armTimer;
- (void)finish;
// From the driver.
- (void)nearbyRouteChanged:(SZFriendsRouteMethod)route;
- (void)networkChanged;
- (void)localNATClassChanged;
- (void)fireTimers;
- (void)close;
@end

// The NAT techniques (+NAT).
@interface SZFriendsOnlineAttempt (NAT)
- (void)maybeAskPortMappingForSlot:(SZFriendsOnlineSlot *)slot;
- (void)startPrediction;
- (void)predictIfPossible;
- (void)startProbing;
- (void)stopProbing;
- (void)proberAddressArrived:(SZFriendsNATEndpoint *)endpoint;
- (void)probeOfferArrived;
@end

NS_ASSUME_NONNULL_END
