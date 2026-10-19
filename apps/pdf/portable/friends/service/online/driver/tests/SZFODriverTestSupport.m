// Shared pieces of friends-driver-check (SZFODriverTestSupport.h).

#import "SZFODriverTestSupport.h"

#import <sodium.h>

int SZFODFailures = 0;

void SZFODFail(const char *file, int line, const char *expression, NSString *detail) {
    SZFODFailures++;
    fprintf(stderr, "%s:%d: expected %s %s\n", file, line, expression, detail.UTF8String);
}

BOOL SZFODWaitUntil(NSTimeInterval timeout, BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MIN(timeout, 10)];
    while (!condition()) {
        if (deadline.timeIntervalSinceNow <= 0) return NO;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return YES;
}

void SZFODSpin(NSTimeInterval seconds) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

NSData *SZFODRandom(NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    randombytes_buf(data.mutableBytes, count);
    return data;
}

SZFriendsIdentity *SZFODNewIdentity(void) {
    return [SZFriendsIdentity identityWithSigningSeed:SZFODRandom(32) staticPrivateKey:SZFODRandom(32)];
}

SZFriendsOnlineFriend *SZFODFriendFor(SZFriendsIdentity *identity, NSData *presenceSecret) {
    SZFriendsOnlineFriend *friend = [SZFriendsOnlineFriend new];
    friend.identityKey = identity.publicKey;
    friend.staticKey = identity.staticPublicKey;
    friend.presenceSecret = presenceSecret;
    return friend;
}

#pragma mark - In-memory sids

@implementation SZFODChannel {
    BOOL _spoke;
}

@synthesize onPayload = _onPayload;
@synthesize onEnd = _onEnd;

+ (NSArray<SZFODChannel *> *)pair {
    SZFODChannel *opener = [SZFODChannel new], *target = [SZFODChannel new];
    opener.peer = target;
    target.peer = opener;
    return @[ opener, target ];
}

- (instancetype)init {
    if ((self = [super init])) _sent = [NSMutableArray array];
    return self;
}

- (BOOL)ended {
    return _closed || _peer == nil || _peer.closed;
}

- (BOOL)sendPayload:(NSData *)payload {
    if (self.ended || payload.length == 0 || payload.length > SZFriendsOnlineSignalPayloadMax) return NO;
    _spoke = YES;
    [_sent addObject:payload];
    SZFODChannel *peer = _peer;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!peer.closed && peer.onPayload) peer.onPayload(payload);
    });
    return YES;
}

// As the host does: an end that never spoke leaves nothing behind for the other to notice.
- (void)close {
    if (_closed) return;
    _closed = YES;
    SZFODChannel *peer = _peer;
    if (!_spoke || peer == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!peer.closed && peer.onEnd) peer.onEnd();
    });
}

- (void)requestRelayCredentials:(void (^)(id<SZFriendsOnlineRelayCredentials>, NSError *))completion {
    id<SZFriendsOnlineRelayCredentials> credentials = self.credentials ? self.credentials() : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(credentials, credentials ? nil : [NSError errorWithDomain:@"SZFOD" code:1 userInfo:nil]);
    });
}

@end

#pragma mark - Delegate

@implementation SZFODDelegate

- (instancetype)init {
    if ((self = [super init])) {
        _friends = [NSMutableDictionary dictionary];
        _streams = [NSMutableArray array];
        _routes = [NSMutableArray array];
        _initiators = [NSMutableArray array];
        _received = [NSMutableArray array];
    }
    return self;
}

- (void)onlineDriverDidBecomeAvailable:(SZFriendsOnlineDriver *)driver {
    (void)driver;
    _availabilityCalls++;
}

- (SZFriendsOnlineFriend *)onlineDriver:(SZFriendsOnlineDriver *)driver friendWithIdentityKey:(NSData *)identityKey {
    (void)driver;
    return _friends[identityKey];
}

- (SZFriendsRouteMethod)onlineDriver:(SZFriendsOnlineDriver *)driver nearbyRouteForFriend:(NSData *)identityKey {
    (void)driver;
    (void)identityKey;
    return _nearbyRoute;
}

- (void)onlineDriver:(SZFriendsOnlineDriver *)driver
       didOpenStream:(id<SZFriendsByteStream>)stream
               route:(SZFriendsRouteMethod)route
           initiator:(BOOL)initiator
              friend:(NSData *)identityKey {
    (void)driver;
    (void)identityKey;
    [_streams addObject:stream];
    [_routes addObject:@(route)];
    [_initiators addObject:@(initiator)];
    __weak SZFODDelegate *weakSelf = self;
    stream.onData = ^(NSData *data) { [weakSelf.received addObject:data]; };
    stream.onClose = ^(NSError *error) { (void)error; };
    [stream startWithQueue:dispatch_get_main_queue()];
}

@end

#pragma mark - Two drivers

@implementation SZFODWorld

