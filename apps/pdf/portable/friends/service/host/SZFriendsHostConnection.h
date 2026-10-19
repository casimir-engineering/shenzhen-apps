// Shenzhen Friends host connection: the signed host list and the check-in that runs while an app is open.
//
// Helper-only. One WebSocket over TLS on 443 to the highest-priority reachable host, kept open while any app
// with Friends on runs, reconnecting with jittered backoff (brief § Friends host). Readers never contact the
// host and nothing on a reader's main thread waits for it. When no host is reachable, Nearby is unaffected,
// nothing claims Online, the Friends ID stays unreserved and the helper retries quietly.
//
// ADR 0005 (portable/friends/docs/adr/0005-friends-host-service.md) is the decision. The messages on that
// WebSocket are the host protocol, versioned and documented with the host service in portable/server/friends/;
// this header is the helper's side of it. Production host: wss://friends.meerkat.orgabots.com/v1 (bootstrap
// list). Tests run the host service locally on loopback and never contact the production host, and a release
// check fails if the helper pins a test key.
//
// Not to be confused with mac/SZFriendsHost.h, the adapter protocol for the app that hosts the Friends views.
//
// Threading: every callback (socket, delegate, completion) runs on the queue given to SZFriendsCheckInClient.
// The host protocol document is portable/server/friends/HOST-PROTOCOL.md.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsIdentity;
@class SZFriendsIDCodec;

// The host protocol version this helper speaks, sent in every check-in; the host service declares the same
// number beside its own code (HOST_PROTOCOL_VERSION in portable/server/friends/src/protocol.js), and its
// document says what each version means.
extern const NSInteger SZFriendsHostProtocolVersion; // 3: a device checks in for its person (§ Devices)

extern NSErrorDomain const SZFriendsHostErrorDomain;

typedef NS_ERROR_ENUM(SZFriendsHostErrorDomain, SZFriendsHostError) {
    SZFriendsHostErrorMalformed = 1,      // not an envelope, or a payload the rules refuse
    SZFriendsHostErrorBadSignature = 2,   // no valid signature from a pinned key
    SZFriendsHostErrorStale = 3,          // older than the current list
    SZFriendsHostErrorSubstituted = 4,    // same version as the current list, different payload
    SZFriendsHostErrorAlreadyCurrent = 5, // the current list again; nothing to do
};

#pragma mark - Signed host list

typedef NS_OPTIONS(NSUInteger, SZFriendsHostRole) {
    SZFriendsHostRoleRendezvous = 1 << 0,
    SZFriendsHostRoleRelay = 1 << 1,
};

@interface SZFriendsHostEntry : NSObject
@property(nonatomic, readonly) NSString *hostID;              // named in check-in signatures (ADR 0005 step 2)
@property(nonatomic, readonly) SZFriendsHostRole roles;
@property(nonatomic, readonly) NSArray<NSURL *> *urls;       // wss:// endpoints
@property(nonatomic, readonly) NSArray<NSString *> *turnURIs; // M2
@property(nonatomic, readonly) NSString *region;
@property(nonatomic, readonly) NSInteger priority;            // 1 among rendezvous hosts: the only ID allocator
@property(nonatomic, readonly) NSData *publicKey;             // 32-byte Ed25519 host key: signs its replies
@end

// Envelope {"payload": "<base64url of UTF-8 JSON>", "sigs": [{"key": "primary"|"backup", "sig": "..."}]}; each
// signature is Ed25519 over "SZFriends host list v1\n" || payload bytes, made offline with an admin key that
// never lives on a host. The app pins two public keys (primary and backup), one valid signature suffices, and a
// lost key is replaced by a release. The signature, not the server, makes a list trustworthy, so any host or
// mirror may serve it. Payload: version (only increases), issued_at, new_id_words (2 or 3, ADR 0006), hosts.
@interface SZFriendsHostList : NSObject
@property(nonatomic, readonly) NSInteger version;
@property(nonatomic, readonly) NSDate *issuedAt;
@property(nonatomic, readonly) NSInteger newIDWords;                   // words in newly drawn Friends IDs
@property(nonatomic, readonly) NSArray<SZFriendsHostEntry *> *entries; // sorted by priority
// The exact envelope bytes, kept so the cache can be re-verified on load; payload bytes are parsed exactly as
// signed, never re-serialized.
@property(nonatomic, readonly) NSData *signedData;

// Verifies a signature against `pinnedKeys` (32-byte Ed25519 public keys) and parses. Nil with an error for
// unsigned, malformed or wrongly signed input. Freshness is the cache's decision, not the parser's.
+ (nullable instancetype)listFromSignedData:(NSData *)data
                                 pinnedKeys:(NSArray<NSData *> *)pinnedKeys
                                      error:(NSError **)error;
