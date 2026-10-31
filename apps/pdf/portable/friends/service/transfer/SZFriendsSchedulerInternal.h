// Shared by SZFriendsScheduler.m (actions, inputs, queries) and SZFriendsScheduler+Decisions.m (the decisions and
// what a silent lane gives back): the scheduler's state, its lanes, transfers and placements, and its constants.

#import "service/transfer/SZFriendsScheduler.h"

NS_ASSUME_NONNULL_BEGIN

// How far back rate and round-trip samples count.
static const double SZFSampleWindow = 10;
// A silent lane: no block completed and no write finished for this long, or 3 round trips if longer.
static const double SZFSilentAfter = 1, SZFSilentAfterBluetooth = 2;
// A lane holding blocks that hears nothing from the peer this long is silent (the peer pings every second).
static const double SZFUnheardAfter = 2.5, SZFUnheardAfterBluetooth = 3.5;
// A lane slower than this many seconds per block holds one block at a time.
static const double SZFSlowBlockSeconds = 1.0;
// A silent lane is closed after this long without a byte from the peer.
static const double SZFCloseSilentAfter = 10;
// In flight per lane at most.
static const uint64_t SZFLaneBytesMax = 32ull << 20, SZFLaneBytesMaxPhone = 8ull << 20;
// The same lane request is not repeated sooner than this...
static const double SZFRequestAgainAfter = 10;
// ... except while the relay is the only lane working: a direct route is asked for this often (ADR 0020).
static const double SZFRequestWhileRelayed = 1;
// A lane is worth asking for only when the work left would take the current lanes longer than this.
static const double SZFWorthALane = 4.0;
// A lane slower than the fastest takes blocks only while it measures at least this share of the fastest: below it,
// what it adds is less than what it costs (its encryption and HAVEs, a block the fastest may end up sending again).
static const double SZFHelpsFromShare = 0.03;
// A lane slower than the fastest holds at most what the fastest sends in this long (one block at least).
static const double SZFSlowerLaneSeconds = 1.0;

// What a route typically does, until a lane on it has measured itself.
static inline void SZFTypical(SZFriendsRouteMethod route, double *rate, double *rtt) {
    switch (route) {
    case SZFriendsRouteMethodLAN: *rate = 40e6, *rtt = 0.005; return;
    case SZFriendsRouteMethodPeerToPeerWiFi: *rate = 20e6, *rtt = 0.005; return;
    case SZFriendsRouteMethodInternet: *rate = 4e6, *rtt = 0.050; return;
    case SZFriendsRouteMethodRelay: *rate = 0.5e6, *rtt = 0.100; return;
    case SZFriendsRouteMethodBluetooth: *rate = 0.15e6, *rtt = 0.040; return;
    default: *rate = 1e6, *rtt = 0.100; return;
    }
}

@interface SZFPlacement : NSObject {
  @public
    SZFriendsLaneID lane;
    uint64_t seq;
    uint64_t bytes;
    BOOL hasSent;
    double sentAt;
    uint64_t delivered; // the lane's delivered bytes and its last delivery's time when assigned (BBR's sample)
    double deliveredAt;
}
@end

@interface SZFTransfer : NSObject {
  @public
    SZFriendsTransferKey key;
    SZFriendsBlockGeometry geometry;
    NSMutableData *wanted; // one byte per block
    uint32_t wantedCount;
    NSMutableIndexSet *unassigned; // wanted, with no live placement
    // Open blocks (assigned since last wanted, not complete) and their placements; one whose lane went away stays
    // open with none, as the receiver may hold parts of it (§ 3 counts it).
    NSMutableDictionary<NSNumber *, NSMutableArray<SZFPlacement *> *> *open;
    uint64_t openBytes;
}
- (uint64_t)bytes:(uint32_t)block;
- (BOOL)isWanted:(uint32_t)block;
- (void)setWanted:(uint32_t)block to:(BOOL)value;
@end

