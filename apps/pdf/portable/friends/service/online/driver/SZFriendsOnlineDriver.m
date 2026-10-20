// The online driver (SZFriendsOnlineDriver.h): the host's protocol 2 on one side, attempts toward friends on the
// other. Publishes this device's record once per host period, answers IK opens from friends, starts attempts when the
// helper asks, and keeps every attempt told about the routes outside it.

#import "service/online/driver/SZFriendsOnlineDriverPrivate.h"

#include <notify.h>

#import "service/host/SZFriendsHostRendezvous.h"
#import "service/identity/SZFriendsIdentity.h"
#import "service/online/nat/SZFriendsNATClassifier.h"

// A burst of routing-table changes (an interface coming up brings several) counts as one: the change is looked at
// once the notifications have been quiet this long, or at the latest this long after the first of the burst.
static const NSTimeInterval kNetworkChangeSettle = 1;
static const NSTimeInterval kNetworkChangeSettleMax = 5;
// Opens toward us that are remembered against replays: a handful of friends' attempts, never a flood's worth.
static const NSUInteger kReplayCacheCapacity = 4096;

@implementation SZFriendsOnlineDriver {
    SZFriendsIdentity *_identity;
    dispatch_queue_t _queue;
    SZFriendsOnlineContext *_context;
    SZFriendsHostOnline *_online;
    NSMutableArray<SZFriendsOnlineAttempt *> *_attempts;
    // Friends an attempt failed for with the relay asked for, and since when (wall clock): kept through retries.
    NSMutableDictionary<NSData *, NSDate *> *_failedEverywhere;
    SZFriendsReplayCache *_replayCache;
    int _networkToken;
    BOOL _watchingNetwork;
    NSUInteger _networkNotices;        // every notification; a settle timer acts only if none came after it
    NSTimeInterval _networkBurstStart; // the burst's first notification on the continuous clock, 0 between bursts
    NSString *_networkSignature;       // the default routes when last looked at (SZFriendsOnlineNetworkSignature)
    BOOL _stopped;
}

- (instancetype)initWithIdentity:(SZFriendsIdentity *)identity queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _identity = identity;
        _queue = queue;
        _attempts = [NSMutableArray array];
        _backoffUntil = [NSMutableDictionary dictionary];
        _backoffWait = [NSMutableDictionary dictionary];
        _lookingUp = [NSMutableSet set];
        _lastLookup = [NSMutableDictionary dictionary];
        _failedEverywhere = [NSMutableDictionary dictionary];
        _networkToken = NOTIFY_TOKEN_INVALID;
        [SZFriendsOnlineDriverTestHooks registerDriver:self];
    }
    return self;
}

- (void)dealloc {
    if (_watchingNetwork) notify_cancel(_networkToken);
}

// Made on the first use, which is the first time the host says it takes online messages: a helper whose host runs
// protocol 1, or that never checks in, makes none of it.
- (SZFriendsOnlineContext *)context {
    if (_context == nil) {
        _context = [[SZFriendsOnlineContext alloc] initWithIdentity:_identity queue:_queue];
        _context.techniqueLogPath = self.techniqueLogPath;
        __weak SZFriendsOnlineDriver *weakSelf = self;
        _context.onNATClassChanged = ^{
            SZFriendsOnlineDriver *strongSelf = weakSelf;
            for (SZFriendsOnlineAttempt *attempt in strongSelf->_attempts.copy) [attempt localNATClassChanged];
        };
    }
    return _context;
}

- (void)setTechniqueLogPath:(NSString *)techniqueLogPath {
    _techniqueLogPath = [techniqueLogPath copy];
    _context.techniqueLogPath = _techniqueLogPath;
}

#pragma mark - The host

- (void)attachHostOnline:(SZFriendsHostOnline *)online {
    if (_online == online || _stopped) return;
    _online.delegate = nil;
    _online.sealedRecordProvider = nil;
    _online = online;
    online.delegate = self;
    __weak SZFriendsOnlineDriver *weakSelf = self;
    online.sealedRecordProvider = ^NSData * { return [weakSelf sealedRecord]; };
    if (online.available) [self hostOnline:online didChangeAvailability:YES];
}

