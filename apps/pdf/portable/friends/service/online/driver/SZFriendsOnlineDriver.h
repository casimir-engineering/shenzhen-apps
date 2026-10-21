// Shenzhen Friends online driver: the helper's Internet attempts toward friends, joining the pieces M2 built apart.
//
// Helper-only. ADR 0009 (the stack), ADR 0010 (the host), ADR 0011 (the techniques and their timers) and the gating
// rule in service/online/SZFriendsOnlineTransport.h are the decisions; this header is how the helper uses them. The
// driver joins:
//   - the host's protocol 2 (service/host/SZFriendsHostRendezvous.h): this device's sealed rendezvous record once per
//     host period, lookups of friends' records, sids opened to a friend's rendezvous key, and sids opened to us;
//   - the signalling (service/session/SZFriendsSignaling.h): Noise IK toward friends, carrying every description with
//     its DTLS fingerprint, every candidate with its technique, each side's NAT class, and the order's signals;
//   - the order (service/online/order/SZFriendsOnlineOrder.h), the one owner of the direct phase's timers, of when
//     the relay opens and of leaving it. The transport's own SZFriendsOnlineDirectPhaseTimer is never armed, and the
//     TCP path runs until the order ends its direct phase, not on a budget of its own;
//   - the transport (service/online/transport/), created on the first attempt, never at launch: the WebRTC stack
//     costs nothing until someone is reached online;
//   - the NAT techniques (service/online/nat/): the two-port class, a router port mapping as a local candidate,
//     predicted ports, the hard-NAT prober and its probe handover connection, and TCP simultaneous open.
//
// The owner's words: "Relay: only in last resort for online friends if everything fails, bandwidth cap it at 5mbps";
// "For transfers: direct connection then p2p then bluetooth then server". So an attempt starts only while no route
// that ranks before Internet carries the session, and the relay opens only once the order's direct phase has run out
// with no other route working; any direct path that connects later replaces it (ADR 0001 resumes transfers on the new
// session from the recipient's verified offset).
//
// Pre-authentication (lead decision 6), end to end:
//   - an attempt toward a friend creates its offer only to seal it into IK message 1 to that friend's stored static
//     key, and applies nothing remote (answer, candidate) until IK message 2 has authenticated the friend;
//   - an incoming IK message 1 is decrypted, its certificate checked, the replay cache consulted, its clock checked
//     and the friend policy asked (SZFriendsSignalingSession) before any peer connection exists for it; a refusal is
//     silence, so the caller cannot tell a refusal from nobody;
//   - every relay, retry or probe handover connection is made by the same attempt, for the same authenticated peer
//     and purpose (header rule 6): requests never take a peer or a purpose from anything else;
//   - Add by ID online (SZFriendsOnlineDriver+ByID.m): an open via a Friends ID is answered only with Noise NN,
//     which carries REQUEST_BY_ID one way and RECEIVED the other and nothing else: no description, no candidate, no
//     attempt and no peer connection. Once the person accepts (or a live invite accepts for them), the holder dials
//     the requester with IK presenting the request's token, and the requester's side admits it only for an Add by ID
//     of its own that admits that key (a request from a mention or a friend link admits only the key it carries);
//   - opens via a link id go to the helper's links service before they get here (SZFriendsHelperLinks.h, which gates
//     them on the link's secret); any that still arrives is left unanswered.
//
// Threading: everything here runs on the queue given to -initWithIdentity:queue: (the helper's one queue, which is
// also the check-in client's), and every delegate callback arrives there.

#import <Foundation/Foundation.h>

#import "service/discovery/SZFriendsDiscovery.h"
#import "service/session/SZFriendsSession.h"

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsHostList;
@class SZFriendsHostOnline;
@class SZFriendsIdentity;
@class SZFriendsOnlineDriver;

// A friend as the driver needs one: who they are, the key IK message 1 is sealed to, and the secret their rendezvous
// record is sealed under.
@interface SZFriendsOnlineFriend : NSObject
@property(nonatomic, copy) NSData *identityKey;               // Ed25519, 32 bytes
@property(nonatomic, copy) NSData *staticKey;                 // X25519, 32 bytes: the key we dial
@property(nonatomic, copy, nullable) NSData *presenceSecret;  // theirs, 32 bytes, when we have it
// Our dial presents this (16 bytes) in IK message 1 while our acceptance of their Add by ID has not reached them:
// until then their side knows us only by the token it issued.
@property(nonatomic, copy, nullable) NSData *requestToken;
// The person's root key, which every device of theirs files its record under (HOST-PROTOCOL-ONLINE.md § Several
// devices): set when `identityKey` is one of their other devices. Nil: the identity key is the root.
@property(nonatomic, copy, nullable) NSData *rootKey;
@end

