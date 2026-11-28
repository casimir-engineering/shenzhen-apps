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
    // one more lane on `route` through another interface than `lane`'s, which degraded (Ethernet beside Wi-Fi)
    SZFriendsScheduleOpenLaneBeside,
};

@interface SZFriendsScheduleAction : NSObject
@property(nonatomic, readonly) SZFriendsScheduleKind kind;
@property(nonatomic, readonly) SZFriendsLaneID lane;
@property(nonatomic, readonly) SZFriendsTransferKey transfer;
@property(nonatomic, readonly) uint32_t block;
@property(nonatomic, readonly) SZFriendsRouteMethod route;
@end

extern const double SZFriendsBluetoothHelpsBelow;  // 4 MB/s

// How a lane the scheduler tried did: the group's acknowledged bytes per second before it and with it.
@interface SZFriendsLaneVerdict : NSObject
@property(nonatomic) SZFriendsLaneID lane;
@property(nonatomic) SZFriendsRouteMethod route;
@property(nonatomic) double before, with;
@property(nonatomic) BOOL kept;
@end

@interface SZFriendsScheduler : NSObject
// `phone`: at most 8 MiB in flight per lane. `directWiFi`: the owner's rule allows direct Wi-Fi for this group (ADR
// 0022: neither device on a Wi-Fi network, or a phone on mobile data, both said so); then a direct Wi-Fi lane is asked
// for where the group has no LAN lane. Without it (and without a boost, -allowDirectWiFi:), direct Wi-Fi is never
// asked for and a direct Wi-Fi lane is closed unused. As the Rust core's scheduler.rs.
- (instancetype)initWithPhone:(BOOL)phone directWiFi:(BOOL)directWiFi NS_DESIGNATED_INITIALIZER;
// The rule's answer for this group changed: while it says no, direct Wi-Fi lanes other than a boost's close at once.
- (void)setDirectWiFi:(BOOL)directWiFi;
// ADR 0019's boost: while allowed, its direct Wi-Fi lane is kept where the rule's answer would close it.
- (void)allowDirectWiFi:(BOOL)allowed;
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
// The same with the time the block left (a pull: when it was asked for), so the round trip includes the asking.
- (void)sent:(SZFriendsLaneID)lane
    transfer:(SZFriendsTransferKey)key
       block:(uint32_t)block
          at:(double)sentAt
         now:(double)now;
- (void)heard:(SZFriendsLaneID)lane now:(double)now;
- (void)cpuBound:(SZFriendsLaneID)lane now:(double)now;
- (void)tick:(double)now;
// When -tick: has something to do next; a negative value for nothing.
- (double)nextTimer;

- (BOOL)isDone:(SZFriendsTransferKey)key;
- (NSUInteger)openBlocks:(SZFriendsTransferKey)key bytes:(uint64_t *_Nullable)bytes;
- (uint64_t)inFlightOfLane:(SZFriendsLaneID)lane;
// What the working lanes on `route` measure together, in bytes per second (0 before any measured): how the Wi-Fi
// Direct boost knows whether its lane beats Bluetooth (ADR 0019 § 5).
- (double)rateOfRoute:(SZFriendsRouteMethod)route;
- (uint64_t)capOfLane:(SZFriendsLaneID)lane blockBytes:(uint64_t)blockBytes;
- (BOOL)hasLane:(SZFriendsLaneID)lane;
// For the helper's log: what the scheduler believes of a lane (rate and round trip measured or assumed, whether it was
// measured, bytes in flight, silent, still reaching the peer). NO for a lane it does not know.
- (BOOL)describeLane:(SZFriendsLaneID)lane
                rate:(double *)rate
                 rtt:(double *)rtt
            measured:(BOOL *)measured
            inFlight:(uint64_t *)inFlight
              silent:(BOOL *)silent
             reaches:(BOOL *)reaches
                 now:(double)now;
@end

// ADR 0018 § 7.2 (SZFriendsScheduler+Health.m): the share of `lane`'s bytes its connection retransmitted lately, as
// the socket says; a lane asked for on `route` that the helper could not open (a trial waiting for it ends); the
// trials judged since the last call; the group's acknowledged rate over `span`.
@interface SZFriendsScheduler (Health)
- (void)retransmits:(SZFriendsLaneID)lane share:(double)share now:(double)now;
- (void)laneRefused:(SZFriendsRouteMethod)route;
- (NSArray<SZFriendsLaneVerdict *> *)takeVerdicts;
- (double)groupRateOver:(double)span now:(double)now;
@end

NS_ASSUME_NONNULL_END
