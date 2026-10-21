// One attempt's signalling (SZFriendsOnlineAttemptInternal.h): IK message 1 carrying the offer, the answer in
// message 2, then Noise transport messages carrying descriptions, candidates, NAT classes and the order's signals,
// several items per payload so the host's 64 messages per sid go far (ADR 0010).
//
// Gating (lead decision 6): the offerer applies nothing remote until -readReply: has authenticated the friend; the
// answerer exists only once SZFriendsSignalingSession authenticated message 1 and the friend policy allowed it.

#import "service/online/driver/SZFriendsOnlineAttemptInternal.h"

#import "service/host/SZFriendsHostRendezvous.h"
#import "service/identity/SZFriendsIdentity.h"
#import "service/online/nat/SZFriendsNATPrediction.h"
#import "service/online/nat/SZFriendsNATProber.h"

// Remote items kept for a connection that cannot take them yet: a description's worth of candidates and more,
// never an unbounded queue a peer could fill.
static const NSUInteger kHeldItemsMax = 64;

@implementation SZFriendsOnlineSlot

- (instancetype)init {
    if ((self = [super init])) _remoteEndpoints = [NSMutableArray array];
    return self;
}

@end

@implementation SZFriendsOnlineAttempt

- (instancetype)initWithFriend:(SZFriendsOnlineFriend *)friend
                          role:(SZFriendsOnlineRole)role
                       context:(SZFriendsOnlineContext *)context
                         owner:(id<SZFriendsOnlineAttemptOwner>)owner {
    if ((self = [super init])) {
        _friend = friend;
        _role = role;
        _context = context;
        _owner = owner;
        _order = [[SZFriendsOnlineOrder alloc] initWithRole:role
                                                    purpose:SZFriendsOnlinePurposeFriend
                                                      clock:context.clock
                                                     random:context.random];
        _slots = [NSMutableDictionary dictionary];
        _held = [NSMutableDictionary dictionary];
        _offers = [NSMutableDictionary dictionary];
        _outgoing = [NSMutableArray array];
        _answerDeadline = INFINITY;
        _lastPhase = SZFriendsOnlinePhaseSignalling;
    }
    return self;
}

- (instancetype)initOffererWithFriend:(SZFriendsOnlineFriend *)friend
                              context:(SZFriendsOnlineContext *)context
                                owner:(id<SZFriendsOnlineAttemptOwner>)owner {
    return [self initWithFriend:friend role:SZFriendsOnlineRoleOfferer context:context owner:owner];
}

- (instancetype)initAnswererWithFriend:(SZFriendsOnlineFriend *)friend
                               session:(SZFriendsSignalingSession *)session
                               channel:(id<SZFriendsOnlineSignalChannel>)channel
                                 items:(NSArray<SZFriendsSignalItem *> *)items
                               context:(SZFriendsOnlineContext *)context
                                 owner:(id<SZFriendsOnlineAttemptOwner>)owner {
    if ((self = [self initWithFriend:friend role:SZFriendsOnlineRoleAnswerer context:context owner:owner])) {
        _session = session;
        _initialItems = [items copy];
        [self adoptChannel:channel];
    }
    return self;
}

- (NSData *)peerRoot {
    return _friend.rootKey.length == 32 ? _friend.rootKey : _friend.identityKey;
}

- (NSData *)peer {
    return _friend.identityKey;
}

- (SZFriendsOnlineRole)role {
    return _role;
}

- (SZFriendsOnlineOrder *)order {
    return _order;
}

- (BOOL)ended {
    return _ended;
}

- (BOOL)answered {
    return _answered;
}

- (BOOL)connected {
    return _connected;
}

- (SZFriendsRouteMethod)carriedRoute {
    switch (_order.phase) {
    case SZFriendsOnlinePhaseDirect: return SZFriendsRouteMethodInternet;
    case SZFriendsOnlinePhaseRelayed: return SZFriendsRouteMethodRelay;
    default: return SZFriendsRouteMethodNone;
    }
}

- (void)start {
    if (_role == SZFriendsOnlineRoleOfferer) {
        // The offer exists only to be sealed to the friend's static key in IK message 1 (gating rule 1).
        _answerDeadline = _context.clock() + SZFriendsOnlineAnswerTimeout;
        if ([self openSlotOfKind:SZFriendsOnlineConnectionDirect number:0 offer:nil relay:nil localPort:0] == nil) {
            [self finish];
            return;
        }
        _nextNumber = 1;
    } else {
        _answered = YES;
        NSArray<SZFriendsSignalItem *> *items = _initialItems;
        _initialItems = nil;
        [self applyItems:items ?: @[]];
    }
    [self armTimer];
}

#pragma mark - The sid

