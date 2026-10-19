// Hard-NAT probing (SZFriendsNATProber.h).

#import "service/online/nat/SZFriendsNATProber.h"

#import "service/online/nat/SZFriendsNATProbeSocket.h"
#import "service/online/nat/SZFriendsNATStun.h"

#include <errno.h>

enum {
    kAnswersMax = 64,      // Binding answers a run sends at most: only the authenticated peer can ask for one
    kTriggeredMax = 8,     // the easy side's requests back to hard-side sockets that reached it
    kTriggeredSends = 5,   // each such request, and the nomination, sent at most this often, 100 ms apart
    kHardSocketsMin = 16,  // fewer than this and the odds are not worth the packets
};

static NSError *ProbeError(SZFriendsNATError code) {
    return [NSError errorWithDomain:SZFriendsNATErrorDomain code:code userInfo:nil];
}

@interface SZFriendsNATProbeHit ()
- (instancetype)initWithLocalPort:(uint16_t)localPort
                           remote:(SZFriendsNATEndpoint *)remote
                       probesSent:(NSUInteger)probesSent;
@end

@implementation SZFriendsNATProber {
    SZFriendsNATProberConfiguration *_configuration;
    dispatch_queue_t _queue;
    NSMutableArray<SZFriendsNATProbeSocket *> *_sockets;
    NSMutableDictionary<NSData *, SZFriendsNATEndpoint *> *_transactions; // our requests: transaction -> destination
    NSMutableIndexSet *_probedPorts;
    NSMutableArray<dispatch_source_t> *_timers;
    dispatch_group_t _openDescriptors; // one entry per socket until its cancel handler has closed it
    dispatch_source_t _probeTimer;
    NSData *_localKey, *_remoteKey;
    NSString *_requestUsername, *_expectedUsername;
    SZFriendsNATProbeSocket *_winner;
    SZFriendsNATEndpoint *_winnerRemote, *_stunServer;
    uint8_t _stunTransaction[SZFriendsStunTransactionLength];
    NSUInteger _answers, _triggered;
    NSMutableSet<SZFriendsNATEndpoint *> *_triggeredRemotes;
    NSMutableSet<NSData *> *_nominations;
    BOOL _nominationAnswered;
    void (^_completion)(SZFriendsNATProbeHit *, NSError *);
    void (^_prepareCompletion)(SZFriendsNATEndpoint *, NSError *);
    BOOL _started, _holdsBudget, _finished;
}

- (instancetype)initWithConfiguration:(SZFriendsNATProberConfiguration *)configuration {
    if ((self = [super init])) {
        _configuration = [configuration copy];
        _sockets = [NSMutableArray array];
        _transactions = [NSMutableDictionary dictionary];
        _probedPorts = [NSMutableIndexSet indexSet];
        _triggeredRemotes = [NSMutableSet set];
        _nominations = [NSMutableSet set];
        _timers = [NSMutableArray array];
        _openDescriptors = dispatch_group_create();
        _localKey = [configuration.localPassword dataUsingEncoding:NSUTF8StringEncoding];
        _remoteKey = [configuration.remotePassword dataUsingEncoding:NSUTF8StringEncoding];
        // A request carries "<receiver's ufrag>:<sender's ufrag>" (RFC 8445 § 7.2.2).
        _requestUsername = [NSString stringWithFormat:@"%@:%@", configuration.remoteUfrag, configuration.localUfrag];
        _expectedUsername = [NSString stringWithFormat:@"%@:%@", configuration.localUfrag, configuration.remoteUfrag];
    }
    return self;
}

- (void)dealloc {
    [self closeSocketsExcept:nil];
}

// Whether the peer itself named `remote` in this attempt: the hard side aims at exactly an endpoint the easy side
// presented, the easy side at an address the hard side presented (on random ports, by design).
- (BOOL)remoteWasPresented {
    SZFriendsNATEndpoint *remote = _configuration.remote;
    BOOL hard = _configuration.role == SZFriendsNATProbeRoleHard;
    for (SZFriendsNATEndpoint *presented in _configuration.presented) {
        if (hard ? [presented isEqual:remote] : [presented hasSameAddressAs:remote]) return YES;
    }
    return NO;
}

