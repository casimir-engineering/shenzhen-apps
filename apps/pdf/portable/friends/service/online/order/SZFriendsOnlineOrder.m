// The online order's inputs (SZFriendsOnlineOrder.h; ADR 0011 § The direct phase, § Leave the relay).

#import "service/online/order/SZFriendsOnlineOrderInternal.h"

BOOL SZFriendsOnlineAttemptWorthStarting(SZFriendsRouteMethod current) {
    return SZFriendsRouteIsBetter(SZFriendsRouteMethodInternet, current);
}

static BOOL IsDirectRoute(SZFriendsOnlineRoute route) {
    return route.method == SZFriendsRouteMethodInternet;
}

@implementation SZFriendsOnlineOrder

- (instancetype)initWithRole:(SZFriendsOnlineRole)role
                     purpose:(SZFriendsOnlinePurpose)purpose
                       clock:(NSTimeInterval (^)(void))clock
                      random:(double (^)(void))random {
    if ((self = [super init])) {
        _role = role;
        _phase = SZFriendsOnlinePhaseSignalling;
        _clock = [clock copy];
        _random = [random copy];
        // The connection the offer or answer belongs to exists from the start (signalling first, ADR 0011).
        _directOpen = YES;
        _hardNATPair = -1;
        _phaseDeadline = _retryDeadline = _retryAt = INFINITY;
        _retryInterval = SZFriendsOnlineRetryFirst;
        _firstDescriptionsAt = NAN;
        _log = [SZFriendsTechniqueLogEntry new];
        _log.purpose = purpose;
        _log.role = role;
    }
    return self;
}

- (SZFriendsTechniqueLogEntry *)logEntry {
    return [SZFriendsTechniqueLogEntry entryWithPropertyList:[_log propertyList]];
}

- (BOOL)ended {
    return _phase == SZFriendsOnlinePhaseEnded;
}

- (NSTimeInterval)nextDeadline {
    if (_phase == SZFriendsOnlinePhaseEnded || _role != SZFriendsOnlineRoleOfferer) return INFINITY;
    NSTimeInterval next = INFINITY;
    if (_phase == SZFriendsOnlinePhasePlainChecks || _phase == SZFriendsOnlinePhaseHardNAT) next = _phaseDeadline;
    if (_retryRunning) next = MIN(next, _retryDeadline);
    BOOL periodic = _phase == SZFriendsOnlinePhaseRelayed || _phase == SZFriendsOnlinePhaseStandby;
    if (!_retryRunning && periodic) next = MIN(next, _retryAt);
    return next;
}

// Each step schedules from the clock's reading, never from the deadline it served, so one call cannot run away
// after a long sleep: it serves what is due once and the next deadline lies ahead.
- (SZFriendsOnlineOrderActions)fireDueTimers {
    SZFriendsOnlineOrderActions actions = SZFriendsOnlineOrderActionNone;
    for (int step = 0; step < 4 && self.nextDeadline <= [self now]; step++) {
        NSTimeInterval now = [self now];
        if (_phase == SZFriendsOnlinePhasePlainChecks && _phaseDeadline <= now) {
            actions |= [self plainChecksEnded];
        } else if (_phase == SZFriendsOnlinePhaseHardNAT && _phaseDeadline <= now) {
            actions |= [self budgetSpent];
        } else if (_retryRunning && _retryDeadline <= now) {
            if (_retryHardNATDue) {
                _retryHardNATDue = NO;
                _retryDeadline = now + SZFriendsOnlineHardNATBudget;
                actions |= [self startHardNAT];
            } else {
                actions |= [self retryEnded];
            }
        } else if (!_retryRunning && _retryAt <= now &&
                   (_phase == SZFriendsOnlinePhaseRelayed || _phase == SZFriendsOnlinePhaseStandby)) {
            actions |= [self openRetry];
        }
    }
    return actions;
}

#pragma mark - Inputs