@interface SZFLane : NSObject {
  @public
    uint8_t index;
    SZFriendsRouteMethod route;
    NSMutableArray<NSArray<NSNumber *> *> *rates, *rtts; // (time, value)
    double rate, rtt;
    BOOL measured;
    uint64_t inFlight, delivered;
    double deliveredAt, progressAt, heardAt;
    BOOL silent, closing, unused;
    // Its unheardAfter passed and the scheduler looked (so the timer for it is not asked again until it is heard).
    BOOL unheardNoted;
    // Placements in the order they were assigned: seq -> (transfer, block).
    NSMutableDictionary<NSNumber *, NSArray<NSNumber *> *> *holds;
}
- (double)eta:(uint64_t)bytes;
- (double)silentAfter;
- (BOOL)working;
- (double)unheardAfter;
- (BOOL)reaches:(double)now;
- (void)sampleRate:(double)value now:(double)now;
- (void)sampleRTT:(double)value now:(double)now;
- (NSArray<NSNumber *> *)holdSeqs;
@end

@interface SZFriendsScheduler () {
    BOOL _phone, _keepsInternet;
    NSMutableDictionary<NSNumber *, SZFLane *> *_lanes;
    NSMutableArray<SZFTransfer *> *_transfers; // in the order they were added: earlier transfers' blocks go first
    NSMutableArray<SZFriendsScheduleAction *> *_actions;
    NSMutableDictionary<NSNumber *, NSNumber *> *_requested;
    uint64_t _seq;
}
- (void)act:(SZFriendsScheduleKind)kind lane:(SZFriendsLaneID)lane transfer:(SZFriendsTransferKey)key
      block:(uint32_t)block;
- (nullable SZFTransfer *)transfer:(SZFriendsTransferKey)key;
@property(nonatomic, readonly) NSArray<NSNumber *> *laneIDs;
@end

@interface SZFriendsScheduleAction ()
+ (instancetype)kind:(SZFriendsScheduleKind)kind
                lane:(SZFriendsLaneID)lane
            transfer:(SZFriendsTransferKey)transfer
               block:(uint32_t)block
               route:(SZFriendsRouteMethod)route;
@end

// SZFriendsScheduler+Decisions.m.
@interface SZFriendsScheduler (Decisions)
- (uint64_t)cap:(SZFLane *)lane blockBytes:(uint64_t)blockBytes;
- (BOOL)room:(SZFLane *)lane bytes:(uint64_t)bytes blockBytes:(uint64_t)blockBytes;
- (uint64_t)unassignedBytes;
- (NSArray<NSNumber *> *)eligible:(double)now;
- (double)finishTime:(NSArray<NSNumber *> *)lanes bytes:(uint64_t)bytes;
- (nullable NSNumber *)pick:(NSArray<NSNumber *> *)eligible bytes:(uint64_t)bytes blockBytes:(uint64_t)blockBytes
                 unassigned:(uint64_t)unassigned;
- (nullable SZFTransfer *)nextBlock:(uint32_t *)blockOut;
- (void)fill:(double)now;
- (void)assign:(SZFTransfer *)transfer block:(uint32_t)block lane:(SZFriendsLaneID)laneID now:(double)now;
- (double)expected:(SZFPlacement *)p now:(double)now;
- (void)endgame:(NSArray<NSNumber *> *)eligible now:(double)now;
- (void)request:(SZFriendsRouteMethod)route now:(double)now;
- (void)askForLanes:(NSArray<NSNumber *> *)eligible now:(double)now;
- (void)releaseIfUnplaced:(SZFTransfer *)transfer block:(uint32_t)block;
- (void)relayStepsAside:(double)now;
- (BOOL)directReaches:(double)now;
- (BOOL)relayed:(double)now;
- (void)goSilent:(SZFriendsLaneID)laneID;
- (void)recover:(SZFriendsLaneID)laneID;
@end

NS_ASSUME_NONNULL_END