- (BOOL)allowsAddress:(SZFriendsNATEndpoint *)endpoint {
    if (endpoint == nil) return NO;
    if (_configuration.loopbackOnly) return SZFriendsNATLoopbackOnlyAllows(endpoint);
    if (endpoint.scope != SZFriendsNATAddressScopeGlobal) return NO;
    for (SZFriendsNATEndpoint *own in SZFriendsNATOwnAddresses()) {
        if ([own hasSameAddressAs:endpoint]) return NO;
    }
    return YES;
}

#pragma mark Sockets

- (SZFriendsNATProbeSocket *)openSocketOnPort:(uint16_t)port {
    __weak SZFriendsNATProber *weakSelf = self;
    SZFriendsNATProbeSocket *probeSocket =
        [SZFriendsNATProbeSocket socketWithFamily:_configuration.remote.family
                                     loopbackOnly:_configuration.loopbackOnly
                                             port:port
                                            queue:_queue
                                  openDescriptors:_openDescriptors
                                         readable:^(SZFriendsNATProbeSocket *readable) {
                                             [weakSelf readFrom:readable];
                                         }];
    if (probeSocket != nil) [_sockets addObject:probeSocket];
    return probeSocket;
}

- (void)closeSocketsExcept:(SZFriendsNATProbeSocket *)keep {
    for (SZFriendsNATProbeSocket *probeSocket in [_sockets copy]) {
        if (probeSocket == keep) continue;
        [probeSocket close];
        [_sockets removeObject:probeSocket];
    }
}

// A Binding request under our credentials, remembered so only its answer counts; nominating, it carries
// USE-CANDIDATE.
- (void)sendRequestFrom:(SZFriendsNATProbeSocket *)probeSocket
                     to:(SZFriendsNATEndpoint *)destination
             nominating:(BOOL)nominating {
    uint8_t transaction[SZFriendsStunTransactionLength], bytes[128];
    SZFriendsStunRandomTransaction(transaction);
    const char *username = _requestUsername.UTF8String;
    size_t length = nominating ? SZFriendsStunWriteNominatingRequest(bytes, sizeof bytes, transaction, username,
                                                                     _remoteKey.bytes, _remoteKey.length)
                               : SZFriendsStunWriteBindingRequest(bytes, sizeof bytes, transaction, username,
                                                                  _remoteKey.bytes, _remoteKey.length);
    NSData *key = [NSData dataWithBytes:transaction length:sizeof transaction];
    _transactions[key] = destination;
    if (nominating) [_nominations addObject:key];
    [probeSocket sendBytes:bytes length:length to:destination];
}

- (dispatch_source_t)timerAfter:(NSTimeInterval)delay repeat:(NSTimeInterval)interval handler:(dispatch_block_t)block {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              interval > 0 ? (uint64_t)(interval * NSEC_PER_SEC) : DISPATCH_TIME_FOREVER,
                              (uint64_t)(0.001 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, block);
    dispatch_resume(timer);
    [_timers addObject:timer];
    return timer;
}

#pragma mark Preparing (easy side)

- (void)prepareOnQueue:(dispatch_queue_t)queue
            completion:(void (^)(SZFriendsNATEndpoint *, NSError *))completion {
    if (_queue != nil || _configuration.role != SZFriendsNATProbeRoleEasy) {
        dispatch_async(queue, ^{
            completion(nil, ProbeError(SZFriendsNATErrorUnsupported));
        });
        return;
    }
    _queue = queue;
    SZFriendsNATProbeSocket *probeSocket = [self openSocketOnPort:0];
    SZFriendsNATEndpoint *server = _configuration.stunServer;
    BOOL serverAllowed = server == nil || ([self allowsServer:server] && server.family == _configuration.remote.family);
    if (probeSocket == nil || !serverAllowed) {
        SZFriendsNATError code = probeSocket == nil ? SZFriendsNATErrorSocket : SZFriendsNATErrorAddressRefused;
        dispatch_async(queue, ^{
            completion(nil, ProbeError(code));
        });
        return;
    }
    if (server == nil) {
        // Loopback tests: no NAT, so the socket's own address is its public one.
        NSString *loopback = _configuration.remote.family == AF_INET6 ? @"::1" : @"127.0.0.1";
        SZFriendsNATEndpoint *own = [SZFriendsNATEndpoint endpointWithHost:loopback port:probeSocket.port];
        dispatch_async(queue, ^{
            completion(_configuration.loopbackOnly ? own : nil,
                       _configuration.loopbackOnly ? nil : ProbeError(SZFriendsNATErrorUnsupported));
        });
        return;
    }
    _stunServer = server;
    _prepareCompletion = [completion copy];
    SZFriendsStunRandomTransaction(_stunTransaction);
    __weak SZFriendsNATProber *weakSelf = self;
    for (NSNumber *delay in @[ @0, @0.25, @0.75 ]) {
        [self timerAfter:delay.doubleValue repeat:0 handler:^{
            [weakSelf sendStunRequest];
        }];
    }
    [self timerAfter:1.5 repeat:0 handler:^{
        [weakSelf finishPreparing:nil];
    }];
}

