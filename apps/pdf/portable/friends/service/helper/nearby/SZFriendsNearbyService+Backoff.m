// When to dial a person again (+Dial decides whom and how): failed attempts and sessions kept by another of our
// computers back off per person, the route racer hears how each handshake went, and reconsidering is scheduled for
// when a backoff ends.

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

// Failed attempts back off per person: 1 s doubling to 5 minutes, so a friend who removed us costs little.
static const NSTimeInterval SZFriendsDialBackoffFirst = 1;
static const NSTimeInterval SZFriendsDialBackoffMax = 300;
// A session that stayed up this long was healthy: its end starts the backoff afresh.
static const NSTimeInterval SZFriendsHealthySession = 30;

@implementation SZFriendsNearbyService (Backoff)

- (BOOL)mayDialConversation:(NSString *)conversationID {
    NSDate *after = self.retryAfter[conversationID];
    return after == nil || after.timeIntervalSinceNow <= 0;
}

- (void)noteFailureForConversation:(NSString *)conversationID {
    NSUInteger count = (NSUInteger)self.failures[conversationID].integerValue + 1;
    self.failures[conversationID] = @(count);
    NSTimeInterval delay = MIN(SZFriendsDialBackoffMax, SZFriendsDialBackoffFirst * pow(2, MIN(count - 1, 10u)));
    self.retryAfter[conversationID] = [NSDate dateWithTimeIntervalSinceNow:delay];
    [self scheduleReconsiderAfter:delay];
}

- (void)noteSuccessForConversation:(NSString *)conversationID {
    [self.failures removeObjectForKey:conversationID];
    [self.retryAfter removeObjectForKey:conversationID];
}

// A live session ended: one that lasted was healthy and starts the backoff afresh.
- (void)noteEndOfLink:(SZFriendsPeerLink *)link {
    if (link.conversationID == nil || link.probe) return;
    if (link.liveAt != nil && -link.liveAt.timeIntervalSinceNow >= SZFriendsHealthySession) {
        [self noteSuccessForConversation:link.conversationID];
        [self.keptElsewhere removeObjectForKey:link.conversationID];
    }
    [self noteFailureForConversation:link.conversationID];
}

// A friend holds one session per person: one with another of our computers wins the race, and this computer would
// dial again at once only to be closed again, many times a second. It waits instead, longer each time in a row (a
// session that lasted starts afresh), while the computer the friend kept delivers for all of ours (ADR 0014).
- (void)noteSessionKeptElsewhereForConversation:(NSString *)conversationID {
    NSUInteger count = (NSUInteger)self.keptElsewhere[conversationID].integerValue + 1;
    self.keptElsewhere[conversationID] = @(count);
    NSTimeInterval delay = MIN(SZFriendsDialBackoffMax, SZFriendsDialBackoffFirst * pow(2, MIN(count - 1, 10u)));
    self.retryAfter[conversationID] = [NSDate dateWithTimeIntervalSinceNow:delay];
    [self scheduleReconsiderAfter:delay];
}

- (void)noteDialToEndpoint:(nullable NSString *)endpointID
                    method:(NSInteger)method
              conversation:(nullable NSString *)conversationID
                 succeeded:(BOOL)succeeded {
    SZFriendsRouteRacer *racer = self.coordinator.racer;
    if (racer == nil || endpointID == nil || conversationID == nil) return;
    SZFriendsDiscoveryMethod discoveryMethod = (SZFriendsDiscoveryMethod)method;
    if (succeeded) {
        [racer noteHandshakeSucceededAtEndpoint:endpointID method:discoveryMethod conversationID:conversationID];
        return;
    }
    [racer noteHandshakeFailedAtEndpoint:endpointID method:discoveryMethod conversationID:conversationID];
    NSDate *end = racer.nextBackoffEnd;
    if (end != nil) [self scheduleReconsiderAfter:MAX(0, end.timeIntervalSinceNow)];
}

- (void)scheduleReconsiderAfter:(NSTimeInterval)delay {
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((delay + 0.01) * NSEC_PER_SEC)), self.queue, ^{
        [weakSelf scheduleReconsider];
    });
}

- (void)pruneAttempts {
    NSDate *now = [NSDate date];
    for (NSString *key in self.attempts.allKeys) {
        if ([self.attempts[key] compare:now] == NSOrderedAscending) [self.attempts removeObjectForKey:key];
    }
}

@end
