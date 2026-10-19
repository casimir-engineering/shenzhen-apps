// The online order's timers and the steps they take (SZFriendsOnlineOrderInternal.h; ADR 0011 § The direct phase).

#import "service/online/order/SZFriendsOnlineOrderInternal.h"

const NSTimeInterval SZFriendsOnlinePlainChecksBudget = 5;
const NSTimeInterval SZFriendsOnlineHardNATBudget = 12;
const NSTimeInterval SZFriendsOnlineRetryFirst = 30;
const NSTimeInterval SZFriendsOnlineRetryMax = 300;
const double SZFriendsOnlineRetryJitter = 0.2;
const NSTimeInterval SZFriendsOnlineRetrySignallingLimit = 10;

BOOL SZFriendsOnlineHardNATWorthTrying(SZFriendsNATClass local, SZFriendsNATClass remote) {
    BOOL localHard = local == SZFriendsNATClassPerDestination;
    BOOL remoteHard = remote == SZFriendsNATClassPerDestination;
    if (localHard == remoteHard) return NO;
    // The other side must be known to be easy: an unknown class means the plain checks were all there was.
    return (localHard ? remote : local) == SZFriendsNATClassEndpointIndependent;
}

static NSInteger NATPair(SZFriendsNATClass local, SZFriendsNATClass remote) {
    return local * 16 + remote;
}

@implementation SZFriendsOnlineOrder (Timers)

- (NSTimeInterval)now {
    return _clock();
}

- (BOOL)otherRouteWorks {
    return SZFriendsRouteRank(_otherRoute) <= SZFriendsRouteRank(SZFriendsRouteMethodRelay);
}

- (SZFriendsOnlineOrderActions)endWithReason:(SZFriendsOnlineEndReason)reason {
    if (_phase == SZFriendsOnlinePhaseEnded) return SZFriendsOnlineOrderActionNone;
    [self stopProbing];
    _phase = SZFriendsOnlinePhaseEnded;
    _endReason = reason;
    _log.endReason = reason;
    _directOpen = _relayOpen = _retryRunning = NO;
    _carrier = 0;
    return SZFriendsOnlineOrderActionEnd;
}

- (SZFriendsOnlineOrderActions)stopProbing {
    if (!_probing) return SZFriendsOnlineOrderActionNone;
    _probing = NO;
    return SZFriendsOnlineOrderActionStopProbing;
}

- (SZFriendsOnlineOrderActions)startHardNAT {
    _hardNATPair = NATPair(_localNAT, _remoteNAT);
    SZFriendsOnlineOrderActions actions = SZFriendsOnlineOrderActionStartPrediction;
    _log.techniquesTried |= 1u << SZFriendsOnlineTechniquePredictedPort;
    if (!_probing) {
        _probing = YES;
        _log.techniquesTried |= 1u << SZFriendsOnlineTechniqueProbeHandover;
        actions |= SZFriendsOnlineOrderActionStartProbing;
    }
    return actions;
}

- (SZFriendsOnlineOrderActions)plainChecksEnded {
    BOOL worth = SZFriendsOnlineHardNATWorthTrying(_localNAT, _remoteNAT);
    _hardNATPair = NATPair(_localNAT, _remoteNAT);
    if (!worth) return [self budgetSpent];
    _phase = SZFriendsOnlinePhaseHardNAT;
    _phaseDeadline = [self now] + SZFriendsOnlineHardNATBudget;
    return [self startHardNAT];
}

- (SZFriendsOnlineOrderActions)budgetSpent {
    SZFriendsOnlineOrderActions actions = [self stopProbing];
    _phaseDeadline = INFINITY;
    if ([self otherRouteWorks]) {
        // "Only in last resort": another route carries the session, so no relay; keep trying direct now and then.
        _phase = SZFriendsOnlinePhaseStandby;
        if (!_retryRunning) [self schedulePeriodicRetryAfter:SZFriendsOnlineRetryFirst];
        return actions;
    }
    _phase = SZFriendsOnlinePhaseRelay;
    _retryAt = INFINITY;
    if (!_relayOpen) {
        _relayOpen = YES;
        _log.relayRequested = YES;
        _log.techniquesTried |= 1u << SZFriendsOnlineTechniqueRelay;
        actions |= SZFriendsOnlineOrderActionOpenRelay;
    }
    // Periodic retries start once the relay carries the stream; until then only a network change opens one.
    return actions;
}

