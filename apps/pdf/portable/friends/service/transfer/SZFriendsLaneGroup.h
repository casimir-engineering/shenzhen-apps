// Lanes (ADR 0018 § 6), as the Rust core's session/lanes.rs: more Noise IK sessions with the same device of the same
// friend, bound to the first by a token from its handshake hash. A group is the first session and its lanes; it
// decides, without any IO, which index a new outbound lane takes and whether an inbound one is admitted, keeps the
// per-route limits, and says which lane carries control frames. The scheduler sees lanes through its events and asks
// for them through its requests.
//
// The rules: index 0 is the first session, lanes take 1 to 15, each once per group; this side opens at most 4 lanes per
// route and 8 per group, and the side that dialed the first session opens odd indexes, the other even ones (a local
// rule, so lanes both sides open at once never collide; any free index is admitted); at most one session of the
// group, the first included, on the relay and on Bluetooth; a lane never races; the first session's end ends the group.

#import <Foundation/Foundation.h>

#import "service/session/SZFriendsSession.h"

NS_ASSUME_NONNULL_BEGIN

typedef uint64_t SZFriendsLaneID; // the driver's name for a session (a counter)

extern const uint8_t SZFriendsLaneIndexMax;          // 15
extern const NSUInteger SZFriendsLanesPerRoute;      // 4
extern const NSUInteger SZFriendsLanesOpenedPerGroup; // 8

// Routes that carry one session of a group at most, the first included: the relay and Bluetooth.
BOOL SZFriendsOneLaneOnly(SZFriendsRouteMethod route);

typedef NS_ENUM(NSInteger, SZFriendsLaneRefusal) {
    SZFriendsLaneAdmitted = 0,
    SZFriendsLaneRefusedToken, // the token names no index of this group
    SZFriendsLaneRefusedInUse, // that index is live already
    SZFriendsLaneRefusedFull,  // the route carries one session at most and has it
};

// What the scheduler hears: a lane went live (up) or closed.
@interface SZFriendsLaneEvent : NSObject
@property(nonatomic, readonly) BOOL up;
@property(nonatomic, readonly) SZFriendsLaneID lane;
@property(nonatomic, readonly) uint8_t index;
@property(nonatomic, readonly) SZFriendsRouteMethod route;
+ (instancetype)up:(SZFriendsLaneID)lane index:(uint8_t)index route:(SZFriendsRouteMethod)route;
+ (instancetype)down:(SZFriendsLaneID)lane;
@end

@interface SZFriendsLaneGroup : NSObject
// The group of a live first session that negotiated fast transfers; `handshakeHash` is that session's h, from which
// all fifteen tokens are derived now, so admission compares in constant time.
- (instancetype)initWithFirst:(SZFriendsLaneID)first
                 handshakeHash:(NSData *)handshakeHash
                     initiator:(BOOL)initiator
                         route:(SZFriendsRouteMethod)route NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) SZFriendsLaneID first;
- (BOOL)contains:(SZFriendsLaneID)lane;
// Outbound: the index (and its token) for one more lane on `route`, reserved until -laneUp: or -laneDown:; 0 past
// the limits.
- (uint8_t)reserve:(SZFriendsLaneID)lane route:(SZFriendsRouteMethod)route token:(NSData *_Nullable *_Nullable)token;
// Inbound: the index the token names, now reserved for `lane`; a refusal otherwise.
- (SZFriendsLaneRefusal)admit:(SZFriendsLaneID)lane
                        token:(NSData *)token
                        route:(SZFriendsRouteMethod)route
                        index:(uint8_t *)index;
- (BOOL)hasRoute:(SZFriendsRouteMethod)route; // a lane on it, live or being opened
- (SZFriendsRouteMethod)routeOf:(SZFriendsLaneID)lane;
- (uint8_t)indexOf:(SZFriendsLaneID)lane; // 0 for the first session or a lane it does not hold
- (NSArray<NSNumber *> *)lanesOnly;       // every lane id but the first, live or not
- (void)laneUp:(SZFriendsLaneID)lane;
// YES when that ends the group (it was the first session).
- (BOOL)laneDown:(SZFriendsLaneID)lane;
- (NSArray<SZFriendsLaneEvent *> *)takeEvents;
@end

NS_ASSUME_NONNULL_END