// Where attempts toward a friend stand, for what the helper shows while no session with them is up.
typedef NS_ENUM(NSInteger, SZFriendsOnlineFriendReach) {
    SZFriendsOnlineFriendReachIdle = 0,   // no attempt runs, and the last one did not fail everywhere (or none ran)
    SZFriendsOnlineFriendReachTrying = 1, // an attempt toward or from this friend runs
    // An attempt failed after asking for the relay: every path, the relay included. Sticky through the retries that
    // follow, running or ended, so the words do not change with each one: until a stream opens, the helper forgets it
    // (-forgetFailureForFriend:), the network changes or the driver stops. An attempt that reached nobody (the friend
    // is not online) and no failure before it is Idle: that is no failure the person could do anything about.
    SZFriendsOnlineFriendReachFailed = 2,
};

// One sid as joining a profile uses it (SZFriendsOnlineDriver (Join)): payloads in order, its end, sending, closing.
@protocol SZFriendsOnlineJoinChannel <NSObject>
@property(nonatomic, copy, nullable) void (^onPayload)(NSData *payload);
@property(nonatomic, copy, nullable) void (^onEnd)(void);
- (BOOL)sendPayload:(NSData *)payload;
- (void)close;
@end

@protocol SZFriendsOnlineDriverDelegate <NSObject>
// Online messages may be sent now (the host's welcome said online), or the network changed: the helper should say
// again which friends it wants to reach (-reachFriend:).
- (void)onlineDriverDidBecomeAvailable:(SZFriendsOnlineDriver *)driver;
// The friend this identity key names now, or nil when it names nobody we may reach online: unknown, removed,
// blocked, or a key change waiting for review. Pure: asked inside the signalling key policy, before anyone proved
// anything (SZFriendsSession.h § key policy).
- (nullable SZFriendsOnlineFriend *)onlineDriver:(SZFriendsOnlineDriver *)driver
                           friendWithIdentityKey:(NSData *)identityKey;
// The best route carrying a session with this friend that no online attempt made (nearby), or None.
- (SZFriendsRouteMethod)onlineDriver:(SZFriendsOnlineDriver *)driver nearbyRouteForFriend:(NSData *)identityKey;
// A connected path: a new ADR 0001 session with this friend over `stream`, on `route` (Internet or Relay). The
// initiator (the side whose attempt made the offer) sends the preamble; the other side answers as responder.
- (void)onlineDriver:(SZFriendsOnlineDriver *)driver
       didOpenStream:(id<SZFriendsByteStream>)stream
               route:(SZFriendsRouteMethod)route
           initiator:(BOOL)initiator
              friend:(NSData *)identityKey;
@optional
// Someone answering an Add by ID of ours: IK message 1 presenting `token`, from `identityKey`. The person as the driver
// may reach them, or nil unless the token is one of our unexpired requests that admits that key (a request bound to
// a key admits no other). Pure, like -onlineDriver:friendWithIdentityKey:. Not implemented: nobody is admitted.
- (nullable SZFriendsOnlineFriend *)onlineDriver:(SZFriendsOnlineDriver *)driver
                  friendAnsweringWithIdentityKey:(NSData *)identityKey
                                    requestToken:(NSData *)token;
// Add by ID online reached us: REQUEST_BY_ID as it arrived over NN, unverified, and that session's handshake hash,
// which its signature and any invite proof are bound to. RECEIVED has already gone back, whatever happens next.
- (void)onlineDriver:(SZFriendsOnlineDriver *)driver
    receivedRequestByID:(SZFriendsFrame *)frame
          handshakeHash:(NSData *)handshakeHash;
// Joining a profile (PROTOCOL.md § Joining): an open by Friends ID whose payload starts with 'J'. Nothing here reads
// it; the helper answers it, or closes the channel and stays silent. Not implemented: such opens are closed.
- (void)onlineDriver:(SZFriendsOnlineDriver *)driver
    receivedJoinPayload:(NSData *)payload
                channel:(id<SZFriendsOnlineJoinChannel>)channel;
// -reachOfFriend: may answer differently now: an attempt started or ended, a stream opened, or failures were
// forgotten (a network change, -forgetFailureForFriend:). Nil: any friend.
- (void)onlineDriver:(SZFriendsOnlineDriver *)driver reachChangedForFriend:(nullable NSData *)identityKey;
@end

@interface SZFriendsOnlineDriver : NSObject
- (instancetype)initWithIdentity:(SZFriendsIdentity *)identity queue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, weak, nullable) id<SZFriendsOnlineDriverDelegate> delegate;
// This device's presence secret (friends hold it): the rendezvous record is sealed under it. Nil publishes nothing.
@property(nonatomic, copy, nullable) NSData *_Nullable (^ownPresenceSecret)(void);
// The verified host list, for the STUN and TURN URIs the connected host's entry names (never the host's answer).
@property(nonatomic, copy, nullable) SZFriendsHostList *_Nullable (^hostList)(void);
// Where the technique log is kept (ADR 0011 § Technique log): numbers only. Nil keeps it in memory.
@property(nonatomic, copy, nullable) NSString *techniqueLogPath;

