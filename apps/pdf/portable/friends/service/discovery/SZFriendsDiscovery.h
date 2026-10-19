// Shenzhen Friends nearby discovery: adapters, sightings, the merger, presence tags and route racing.
//
// Helper-only. ADR 0004 (portable/friends/docs/adr/0004-nearby-transport-presence.md) is the decision; this header
// is its interface. Two adapters run side by side and never wait for each other (brief § Nearby):
//   - Network.framework: one browser and listener for SZFriendsBonjourServiceType with includePeerToPeer, covering
//     the LAN and peer-to-peer Wi-Fi (the link AirDrop uses), classified per connection by interface;
//   - CoreBluetooth: filtered scanning, advertising and L2CAP channels.
// Both report to one merger, a pure component with no radios, so simultaneous, out-of-order, flapping and
// expiring sightings are tested with scripted adapters. The racer decides which connection attempts to make
// and which session wins, also without radios. SZFriendsDiscoveryCoordinator (SZFriendsDiscoveryCoordinator.h)
// wires adapters to the merger for the helper.
//
// Bluetooth addresses, peripheral identifiers and Bonjour instance names are never identity: a friend is
// recognised by a presence tag only they could compute, and a stranger only after a handshake returned their key.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol SZFriendsByteStream;

#pragma mark - Routes (shared with session and presentation)

// What a conversation shows as its state (PROTOCOL.md route.kind). Online is M2; M1 never reports it.
typedef NS_ENUM(NSInteger, SZFriendsRouteKind) {
    SZFriendsRouteKindNone = 0,    // nothing to show (a request by ID that never connected): no route icon
    SZFriendsRouteKindLocal = 1,   // a nearby session is up
    SZFriendsRouteKindOnline = 2,  // an Internet session is up (M2)
    SZFriendsRouteKindOffline = 3, // a friend with no working route
};

// Which link carries the session (PROTOCOL.md route.method). The numbers also travel as the initiator's route class
// in handshake payloads (ADR 0001): never renumber. They are NOT the racing order (Internet is 4, Bluetooth 3):
// compare routes only through SZFriendsRouteRank below.
typedef NS_ENUM(NSInteger, SZFriendsRouteMethod) {
    SZFriendsRouteMethodNone = 0,
    SZFriendsRouteMethodLAN = 1,            // shared network, Wi-Fi or Ethernet
    SZFriendsRouteMethodPeerToPeerWiFi = 2, // no shared network; direct Wi-Fi link (awdl/llw interface)
    SZFriendsRouteMethodBluetooth = 3,      // L2CAP; carries traffic only while no Wi-Fi or Internet route works
    SZFriendsRouteMethodInternet = 4,       // M2 direct
    SZFriendsRouteMethodRelay = 5,          // M2 last resort
};

// The one order every comparison between routes uses (ADR 0011 § Route rank; the owner's order): LAN, peer-to-peer
// Wi-Fi, Internet, Bluetooth, relay. Lower is better. None and any value outside the enum rank after the relay, so
// a session that never declared a real class cannot win on the strength of a small number.
static inline NSInteger SZFriendsRouteRank(SZFriendsRouteMethod route) {
    switch (route) {
    case SZFriendsRouteMethodLAN:
        return 0;
    case SZFriendsRouteMethodPeerToPeerWiFi:
        return 1;
    case SZFriendsRouteMethodInternet:
        return 2;
    case SZFriendsRouteMethodBluetooth:
        return 3;
    case SZFriendsRouteMethodRelay:
        return 4;
    case SZFriendsRouteMethodNone:
        break;
    }
    return 5;
}

// YES when `route` ranks strictly before `other`.
static inline BOOL SZFriendsRouteIsBetter(SZFriendsRouteMethod route, SZFriendsRouteMethod other) {
    return SZFriendsRouteRank(route) < SZFriendsRouteRank(other);
}

#pragma mark - Adapters

extern NSString *const SZFriendsBonjourServiceType; // "_szfriends._tcp"

