// The online driver's pieces, shared by the files of service/online/driver/ and its tests. Not a public header:
// the helper uses SZFriendsOnlineDriver.h.
//
//   SZFriendsOnlineContext   what every attempt shares: the transport (made on first use), the host's STUN servers as
//                            numeric addresses, this network's NAT class, the clock, the technique log, test hooks
//   SZFriendsOnlineAttempt   one attempt toward one friend over one sid (or a later one for the same attempt): the
//                            signalling session, the order, and the connections it opens
//   SZFriendsOnlineTCPSidePath  the NAT area's TCP simultaneous-open path as the transport's side path, running until
//                            the order ends the direct phase (no budget of its own)

#import <Foundation/Foundation.h>

#import "service/online/SZFriendsOnlineTransport.h"
#import "service/online/driver/SZFriendsOnlineDriver.h"
#import "service/online/nat/SZFriendsNAT.h"
#import "service/online/order/SZFriendsOnlineOrder.h"
#import "service/online/transport/SZFriendsOnlineDataChannelTransport.h"
#import "service/session/SZFriendsSignaling.h"

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsNATClassification;
@class SZFriendsNATEndpoint;
@class SZFriendsNATProbeHit;

#pragma mark - Limits (provisional, like ADR 0011's timers)

// An offer whose sid gets no answer within this is given up: a friend who is not online stays silent (ADR 0010).
extern const NSTimeInterval SZFriendsOnlineAnswerTimeout;  // 15 s
// After an attempt that reached nobody or found no path: the next one waits this long, doubling to the maximum.
extern const NSTimeInterval SZFriendsOnlineBackoffFirst;   // 30 s
extern const NSTimeInterval SZFriendsOnlineBackoffMax;     // 900 s
// Connection numbers are one byte in the signalling; an attempt that has used them all ends.
extern const NSUInteger SZFriendsOnlineConnectionsMax;     // 250

#pragma mark - A sid, as an attempt uses it

// One sid (SZFriendsHostSignal) as the attempt needs it, so tests can join two attempts in memory.
@protocol SZFriendsOnlineSignalChannel <NSObject>
@property(nonatomic, copy, nullable) void (^onPayload)(NSData *payload);
@property(nonatomic, copy, nullable) void (^onEnd)(void);
@property(nonatomic, readonly) BOOL ended;
- (BOOL)sendPayload:(NSData *)payload;
- (void)close;
// TURN credentials for this sid (both ends have spoken), with the first TURN over UDP URI of the signed list.
- (void)requestRelayCredentials:(void (^)(id<SZFriendsOnlineRelayCredentials> _Nullable credentials,
                                          NSError *_Nullable error))completion;
@end

// Wraps a host sid. Nil when the list gives no TURN over UDP URI for credentials (the relay then fails at once).
@class SZFriendsHostSignal;
id<SZFriendsOnlineSignalChannel> SZFriendsOnlineChannelForSignal(SZFriendsHostSignal *signal);

#pragma mark - Requests

@interface SZFriendsOnlineRequest : NSObject <SZFriendsOnlineConnectionRequest>
@property(nonatomic) SZFriendsOnlinePurpose purpose;
@property(nonatomic) SZFriendsOnlineRole role;
@property(nonatomic) SZFriendsOnlineConnectionKind kind;
@property(nonatomic, copy) NSData *peer;
@property(nonatomic, copy, nullable) NSString *stunURI;
@property(nonatomic, nullable) id<SZFriendsOnlineRelayCredentials> relay;
@property(nonatomic) uint16_t localPort;
@property(nonatomic, copy, nullable) NSString *remoteOfferSDP;
@property(nonatomic, copy, nullable) NSData *remoteFingerprint;
// Whether the side path factory may attach the TCP path (direct connections while direct paths are not blocked).
@property(nonatomic) BOOL wantsTCPPath;
// Told when the factory made this request's TCP path, so the attempt can end it with the direct phase.
@property(nonatomic, copy, nullable) void (^onSidePath)(id<SZFriendsOnlineSidePath> sidePath);
@end