- (instancetype)initWithTransportFactory:(id<SZFriendsOnlineTransport> (^)(void))factory {
    if ((self = [super init])) {
        _identityA = SZFODNewIdentity();
        _identityB = SZFODNewIdentity();
        _a = [[SZFriendsOnlineDriver alloc] initWithIdentity:_identityA queue:dispatch_get_main_queue()];
        _b = [[SZFriendsOnlineDriver alloc] initWithIdentity:_identityB queue:dispatch_get_main_queue()];
        _delegateA = [SZFODDelegate new];
        _delegateB = [SZFODDelegate new];
        _a.delegate = _delegateA;
        _b.delegate = _delegateB;
        _sids = [NSMutableArray array];
        if (factory) {
            _a.onlineContext.transport = factory();
            _b.onlineContext.transport = factory();
        }
        [self connect:_a to:_b];
        [self connect:_b to:_a];
    }
    return self;
}

- (void)connect:(SZFriendsOnlineDriver *)from to:(SZFriendsOnlineDriver *)to {
    __weak SZFODWorld *weakSelf = self;
    __weak SZFriendsOnlineDriver *weakTo = to;
    from.testOpener = ^(NSData *rdvKey, NSData *payload, void (^completion)(id<SZFriendsOnlineSignalChannel>)) {
        (void)rdvKey;
        SZFODWorld *world = weakSelf;
        NSArray<SZFODChannel *> *pair = [SZFODChannel pair];
        for (SZFODChannel *end in pair) end.credentials = world.credentials;
        [world.sids addObject:pair];
        completion(pair[0]);
        // The host forwards the open after answering the opener with its sid.
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakTo receiveOpenVia:SZFriendsHostSignalViaRendezvous channel:pair[1] payload:payload];
        });
    };
}

- (void)befriend {
    NSData *secretA = SZFODRandom(32), *secretB = SZFODRandom(32);
    _delegateA.friends[_identityB.publicKey] = SZFODFriendFor(_identityB, secretB);
    _delegateB.friends[_identityA.publicKey] = SZFODFriendFor(_identityA, secretA);
}

- (void)stop {
    [_a stop];
    [_b stop];
    SZFODSpin(0.2);
}

@end

#pragma mark - A transport that never touches the stack

@implementation SZFODFakeConnection {
    __weak id<SZFriendsOnlineConnectionDelegate> _delegate;
}

@synthesize purpose = _purpose, role = _role, kind = _kind, peer = _peer;

- (instancetype)initWithRequest:(id<SZFriendsOnlineConnectionRequest>)request
                       delegate:(id<SZFriendsOnlineConnectionDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _purpose = request.purpose;
        _role = request.role;
        _kind = request.kind;
        _peer = [request.peer copy];
        _delegate = delegate;
        __weak SZFODFakeConnection *weakSelf = self;
        dispatch_async(queue, ^{
            SZFODFakeConnection *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.closed) return;
            [strongSelf->_delegate onlineConnection:strongSelf
                          didCreateLocalDescription:@"v=0\r\n"
                                        fingerprint:[NSMutableData dataWithLength:32]];
        });
    }
    return self;
}

- (NSData *)localFingerprint {
    return [NSMutableData dataWithLength:32];
}

- (uint16_t)localPort {
    return 0;
}

- (SZFriendsOnlineRoute)route {
    return SZFriendsOnlineRouteMake(SZFriendsOnlineTechniqueNone, NO);
}

- (BOOL)applyRemoteAnswerSDP:(NSString *)sdp remoteFingerprint:(NSData *)fingerprint error:(NSError **)error {
    (void)sdp;
    (void)fingerprint;
    (void)error;
    _answersApplied++;
    return YES;
}

- (BOOL)addRemoteCandidate:(NSString *)candidate technique:(SZFriendsOnlineTechnique)technique error:(NSError **)error {
    (void)candidate;
    (void)technique;
    (void)error;
    _candidatesAdded++;
    return YES;
}

- (void)remoteCandidatesDidEnd {
}

- (void)addLocalCandidate:(NSString *)candidate technique:(SZFriendsOnlineTechnique)technique {
    (void)candidate;
    (void)technique;
}

- (void)close {
    _closed = YES;
}

- (void)fail {
    if (_closed) return;
    _closed = YES;
    [_delegate onlineConnection:self didFailWithError:[NSError errorWithDomain:@"SZFOD" code:2 userInfo:nil]];
}

@end

@implementation SZFODFakeTransport

- (instancetype)init {
    if ((self = [super init])) {
        _connections = [NSMutableArray array];
        _requests = [NSMutableArray array];
    }
    return self;
}

- (id<SZFriendsOnlineConnection>)openConnection:(id<SZFriendsOnlineConnectionRequest>)request
                                       delegate:(id<SZFriendsOnlineConnectionDelegate>)delegate
                                          queue:(dispatch_queue_t)queue
                                          error:(NSError **)error {
    (void)error;
    [_requests addObject:request];
    SZFODFakeConnection *connection = [[SZFODFakeConnection alloc] initWithRequest:request delegate:delegate
                                                                             queue:queue];
    [_connections addObject:connection];
    return connection;
}

@end