typedef NS_ENUM(NSInteger, SZFriendsDiscoveryMethod) {
    SZFriendsDiscoveryMethodNetwork = 0,   // LAN + peer-to-peer Wi-Fi (Network.framework)
    SZFriendsDiscoveryMethodBluetooth = 1, // CoreBluetooth
};

// Each method reports its own state; Nearby shows each one that is not working instead of an empty search.
typedef NS_ENUM(NSInteger, SZFriendsAdapterState) {
    SZFriendsAdapterStateNotAsked = 0,  // permission never requested: not started (no prompt at launch); also
                                        // what an adapter reports again after -stop
    SZFriendsAdapterStateStarting = 1,
    SZFriendsAdapterStateWorking = 2,   // browsing/scanning and listening/advertising
    SZFriendsAdapterStateDenied = 3,    // Local Network or Bluetooth access denied (or restricted)
    SZFriendsAdapterStateRadioOff = 4,  // Wi-Fi off (Network) or Bluetooth off
    SZFriendsAdapterStateUnavailable = 5, // failing; detail in the adapter's log only
    SZFriendsAdapterStateUnsupported = 6, // this computer has no radio the method can use (Bluetooth LE missing);
                                          // PROTOCOL.md's method state stays `unavailable`, its words say which
};

// Permission as an adapter can read it without prompting.
typedef NS_ENUM(NSInteger, SZFriendsPermission) {
    SZFriendsPermissionUnknown = 0,       // no API answers without prompting (Local Network: browsing is the ask)
    SZFriendsPermissionNotDetermined = 1, // never asked (Bluetooth: CBManager.authorization, no manager created)
    SZFriendsPermissionAllowed = 2,
    SZFriendsPermissionDenied = 3,        // denied or restricted
};

// ADR 0004 § Permissions at launch as one decision: start this adapter before any `activate`? Allowed: yes.
// Denied: no (report Denied without starting). Not determined: no, wait for the first open. Unknown: only once
// the store records that the person was asked (nearbyPermissionsRequested).
BOOL SZFriendsStartAdapterAtLaunch(SZFriendsPermission permission, BOOL nearbyPermissionsRequested);

// One observation of one endpoint by one method. Immutable.
@interface SZFriendsSighting : NSObject
@property(nonatomic, readonly) SZFriendsDiscoveryMethod method;
@property(nonatomic, readonly) SZFriendsRouteMethod route;
// Opaque per-adapter handle for dialing this endpoint; meaningless outside that adapter.
@property(nonatomic, readonly) NSString *endpointID;
// The device's private presence tag (TXT t, or Bluetooth), nil for a public entry advertised during someone's
// 5 minutes, which carries none.
@property(nonatomic, readonly, nullable) NSData *presenceTag;
// Callback tags the device advertises while its Add by ID requests are pending (TXT c; ADR 0004 step 3).
@property(nonatomic, readonly) NSArray<NSData *> *callbackTags;
@property(nonatomic, readonly) BOOL isPublic;
@property(nonatomic, readonly) NSDate *seenAt;
- (instancetype)initWithMethod:(SZFriendsDiscoveryMethod)method
                         route:(SZFriendsRouteMethod)route
                    endpointID:(NSString *)endpointID
                   presenceTag:(nullable NSData *)presenceTag
                  callbackTags:(NSArray<NSData *> *)callbackTags
                      isPublic:(BOOL)isPublic
                        seenAt:(NSDate *)seenAt NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