@interface SZFriendsOnlineRelayCredentialsValue : NSObject <SZFriendsOnlineRelayCredentials>
@property(nonatomic, copy) NSString *turnURI;
@property(nonatomic, copy) NSString *username;
@property(nonatomic, copy) NSString *credential;
@property(nonatomic) NSDate *expires;
@end

// The first TURN over UDP URI in `uris` (turn:host[:port] or with ?transport=udp), or nil: libjuice relays over
// UDP only (ADR 0009 § Gaps), so a TCP or TLS URI further up the list is passed over.
NSString *_Nullable SZFriendsOnlineFirstTURNOverUDP(NSArray<NSString *> *uris);
// "stun:host[:port]" -> host and port (3478 when absent); NO for anything else.
BOOL SZFriendsOnlineSplitSTUNURI(NSString *uri, NSString *_Nullable *_Nonnull host, uint16_t *port);
// "stun:<numeric address>:<port>", brackets around IPv6.
NSString *SZFriendsOnlineNumericSTUNURI(SZFriendsNATEndpoint *endpoint);

// The stream as the session layer gets it, telling the attempt when it closes (the order's -streamClosed...), since
// the session layer owns the stream's own onClose.
id<SZFriendsByteStream> SZFriendsOnlineTrackStream(id<SZFriendsByteStream> stream, void (^onClose)(void));

#pragma mark - The TCP path as a side path

@interface SZFriendsOnlineTCPSidePath : NSObject <SZFriendsOnlineSidePath>
// Nil for a request that has no TCP path (a link, a relay or probe handover connection). `stunServer` is the host's
// STUN for TCP (3478), numeric; nil gathers no mapped address.
+ (nullable instancetype)sidePathForRequest:(id<SZFriendsOnlineConnectionRequest>)request
                                 stunServer:(nullable SZFriendsNATEndpoint *)stunServer
                               loopbackOnly:(BOOL)loopbackOnly;
- (instancetype)init NS_UNAVAILABLE;
// The order ended the direct phase: a path with no stream stops dialling and reports itself over; one carrying a
// stream keeps it. Idempotent.
- (void)finishBudget;
@property(nonatomic, readonly) BOOL carriesStream;
@end

#pragma mark - The shared context

@interface SZFriendsOnlineContext : NSObject
- (instancetype)initWithIdentity:(SZFriendsIdentity *)identity queue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) SZFriendsIdentity *identity;
@property(nonatomic, readonly) dispatch_queue_t queue;
@property(nonatomic, readonly) BOOL loopbackOnly; // SZFriendsOnlineDriverTestHooks.loopbackOnly when made
// The transport, made on first use (the stack is configured then, never at launch). Tests set their own first.
@property(nonatomic, strong, null_resettable) id<SZFriendsOnlineTransport> transport;
@property(nonatomic, readonly) BOOL transportCreated;
// The connected host's STUN servers (stun: URIs of its signed entry), resolved to numeric addresses: the first is
// the connection's STUN server and the TCP path's (3478), the second the classifier's other port (3479).
@property(nonatomic, strong, nullable) SZFriendsNATEndpoint *stunPrimary;
@property(nonatomic, strong, nullable) SZFriendsNATEndpoint *stunSecondary;
@property(nonatomic, readonly, nullable) NSString *stunURI; // stun:<numeric>:<port> of stunPrimary
// This network's class (Unknown until measured); -measureNATClass runs the classifier once per network.
@property(nonatomic, readonly) SZFriendsNATClass natClass;
@property(nonatomic, readonly) int16_t natStep;
@property(nonatomic, copy, nullable) void (^onNATClassChanged)(void);
- (void)measureNATClass;
- (void)networkChanged;
// Direct paths blocked by the test hook.
- (BOOL)directPathsBlocked;
// The clock the order reads (continuous, never set back) and the jitter source.
@property(nonatomic, copy) NSTimeInterval (^clock)(void);
@property(nonatomic, copy) double (^random)(void);
// Timers: production arms dispatch timers; tests turn this off and call -fireTimers on attempts themselves.
@property(nonatomic) BOOL usesDispatchTimers;
// Where an ended attempt's entry goes.
- (void)appendLogEntry:(SZFriendsTechniqueLogEntry *)entry;
@property(nonatomic, readonly) SZFriendsTechniqueLog *techniqueLog;
@property(nonatomic, copy, nullable) NSString *techniqueLogPath;
// The NAT techniques, replaceable by tests: a port mapping for a bound port (nil: none on this network), and a
// prober for a configuration.
@property(nonatomic, copy, nullable) id _Nullable (^portMappingFactory)(uint16_t port, id delegate);
@property(nonatomic, copy, nullable) id _Nullable (^proberFactory)(id configuration);
@end

