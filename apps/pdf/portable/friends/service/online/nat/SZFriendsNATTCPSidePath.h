// The TCP simultaneous-open path as the transport's side path (SZFriendsOnlineSidePath in
// transport/SZFriendsOnlineDataChannelTransport.h): what the helper's sidePathFactory returns for a direct
// connection, so the path's candidates and stream reach the connection's delegate like the data channel's.
//
// One per direct connection toward a friend or a first contact (download links have no TCP path: browsers cannot
// open one). It runs for the direct phase's plain budget (SZFriendsOnlineDirectPlainBudget, 5 s, provisional) and
// reports itself over when that runs out with no stream, when the stream it opened ends, or when it cannot start.

#import "service/online/nat/SZFriendsNATTCPPath.h"
#import "service/online/transport/SZFriendsOnlineDataChannelTransport.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsNATTCPSidePath : NSObject <SZFriendsOnlineSidePath>
// Nil for a request that has no TCP path (a download link, a relay or probe handover connection). `stunServer` is
// the host's STUN address for TCP (3478), resolved by the caller from the signed host list; nil gathers no mapped
// address. `loopbackOnly` is for tests (SZFriendsNAT.h).
+ (nullable instancetype)sidePathForRequest:(id<SZFriendsOnlineConnectionRequest>)request
                                 stunServer:(nullable SZFriendsNATEndpoint *)stunServer
                               loopbackOnly:(BOOL)loopbackOnly;
- (instancetype)init NS_UNAVAILABLE;
// Its configuration, adjustable before -startWithQueue:events: (the budget follows the direct phase's).
@property(nonatomic, readonly) SZFriendsNATTCPPathConfiguration *configuration;
@end

NS_ASSUME_NONNULL_END
