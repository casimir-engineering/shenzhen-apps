// One attempt's connections (SZFriendsOnlineAttemptInternal.h): opening them for the order, what the transport
// reports about them, the order's actions and its timers. The order is the one owner of the direct phase's timers:
// the transport's SZFriendsOnlineDirectPhaseTimer is never given an expiry, and the TCP path ends when the order
// leaves the direct phase.

#import "service/online/driver/SZFriendsOnlineAttemptInternal.h"

#import "service/online/nat/SZFriendsNATPortMapping.h"
#import "service/online/nat/SZFriendsNATPrediction.h"
#import "service/online/nat/SZFriendsNATProber.h"

static BOOL InDirectPhase(SZFriendsOnlinePhase phase) {
    return phase == SZFriendsOnlinePhaseSignalling || phase == SZFriendsOnlinePhasePlainChecks ||
           phase == SZFriendsOnlinePhaseHardNAT;
}

@implementation SZFriendsOnlineAttempt (Connections)

#pragma mark - Opening

// Every request names this attempt's own peer and purpose (header rule 6): a relay, retry or probe handover
// connection is never aimed anywhere the authenticated signalling did not establish.
- (SZFriendsOnlineSlot *)openSlotOfKind:(SZFriendsOnlineConnectionKind)kind
                                 number:(uint8_t)number
                                  offer:(SZFriendsSignalItem *)offer
                                  relay:(id<SZFriendsOnlineRelayCredentials>)relay
                              localPort:(uint16_t)localPort {
    if (_ended || _slots[@(number)] != nil) return nil;
    BOOL blocked = [_context directPathsBlocked];
    SZFriendsOnlineRequest *request = [SZFriendsOnlineRequest new];
    request.purpose = SZFriendsOnlinePurposeFriend;
    request.role = _role;
    request.kind = kind;
    request.peer = _friend.identityKey;
    request.relay = relay;
    request.localPort = localPort;
    // One STUN server, the host's, for a direct connection; a relay gathers relay candidates only, and a probe
    // handover's only pair is the prober's.
    request.stunURI = kind == SZFriendsOnlineConnectionDirect && !blocked ? _context.stunURI : nil;
    request.wantsTCPPath = kind == SZFriendsOnlineConnectionDirect && !blocked;
    if (offer != nil) {
        request.remoteOfferSDP = [offer stringForTag:SZFriendsSignalTagSDP];
        request.remoteFingerprint = [offer dataForTag:SZFriendsSignalTagFingerprint];
    }
    SZFriendsOnlineSlot *slot = [SZFriendsOnlineSlot new];
    slot.number = number;
    slot.kind = kind;
    slot.remoteReady = _role == SZFriendsOnlineRoleAnswerer;
    request.onSidePath = ^(id<SZFriendsOnlineSidePath> sidePath) {
        if ([(id)sidePath isKindOfClass:[SZFriendsOnlineTCPSidePath class]]) {
            slot.sidePath = (SZFriendsOnlineTCPSidePath *)sidePath;
        }
    };
    _slots[@(number)] = slot; // before the transport can call back
    id<SZFriendsOnlineConnection> connection = [_context.transport openConnection:request
                                                                         delegate:self
                                                                            queue:_context.queue
                                                                            error:NULL];
    if (connection == nil) {
        [_slots removeObjectForKey:@(number)];
        return nil;
    }
    slot.connection = connection;
    // Never the transport's own direct-phase clock: the order decides (lead decision for M2).
    if ([(id)connection conformsToProtocol:@protocol(SZFriendsOnlineConnectionExtras)]) {
        ((id<SZFriendsOnlineConnectionExtras>)connection).directPhase.onExpire = nil;
    }
    if (kind == SZFriendsOnlineConnectionDirect) _direct = slot;
    if (kind == SZFriendsOnlineConnectionRelay) _relay = slot;
    if (kind == SZFriendsOnlineConnectionProbeHandover) _probe = slot;
    if (slot.remoteReady) [self applyHeldItemsForSlot:slot];
    return slot;
}

- (SZFriendsOnlineSlot *)slotForConnection:(id<SZFriendsOnlineConnection>)connection {
    for (SZFriendsOnlineSlot *slot in _slots.allValues) {
        if (slot.connection == connection) return slot;
    }
    return nil;
}

- (BOOL)isCurrentSlot:(SZFriendsOnlineSlot *)slot {
    return slot != nil && (slot == _direct || slot == _relay || slot == _probe);
}

// Forgotten first, then closed: the streams it closes report to a slot that is no longer current.
- (void)closeSlot:(SZFriendsOnlineSlot *)slot {
    if (slot == nil) return;
    if (slot == _direct) _direct = nil;
    if (slot == _relay) _relay = nil;
    if (slot == _probe) _probe = nil;
    id<SZFriendsOnlineConnection> connection = slot.connection;
    slot.connection = nil;
    [slot.portMapping close];
    slot.portMapping = nil;
    [connection close];
    [_held removeObjectForKey:@(slot.number)];
}