#pragma mark - One attempt

@class SZFriendsOnlineAttempt;

@protocol SZFriendsOnlineAttemptOwner <NSObject>
// Opens a sid to the friend's rendezvous key with IK message 1; the completion gets the channel or nil.
- (void)attempt:(SZFriendsOnlineAttempt *)attempt
    openChannelWithPayload:(NSData *)payload
                completion:(void (^)(id<SZFriendsOnlineSignalChannel> _Nullable channel))completion;
- (void)attempt:(SZFriendsOnlineAttempt *)attempt
    didOpenStream:(id<SZFriendsByteStream>)stream
            route:(SZFriendsOnlineRoute)route;
- (void)attemptDidEnd:(SZFriendsOnlineAttempt *)attempt;
@end

@interface SZFriendsOnlineAttempt : NSObject
// Offerer: dials `friend`; -start makes the offer and opens the sid with IK message 1.
- (instancetype)initOffererWithFriend:(SZFriendsOnlineFriend *)friend
                              context:(SZFriendsOnlineContext *)context
                                owner:(id<SZFriendsOnlineAttemptOwner>)owner;
// Answerer: `session` is the IK responder that authenticated `friend` from message 1, `items` that message's items.
- (instancetype)initAnswererWithFriend:(SZFriendsOnlineFriend *)friend
                               session:(SZFriendsSignalingSession *)session
                               channel:(id<SZFriendsOnlineSignalChannel>)channel
                                 items:(NSArray<SZFriendsSignalItem *> *)items
                               context:(SZFriendsOnlineContext *)context
                                 owner:(id<SZFriendsOnlineAttemptOwner>)owner;
- (instancetype)init NS_UNAVAILABLE;
- (void)start;
@property(nonatomic, readonly) SZFriendsOnlineRole role;
@property(nonatomic, readonly) NSData *peer; // the friend's identity key
@property(nonatomic, readonly) NSData *peerRoot; // the key their records are filed under: their root
@property(nonatomic, readonly) SZFriendsOnlineOrder *order;
@property(nonatomic, readonly) BOOL ended;
// Whether the attempt ever reached a stream, and whether the friend answered at all.
@property(nonatomic, readonly) BOOL answered;
@property(nonatomic, readonly) BOOL connected;
// The route this attempt's stream carries the session on now: Internet when direct, Relay when relayed, else None.
@property(nonatomic, readonly) SZFriendsRouteMethod carriedRoute;
// Answerer: the same friend opened a new sid for this attempt (the old one expired); its message 1 continues it.
- (void)continueWithSession:(SZFriendsSignalingSession *)session
                    channel:(id<SZFriendsOnlineSignalChannel>)channel
                      items:(NSArray<SZFriendsSignalItem *> *)items;
@end
// Its inputs and the rest of its methods are in SZFriendsOnlineAttemptInternal.h.

NS_ASSUME_NONNULL_END