@end

// The pinned host-list keys from the pinned-keys file the helper bundles (friends/service/host/resources/
// pinned-keys.json, listed in FRIENDS_HOST_RESOURCES in host.mk): {"keys": [{"name", "public_key" (base64url,
// 32 bytes), "test"}]}. `containsTestKeys` reports whether any entry is not explicitly "test": false, which the
// release check refuses. Nil with an error for a malformed file or one with no keys.
NSArray<NSData *> *_Nullable SZFriendsHostPinnedKeysFromData(NSData *data, BOOL *_Nullable containsTestKeys,
                                                            NSError **error);

// The newest verified list: <state dir>/hosts.json when it verifies and is at least as new as the bootstrap list
// in the helper bundle, which is also a floor (a cache older than the bundled list is replaced). Lists never
// expire, so withholding updates cannot strand clients.
@interface SZFriendsHostListCache : NSObject
- (instancetype)initWithCachePath:(NSString *)cachePath
                    bootstrapData:(NSData *)bootstrapData
                       pinnedKeys:(NSArray<NSData *> *)pinnedKeys NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// hosts.json in the state directory; the check-in client keeps its attestation beside it.
@property(nonatomic, readonly) NSString *cachePath;
// Never nil: with neither a verifying cache nor a verifying bootstrap list (a build that pinned keys without
// re-signing the bundled list) it is an empty list of version 0, so the helper stays unreachable rather than
// trusting anything unsigned. Safe to read from any thread.
@property(nonatomic, readonly) SZFriendsHostList *currentList;
// Accepts only a verified list with a higher version than the current one, then writes it atomically.
// Rejects older versions, and an equal version with different bytes (rollback or substitution), so a replayed
// old list cannot redirect clients. Errors are in SZFriendsHostErrorDomain.
- (BOOL)offerSignedList:(NSData *)data error:(NSError **)error;
@end

#pragma mark - ID attestations

// How many days after the day it names an attestation stays good (HOST-PROTOCOL.md § ID attestations).
extern const NSInteger SZFriendsHostAttestationMaxAgeDays; // 30

// A host's signed statement that a Friends ID was reserved for an identity key, as of a UTC day. Anyone nearby who
// hears an Add by ID can answer it, and nothing offline ties an ID to a key; this does. The host sends one with every
// reservation answer that says "reserved", the check-in client keeps the newest (-attestationForFriendsID:), and the
// helper can show it when it answers an Add by ID, so the requester can tell the ID's holder from anyone who heard
// the request. Signed with the host key the signed list gives `hostID`: Ed25519 over "SZFriends id attestation v1"
// followed by the length-prefixed host id, Friends ID, identity key and day. A compromised listed host can still
// attest falsely; a list that drops it ends that. An ID released and given to someone else stays attestable by its
// previous holder until their last attestation expires.
@interface SZFriendsHostAttestation : NSObject
@property(nonatomic, readonly) NSString *hostID;
@property(nonatomic, readonly) NSString *friendsID;
@property(nonatomic, readonly) NSData *identityKey; // 32-byte Ed25519 identity public key
@property(nonatomic, readonly) NSString *day;       // YYYY-MM-DD in UTC: when the host last confirmed the reservation
@property(nonatomic, readonly) NSData *signature;   // 64 bytes
// The wire form the host sends, {"host_id", "friends_id", "identity_key", "day", "sig"} with base64url keys and
// signature. Nil for anything that is not one: wrong types or lengths, a host id or Friends ID of the wrong shape, a
// day that is not a calendar day. The signature is not checked here; SZFriendsHostAttestationCheck checks it.
+ (nullable instancetype)attestationFromDictionary:(id)dictionary;
// The same object as UTF-8 JSON, at most 1 KiB: what -encodedData produces, for carrying it in another protocol.
+ (nullable instancetype)attestationFromData:(NSData *)data;
- (NSDictionary<NSString *, NSString *> *)dictionary;
- (NSData *)encodedData;
@end

typedef NS_ENUM(NSInteger, SZFriendsHostAttestationVerdict) {
    SZFriendsHostAttestationValid = 0,
    SZFriendsHostAttestationMalformed = 1,    // nil: not an attestation
    SZFriendsHostAttestationUnknownHost = 2,  // not a rendezvous host in the list (only those check helpers in)
    SZFriendsHostAttestationBadSignature = 3, // not signed by the key the list gives that host
    SZFriendsHostAttestationWrongHolder = 4,  // genuine, but for another Friends ID or identity key than claimed
    SZFriendsHostAttestationExpired = 5,      // dated over 30 days before `now`, or more than a day after it
};

