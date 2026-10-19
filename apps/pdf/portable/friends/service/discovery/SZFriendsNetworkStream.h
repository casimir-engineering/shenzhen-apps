// A TCP connection from Network.framework as an SZFriendsByteStream (LAN and peer-to-peer Wi-Fi). Internal to
// this directory: the adapter hands it out as id<SZFriendsByteStream>.

#import <Foundation/Foundation.h>
#import <Network/Network.h>

#import "service/discovery/SZFriendsDiscoveryInternal.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsNetworkStream : NSObject <SZFriendsByteStream>
// `connectionQueue` is the adapter's queue; the connection's own events run there. Session callbacks run on the
// queue given to -startWithQueue:.
- (instancetype)initWithConnection:(nw_connection_t)connection
                   connectionQueue:(dispatch_queue_t)connectionQueue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Starts the connection. `ready` runs once on the connection queue: nil once bytes can flow, or why not. A
// connection still waiting after `timeout` is cancelled. Call before -startWithQueue:.
- (void)connectWithTimeout:(NSTimeInterval)timeout ready:(void (^)(NSError *_Nullable error))ready;
- (void)cancel; // abandons a connection attempt; ready gets Cancelled
// The route the connected path took, from its interface (valid once ready).
@property(nonatomic, readonly) SZFriendsRouteMethod pathRoute;
@end

BOOL SZFriendsNetworkErrorIsPolicyDenied(nw_error_t _Nullable error);
NSError *SZFriendsErrorFromNetworkError(nw_error_t _Nullable error);

NS_ASSUME_NONNULL_END