- (SZFriendsOnlineOrderActions)descriptionsAppliedWithLocalNATClass:(SZFriendsNATClass)local
                                                     remoteNATClass:(SZFriendsNATClass)remote {
    if (self.ended) return SZFriendsOnlineOrderActionNone;
    _localNAT = local;
    _remoteNAT = remote;
    _log.localNATClass = local;
    _log.remoteNATClass = remote;
    if (isnan(_firstDescriptionsAt)) _firstDescriptionsAt = [self now];
    if (_retryRunning) {
        [self retryDescriptionsApplied];
    } else if (_phase == SZFriendsOnlinePhaseSignalling) {
        _phase = SZFriendsOnlinePhasePlainChecks;
        // The offerer's timer rules; the answerer follows its signalling.
        if (_role == SZFriendsOnlineRoleOfferer) _phaseDeadline = [self now] + SZFriendsOnlinePlainChecksBudget;
    }
    return SZFriendsOnlineOrderActionNone;
}

- (void)noteTechniqueTried:(SZFriendsOnlineTechnique)technique {
    if (technique > SZFriendsOnlineTechniqueNone && technique <= SZFriendsOnlineTechniqueRelay) {
        _log.techniquesTried |= 1u << technique;
    }
}

- (SZFriendsOnlineOrderActions)streamOpenedOnConnection:(SZFriendsOnlineConnectionKind)kind
                                                  route:(SZFriendsOnlineRoute)route {
    if (self.ended) return SZFriendsOnlineOrderActionNone;
    if (_log.firstTechnique == SZFriendsOnlineTechniqueNone) {
        _log.firstTechnique = route.technique;
        NSTimeInterval since = isnan(_firstDescriptionsAt) ? 0 : [self now] - _firstDescriptionsAt;
        _log.secondsToFirstStream = MAX(since, 0);
    }
    if (_phase == SZFriendsOnlinePhaseDirect) {
        // A second path of the same class: the session race keeps the first (ADR 0011 § Route rank).
        return SZFriendsOnlineOrderActionNone;
    }
    _log.finalTechnique = route.technique;
    if (IsDirectRoute(route) || kind != SZFriendsOnlineConnectionRelay) return [self becomeDirectOn:kind];
    // The relay carries it.
    _log.relayNeeded = YES;
    _carrier = SZFriendsOnlineConnectionRelay;
    if ([self otherRouteWorks]) return [self leaveRelayForOtherRoute];
    _phase = SZFriendsOnlinePhaseRelayed;
    if (!_retryRunning) [self schedulePeriodicRetryAfter:SZFriendsOnlineRetryFirst];
    return SZFriendsOnlineOrderActionNone;
}

- (SZFriendsOnlineOrderActions)routeChangedOnConnection:(SZFriendsOnlineConnectionKind)kind
                                                  route:(SZFriendsOnlineRoute)route {
    if (self.ended || kind != _carrier) return SZFriendsOnlineOrderActionNone;
    _log.finalTechnique = route.technique;
    if (kind != SZFriendsOnlineConnectionRelay) return SZFriendsOnlineOrderActionNone;
    // libjuice settled the relay connection on a shorter pair by itself: direct, and the connection stays.
    if (IsDirectRoute(route) && _phase == SZFriendsOnlinePhaseRelayed) return [self becomeDirectOn:kind];
    if (!IsDirectRoute(route) && _phase == SZFriendsOnlinePhaseDirect) {
        _phase = SZFriendsOnlinePhaseRelayed;
        _relayOpen = YES;
        [self schedulePeriodicRetryAfter:SZFriendsOnlineRetryFirst];
    }
    return SZFriendsOnlineOrderActionNone;
}

