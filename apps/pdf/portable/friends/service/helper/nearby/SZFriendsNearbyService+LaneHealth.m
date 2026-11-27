// Lanes that degrade (ADR 0018 § 7.2), the nearby service's side: each LAN lane's own TCP counters (Network.framework's
// data-transfer report: bytes sent and retransmitted) go to the group's scheduler once a block tick, which opens a
// second connection on a lossy LAN that moves under 70 % of its peak; a lane asked for beside a degraded one avoids
// that one's interface (Ethernet beside Wi-Fi); and the scheduler's verdicts on the lanes it tried go to helper.log.

#import <objc/runtime.h>

#import "service/discovery/SZFriendsDiscoveryInternal.h"
#import "service/helper/nearby/SZFriendsNearbyInternal.h"
#import "service/helper/nearby/SZFriendsNearbyLaneHealth.h"

static const void *SZFLaneHealthCountersKey = &SZFLaneHealthCountersKey;   // @[ sent, retransmitted ] not yet shared
static const void *SZFLaneHealthInterfaceKey = &SZFLaneHealthInterfaceKey; // its nw_interface_t
static const uint64_t SZFLaneHealthMinSent = 256 << 10; // a share only over at least this much sent

@implementation SZFriendsNearbyService (LaneHealth)

- (SZFriendsLaneID)laneIDOfMember:(SZFriendsPeerLink *)link {
    return link.lane ? link.laneSerial : SZFriendsHeadLane;
}

- (void)laneHealthTickOnLink:(SZFriendsPeerLink *)head {
    SZFriendsBlockExchange *blocks = head.blocks;
    if (blocks == nil || head.lane) return;
    for (SZFriendsLaneVerdict *v in [blocks takeVerdicts]) {
        SZFriendsHelperLog(@"lane %llu on %@ of %@ %@: the group moved %@ before it, %@ with it",
                           (unsigned long long)v.lane, SZFriendsTraceRouteName(v.route), [self traceWhoOfLink:head],
                           v.kept ? @"helps, kept" : @"did not help, closed", SZFriendsTraceRate(v.before),
                           SZFriendsTraceRate(v.with));
    }
    if (blocks.sending.count == 0) return;
    NSMutableArray<SZFriendsPeerLink *> *members = [NSMutableArray arrayWithObject:head];
    [members addObjectsFromArray:head.lanes.allObjects];
    __weak SZFriendsNearbyService *weakSelf = self;
    for (SZFriendsPeerLink *link in members) {
        if (link.closed || !link.live || link.raceRoute != SZFriendsRouteMethodLAN) continue;
        __weak SZFriendsPeerLink *weakLink = link, *weakHead = head;
        [link.channel collectTransportHealth:^(uint64_t sent, uint64_t again, id interface) {
            dispatch_async(weakSelf.queue ?: dispatch_get_main_queue(), ^{
                SZFriendsPeerLink *member = weakLink, *group = weakHead;
                if (member == nil || group == nil) return;
                if (interface) objc_setAssociatedObject(member, SZFLaneHealthInterfaceKey, interface, OBJC_ASSOCIATION_RETAIN);
                // Each reading counts since the last one; readings add up until enough was sent for a share.
                NSArray<NSNumber *> *last = objc_getAssociatedObject(member, SZFLaneHealthCountersKey);
                uint64_t total = last[0].unsignedLongLongValue + sent;
                uint64_t retransmitted = last[1].unsignedLongLongValue + again;
                if (total < SZFLaneHealthMinSent) {
                    objc_setAssociatedObject(member, SZFLaneHealthCountersKey, @[ @(total), @(retransmitted) ],
                                             OBJC_ASSOCIATION_RETAIN);
                    return;
                }
                objc_setAssociatedObject(member, SZFLaneHealthCountersKey, nil, OBJC_ASSOCIATION_RETAIN);
                double share = (double)retransmitted / (double)total;
                [group.blocks lane:[weakSelf laneIDOfMember:member] retransmitted:share];
            });
        }];
    }
}

- (BOOL)openLaneOfLink:(SZFriendsPeerLink *)head route:(SZFriendsRouteMethod)route beside:(SZFriendsLaneID)lane {
    SZFriendsPeerLink *degraded = nil;
    for (SZFriendsPeerLink *member in [@[ head ] arrayByAddingObjectsFromArray:head.lanes.allObjects]) {
        if ([self laneIDOfMember:member] == lane) degraded = member;
    }
    id interface = degraded ? objc_getAssociatedObject(degraded, SZFLaneHealthInterfaceKey) : nil;
    NSString *endpointID = interface != nil ? degraded.endpointID : nil;
    for (id<SZFriendsDiscoveryAdapter> adapter in endpointID ? self.adapters : @[]) {
        SZFriendsNetworkAdapterAvoidInterface(adapter, endpointID, interface);
    }
    BOOL dialed = [self openLaneOfLink:head route:route];
    // The adapter takes the interface on the dial that follows at once; with none, it must not wait for a later one.
    for (id<SZFriendsDiscoveryAdapter> adapter in endpointID && !dialed ? self.adapters : @[]) {
        SZFriendsNetworkAdapterAvoidInterface(adapter, endpointID, nil);
    }
    if (endpointID && dialed) {
        SZFriendsHelperLog(@"lane %llu of %@ degraded: one more LAN lane, avoiding its interface",
                           (unsigned long long)lane, [self traceWhoOfLink:head]);
    }
    return dialed;
}

@end