- (BOOL)available {
    return !_stopped && (_online.available || self.testOpener != nil);
}

// This device's record for the period: its NAT class only. Candidates stay in the signalling, sealed to one friend.
- (NSData *)sealedRecord {
    NSData *secret = self.ownPresenceSecret ? self.ownPresenceSecret() : nil;
    if (_stopped || secret.length != 32) return nil;
    SZFriendsOnlineContext *context = self.context;
    NSArray *items = @[ [SZFriendsSignalItem natWithClass:(SZFriendsSignalNATClass)context.natClass
                                                     step:context.natStep] ];
    return SZFriendsSealRendezvousRecord(_identity, _identity.publicKey, secret,
                                         SZFriendsPresenceWindowIndex([NSDate date]), items, NULL);
}

- (void)hostOnline:(SZFriendsHostOnline *)online didChangeAvailability:(BOOL)available {
    if (online != _online || _stopped) return;
    if (!available) return; // every sid ended already; streams carry on peer to peer
    [self refreshSTUNServers];
    [self watchNetwork];
    [_backoffUntil removeAllObjects]; // a new host connection: everyone may be tried again
    [self.delegate onlineDriverDidBecomeAvailable:self];
}

// The connected host's entry in the verified list names the STUN servers (3478 first, then 3479); a name is resolved
// off the queue, and only numeric addresses ever reach the stack and the NAT techniques.
- (void)refreshSTUNServers {
    SZFriendsHostList *list = self.hostList ? self.hostList() : nil;
    NSString *hostID = _online.hostID;
    NSMutableArray<NSString *> *uris = [NSMutableArray array];
    for (SZFriendsHostEntry *entry in list.entries) {
        if (![entry.hostID isEqualToString:hostID]) continue;
        for (NSString *uri in entry.turnURIs) {
            if ([uri hasPrefix:@"stun:"]) [uris addObject:uri];
        }
    }
    SZFriendsOnlineContext *context = self.context;
    __weak SZFriendsOnlineDriver *weakSelf = self;
    dispatch_queue_t queue = _queue;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray<SZFriendsNATEndpoint *> *servers = SZFriendsOnlineResolveSTUNURIs(uris);
        dispatch_async(queue, ^{
            if (weakSelf == nil) return;
            context.stunPrimary = servers.count > 0 ? servers[0] : nil;
            context.stunSecondary = servers.count > 1 ? servers[1] : nil;
        });
    });
}

- (void)hostOnline:(SZFriendsHostOnline *)online
    didReceiveSignal:(SZFriendsHostSignal *)signal
             payload:(NSData *)payload {
    if (online != _online) {
        [signal close];
        return;
    }
    [self receiveOpenVia:signal.via channel:SZFriendsOnlineChannelForSignal(signal) payload:payload];
}

#pragma mark - Opens toward us

