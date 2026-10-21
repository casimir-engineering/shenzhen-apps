// A test home's network held back (SZFRIENDS_TEST_NETWORK_HOLD, SZFriendsHelperTesting.h): while the file exists the
// wrapped network adapter does not start (no entry, no browse, no listener) and reports its radio off, as a Mac with
// Wi-Fi off; once the file is gone it starts within 100 ms, as Wi-Fi coming up. Creating the file again stops it
// again. The Rust helper does the same (core-rs/crates/szfriends-helper/src/nearby/hold.rs).

#import "service/helper/SZFriendsHelperTesting.h"

#import "service/discovery/SZFriendsDiscoveryInternal.h"
#import "service/helper/SZFriendsHelperInternal.h"

static const NSTimeInterval kHoldPoll = 0.1;

@interface SZFriendsHeldNetworkAdapter : NSObject <SZFriendsDiscoveryAdapter, SZFriendsDiscoveryAdapterDelegate>
@end

@implementation SZFriendsHeldNetworkAdapter {
    dispatch_queue_t _queue;
    id<SZFriendsDiscoveryAdapter> _inner;
    NSString *_file;
    BOOL _wanted; // started by the helper
    BOOL _held;   // started, and held back by the file
    dispatch_source_t _poll;
}

@synthesize delegate = _delegate;

- (instancetype)initWithQueue:(dispatch_queue_t)queue inner:(id<SZFriendsDiscoveryAdapter>)inner file:(NSString *)file {
    if ((self = [super init])) {
        _queue = queue;
        _inner = inner;
        _file = [file copy];
        _inner.delegate = self;
    }
    return self;
}

- (void)dealloc {
    if (_poll) dispatch_source_cancel(_poll);
}

- (SZFriendsDiscoveryMethod)method {
    return _inner.method;
}

- (SZFriendsAdapterState)state {
    return _held ? SZFriendsAdapterStateRadioOff : _inner.state;
}

- (SZFriendsPermission)permissionWithoutPrompting {
    return _inner.permissionWithoutPrompting;
}

- (BOOL)fileExists {
    return [[NSFileManager defaultManager] fileExistsAtPath:_file];
}

- (void)start {
    if (_wanted) return;
    _wanted = YES;
    _poll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_poll, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHoldPoll * NSEC_PER_SEC)),
                              (uint64_t)(kHoldPoll * NSEC_PER_SEC), (uint64_t)(0.02 * NSEC_PER_SEC));
    __weak SZFriendsHeldNetworkAdapter *weakSelf = self;
    dispatch_source_set_event_handler(_poll, ^{ [weakSelf follow]; });
    dispatch_resume(_poll);
    _held = [self fileExists];
    if (_held) {
        SZFriendsHelperLog(@"nearby network: held by the test");
        [self.delegate adapter:self didChangeState:SZFriendsAdapterStateRadioOff];
    } else {
        [_inner start];
    }
}

- (void)stop {
    if (!_wanted) return;
    _wanted = NO;
    if (_poll) dispatch_source_cancel(_poll);
    _poll = nil;
    if (_held) {
        _held = NO;
        [self.delegate adapter:self didChangeState:SZFriendsAdapterStateNotAsked];
    } else {
        [_inner stop];
    }
}

- (void)follow {
    if (!_wanted) return;
    BOOL hold = [self fileExists];
    if (hold == _held) return;
    _held = hold;
    if (hold) {
        SZFriendsHelperLog(@"nearby network: held by the test");
        [_inner stop]; // its NotAsked is not passed on while held
        [self.delegate adapter:self didChangeState:SZFriendsAdapterStateRadioOff];
    } else {
        SZFriendsHelperLog(@"nearby network: released by the test");
        [_inner start];
    }
}

- (void)advertisePresenceTag:(NSData *)tag callbackTags:(NSArray<NSData *> *)callbackTags publicEntry:(BOOL)publicEntry {
    // Kept by the inner adapter until it runs.
    [_inner advertisePresenceTag:tag callbackTags:callbackTags publicEntry:publicEntry];
}

- (void)openStreamToEndpoint:(NSString *)endpointID
                  completion:(void (^)(id<SZFriendsByteStream> stream, NSError *error))completion {
    if (_held || !_wanted) {
        completion(nil, SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorNotRunning, @"the network is held"));
        return;
    }
    [_inner openStreamToEndpoint:endpointID completion:completion];
}

- (void)refreshDiscovery {
    if (!_held && [_inner respondsToSelector:@selector(refreshDiscovery)]) [_inner refreshDiscovery];
}

- (void)setAdmissionLimits:(SZFriendsAdmissionLimits *)limits {
    if ([_inner respondsToSelector:@selector(setAdmissionLimits:)]) [_inner setAdmissionLimits:limits];
}

#pragma mark - From the inner adapter, passed on as this one

- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didChangeState:(SZFriendsAdapterState)state {
    (void)adapter;
    if (_held) return;
    [self.delegate adapter:self didChangeState:state];
}

- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didSight:(SZFriendsSighting *)sighting {
    (void)adapter;
    if (!_held) [self.delegate adapter:self didSight:sighting];
}

- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didLoseEndpoint:(NSString *)endpointID {
    (void)adapter;
    [self.delegate adapter:self didLoseEndpoint:endpointID];
}

- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter
    didAcceptStream:(id<SZFriendsByteStream>)stream
              route:(SZFriendsRouteMethod)route {
    [self adapter:adapter didAcceptStream:stream route:route publicEntry:NO];
}

- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter
    didAcceptStream:(id<SZFriendsByteStream>)stream
              route:(SZFriendsRouteMethod)route
        publicEntry:(BOOL)publicEntry {
    (void)adapter;
    id<SZFriendsDiscoveryAdapterDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(adapter:didAcceptStream:route:publicEntry:)]) {
        [delegate adapter:self didAcceptStream:stream route:route publicEntry:publicEntry];
    } else {
        [delegate adapter:self didAcceptStream:stream route:route];
    }
}

@end

id<SZFriendsDiscoveryAdapter> SZFriendsHelperHoldNetworkAdapter(dispatch_queue_t queue,
                                                                id<SZFriendsDiscoveryAdapter> adapter,
                                                                NSString *file) {
    return [[SZFriendsHeldNetworkAdapter alloc] initWithQueue:queue inner:adapter file:file];
}
