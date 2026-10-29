// Session transcripts: the recording link, the clock and the per-side random source (SZFVectorExportSession.h).

#import "SZFVectorExportSession.h"

#import <sodium.h>

#import "SZFVectorExport.h"
#import "service/session/SZFriendsSecureChannelInternal.h"

#pragma mark - Random source

// The transcript being recorded and the side whose code is running, or -1: set only on the transcript's queue.
static SZFTranscript *gTranscript;
static NSInteger gSide = -1;

@interface SZFTranscript ()
- (void)recordDraw:(NSData *)bytes;
- (void)record:(NSDictionary *)step side:(NSInteger)side;
- (void)schedule:(dispatch_block_t)block side:(SZFSide)side;
@property(nonatomic, readonly) NSTimeInterval now;
@property(nonatomic, readonly) dispatch_queue_t queue;
@end

static void SZFRandomBuf(void *const buffer, const size_t size) {
    if (gTranscript == nil || gSide < 0) {
        randombytes_sysrandom_implementation.buf(buffer, size);
        return;
    }
    [gTranscript recordDraw:[NSData dataWithBytesNoCopy:buffer length:size freeWhenDone:NO]];
}

static uint32_t SZFRandom(void) { return randombytes_sysrandom_implementation.random(); }
static void SZFStir(void) { randombytes_sysrandom_implementation.stir(); }
static int SZFClose(void) { return randombytes_sysrandom_implementation.close(); }
static const char *SZFName(void) { return "szf-transcript"; }

static randombytes_implementation SZFTranscriptRandom = {
    .implementation_name = SZFName, .random = SZFRandom, .stir = SZFStir, .uniform = NULL, .buf = SZFRandomBuf,
    .close = SZFClose,
};

void SZFInstallTranscriptRandom(void) { randombytes_set_implementation(&SZFTranscriptRandom); }

NSString *SZFSideName(SZFSide side) { return side == SZFSideInitiator ? @"initiator" : @"responder"; }

// Runs `block` as `side`: what it draws comes from that side's stream.
static void SZFAsSide(NSInteger side, dispatch_block_t block) {
    NSInteger saved = gSide;
    gSide = side;
    block();
    gSide = saved;
}

#pragma mark - The recording link

@interface SZFTranscriptStream : NSObject <SZFriendsByteStream>
@property(nonatomic, weak) SZFTranscriptStream *peer;
@property(nonatomic) SZFSide side;
@property(nonatomic, weak) SZFTranscript *transcript;
@end

@implementation SZFTranscriptStream {
    BOOL _closed;
}
@synthesize onData = _onData, onClose = _onClose;

- (NSUInteger)preferredWriteSize {
    return 65536;
}

- (void)startWithQueue:(dispatch_queue_t)queue {
    (void)queue;
}

- (void)writeData:(NSData *)data completion:(void (^)(NSError *))completion {
    SZFTranscript *transcript = self.transcript;
    SZFSide side = self.side;
    [transcript record:@{@"write" : SZFHexString(data)} side:side];
    SZFTranscriptStream *peer = self.peer;
    [transcript schedule:^{
        if (peer.onData == nil) return;
        [transcript record:@{@"receive" : SZFHexString(data)} side:peer.side];
        peer.onData(data);
    } side:peer.side];
    [transcript schedule:^{
        [transcript record:@{@"written" : @(data.length)} side:side];
        if (completion) completion(nil);
    } side:side];
}

- (void)close {
    if (_closed) return;
    _closed = YES;
    SZFTranscript *transcript = self.transcript;
    SZFTranscriptStream *peer = self.peer;
    [transcript schedule:^{
        if (peer.onClose == nil) return;
        [transcript record:@{@"eof" : @YES} side:peer.side];
        peer.onClose(nil);
    } side:peer.side];
}

@end

#pragma mark - Transcript

