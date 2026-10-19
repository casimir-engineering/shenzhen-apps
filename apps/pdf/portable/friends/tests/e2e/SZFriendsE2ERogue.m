// A peer under the scenario's control (SZFriendsE2ERogue.h).

#import "SZFriendsE2ERogue.h"

#import <sodium.h>

#import "service/discovery/SZFriendsDiscovery.h"

NSData *SZFE2ERandomBytes(NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    randombytes_buf(data.mutableBytes, count);
    return data;
}

static NSData *SZFE2ENow(void) {
    return [SZFriendsFrame fieldWithUInt64:(uint64_t)([NSDate date].timeIntervalSince1970 * 1000)
                                       tag:SZFriendsFieldSentAt];
}

SZFriendsFrame *SZFE2ERequestFrame(void) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeRequest
                                  fields:@{@(SZFriendsFieldID) : SZFE2ERandomBytes(16), @(SZFriendsFieldSentAt) :
                                               SZFE2ENow()}];
}

SZFriendsFrame *SZFE2EProfileFrame(NSString *name) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeProfile
                                  fields:@{@(SZFriendsFieldName) : [name dataUsingEncoding:NSUTF8StringEncoding]}];
}

SZFriendsFrame *SZFE2EMessageFrame(NSString *text) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeMessage
                                  fields:@{@(SZFriendsFieldID) : SZFE2ERandomBytes(16),
                                           @(SZFriendsFieldSentAt) : SZFE2ENow(),
                                           @(SZFriendsFieldText) : [text dataUsingEncoding:NSUTF8StringEncoding]}];
}

SZFriendsFrame *SZFE2EAcceptFrame(void) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeAccept
                                  fields:@{@(SZFriendsFieldID) : SZFE2ERandomBytes(16)}];
}

// Called on the rogue's queue only.
@interface SZFE2ERogueSession ()
- (instancetype)initWithQueue:(dispatch_queue_t)queue;
- (void)attachChannel:(SZFriendsSecureChannel *)channel;
- (void)failOnQueue:(nullable NSError *)error;
- (void)closeOnQueue;
- (nullable NSDate *)firstArrivalOnQueue:(SZFriendsFrameType)type;
- (void)notePublicProfile:(NSDictionary<NSNumber *, NSData *> *)profile;
@end

@implementation SZFE2ERogueSession {
    SZFriendsSecureChannel *_channel;
    dispatch_queue_t _queue;
    BOOL _established, _closed;
    NSDate *_establishedAt;
    NSError *_closeError;
    NSDate *_closedAt;
    NSDictionary<NSNumber *, NSData *> *_publicProfile;
    NSString *_code;
    NSMutableArray<SZFriendsFrame *> *_frames;
    NSMutableDictionary<NSNumber *, NSDate *> *_arrivals;
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _queue = queue;
        _frames = [NSMutableArray array];
        _arrivals = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)attachChannel:(SZFriendsSecureChannel *)channel {
    _channel = channel;
    __weak SZFE2ERogueSession *weakSelf = self;
        channel.onEstablished = ^{
            SZFE2ERogueSession *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            strongSelf->_established = YES;
            strongSelf->_establishedAt = [NSDate date];
        };
        channel.onFrame = ^(SZFriendsFrame *frame) { [weakSelf received:frame]; };
        channel.onClose = ^(NSError *error) {
            SZFE2ERogueSession *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            strongSelf->_closed = YES;
            strongSelf->_closeError = error;
            strongSelf->_closedAt = [NSDate date];
        };
}

- (void)failOnQueue:(NSError *)error {
    _closed = YES;
    _closeError = error ?: [NSError errorWithDomain:@"SZFE2ERogue" code:1 userInfo:nil];
    _closedAt = [NSDate date];
}

- (void)closeOnQueue {
    [_channel close];
}

- (NSDate *)firstArrivalOnQueue:(SZFriendsFrameType)type {
    return _arrivals[@(type)];
}

- (void)received:(SZFriendsFrame *)frame {
    [_frames addObject:frame];
    if (_arrivals[@(frame.type)] == nil) _arrivals[@(frame.type)] = [NSDate date];
    // Every device answers an NN request at once with RECEIVED; so does the rogue.
    if (frame.type == SZFriendsFrameTypeRequestByID) {
        [_channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeReceived fields:@{}]];
    }
}