// What a listener lets in before a session authenticates (ADR 0001 review item 4: work before authentication).
// Each adapter counts every stream it accepts, from accept until its responder session knows who the initiator is
// (SZFriendsByteStream -sessionDidAuthenticate) or the stream closes, per listener (the hidden or the public entry)
// and per remote address (an IPv4 address, an IPv6 /64, a Bluetooth central). A new connection where either already
// holds the maximum closes the oldest connection counted there instead of being refused: refusing the newcomer let
// anyone who kept the places full, from a handful of IPv6 addresses, cut every friend off. A connection that has not
// delivered a complete message 1 within firstMessageTimeout of accept is closed too, so a place is held only briefly
// by a peer that sends nothing. Rates count handshakes admitted per minute once the preamble names the pattern, per
// listener and per remote address; a full rate refuses like the key policy (SZFriendsSession.h). 0 means no limit.
extern const NSUInteger SZFriendsPendingPerListenerMax;   // 32
extern const NSUInteger SZFriendsPendingPerAddressMax;    // 4
extern const NSTimeInterval SZFriendsFirstMessageTimeout; // 2 s
@interface SZFriendsAdmissionLimits : NSObject <NSCopying>
// The caps and deadline above and no rate limits; what every adapter starts with.
+ (instancetype)defaultLimits;
@property(nonatomic) NSUInteger pendingPerListener;
@property(nonatomic) NSUInteger pendingPerAddress;
@property(nonatomic) NSTimeInterval firstMessageTimeout;
// Suggested (ADR 0004 step 2 and the session review): NN 60 per listener; XX 20 per listener and 3 per address.
@property(nonatomic) NSUInteger xxPerMinutePerListener, xxPerMinutePerAddress;
@property(nonatomic) NSUInteger ikPerMinutePerListener, ikPerMinutePerAddress;
@property(nonatomic) NSUInteger nnPerMinutePerListener, nnPerMinutePerAddress;
@end

@protocol SZFriendsDiscoveryAdapter;

// Adapters call their delegate on the helper's discovery queue.
@protocol SZFriendsDiscoveryAdapterDelegate <NSObject>
- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didChangeState:(SZFriendsAdapterState)state;
- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didSight:(SZFriendsSighting *)sighting;
- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didLoseEndpoint:(NSString *)endpointID;
// An incoming connection. The session layer runs the handshake; nothing is trusted before it completes.
- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didAcceptStream:(id<SZFriendsByteStream>)stream
          route:(SZFriendsRouteMethod)route;
@optional
// Preferred over the method above when implemented: `publicEntry` says the stream arrived through the public
// entry (the person's 5 minutes), where XX is accepted and the public profile is served; NO means the hidden
// listener (IK from friends, NN Add by ID). A delegate without it gets public-entry streams through the method
// above, so they are refused like any unknown key on the hidden listener: safe, never more open.
- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didAcceptStream:(id<SZFriendsByteStream>)stream
          route:(SZFriendsRouteMethod)route
    publicEntry:(BOOL)publicEntry;
@end

@protocol SZFriendsDiscoveryAdapter <NSObject>
@property(nonatomic, readonly) SZFriendsDiscoveryMethod method;
@property(nonatomic, readonly) SZFriendsAdapterState state;
@property(nonatomic, weak, nullable) id<SZFriendsDiscoveryAdapterDelegate> delegate;
// Read without prompting and without creating a browser, listener or manager.
@property(nonatomic, readonly) SZFriendsPermission permissionWithoutPrompting;

// Starts browsing and listening. Creating the underlying browser or manager is what prompts for permission, so
// the helper calls this only after `activate` or when SZFriendsStartAdapterAtLaunch says so. Denial is inferred
// from the system's refusal (DNS-SD PolicyDenied, CBManagerStateUnauthorized), never from an empty result.
- (void)start;
- (void)stop;
// What to advertise: the current private presence tag, the callback tags of pending Add by ID requests (at most
// 4, padded to exactly 4 slots on the air), and whether the public entry is on (the person's 5 minutes). Called on
// every 15-minute window and every change; the visibility deadline turns the public entry off on both adapters at
// once. May be called before -start; the adapter advertises the latest values once running. A new presence tag is a
// new window: the hidden entry then moves to a fresh listener port or L2CAP PSM (and Bluetooth restarts its
// advertising), keeping the old one a short while for connections already on their way, so nothing an observer
// sees links the new tag to the old one.
- (void)advertisePresenceTag:(nullable NSData *)tag
                callbackTags:(NSArray<NSData *> *)callbackTags
                 publicEntry:(BOOL)publicEntry;
