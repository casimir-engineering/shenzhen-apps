// The helper's check-in with the Friends host: whether it may run at all, and the glue between the host area's
// SZFriendsCheckInClient and the store's Friends ID (ADR 0005, ADR 0006). Internal to the helper.
//
// Production (no SZFRIENDS_STATE_DIR) checks in with the hosts in the signed list bundled in the helper
// (Resources/bootstrap-hosts.json, verified with Resources/pinned-keys.json), or a newer cached one. Under
// SZFRIENDS_STATE_DIR (tests, probes, the two-helper harness) it never checks in, unless both test-only variables
// below name readable files and every host in that list is on the loopback interface:
//   SZFRIENDS_TEST_HOST_LIST  absolute path of a signed host list (the local host harness's)
//   SZFRIENDS_TEST_HOST_KEYS  absolute path of the pinned-keys file that list verifies with
// So no test can reach friends.meerkat.orgabots.com, or any other machine, by forgetting a setting.

#import <Foundation/Foundation.h>

#import "service/host/SZFriendsHostConnection.h"

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsHelperServices;
@class SZFriendsStore;

// What a check-in would start from; nil when this helper must not check in.
@interface SZFriendsCheckInSetup : NSObject
@property(nonatomic, readonly) NSData *bootstrapData;
@property(nonatomic, readonly) NSArray<NSData *> *pinnedKeys;
@property(nonatomic, readonly) BOOL loopbackOnly; // the test override: every start re-checks the current list
// `bundledList` and `bundledKeys` are the helper bundle's resources (nil outside a bundle). `why` says, for the log,
// why there is no setup.
+ (nullable instancetype)setupWithEnvironment:(NSDictionary<NSString *, NSString *> *)env
                                  bundledList:(nullable NSData *)bundledList
                                  bundledKeys:(nullable NSData *)bundledKeys
                                          why:(NSString *_Nullable *_Nullable)why;
@end

// Every rendezvous and relay URL is ws:// or wss:// on 127.0.0.1, ::1 or localhost, and every STUN and TURN URI
// (online Friends' tests run them locally) names one of those hosts.
BOOL SZFriendsHostListIsLoopbackOnly(SZFriendsHostList *list);

// The store's sync state keys the check-in keeps (SZFriendsStoreSync.h): a release owed for this computer's ID from
// before it joined a profile, and the host's word that another of the person's computers removed this one.
extern NSString *const SZFriendsCheckInPreJoinReleaseKey;
extern NSString *const SZFriendsCheckInRemovedByHostKey;

// Protocol 3: the person this computer speaks for and the chain that shows it (on the first computer, only once the
// profile has others), asked at each check-in. A computer that joined a profile never draws an ID: the person's is
// reserved from their first one.
void SZFriendsConfigureCheckInMembership(SZFriendsCheckInClient *client, SZFriendsStore *store, NSData *localKey);

@interface SZFriendsHelperCheckIn : NSObject <SZFriendsCheckInDelegate>
- (instancetype)initWithServices:(SZFriendsHelperServices *)services
                           setup:(SZFriendsCheckInSetup *)setup
                           cache:(SZFriendsHostListCache *)cache
                           queue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// The ID's reservation state or the update notice changed: snapshots may differ.
@property(nonatomic, copy, nullable) void (^onChange)(void);
// With the current identity; after Reset Friends, call again for the new one.
- (void)start;
// Disable and exit stop all host contact at once.
- (void)stop;
// This computer just joined a person's profile: the check-in starts again for that person, after the ID this computer
// held on its own is released (at the next start too, until a host confirms the release).
- (void)restartAfterJoining;
// This computer removed another: a new check-in brings the chain, so the host turns that computer away (4002) from now
// on, and disconnects it if it is connected.
- (void)restartAfterRevoking;
// Check-in clients started since launch (each connection run), for tests.
@property(nonatomic, readonly) NSUInteger clientsStarted;
// Reset Friends: the signed release frees the ID on the host first (best effort, 5 s at most); then `completion`.
// Never on the profile's first computer while the profile has others: the ID is theirs too (the host refuses it too).
- (void)releaseIdentityWithCompletion:(void (^)(void))completion;
// The provider's rule, exposed for tests: the current ID first, then a fresh draw after each "taken" that never
// repeats the refused one; the collision count is stored as it grows (ADR 0006).
- (NSString *)friendsIDForCollisionsInARow:(NSUInteger)collisionsInARow;
// The host's newest attestation that `friendsID` is this identity's, for answering an Add by ID (ADR 0004, Review
// amendments, 9): the check-in client keeps it across launches and gives it only while it checks out against the
// current list today. Nil before any reservation, after a rename to another ID, and while not checking in.
- (nullable SZFriendsHostAttestation *)attestationForFriendsID:(NSString *)friendsID;
@end

NS_ASSUME_NONNULL_END