- (BOOL)allowsServer:(SZFriendsNATEndpoint *)server {
    return _configuration.loopbackOnly ? SZFriendsNATLoopbackOnlyAllows(server)
                                       : server.scope == SZFriendsNATAddressScopeGlobal;
}

- (void)sendStunRequest {
    if (_prepareCompletion == nil || _sockets.count == 0) return;
    uint8_t bytes[64];
    size_t length = SZFriendsStunWriteBindingRequest(bytes, sizeof bytes, _stunTransaction, NULL, NULL, 0);
    [_sockets.firstObject sendBytes:bytes length:length to:_stunServer];
}

- (void)finishPreparing:(SZFriendsNATEndpoint *)reflexive {
    void (^completion)(SZFriendsNATEndpoint *, NSError *) = _prepareCompletion;
    if (completion == nil) return;
    _prepareCompletion = nil;
    for (dispatch_source_t timer in _timers) dispatch_source_cancel(timer);
    [_timers removeAllObjects];
    completion(reflexive, reflexive != nil ? nil : ProbeError(SZFriendsNATErrorTimedOut));
}

#pragma mark Probing

- (void)startOnQueue:(dispatch_queue_t)queue
          completion:(void (^)(SZFriendsNATProbeHit *, NSError *))completion {
    if (_started) return;
    _started = YES;
    if (_queue == nil) _queue = queue;
    _completion = [completion copy];
    __weak SZFriendsNATProber *weakSelf = self;
    dispatch_async(_queue, ^{
        [weakSelf begin];
    });
}

- (void)begin {
    if (_finished) return;
    [self finishPreparing:nil];
    if (!_configuration.valid || ![self allowsAddress:_configuration.remote] || ![self remoteWasPresented]) {
        SZFriendsNATError code = _configuration.valid ? SZFriendsNATErrorAddressRefused : SZFriendsNATErrorUnsupported;
        [self finishWithHit:nil error:ProbeError(code)];
        return;
    }
    if (![_configuration.budget beginRunForPeer:_configuration.peer]) {
        [self finishWithHit:nil error:ProbeError(SZFriendsNATErrorBudget)];
        return;
    }
    _holdsBudget = YES;
    __weak SZFriendsNATProber *weakSelf = self;
    [self timerAfter:_configuration.duration repeat:0 handler:^{
        [weakSelf finishWithHit:nil error:ProbeError(SZFriendsNATErrorTimedOut)];
    }];
    if (_configuration.role == SZFriendsNATProbeRoleHard) {
        [self beginHard];
    } else {
        if (_sockets.count == 0 && [self openSocketOnPort:0] == nil) {
            [self finishWithHit:nil error:ProbeError(SZFriendsNATErrorSocket)];
            return;
        }
        NSTimeInterval interval = 1.0 / SZFriendsNATProbesPerSecond;
        _probeTimer = [self timerAfter:0 repeat:interval handler:^{
            [weakSelf sendRandomProbe];
        }];
    }
}

- (void)beginHard {
    [SZFriendsNATProbeSocket raiseFileLimit];
    NSArray<NSNumber *> *ports = _configuration.localPorts;
    NSUInteger count = ports != nil ? MIN(ports.count, _configuration.socketCount) : _configuration.socketCount;
    for (NSUInteger i = 0; i < count; i++) {
        SZFriendsNATProbeSocket *probeSocket = [self openSocketOnPort:ports != nil ? ports[i].unsignedShortValue : 0];
        if (probeSocket == nil && errno == EMFILE) break;
    }
    if (_sockets.count < MIN((NSUInteger)kHardSocketsMin, count)) {
        [self finishWithHit:nil error:ProbeError(SZFriendsNATErrorSocket)];
        return;
    }
    // One probe from each socket opens one mapping on this side's NAT toward the easy side.
    for (SZFriendsNATProbeSocket *probeSocket in [_sockets copy]) {
        [self sendRequestFrom:probeSocket to:_configuration.remote nominating:NO];
        _probesSent++;
    }
}

