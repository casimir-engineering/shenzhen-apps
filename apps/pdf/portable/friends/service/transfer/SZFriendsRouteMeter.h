// What each route carried for each transfer (PROTOCOL.md § Fast transfers, Progress by route), as the Rust core's
// transfer/meter.rs, rule for rule: the helper counts the file bytes of every PART and CHUNK a session sends or
// receives, by the transfer they belong to and the session's route, and the views draw the transfer's bar split by
// those counts, its routes in use right now, a speed that does not jitter and a time left that counts down instead of
// jumping. Cheap: one entry per transfer moving, a few adds per frame, the speed and time left worked out only when a
// snapshot asks.

#import <Foundation/Foundation.h>

#import "service/discovery/SZFriendsDiscovery.h"

NS_ASSUME_NONNULL_BEGIN

// One transfer's counts as a snapshot shows them.
@interface SZFriendsRouteReading : NSObject
// Bytes each route carried (SZFriendsRouteMethod -> bytes), and the routes carrying it right now in the routes' fixed
// order (same Wi-Fi, direct Wi-Fi, Internet, Bluetooth, relay).
@property(nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *routeBytes;
@property(nonatomic, copy) NSArray<NSNumber *> *activeRoutes;
@property(nonatomic) double bytesPerSecond; // smoothed; 0 until a second of bytes was counted
@property(nonatomic) double secondsLeft;    // counting down steadily; 0 when unknown
@end

@interface SZFriendsRouteMeter : NSObject
// `bytes` of `transferID`'s file went or came on a session over `route`, at `now` (monotonic seconds).
- (void)carried:(uint64_t)bytes route:(SZFriendsRouteMethod)route transfer:(NSString *)transferID now:(double)now;
// The counts of `transferID` with `remaining` bytes still to go; nil when nothing was counted for it.
- (nullable SZFriendsRouteReading *)readingFor:(NSString *)transferID remaining:(uint64_t)remaining now:(double)now;
- (void)forget:(NSString *)transferID;
@end

NS_ASSUME_NONNULL_END
