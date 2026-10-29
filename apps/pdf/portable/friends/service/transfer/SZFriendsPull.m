// One file's blocks fetched from several sources at once (SZFriendsPull.h).

#import "service/transfer/SZFriendsPull.h"

#import "service/transfer/SZFriendsBlockFlow.h"
#import "service/transfer/SZFriendsScheduler.h"

static const SZFriendsTransferKey SZFriendsPullKey = 0;

@implementation SZFriendsPullAction
+ (instancetype)want:(BOOL)want source:(SZFriendsSourceID)source ranges:(NSData *)ranges {
    SZFriendsPullAction *action = [[self alloc] init];
    action->_want = want;
    action->_source = source;
    action->_ranges = ranges;
    return action;
}
@end

@implementation SZFriendsPull {
    SZFriendsScheduler *_scheduler;
    NSMutableDictionary<NSNumber *, NSMutableIndexSet *> *_asked; // per source: asked, not delivered nor told about
    uint8_t _nextIndex;
}

- (instancetype)initWithGeometry:(SZFriendsBlockGeometry)geometry missing:(NSData *)missing now:(double)now {
    if ((self = [super init])) {
        _geometry = geometry;
        _scheduler = [[SZFriendsScheduler alloc] initWithPhone:NO directWiFiKeepsInternet:YES];
        [_scheduler addTransfer:SZFriendsPullKey geometry:geometry];
        [_scheduler want:SZFriendsPullKey ranges:missing now:now];
        _asked = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)sourceUp:(SZFriendsSourceID)source route:(SZFriendsRouteMethod)route now:(double)now {
    if (_asked[@(source)] != nil) return;
    _asked[@(source)] = [NSMutableIndexSet indexSet];
    uint8_t index = _nextIndex;
    if (_nextIndex < UINT8_MAX) _nextIndex++;
    [_scheduler laneEvent:[SZFriendsLaneEvent up:source index:index route:route] now:now];
}

- (void)sourceDown:(SZFriendsSourceID)source now:(double)now {
    if (_asked[@(source)] == nil) return;
    [_asked removeObjectForKey:@(source)];
    [_scheduler laneEvent:[SZFriendsLaneEvent down:source] now:now];
}

- (void)heard:(SZFriendsSourceID)source now:(double)now {
    [_scheduler heard:source now:now];
}

- (void)arrived:(SZFriendsSourceID)source block:(uint32_t)block now:(double)now {
    if (block >= _geometry.blocks || [_scheduler isDone:SZFriendsPullKey]) return;
    [_asked[@(source)] removeIndex:block];
    // Credited to that source as a copy sent whole: its rate and round trip are measured this way.
    [_scheduler sent:source transfer:SZFriendsPullKey block:block now:now];
    [_scheduler have:SZFriendsPullKey ranges:SZFriendsRange(block, 1) now:now];
}

- (void)failed:(uint32_t)block now:(double)now {
    for (NSMutableIndexSet *asked in _asked.allValues) [asked removeIndex:block];
    [_scheduler want:SZFriendsPullKey ranges:SZFriendsRange(block, 1) now:now];
}

- (void)tick:(double)now {
    [_scheduler tick:now];
}

- (double)nextTimer {
    return [_scheduler nextTimer];
}

- (BOOL)done {
    return [_scheduler isDone:SZFriendsPullKey];
}

- (NSArray<SZFriendsPullAction *> *)takeActions {
    NSMutableDictionary<NSNumber *, NSMutableIndexSet *> *wants = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSMutableIndexSet *> *haves = [NSMutableDictionary dictionary];
    NSMutableIndexSet *(^entry)(NSMutableDictionary *, SZFriendsLaneID) = ^(NSMutableDictionary *map, SZFriendsLaneID lane) {
        NSMutableIndexSet *set = map[@(lane)];
        if (set == nil) map[@(lane)] = set = [NSMutableIndexSet indexSet];
        return set;
    };
    for (SZFriendsScheduleAction *action in [_scheduler takeActions]) {
        NSMutableIndexSet *asked = _asked[@(action.lane)];
        switch (action.kind) {
        case SZFriendsScheduleSend:
            if (asked == nil) break;
            [asked addIndex:action.block];
            [entry(wants, action.lane) addIndex:action.block];
            [haves[@(action.lane)] removeIndex:action.block];
            break;
        case SZFriendsScheduleCancel:
            if ([asked containsIndex:action.block]) {
                [asked removeIndex:action.block];
                [entry(haves, action.lane) addIndex:action.block];
            }
            [wants[@(action.lane)] removeIndex:action.block];
            break;
        // Sources are the sessions that hold the file; the scheduler's lane requests do not apply.
        case SZFriendsScheduleOpenLane:
        case SZFriendsScheduleCloseLane: break;
        }
    }
    NSMutableArray<SZFriendsPullAction *> *out = [NSMutableArray array];
    for (NSNumber *source in [wants.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (wants[source].count) {
            [out addObject:[SZFriendsPullAction want:YES source:source.unsignedLongLongValue
                                              ranges:SZFriendsIndexesAsRanges(wants[source])]];
        }
    }
    for (NSNumber *source in [haves.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (haves[source].count) {
            [out addObject:[SZFriendsPullAction want:NO source:source.unsignedLongLongValue
                                              ranges:SZFriendsIndexesAsRanges(haves[source])]];
        }
    }
    return out;
}

@end