// Only friends, and holders answering our Add by ID, reach the stack, by IK; opens by Friends ID get NN and never a
// peer connection (+ByID). Links are served by the helper's links service, so other opens are closed unanswered. A
// refusal of any kind is silence, so the caller cannot tell it from nobody (ADR 0010).
- (void)receiveOpenVia:(SZFriendsHostSignalVia)via
               channel:(id<SZFriendsOnlineSignalChannel>)channel
               payload:(NSData *)payload {
    if (!_stopped && (via == SZFriendsHostSignalViaFriendsID || via == SZFriendsHostSignalViaJoin)) {
        [self routeOpenVia:via channel:channel payload:payload]; // joining (+Join), else Add by ID (+ByID)
        return;
    }
    if (_stopped || via != SZFriendsHostSignalViaRendezvous) {
        [channel close];
        return;
    }
    if (_replayCache == nil) {
        _replayCache = [[SZFriendsReplayCache alloc] initWithCapacity:kReplayCacheCapacity clock:nil];
    }
    __block SZFriendsOnlineFriend *admitted = nil;
    __weak SZFriendsOnlineDriver *weakSelf = self;
    // Pure, as the session layer requires: it reads who the key names now and remembers it for after the handshake.
    SZFriendsRemoteKeyPolicy policy = ^BOOL(NSData *key, SZFriendsHandshakePattern pattern, NSData *token) {
        SZFriendsOnlineDriver *strongSelf = weakSelf;
        if (strongSelf == nil || pattern != SZFriendsHandshakeIK || key.length != 32) return NO;
        // A token answers an Add by ID of ours (the holder, before our ACCEPT reached it); anyone else is a friend.
        admitted = token ? [strongSelf friendAnsweringWithIdentityKey:key token:token]
                         : [strongSelf.delegate onlineDriver:strongSelf friendWithIdentityKey:key];
        return admitted != nil;
    };
    NSArray<SZFriendsSignalItem *> *items = nil;
    SZFriendsSignalingSession *session = [SZFriendsSignalingSession responderForMessage:payload
                                                                               identity:_identity
                                                                                allowed:@[ @(SZFriendsHandshakeIK) ]
                                                                            replayCache:_replayCache
                                                                              keyPolicy:policy
                                                                                    now:[NSDate date]
                                                                                  items:&items
                                                                                  error:NULL];
    // The friend must also present the static key we hold for them: another one waits for the person's review. A
    // holder answering our Add by ID has none stored yet: its certificate in message 1 bound the one it presented.
    if (admitted != nil && admitted.staticKey == nil) admitted.staticKey = session.remoteStaticKey;
    if (session == nil || admitted == nil || ![session.remoteIdentityKey isEqualToData:admitted.identityKey] ||
        ![session.remoteStaticKey isEqualToData:admitted.staticKey]) {
        [channel close];
        return;
    }
    [self admitSession:session channel:channel items:items ?: @[] friend:admitted];
}

- (void)admitSession:(SZFriendsSignalingSession *)session
             channel:(id<SZFriendsOnlineSignalChannel>)channel
               items:(NSArray<SZFriendsSignalItem *> *)items
              friend:(SZFriendsOnlineFriend *)friend {
    NSData *key = friend.identityKey;
    for (SZFriendsOnlineAttempt *attempt in _attempts.copy) {
        if (![attempt.peer isEqualToData:key]) continue;
        if (attempt.role == SZFriendsOnlineRoleAnswerer) {
            // The friend's own attempt, on a new sid (the old one ran out): it carries on.
            [attempt continueWithSession:session channel:channel items:items];
            return;
        }
        // Both sides started at once. One rule on both Macs keeps exactly one: the side whose identity key sorts
        // first offers. Ours goes unless it already carries a stream, and goes again when nobody answered it yet.
        if (attempt.connected || SZFriendsOnlineKeySortsFirst(_identity.publicKey, key)) {
            [channel close];
            if (!attempt.connected && !attempt.answered) [self offerAgain:attempt];
            return;
        }
        [attempt close];
    }
    SZFriendsOnlineAttempt *attempt = [[SZFriendsOnlineAttempt alloc] initAnswererWithFriend:friend
                                                                                     session:session
                                                                                     channel:channel
                                                                                       items:items
                                                                                     context:self.context
                                                                                       owner:self];
    [self begin:attempt];
}

#pragma mark - Attempts

- (void)reachFriend:(NSData *)identityKey {
    if (!self.available || identityKey.length != 32 || [self hasAttemptForFriend:identityKey]) return;
    if ([self backedOff:identityKey]) {
        [self lookUpFriend:identityKey];
        return;
    }
    SZFriendsOnlineFriend *friend = [self.delegate onlineDriver:self friendWithIdentityKey:identityKey];
    if (friend == nil || ![friend.identityKey isEqualToData:identityKey]) return;
    SZFriendsRouteMethod other = [self otherRouteForFriend:identityKey except:nil];
    if (!SZFriendsOnlineAttemptWorthStarting(other)) return;
    SZFriendsOnlineAttempt *attempt = [[SZFriendsOnlineAttempt alloc] initOffererWithFriend:friend
                                                                                    context:self.context
                                                                                      owner:self];
    [self begin:attempt];
}

- (void)begin:(SZFriendsOnlineAttempt *)attempt {
    [_attempts addObject:attempt];
    [self.context measureNATClass];
    [self reachChangedForFriend:attempt.peer];
    [attempt start];
    if (!attempt.ended) [attempt nearbyRouteChanged:[self otherRouteForFriend:attempt.peer except:attempt]];
}

