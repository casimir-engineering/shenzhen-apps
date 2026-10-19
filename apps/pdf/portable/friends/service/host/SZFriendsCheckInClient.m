// The check-in client (ADR 0005 § Check-in): one connection to the highest-priority reachable rendezvous host,
// a signed check-in that reserves the Friends ID, collision renames, host-list updates, reconnection with
// jittered backoff, and the signed release behind Reset Friends. Every answer that changes the Friends ID must
// carry the host's signature (SZFriendsHostReply.m). Everything runs on the client's queue; a socket generation
// counter discards callbacks from sockets the client already gave up on.

#import "service/host/SZFriendsCheckInClientPrivate.h"
#import "service/host/SZFriendsHostInternal.h"
#import "service/host/SZFriendsHostRendezvousInternal.h"
#import "service/identity/SZFriendsIdentity.h"

#import <os/log.h>

// 2: online Friends (HOST-PROTOCOL-ONLINE.md), sent only once a welcome says the host takes them. 3: a device checks
// in with its own key for its person's root, with the device chain as proof (HOST-PROTOCOL.md § Devices).
const NSInteger SZFriendsHostProtocolVersion = 3;

void SZFriendsHostCancelTimer(dispatch_source_t __strong *timer) {
    if (*timer) dispatch_source_cancel(*timer);
    *timer = nil;
}

@implementation SZFriendsHostCandidate
@end

@implementation SZFriendsCheckInClient

- (instancetype)initWithListCache:(SZFriendsHostListCache *)cache
                         identity:(SZFriendsIdentity *)identity
                       appVersion:(NSString *)appVersion
                    socketFactory:(SZFriendsHostSocketFactory)socketFactory
                            queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _cache = cache;
        _identity = identity;
        _appVersion = [appVersion copy];
        _factory = [socketFactory copy];
        _queue = queue;
        _state = SZFriendsHostStateStopped;
        _connectTimeout = 10;
        _releaseTimeout = 5;
        _watchesNetworkPath = YES;
        _drawsIDs = YES;
        _attestationPath = [cache.cachePath.stringByDeletingLastPathComponent
            stringByAppendingPathComponent:@"host-attestation.json"];
    }
    return self;
}

- (void)dealloc {
    [self tearDown];
    if (_pathMonitor) nw_path_monitor_cancel(_pathMonitor);
}

- (SZFriendsHostState)state {
    return _state;
}

- (NSUInteger)reconnectAttempt {
    return _attempt;
}

- (NSUInteger)drawsThisLaunch {
    return _draws;
}

- (nullable NSData *)personKey {
    return _personKey;
}

- (void)setState:(SZFriendsHostState)state {
    if (_state == state) return;
    _state = state;
    [self.delegate checkInStateDidChange:state];
}

+ (NSTimeInterval)backoffForAttempt:(NSUInteger)attempt jitter:(double)jitter {
    double cap = attempt >= 9 ? 300 : MIN(300.0, (double)(1u << attempt));
    double clamped = MAX(0.0, MIN(jitter, 1.0));
    return 1.0 + clamped * (cap - 1.0);
}

- (dispatch_source_t)timerAfter:(NSTimeInterval)delay handler:(void (^)(SZFriendsCheckInClient *client))handler {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 20);
    __weak SZFriendsCheckInClient *weakSelf = self;
    __weak dispatch_source_t weakTimer = timer;
    dispatch_source_set_event_handler(timer, ^{
        dispatch_source_t strongTimer = weakTimer;
        if (strongTimer) dispatch_source_cancel(strongTimer);
        SZFriendsCheckInClient *client = weakSelf;
        if (client) handler(client);
    });
    dispatch_resume(timer);
    return timer;
}

#pragma mark - Lifecycle

- (void)startWithFriendsIDProvider:(NSString * (^)(NSUInteger collisionsInARow))idProvider {
    SZFriendsIDProvider provider = [idProvider copy];
    dispatch_async(_queue, ^{
        if (self->_running || self->_releaseCompletion) return;
        self->_running = YES;
        self->_idProvider = provider;
        self->_attempt = 0;
        self->_draws = 0;
        if (self->_idCodec == nil) {
            SZFriendsWordList *words = [SZFriendsWordList bundledList];
            if (words) self->_idCodec = [[SZFriendsIDCodec alloc] initWithWordList:words];
        }
        [self startPathMonitor];
        [self beginRound];
    });
}

- (void)stop {
    dispatch_async(_queue, ^{
        self->_running = NO;
        [self tearDown];
        if (!self->_releaseCompletion) [self setState:SZFriendsHostStateStopped];
    });
}

