// The online side's private state, shared by SZFriendsHostRendezvous.m (availability, records, lookups) and
// SZFriendsHostSignaling.m (sids and relay credentials), and the four calls the check-in client makes into it.
// Everything here runs on the check-in client's queue. Not a public header; other areas use SZFriendsHostRendezvous.h.

#import "service/host/SZFriendsHostRendezvous.h"

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsIdentity;

NSError *SZFriendsHostOnlineMakeError(SZFriendsHostOnlineError code, NSString *description);

// One request waiting for the host's answer, by its req number.
@interface SZFriendsHostPending : NSObject
@property(nonatomic, copy) NSString *kind; // the answer types it takes: "lookup", "open", "credentials"
@property(nonatomic, copy, nullable) id completion;
@property(nonatomic, nullable) dispatch_source_t timer;
// Lookups: the batch this request is one message of, and where its keys start in it.
@property(nonatomic, nullable) id batch;
@property(nonatomic) NSUInteger offset;
@property(nonatomic) NSUInteger count;
// Opens: how the target was named; credentials: the sid asked for.
@property(nonatomic) SZFriendsHostSignalVia via;
@property(nonatomic, copy, nullable) NSData *linkID;
@property(nonatomic, nullable) SZFriendsHostSignal *signal;
@end

@interface SZFriendsHostOnline () {
  @package
    __weak SZFriendsCheckInClient *_client;
    SZFriendsIdentity *_identity;
    dispatch_queue_t _queue;
    SZFriendsHostEntry *_Nullable _entry;
    NSArray<NSString *> *_relayURIs;
    NSTimeInterval _skew; // host clock minus this Mac's, from the challenge's time
    uint64_t _seq;
    NSInteger _nextReq;
    NSUInteger _generation; // bumped whenever the connection ends; timers from before do nothing
    NSMutableDictionary<NSNumber *, SZFriendsHostPending *> *_pending;
    NSMutableDictionary<NSString *, SZFriendsHostSignal *> *_signals;
    dispatch_source_t _Nullable _publishTimer;
    BOOL _available;
}
- (instancetype)initWithClient:(SZFriendsCheckInClient *)client
                      identity:(SZFriendsIdentity *)identity
                         queue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// The host's clock now, as this helper estimates it.
- (NSTimeInterval)hostNow;
// Sends one online message; NO when not available.
- (BOOL)sendType:(NSString *)type fields:(NSDictionary<NSString *, id> *)fields;
// A request number, and its entry with a timeout that completes it with TimedOut.
- (NSInteger)addPending:(SZFriendsHostPending *)pending;
- (nullable SZFriendsHostPending *)takePending:(id _Nullable)req kind:(NSString *)kind;
@end

// What the check-in client calls, on its queue (SZFriendsCheckInClient.m).
@interface SZFriendsHostOnline (Connection)
// The challenge that opens every connection: its `time` sets the clock offset records' expiries use.
- (void)connectionDidReceiveChallenge:(NSDictionary<NSString *, id> *)message;
// A welcome from `entry`; online only when it says `online: true` (protocol 2, FRIENDS_M2 on).
- (void)connectionDidCheckInWithWelcome:(NSDictionary<NSString *, id> *)message
                                  entry:(SZFriendsHostEntry *)entry
                                   list:(SZFriendsHostList *)list;
// YES when `message` is an online answer this object took (even one it then ignored).
- (BOOL)connectionDidReceive:(NSDictionary<NSString *, id> *)message;
// The socket closed or was given up: ends everything. Idempotent and cheap: called before every connection attempt.
- (void)connectionDidClose;
@end

// The sid side, in SZFriendsHostSignaling.m.
@interface SZFriendsHostOnline (SignalingInternal)
- (BOOL)receiveSignalingMessage:(NSDictionary<NSString *, id> *)message type:(NSString *)type;
- (void)endAllSignals;
@end

@interface SZFriendsHostSignal ()
- (instancetype)initWithOnline:(SZFriendsHostOnline *)online
                           sid:(NSString *)sid
                           via:(SZFriendsHostSignalVia)via
                      incoming:(BOOL)incoming
                        linkID:(nullable NSData *)linkID
                   ownerOnline:(BOOL)ownerOnline NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)endWithReason:(SZFriendsHostSignalEnd)reason;
- (void)deliver:(NSData *)payload;
@end

NS_ASSUME_NONNULL_END
