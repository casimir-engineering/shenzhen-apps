// Test support for the online transport suite (SZFOnlineTestSupport.h).

#import "SZFOnlineTestSupport.h"

#include <stdio.h>
#include <unistd.h>

int SZFOFailures = 0;

void SZFOFail(const char *file, int line, const char *expression, NSString *detail) {
    SZFOFailures++;
    fprintf(stderr, "%s:%d: CHECK failed: %s %s\n", file, line, expression, detail.UTF8String);
}

BOOL SZFOWaitUntil(dispatch_queue_t queue, NSTimeInterval timeout, BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MIN(timeout, 10)];
    while (YES) {
        __block BOOL done = NO;
        dispatch_sync(queue, ^{
            done = condition();
        });
        if (done) return YES;
        if ([deadline timeIntervalSinceNow] <= 0) return NO;
        usleep(10000);
    }
}

void SZFOOnQueue(dispatch_queue_t queue, dispatch_block_t block) {
    dispatch_sync(queue, block);
}

NSData *SZFOBytes(uint8_t value, NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    memset(data.mutableBytes, value, count);
    return data;
}

@implementation SZFORequest
+ (instancetype)offererForPurpose:(SZFriendsOnlinePurpose)purpose {
    SZFORequest *request = [self new];
    request.purpose = purpose;
    request.role = SZFriendsOnlineRoleOfferer;
    request.kind = SZFriendsOnlineConnectionDirect;
    request.peer = SZFOBytes(0x42, purpose == SZFriendsOnlinePurposeLink ? 16 : 32);
    return request;
}
@end

@implementation SZFORelayCredentials
@end

@implementation SZFORecorder

- (instancetype)init {
    if ((self = [super init])) {
        _events = [NSMutableArray array];
        _candidates = [NSMutableArray array];
        _techniques = [NSMutableArray array];
        _streams = [NSMutableArray array];
    }
    return self;
}