// Opens a byte stream to a sighted endpoint. The completion runs once, with a stream or an error.
- (void)openStreamToEndpoint:(NSString *)endpointID
                  completion:(void (^)(id<SZFriendsByteStream> _Nullable stream, NSError *_Nullable error))completion;
@optional
// Looks again now instead of waiting for the next change (a Bluetooth sighting of a friend asks the network
// adapter for a fresh browse, ADR 0004 § Route racing).
- (void)refreshDiscovery;
// Replaces the admission limits (default SZFriendsAdmissionLimits.defaultLimits); streams already admitted keep
// their places.
- (void)setAdmissionLimits:(SZFriendsAdmissionLimits *)limits;
@end

// Production adapters. Separate files implement them; tests substitute scripted adapters with the same protocol.
// Creating one creates no browser, listener or Bluetooth manager; only -start does.
id<SZFriendsDiscoveryAdapter> SZFriendsMakeNetworkAdapter(dispatch_queue_t queue);
id<SZFriendsDiscoveryAdapter> SZFriendsMakeBluetoothAdapter(dispatch_queue_t queue);
// The network adapter restricted to the loopback interface, without peer-to-peer Wi-Fi, for the two-helper harness
// and tests: it never reaches the network, so it never asks for Local Network access. `serviceType` keeps test
// instances apart from a real helper browsing on the same Mac (for example "_szfriendstest._tcp").
id<SZFriendsDiscoveryAdapter> SZFriendsMakeLoopbackNetworkAdapter(dispatch_queue_t queue, NSString *serviceType);

#pragma mark - Presence tags (pure)

// Tag for window w = first 8 bytes of BLAKE2b-256 keyed with the 32-byte secret over
// "SZFriends presence v1" || u64be(w), with w = floor(unix seconds / 900). Callback tags for Add by ID are the
// same function over the request's callback secret. Strangers see 8 bytes that change every 15 minutes.
extern const NSTimeInterval SZFriendsPresenceWindow; // 900 s
extern const NSUInteger SZFriendsPresenceTagLength;  // 8
extern const NSUInteger SZFriendsPresenceSecretLength; // 32
int64_t SZFriendsPresenceWindowIndex(NSDate *date);
// When the window holding `date` ends: re-advertise then, with the next tag (and a new Bonjour instance name).
NSDate *SZFriendsPresenceWindowEnd(NSDate *date);
NSData *SZFriendsPresenceTag(NSData *secret, int64_t windowIndex);
// The tags a matcher accepts for `secret` at `now`: windows w-1, w and w+1, tolerating 15 minutes of clock skew.
NSArray<NSData *> *SZFriendsPresenceTagsToMatch(NSData *secret, NSDate *now);
// A fresh random secret: our presence secret at first launch and on every remove or block (rotation), and each
// Add by ID request's callback secret. After a rotation the helper advertises tags of the new secret and queues it
// to every remaining friend through the outbox; the removed or blocked person keeps a dead secret.
NSData *SZFriendsNewPresenceSecret(void);

// Maps an advertised tag (presence or callback) to a conversation id, or nil.
typedef NSString *_Nullable (^SZFriendsTagMatcher)(NSData *tag);
// The matcher the merger takes: every tag SZFriendsPresenceTagsToMatch accepts at `now` for each conversation's
// secrets (a friend's presence secret; an incoming Add by ID's callback secret) maps to that conversation. Pass
// only people whose tags should be recognised: friends and incoming requests, never blocked or removed people.
// Rebuild it on every window and every change to those secrets and give it to the merger's tagMatcher.
SZFriendsTagMatcher SZFriendsMakeTagMatcher(NSDictionary<NSString *, NSArray<NSData *> *> *secretsByConversation,
                                            NSDate *now);