- (SZFriendsOnlineOrderActions)becomeDirectOn:(SZFriendsOnlineConnectionKind)kind {
    SZFriendsOnlineOrderActions actions = [self stopProbing];
    if (_log.relayNeeded) _log.leftRelay = YES;
    if (kind != SZFriendsOnlineConnectionDirect && _directOpen) {
        _directOpen = NO;
        actions |= SZFriendsOnlineOrderActionCloseDirect;
    }
    if (kind != SZFriendsOnlineConnectionRelay && _relayOpen) {
        _relayOpen = NO;
        actions |= SZFriendsOnlineOrderActionCloseRelay;
    }
    _carrier = kind;
    _phase = SZFriendsOnlinePhaseDirect;
    _phaseDeadline = _retryAt = _retryDeadline = INFINITY;
    _retryRunning = NO;
    return actions;
}

// A new direct connection beside the relay (or Standby's other route): the plain checks once more.
- (SZFriendsOnlineOrderActions)openRetry {
    SZFriendsOnlineOrderActions actions = [self stopProbing];
    if (_directOpen) actions |= SZFriendsOnlineOrderActionCloseDirect;
    _directOpen = YES;
    _retryRunning = YES;
    _retryHasDescriptions = _retryHardNATDue = NO;
    _retryDeadline = [self now] + SZFriendsOnlineRetrySignallingLimit;
    _retryAt = INFINITY;
    _log.directRetries++;
    return actions | SZFriendsOnlineOrderActionOpenDirect;
}

// A retry found no direct path in its budget (or its connection failed): close it and wait longer for the next.
- (SZFriendsOnlineOrderActions)retryEnded {
    SZFriendsOnlineOrderActions actions = [self stopProbing];
    if (_directOpen) actions |= SZFriendsOnlineOrderActionCloseDirect;
    _directOpen = NO;
    _retryRunning = NO;
    _retryDeadline = INFINITY;
    BOOL periodic = _phase == SZFriendsOnlinePhaseRelayed || _phase == SZFriendsOnlinePhaseStandby;
    if (periodic) [self schedulePeriodicRetryAfter:MIN(_retryInterval * 2, SZFriendsOnlineRetryMax)];
    return actions;
}

// Only the offerer retries (the answerer answers the offerer's new offers); each wait is drawn from +/-20%.
- (void)schedulePeriodicRetryAfter:(NSTimeInterval)interval {
    _retryInterval = MAX(interval, SZFriendsOnlineRetryFirst);
    if (_role != SZFriendsOnlineRoleOfferer) {
        _retryAt = INFINITY;
        return;
    }
    double r = MIN(MAX(_random(), 0.0), 1.0);
    _retryAt = [self now] + _retryInterval * (1 + SZFriendsOnlineRetryJitter * (2 * r - 1));
}

// A retry's descriptions arrived: its plain checks run from now, then its hard-NAT step if a NAT class changed.
- (void)retryDescriptionsApplied {
    _retryHasDescriptions = YES;
    _retryDeadline = [self now] + SZFriendsOnlinePlainChecksBudget;
    BOOL changed = NATPair(_localNAT, _remoteNAT) != _hardNATPair;
    _retryHardNATDue = _role == SZFriendsOnlineRoleOfferer && changed &&
                       SZFriendsOnlineHardNATWorthTrying(_localNAT, _remoteNAT);
    if (!_retryHardNATDue) _hardNATPair = NATPair(_localNAT, _remoteNAT);
}

@end
