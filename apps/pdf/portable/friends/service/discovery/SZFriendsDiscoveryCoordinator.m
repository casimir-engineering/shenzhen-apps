// Wires the adapters to the merger and the racer for the helper (ADR 0004 § Merger, § Route racing,
// § Permissions at launch). Every adapter is handled on its own; nothing here waits for one method to use another.

#import "service/discovery/SZFriendsDiscoveryCoordinator.h"

// A Bluetooth sighting of a friend with no Wi-Fi sighting asks the network adapter to browse again, at most this
// often, so a friend lingering at the edge of Bluetooth range cannot make it browse continuously.
static const NSTimeInterval kRefreshMinimumInterval = 10;

@implementation SZFriendsDiscoveryCoordinator {
    NSArray<id<SZFriendsDiscoveryAdapter>> *_adapters;
    dispatch_queue_t _queue;
    NSDate * (^_clock)(void);
    NSMutableSet<NSNumber *> *_started;                          // methods whose adapter runs
    NSMutableDictionary<NSNumber *, NSNumber *> *_launchDenied;  // methods reported Denied without starting
    NSMutableDictionary<NSNumber *, NSMutableSet<NSString *> *> *_endpoints; // live endpoint ids per method
    NSUInteger _reportedGeneration;
    dispatch_source_t _expiryTimer;
    NSDate *_lastRefresh;
    BOOL _restarting; // a wake restart: the stop in between is not news for Nearby
    BOOL _hasAdvertisement;
    NSData *_tag;
    NSArray<NSData *> *_callbackTags; // already padded to exactly SZFriendsCallbackTagsMax slots
    SZFriendsCallbackSlots *_slots;
    BOOL _publicEntry;
    SZFriendsAdmissionLimits *_admissionLimits;
}

- (instancetype)initWithAdapters:(NSArray<id<SZFriendsDiscoveryAdapter>> *)adapters
                          merger:(SZFriendsDiscoveryMerger *)merger
                           queue:(dispatch_queue_t)queue
                           clock:(NSDate * (^)(void))clock {
    if ((self = [super init])) {
        _adapters = [adapters copy];
        _merger = merger;
        _racer = [SZFriendsRouteRacer new];
        // Asked at the moment of each dial, so it is always the matcher the helper last gave the merger.
        __weak SZFriendsDiscoveryMerger *weakMerger = merger;
        _racer.tagMatcher = ^NSString *(NSData *tag) {
            SZFriendsTagMatcher matcher = weakMerger.tagMatcher;
            return matcher ? matcher(tag) : nil;
        };
        _queue = queue;
        _clock = [clock copy];
        _started = [NSMutableSet set];
        _launchDenied = [NSMutableDictionary dictionary];
        _endpoints = [NSMutableDictionary dictionary];
        _reportedGeneration = merger.generation;
        _callbackTags = @[];
        _slots = [SZFriendsCallbackSlots new];
        _admissionLimits = [SZFriendsAdmissionLimits defaultLimits];
        _delayScale = 1;
        for (id<SZFriendsDiscoveryAdapter> adapter in _adapters) adapter.delegate = self;
    }
    return self;
}

- (void)dealloc {
    if (_expiryTimer) dispatch_source_cancel(_expiryTimer);
}

- (id<SZFriendsDiscoveryAdapter>)adapterForMethod:(SZFriendsDiscoveryMethod)method {
    for (id<SZFriendsDiscoveryAdapter> adapter in _adapters) {
        if (adapter.method == method) return adapter;
    }
    return nil;
}

#pragma mark - Starting and stopping

- (void)startAtLaunchWithNearbyPermissionsRequested:(BOOL)nearbyPermissionsRequested {
    for (id<SZFriendsDiscoveryAdapter> adapter in _adapters) {
        if ([_started containsObject:@(adapter.method)]) continue;
        SZFriendsPermission permission = adapter.permissionWithoutPrompting;
        if (SZFriendsStartAdapterAtLaunch(permission, nearbyPermissionsRequested)) {
            [self startAdapter:adapter];
        } else if (permission == SZFriendsPermissionDenied) {
            // Starting would not prompt, but ADR 0004 says report it and start nothing: no manager for a method
            // the person turned off.
            _launchDenied[@(adapter.method)] = @YES;
            [self.delegate discoveryCoordinator:self
                                 didChangeState:SZFriendsAdapterStateDenied
                                       ofMethod:adapter.method];
        }
    }
}