- (void)adoptChannel:(id<SZFriendsOnlineSignalChannel>)channel {
    [_channel close];
    _channel = channel;
    __weak SZFriendsOnlineAttempt *weakSelf = self;
    __weak id<SZFriendsOnlineSignalChannel> weakChannel = channel;
    channel.onPayload = ^(NSData *payload) {
        SZFriendsOnlineAttempt *strongSelf = weakSelf;
        if (strongSelf != nil && strongSelf->_channel == weakChannel) [strongSelf receivePayload:payload];
    };
    channel.onEnd = ^{
        SZFriendsOnlineAttempt *strongSelf = weakSelf;
        if (strongSelf != nil && strongSelf->_channel == weakChannel) [strongSelf channelEnded];
    };
}

// A sid ends after 120 s or 64 messages (ADR 0010), or when either end's host connection ends. Streams already open
// keep going; whatever must be said later goes in a new sid (-sendItems: opens one for the offerer; the answerer
// waits for the offerer's). An attempt that reached no stream has nothing left once its sid is gone: without one it
// could never ask for the relay, and would only keep the next offer either side makes from being answered. An offerer
// that was answered ends without a wait; the side whose connection ended asks again once it is back.
- (void)channelEnded {
    _channel = nil;
    if (!_connected) [self finish];
}

- (void)continueWithSession:(SZFriendsSignalingSession *)session
                    channel:(id<SZFriendsOnlineSignalChannel>)channel
                      items:(NSArray<SZFriendsSignalItem *> *)items {
    if (_ended || _role != SZFriendsOnlineRoleAnswerer) return;
    _session = session;
    _replied = NO;
    [self adoptChannel:channel];
    [self applyItems:items];
    // A new sid that carried no new description still needs IK message 2 for the offerer to send on it.
    if (!_replied) [self replyWithDescription:nil];
    [self armTimer];
}

- (SZFriendsSignalItem *)natItem {
    return [SZFriendsSignalItem natWithClass:(SZFriendsSignalNATClass)_context.natClass step:_context.natStep];
}

// Offerer: IK message 1 to the friend's rendezvous key, carrying `description` (and whatever else waits that fits).
- (void)openSidWithDescription:(SZFriendsSignalItem *)description {
    if (_opening || _ended) return;
    SZFriendsSignalingSession *session =
        [[SZFriendsSignalingSession alloc] initIKInitiatorWithIdentity:_context.identity
                                                       remoteStaticKey:_friend.staticKey
                                                   expectedIdentityKey:_friend.identityKey
                                                          requestToken:_friend.requestToken];
    NSMutableArray<SZFriendsSignalItem *> *items = [NSMutableArray arrayWithObject:[self natItem]];
    if (description != nil) [items insertObject:description atIndex:0];
    NSData *message = session ? [session openingMessageWithItems:items now:[NSDate date] error:NULL] : nil;
    if (message == nil) {
        [self finish];
        return;
    }
    _session = session;
    _opening = YES;
    _answered = _answered && description == nil; // a new sid must be answered again before it carries anything
    __weak SZFriendsOnlineAttempt *weakSelf = self;
    [_owner attempt:self
        openChannelWithPayload:message
                    completion:^(id<SZFriendsOnlineSignalChannel> channel) {
                        SZFriendsOnlineAttempt *strongSelf = weakSelf;
                        if (strongSelf == nil) {
                            [channel close];
                            return;
                        }
                        strongSelf->_opening = NO;
                        if (channel == nil || strongSelf->_ended) {
                            [channel close];
                            if (!strongSelf->_ended && !strongSelf->_connected) [strongSelf finish];
                            return;
                        }
                        [strongSelf adoptChannel:channel];
                        strongSelf->_answerDeadline = strongSelf->_context.clock() + SZFriendsOnlineAnswerTimeout;
                        [strongSelf armTimer];
                    }];
}

// Answerer: IK message 2, with this side's answer when there is one. The session is established after it.
- (void)replyWithDescription:(SZFriendsSignalItem *)description {
    NSMutableArray<SZFriendsSignalItem *> *items = [NSMutableArray arrayWithObject:[self natItem]];
    if (description != nil) [items insertObject:description atIndex:0];
    NSData *reply = [_session replyWithItems:items error:NULL];
    if (reply == nil || ![_channel sendPayload:reply]) {
        [self finish];
        return;
    }
    _replied = YES;
    [self flush];
}

#pragma mark - Sending

- (BOOL)canSend {
    return _session.established && _channel != nil && !_channel.ended &&
           (_role == SZFriendsOnlineRoleOfferer || _replied);
}