- (void)tearDown {
    SZFriendsHostCancelTimer(&_connectTimer);
    SZFriendsHostCancelTimer(&_retryTimer);
    SZFriendsHostCancelTimer(&_reserveTimer);
    if (!_releaseCompletion) [self closeSocket];
    if (_pathMonitor && !_running) {
        nw_path_monitor_cancel(_pathMonitor);
        _pathMonitor = nil;
    }
}

- (void)closeSocket {
    _generation += 1; // late callbacks from this socket are ignored from here on
    [_socket close];
    _socket = nil;
    _phase = SZFriendsCheckInPhaseIdle;
    _challenge = nil;
    SZFriendsHostCancelTimer(&_connectTimer);
    [_online connectionDidClose];
}

- (void)startPathMonitor {
    if (!_watchesNetworkPath || _pathMonitor) return;
    _pathMonitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(_pathMonitor, _queue);
    __weak SZFriendsCheckInClient *weakSelf = self;
    nw_path_monitor_set_update_handler(_pathMonitor, ^(nw_path_t path) {
        if (nw_path_get_status(path) == nw_path_status_satisfied) [weakSelf networkDidChange];
    });
    nw_path_monitor_start(_pathMonitor);
}

- (void)networkDidChange {
    dispatch_async(_queue, ^{
        if (!self->_running || self->_releaseCompletion || self->_retryTimer == nil) return;
        SZFriendsHostCancelTimer(&self->_retryTimer);
        self->_attempt = 0;
        [self beginRound];
    });
}

#pragma mark - Connecting

// Every wss:// URL of every rendezvous host, in priority order: the main host first, replicas after it.
- (NSArray<SZFriendsHostCandidate *> *)candidatesFromList:(SZFriendsHostList *)list {
    NSMutableArray<SZFriendsHostCandidate *> *candidates = [NSMutableArray array];
    for (SZFriendsHostEntry *entry in list.entries) {
        if ((entry.roles & SZFriendsHostRoleRendezvous) == 0) continue;
        for (NSURL *url in entry.urls) {
            SZFriendsHostCandidate *candidate = [[SZFriendsHostCandidate alloc] init];
            candidate.entry = entry;
            candidate.url = url;
            [candidates addObject:candidate];
        }
    }
    return candidates;
}

- (void)beginRound {
    if (!_running && !_releaseCompletion) return;
    _candidates = [self candidatesFromList:_cache.currentList];
    _candidateIndex = 0;
    [self connectCandidate];
}

- (void)connectCandidate {
    if (_candidateIndex >= _candidates.count) {
        if (_releaseCompletion) {
            [self finishRelease:NO]; // no host answered
            return;
        }
        // Every host failed: stay quiet and try again later. Nearby is unaffected.
        [self setState:SZFriendsHostStateUnreachable];
        [self scheduleRetry];
        return;
    }
    // From Unreachable the state stays put until a check-in succeeds, so retries do not flicker.
    if (!_releaseCompletion && _state != SZFriendsHostStateUnreachable) [self setState:SZFriendsHostStateConnecting];
    SZFriendsHostCandidate *candidate = _candidates[_candidateIndex];
    [self closeSocket];
    NSUInteger generation = _generation;
    id<SZFriendsHostSocket> socket = _factory(candidate.url);
    _socket = socket;
    _phase = SZFriendsCheckInPhaseOpening;
    __weak SZFriendsCheckInClient *weakSelf = self;
    dispatch_queue_t queue = _queue;
    // Nothing to do on open: the host speaks first, with its challenge.
    socket.onMessage = ^(NSData *message) {
        dispatch_async(queue, ^{
            SZFriendsCheckInClient *client = weakSelf;
            if (client && client->_generation == generation) [client receive:message];
        });
    };
    socket.onClose = ^(NSError *error) {
        dispatch_async(queue, ^{
            SZFriendsCheckInClient *client = weakSelf;
            if (client && client->_generation == generation) [client socketClosed:error];
        });
    };
    _connectTimer = [self timerAfter:_connectTimeout
                             handler:^(SZFriendsCheckInClient *client) {
                                 if (client->_generation == generation) [client candidateFailed];
                             }];
    [socket open];
}

- (void)candidateFailed {
    [self closeSocket];
    _candidateIndex += 1;
    [self connectCandidate];
}

- (void)scheduleRetry {
    NSTimeInterval delay = [SZFriendsCheckInClient backoffForAttempt:_attempt jitter:arc4random() / 4294967296.0];
    _attempt += 1;
    SZFriendsHostCancelTimer(&_retryTimer);
    _retryTimer = [self timerAfter:delay
                           handler:^(SZFriendsCheckInClient *client) {
                               client->_retryTimer = nil;
                               [client beginRound];
                           }];
}