- (SZFriendsOnlineOrderActions)connectionFailed:(SZFriendsOnlineConnectionKind)kind {
    if (self.ended) return SZFriendsOnlineOrderActionNone;
    if (kind == _carrier) return [self endWithReason:SZFriendsOnlineEndStreamClosed];
    switch (kind) {
    case SZFriendsOnlineConnectionDirect:
        _directOpen = NO;
        if (_retryRunning) return [self retryEnded];
        if (_phase == SZFriendsOnlinePhaseSignalling) return [self endWithReason:SZFriendsOnlineEndUnreachable];
        if (_phase == SZFriendsOnlinePhasePlainChecks && _role == SZFriendsOnlineRoleOfferer) {
            return [self plainChecksEnded];
        }
        if (_phase == SZFriendsOnlinePhaseHardNAT && !_probing && _role == SZFriendsOnlineRoleOfferer) {
            return [self budgetSpent];
        }
        break;
    case SZFriendsOnlineConnectionProbeHandover: {
        SZFriendsOnlineOrderActions actions = [self stopProbing];
        if (_phase == SZFriendsOnlinePhaseHardNAT && !_directOpen && _role == SZFriendsOnlineRoleOfferer) {
            actions |= [self budgetSpent];
        }
        return actions;
    }
    case SZFriendsOnlineConnectionRelay:
        _relayOpen = NO;
        break;
    }
    BOOL nothingLeft = !_directOpen && !_relayOpen && !_retryRunning && !_probing;
    BOOL waitingOnRelay = _phase == SZFriendsOnlinePhaseRelay || _phase == SZFriendsOnlinePhaseRelayed;
    if (nothingLeft && waitingOnRelay) return [self endWithReason:SZFriendsOnlineEndUnreachable];
    return SZFriendsOnlineOrderActionNone;
}

- (SZFriendsOnlineOrderActions)streamClosedOnConnection:(SZFriendsOnlineConnectionKind)kind {
    if (self.ended || kind != _carrier) return SZFriendsOnlineOrderActionNone;
    return [self endWithReason:SZFriendsOnlineEndStreamClosed];
}

// Another route works: the relay is closed and the attempt keeps trying direct (Standby).
- (SZFriendsOnlineOrderActions)leaveRelayForOtherRoute {
    SZFriendsOnlineOrderActions actions = SZFriendsOnlineOrderActionNone;
    if (_relayOpen) actions |= SZFriendsOnlineOrderActionCloseRelay;
    _relayOpen = NO;
    if (_carrier == SZFriendsOnlineConnectionRelay) _carrier = 0;
    BOOL scheduled = _phase == SZFriendsOnlinePhaseRelayed && isfinite(_retryAt);
    _phase = SZFriendsOnlinePhaseStandby;
    if (!_retryRunning && !scheduled) [self schedulePeriodicRetryAfter:SZFriendsOnlineRetryFirst];
    return actions;
}

- (SZFriendsOnlineOrderActions)otherRouteChanged:(SZFriendsRouteMethod)route {
    _otherRoute = route;
    if (self.ended) return SZFriendsOnlineOrderActionNone;
    BOOL better = SZFriendsRouteIsBetter(route, SZFriendsRouteMethodInternet);
    BOOL earlierInternet = route == SZFriendsRouteMethodInternet && _phase != SZFriendsOnlinePhaseDirect;
    if (better || earlierInternet) return [self endWithReason:SZFriendsOnlineEndSuperseded];
    if ([self otherRouteWorks]) {
        if (_phase == SZFriendsOnlinePhaseRelay || _phase == SZFriendsOnlinePhaseRelayed) {
            return [self leaveRelayForOtherRoute];
        }
        return SZFriendsOnlineOrderActionNone;
    }
    // The other route is gone. The offerer turns to the relay if its budget is already spent; the answerer waits
    // for the offerer's relay offer.
    if (_phase == SZFriendsOnlinePhaseStandby && _role == SZFriendsOnlineRoleOfferer) return [self budgetSpent];
    return SZFriendsOnlineOrderActionNone;
}