@implementation SZFTranscript {
    NSString *_name;
    dispatch_queue_t _queue;
    NSInteger _pending;
    NSTimeInterval _now;
    NSMutableArray<NSDictionary *> *_steps;
    NSMutableArray<NSMutableArray<NSString *> *> *_draws;
    NSUInteger _drawCount[2];
    NSMutableArray<NSDictionary *> *_timers; // {due, side, block}
    SZFTranscriptStream *_streams[2];
    SZFriendsReplayCache *_replay;
    NSMutableDictionary *_setup[2];
}

- (instancetype)initWithName:(NSString *)name {
    if ((self = [super init])) {
        _name = [name copy];
        _queue = dispatch_queue_create("szf.transcript", DISPATCH_QUEUE_SERIAL);
        _now = 1000;
        _steps = [NSMutableArray array];
        _draws = [@[ [NSMutableArray array], [NSMutableArray array] ] mutableCopy];
        _timers = [NSMutableArray array];
        _rekeyAfterBytes = SZFriendsRekeyAfterBytes;
        __weak SZFTranscript *weakSelf = self;
        _replay = [[SZFriendsReplayCache alloc] initWithCapacity:64 clock:^NSTimeInterval { return weakSelf.now; }];
        for (int i = 0; i < 2; i++) {
            _streams[i] = [[SZFTranscriptStream alloc] init];
            _streams[i].side = (SZFSide)i;
            _streams[i].transcript = self;
            _setup[i] = [NSMutableDictionary dictionary];
        }
        _streams[0].peer = _streams[1];
        _streams[1].peer = _streams[0];
    }
    return self;
}

- (NSTimeInterval)now {
    return _now;
}

- (dispatch_queue_t)queue {
    return _queue;
}

- (void)recordDraw:(NSData *)buffer {
    NSInteger side = gSide;
    NSString *label = [NSString stringWithFormat:@"%@ %@ draw %lu", _name, SZFSideName((SZFSide)side),
                                                 (unsigned long)_drawCount[side]++];
    NSMutableData *bytes = [NSMutableData data];
    for (NSUInteger block = 0; bytes.length < buffer.length; block++) {
        [bytes appendData:SZFDerive([label stringByAppendingFormat:@" %lu", (unsigned long)block], 64)];
    }
    bytes.length = buffer.length;
    memcpy((void *)buffer.bytes, bytes.bytes, bytes.length);
    [_draws[side] addObject:SZFHexString(bytes)];
}

- (void)record:(NSDictionary *)step side:(NSInteger)side {
    NSMutableDictionary *entry = [step mutableCopy];
    entry[@"side"] = side < 0 ? @"both" : SZFSideName((SZFSide)side);
    [_steps addObject:entry];
}

- (void)schedule:(dispatch_block_t)block side:(SZFSide)side {
    _pending++;
    dispatch_async(_queue, ^{
        SZFAsSide(side, block);
        self->_pending--;
    });
}

- (void)drain {
    for (;;) {
        __block NSInteger pending = 0;
        dispatch_sync(_queue, ^{ pending = self->_pending; });
        if (pending == 0) return;
    }
}

- (void)attach:(SZFriendsSecureChannel *)channel side:(SZFSide)side {
    __weak SZFTranscript *weakSelf = self;
    [channel setClock:^NSTimeInterval { return weakSelf.now; }];
    [channel setScheduler:^(NSTimeInterval delay, dispatch_block_t block) {
        SZFTranscript *strongSelf = weakSelf;
        [strongSelf->_timers addObject:@{@"due" : @(strongSelf.now + delay), @"side" : @(side), @"block" : block}];
    }];
    [channel setRekeyAfterBytes:_rekeyAfterBytes interval:SZFriendsRekeyAfterInterval];
    channel.onEstablished = ^{ [weakSelf record:@{@"event" : @"established"} side:side]; };
    channel.onFrame = ^(SZFriendsFrame *frame) {
        [weakSelf record:@{@"event" : @"frame", @"frame" : SZFHexString(SZFriendsEncodeFrame(frame, NULL))} side:side];
    };
    channel.onClose = ^(NSError *error) {
        NSMutableDictionary *event = [@{@"event" : @"closed", @"error" : @(error ? error.code : 0)} mutableCopy];
        NSNumber *reason = error.userInfo[SZFriendsSessionCloseReasonKey];
        if (reason) event[@"reason"] = reason;
        [weakSelf record:event side:side];
    };
    channel.onPublicProfile = ^BOOL(NSDictionary<NSNumber *, NSData *> *profile) {
        NSMutableDictionary *fields = [NSMutableDictionary dictionary];
        for (NSNumber *tag in profile) fields[tag.stringValue] = SZFHexString(profile[tag]);
        [weakSelf record:@{@"event" : @"profile", @"fields" : fields} side:side];
        return YES;
    };
}

