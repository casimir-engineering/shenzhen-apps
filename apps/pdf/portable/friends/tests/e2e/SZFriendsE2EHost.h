// friends-e2e-check: the local Node host service (portable/server/friends) on 127.0.0.1, for scenarios whose helpers
// check in. Its list is signed with a throwaway key and names 127.0.0.1 only, and a helper under SZFRIENDS_STATE_DIR
// refuses any other (SZFriendsHostCheckIn.h), so no scenario reaches the production host.

#import "SZFriendsE2EHarness.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFE2ELocalHost : NSObject
// Starts the service in the world's scenario directory. Nil with `skip` saying why when it cannot run here (no
// Node.js 22.16, no node_modules: the scenario then passes with a line saying so); nil with `skip` nil when it failed
// to start, which is recorded as a failure with the service's errors.
+ (nullable instancetype)startInWorld:(SZFE2EWorld *)world skip:(NSString *_Nullable *_Nonnull)skip;
// SZFRIENDS_TEST_HOST_LIST and SZFRIENDS_TEST_HOST_KEYS: what a helper needs to check in with it.
@property(nonatomic, readonly) NSDictionary<NSString *, NSString *> *helperEnvironment;
// Stops the service and reaps it; idempotent.
- (void)stop;
@end

// The profile view's `id` of a client subscribed to it (state, friends_id).
NSDictionary *_Nullable SZFE2EProfileID(SZFE2EClient *client, NSString *subscription);
// Where a helper's check-in client keeps its host attestation: beside the cached list in its state directory.
NSString *SZFE2EAttestationPath(SZFE2EHelper *helper);
// The helper's Friends ID once the host reserved it and its attestation is kept, so its next Add by ID answer shows
// it; nil after recording a failure when that takes over 10 s.
NSString *_Nullable SZFE2EReservedAndAttested(SZFE2EClient *client, SZFE2EHelper *helper);

NS_ASSUME_NONNULL_END
