#import "SZFriendsDiscoveryTestSupport.h"

int SZFTestFailures = 0;

NSData *SZFTestData(NSString *hex) {
    NSData *data = SZFriendsDataFromHex(hex);
    if (!data) {
        fprintf(stderr, "bad hex in test: %s\n", hex.UTF8String);
        abort();
    }
    return data;
}

NSData *SZFTestSecret(uint8_t fill) {
    NSMutableData *secret = [NSMutableData dataWithLength:32];
    memset(secret.mutableBytes, fill, 32);
    return secret;
}

NSDate *SZFTestDate(NSTimeInterval secondsSince1970) {
    return [NSDate dateWithTimeIntervalSince1970:secondsSince1970];
}

BOOL SZFTestWait(dispatch_queue_t queue, NSTimeInterval timeout, BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    for (;;) {
        __block BOOL holds = NO;
        dispatch_sync(queue, ^{
            holds = condition();
        });
        if (holds) return YES;
        if ([deadline timeIntervalSinceNow] <= 0) return NO;
        usleep(10000);
    }
}

SZFriendsSighting *SZFTestSighting(SZFriendsDiscoveryMethod method, SZFriendsRouteMethod route, NSString *endpointID,
                                   NSData *tag, NSArray<NSData *> *callbackTags, BOOL isPublic, NSDate *seenAt) {
    return [[SZFriendsSighting alloc] initWithMethod:method
                                               route:route
                                          endpointID:endpointID
                                         presenceTag:tag
                                        callbackTags:callbackTags
                                            isPublic:isPublic
                                              seenAt:seenAt];
}

@implementation SZFTestStream

@synthesize onData = _onData;
@synthesize onClose = _onClose;

- (instancetype)init {
    if ((self = [super init])) {
        _written = [NSMutableData data];
        _name = @"stream";
    }
    return self;
}

- (NSUInteger)preferredWriteSize {
    return 4096;
}

- (void)startWithQueue:(dispatch_queue_t)queue {
    (void)queue;
}

- (void)writeData:(NSData *)data completion:(void (^)(NSError *))completion {
    [self.written appendData:data];
    if (completion) completion(nil);
}

- (void)close {
    self.closed = YES;
}

@end

@implementation SZFTestAdapter {
    SZFriendsDiscoveryMethod _method;
}

@synthesize delegate = _delegate;
@synthesize state = _state;

- (instancetype)initWithMethod:(SZFriendsDiscoveryMethod)method {
    if ((self = [super init])) {
        _method = method;
        _stateOnStart = SZFriendsAdapterStateWorking;
        _advertisedCallbackTags = @[];
        _openRequests = [NSMutableArray array];
        _openStreams = [NSMutableDictionary dictionary];
    }
    return self;
}

- (SZFriendsDiscoveryMethod)method {
    return _method;
}

- (SZFriendsPermission)permissionWithoutPrompting {
    return self.permission;
}

- (void)start {
    _startCount++;
    [self reportState:self.stateOnStart];
}

- (void)stop {
    _stopCount++;
    [self reportState:SZFriendsAdapterStateNotAsked];
}

- (void)refreshDiscovery {
    _refreshCount++;
}

- (void)advertisePresenceTag:(NSData *)tag
                callbackTags:(NSArray<NSData *> *)callbackTags
                 publicEntry:(BOOL)publicEntry {
    if (_startCount == 0) _advertisedBeforeStart = YES;
    _advertisedTag = tag;
    _advertisedCallbackTags = callbackTags;
    _advertisedPublic = publicEntry;
}

- (void)openStreamToEndpoint:(NSString *)endpointID
                  completion:(void (^)(id<SZFriendsByteStream> _Nullable, NSError *_Nullable))completion {
    [self.openRequests addObject:endpointID];
    id<SZFriendsByteStream> stream = self.openStreams[endpointID];
    NSError *error = stream ? nil : SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorUnknownEndpoint, endpointID);
    dispatch_queue_t queue = self.queue ?: dispatch_get_main_queue();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.openDelay * NSEC_PER_SEC)), queue, ^{
        completion(stream, error);
    });
}

- (void)reportState:(SZFriendsAdapterState)state {
    _state = state;
    [self.delegate adapter:self didChangeState:state];
}

- (void)sight:(SZFriendsSighting *)sighting {
    [self.delegate adapter:self didSight:sighting];
}

- (void)lose:(NSString *)endpointID {
    [self.delegate adapter:self didLoseEndpoint:endpointID];
}

- (void)acceptStream:(id<SZFriendsByteStream>)stream publicEntry:(BOOL)publicEntry {
    [self.delegate adapter:self didAcceptStream:stream route:SZFriendsRouteMethodLAN publicEntry:publicEntry];
}

- (void)setAdmissionLimits:(SZFriendsAdmissionLimits *)limits {
    _admissionLimits = [limits copy];
}

@end
