// The refusal rig the session's refusal tests share (SZFRefusalRig.h).

#import "SZFRefusalRig.h"

#import "SZFriendsSessionTests.h"
#import "service/session/SZFriendsSecureChannelInternal.h"

@implementation SZFAdmissionStream {
    SZFMemoryStream *_inner;
}

- (instancetype)initWithStream:(SZFMemoryStream *)stream {
    if ((self = [super init])) {
        _inner = stream;
        _admit = YES;
        _askedPatterns = [NSMutableArray array];
    }
    return self;
}
- (NSUInteger)preferredWriteSize {
    return _inner.preferredWriteSize;
}
- (void (^)(NSData *))onData {
    return _inner.onData;
}
- (void)setOnData:(void (^)(NSData *))onData {
    _inner.onData = onData;
}
- (void (^)(NSError *))onClose {
    return _inner.onClose;
}
- (void)setOnClose:(void (^)(NSError *))onClose {
    _inner.onClose = onClose;
}
- (void)startWithQueue:(dispatch_queue_t)queue {
    [_inner startWithQueue:queue];
}
- (void)writeData:(NSData *)data completion:(void (^)(NSError *))completion {
    [_inner writeData:data completion:completion];
}
- (void)close {
    [_inner close];
}
- (BOOL)admitHandshakePattern:(SZFriendsHandshakePattern)pattern {
    [_askedPatterns addObject:@(pattern)];
    if (_onAsk) _onAsk();
    return _admit;
}
- (void)handshakeDidReceiveFirstMessage {
    _firstMessages++;
}
- (void)sessionDidAuthenticate {
    _authenticated++;
}

@end

@implementation SZFRefusalRig

+ (instancetype)rigFor:(SZFriendsIdentity *)identity
               profile:(NSDictionary *)profile
                 cache:(SZFriendsReplayCache *)cache
                policy:(SZFRigPolicy)policy {
    SZFRefusalRig *rig = [self new];
    rig.queue = dispatch_queue_create("szfriends.session.refusal", DISPATCH_QUEUE_SERIAL);
    rig.timers = [NSMutableArray array];
    NSArray<SZFMemoryStream *> *streams = [SZFMemoryStream pair];
    rig.peerEnd = streams[0];
    rig.listenerEnd = streams[1];
    rig.stream = [[SZFAdmissionStream alloc] initWithStream:streams[1]];
    __weak SZFRefusalRig *weakRig = rig;
    rig.responder = [[SZFriendsSecureChannel alloc]
        initAsResponderWithStream:rig.stream
                         identity:identity
                    publicProfile:profile
                        keyPolicy:^BOOL(NSData *key, SZFriendsHandshakePattern pattern, NSData *token) {
                            (void)key, (void)token;
                            SZFRefusalRig *strongRig = weakRig;
                            strongRig.policyCalls++;
                            return policy ? policy(strongRig, pattern) : YES;
                        }
                            queue:rig.queue];
    rig.responder.replayCache = cache ?: [[SZFriendsReplayCache alloc] init];
    [rig.responder setClock:^NSTimeInterval {
        return weakRig.now;
    }];
    [rig.responder setScheduler:^(NSTimeInterval delay, dispatch_block_t block) {
        SZFRefusalRig *strongRig = weakRig;
        [strongRig.timers addObject:@[ @(strongRig.now + delay), [block copy] ]];
    }];
    rig.responder.onClose = ^(NSError *error) {
        SZFRefusalRig *strongRig = weakRig;
        strongRig.closed = YES;
        strongRig.error = error;
        strongRig.closedAt = strongRig.now;
    };
    SZFOnQueue(rig.queue, ^{
        [rig.peerEnd startWithQueue:rig.queue];
        [rig.responder start];
    });
    return rig;
}

- (void)deliver:(NSData *)bytes at:(NSTimeInterval)time {
    SZFOnQueue(_queue, ^{
        self.now = time;
        [self.peerEnd writeData:bytes completion:nil];
    });
    SZFDrain(_queue);
}

- (void)fireTimers {
    SZFOnQueue(_queue, ^{
        NSArray<NSArray *> *due = [self.timers copy];
        [self.timers removeAllObjects];
        for (NSArray *timer in due) {
            self.now = [timer[0] doubleValue];
            ((dispatch_block_t)timer[1])();
        }
    });
    SZFDrain(_queue);
}

@end

NSData *SZFMessage1(SZFriendsHandshakeOptions *options, SZFriendsIdentity *initiator) {
    dispatch_queue_t queue = dispatch_queue_create("szfriends.session.message1", DISPATCH_QUEUE_SERIAL);
    NSArray<SZFMemoryStream *> *streams = [SZFMemoryStream pair];
    SZFriendsSecureChannel *channel = [[SZFriendsSecureChannel alloc] initAsInitiatorWithStream:streams[0]
                                                                                       identity:initiator
                                                                                        options:options
                                                                                          queue:queue];
    __block NSData *bytes = nil;
    SZFOnQueue(queue, ^{
        [streams[1] startWithQueue:queue];
        [channel start];
        bytes = [streams[0].transcript copy];
        [channel close];
    });
    SZFDrain(queue);
    return bytes;
}

NSTimeInterval SZFExpectQuietRefusal(SZFRefusalRig *rig, NSData *message, NSTimeInterval arrival,
                                            SZFRefusalCase expected) {
    NSString *label = @(expected.label);
    [rig deliver:message at:arrival];
    // Bytes after the refusal are not read: they change neither the deadline nor anything else.
    [rig deliver:SZFRandomBytes(80) at:arrival + 0.5];
    __block NSTimeInterval fireAt = -1;
    SZFOnQueue(rig.queue, ^{
        SZF_CHECK(!rig.closed && !rig.listenerEnd.closed, @"%@: closed before the refusal deadline", label);
        SZF_CHECK(rig.listenerEnd.transcript.length == 0, @"%@: the responder wrote nothing", label);
        SZF_CHECK(rig.timers.count == 1, @"%@: one deadline, got %lu", label, (unsigned long)rig.timers.count);
        fireAt = rig.timers.count ? [rig.timers[0][0] doubleValue] : -1;
    });
    SZF_CHECK(fabs(fireAt - (arrival + SZFriendsRefusalDelay)) < 1e-9, @"%@: deadline %.6f after arrival", label,
              fireAt - arrival);
    [rig fireTimers];
    __block NSTimeInterval closedAfter = -1;
    SZFOnQueue(rig.queue, ^{
        SZF_CHECK(rig.closed && rig.listenerEnd.closed, @"%@: closed at the deadline", label);
        SZF_CHECK(rig.error.code == expected.code, @"%@: reason %@", label, rig.error);
        SZF_CHECK(rig.listenerEnd.transcript.length == 0, @"%@: still nothing written", label);
        closedAfter = rig.closedAt - arrival;
    });
    return closedAfter;
}
