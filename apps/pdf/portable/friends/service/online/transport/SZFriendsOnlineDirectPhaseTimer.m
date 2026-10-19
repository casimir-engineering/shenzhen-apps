// The direct phase's clock (ADR 0011 § The direct phase): plain checks first, then hard-NAT probing only when
// exactly one side's NAT maps per destination. Values are provisional until the M0 real-network matrix.

#import "service/online/transport/SZFriendsOnlineDataChannelTransport.h"

const NSTimeInterval SZFriendsOnlineDirectPlainBudget = 5;
const NSTimeInterval SZFriendsOnlineDirectHardNATBudget = 12;

@implementation SZFriendsOnlineDirectPhaseTimer {
    dispatch_queue_t _queue;
    void (^_scheduler)(NSTimeInterval, dispatch_block_t);
    BOOL _extended; // the hard-NAT budget is running
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue
                    scheduler:(void (^)(NSTimeInterval, dispatch_block_t))scheduler {
    if ((self = [super init])) {
        _queue = queue;
        _scheduler = [scheduler copy];
    }
    return self;
}

- (void)start {
    if (_started || _stopped) return;
    _started = YES;
    [self scheduleAfter:SZFriendsOnlineDirectPlainBudget];
}

- (void)stop {
    _stopped = YES;
}

- (void)scheduleAfter:(NSTimeInterval)delay {
    __weak SZFriendsOnlineDirectPhaseTimer *weakSelf = self;
    dispatch_block_t fire = ^{
        [weakSelf budgetRanOut];
    };
    if (_scheduler) {
        _scheduler(delay, fire);
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, fire);
    }
}

- (void)budgetRanOut {
    if (_stopped || _expired) return;
    if (_hardNATProbing && !_extended) {
        _extended = YES;
        [self scheduleAfter:SZFriendsOnlineDirectHardNATBudget];
        return;
    }
    _expired = YES;
    void (^onExpire)(void) = self.onExpire;
    if (onExpire) onExpire();
}

@end