- (void)sendRandomProbe {
    NSUInteger range = (NSUInteger)_configuration.portRangeHigh - _configuration.portRangeLow + 1;
    if (_winner != nil || _probesSent >= _configuration.probeMax || _probedPorts.count >= range) {
        if (_probeTimer != nil) dispatch_source_cancel(_probeTimer);
        _probeTimer = nil;
        return;
    }
    NSUInteger port;
    do {
        port = _configuration.portRangeLow + arc4random_uniform((uint32_t)range);
    } while ([_probedPorts containsIndex:port]);
    [_probedPorts addIndex:port];
    [self sendRequestFrom:_sockets.firstObject
                       to:[_configuration.remote endpointWithPort:(uint16_t)port]
               nominating:NO];
    _probesSent++;
}

- (void)readFrom:(SZFriendsNATProbeSocket *)probeSocket {
    for (;;) {
        uint8_t buffer[SZFriendsStunMessageMax + 1];
        struct sockaddr_storage from;
        socklen_t fromLength = sizeof from;
        ssize_t received = recvfrom(probeSocket.fd, buffer, sizeof buffer, 0, (struct sockaddr *)&from, &fromLength);
        if (received < 0) return;
        SZFriendsNATEndpoint *source = [SZFriendsNATEndpoint endpointWithSockaddr:(struct sockaddr *)&from
                                                                          length:fromLength];
        SZFriendsStunMessage message;
        if (source == nil || !SZFriendsStunParse(buffer, (size_t)received, &message)) continue;
        if (_prepareCompletion != nil) {
            if (message.type == SZFriendsStunTypeBindingSuccess && message.hasMappedAddress &&
                [source isEqual:_stunServer] &&
                memcmp(message.transaction, _stunTransaction, sizeof _stunTransaction) == 0) {
                const struct sockaddr *mapped = (const struct sockaddr *)&message.mappedAddress;
                [self finishPreparing:[SZFriendsNATEndpoint endpointWithSockaddr:mapped
                                                                          length:message.mappedAddressLength]];
            }
            continue;
        }
        if (!_started || _finished || ![source hasSameAddressAs:_configuration.remote]) continue;
        if (message.type == SZFriendsStunTypeBindingRequest) {
            [self handleRequest:&message bytes:buffer length:(size_t)received on:probeSocket from:source];
        } else if (message.type == SZFriendsStunTypeBindingSuccess) {
            [self handleAnswer:&message bytes:buffer length:(size_t)received on:probeSocket from:source];
        }
    }
}

- (void)handleRequest:(const SZFriendsStunMessage *)message
                bytes:(const uint8_t *)bytes
               length:(size_t)length
                   on:(SZFriendsNATProbeSocket *)probeSocket
                 from:(SZFriendsNATEndpoint *)source {
    NSData *username = [_expectedUsername dataUsingEncoding:NSUTF8StringEncoding];
    if (message->username == NULL || message->usernameLength != username.length ||
        memcmp(message->username, username.bytes, username.length) != 0) {
        return;
    }
    if (!SZFriendsStunCheckIntegrity(bytes, length, message, _localKey.bytes, _localKey.length)) return;
    if ((_winner != nil && (probeSocket != _winner || ![source isEqual:_winnerRemote])) || _answers >= kAnswersMax) {
        return;
    }
    uint8_t answer[128];
    struct sockaddr_storage storage;
    [source getSockaddr:&storage];
    size_t answerLength = SZFriendsStunWriteBindingSuccess(answer, sizeof answer, message->transaction,
                                                           (struct sockaddr *)&storage, _localKey.bytes,
                                                           _localKey.length);
    [probeSocket sendBytes:answer length:answerLength to:source];
    _answers++;
    if (_configuration.role == SZFriendsNATProbeRoleHard) {
        // The easy side chose this pair: it is the hard side's hit.
        if (message->useCandidate && _winner == nil) [self selectSocket:probeSocket remote:source];
        return;
    }
    // Easy side: a request from one of the hard side's sockets shows a mapping that reaches us; ask back through it,
    // so its answer (if the NAT lets it through) selects the pair.
    if (_winner != nil || _triggered >= kTriggeredMax || [_triggeredRemotes containsObject:source]) return;
    [_triggeredRemotes addObject:source];
    _triggered++;
    [self repeat:kTriggeredSends request:NO from:probeSocket to:source];
}