// Add by ID requests this person sent and has not had answered (ADR 0004 step 3; store table id_requests).
//
// Every device that hears REQUEST_BY_ID learns its callback secret and can compute its callback tags, so how long
// they are advertised is how long that device can follow the requester. Exposure is cut three ways: tags go on the
// air only within SZFriendsCallbackAdvertiseWindow of the last broadcast carrying the secret; a secret is retired a
// day after it was drawn (the helper draws a fresh one and broadcasts again, SZFriendsCallbackNeedsFreshSecret); and
// every advertisement carries exactly SZFriendsCallbackTagsMax callback slots (SZFriendsCallbackSlots), so their
// number says nothing about how many requests are pending.
extern const NSUInteger SZFriendsCallbackTagsMax;              // 4
extern const NSTimeInterval SZFriendsCallbackRequestLifetime;   // 7 days
extern const NSTimeInterval SZFriendsCallbackAdvertiseWindow;   // 6 hours after each broadcast
extern const NSTimeInterval SZFriendsCallbackSecretLifetime;    // 1 day, then a fresh secret and a new broadcast
@interface SZFriendsPendingCallback : NSObject
@property(nonatomic, readonly) NSData *callbackSecret; // 32 bytes
@property(nonatomic, readonly) NSDate *createdAt;
@property(nonatomic, readonly) NSDate *expiresAt;      // the store's createdAt + 7 days
@property(nonatomic, readonly) NSDate *secretIssuedAt; // when this callback secret was drawn
// When REQUEST_BY_ID carrying this secret last went to a device; nil while it never has, which advertises nothing,
// since no device could match the tags yet.
@property(nonatomic, readonly, nullable) NSDate *lastBroadcastAt;
- (instancetype)initWithCallbackSecret:(NSData *)callbackSecret
                             createdAt:(NSDate *)createdAt
                             expiresAt:(NSDate *)expiresAt
                        secretIssuedAt:(NSDate *)secretIssuedAt
                       lastBroadcastAt:(nullable NSDate *)lastBroadcastAt NS_DESIGNATED_INITIALIZER;
// For a store that keeps neither time yet: the secret counts as drawn, and last broadcast, at createdAt.
- (instancetype)initWithCallbackSecret:(NSData *)callbackSecret
                             createdAt:(NSDate *)createdAt
                             expiresAt:(NSDate *)expiresAt;
- (instancetype)init NS_UNAVAILABLE;
@end
// The callback tags to advertise at `now`, one per live request, newest request first. A request is live before its
// expiresAt and 7 days after createdAt (whichever is sooner), within 6 hours of lastBroadcastAt, and within a day of
// secretIssuedAt. At most 4 are kept even if the store hands over more, so a stale row can never put a fifth tag on
// the air. Real tags only: the adapters pad to exactly 4 slots.
NSArray<NSData *> *SZFriendsCallbackTagsToAdvertise(NSArray<SZFriendsPendingCallback *> *pending, NSDate *now);
// YES when the request is still pending but its secret is a day old: draw a fresh secret (SZFriendsNewPresenceSecret),
// store it with secretIssuedAt now, and broadcast REQUEST_BY_ID again with the same token, so a device that heard
// yesterday's secret cannot recognise us today.
BOOL SZFriendsCallbackNeedsFreshSecret(SZFriendsPendingCallback *request, NSDate *now);
// The next moment after `now` when SZFriendsCallbackTagsToAdvertise or SZFriendsCallbackNeedsFreshSecret changes
// for `pending` other than at a window boundary (an advertise window, a secret's day or a request's life ends); nil
// when none will. The helper refreshes its advertisement then.
NSDate *_Nullable SZFriendsCallbackNextChange(NSArray<SZFriendsPendingCallback *> *pending, NSDate *now);

// Exactly SZFriendsCallbackTagsMax callback slots for one advertisement: the real tags, and random 8-byte padding
// that no matcher recognises. Padding is drawn once per rotation (a new presence tag or window) and kept while the
// advertisement is refreshed within it, and a real tag keeps its slot, so re-advertising never shows which slots
// are padding. The coordinator keeps one for both adapters, so both radios carry the same slots.
@interface SZFriendsCallbackSlots : NSObject
// `rotationKey` names the advertisement's window: the presence tag, or the window index when there is none.
- (NSArray<NSData *> *)slotsForTags:(NSArray<NSData *> *)tags rotationKey:(id<NSCopying, NSObject>)rotationKey;
@end