- (uint8_t)takeNumber {
    NSUInteger number = _nextNumber++;
    return number < SZFriendsOnlineConnectionsMax ? (uint8_t)number : 0;
}

#pragma mark - Remote input

- (void)answererOfferArrived:(SZFriendsSignalItem *)offer
                       number:(uint8_t)number
                         kind:(SZFriendsOnlineConnectionKind)kind {
    if (number == 0 && kind == SZFriendsOnlineConnectionDirect && _direct == nil && _slots.count == 0) {
        // The first direct connection exists from the start of the attempt (the order counts it open).
        if ([self openSlotOfKind:kind number:0 offer:offer relay:nil localPort:0] == nil) [self finish];
        return;
    }
    NSMutableDictionary *pending = [NSMutableDictionary dictionaryWithObject:offer forKey:@"offer"];
    pending[@"number"] = @(number);
    _offers[@(kind)] = pending;
    switch (kind) {
    case SZFriendsOnlineConnectionDirect:
        [self perform:[_order peerOpenedDirect]];
        break;
    case SZFriendsOnlineConnectionRelay:
        [self perform:[_order peerOpenedRelay]];
        break;
    case SZFriendsOnlineConnectionProbeHandover:
        [self probeOfferArrived];
        break;
    }
}

- (void)applyRemoteCandidate:(SZFriendsSignalItem *)item toSlot:(SZFriendsOnlineSlot *)slot {
    uint64_t technique = 0;
    [item getUnsigned:&technique forTag:SZFriendsSignalTagTechnique];
    NSString *line = [item stringForTag:SZFriendsSignalTagCandidate];
    if (line == nil || slot.kind == SZFriendsOnlineConnectionProbeHandover) return;
    // A scripted direct failure (tests): only relay candidates reach the stack.
    if ([_context directPathsBlocked] && technique != SZFriendsOnlineTechniqueRelay) return;
    if (![slot.connection addRemoteCandidate:line technique:(SZFriendsOnlineTechnique)technique error:NULL]) return;
    SZFriendsNATCandidate *candidate = [SZFriendsNATCandidate candidateWithLine:line];
    if (candidate != nil && !candidate.tcp) {
        slot.remoteCandidates++;
        [slot.remoteEndpoints addObject:candidate.endpoint];
    }
    if (candidate.type == SZFriendsNATCandidateTypeServerReflexive && slot.remoteReflexive == nil) {
        slot.remoteReflexive = candidate.endpoint;
        if (slot == _direct) [self predictIfPossible];
    }
}