// Whether `attestation` shows that `friendsID` (canonical form, as SZFriendsIDCodec normalizes it) is reserved for
// `identityKey`, according to `list` (a verified signed list, such as SZFriendsHostListCache.currentList), and is
// recent at `now`. The checks run in the order of the verdicts and the first failure is returned; the host service's
// checkAttestation gives the same verdicts on the shared vectors. Pure; any thread.
SZFriendsHostAttestationVerdict SZFriendsHostAttestationCheck(SZFriendsHostAttestation *_Nullable attestation,
                                                              SZFriendsHostList *list, NSString *friendsID,
                                                              NSData *identityKey, NSDate *now);

#pragma mark - Transport seam

// One WebSocket. NSURLSessionWebSocketTask in production; a scripted fake in tests (unreachable hosts, slow
// failures, replicas racing for one ID) so check-in logic is tested without a network.
@protocol SZFriendsHostSocket <NSObject>
@property(nonatomic, copy, nullable) void (^onOpen)(void);
@property(nonatomic, copy, nullable) void (^onMessage)(NSData *message);
@property(nonatomic, copy, nullable) void (^onClose)(NSError *_Nullable error);
- (void)open;
- (void)sendMessage:(NSData *)message;
- (void)close;
@end

typedef id<SZFriendsHostSocket> _Nonnull (^SZFriendsHostSocketFactory)(NSURL *url);

// The production socket: NSURLSessionWebSocketTask on an ephemeral session (no cookies, no cache), messages of at
// most 64 KiB as JSON text, callbacks on `queue`. It pings every 25 s and reports a close when a pong does not
// come back within 15 s, because a dead TCP path (sleep, a dropped mobile link) can otherwise go unnoticed for
// minutes. URLs must be wss://, or ws:// on loopback for the local test harness.
SZFriendsHostSocketFactory SZFriendsHostWebSocketFactory(dispatch_queue_t queue);

#pragma mark - Check-in

typedef NS_ENUM(NSInteger, SZFriendsHostState) {
    SZFriendsHostStateStopped = 0,
    SZFriendsHostStateConnecting = 1,
    SZFriendsHostStateConnected = 2,   // checked in; the host knows this identity is online
    SZFriendsHostStateUnreachable = 3, // every host failed; retrying with backoff; Nearby unaffected
};

@protocol SZFriendsCheckInDelegate <NSObject>
- (void)checkInStateDidChange:(SZFriendsHostState)state;
// The main host granted `friendsID` (first reservation wins), or this key already held it on record (a
// reinstall that kept its key adopts its old ID, which only a check-in's welcome can do). A replica that cannot
// reach the main host answers "unavailable": no callback, and the ID stays unreserved. So does an answer whose
// host signature does not verify, or whose ID is not two or three list words (or, after a collision, is not the
// ID just asked for).
- (void)checkInDidReserveID:(NSString *)friendsID;
// `friendsID` was taken; the client drew `newID` and the host reserved that instead. Keys, friends and history
// are unchanged because friends are stored by key. The store records the old ID for the one-time notice.
- (void)checkInDidRenameIDFrom:(NSString *)friendsID to:(NSString *)newID;
// The host says this app's protocol is too old for online Friends; reading and Nearby keep working.
- (void)checkInRequiresUpdate;
@optional
// The host closed with 4002: another of the person's devices removed this one. The client has stopped for good.
- (void)checkInDeviceWasRevoked;
// A host attested the ID just reserved or renamed to (after -checkInDidReserveID: or -checkInDidRenameIDFrom:to:).
// The client has already checked it against the current list and kept it; -attestationForFriendsID: returns it.
- (void)checkInDidReceiveAttestation:(SZFriendsHostAttestation *)attestation;
@end

@interface SZFriendsCheckInClient : NSObject
- (instancetype)initWithListCache:(SZFriendsHostListCache *)cache
                         identity:(SZFriendsIdentity *)identity
                       appVersion:(NSString *)appVersion
                    socketFactory:(SZFriendsHostSocketFactory)socketFactory
                            queue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, weak, nullable) id<SZFriendsCheckInDelegate> delegate;
