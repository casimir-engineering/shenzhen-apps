// The scripted network method (SZFriendsE2EScriptedNearby.h).

#import "SZFriendsE2EScriptedNearby.h"

static const NSTimeInterval SZFE2EScriptPoll = 0.25;

@interface SZFE2EScriptedNearby : NSObject <SZFriendsDiscoveryAdapter>
- (instancetype)initWithQueue:(dispatch_queue_t)queue path:(NSString *)path;
@end

@implementation SZFE2EScriptedNearby {
    dispatch_queue_t _queue;
    NSString *_path;
    dispatch_source_t _timer;
    BOOL _started;
}

@synthesize delegate = _delegate;
@synthesize state = _state;

- (instancetype)initWithQueue:(dispatch_queue_t)queue path:(NSString *)path {
    if ((self = [super init])) {
        _queue = queue;
        _path = [path copy];
        _state = SZFriendsAdapterStateNotAsked;
        // Watched from the start, so a state the test writes reaches the helper whether or not it ever starts us.
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFE2EScriptPoll * NSEC_PER_SEC)),
                                  (uint64_t)(SZFE2EScriptPoll * NSEC_PER_SEC), (uint64_t)(0.05 * NSEC_PER_SEC));
        __weak SZFE2EScriptedNearby *weakSelf = self;
        dispatch_source_set_event_handler(_timer, ^{ [weakSelf poll]; });
        dispatch_resume(_timer);
    }
    return self;
}

- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
}

- (NSString *)word {
    NSString *text = [NSString stringWithContentsOfFile:_path encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static SZFriendsAdapterState SZFE2EStateNamed(NSString *word) {
    NSDictionary<NSString *, NSNumber *> *states = @{
        @"not_asked" : @(SZFriendsAdapterStateNotAsked),
        @"starting" : @(SZFriendsAdapterStateStarting),
        @"working" : @(SZFriendsAdapterStateWorking),
        @"denied" : @(SZFriendsAdapterStateDenied),
        @"radio_off" : @(SZFriendsAdapterStateRadioOff),
        @"unavailable" : @(SZFriendsAdapterStateUnavailable),
    };
    NSNumber *state = states[word];
    return state ? (SZFriendsAdapterState)state.integerValue : SZFriendsAdapterStateNotAsked;
}

- (void)poll {
    SZFriendsAdapterState state = SZFE2EStateNamed([self word]);
    // Started while never asked: the system's question is up, and the method reports Starting until it is answered
    // (the test writes the answer).
    if (_started && state == SZFriendsAdapterStateNotAsked) state = SZFriendsAdapterStateStarting;
    if (state == _state) return;
    _state = state;
    [self.delegate adapter:self didChangeState:state];
}

- (SZFriendsDiscoveryMethod)method {
    return SZFriendsDiscoveryMethodNetwork;
}

- (SZFriendsPermission)permissionWithoutPrompting {
    NSString *word = [self word];
    if ([word isEqualToString:@"not_asked"]) return SZFriendsPermissionNotDetermined;
    if ([word isEqualToString:@"denied"]) return SZFriendsPermissionDenied;
    return SZFriendsPermissionAllowed;
}

- (void)start {
    _started = YES;
    NSString *starts = [_path stringByAppendingString:@".starts"];
    NSString *before = [NSString stringWithContentsOfFile:starts encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    [[before stringByAppendingString:@"start\n"] writeToFile:starts atomically:YES encoding:NSUTF8StringEncoding
                                                       error:NULL];
    dispatch_async(_queue, ^{ [self poll]; });
}

- (void)stop {
    _started = NO;
}

- (void)advertisePresenceTag:(NSData *)tag callbackTags:(NSArray<NSData *> *)callbackTags publicEntry:(BOOL)publicEntry {
    (void)tag, (void)callbackTags, (void)publicEntry;
}

- (void)openStreamToEndpoint:(NSString *)endpointID
                  completion:(void (^)(id<SZFriendsByteStream> _Nullable, NSError *_Nullable))completion {
    (void)endpointID;
    dispatch_async(_queue, ^{
        completion(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTCONN userInfo:nil]);
    });
}

@end

id<SZFriendsDiscoveryAdapter> SZFriendsE2EMakeScriptedNearbyAdapter(dispatch_queue_t queue, NSString *scriptPath) {
    return [[SZFE2EScriptedNearby alloc] initWithQueue:queue path:scriptPath];
}
