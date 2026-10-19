// Reset Friends: a new identity and ID, from a helper whose identity is fine or one that could not read it.

#import "service/helper/SZFriendsIntentRouter.h"

#import "service/helper/SZFriendsHelperInternal.h"
#import "service/helper/SZFriendsHostCheckIn.h"
#import "service/helper/nearby/SZFriendsNearbyService.h"

@implementation SZFriendsIntentRouter (Reset)

- (void)intent_reset_friends:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                       reply:(SZFriendsIntentReply)reply {
    if (![intent[@"confirm"] isEqual:@"reset"]) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"confirm"} connection:connection];
        return;
    }
    SZFriendsHelperCheckIn *checkIn = self.services.checkIn;
    // Off the air while the host releases the old identity and the reset runs, and until it has succeeded.
    [self.services.nearby suspendForReset];
    // The stored identity goes first, before the host forgets it and before anything of the person's is deleted: if
    // the keychain refuses (locked, say), nothing has changed and the person can try again.
    NSError *removeError = nil;
    if (![self.services removeIdentityForResetWithError:&removeError]) {
        SZFriendsHelperLog(@"reset stopped, the identity could not be removed: %@",
                           removeError.localizedDescription ?: @"no detail");
        // Nothing changed, so Nearby carries on as the same person.
        [self.services.nearby identityDidReset];
        [self fail:reply code:@"internal" details:@{@"reason" : @"identity_not_removed"} connection:connection];
        return;
    }
    __weak SZFriendsIntentRouter *weakSelf = self;
    void (^reset)(void) = ^{
        SZFriendsIntentRouter *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        BOOL hadNearby = strongSelf.services.nearby != nil;
        NSError *error = nil;
        if (![strongSelf.services resetFriendsWithError:&error]) {
            SZFriendsHelperLog(@"reset failed: %@", error.localizedDescription ?: @"no detail");
            [strongSelf fail:reply code:@"internal" details:nil connection:connection];
            return;
        }
        if (hadNearby) {
            // Nothing of the old identity stays on the air; the host meets the new one.
            [strongSelf.services.nearby identityDidReset];
            [strongSelf.services.checkIn start];
        } else if (strongSelf.onIdentityAvailable) {
            // The identity could not be read before, so nothing ran for it: Nearby and the check-in start now.
            strongSelf.onIdentityAvailable();
        }
        // The person reset from an open Friends, so Nearby starts in full, as opening Friends does; this is what
        // may ask for Local Network and Bluetooth access the first time.
        [strongSelf.services.nearby activate];
        reply(@{}, nil, nil, nil);
        // Every view now shows someone who no longer exists: all clients reconnect and subscribe again.
        if (strongSelf.onReset) strongSelf.onReset();
    };
    // The host forgets the old identity and frees its ID first (ADR 0005 step 6), best effort and bounded.
    if (checkIn != nil) [checkIn releaseIdentityWithCompletion:reset];
    else reset();
}

@end
