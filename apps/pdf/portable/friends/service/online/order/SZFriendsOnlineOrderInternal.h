// The online order's shared state, split by concern so each file stays reviewable: SZFriendsOnlineOrder.m (the
// inputs) and +Timers (the phase timers, the hard-NAT step, the relay decision and the direct retries). Internal to
// this directory.

#import "service/online/order/SZFriendsOnlineOrder.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsOnlineOrder () {
  @package
    SZFriendsOnlineRole _role;
    SZFriendsOnlinePhase _phase;
    SZFriendsOnlineEndReason _endReason;
    NSTimeInterval (^_clock)(void);
    double (^_random)(void);
    // Which connections this attempt holds, and which one carries the stream (0 while none does).
    BOOL _directOpen, _relayOpen, _probing;
    SZFriendsOnlineConnectionKind _carrier;
    SZFriendsRouteMethod _otherRoute;
    SZFriendsNATClass _localNAT, _remoteNAT;
    // The NAT classes the last hard-NAT decision saw (-1 before any): a retry probes again only when they changed.
    NSInteger _hardNATPair;
    NSTimeInterval _phaseDeadline;
    // Direct retries: the one running (its connection, whether its descriptions arrived, whether its hard-NAT step
    // is due) and when the next periodic one starts.
    BOOL _retryRunning, _retryHasDescriptions, _retryHardNATDue;
    NSTimeInterval _retryDeadline, _retryAt, _retryInterval;
    NSTimeInterval _firstDescriptionsAt;
    SZFriendsTechniqueLogEntry *_log;
}
@end

@interface SZFriendsOnlineOrder (Timers)
- (NSTimeInterval)now;
- (BOOL)otherRouteWorks;
- (SZFriendsOnlineOrderActions)endWithReason:(SZFriendsOnlineEndReason)reason;
- (SZFriendsOnlineOrderActions)stopProbing;
- (SZFriendsOnlineOrderActions)startHardNAT;
// The plain checks ended (their timer, or the direct connection failed): the hard-NAT step, or the budget is spent.
- (SZFriendsOnlineOrderActions)plainChecksEnded;
// No direct path within the budget: the relay, or Standby while another route works.
- (SZFriendsOnlineOrderActions)budgetSpent;
- (SZFriendsOnlineOrderActions)becomeDirectOn:(SZFriendsOnlineConnectionKind)kind;
- (SZFriendsOnlineOrderActions)openRetry;
- (SZFriendsOnlineOrderActions)retryEnded;
- (void)retryDescriptionsApplied;
- (void)schedulePeriodicRetryAfter:(NSTimeInterval)interval;
@end

NS_ASSUME_NONNULL_END