// Sends a request `count` times 100 ms apart from `probeSocket`, until a pair is selected (or, for a nomination,
// until it is answered or the run ends).
- (void)repeat:(NSUInteger)count
       request:(BOOL)nominating
          from:(SZFriendsNATProbeSocket *)probeSocket
            to:(SZFriendsNATEndpoint *)destination {
    __block NSUInteger sends = 0;
    __weak SZFriendsNATProber *weakSelf = self;
    __weak SZFriendsNATProbeSocket *weakSocket = probeSocket;
    __block dispatch_source_t timer = [self timerAfter:0 repeat:0.1 handler:^{
        SZFriendsNATProber *strongSelf = weakSelf;
        SZFriendsNATProbeSocket *strongSocket = weakSocket;
        BOOL stale = strongSelf == nil || (nominating ? strongSelf->_nominationAnswered : strongSelf->_winner != nil);
        if (stale || strongSocket == nil || sends >= count || strongSelf->_finished) {
            dispatch_source_cancel(timer);
            return;
        }
        sends++;
        [strongSelf sendRequestFrom:strongSocket to:destination nominating:nominating];
    }];
}

- (void)handleAnswer:(const SZFriendsStunMessage *)message
               bytes:(const uint8_t *)bytes
              length:(size_t)length
                  on:(SZFriendsNATProbeSocket *)probeSocket
                from:(SZFriendsNATEndpoint *)source {
    NSData *transaction = [NSData dataWithBytes:message->transaction length:SZFriendsStunTransactionLength];
    SZFriendsNATEndpoint *destination = _transactions[transaction];
    if (destination == nil || ![destination isEqual:source]) return;
    if (!SZFriendsStunCheckIntegrity(bytes, length, message, _remoteKey.bytes, _remoteKey.length)) return;
    if (_configuration.role != SZFriendsNATProbeRoleEasy) return; // the hard side's hit is the nomination
    if (_winner == nil) {
        // The first pair whose check came back is the one (ICE's controlling side): nominate it.
        [self selectSocket:probeSocket remote:source];
        [self repeat:kTriggeredSends request:YES from:probeSocket to:source];
    } else if ([_nominations containsObject:transaction]) {
        _nominationAnswered = YES; // the hard side has it too: no need to linger
        [self finishWithHit:[self hit] error:nil];
    }
}

- (SZFriendsNATProbeHit *)hit {
    return [[SZFriendsNATProbeHit alloc] initWithLocalPort:_winner.port remote:_winnerRemote probesSent:_probesSent];
}

// Stops probing, keeps only the winning socket, and reports the pair after the linger.
- (void)selectSocket:(SZFriendsNATProbeSocket *)probeSocket remote:(SZFriendsNATEndpoint *)remote {
    _winner = probeSocket;
    _winnerRemote = remote;
    if (_probeTimer != nil) dispatch_source_cancel(_probeTimer);
    _probeTimer = nil;
    [self closeSocketsExcept:probeSocket];
    __weak SZFriendsNATProber *weakSelf = self;
    [self timerAfter:_configuration.linger repeat:0 handler:^{
        SZFriendsNATProber *strongSelf = weakSelf;
        if (strongSelf != nil) [strongSelf finishWithHit:[strongSelf hit] error:nil];
    }];
}

- (void)finishWithHit:(SZFriendsNATProbeHit *)hit error:(NSError *)error {
    if (_finished) return;
    _finished = YES;
    for (dispatch_source_t timer in _timers) dispatch_source_cancel(timer);
    [_timers removeAllObjects];
    _probeTimer = nil;
    [self closeSocketsExcept:nil];
    if (_holdsBudget) [_configuration.budget endRun];
    _holdsBudget = NO;
    void (^completion)(SZFriendsNATProbeHit *, NSError *) = _completion;
    _completion = nil;
    if (completion == nil) return;
    // Reported once every cancel handler has closed its descriptor, so the caller can bind the winning port at once
    // (the probe handover connection does).
    dispatch_group_notify(_openDescriptors, _queue, ^{
        completion(hit, error);
    });
}

- (void)cancel {
    if (_queue == nil) {
        _finished = YES;
        return;
    }
    __weak SZFriendsNATProber *weakSelf = self;
    dispatch_async(_queue, ^{
        [weakSelf finishPreparing:nil];
        [weakSelf finishWithHit:nil error:ProbeError(SZFriendsNATErrorCancelled)];
    });
}

@end