- (void)sendItems:(NSArray<SZFriendsSignalItem *> *)items {
    if (_ended || items.count == 0) return;
    [_outgoing addObjectsFromArray:items];
    if (_flushScheduled) return;
    _flushScheduled = YES;
    // Items gathered in one turn of the queue (a burst of candidates) go together in as few payloads as fit.
    __weak SZFriendsOnlineAttempt *weakSelf = self;
    dispatch_async(_context.queue, ^{
        SZFriendsOnlineAttempt *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf->_flushScheduled = NO;
        [strongSelf flush];
    });
}

- (void)flush {
    if (_ended || _outgoing.count == 0) return;
    if (![self canSend]) {
        // The offerer's sid ended with something still to say (a retry's offer): a new sid, answered again.
        BOOL lost = _session.established && (_channel == nil || _channel.ended);
        if (_role == SZFriendsOnlineRoleOfferer && lost && !_opening) [self reopenSid];
        return;
    }
    NSUInteger capacity = SZFriendsSignalPayloadMax - 16; // Noise's tag
    NSMutableArray<SZFriendsSignalItem *> *batch = [NSMutableArray array];
    while (_outgoing.count > 0) {
        SZFriendsSignalItem *next = _outgoing.firstObject;
        [batch addObject:next];
        if (SZFriendsEncodeSignalItems(batch, capacity, NULL) == nil) {
            [batch removeLastObject];
            if (batch.count == 0) {
                [_outgoing removeObjectAtIndex:0]; // one item too large on its own: never sendable
                continue;
            }
            if (![self sendBatch:batch]) return;
            [batch removeAllObjects];
            continue;
        }
        [_outgoing removeObjectAtIndex:0];
    }
    if (batch.count > 0) [self sendBatch:batch];
}

- (BOOL)sendBatch:(NSArray<SZFriendsSignalItem *> *)batch {
    NSData *payload = [_session sealItems:batch error:NULL];
    if (payload != nil && [_channel sendPayload:payload]) return YES;
    // The 65th payload, or an ended sid: what is left goes on the next sid.
    [_outgoing insertObjects:batch atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, batch.count)]];
    [_channel close];
    _channel = nil;
    if (_role == SZFriendsOnlineRoleOfferer) [self reopenSid];
    return NO;
}

// Offerer only: the newest description waiting goes in the new IK message 1; the rest follows once answered.
- (void)reopenSid {
    SZFriendsSignalItem *description = nil;
    for (SZFriendsSignalItem *item in _outgoing) {
        if (item.type == SZFriendsSignalItemDescription) description = item;
    }
    if (description == nil) return; // nothing new to offer: nothing needs a sid now
    [_outgoing removeObject:description];
    [self openSidWithDescription:description];
}

#pragma mark - Receiving

- (void)receivePayload:(NSData *)payload {
    if (_ended) return;
    NSArray<SZFriendsSignalItem *> *items = nil;
    if (_role == SZFriendsOnlineRoleOfferer && !_session.established) {
        // IK message 2: the friend proves its key here, and only then is anything remote applied.
        items = [_session readReply:payload error:NULL];
        if (items != nil) {
            _answered = YES;
            _answerDeadline = INFINITY;
        }
    } else {
        items = [_session openPayload:payload error:NULL];
    }
    if (items == nil) {
        // A payload that does not open here ends the exchange: nothing in it is trusted.
        [self finish];
        return;
    }
    [self applyItems:items];
    [self flush];
    [self armTimer];
}

- (void)holdItem:(SZFriendsSignalItem *)item number:(uint8_t)number {
    NSMutableArray<SZFriendsSignalItem *> *held = _held[@(number)];
    if (held == nil) _held[@(number)] = held = [NSMutableArray array];
    if (held.count < kHeldItemsMax) [held addObject:item];
}

- (void)applyHeldItemsForSlot:(SZFriendsOnlineSlot *)slot {
    NSArray<SZFriendsSignalItem *> *held = _held[@(slot.number)];
    [_held removeObjectForKey:@(slot.number)];
    if (held.count > 0) [self applyItems:held];
}