- (void)note:(NSString *)event {
    [_events addObject:event];
    if (_closedByTest) _eventsAfterClose++;
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
    didCreateLocalDescription:(NSString *)sdp
                  fingerprint:(NSData *)fingerprint {
    (void)connection;
    [self note:@"description"];
    self.sdp = sdp;
    self.fingerprint = fingerprint;
    if (self.onDescription) self.onDescription(sdp, fingerprint);
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
    didGatherLocalCandidate:(NSString *)candidate
                  technique:(SZFriendsOnlineTechnique)technique {
    (void)connection;
    [self note:@"candidate"];
    [_candidates addObject:candidate];
    [_techniques addObject:@(technique)];
    if (self.onCandidate) self.onCandidate(candidate, technique);
}

- (void)onlineConnectionDidFinishGathering:(id<SZFriendsOnlineConnection>)connection {
    (void)connection;
    [self note:@"gathered"];
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
           didOpenStream:(id<SZFriendsByteStream>)stream
                   route:(SZFriendsOnlineRoute)route {
    (void)connection;
    [self note:@"stream"];
    [_streams addObject:stream];
    self.openedRoute = route;
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
                  stream:(id<SZFriendsByteStream>)stream
          didChangeRoute:(SZFriendsOnlineRoute)route {
    (void)connection;
    (void)stream;
    (void)route;
    [self note:@"route"];
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection didFailWithError:(NSError *)error {
    (void)connection;
    [self note:@"failed"];
    self.error = error;
}

@end

@implementation SZFOPair {
    SZFriendsOnlineDataChannelTransport *_transport;
    SZFriendsOnlinePurpose _purpose;
    SZFriendsOnlineConnectionKind _kind;
}

- (instancetype)initWithTransport:(SZFriendsOnlineDataChannelTransport *)transport
                          purpose:(SZFriendsOnlinePurpose)purpose
                             kind:(SZFriendsOnlineConnectionKind)kind {
    if ((self = [super init])) {
        _transport = transport;
        _purpose = purpose;
        _kind = kind;
        _offererQueue = dispatch_queue_create("szfo.offerer", DISPATCH_QUEUE_SERIAL);
        _answererQueue = dispatch_queue_create("szfo.answerer", DISPATCH_QUEUE_SERIAL);
        _offererEvents = [SZFORecorder new];
        _answererEvents = [SZFORecorder new];
    }
    return self;
}

- (BOOL)start {
    __weak SZFOPair *weakSelf = self;
    self.offererEvents.onDescription = ^(NSString *sdp, NSData *fingerprint) {
        [weakSelf openAnswererWithOffer:sdp fingerprint:fingerprint];
    };
    // Each forward is queued on the far side's queue behind what came before it, as the signalling would deliver.
    self.offererEvents.onCandidate = ^(NSString *candidate, SZFriendsOnlineTechnique technique) {
        SZFOPair *pair = weakSelf;
        if (pair == nil) return;
        dispatch_async(pair.answererQueue, ^{
            [pair.answerer addRemoteCandidate:candidate technique:technique error:NULL];
        });
    };
    self.answererEvents.onDescription = ^(NSString *sdp, NSData *fingerprint) {
        SZFOPair *pair = weakSelf;
        if (pair == nil) return;
        dispatch_async(pair.offererQueue, ^{
            [pair.offerer applyRemoteAnswerSDP:sdp remoteFingerprint:fingerprint error:NULL];
        });
    };
    self.answererEvents.onCandidate = ^(NSString *candidate, SZFriendsOnlineTechnique technique) {
        SZFOPair *pair = weakSelf;
        if (pair == nil) return;
        dispatch_async(pair.offererQueue, ^{
            [pair.offerer addRemoteCandidate:candidate technique:technique error:NULL];
        });
    };
    __block BOOL opened = NO;
    dispatch_sync(_offererQueue, ^{
        SZFORequest *request = [SZFORequest offererForPurpose:self->_purpose];
        request.kind = self->_kind;
        request.relay = self.offererRelay;
        NSError *error = nil;
        self->_offerer = [self->_transport openConnection:request
                                                 delegate:self.offererEvents
                                                    queue:self->_offererQueue
                                                    error:&error];
        opened = self->_offerer != nil;
        if (!opened) fprintf(stderr, "offerer did not open: %s\n", error.description.UTF8String);
    });
    return opened;
}

- (void)openAnswererWithOffer:(NSString *)sdp fingerprint:(NSData *)fingerprint {
    NSString *offer = self.rewriteOffer ? self.rewriteOffer(sdp) : sdp;
    NSData *authenticated = self.authenticatedOfferFingerprint ?: fingerprint;
    dispatch_async(_answererQueue, ^{
        SZFORequest *request = [SZFORequest offererForPurpose:self->_purpose];
        request.role = SZFriendsOnlineRoleAnswerer;
        request.kind = self->_kind;
        request.relay = self.answererRelay;
        request.remoteOfferSDP = offer;
        request.remoteFingerprint = authenticated;
        NSError *error = nil;
        self->_answerer = [self->_transport openConnection:request
                                                  delegate:self.answererEvents
                                                     queue:self->_answererQueue
                                                     error:&error];
        if (self->_answerer == nil) self.answererOpenError = error;
    });
}

- (BOOL)waitForStreams {
    BOOL offered = SZFOWaitUntil(_offererQueue, 10, ^BOOL {
        return self.offererEvents.streams.count > 0 || self.offererEvents.error != nil;
    });
    BOOL answered = SZFOWaitUntil(_answererQueue, 10, ^BOOL {
        return self.answererEvents.streams.count > 0 || self.answererEvents.error != nil;
    });
    __block BOOL both = NO;
    SZFOOnQueue(_offererQueue, ^{
        both = self.offererEvents.streams.count > 0;
    });
    SZFOOnQueue(_answererQueue, ^{
        both = both && self.answererEvents.streams.count > 0;
    });
    return offered && answered && both;
}

- (void)close {
    SZFOOnQueue(_offererQueue, ^{
        [self.offerer close];
    });
    SZFOOnQueue(_answererQueue, ^{
        [self.answerer close];
    });
}

@end
