// A virtual-time simulator for the Objective-C scheduler, as the Rust core's transfer/sim.rs (its byte-counting
// mode): one file sent over emulated lanes, each with a rate, a round trip, part loss, silences (nothing moves either
// way) and a cut (closed, noticed a little later). Lanes come and go through SZFriendsLaneGroup, so its limits apply.
// The receiver counts 4 KiB granules, answers each completed block with a HAVE on the lane that completed it (or the
// quickest live lane if that one is gone), answers the first late part of a block on each lane with a HAVE, and pings
// each lane every second. With a lane's socket buffer, a write completes once its part is in the buffer. Scenarios
// come from friends/fixtures/scheduler/scenarios.json.

#import <Foundation/Foundation.h>

#import "service/transfer/SZFriendsScheduler.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFSimLaneProfile : NSObject
@property(nonatomic) SZFriendsRouteMethod route;
@property(nonatomic) double rate; // bytes per second, each way
@property(nonatomic) double rtt;
@property(nonatomic) double loss;
@property(nonatomic) uint64_t partBytes;
@property(nonatomic) double upAt; // negative: only when the scheduler asks for its route, `dial` after
@property(nonatomic) double dial;
@property(nonatomic) double cutAt; // negative: never
@property(nonatomic) double detect;
@property(nonatomic, strong) NSMutableArray<NSArray<NSNumber *> *> *silences; // (from, to), sorted
// The sender's socket buffer: a write completes once its part is in it, before the part crosses (0: as it crosses).
@property(nonatomic) uint64_t buffer;
+ (nullable instancetype)profileWithJSON:(NSDictionary *)json;
- (instancetype)copyUpFromStart; // the same lane, up at 0
@end

@interface SZFSimScenario : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) uint64_t size;
@property(nonatomic) BOOL phone, directWiFiKeepsInternet;
@property(nonatomic, strong) NSArray<SZFSimLaneProfile *> *lanes;
@property(nonatomic) uint64_t seed;
@property(nonatomic) double limit;
@property(nonatomic) uint8_t unitShift; // the scheduler's unit: 0 for the file's blocks, 18 for 256 KiB slices
+ (nullable instancetype)scenarioWithJSON:(NSDictionary *)json;
- (instancetype)copyWithLanes:(NSArray<SZFSimLaneProfile *> *)lanes;
@end

@interface SZFSimOutcome : NSObject
@property(nonatomic) double doneAt; // negative: did not finish
@property(nonatomic) uint64_t wastedBytes;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *laneSentBytes;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *laneLastWrite;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *laneUp;
@property(nonatomic) NSUInteger maxOpenBlocks;
@property(nonatomic) uint64_t maxOpenBytes;
@property(nonatomic) BOOL laneCapExceeded;
@property(nonatomic, strong) NSMutableArray<NSString *> *requests; // "open bluetooth", "close"
// How long the fastest lane still up at the end sat idle before completion.
- (double)tailFor:(SZFSimScenario *)scenario;
@end

SZFSimOutcome *SZFSimRun(SZFSimScenario *scenario);
NSString *SZFSimRouteName(SZFriendsRouteMethod route);

NS_ASSUME_NONNULL_END