- (void)socketClosed:(NSError *)error {
    SZFriendsCheckInPhase phase = _phase;
    _socket = nil;
    [self closeSocket];
    SZFriendsHostCancelTimer(&_reserveTimer);
    if ([error.domain isEqualToString:SZFriendsHostErrorDomain] && error.code == SZFriendsHostCloseDeviceRevoked &&
        !_releaseCompletion) {
        [self deviceWasRevoked];
        return;
    }
    if (_releaseCompletion || phase < SZFriendsCheckInPhaseCheckedIn) {
        // Before a welcome (or a release answer), a close means this host did not work out: try the next one.
        _candidateIndex += 1;
        [self connectCandidate];
        return;
    }
    if (!_running) return;
    os_log_info(OS_LOG_DEFAULT, "Friends: host connection closed (%{public}ld)", (long)error.code);
    [self setState:SZFriendsHostStateConnecting];
    [self scheduleRetry];
}

// Another of the person's devices removed this one (close 4002, or the error before it): no host will take it again,
// so nothing more is tried.
- (void)deviceWasRevoked {
    if (!_running) return;
    os_log_info(OS_LOG_DEFAULT, "Friends: the host says this device was removed from its profile");
    _running = NO;
    [self tearDown];
    [self setState:SZFriendsHostStateStopped];
    id<SZFriendsCheckInDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(checkInDeviceWasRevoked)]) [delegate checkInDeviceWasRevoked];
}

- (void)send:(NSString *)type fields:(NSDictionary<NSString *, id> *)fields {
    NSData *message = SZFriendsHostEncodeMessage(type, fields);
    if (message) [_socket sendMessage:message];
}

#pragma mark - Messages

- (void)receive:(NSData *)data {
    NSDictionary<NSString *, id> *message = SZFriendsHostDecodeMessage(data);
    NSString *type = message[@"type"];
    if ([type isEqualToString:@"challenge"]) {
        [self receiveChallenge:message];
    } else if ([type isEqualToString:@"welcome"] && _phase == SZFriendsCheckInPhaseCheckingIn) {
        [self receiveWelcome:message];
    } else if ([type isEqualToString:@"reserve_result"] && _phase == SZFriendsCheckInPhaseCheckedIn) {
        BOOL verified = [self verifies:message body:SZFriendsHostReserveResultBody(_pendingID, message)];
        [self handleReservation:verified ? message[@"reservation"] : @"unavailable"
                      friendsID:message[@"friends_id"]
                    attestation:message[@"attestation"]
                      adoptable:NO];
    } else if ([type isEqualToString:@"host_list"]) {
        [self offerList:message[@"host_list"]];
    } else if ([type isEqualToString:@"released"] && _phase == SZFriendsCheckInPhaseReleasing) {
        // An unsigned "released" proves nothing; the reset goes ahead either way, reported as unconfirmed.
        BOOL verified = [self verifies:message body:SZFriendsHostReleasedBody(message)];
        [self finishRelease:verified && [message[@"released"] isEqual:@YES]];
    } else if (_phase == SZFriendsCheckInPhaseCheckedIn && [_online connectionDidReceive:message]) {
        // A protocol 2 answer, taken by the online side.
    } else if ([type isEqualToString:@"error"] && [message[@"code"] isEqual:@"device_revoked"] &&
               !_releaseCompletion) {
        [self deviceWasRevoked];
    } else if ([type isEqualToString:@"error"]) {
        NSString *code = [message[@"code"] isKindOfClass:[NSString class]] ? message[@"code"] : @"?";
        os_log_info(OS_LOG_DEFAULT, "Friends: host refused a message: %{public}@", code);
    }
}

