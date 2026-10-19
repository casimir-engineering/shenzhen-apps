// Add by ID online (SZFriendsOnlineDriver.h, Add by ID online; ADR 0004 through the host; lead decision 6). Our
// pending requests, from add_by_id, add_from_mention and add_from_link alike, go to whoever holds the ID now, through
// the driver's NN exchange: REQUEST_BY_ID one way, RECEIVED back, and no peer connection. The holder treats it as a
// request heard nearby (+RequestByID): it waits for the person, or is accepted at once through a live invite. Either
// way the holder then dials us with IK presenting our token, which this side admits exactly as its hidden listener
// would: only for an unexpired request of ours that admits that key, so a request from a mention or a friend link
// completes only with the key it carries, whoever holds the ID by then.

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

// A request that reached nobody (the holder offline, the host's hourly budget spent) is sent again after this,
// doubling to the maximum. Once its holder's RECEIVED arrives it goes no more that day; the next day carries that
// day's callback secret, as nearby does.
static const NSTimeInterval SZFriendsByIDOnlineRetryFirst = 30;
static const NSTimeInterval SZFriendsByIDOnlineRetryMax = 3600;

@implementation SZFriendsNearbyService (ByIDOnline)

#pragma mark - Requester

- (void)offerRequestsByIDOnline {
    SZFriendsOnlineDriver *driver = self.onlineDriver;
    SZFriendsStore *store = self.services.store;
    if (!driver.available || store == nil || self.shutDown || self.resetting) return;
    if (self.onlineIDRequests == nil) self.onlineIDRequests = [NSMutableDictionary dictionary];
    NSDate *now = [NSDate date];
    NSDate *next = nil;
    NSMutableSet<NSString *> *live = [NSMutableSet set];
    for (SZFriendsIDRequestRecord *request in [store pendingIDRequestsAtDate:now]) {
        int64_t day = SZFriendsCallbackDay(request.createdAt, now);
        NSString *key = [NSString stringWithFormat:@"%@|%lld", SZFriendsLinkHex(request.requestToken), (long long)day];
        [live addObject:key];
        id state = self.onlineIDRequests[key];
        NSArray *retry = [state isKindOfClass:NSArray.class] ? state : nil;
        if (state != nil && retry == nil) continue; // on its way, or received today
        NSDate *when = retry.firstObject;
        if (when != nil && [when compare:now] == NSOrderedDescending) {
            next = next == nil || [when compare:next] == NSOrderedAscending ? when : next;
            continue;
        }
        self.onlineIDRequests[key] = NSNull.null;
        [self sendRequestByIDOnline:request key:key lastWait:[retry.lastObject doubleValue]];
    }
    // Requests answered, withdrawn or expired, and earlier days, are forgotten.
    for (NSString *key in self.onlineIDRequests.allKeys) {
        if (![live containsObject:key]) [self.onlineIDRequests removeObjectForKey:key];
    }
    if (next != nil) [self scheduleReconsiderAfter:MAX(0.1, [next timeIntervalSinceDate:now] + 0.1)];
}

- (void)sendRequestByIDOnline:(SZFriendsIDRequestRecord *)request key:(NSString *)key lastWait:(NSTimeInterval)last {
    NSData *token = request.requestToken;
    __weak SZFriendsNearbyService *weakSelf = self;
    [self.onlineDriver sendRequestByIDToFriendsID:request.targetFriendsID
        frame:^NSData *(NSData *handshakeHash) {
            // Built only now, for this session's hash, and only while the request is still pending.
            SZFriendsFrame *frame = [weakSelf requestByIDFrameForToken:token handshakeHash:handshakeHash];
            return frame ? SZFriendsEncodeFrame(frame, NULL) : nil;
        }
        completion:^(BOOL received) {
            SZFriendsNearbyService *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.onlineIDRequests[key] != NSNull.null) return;
            if (received) {
                strongSelf.onlineIDRequests[key] = @YES;
                return;
            }
            NSTimeInterval wait = last > 0 ? MIN(last * 2, SZFriendsByIDOnlineRetryMax) : SZFriendsByIDOnlineRetryFirst;
            strongSelf.onlineIDRequests[key] = @[ [NSDate dateWithTimeIntervalSinceNow:wait], @(wait) ];
            [strongSelf scheduleReconsiderAfter:wait + 0.1];
        }];
}

#pragma mark - Holder

- (void)onlineDriver:(SZFriendsOnlineDriver *)driver
    receivedRequestByID:(SZFriendsFrame *)frame
          handshakeHash:(NSData *)handshakeHash {
    (void)driver;
    if (self.shutDown || self.resetting || self.services.store == nil) return;
    [self receivedRequestByID:frame handshakeHash:handshakeHash];
}

#pragma mark - The holder's callback, on the requester's side

// Pure, before any peer connection: the same people our hidden listener lets in with a token (+KeyPolicy), judged
// without an attestation, which travels only inside the session that follows.
- (nullable SZFriendsOnlineFriend *)onlineDriver:(SZFriendsOnlineDriver *)driver
                  friendAnsweringWithIdentityKey:(NSData *)identityKey
                                    requestToken:(NSData *)token {
    (void)driver;
    SZFriendsStore *store = self.services.store;
    NSDate *now = [NSDate date];
    if (store == nil || self.shutDown || self.resetting || token.length != 16 || identityKey.length != 32 ||
        [identityKey isEqualToData:[self localIdentityKey]]) {
        return nil;
    }
    // An Add from a mention or a friend link admits only the key it carried (ADR 0007, friends-links.md).
    if ([self requestToken:token refusesIdentityKey:identityKey atDate:now]) return nil;
    SZFriendsPersonRecord *person = [store personWithIdentityKey:identityKey];
    BOOL admitted = person != nil ? [self person:person mayOpenIKWithToken:token attested:NO now:now]
                                  : [store idRequestWithToken:token admitsIdentityKey:identityKey attested:NO
                                                       atDate:now];
    if (!admitted) return nil;
    SZFriendsOnlineFriend *friend = [[SZFriendsOnlineFriend alloc] init];
    friend.identityKey = identityKey;
    // A friend already must present the static key we hold; anyone else, the one their certificate binds.
    BOOL friendKey = person.relation == SZFriendsRelationFriend && person.staticKey.length == 32;
    if (friendKey) friend.staticKey = person.staticKey;
    friend.presenceSecret = person.presenceSecret;
    return friend;
}

@end