#pragma mark - Merger (pure)

// Per-method expiry (ADR 0004; the spike tunes): a Bonjour endpoint lingers this long after its removal, a
// Bluetooth sighting this long after it was last seen. A Bluetooth removal never shortens or extends that.
extern const NSTimeInterval SZFriendsBonjourRemovalGrace;   // 30 s
extern const NSTimeInterval SZFriendsBluetoothSightingLife; // 90 s

// One person nearby, before or after identification: a friend matched by tag, or a public endpoint. Immutable
// snapshot; the merger replaces it on every change.
@interface SZFriendsCandidate : NSObject
@property(nonatomic, readonly) NSString *candidateID;          // stable while any sighting is alive
@property(nonatomic, readonly, nullable) NSString *conversationID; // set when a presence or callback tag matched
// Public entries of someone not in the list (no conversation): dialed with XX. A friend who is also visible is one
// candidate with a conversation, and isPublic NO, whatever entries they show.
@property(nonatomic, readonly) BOOL isPublic;
@property(nonatomic, readonly) NSArray<SZFriendsSighting *> *sightings; // live ones, best route first (rank)
// The Ed25519 identity key a handshake over one of its public endpoints returned (-identifyEndpoint:...).
@property(nonatomic, readonly, nullable) NSData *identityKey;
// Whether Nearby may show it: a tag matched, or a handshake returned key and profile. An unidentified public
// endpoint is only something to dial.
@property(nonatomic, readonly) BOOL isIdentified;
@end

@interface SZFriendsDiscoveryMerger : NSObject
// `tagMatcher` maps any advertised tag (presence or callback) to a conversation id, or nil. Injected so the merger
// stays pure; the helper builds it with SZFriendsMakeTagMatcher over every friend's secret.
- (instancetype)initWithTagMatcher:(SZFriendsTagMatcher)tagMatcher NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Setting it matches every live sighting again: a new window, a friend added, removed or blocked.
@property(nonatomic, copy) SZFriendsTagMatcher tagMatcher;
- (void)addSighting:(SZFriendsSighting *)sighting;
// Starts the method's removal grace for this endpoint rather than dropping it at once.
- (void)removeEndpoint:(NSString *)endpointID method:(SZFriendsDiscoveryMethod)method atDate:(NSDate *)date;
// Drops sightings past their method's expiry. A candidate disappears only when all its sightings have expired, so
// a brief loss on one method does not flip the route icon. Returns YES when candidates changed.
- (BOOL)expireAtDate:(NSDate *)now;
// Friends matched by tag and public endpoints (identified or not), oldest first.
@property(nonatomic, readonly) NSArray<SZFriendsCandidate *> *candidates;

// A handshake over a public endpoint returned this person's key and profile. Their endpoints then form one
// candidate per key, merged into the conversation's candidate when `conversationID` names someone in the list.
// Forgotten when the endpoint expires.
- (void)identifyEndpoint:(NSString *)endpointID
                  method:(SZFriendsDiscoveryMethod)method
             identityKey:(NSData *)identityKey
          conversationID:(nullable NSString *)conversationID;
// What Nearby shows, one per person: the identified subset of `candidates`.
@property(nonatomic, readonly) NSArray<SZFriendsCandidate *> *identifiedCandidates;
// Hidden devices whose tag nobody in the list matches, one per tag. Never shown; Add by ID nearby sends its NN
// request to each of these and to every public endpoint.
@property(nonatomic, readonly) NSArray<SZFriendsCandidate *> *unmatchedDevices;
- (nullable SZFriendsCandidate *)candidateWithID:(NSString *)candidateID;
// When the next sighting expires (nil when none will): call -expireAtDate: then.
@property(nonatomic, readonly, nullable) NSDate *nextExpiry;
// Increments whenever candidates, identified candidates or unmatched devices change, so the helper can skip
// snapshots when nothing did. A re-sighting with the same content, or a removal still in its grace, does not.
@property(nonatomic, readonly) NSUInteger generation;
@end