#pragma mark - SZFriendsOnlineConnectionDelegate

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
    didCreateLocalDescription:(NSString *)sdp
                  fingerprint:(NSData *)fingerprint {
    SZFriendsOnlineSlot *slot = [self slotForConnection:connection];
    if (slot == nil || _ended) return;
    SZFriendsSignalItem *description = [SZFriendsSignalItem descriptionWithConnection:slot.number
                                                                                 kind:(uint8_t)slot.kind
                                                                                  sdp:sdp
                                                                          fingerprint:fingerprint];
    if (_role == SZFriendsOnlineRoleOfferer) {
        if (_session == nil) [self openSidWithDescription:description];
        else [self sendItems:@[ description ]];
        return;
    }
    if (_replied) [self sendItems:@[ description ]];
    else [self replyWithDescription:description];
    // The answerer's descriptions are both applied once it sends its answer (ADR 0011 § The direct phase).
    if (slot == _direct && !_ended) {
        [self perform:[_order descriptionsAppliedWithLocalNATClass:_context.natClass remoteNATClass:_remoteNAT]];
    }
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
    didGatherLocalCandidate:(NSString *)candidate
                  technique:(SZFriendsOnlineTechnique)technique {
    SZFriendsOnlineSlot *slot = [self slotForConnection:connection];
    if (slot == nil || _ended) return;
    if ([_context directPathsBlocked] && technique != SZFriendsOnlineTechniqueRelay) return;
    [_order noteTechniqueTried:technique];
    [self sendItems:@[ [SZFriendsSignalItem candidateWithConnection:slot.number
                                                          technique:(uint8_t)technique
                                                               line:candidate] ]];
    [self maybeAskPortMappingForSlot:slot];
}

- (void)onlineConnectionDidFinishGathering:(id<SZFriendsOnlineConnection>)connection {
    SZFriendsOnlineSlot *slot = [self slotForConnection:connection];
    if (slot != nil && !_ended) [self sendItems:@[ [SZFriendsSignalItem candidatesEndWithConnection:slot.number] ]];
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
           didOpenStream:(id<SZFriendsByteStream>)stream
                   route:(SZFriendsOnlineRoute)route {
    SZFriendsOnlineSlot *slot = [self slotForConnection:connection];
    if (slot == nil || _ended || ![self isCurrentSlot:slot]) {
        [stream close];
        return;
    }
    slot.openStreams++;
    _connected = YES;
    __weak SZFriendsOnlineAttempt *weakSelf = self;
    __weak SZFriendsOnlineSlot *weakSlot = slot;
    id<SZFriendsByteStream> tracked = SZFriendsOnlineTrackStream(stream, ^{
        [weakSelf streamClosedOnSlot:weakSlot];
    });
    [_owner attempt:self didOpenStream:tracked route:route];
    [self perform:[_order streamOpenedOnConnection:slot.kind route:route]];
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
                  stream:(id<SZFriendsByteStream>)stream
          didChangeRoute:(SZFriendsOnlineRoute)route {
    (void)stream;
    SZFriendsOnlineSlot *slot = [self slotForConnection:connection];
    if ([self isCurrentSlot:slot]) [self perform:[_order routeChangedOnConnection:slot.kind route:route]];
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection didFailWithError:(NSError *)error {
    (void)error;
    SZFriendsOnlineSlot *slot = [self slotForConnection:connection];
    if (slot == nil) return;
    BOOL current = [self isCurrentSlot:slot];
    slot.connection = nil;
    [slot.portMapping close];
    slot.portMapping = nil;
    if (slot == _direct) _direct = nil;
    if (slot == _relay) _relay = nil;
    if (slot == _probe) _probe = nil;
    if (current && !_ended) [self perform:[_order connectionFailed:slot.kind]];
}

- (void)streamClosedOnSlot:(SZFriendsOnlineSlot *)slot {
    if (slot == nil || _ended) return;
    if (slot.openStreams > 0) slot.openStreams--;
    if (slot.openStreams == 0 && [self isCurrentSlot:slot]) {
        [self perform:[_order streamClosedOnConnection:slot.kind]];
    }
}

#pragma mark - The order's actions

// In the order the header gives (closes before opens); a step may feed the order again (a connection that could
// not open), which can end the attempt, so each step looks first.
- (void)perform:(SZFriendsOnlineOrderActions)actions {
    if (_ended) return;
    if (actions & SZFriendsOnlineOrderActionStopProbing) [self stopProbing];
    if ((actions & SZFriendsOnlineOrderActionCloseDirect) && _direct.openStreams == 0) [self closeSlot:_direct];
    if (actions & SZFriendsOnlineOrderActionCloseRelay) [self closeSlot:_relay];
    if (!_ended && (actions & SZFriendsOnlineOrderActionOpenDirect)) {
        [self openForOrder:SZFriendsOnlineConnectionDirect];
    }
    if (!_ended && (actions & SZFriendsOnlineOrderActionOpenRelay)) [self openRelay];
    if (!_ended && (actions & SZFriendsOnlineOrderActionStartPrediction)) [self startPrediction];
    if (!_ended && (actions & SZFriendsOnlineOrderActionStartProbing)) [self startProbing];
    if (!_ended && (actions & SZFriendsOnlineOrderActionSignalNetworkChange)) {
        uint8_t number = _direct ? _direct.number : 0;
        [self sendItems:@[ [SZFriendsSignalItem startWithConnection:number kind:SZFriendsOnlineConnectionDirect] ]];
    }
    if (actions & SZFriendsOnlineOrderActionEnd) [self finish];
    if (_ended) return;
    [self followPhase];
    [self armTimer];
}

// The TCP path dials while the order's direct phase lasts: when the phase gives way to the relay or Standby, or a
// path connects, a TCP path with no stream stops.
- (void)followPhase {
    SZFriendsOnlinePhase phase = _order.phase;
    if (phase != _lastPhase) {
        if (phase == SZFriendsOnlinePhaseDirect) {
            for (SZFriendsOnlineSlot *slot in _slots.allValues) [slot.sidePath finishBudget];
        } else if (InDirectPhase(_lastPhase) && !InDirectPhase(phase)) {
            [_direct.sidePath finishBudget];
        }
    }
    _lastPhase = phase;
}

- (void)openForOrder:(SZFriendsOnlineConnectionKind)kind {
    if (_role == SZFriendsOnlineRoleOfferer) {
        uint8_t number = [self takeNumber];
        if (number == 0 || [self openSlotOfKind:kind number:number offer:nil relay:nil localPort:0] == nil) {
            [self perform:[_order connectionFailed:kind]];
        }
        return;
    }
    NSDictionary *pending = (NSDictionary *)_offers[@(kind)];
    [_offers removeObjectForKey:@(kind)];
    uint8_t number = (uint8_t)[pending[@"number"] unsignedIntValue];
    if (pending == nil || [self openSlotOfKind:kind number:number offer:pending[@"offer"] relay:nil
                                     localPort:0] == nil) {
        [self perform:[_order connectionFailed:kind]];
    }
}

// The relay: credentials for this sid first (ADR 0010: only once both ends have spoken), then a new connection with
// relay candidates only. The answerer asks for its own and answers the offerer's relay offer.
- (void)openRelay {
    if (_channel == nil || _channel.ended) {
        [self perform:[_order connectionFailed:SZFriendsOnlineConnectionRelay]];
        return;
    }
    __weak SZFriendsOnlineAttempt *weakSelf = self;
    [_channel requestRelayCredentials:^(id<SZFriendsOnlineRelayCredentials> credentials, NSError *error) {
        (void)error;
        [weakSelf openRelayWithCredentials:credentials];
    }];
}

- (void)openRelayWithCredentials:(id<SZFriendsOnlineRelayCredentials>)credentials {
    if (_ended) return;
    SZFriendsOnlineSlot *slot = nil;
    if (credentials != nil && _role == SZFriendsOnlineRoleOfferer) {
        uint8_t number = [self takeNumber];
        if (number != 0) {
            slot = [self openSlotOfKind:SZFriendsOnlineConnectionRelay number:number offer:nil relay:credentials
                              localPort:0];
        }
    } else if (credentials != nil) {
        NSDictionary *pending = (NSDictionary *)_offers[@(SZFriendsOnlineConnectionRelay)];
        [_offers removeObjectForKey:@(SZFriendsOnlineConnectionRelay)];
        if (pending != nil) {
            slot = [self openSlotOfKind:SZFriendsOnlineConnectionRelay
                                 number:(uint8_t)[pending[@"number"] unsignedIntValue]
                                  offer:pending[@"offer"]
                                  relay:credentials
                              localPort:0];
        }
    }
    if (slot == nil) [self perform:[_order connectionFailed:SZFriendsOnlineConnectionRelay]];
}

#pragma mark - Timers

- (void)armTimer {
    if (_timer) dispatch_source_cancel(_timer);
    _timer = nil;
    if (_ended || !_context.usesDispatchTimers) return;
    NSTimeInterval deadline = MIN(_order.nextDeadline, _answered ? INFINITY : _answerDeadline);
    if (!isfinite(deadline)) return;
    NSTimeInterval delay = MAX(deadline - _context.clock(), 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _context.queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 50);
    __weak SZFriendsOnlineAttempt *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{ [weakSelf fireTimers]; });
    dispatch_resume(timer);
    _timer = timer;
}

- (void)fireTimers {
    if (_ended) return;
    if (!_answered && !_connected && _answerDeadline <= _context.clock()) {
        // Nobody answered: an offline friend and a refusal look the same, and both end the attempt quietly.
        [self finish];
        return;
    }
    if (!_answered && _answerDeadline <= _context.clock()) {
        // A later sid went unanswered while a stream still carries the session: forget that sid, keep the rest.
        _answerDeadline = INFINITY;
        [_channel close];
        _channel = nil;
        [_outgoing removeAllObjects];
    }
    [self perform:[_order fireDueTimers]];
}

#pragma mark - Inputs from the driver

- (void)nearbyRouteChanged:(SZFriendsRouteMethod)route {
    [self perform:[_order otherRouteChanged:route]];
}

- (void)networkChanged {
    for (SZFriendsOnlineSlot *slot in _slots.allValues) [slot.portMapping networkDidChange];
    [self perform:[_order networkChanged]];
}

// The classifier measured this network: the order's hard-NAT decision uses the new class, and the friend hears it.
- (void)localNATClassChanged {
    if (_ended) return;
    [self perform:[_order localNATClassChanged:_context.natClass]];
    if (_session.established) [self sendItems:@[ [self natItem] ]];
}

- (void)close {
    if (_ended) return;
    [_order close];
    [self finish];
}

// Ends everything this attempt holds, says so to the friend when they heard from us, and leaves its log entry.
- (void)finish {
    if (_ended) return;
    [_order close];
    if (_session.established && _channel != nil && !_channel.ended) {
        NSData *end = [_session sealItems:@[ [SZFriendsSignalItem endWithReason:SZFriendsSignalEndDone] ] error:NULL];
        if (end != nil && (_role == SZFriendsOnlineRoleOfferer || _replied)) [_channel sendPayload:end];
    }
    _ended = YES;
    if (_timer) dispatch_source_cancel(_timer);
    _timer = nil;
    [_prober cancel];
    _prober = nil;
    for (SZFriendsOnlineSlot *slot in _slots.allValues) [self closeSlot:slot];
    [_channel close];
    _channel = nil;
    [_outgoing removeAllObjects];
    [_context appendLogEntry:_order.logEntry];
    [_owner attemptDidEnd:self];
}

@end