- (BOOL)hasAttemptForFriend:(NSData *)identityKey {
    for (SZFriendsOnlineAttempt *attempt in _attempts) {
        if ([attempt.peer isEqualToData:identityKey]) return YES;
    }
    return NO;
}

// The best route carrying a session with this friend outside `attempt`: nearby's, or another attempt's stream.
- (SZFriendsRouteMethod)otherRouteForFriend:(NSData *)identityKey except:(SZFriendsOnlineAttempt *)except {
    SZFriendsRouteMethod best = [self.delegate onlineDriver:self nearbyRouteForFriend:identityKey];
    for (SZFriendsOnlineAttempt *attempt in _attempts) {
        if (attempt == except || ![attempt.peer isEqualToData:identityKey]) continue;
        SZFriendsRouteMethod carried = attempt.carriedRoute;
        if (carried != SZFriendsRouteMethodNone && SZFriendsRouteIsBetter(carried, best)) best = carried;
    }
    return best;
}

- (void)nearbyRoutesChanged {
    for (SZFriendsOnlineAttempt *attempt in _attempts.copy) {
        if (!attempt.ended) [attempt nearbyRouteChanged:[self otherRouteForFriend:attempt.peer except:attempt]];
    }
}

- (void)networkChanged {
    if (_stopped) return;
    [_context networkChanged];
    [_backoffUntil removeAllObjects];
    [_backoffWait removeAllObjects];
    [self forgetFailures];
    for (SZFriendsOnlineAttempt *attempt in _attempts.copy) [attempt networkChanged];
    if (_attempts.count > 0) [_context measureNATClass];
    if (self.available) [self.delegate onlineDriverDidBecomeAvailable:self];
}

- (void)stop {
    if (_stopped) return;
    _stopped = YES;
    _online.sealedRecordProvider = nil;
    _online.delegate = nil;
    _online = nil;
    if (_watchingNetwork) notify_cancel(_networkToken);
    _watchingNetwork = NO;
    [self closeIDExchanges];
    for (SZFriendsOnlineAttempt *attempt in _attempts.copy) [attempt close];
    [_attempts removeAllObjects];
    [_failedEverywhere removeAllObjects];
}

- (SZFriendsOnlineFriendReach)reachOfFriend:(NSData *)identityKey {
    if (_stopped || identityKey == nil) return SZFriendsOnlineFriendReachIdle;
    if (_failedEverywhere[identityKey] != nil) return SZFriendsOnlineFriendReachFailed;
    return [self hasAttemptForFriend:identityKey] ? SZFriendsOnlineFriendReachTrying : SZFriendsOnlineFriendReachIdle;
}

- (nullable NSDate *)failedSinceForFriend:(NSData *)identityKey {
    return identityKey == nil || _stopped ? nil : _failedEverywhere[identityKey];
}

- (void)forgetFailureForFriend:(NSData *)identityKey {
    if (identityKey == nil || _failedEverywhere[identityKey] == nil) return;
    [_failedEverywhere removeObjectForKey:identityKey];
    [self reachChangedForFriend:identityKey];
}

- (void)reachChangedForFriend:(nullable NSData *)identityKey {
    id<SZFriendsOnlineDriverDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(onlineDriver:reachChangedForFriend:)]) {
        [delegate onlineDriver:self reachChangedForFriend:identityKey];
    }
}

- (void)forgetFailures {
    if (_failedEverywhere.count == 0) return;
    [_failedEverywhere removeAllObjects];
    [self reachChangedForFriend:nil];
}

#pragma mark - SZFriendsOnlineAttemptOwner

- (void)attempt:(SZFriendsOnlineAttempt *)attempt
    openChannelWithPayload:(NSData *)payload
                completion:(void (^)(id<SZFriendsOnlineSignalChannel>))completion {
    NSData *rdvKey = SZFriendsHostRendezvousKey(attempt.peerRoot); // every device of theirs; theirs alone answers
    if (!self.available || rdvKey == nil) {
        completion(nil);
        return;
    }
    if (self.testOpener != nil) {
        self.testOpener(rdvKey, payload, completion);
        return;
    }
    [_online openToRendezvousKey:rdvKey
                         payload:payload
                      completion:^(SZFriendsHostSignal *signal, NSError *error) {
                          (void)error;
                          completion(signal ? SZFriendsOnlineChannelForSignal(signal) : nil);
                      }];
}