- (void)setInitiatorIdentity:(NSString *)name options:(SZFriendsHandshakeOptions *)options {
    _initiator = [[SZFriendsSecureChannel alloc] initAsInitiatorWithStream:_streams[0]
                                                                  identity:SZFVectorIdentity(name)
                                                                   options:options
                                                                     queue:_queue];
    // Recorded as a helper that runs fast transfers (ADR 0018 § 1): the bit is part of every payload with a range.
    _initiator.localCapabilities = SZFriendsCapabilityFastTransfers;
    [self attach:_initiator side:SZFSideInitiator];
    if (options.browseOnly) _initiator.onPublicProfile = nil;
    NSMutableDictionary *setup = _setup[0];
    setup[@"identity"] = name;
    setup[@"pattern"] = @(options.pattern);
    setup[@"route"] = @(options.route);
    setup[@"browse_only"] = @(options.browseOnly);
    if (options.remoteStaticKey) setup[@"remote_static"] = SZFHexString(options.remoteStaticKey);
    if (options.expectedIdentityKey) setup[@"expected_identity"] = SZFHexString(options.expectedIdentityKey);
    if (options.requestToken) setup[@"request_token"] = SZFHexString(options.requestToken);
}

- (void)setResponderIdentity:(NSString *)name
                     profile:(NSDictionary<NSNumber *, NSData *> *)profile
                      policy:(SZFriendsRemoteKeyPolicy)policy {
    NSMutableDictionary *setup = _setup[1];
    NSMutableArray *asked = [NSMutableArray array];
    setup[@"policy"] = asked;
    // The policy's answers are part of the transcript, so the replay answers the same way.
    SZFriendsRemoteKeyPolicy recorded = ^BOOL(NSData *key, SZFriendsHandshakePattern pattern, NSData *token) {
        BOOL allowed = policy(key, pattern, token);
        [asked addObject:@{@"identity" : key ? SZFHexString(key) : [NSNull null], @"pattern" : @(pattern),
                           @"token" : token ? SZFHexString(token) : [NSNull null], @"allowed" : @(allowed)}];
        return allowed;
    };
    _responder = [[SZFriendsSecureChannel alloc] initAsResponderWithStream:_streams[1]
                                                                  identity:SZFVectorIdentity(name)
                                                             publicProfile:profile
                                                                 keyPolicy:recorded
                                                                     queue:_queue];
    _responder.replayCache = _replay;
    _responder.localCapabilities = SZFriendsCapabilityFastTransfers;
    [self attach:_responder side:SZFSideResponder];
    setup[@"identity"] = name;
    if (profile) {
        NSMutableDictionary *fields = [NSMutableDictionary dictionary];
        for (NSNumber *tag in profile) fields[tag.stringValue] = SZFHexString(profile[tag]);
        setup[@"public_profile"] = fields;
    }
}

- (void)side:(SZFSide)side do:(NSString *)action details:(NSDictionary *)details
       block:(void (^)(SZFriendsSecureChannel *))block {
    SZFriendsSecureChannel *channel = side == SZFSideInitiator ? _initiator : _responder;
    dispatch_sync(_queue, ^{
        gTranscript = self;
        NSMutableDictionary *step = [NSMutableDictionary dictionaryWithDictionary:details ?: @{}];
        step[@"do"] = action;
        [self record:step side:side];
        SZFAsSide(side, ^{ block(channel); });
    });
    [self drain];
}

