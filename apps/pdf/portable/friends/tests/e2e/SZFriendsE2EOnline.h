// friends-e2e-check, online Friends: two real helpers that are friends but never meet nearby (each browses its own
// loopback Bonjour type) reach each other through the local Node host service with FRIENDS_M2 and FRIENDS_RELAY on,
// and a coturn built from pinned source (FRIENDS_TEST_COTURN). Everything stays on this Mac: the host and coturn
// listen on 127.0.0.1, the peers bind to 127.0.0.1 (the online helper's test hooks, SZFriendsE2EOnlineHelperMain.m),
// and coturn relays from en0's address so the relayed path stays relay to relay. Never the production host: the
// signed list names 127.0.0.1 only, and a helper under SZFRIENDS_STATE_DIR refuses any other.

#import "SZFriendsE2EHarness.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFE2EOnlineHost : NSObject
// The Node host and, when FRIENDS_TEST_COTURN names one, coturn at the host's 5 Mbit/s cap (max-bps=625000). Nil with
// `skip` saying why when this Mac cannot run it (no Node.js 22.16, no node_modules, or no coturn when `relay`); nil
// with `skip` nil when it failed to start (recorded as a failure).
+ (nullable instancetype)startInWorld:(SZFE2EWorld *)world relay:(BOOL)relay skip:(NSString *_Nullable *_Nonnull)skip;
// What a helper needs to check in with it, beside its own Bonjour type so the two never meet nearby.
- (NSDictionary<NSString *, NSString *> *)environmentForHelper:(NSString *)name;
- (void)stop;
@end

// Two helpers' stores, before either starts: each holds the other as a friend with the keys and presence secret a
// nearby friendship leaves behind. The conversation ids each side gives the other come back.
BOOL SZFE2EOnlineSeedFriends(SZFE2EHelper *a, SZFE2EHelper *b, NSString *_Nullable *_Nonnull bAtA,
                             NSString *_Nullable *_Nonnull aAtB);

// While this exists in a helper's state directory, it sends and applies no direct candidate: only the relay connects.
NSString *SZFE2EOnlineBlockPath(SZFE2EHelper *helper);

BOOL SZFE2EOnlineScenarioDirect(SZFE2EWorld *world);
BOOL SZFE2EOnlineScenarioRelayThenDirect(SZFE2EWorld *world);
// Add by ID online (SZFriendsE2EOnlineAddScenarios.m).
BOOL SZFE2EOnlineScenarioAddByID(SZFE2EWorld *world);
BOOL SZFE2EOnlineScenarioFriendLink(SZFE2EWorld *world);
BOOL SZFE2EOnlineScenarioLinkKeyMismatch(SZFE2EWorld *world);
BOOL SZFE2EOnlineScenarioLinkCap(SZFE2EWorld *world);

NS_ASSUME_NONNULL_END