- (void)notePublicProfile:(NSDictionary<NSNumber *, NSData *> *)profile {
    _publicProfile = [profile copy];
}

- (id)read:(id (^)(void))block {
    __block id value = nil;
    dispatch_sync(_queue, ^{ value = block(); });
    return value;
}

- (BOOL)established {
    return [[self read:^id { return @(self->_established); }] boolValue];
}

- (NSDate *)establishedAt {
    return [self read:^id { return self->_establishedAt; }];
}

- (BOOL)closed {
    return [[self read:^id { return @(self->_closed); }] boolValue];
}

- (NSError *)closeError {
    return [self read:^id { return self->_closeError; }];
}

- (NSDate *)closedAt {
    return [self read:^id { return self->_closedAt; }];
}

- (NSDictionary<NSNumber *, NSData *> *)publicProfile {
    return [self read:^id { return self->_publicProfile; }];
}

- (NSString *)code {
    return [self read:^id { return self->_code; }];
}

- (NSArray<SZFriendsFrame *> *)frames {
    return [self read:^id { return [self->_frames copy]; }];
}

- (NSDate *)firstArrivalOfType:(SZFriendsFrameType)type {
    return [self read:^id { return self->_arrivals[@(type)]; }];
}

- (NSData *)handshakeHash {
    return [self read:^id { return self->_channel.handshakeHash; }];
}

- (BOOL)send:(SZFriendsFrame *)frame {
    return [[self read:^id { return @(self->_channel != nil && [self->_channel sendFrame:frame]); }] boolValue];
}

- (void)runCodeExchange {
    dispatch_sync(_queue, ^{
        __weak SZFE2ERogueSession *weakSelf = self;
        [self->_channel runComparisonCodeExchange:^(NSString *code, NSError *error) {
            (void)error;
            SZFE2ERogueSession *strongSelf = weakSelf;
            if (strongSelf && code) strongSelf->_code = [code copy];
        }];
    });
}

- (void)close {
    dispatch_sync(_queue, ^{ [self->_channel close]; });
}

@end

@interface SZFE2ERogue () <SZFriendsDiscoveryAdapterDelegate>
@end

@implementation SZFE2ERogue {
    dispatch_queue_t _queue;
    id<SZFriendsDiscoveryAdapter> _adapter;
    SZFriendsIdentity *_identity;
    NSData *_tag;
    NSMutableDictionary<NSString *, SZFriendsSighting *> *_sightings;
    NSMutableArray<SZFE2ERogueSession *> *_sessions;
    NSMutableArray<SZFE2ERogueSession *> *_accepted;
}

- (instancetype)initWithServiceType:(NSString *)serviceType {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("szfe.rogue", DISPATCH_QUEUE_SERIAL);
        _adapter = SZFriendsMakeLoopbackNetworkAdapter(_queue, serviceType);
        _adapter.delegate = self;
        _tag = SZFE2ERandomBytes(SZFriendsPresenceTagLength);
        _sightings = [NSMutableDictionary dictionary];
        _sessions = [NSMutableArray array];
        _accepted = [NSMutableArray array];
        [self useFreshIdentity];
    }
    return self;
}

- (SZFriendsIdentity *)identity {
    __block SZFriendsIdentity *identity = nil;
    dispatch_sync(_queue, ^{ identity = self->_identity; });
    return identity;
}

- (void)useFreshIdentity {
    SZFriendsIdentity *identity = [SZFriendsIdentity identityWithSigningSeed:SZFE2ERandomBytes(32)
                                                            staticPrivateKey:SZFE2ERandomBytes(32)];
    dispatch_sync(_queue, ^{ self->_identity = identity; });
}

- (void)start {
    dispatch_sync(_queue, ^{
        [self->_adapter advertisePresenceTag:self->_tag callbackTags:@[] publicEntry:NO];
        [self->_adapter start];
    });
}

- (void)stop {
    dispatch_sync(_queue, ^{
        for (SZFE2ERogueSession *session in self->_sessions) [session closeOnQueue];
        for (SZFE2ERogueSession *session in self->_accepted) [session closeOnQueue];
        [self->_adapter stop];
    });
}