- (void)start {
    for (SZFSide side = SZFSideInitiator; side <= SZFSideResponder; side++) {
        SZFriendsSecureChannel *channel = side == SZFSideInitiator ? _initiator : _responder;
        NSData *attestation = channel.localAttestation;
        if (attestation) _setup[side][@"attestation"] = SZFHexString(attestation);
    }
    // The responder listens first, as a listener does.
    [self side:SZFSideResponder do:@"start" details:nil block:^(SZFriendsSecureChannel *c) { [c start]; }];
    [self side:SZFSideInitiator do:@"start" details:nil block:^(SZFriendsSecureChannel *c) { [c start]; }];
}

- (void)send:(SZFriendsFrame *)frame from:(SZFSide)side {
    NSDictionary *details = @{@"frame" : SZFHexString(SZFriendsEncodeFrame(frame, NULL))};
    [self side:side do:@"send" details:details block:^(SZFriendsSecureChannel *c) {
        if (![c sendFrame:frame]) [self record:@{@"event" : @"send_refused"} side:side];
    }];
}

- (void)runCodeOn:(SZFSide)side {
    [self side:side do:@"code" details:nil block:^(SZFriendsSecureChannel *c) {
        [c runComparisonCodeExchange:^(NSString *code, NSError *error) {
            [self record:@{@"event" : @"code", @"code" : code ?: [NSNull null], @"error" : @(error.code)} side:side];
        }];
    }];
}

- (void)closeSide:(SZFSide)side reason:(SZFriendsCloseReason)reason {
    [self side:side do:@"close" details:@{@"reason" : @(reason)} block:^(SZFriendsSecureChannel *c) {
        [c closeWithReason:reason];
    }];
}

- (void)advance:(NSTimeInterval)seconds {
    dispatch_sync(_queue, ^{
        self->_now += seconds;
        [self record:@{@"advance" : @(seconds)} side:-1];
        NSArray *due = [self->_timers filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"due <= %@", @(self->_now)]];
        [self->_timers removeObjectsInArray:due];
        for (NSDictionary *timer in due) SZFAsSide([timer[@"side"] integerValue], timer[@"block"]);
    });
    [self drain];
}

static NSDictionary *SZFChannelFacts(SZFriendsSecureChannel *c) {
    NSMutableDictionary *facts = [NSMutableDictionary dictionary];
    if (c.remoteIdentityKey) facts[@"remote_identity"] = SZFHexString(c.remoteIdentityKey);
    if (c.remoteStaticKey) facts[@"remote_static"] = SZFHexString(c.remoteStaticKey);
    if (c.remoteAttestation) facts[@"remote_attestation"] = SZFHexString(c.remoteAttestation);
    if (c.presentedRequestToken) facts[@"presented_token"] = SZFHexString(c.presentedRequestToken);
    if (c.handshakeHash) facts[@"handshake_hash"] = SZFHexString(c.handshakeHash);
    facts[@"negotiated_minor"] = @(c.negotiatedMinor);
    facts[@"initiator_route"] = @(c.initiatorRoute);
    facts[@"rekeys"] = @[ @(c.rekeysSent), @(c.rekeysReceived) ];
    return facts;
}

- (NSDictionary *)export {
    __block NSDictionary *result = nil;
    dispatch_sync(_queue, ^{
        NSMutableDictionary *initiator = self->_setup[0], *responder = self->_setup[1];
        initiator[@"random"] = self->_draws[0];
        responder[@"random"] = self->_draws[1];
        initiator[@"facts"] = SZFChannelFacts(self->_initiator);
        responder[@"facts"] = SZFChannelFacts(self->_responder);
        result = @{
            @"name" : self->_name,
            @"rekey_after_bytes" : @(self->_rekeyAfterBytes),
            @"start_seconds" : @1000,
            @"initiator" : initiator,
            @"responder" : responder,
            @"steps" : self->_steps,
        };
        gTranscript = nil;
    });
    return result;
}

@end