- (SZFriendsOnlineOrderActions)networkChanged {
    if (self.ended || _phase == SZFriendsOnlinePhaseDirect) return SZFriendsOnlineOrderActionNone;
    if (_role != SZFriendsOnlineRoleOfferer) return SZFriendsOnlineOrderActionSignalNetworkChange;
    switch (_phase) {
    case SZFriendsOnlinePhaseSignalling:
    case SZFriendsOnlinePhasePlainChecks:
    case SZFriendsOnlinePhaseHardNAT: {
        // Before any relay: start over with a new direct connection; its descriptions start a new budget.
        SZFriendsOnlineOrderActions actions = [self stopProbing];
        if (_directOpen) actions |= SZFriendsOnlineOrderActionCloseDirect;
        _directOpen = YES;
        _phase = SZFriendsOnlinePhaseSignalling;
        _phaseDeadline = INFINITY;
        _hardNATPair = -1;
        _log.directRetries++;
        return actions | SZFriendsOnlineOrderActionOpenDirect;
    }
    default:
        // Relay, Relayed, Standby: try direct at once. Should it fail, the next periodic retry waits the first
        // step again (retryEnded doubles this half step to SZFriendsOnlineRetryFirst).
        _retryInterval = SZFriendsOnlineRetryFirst / 2;
        return [self openRetry];
    }
}

- (SZFriendsOnlineOrderActions)localNATClassChanged:(SZFriendsNATClass)local {
    if (!self.ended) {
        _localNAT = local;
        _log.localNATClass = local;
    }
    return SZFriendsOnlineOrderActionNone;
}

- (SZFriendsOnlineOrderActions)probingEndedRefused:(BOOL)refused {
    if (self.ended || !_probing) return SZFriendsOnlineOrderActionNone;
    _probing = NO;
    if (refused) _log.techniquesTried &= ~(NSUInteger)(1u << SZFriendsOnlineTechniqueProbeHandover);
    // With the direct connection already gone, nothing else can connect in this phase: on to the relay now.
    BOOL offererInHardNAT = _phase == SZFriendsOnlinePhaseHardNAT && _role == SZFriendsOnlineRoleOfferer;
    if (offererInHardNAT && !_directOpen) return [self budgetSpent];
    return SZFriendsOnlineOrderActionNone;
}

- (SZFriendsOnlineOrderActions)peerStartedHardNAT {
    if (self.ended || _role != SZFriendsOnlineRoleAnswerer) return SZFriendsOnlineOrderActionNone;
    if (_phase == SZFriendsOnlinePhasePlainChecks || _phase == SZFriendsOnlinePhaseSignalling) {
        _phase = SZFriendsOnlinePhaseHardNAT;
    } else if (!_retryRunning) {
        return SZFriendsOnlineOrderActionNone;
    }
    return [self startHardNAT];
}

- (SZFriendsOnlineOrderActions)peerOpenedRelay {
    if (self.ended || _role != SZFriendsOnlineRoleAnswerer || _relayOpen) return SZFriendsOnlineOrderActionNone;
    if (_phase == SZFriendsOnlinePhaseDirect) return SZFriendsOnlineOrderActionNone;
    SZFriendsOnlineOrderActions actions = [self stopProbing];
    _relayOpen = YES;
    _phase = SZFriendsOnlinePhaseRelay;
    _log.relayRequested = YES;
    _log.techniquesTried |= 1u << SZFriendsOnlineTechniqueRelay;
    return actions | SZFriendsOnlineOrderActionOpenRelay;
}

- (SZFriendsOnlineOrderActions)peerOpenedDirect {
    if (self.ended || _role != SZFriendsOnlineRoleAnswerer || _phase == SZFriendsOnlinePhaseDirect) {
        return SZFriendsOnlineOrderActionNone;
    }
    SZFriendsOnlineOrderActions actions = [self stopProbing];
    if (_directOpen) actions |= SZFriendsOnlineOrderActionCloseDirect;
    _directOpen = YES;
    _log.directRetries++;
    if (_phase == SZFriendsOnlinePhasePlainChecks || _phase == SZFriendsOnlinePhaseHardNAT) {
        _phase = SZFriendsOnlinePhaseSignalling;
    } else if (_phase != SZFriendsOnlinePhaseSignalling) {
        _retryRunning = YES;
    }
    return actions | SZFriendsOnlineOrderActionOpenDirect;
}

- (SZFriendsOnlineOrderActions)peerNetworkChanged {
    if (_role != SZFriendsOnlineRoleOfferer) return SZFriendsOnlineOrderActionNone;
    return [self networkChanged];
}

- (SZFriendsOnlineOrderActions)close {
    return [self endWithReason:SZFriendsOnlineEndClosed];
}

@end
