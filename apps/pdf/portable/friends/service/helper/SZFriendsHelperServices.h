// The service areas as the helper holds them: resources loaded at start, identity, store, outbox, transfers.
//
// Internal to the helper. Opening follows SZFriendsHelperMain's order after the lock and sodium_init(): resources
// first (the updater may replace the bundle while the helper runs, ADR 0002 § Bundle replacement), then identity,
// then the store. Every other area is reached only through its public header.

#import <Foundation/Foundation.h>

#import "avatars/SZFriendsAvatars.h"
#import "service/helper/SZFriendsHelper.h"
#import "service/identity/SZFriendsIdentity.h"
#import "service/presentation/SZFriendsPresentation.h"
#import "service/store/SZFriendsOutbox.h"
#import "service/store/SZFriendsStore.h"
#import "service/store/SZFriendsTransfers.h"

NS_ASSUME_NONNULL_BEGIN

// Everything the helper reads from its own bundle, read once at start.
@interface SZFriendsHelperResources : NSObject
+ (instancetype)loadFromBundle:(NSBundle *)bundle;
@property(nonatomic, readonly, nullable) SZFriendsWordList *wordList;
@property(nonatomic, readonly, nullable) SZFriendsAnimalSet *animalSet;
// Resources/bootstrap-hosts.json, the signed host list the host connection falls back to (ADR 0005), and
// Resources/pinned-keys.json, the keys it must verify with.
@property(nonatomic, readonly, nullable) NSData *bootstrapHostList;
@property(nonatomic, readonly, nullable) NSData *pinnedHostKeys;
@end

@class SZFriendsCheckInSetup;
@class SZFriendsHelperCheckIn;
@class SZFriendsHostListCache;
@class SZFriendsLinkService;
@class SZFriendsNearbyService;

@interface SZFriendsHelperServices : NSObject
- (instancetype)initWithPaths:(SZFriendsStatePaths *)paths
                  environment:(NSDictionary<NSString *, NSString *> *)environment
                    resources:(SZFriendsHelperResources *)resources NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) SZFriendsStatePaths *paths;
@property(nonatomic, readonly) SZFriendsHelperResources *resources;

// Identity, then store. Never fails as a whole: an unreadable identity or an unopenable store becomes a state
// the views explain (identity unavailable, update required) instead of a helper that will not start.
- (void)open;
- (void)close;

@property(nonatomic, readonly, nullable) SZFriendsIdentity *identity;
@property(nonatomic, readonly) SZFriendsIdentityState identityState;
@property(nonatomic, readonly, nullable) SZFriendsStore *store;
@property(nonatomic, readonly, nullable) SZFriendsOutbox *outbox;
@property(nonatomic, readonly, nullable) SZFriendsTransfers *transfers;
@property(nonatomic, readonly, nullable) SZFriendsIDCodec *codec;
// Store when a newer helper raised the store's minimum reader version past this one (ADR 0003); Online when the
// host said online Friends needs a newer app.
@property(nonatomic) SZFriendsUpdateNeed updateNeed;
// The verified host list (its new_id_words decides how many words a new ID has) and whether this helper checks in
// at all (SZFriendsHostCheckIn.h); both nil when it must not.
@property(nonatomic, readonly, nullable) SZFriendsCheckInSetup *checkInSetup;
@property(nonatomic, readonly, nullable) SZFriendsHostListCache *hostListCache;
// Set by SZFriendsHelperMain once the socket is bound; nil before, and without a store or identity.
@property(nonatomic, strong, nullable) SZFriendsNearbyService *nearby;
@property(nonatomic, strong, nullable) SZFriendsHelperCheckIn *checkIn;
// Friend and download links (SZFriendsHelperLinks.h): made on first use, never at launch.
@property(nonatomic, strong, nullable) SZFriendsLinkService *links;
@property(nonatomic, strong, nullable) id linkRouter;

// Fails outbox entries unsent for 30 days; at open, then hourly. Returns whether any changed.
- (BOOL)expireOutbox;
// Lets friend requests nobody answered for 14 days lapse; at open, then hourly. Returns whether any did.
- (BOOL)expireIncomingRequests;
// Requests we sent that can no longer be answered lapse (the store's -expireOutgoingRequestsAtDate:), on the same
// clock; YES when any did.
- (BOOL)expireOutgoingRequests;
// A fresh Friends ID for the current collision count (ADR 0006); nil without a word list.
- (nullable NSString *)drawFriendsID;
// While the identity is unavailable: reads it again, never creating one (a keychain that was still locked at start
// opens later). YES when there is an identity now. The helper then starts Nearby and the check-in for it.
- (BOOL)retryIdentity;
// Reset Friends: a new identity and ID; friends, history and pictures deleted; received files kept.
- (BOOL)resetFriendsWithError:(NSError **)error;
// The first step of the reset on its own: the stored identity is removed and nothing else is touched. The reset
// router does this before the host forgets the old identity, so a keychain that refuses costs the person nothing.
- (BOOL)removeIdentityForResetWithError:(NSError **)error;

// Random bytes from libsodium (Add by ID request tokens).
+ (NSData *)randomBytes:(NSUInteger)count;
@end

NS_ASSUME_NONNULL_END