- (nullable NSString *)endpointPublic:(BOOL)wantPublic {
    __block NSString *found = nil;
    dispatch_sync(_queue, ^{
        for (SZFriendsSighting *sighting in self->_sightings.allValues) {
            if (sighting.isPublic != wantPublic) continue;
            BOOL ours = [sighting.presenceTag isEqualToData:self->_tag];
            if (!wantPublic && (sighting.presenceTag == nil || ours)) continue;
            found = sighting.endpointID;
        }
    });
    return found;
}

- (NSString *)publicEndpoint {
    return [self endpointPublic:YES];
}

- (NSString *)hiddenEndpoint {
    return [self endpointPublic:NO];
}

- (SZFE2ERogueSession *)dial:(NSString *)endpointID options:(SZFriendsHandshakeOptions *)options {
    return [self dial:endpointID options:options attestation:nil];
}

- (SZFE2ERogueSession *)dial:(NSString *)endpointID
                     options:(SZFriendsHandshakeOptions *)options
                 attestation:(NSData *)attestation {
    __block SZFE2ERogueSession *session = nil;
    dispatch_sync(_queue, ^{
        SZFE2ERogueSession *pending = [[SZFE2ERogueSession alloc] initWithQueue:self->_queue];
        session = pending;
        [self->_sessions addObject:pending];
        SZFriendsIdentity *identity = self->_identity;
        [self->_adapter openStreamToEndpoint:endpointID
                                  completion:^(id<SZFriendsByteStream> stream, NSError *error) {
                                      dispatch_async(self->_queue, ^{
                                          [self opened:stream error:error session:pending identity:identity
                                               options:options attestation:attestation];
                                      });
                                  }];
    });
    return session;
}

- (void)opened:(id<SZFriendsByteStream>)stream
         error:(NSError *)error
       session:(SZFE2ERogueSession *)session
      identity:(SZFriendsIdentity *)identity
       options:(SZFriendsHandshakeOptions *)options
   attestation:(NSData *)attestation {
    if (stream == nil) {
        [session failOnQueue:error];
        return;
    }
    SZFriendsSecureChannel *channel = [[SZFriendsSecureChannel alloc] initAsInitiatorWithStream:stream
                                                                                       identity:identity
                                                                                        options:options
                                                                                          queue:_queue];
    channel.localAttestation = attestation;
    [session attachChannel:channel];
    if (options.pattern == SZFriendsHandshakeXX && options.browseOnly) {
        __weak SZFE2ERogueSession *weakSession = session;
        channel.onPublicProfile = ^BOOL(NSDictionary<NSNumber *, NSData *> *profile) {
            [weakSession notePublicProfile:profile];
            return NO;
        };
    }
    [channel start];
}

- (NSArray<SZFE2ERogueSession *> *)requestsByID {
    __block NSArray *requests = nil;
    dispatch_sync(_queue, ^{
        NSMutableArray *found = [NSMutableArray array];
        for (SZFE2ERogueSession *session in self->_accepted) {
            if ([session firstArrivalOnQueue:SZFriendsFrameTypeRequestByID]) [found addObject:session];
        }
        requests = found;
    });
    return requests;
}

#pragma mark - SZFriendsDiscoveryAdapterDelegate (on the rogue's queue)

- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didChangeState:(SZFriendsAdapterState)state {
    (void)adapter, (void)state;
}

- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didSight:(SZFriendsSighting *)sighting {
    (void)adapter;
    _sightings[sighting.endpointID] = sighting;
}

- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didLoseEndpoint:(NSString *)endpointID {
    (void)adapter;
    [_sightings removeObjectForKey:endpointID];
}

- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter
    didAcceptStream:(id<SZFriendsByteStream>)stream
              route:(SZFriendsRouteMethod)route {
    (void)adapter, (void)route;
    // Only Add by ID reaches the rogue's listener: it never answers IK or XX.
    SZFriendsRemoteKeyPolicy policy = ^BOOL(NSData *key, SZFriendsHandshakePattern pattern, NSData *token) {
        (void)key, (void)token;
        return pattern == SZFriendsHandshakeNN;
    };
    SZFriendsSecureChannel *channel = [[SZFriendsSecureChannel alloc] initAsResponderWithStream:stream
                                                                                       identity:_identity
                                                                                  publicProfile:nil
                                                                                      keyPolicy:policy
                                                                                          queue:_queue];
    SZFE2ERogueSession *session = [[SZFE2ERogueSession alloc] initWithQueue:_queue];
    [session attachChannel:channel];
    [_accepted addObject:session];
    [channel start];
}

@end