@property(nonatomic, readonly) SZFriendsHostState state;
// Whether the store says the current ID is reserved; sent in the check-in (ADR 0005 step 2) and set to YES by the
// client after a reservation. The host decides from its own records either way.
@property(nonatomic) BOOL friendsIDReserved;
// How long one host may take to open and answer the check-in before the next host in the list is tried.
// Default 10 s.
@property(nonatomic) NSTimeInterval connectTimeout;
// Checks every Friends ID a host returns. Nil until set means a codec over SZFriendsWordList.bundledList, made when
// the client starts; when even that is missing, no answer is believed and the ID stays unreserved.
@property(nonatomic, nullable) SZFriendsIDCodec *idCodec;
// How long releaseIdentityWithCompletion: waits for an answer. Default 5 s.
@property(nonatomic) NSTimeInterval releaseTimeout;
// Default YES: a Network.framework path monitor calls -networkDidChange. Tests turn it off for determinism.
@property(nonatomic) BOOL watchesNetworkPath;
// Where the newest attestation is kept between launches (mode 0600, written atomically), so it can be shown nearby
// before the host answers or while no host is reachable. Defaults to host-attestation.json beside the list cache;
// nil keeps it in memory only. Set before starting.
@property(copy, nullable) NSString *attestationPath;
// Protocol 3 (HOST-PROTOCOL.md § Devices): the person this device speaks for, asked at every check-in. Returns their
// root key and sets `*chain` to the device chain that shows this device belongs to them (on the first device, whose
// own key is the root, the chain once it names other devices, so the host learns of removals). Unset or nil: the
// device is its own root and brings no chain.
@property(nonatomic, copy, nullable) NSData *_Nullable (^membershipProvider)(NSData *_Nullable *_Nonnull chain);
// Default YES. NO on a device that joined a person's profile: the Friends ID is the person's, so after "taken" or
// "invalid" it draws no ID of its own and claims nothing more on that connection.
@property(nonatomic) BOOL drawsIDs;
// The root key the current connection checked in for (this identity's own key without a membership); the
// attestation names it and the online side files records under it. Nil before the first check-in. Client's queue.
@property(nonatomic, readonly, nullable) NSData *personKey;

// The attestation to show when answering an Add by ID for `friendsID`: the newest one a host gave this identity,
// when it names `friendsID` and still checks out against the current list today. Nil otherwise, including after a
// release. Any thread.
- (nullable SZFriendsHostAttestation *)attestationForFriendsID:(NSString *)friendsID;

// Check-in answers the host's challenge with the identity public key, a signature bound to the challenge and the
// host id (so nobody can inflate counts or appear online as someone else, and one host cannot replay it to
// another), the Friends ID to reserve when unreserved, app and protocol versions, and the host-list version held.
// The host signs its answers with the host key the list gives it, over the same challenge; an answer that does not
// verify counts as "unavailable", so a TLS-intercepting proxy can neither rename nor stall anyone. A newer signed
// list in the reply, or pushed later, goes to the cache. `idProvider` returns the ID to claim: the current one with
// collisionsInARow 0, then a fresh draw after each "taken" (at most 20 per connection and 40 per launch); it uses
// SZFriendsWordCountForNewID with the list's newIDWords. Reconnect backoff keeps growing until a reservation
// succeeds, so a host that refuses every ID and hangs up is retried less and less often.
- (void)startWithFriendsIDProvider:(NSString * (^)(NSUInteger collisionsInARow))idProvider;
// Disable and helper exit stop all host contact at once.
- (void)stop;
// A network change (new Wi-Fi, VPN up, wake): while waiting to retry, try again at once (ADR 0005 step 5).
- (void)networkDidChange;
// Reset Friends: a signed `release` frees the ID and deletes this identity's row on the host. Best effort:
// the completion runs once, with NO when no host answered in time; the reset goes ahead either way.
// Uses the open connection when checked in, otherwise opens one. Stops the client: it does not reconnect after.
- (void)releaseIdentityWithCompletion:(void (^)(BOOL released))completion;

// Backoff before reconnect attempt `attempt` (0-based): exponential from 1 s to 5 min with full jitter.
// Exposed so tests check the bound without waiting. `jitter` is uniform in [0, 1).
// Concretely 1 + jitter * (min(300, 2^attempt) - 1) seconds: never sooner than 1 s, never later than 5 min.
+ (NSTimeInterval)backoffForAttempt:(NSUInteger)attempt jitter:(double)jitter;
@end

#pragma mark - Friends ID provider

typedef NSString *_Nonnull (^SZFriendsIDProvider)(NSUInteger collisionsInARow);

// The standard idProvider for -startWithFriendsIDProvider:. collisionsInARow 0 returns `currentID`; every later
// call draws a fresh ID from `codec` with SZFriendsWordCountForNewID(cache.currentList.newIDWords,
// collisionsInARow) words and libsodium's randombytes_uniform (sodium_init() must have run).
SZFriendsIDProvider SZFriendsHostIDProvider(NSString *currentID, SZFriendsIDCodec *codec,
                                            SZFriendsHostListCache *cache);

NS_ASSUME_NONNULL_END