- (void)activate {
    for (id<SZFriendsDiscoveryAdapter> adapter in _adapters) {
        if (![_started containsObject:@(adapter.method)]) [self startAdapter:adapter];
    }
}

- (void)startAdapter:(id<SZFriendsDiscoveryAdapter>)adapter {
    [_started addObject:@(adapter.method)];
    [_launchDenied removeObjectForKey:@(adapter.method)];
    if (_hasAdvertisement) {
        [adapter advertisePresenceTag:_tag callbackTags:_callbackTags publicEntry:_publicEntry];
    }
    [adapter start];
}

- (void)restartAfterWake {
    for (id<SZFriendsDiscoveryAdapter> adapter in _adapters) {
        if (![_started containsObject:@(adapter.method)]) continue;
        _restarting = YES;
        [adapter stop];
        _restarting = NO;
        // What the adapter saw before sleep lingers through its grace; anything still there is sighted again.
        [self loseEndpointsOfMethod:adapter.method];
        [self startAdapter:adapter];
    }
    [self changed];
}

- (void)stop {
    for (id<SZFriendsDiscoveryAdapter> adapter in _adapters) {
        BOOL wasStarted = [_started containsObject:@(adapter.method)];
        // Out of the started set first, so the adapter's own Not asked is not reported twice.
        [_started removeObject:@(adapter.method)];
        if (wasStarted) [adapter stop];
        [self loseEndpointsOfMethod:adapter.method];
        if (wasStarted) {
            [self.delegate discoveryCoordinator:self
                                 didChangeState:SZFriendsAdapterStateNotAsked
                                       ofMethod:adapter.method];
        }
    }
    // Disabling forgets: no grace for anything seen before.
    [_merger expireAtDate:[NSDate distantFuture]];
    [self changed];
}

- (SZFriendsAdmissionLimits *)admissionLimits {
    return _admissionLimits;
}

- (void)setAdmissionLimits:(SZFriendsAdmissionLimits *)admissionLimits {
    _admissionLimits = [admissionLimits copy] ?: [SZFriendsAdmissionLimits defaultLimits];
    for (id<SZFriendsDiscoveryAdapter> adapter in _adapters) {
        if ([adapter respondsToSelector:@selector(setAdmissionLimits:)]) [adapter setAdmissionLimits:_admissionLimits];
    }
}

- (SZFriendsAdapterState)stateOfMethod:(SZFriendsDiscoveryMethod)method {
    if (_launchDenied[@(method)]) return SZFriendsAdapterStateDenied;
    if (![_started containsObject:@(method)]) return SZFriendsAdapterStateNotAsked;
    return [self adapterForMethod:method].state;
}

- (void)advertisePresenceTag:(NSData *)tag
                callbackTags:(NSArray<NSData *> *)callbackTags
                 publicEntry:(BOOL)publicEntry {
    _hasAdvertisement = YES;
    _tag = [tag copy];
    // Padded here, once for both adapters: the same slots on Bonjour and Bluetooth, so comparing the two radios
    // cannot tell padding from real tags either.
    id<NSCopying, NSObject> window = tag ?: @(SZFriendsPresenceWindowIndex(_clock()));
    _callbackTags = [_slots slotsForTags:callbackTags rotationKey:window];
    _publicEntry = publicEntry;
    for (id<SZFriendsDiscoveryAdapter> adapter in _adapters) {
        [adapter advertisePresenceTag:_tag callbackTags:_callbackTags publicEntry:_publicEntry];
    }
}

#pragma mark - Adapter delegate

- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didChangeState:(SZFriendsAdapterState)state {
    if (state != SZFriendsAdapterStateWorking && state != SZFriendsAdapterStateStarting) {
        // A method that stopped working stops vouching for its endpoints; they linger, then expire, while the
        // other method's sightings carry on untouched.
        [self loseEndpointsOfMethod:adapter.method];
        [self changed];
    }
    if (![_started containsObject:@(adapter.method)] || _restarting) return; // a stopped adapter's last word
    [self.delegate discoveryCoordinator:self didChangeState:state ofMethod:adapter.method];
}

- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didSight:(SZFriendsSighting *)sighting {
    if (![_started containsObject:@(adapter.method)]) return;
    NSMutableSet<NSString *> *endpoints = _endpoints[@(sighting.method)];
    if (!endpoints) _endpoints[@(sighting.method)] = endpoints = [NSMutableSet set];
    [endpoints addObject:sighting.endpointID];
    [_merger addSighting:sighting];
    if (sighting.method == SZFriendsDiscoveryMethodBluetooth) [self refreshNetworkForSighting:sighting];
    [self changed];
}

- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didLoseEndpoint:(NSString *)endpointID {
    [_endpoints[@(adapter.method)] removeObject:endpointID];
    [_merger removeEndpoint:endpointID method:adapter.method atDate:_clock()];
    [self changed];
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
    [self.delegate discoveryCoordinator:self didAcceptStream:stream route:route publicEntry:publicEntry];
}

#pragma mark - Internals

- (void)loseEndpointsOfMethod:(SZFriendsDiscoveryMethod)method {
    NSDate *now = _clock();
    for (NSString *endpointID in _endpoints[@(method)]) [_merger removeEndpoint:endpointID method:method atDate:now];
    [_endpoints removeObjectForKey:@(method)];
}

- (void)refreshNetworkForSighting:(SZFriendsSighting *)sighting {
    id<SZFriendsDiscoveryAdapter> network = [self adapterForMethod:SZFriendsDiscoveryMethodNetwork];
    if (![network respondsToSelector:@selector(refreshDiscovery)]) return;
    if (![_started containsObject:@(SZFriendsDiscoveryMethodNetwork)]) return;
    for (SZFriendsCandidate *candidate in _merger.candidates) {
        if (!candidate.conversationID) continue;
        BOOL holdsSighting = NO, hasWiFi = NO;
        for (SZFriendsSighting *s in candidate.sightings) {
            holdsSighting =
                holdsSighting || (s.method == sighting.method && [s.endpointID isEqual:sighting.endpointID]);
            hasWiFi = hasWiFi || s.method == SZFriendsDiscoveryMethodNetwork;
        }
        if (!holdsSighting || hasWiFi) continue;
        NSDate *now = _clock();
        if (_lastRefresh && [now timeIntervalSinceDate:_lastRefresh] < kRefreshMinimumInterval) return;
        _lastRefresh = now;
        [network refreshDiscovery];
        return;
    }
}

- (void)changed {
    [self scheduleExpiry];
    if (_merger.generation == _reportedGeneration) return;
    _reportedGeneration = _merger.generation;
    [self.delegate discoveryCoordinatorDidChangeCandidates:self];
}

- (void)expireSightings {
    [_merger expireAtDate:_clock()];
    [self changed];
}

- (void)scheduleExpiry {
    NSDate *next = _merger.nextExpiry;
    if (!next) {
        if (_expiryTimer) dispatch_source_cancel(_expiryTimer);
        _expiryTimer = nil;
        return;
    }
    if (!_expiryTimer) {
        _expiryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        __weak SZFriendsDiscoveryCoordinator *weakSelf = self;
        dispatch_source_set_event_handler(_expiryTimer, ^{
            [weakSelf expireSightings];
        });
        dispatch_resume(_expiryTimer);
    }
    NSTimeInterval wait = MAX(0, [next timeIntervalSinceDate:_clock()]);
    // A quarter-second leeway lets the system batch wakeups; expiry is not that precise anyway (the spike tunes).
    dispatch_source_set_timer(_expiryTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 4);
}

#pragma mark - Dialing

- (void)dialCandidate:(SZFriendsCandidate *)candidate
         currentRoute:(SZFriendsRouteMethod (^)(void))currentRoute
             onStream:(void (^)(id<SZFriendsByteStream> stream, SZFriendsDialAttempt *attempt))onStream {
    SZFriendsRouteMethod (^route)(void) = [currentRoute copy];
    void (^deliver)(id<SZFriendsByteStream>, SZFriendsDialAttempt *) = [onStream copy];
    for (SZFriendsDialAttempt *attempt in [_racer attemptsForCandidate:candidate]) {
        int64_t delay = (int64_t)(attempt.delay * self.delayScale * NSEC_PER_SEC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), _queue, ^{
            if (![self.racer shouldStartAttempt:attempt currentRoute:route()]) return;
            id<SZFriendsDiscoveryAdapter> adapter = [self adapterForMethod:attempt.sighting.method];
            if (!adapter || ![self->_started containsObject:@(adapter.method)]) return;
            [adapter openStreamToEndpoint:attempt.sighting.endpointID
                               completion:^(id<SZFriendsByteStream> stream, NSError *error) {
                                   (void)error; // failures are retried by the next sighting or another route
                                   if (!stream) return;
                                   dispatch_async(self->_queue, ^{
                                       deliver(stream, attempt);
                                   });
                               }];
        });
    }
}

@end
