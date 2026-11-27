// Lanes that degrade (ADR 0018 § 7.2), the nearby service's side (SZFriendsNearbyService+LaneHealth.m).

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsNearbyService (LaneHealth)
// Once a block tick: each LAN lane's retransmitted share to the scheduler, its verdicts to helper.log.
- (void)laneHealthTickOnLink:(SZFriendsPeerLink *)head;
// One more lane on `route` that avoids degraded `lane`'s interface where the adapter can.
- (void)openLaneOfLink:(SZFriendsPeerLink *)head route:(SZFriendsRouteMethod)route beside:(SZFriendsLaneID)lane;
@end

NS_ASSUME_NONNULL_END
