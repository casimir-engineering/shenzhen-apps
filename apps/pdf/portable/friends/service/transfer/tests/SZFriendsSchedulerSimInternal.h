// Shared by SZFriendsSchedulerSim.m and SZFriendsSchedulerSim+Events.m: the simulator's events, lanes and state.

#import "SZFriendsSchedulerSim.h"

NS_ASSUME_NONNULL_BEGIN

static const uint64_t SZFGranule = 4096;
static const SZFriendsTransferKey SZFKey = 1;

typedef NS_ENUM(int, SZFEv) { SZFEvUp, SZFEvCut, SZFEvNotice, SZFEvTxDone, SZFEvArrive, SZFEvBack, SZFEvPing,
                               SZFEvHeard, SZFEvTimer };

typedef struct {
    double t;
    uint64_t seq;
    SZFEv kind;
    int lane;
    uint32_t epoch, block;
    uint64_t from, to;
    BOOL want;
} SZFEvent;

typedef struct {
    uint32_t block;
    uint64_t from, to;
    BOOL last;
} SZFPart;

static inline SZFEvent SZFMake(SZFEv kind, int lane) {
    SZFEvent event = {0};
    event.kind = kind;
    event.lane = lane;
    return event;
}

typedef NS_ENUM(int, SZFLaneState) { SZFIdle, SZFDialing, SZFUp, SZFGone };

@interface SZFSimLane : NSObject {
  @public
    SZFSimLaneProfile *profile;
    SZFriendsLaneID lane;
    SZFLaneState state;
    uint32_t epoch;
    NSMutableData *queue; // SZFPart
    NSUInteger head;
    BOOL busy;
    SZFPart current;
    // With a socket buffer: parts written, not yet across (the one crossing included), and their bytes.
    NSMutableData *buffered; // SZFPart
    NSUInteger bufferedHead;
    uint64_t bufferedBytes;
}
- (NSUInteger)queued;
@end

@interface SZFSimLaneProfile ()
- (double)advance:(double)t by:(double)d;
@end

@interface SZFSim : NSObject
@end

@interface SZFSim () {
  @public
    SZFriendsBlockGeometry _geometry;
    double _now;
    uint64_t _seq;
    SZFEvent *_heap;
    NSUInteger _count, _capacity;
    BOOL _timerArmed;
    double _timerAt;
    NSMutableArray<SZFSimLane *> *_lanes;
    SZFriendsLaneGroup *_group;
    SZFriendsScheduler *_scheduler;
    NSMutableArray<NSMutableData *> *_covered;
    NSMutableData *_complete;
    NSMutableSet<NSNumber *> *_answered;
    uint64_t _random;
    SZFSimOutcome *_out;
}
- (void)at:(double)t event:(SZFEvent)event;
- (BOOL)pop:(SZFEvent *)out;
- (double)nextRandom;
- (void)start;
- (void)feedGroup;
- (void)armTimer;
- (void)checkLimits;
- (int)laneOf:(SZFriendsLaneID)lane;
- (void)act;
- (void)actOn:(NSArray<SZFriendsScheduleAction *> *)actions;
- (void)transmit:(int)i;
- (void)transmitBuffered:(int)i;
- (void)cut:(int)i;
- (void)notice:(int)i;
- (void)sendBack:(int)i block:(uint32_t)block want:(BOOL)want;
@end

@interface SZFSim (Events)
- (void)handle:(SZFEvent)ev;
@end

NS_ASSUME_NONNULL_END