#pragma mark - Route racing (pure)

// Dial stagger toward better routes, in SZFriendsRouteRank's order (ADR 0004, ADR 0011; the spike tunes). The relay
// is never dialed from a sighting before the direct phase's plain checks could have ended; the online order
// component (service/online/order/) starts it.
extern const NSTimeInterval SZFriendsDialDelayLAN;            // 0 s
extern const NSTimeInterval SZFriendsDialDelayPeerToPeerWiFi; // 0.15 s
extern const NSTimeInterval SZFriendsDialDelayInternet;       // 0.3 s
extern const NSTimeInterval SZFriendsDialDelayBluetooth;      // 0.5 s
extern const NSTimeInterval SZFriendsDialDelayRelay;          // 5 s: ADR 0011's plain-check budget
// The delay an attempt on `route` waits; None and unknown values wait like the relay.
NSTimeInterval SZFriendsDialDelayForRoute(SZFriendsRouteMethod route);

// One connection attempt the racer wants made: which endpoint, by which method, after what delay.
@interface SZFriendsDialAttempt : NSObject
@property(nonatomic, readonly) SZFriendsSighting *sighting;
@property(nonatomic, readonly) NSTimeInterval delay;
@end

typedef NS_ENUM(NSInteger, SZFriendsRaceDecision) {
    SZFriendsRaceDecisionAdopt = 0,     // first completed handshake: carry traffic on it now
    SZFriendsRaceDecisionUpgrade = 1,   // faster than the current session: move traffic, close the old one
    SZFriendsRaceDecisionClose = 2,     // slower or duplicate: close it
};

// After a handshake fails for a person (refused, timed out, the wrong device) at an endpoint showing one of their
// tags, no endpoint showing that tag is dialed for them by that method until a backoff passes, doubling per further
// failure. Keyed per person, method and tag (a tag is one window of one secret), never per endpoint: a device
// re-advertising someone's captured tag (ADR 0004 § Presence tags) learns who their friends are from who dials it,
// and keyed per endpoint it drew a fresh dial from every friend each time it re-advertised under a new Bonjour name.
// The price: while a relayed tag is backing off, the real device showing the same tag waits too, on that method only
// and for that window only. An endpoint showing no tag (a public entry) backs off on its own.
extern const NSTimeInterval SZFriendsEndpointBackoffFirst; // 2 s
extern const NSTimeInterval SZFriendsEndpointBackoffMax;   // 900 s: one window, after which tags have rotated

@interface SZFriendsRouteRacer : NSObject
// Stamps failures and decides when backoffs end; default [NSDate date]. Injected by tests.
@property(nonatomic, copy) NSDate * (^clock)(void);
// Which of an endpoint's tags (presence or callback) names the candidate's conversation, so a failure is held
// against the tag that matched rather than one a relayer could vary. The coordinator passes its merger's matcher;
// without one the presence tag counts.
@property(nonatomic, copy, nullable) SZFriendsTagMatcher tagMatcher;
// Dial every sighted endpoint at once with IK, staggered in rank order (LAN, peer-to-peer Wi-Fi, Internet, Bluetooth,
// relay), shortest delay first. Every endpoint of the candidate is dialed, lingering ones included, so a Bluetooth
// sighting never holds back Wi-Fi attempts to endpoints known for that friend (the coordinator also asks for a fresh
// browse). A friend's public entries are skipped while a hidden one is known: IK belongs on the hidden listener.
// Endpoints in their backoff for the candidate's conversation are left out.
- (NSArray<SZFriendsDialAttempt *> *)attemptsForCandidate:(SZFriendsCandidate *)candidate;
// The helper reports how each dial for a person ended before the session went live: a failure starts or doubles
// the backoff of the tag that endpoint showed when the racer last handed it out (of the endpoint itself when it
// showed none, or was never handed out); a session that went live clears it.
- (void)noteHandshakeFailedAtEndpoint:(NSString *)endpointID
                               method:(SZFriendsDiscoveryMethod)method
                       conversationID:(NSString *)conversationID;