- (void)applyItems:(NSArray<SZFriendsSignalItem *> *)items {
    for (SZFriendsSignalItem *item in items) {
        if (_ended) return;
        uint64_t number = 0, kind = 0, technique = 0;
        [item getUnsigned:&number forTag:SZFriendsSignalTagConnection];
        [item getUnsigned:&kind forTag:SZFriendsSignalTagKind];
        SZFriendsOnlineSlot *slot = _slots[@(number)];
        switch (item.type) {
        case SZFriendsSignalItemDescription:
            [self applyDescription:item number:(uint8_t)number kind:(SZFriendsOnlineConnectionKind)kind];
            break;
        case SZFriendsSignalItemCandidate:
            [item getUnsigned:&technique forTag:SZFriendsSignalTagTechnique];
            if (technique == SZFriendsOnlineTechniqueProbeHandover) {
                // The easy prober's own address (ADR 0011 § Probing budget), never a candidate for any connection.
                SZFriendsNATCandidate *candidate =
                    [SZFriendsNATCandidate candidateWithLine:[item stringForTag:SZFriendsSignalTagCandidate] ?: @""];
                if (candidate != nil && !candidate.tcp) [self proberAddressArrived:candidate.endpoint];
            } else if (slot != nil && slot.remoteReady) {
                [self applyRemoteCandidate:item toSlot:slot];
            } else if (slot == nil || slot.connection != nil) {
                [self holdItem:item number:(uint8_t)number];
            }
            break;
        case SZFriendsSignalItemCandidatesEnd:
            if (slot != nil && slot.remoteReady) [slot.connection remoteCandidatesDidEnd];
            else [self holdItem:item number:(uint8_t)number];
            break;
        case SZFriendsSignalItemNAT:
            [self applyNAT:item];
            break;
        case SZFriendsSignalItemStart:
            [self applyStart:(SZFriendsOnlineConnectionKind)kind];
            break;
        case SZFriendsSignalItemEnd:
            // The friend's side of this attempt is over (a better route won, or they cancelled).
            [self finish];
            return;
        default:
            break; // Hello, Frame and link items mean nothing in a friends' attempt
        }
    }
}

- (void)applyDescription:(SZFriendsSignalItem *)item number:(uint8_t)number kind:(SZFriendsOnlineConnectionKind)kind {
    SZFriendsOnlineSlot *slot = _slots[@(number)];
    if (_role == SZFriendsOnlineRoleAnswerer) {
        if (slot == nil) [self answererOfferArrived:item number:number kind:kind];
        return;
    }
    if (slot == nil || slot.remoteReady || slot.connection == nil) return;
    NSString *sdp = [item stringForTag:SZFriendsSignalTagSDP];
    NSData *fingerprint = [item dataForTag:SZFriendsSignalTagFingerprint];
    // A failure here is reported by the connection itself (-onlineConnection:didFailWithError:) on the next turn.
    if (sdp == nil || ![slot.connection applyRemoteAnswerSDP:sdp remoteFingerprint:fingerprint ?: [NSData data]
                                                       error:NULL]) {
        return;
    }
    slot.remoteReady = YES;
    if (slot.kind == SZFriendsOnlineConnectionProbeHandover && _probeHit != nil) {
        [self applyProbeRemoteToSlot:slot];
    } else {
        [self applyHeldItemsForSlot:slot];
    }
    if (slot == _direct) {
        [self perform:[_order descriptionsAppliedWithLocalNATClass:_context.natClass remoteNATClass:_remoteNAT]];
    }
}

// The probe handover connection's only remote candidate is the pair the prober found (ADR 0011), which the prober
// accepted only with this attempt's signalling credentials.
- (void)applyProbeRemoteToSlot:(SZFriendsOnlineSlot *)slot {
    NSString *line = SZFriendsNATCandidateLine(_probeHit.remote, SZFriendsNATCandidateTypeHost, NO, 65535);
    [slot.connection addRemoteCandidate:line technique:SZFriendsOnlineTechniqueProbeHandover error:NULL];
    [slot.connection remoteCandidatesDidEnd];
    [_held removeObjectForKey:@(slot.number)];
}

- (void)applyNAT:(SZFriendsSignalItem *)item {
    uint64_t natClass = 0;
    if (![item getUnsigned:&natClass forTag:SZFriendsSignalTagNATClass] || natClass > SZFriendsNATClassPerDestination) {
        return;
    }
    _remoteNAT = (SZFriendsNATClass)natClass;
    _remoteStep = natClass == SZFriendsNATClassPerDestination ? item.natStep : 0;
    // A class measured after the descriptions: the order's hard-NAT decision at the end of the plain checks uses it.
    if (_order.phase == SZFriendsOnlinePhasePlainChecks) {
        [_order descriptionsAppliedWithLocalNATClass:_context.natClass remoteNATClass:_remoteNAT];
    }
    [self predictIfPossible];
}

// Start from the offerer: its hard-NAT step began. Start(direct) from the answerer: its network changed, so the
// offerer tries direct again (the order's SignalNetworkChange; the signalling has no item of its own for it yet).
- (void)applyStart:(SZFriendsOnlineConnectionKind)kind {
    if (_role == SZFriendsOnlineRoleAnswerer && kind == SZFriendsOnlineConnectionProbeHandover) {
        [self perform:[_order peerStartedHardNAT]];
    } else if (_role == SZFriendsOnlineRoleOfferer && kind == SZFriendsOnlineConnectionDirect) {
        [self perform:[_order peerNetworkChanged]];
    }
}

@end
