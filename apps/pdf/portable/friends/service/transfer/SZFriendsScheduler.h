// The multi-route scheduler (ADR 0018 § 7), sans I/O, ported from the Rust core's transfer/scheduler.rs (WP2): which
// lane of a group carries which block of which transfer. The rules and their reasons are that file's and the
// fast-transfers journal's; frames never depend on them, only tuning could differ, and both ports meet
// friends/fixtures/scheduler/scenarios.json through their simulators.
//
// In: lanes coming and going (the group's events), WANT and HAVE, a write completed on a lane, a block's last part
// written, a byte heard, the encrypting thread busy, and timer ticks. Out: actions: send this block on that lane,
// drop what is left of a block another lane completed, open a lane on a route, close a lane. Time is whatever
// monotonic clock the driver passes, in seconds.

#import <Foundation/Foundation.h>

#import "service/transfer/SZFriendsLaneGroup.h"
#import "service/transfer/SZFriendsTransferBlocks.h"

NS_ASSUME_NONNULL_BEGIN

typedef uint64_t SZFriendsTransferKey; // the driver's name for one transfer within the group

typedef NS_ENUM(NSInteger, SZFriendsScheduleKind) {
    SZFriendsScheduleSend,      // read `block` of `transfer`, check it against its leaf, send it as PARTs on `lane`
    SZFriendsScheduleCancel,    // another copy of `block` completed: drop its parts not yet written on `lane`
    SZFriendsScheduleOpenLane,  // one more lane on `route` (the group keeps its limits)
    SZFriendsScheduleCloseLane, // close `lane`
};

@interface SZFriendsScheduleAction : NSObject
@property(nonatomic, readonly) SZFriendsScheduleKind kind;
@property(nonatomic, readonly) SZFriendsLaneID lane;
@property(nonatomic, readonly) SZFriendsTransferKey transfer;
@property(nonatomic, readonly) uint32_t block;
@property(nonatomic, readonly) SZFriendsRouteMethod route;
@end

extern const double SZFriendsBluetoothHelpsBelow;  // 4 MB/s
extern const double SZFriendsDirectWiFiHelpsBelow; // 25 MB/s

@interface SZFriendsScheduler : NSObject
// `phone`: at most 8 MiB in flight per lane. `directWiFiKeepsInternet`: direct Wi-Fi leaves this device on its Wi-Fi
// network (AWDL on Macs); without it, direct Wi-Fi is never asked for and a direct Wi-Fi lane is closed unused.
- (instancetype)initWithPhone:(BOOL)phone directWiFiKeepsInternet:(BOOL)keepsInternet NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (NSArray<SZFriendsScheduleAction *> *)takeActions;

- (void)laneEvent:(SZFriendsLaneEvent *)event now:(double)now;
- (void)addTransfer:(SZFriendsTransferKey)key geometry:(SZFriendsBlockGeometry)geometry;
- (void)removeTransfer:(SZFriendsTransferKey)key;
- (BOOL)hasTransfer:(SZFriendsTransferKey)key;
// Ranges are packed (first, count) pairs as SZFriendsTransferBlocks.h has them; NO for an unknown transfer or ranges
// past the file.
- (BOOL)want:(SZFriendsTransferKey)key ranges:(NSData *)ranges now:(double)now;
- (BOOL)have:(SZFriendsTransferKey)key ranges:(NSData *)ranges now:(double)now;
- (void)written:(SZFriendsLaneID)lane now:(double)now;
- (void)sent:(SZFriendsLaneID)lane transfer:(SZFriendsTransferKey)key block:(uint32_t)block now:(double)now;
- (void)heard:(SZFriendsLaneID)lane now:(double)now;
- (void)cpuBound:(SZFriendsLaneID)lane now:(double)now;
- (void)tick:(double)now;
// When -tick: has something to do next; a negative value for nothing.
- (double)nextTimer;

- (BOOL)isDone:(SZFriendsTransferKey)key;
- (NSUInteger)openBlocks:(SZFriendsTransferKey)key bytes:(uint64_t *_Nullable)bytes;
- (uint64_t)inFlightOfLane:(SZFriendsLaneID)lane;
- (uint64_t)capOfLane:(SZFriendsLaneID)lane blockBytes:(uint64_t)blockBytes;
- (BOOL)hasLane:(SZFriendsLaneID)lane;
@end

NS_ASSUME_NONNULL_END