- (void)receiveChallenge:(NSDictionary<NSString *, id> *)message {
    if (_phase != SZFriendsCheckInPhaseOpening) return;
    SZFriendsHostEntry *entry = _candidates[_candidateIndex].entry;
    NSData *nonce = SZFriendsHostBase64URLDecode(message[@"nonce"], 32);
    // The signature names the host id from the signed list; a host answering under another name is not the host
    // the list describes, so it gets nothing signed.
    if (nonce == nil || ![message[@"host_id"] isEqual:entry.hostID]) {
        [self candidateFailed];
        return;
    }
    _challenge = nonce;
    [_online connectionDidReceiveChallenge:message];
    if (_releaseCompletion) {
        [self sendRelease];
        return;
    }
    NSString *friendsID = _idProvider(0);
    _originalID = friendsID;
    _pendingID = friendsID;
    _collisions = 0;
    NSInteger listVersion = _cache.currentList.version;
    // The person this device speaks for: its own key on the first device, which brings its chain only once it holds
    // other devices (so the host learns of the ones it removed). A host from before protocol 3 says no protocol in its
    // challenge and reads only protocol 2's check-in: the device checks in as itself there, until the host is updated.
    NSData *chain = nil;
    NSData *root = self.membershipProvider ? self.membershipProvider(&chain) : nil;
    NSInteger protocol = SZFriendsHostProtocolForChallenge(message);
    if (root.length != 32 || protocol < SZFriendsHostDevicesProtocol) {
        root = _identity.publicKey;
        chain = nil;
    }
    _personKey = root;
    NSData *signed_ = SZFriendsHostCheckinMessage(entry.hostID, nonce, _identity.publicKey, friendsID,
                                                  _friendsIDReserved, _appVersion, protocol, listVersion, root, chain);
    NSData *signature = [_identity signatureForMessage:signed_ domain:SZFriendsHostCheckinDomain];
    _phase = SZFriendsCheckInPhaseCheckingIn;
    NSMutableDictionary<NSString *, id> *fields = [@{
        @"identity_key" : SZFriendsHostBase64URLEncode(_identity.publicKey),
        @"friends_id" : friendsID,
        @"reserved" : @(_friendsIDReserved),
        @"app_version" : _appVersion,
        @"protocol" : @(protocol),
        @"list_version" : @(listVersion),
        @"sig" : SZFriendsHostBase64URLEncode(signature),
    } mutableCopy];
    if (protocol >= SZFriendsHostDevicesProtocol) fields[@"root_key"] = SZFriendsHostBase64URLEncode(root);
    if (chain != nil) fields[@"chain"] = SZFriendsHostBase64URLEncode(chain);
    [self send:@"checkin" fields:fields];
}

// Signed by the host key the list gives the host this connection reached, over this connection's challenge.
- (BOOL)verifies:(NSDictionary<NSString *, id> *)message body:(NSArray *)body {
    SZFriendsHostEntry *entry = _candidateIndex < _candidates.count ? _candidates[_candidateIndex].entry : nil;
    if (SZFriendsHostReplyVerifies(message, body, _challenge, entry.publicKey)) return YES;
    os_log_error(OS_LOG_DEFAULT, "Friends: a host answer was not signed by that host's key");
    return NO;
}

// The backoff is not reset here: only a reservation resets it, so a host that welcomes and then refuses every ID
// is retried less and less often.
- (void)receiveWelcome:(NSDictionary<NSString *, id> *)message {
    SZFriendsHostCancelTimer(&_connectTimer);
    _phase = SZFriendsCheckInPhaseCheckedIn;
    _unavailableRetries = 0;
    [self setState:SZFriendsHostStateConnected];
    BOOL verified = [self verifies:message body:SZFriendsHostWelcomeBody(_pendingID, message)];
    if (verified && [message[@"update_required"] isEqual:@YES]) [self.delegate checkInRequiresUpdate];
    // A list carries its own signature, so it is offered whether or not the welcome verified.
    if ([self offerList:message[@"host_list"]]) return; // reconnecting to a better host
    [self handleReservation:verified ? message[@"reservation"] : @"unavailable"
                  friendsID:message[@"friends_id"]
                attestation:message[@"attestation"]
                  adoptable:YES];
    // `online` sits outside host_sig: whoever could alter it could cut the connection anyway.
    if (_phase == SZFriendsCheckInPhaseCheckedIn) {
        [_online connectionDidCheckInWithWelcome:message
                                           entry:_candidates[_candidateIndex].entry
                                            list:_cache.currentList];
    }
}

// Returns YES when the new list moved the preferred host elsewhere and the client is reconnecting to it.
- (BOOL)offerList:(id)envelope {
    if (![envelope isKindOfClass:[NSDictionary class]]) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:NULL];
    NSError *error = nil;
    if (data == nil || ![_cache offerSignedList:data error:&error]) {
        if (error.code != SZFriendsHostErrorAlreadyCurrent) {
            os_log_info(OS_LOG_DEFAULT, "Friends: host list refused (%ld)", (long)error.code);
        }
        return NO;
    }
    if (!_running || _releaseCompletion || _phase != SZFriendsCheckInPhaseCheckedIn) return NO;
    NSArray<SZFriendsHostCandidate *> *candidates = [self candidatesFromList:_cache.currentList];
    NSURL *current = _candidates[_candidateIndex].url;
    if (candidates.count > 0 && [candidates[0].url isEqual:current]) return NO;
    // Connected users switch within seconds of a new list (brief § Signed host list).
    [self closeSocket];
    _attempt = 0;
    [self beginRound];
    return YES;
}

- (void)releaseIdentityWithCompletion:(void (^)(BOOL released))completion {
    [self startReleaseWithCompletion:completion];
}

- (SZFriendsHostAttestation *)attestationForFriendsID:(NSString *)friendsID {
    return [self keptAttestationForFriendsID:friendsID];
}

@end
