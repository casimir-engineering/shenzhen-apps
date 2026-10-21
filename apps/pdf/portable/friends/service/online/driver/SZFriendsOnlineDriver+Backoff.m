// Waiting after an attempt nobody answered, and what ends it (SZFriendsOnlineDriverPrivate.h, BackoffInternal): a wait
// that doubles from SZFriendsOnlineBackoffFirst to SZFriendsOnlineBackoffMax, a lookup of the friend's record, and an
// open from the friend, which shows they are there.

#import "service/online/driver/SZFriendsOnlineDriverPrivate.h"

#import "service/host/SZFriendsHostRendezvous.h"
#import "service/session/SZFriendsSignaling.h"

@implementation SZFriendsOnlineDriver (Backoff)

- (BOOL)backedOff:(NSData *)identityKey {
    NSNumber *until = self.backoffUntil[identityKey];
    return until != nil && until.doubleValue > self.onlineContext.clock();
}

- (void)noteFailureForFriend:(NSData *)identityKey {
    NSTimeInterval wait = self.backoffWait[identityKey] ? MIN(self.backoffWait[identityKey].doubleValue * 2,
                                                          SZFriendsOnlineBackoffMax)
                                                    : SZFriendsOnlineBackoffFirst;
    self.backoffWait[identityKey] = @(wait);
    self.backoffUntil[identityKey] = @(self.onlineContext.clock() + wait);
}

// Lookups change only once per host period, so a friend is looked up at most once in each, however often the helper
// asks.
- (void)lookUpFriend:(NSData *)identityKey {
    NSTimeInterval now = self.onlineContext.clock();
    NSNumber *last = self.lastLookup[identityKey];
    BOOL recent = last && now - last.doubleValue < SZFriendsHostRecordPeriod;
    if ([self.lookingUp containsObject:identityKey] || recent) return;
    SZFriendsOnlineFriend *friend = [self.delegate onlineDriver:self friendWithIdentityKey:identityKey];
    // A person's devices all file their records under the person's root key (HOST-PROTOCOL-ONLINE.md § Several
    // devices): another computer of ours or of a friend is looked up there, never under its own device key.
    NSData *rdvKey = SZFriendsHostRendezvousKey(friend.rootKey.length == 32 ? friend.rootKey : identityKey);
    if (friend.presenceSecret.length != 32 || rdvKey == nil) return;
    void (^lookup)(NSArray<NSData *> *, void (^)(NSArray<NSData *> *, NSError *)) = self.testLookup;
    if (lookup == nil && self.online != nil) {
        SZFriendsHostOnline *online = self.online;
        lookup = ^(NSArray<NSData *> *keys, void (^completion)(NSArray<NSData *> *, NSError *)) {
            [online lookupRendezvousKeys:keys completion:completion];
        };
    }
    if (lookup == nil) return;
    self.lastLookup[identityKey] = @(now);
    [self.lookingUp addObject:identityKey];
    __weak SZFriendsOnlineDriver *weakSelf = self;
    NSData *secret = friend.presenceSecret;
    lookup(@[ rdvKey ], ^(NSArray<NSData *> *blobs, NSError *error) {
        (void)error;
        SZFriendsOnlineDriver *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        [strongSelf.lookingUp removeObject:identityKey];
        int64_t window = SZFriendsPresenceWindowIndex([NSDate date]);
        NSData *blob = blobs.count == 1 ? blobs[0] : nil;
        // Only the friend's own record opens with their secret; the host's filler for someone offline does not.
        if (blob != nil && SZFriendsOpenRendezvousRecord(blob, identityKey, secret, @[ identityKey ], window) != nil) {
            [strongSelf.backoffUntil removeObjectForKey:identityKey];
            [strongSelf reachFriend:identityKey];
        }
    });
}

- (void)offerAgain:(SZFriendsOnlineAttempt *)attempt {
    NSData *peer = attempt.peer;
    [attempt close];
    // Its end counted as a failure (nobody answered); the friend's open says otherwise.
    [self.backoffUntil removeObjectForKey:peer];
    [self.backoffWait removeObjectForKey:peer];
    [self reachFriend:peer];
}

@end
