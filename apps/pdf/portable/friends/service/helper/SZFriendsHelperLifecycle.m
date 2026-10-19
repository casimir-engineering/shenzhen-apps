// Applies the lifecycle policy to the running helper: when to exit, and saying goodbye on the way out.
//
// PROTOCOL.md § Lifecycle and ADR 0002 § Exit. The policy (SZFriendsHelperPolicy.m) is pure; this file feeds it
// the live facts, re-evaluates on every connection change and on a timer aimed at the next deadline, and runs
// the exit sequence once.

#import "service/helper/SZFriendsHelperInternal.h"

// While a handover waits for work in flight, how often to look again.
static const NSTimeInterval SZFriendsLifecycleWorkPoll = 0.1;
// How long goodbyes get to reach clients before the process exits anyway.
static const NSTimeInterval SZFriendsLifecycleGoodbyeFlush = 1.0;

@implementation SZFriendsHelperLifecycle {
    SZFriendsLifecyclePolicy *_policy;
    __weak SZFriendsIPCServer *_server;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    NSDate *_startedAt;
    BOOL _everHadClient;
    NSUInteger _lastActiveCount;
    NSDate *_lastClientLeft;
    BOOL _lastDropWasDisable;
    BOOL _disabledByLastApp;
    NSDate *_handoverRequestedAt;
    NSDictionary<NSString *, id> *_successor;
    BOOL _exiting;
}

- (instancetype)initWithPolicy:(SZFriendsLifecyclePolicy *)policy
                        server:(SZFriendsIPCServer *)server
                         queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _policy = policy;
        _server = server;
        _queue = queue;
    }
    return self;
}

- (void)start {
    _startedAt = [NSDate date];
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    __weak SZFriendsHelperLifecycle *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf evaluate]; });
    dispatch_source_set_timer(_timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(_timer);
    [self evaluate];
}

// Clients that keep the helper alive: every accepted connection except those that turned Friends off. A
// connection counts from accept, before its hello, so a slow first frame never sees the helper leave.
- (NSUInteger)activeClientCount {
    NSUInteger count = 0;
    for (SZFriendsIPCConnection *connection in _server.connections) {
        if (!connection.sentDisable) count++;
    }
    return count;
}

- (void)connectionsChanged:(nullable SZFriendsIPCConnection *)closedConnection {
    // A connection that already sent disable and now closes keeps the drop attributed to the disable.
    if (closedConnection != nil && !closedConnection.sentDisable) _lastDropWasDisable = NO;
    [self evaluate];
}

- (void)connectionSentDisable:(SZFriendsIPCConnection *)connection {
    connection.sentDisable = YES;
    _lastDropWasDisable = YES;
    // Evaluated on the next turn so the disable intent's reply goes out before any goodbye.
    __weak SZFriendsHelperLifecycle *weakSelf = self;
    dispatch_async(_queue, ^{ [weakSelf evaluate]; });
}

- (void)requestHandoverWithSuccessor:(NSDictionary<NSString *, id> *)embeddedHelper {
    uint64_t offered = [embeddedHelper[@"build_number"] unsignedLongLongValue];
    if (_successor == nil || offered > [_successor[@"build_number"] unsignedLongLongValue]) {
        _successor = @{@"version" : embeddedHelper[@"version"] ?: @"", @"build_number" : @(offered)};
    }
    if (_handoverRequestedAt == nil) {
        _handoverRequestedAt = [NSDate date];
        SZFriendsHelperLog(@"handing over to build %llu", offered);
        [_server stopAccepting];
    }
    // Next turn: the requesting client's welcome (handover "scheduled") is sent before its goodbye.
    __weak SZFriendsHelperLifecycle *weakSelf = self;
    dispatch_async(_queue, ^{ [weakSelf evaluate]; });
}

- (void)shutdownForSignal:(int)signalNumber {
    if (_exiting) return;
    SZFriendsHelperLog(@"shutting down on signal %d", signalNumber);
    [self exitWithReason:SZFriendsExitReasonNone goodbye:@"shutdown"];
}