- (void)attempt:(SZFriendsOnlineAttempt *)attempt
    didOpenStream:(id<SZFriendsByteStream>)stream
            route:(SZFriendsOnlineRoute)route {
    [_backoffUntil removeObjectForKey:attempt.peer];
    [_backoffWait removeObjectForKey:attempt.peer];
    [self forgetFailureForFriend:attempt.peer];
    id<SZFriendsOnlineDriverDelegate> delegate = self.delegate;
    if (delegate == nil) {
        [stream close];
        return;
    }
    [delegate onlineDriver:self
             didOpenStream:stream
                     route:route.method
                 initiator:attempt.role == SZFriendsOnlineRoleOfferer
                    friend:attempt.peer];
    [self nearbyRoutesChanged];
}

- (void)attemptDidEnd:(SZFriendsOnlineAttempt *)attempt {
    [_attempts removeObject:attempt];
    SZFriendsOnlineEndReason reason = attempt.order.endReason;
    BOOL nobody = attempt.role == SZFriendsOnlineRoleOfferer && !attempt.answered;
    if (!_stopped && !attempt.connected && (nobody || reason == SZFriendsOnlineEndUnreachable)) {
        [self noteFailureForFriend:attempt.peer];
    }
    // Failed everywhere only when the friend answered and the relay was asked for too: the words then say they are not
    // reachable, rather than not connected. A later attempt ending any other way changes nothing: only a stream, the
    // helper (something new queued, the conversation opened), a network change or -stop clears it.
    BOOL everywhere = !attempt.connected && !nobody && reason == SZFriendsOnlineEndUnreachable &&
                      attempt.order.logEntry.relayRequested;
    if (_stopped) return;
    if (everywhere && _failedEverywhere[attempt.peer] == nil) _failedEverywhere[attempt.peer] = [NSDate date];
    [self nearbyRoutesChanged];
    [self reachChangedForFriend:attempt.peer];
}

#pragma mark - The network

// The system posts this whenever its network configuration changes (an interface, an address, a route).
- (void)watchNetwork {
    if (_watchingNetwork) return;
    __weak SZFriendsOnlineDriver *weakSelf = self;
    uint32_t status = notify_register_dispatch("com.apple.system.config.network_change", &_networkToken, _queue,
                                               ^(int token) {
                                                   (void)token;
                                                   [weakSelf scheduleNetworkChange];
                                               });
    _watchingNetwork = status == NOTIFY_STATUS_OK;
    _networkSignature = [self currentNetworkSignature];
}

- (NSString *)currentNetworkSignature {
    return self.testNetworkSignature ? self.testNetworkSignature() : SZFriendsOnlineNetworkSignature();
}

- (void)scheduleNetworkChange {
    if (_stopped) return;
    NSUInteger notice = ++_networkNotices;
    NSTimeInterval now = SZFriendsInstantNow().continuous;
    if (_networkBurstStart == 0) _networkBurstStart = now;
    NSTimeInterval delay = MAX(MIN(kNetworkChangeSettle, _networkBurstStart + kNetworkChangeSettleMax - now), 0);
    __weak SZFriendsOnlineDriver *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
        SZFriendsOnlineDriver *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_networkNotices != notice) return;
        strongSelf->_networkBurstStart = 0;
        [strongSelf networkMayHaveChanged];
    });
}

// Backoffs, NAT classes and attempts are reset only when the default route's interface, gateway or source address
// moved: a VPN or a second interface coming and going leaves offline friends backed off.
- (void)networkMayHaveChanged {
    NSString *signature = [self currentNetworkSignature];
    if (_stopped || [signature isEqualToString:_networkSignature]) return;
    _networkSignature = signature;
    [self networkChanged];
}

#pragma mark - Tests

- (SZFriendsOnlineContext *)onlineContext {
    return self.context;
}

- (NSArray<SZFriendsOnlineAttempt *> *)attempts {
    return [_attempts copy];
}

@end