- (void)noteHandshakeSucceededAtEndpoint:(NSString *)endpointID
                                  method:(SZFriendsDiscoveryMethod)method
                          conversationID:(NSString *)conversationID;
// When the earliest running backoff ends (nil when none runs): look at the candidates again then.
@property(nonatomic, readonly, nullable) NSDate *nextBackoffEnd;
// When an attempt's delay has passed: start it only while no session exists or its route ranks before `current`
// (SZFriendsRouteRank). Attempts on an equal or worse route are never started once a session is up.
- (BOOL)shouldStartAttempt:(SZFriendsDialAttempt *)attempt currentRoute:(SZFriendsRouteMethod)current;
// Called when a handshake completes on `route` while `current` carries the session (None when none): Upgrade only
// when `route` ranks strictly before `current`, so Internet supersedes Bluetooth and any direct route the relay.
- (SZFriendsRaceDecision)decisionForCompletedRoute:(SZFriendsRouteMethod)route
                                      currentRoute:(SZFriendsRouteMethod)current;
@end

// ADR 0001 § Session race: two live sessions with one friend (both dialed at once, or several routes). Both sides
// reach the same answer from facts both hold: the better route class as each initiator declared it wins, by
// SZFriendsRouteRank (None and any value outside LAN through Relay rank below every real class, so a session that
// never declared one cannot beat one that did); within a class, the session initiated by the lower Ed25519 identity
// key (bytewise; a shorter key that is a prefix of the other sorts first) wins. YES keeps session A. Identical class
// and key mean one side dialed twice on one class: nothing both sides hold tells the sessions apart, so this returns
// YES and only that initiator acts on it, passing the session already carrying traffic as A and closing the other;
// the responder waits for its CLOSE.
BOOL SZFriendsSessionAWins(SZFriendsRouteMethod routeA, NSData *initiatorKeyA, SZFriendsRouteMethod routeB,
                           NSData *initiatorKeyB);

#pragma mark - Visibility deadline (pure)

// "Make myself visible for 5 minutes" (brief § Product; PROTOCOL.md start_visibility). The deadline is absolute:
// expiry, sleep and wake, disabling and restarting never extend it, and repeating start does not either.
extern const NSTimeInterval SZFriendsVisibilityDuration; // 300 s

// Two readings of one moment. Wall time is what the store keeps across restarts. Continuous time counts sleep
// (mach_continuous_time) and cannot be set back, so setting the clock back cannot extend a running deadline.
typedef struct SZFriendsInstant {
    NSTimeInterval wall;       // seconds since 1970
    NSTimeInterval continuous; // seconds on a clock that keeps counting during sleep
} SZFriendsInstant;
SZFriendsInstant SZFriendsInstantNow(void);

@interface SZFriendsVisibility : NSObject
// `storedDeadline` is the store's visibilityDeadline. One already past, or further away than 5 minutes (the clock
// was set back since it was stored), is dropped at once: visibility fails closed.
- (instancetype)initWithStoredDeadline:(nullable NSDate *)storedDeadline
                                   now:(SZFriendsInstant)now NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Visible for 5 minutes from now, or the running deadline unchanged. Returns the deadline to store and report.
- (NSDate *)startAt:(SZFriendsInstant)now;
- (void)stop;
// Checks both clocks; once either says the 5 minutes are over, clears the deadline and returns NO. The helper calls
// it on every tick, after a wake before advertising anything, and when Friends is enabled again.
- (BOOL)isVisibleAt:(SZFriendsInstant)now;
- (NSTimeInterval)remainingAt:(SZFriendsInstant)now; // 0 when hidden
// The deadline to store (nil when hidden). Reflects the last check; call -isVisibleAt: first.
@property(nonatomic, readonly, nullable) NSDate *deadline;
@end

NS_ASSUME_NONNULL_END
