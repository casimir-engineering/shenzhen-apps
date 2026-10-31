// The owner's relay rule on the nearby side (ADR 0020; the Rust helper's service/nearby/relayed.rs): the relay is the
// last resort, so while it carries a friend's session every direct route keeps being tried, each at most
// SZFriendsRelayProbeInterval apart. Once a second: the person's dial backoffs end (an endpoint that failed while they
// were away is dialed again on the next pass, and a better route found that way wins the session race), Bluetooth
// scans afresh (a device coming back into range is reported only by a new scan), and every candidate is looked at
// again. The LAN needs no help: the network's browse reports a device that joins at once.

#import "SZFriendsNearbyInternal.h"

NS_ASSUME_NONNULL_BEGIN

const NSTimeInterval SZFriendsRelayProbeInterval = 1;

@implementation SZFriendsNearbyService (Relayed)

- (NSArray<NSString *> *)relayedConversations {
    NSMutableSet<NSString *> *relayed = [NSMutableSet set];
    for (SZFriendsPeerLink *link in self.links) {
        if (!link.adopted || link.superseded || link.closed || link.lane || link.conversationID == nil) continue;
        if (link.raceRoute == SZFriendsRouteMethodRelay) [relayed addObject:link.conversationID];
    }
    return [relayed.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

- (void)relayProbeIfRelayed {
    if (self.relayProbeScheduled || self.shutDown || self.relayedConversations.count == 0) return;
    [self relayProbe];
}

// Once a second while the relay carries a session: try every direct route again.
- (void)relayProbe {
    NSArray<NSString *> *relayed = self.relayedConversations;
    if (self.shutDown || relayed.count == 0) return;
    for (NSString *conversationID in relayed) {
        [self.retryAfter removeObjectForKey:conversationID];
        [self.coordinator.racer endBackoffsForConversation:conversationID];
    }
    for (id<SZFriendsDiscoveryAdapter> adapter in self.adapters) {
        BOOL bluetooth = adapter.method == SZFriendsDiscoveryMethodBluetooth;
        if (bluetooth && [adapter respondsToSelector:@selector(refreshDiscovery)]) [adapter refreshDiscovery];
    }
    [self scheduleReconsider];
    self.relayProbeScheduled = YES;
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsRelayProbeInterval * NSEC_PER_SEC)), self.queue,
                   ^{
                       SZFriendsNearbyService *strongSelf = weakSelf;
                       if (strongSelf == nil) return;
                       strongSelf.relayProbeScheduled = NO;
                       [strongSelf relayProbe];
                   });
}

@end

NS_ASSUME_NONNULL_END