- (void)evaluate {
    if (_exiting) return;
    NSDate *now = [NSDate date];
    NSUInteger active = [self activeClientCount];
    if (active > 0) {
        _everHadClient = YES;
        _lastClientLeft = nil;
        _disabledByLastApp = NO;
    } else if (_lastActiveCount > 0) {
        _lastClientLeft = now;
        _disabledByLastApp = _lastDropWasDisable;
    }
    _lastActiveCount = active;
    BOOL busy = _handoverRequestedAt != nil && self.workInFlight != nil && self.workInFlight();
    SZFriendsExitReason reason = [_policy exitReasonWithClientCount:active
                                                          startedAt:_startedAt
                                                     everHadClient:_everHadClient
                                                     lastClientLeft:_lastClientLeft
                                                   disabledByLastApp:_disabledByLastApp
                                                 handoverRequestedAt:_handoverRequestedAt
                                                        workInFlight:busy
                                                                now:now];
    switch (reason) {
        case SZFriendsExitReasonNone:
            [self scheduleNextEvaluationFrom:now busy:busy];
            return;
        case SZFriendsExitReasonHandover:
            [self exitWithReason:reason goodbye:@"handover"];
            return;
        case SZFriendsExitReasonDisabled:
            // The connections left are the ones that turned Friends off; they are on their way out anyway.
            [self exitWithReason:reason goodbye:@"shutdown"];
            return;
        case SZFriendsExitReasonIdle:
        case SZFriendsExitReasonNoClient:
            [self exitWithReason:reason goodbye:nil];
            return;
    }
}

- (void)scheduleNextEvaluationFrom:(NSDate *)now busy:(BOOL)busy {
    NSTimeInterval next = DBL_MAX;
    if (_handoverRequestedAt != nil) {
        NSTimeInterval deadline = _policy.handoverDeadline - [now timeIntervalSinceDate:_handoverRequestedAt];
        next = MIN(next, busy ? MIN(SZFriendsLifecycleWorkPoll, deadline) : deadline);
    }
    if (_lastClientLeft != nil) {
        next = MIN(next, _policy.gracePeriod - [now timeIntervalSinceDate:_lastClientLeft]);
    }
    if (!_everHadClient) {
        next = MIN(next, _policy.firstClientDeadline - [now timeIntervalSinceDate:_startedAt]);
    }
    if (next == DBL_MAX) {
        dispatch_source_set_timer(_timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
        return;
    }
    // A small floor so a deadline that is "due now" by rounding fires rather than spinning.
    int64_t nanoseconds = (int64_t)(MAX(next, 0.005) * NSEC_PER_SEC);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, nanoseconds), DISPATCH_TIME_FOREVER,
                              NSEC_PER_MSEC);
}

- (void)exitWithReason:(SZFriendsExitReason)reason goodbye:(nullable NSString *)goodbye {
    _exiting = YES;
    dispatch_source_cancel(_timer);
    SZFriendsIPCServer *server = _server;
    [server stopAccepting];
    if (goodbye != nil) {
        NSDictionary *successor = [goodbye isEqualToString:@"handover"] ? _successor : nil;
        [server broadcastGoodbyeWithReason:goodbye successor:successor];
    }
    [self finishAfterFlush:reason deadline:[NSDate dateWithTimeIntervalSinceNow:SZFriendsLifecycleGoodbyeFlush]];
}

// Connections close themselves once their goodbye is written; exit when they have, or at the deadline.
- (void)finishAfterFlush:(SZFriendsExitReason)reason deadline:(NSDate *)deadline {
    if (_server.connections.count > 0 && deadline.timeIntervalSinceNow > 0) {
        __weak SZFriendsHelperLifecycle *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), _queue, ^{
            [weakSelf finishAfterFlush:reason deadline:deadline];
        });
        return;
    }
    if (self.onExit) self.onExit(reason);
}

@end