// The check-in client's online side. The driver becomes its delegate and does nothing until the host says it takes
// online messages (the welcome's `online`); a protocol 1 host, or FRIENDS_M2 off, leaves everything as it was.
- (void)attachHostOnline:(SZFriendsHostOnline *)online;
// Online messages may be sent now (the welcome said online and the connection is up).
@property(nonatomic, readonly) BOOL available;

// The helper wants a session with this friend (something to deliver, a transfer to finish) and no route ranking
// before Internet carries one. Starts an attempt unless one runs, the friend's last attempt failed recently (backoff,
// cleared by a network change, a new host connection or the friend's record appearing), or online is unavailable.
- (void)reachFriend:(NSData *)identityKey;
// Whether an attempt toward or from this friend is running.
- (BOOL)hasAttemptForFriend:(NSData *)identityKey;
// Failed from an attempt that failed everywhere until it is forgotten, even while a retry runs; otherwise Trying while
// an attempt runs (SZFriendsOnlineFriendReach).
- (SZFriendsOnlineFriendReach)reachOfFriend:(NSData *)identityKey;
// When the failure -reachOfFriend: reports began (the wall clock), or nil while it reports none.
- (nullable NSDate *)failedSinceForFriend:(NSData *)identityKey;
// Something new was queued for this friend, or the person opened their conversation: the failure is old news, and the
// words follow the attempts again. Backoffs are left as they are.
- (void)forgetFailureForFriend:(NSData *)identityKey;
// Nearby sessions changed: every attempt asks its delegate again for the route outside it.
- (void)nearbyRoutesChanged;
// The default route changed: classes are measured again, backoffs end, and attempts try direct again (ADR 0011 § Leave
// the relay). The driver also watches the system's notifications itself once it has started: a burst counts once,
// and only a change of the default routes' interface, gateway or source address acts.
- (void)networkChanged;
// Exit, disable or Reset Friends: every attempt ends, and nothing is published or answered any more.
- (void)stop;
@end

@interface SZFriendsOnlineDriver (ByID)
// Add by ID online: an NN exchange with whichever helper holds `friendsID` now, through the host. `frame` makes the
// encoded REQUEST_BY_ID for that session's handshake hash (nil gives up). The completion runs once: YES when the
// holder's RECEIVED arrived, NO when nobody answered in time, the host refused, or this helper may not open another
// by ID this hour (the host's 5).
- (void)sendRequestByIDToFriendsID:(NSString *)friendsID
                             frame:(NSData *_Nullable (^)(NSData *handshakeHash))frame
                        completion:(void (^)(BOOL received))completion;
@end

extern const NSUInteger SZFriendsOnlineJoinOpensPerHour; // 40, the host's limit on to.join opens from one device

@interface SZFriendsOnlineDriver (Join)
// Joining a profile: a sid opened to whichever helpers hold `friendsID` now, carrying `payload` ('J' and the join
// payload, at most 4,096 bytes) as its open. Join opens have a budget of their own, the host's for to.join
// (SZFriendsOnlineJoinOpensPerHour), and never spend Add by ID's 5. The completion gets the channel, or nil when
// online is unavailable, the budget is spent or the host refused.
- (void)openJoinToFriendsID:(NSString *)friendsID
                    payload:(NSData *)payload
                 completion:(void (^)(id<SZFriendsOnlineJoinChannel> _Nullable channel))completion;
@end

// Tests only. The e2e online helper's main (tests/e2e/SZFriendsE2EOnlineHelperMain.m) sets these under
// SZFRIENDS_STATE_DIR, and the helper's own main in a test home (SZFriendsHelperSetOnlineTestHooks); never in a
// person's own home.
@interface SZFriendsOnlineDriverTestHooks : NSObject
// Peer connections bind to 127.0.0.1 and accept loopback candidates, every NAT technique runs in its loopback-only
// mode, and no router is asked for a port mapping: two helpers on one Mac meet without leaving it.
@property(class, nonatomic) BOOL loopbackOnly;
// While this answers YES, no host, server-reflexive, port-mapped, predicted or TCP candidate is sent or applied, so
// only the relay can connect (a scripted direct failure).
@property(class, nonatomic, copy, nullable) BOOL (^directPathsBlocked)(void);
// What a path monitor would report: every running driver hears -networkChanged.
+ (void)simulateNetworkChange;
@end

NS_ASSUME_NONNULL_END
