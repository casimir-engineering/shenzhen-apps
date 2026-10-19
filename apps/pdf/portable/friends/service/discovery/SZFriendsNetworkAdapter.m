// The Network.framework adapter (ADR 0004 § Decision): one browser and one hidden listener for the Friends
// Bonjour type over TCP with peer-to-peer Wi-Fi, plus a public listener during the person's 5 minutes. C nw_* API.
// The browser and path monitor are in +Browse.

#import "service/discovery/SZFriendsNetworkAdapterInternal.h"

#include <stdatomic.h>

static atomic_uint gNetworkObjectsCreated;

NSUInteger SZFriendsNetworkObjectsCreated(void) {
    return atomic_load(&gNetworkObjectsCreated);
}

void SZFriendsNoteNetworkObjectCreated(void) {
    atomic_fetch_add(&gNetworkObjectsCreated, 1);
}

// Our own recent instance names, so the browser never sights this Mac: a rotated name lingers in other
// browsers' results for a moment after it is replaced.
static const NSUInteger kOwnNamesRemembered = 8;

@implementation SZFriendsNetworkAdapterOptions

- (instancetype)init {
    if ((self = [super init])) {
        _serviceType = SZFriendsBonjourServiceType;
        _connectTimeout = 10;
        _retryDelay = 5;
        _listenerOverlap = 30;
        _clock = ^NSDate * {
            return [NSDate date];
        };
    }
    return self;
}

@end

// Where a connection came from, as the per-address admission limit counts it (SZFriendsAdmissionKeyForAddress).
static NSString *AdmissionKey(nw_connection_t connection) {
    nw_endpoint_t endpoint = nw_connection_copy_endpoint(connection);
    if (!endpoint) return nil;
    if (nw_endpoint_get_type(endpoint) == nw_endpoint_type_address) {
        return SZFriendsAdmissionKeyForAddress(nw_endpoint_get_address(endpoint));
    }
    const char *host = nw_endpoint_get_hostname(endpoint);
    return host ? [@"host:" stringByAppendingString:@(host)] : nil;
}

@implementation SZFriendsNetworkAdapter {
    nw_listener_t _hiddenListener;
    id _hiddenListenerKey;   // the window the hidden listener stands for (SZFriendsNetworkAdapter -hiddenKey)
    NSUInteger _hiddenGeneration; // which hidden listener's state changes still matter
    NSMutableArray<nw_listener_t> *_retiringListeners;
    nw_listener_t _publicListener;
    NSData *_tag;
    NSArray<NSData *> *_callbackTags;
    SZFriendsCallbackSlots *_slots;
    BOOL _publicEntry;
    NSString *_hiddenName;
    NSString *_publicName;
    NSMutableSet<SZFriendsNetworkStream *> *_connecting;
    SZFriendsAdmissionController *_admission;
}

@synthesize delegate = _delegate;
@synthesize state = _state;

- (instancetype)initWithQueue:(dispatch_queue_t)queue options:(SZFriendsNetworkAdapterOptions *)options {
    if ((self = [super init])) {
        _queue = queue;
        _options = options;
        _callbackTags = @[];
        _slots = [SZFriendsCallbackSlots new];
        _ownNames = [NSMutableArray array];
        _endpoints = [NSMutableDictionary dictionary];
        _connecting = [NSMutableSet set];
        _retiringListeners = [NSMutableArray array];
        _admission = [[SZFriendsAdmissionController alloc] initWithClock:nil];
    }
    return self;
}

- (SZFriendsDiscoveryMethod)method {
    return SZFriendsDiscoveryMethodNetwork;
}

- (SZFriendsPermission)permissionWithoutPrompting {
    // Local Network access has no query API (ADR 0004): only a refusal seen while running tells.
    return _policyDenied ? SZFriendsPermissionDenied : SZFriendsPermissionUnknown;
}

- (void)setAdmissionLimits:(SZFriendsAdmissionLimits *)limits {
    _admission.limits = limits;
}

- (nw_parameters_t)parameters {
    nw_parameters_t parameters =
        nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, ^(nw_protocol_options_t tcp) {
            nw_tcp_options_set_no_delay(tcp, true);
            nw_tcp_options_set_enable_keepalive(tcp, true);
            nw_tcp_options_set_keepalive_idle_time(tcp, 30);
        });
    if (_options.loopbackOnly) {
        // Tests and the two-helper harness: lo0 only. Prohibiting every other type as well means a change in how
        // the required type is honoured can never put a test on the real network (a Local Network prompt).
        nw_parameters_set_required_interface_type(parameters, nw_interface_type_loopback);
        nw_parameters_prohibit_interface_type(parameters, nw_interface_type_wifi);
        nw_parameters_prohibit_interface_type(parameters, nw_interface_type_wired);
        nw_parameters_prohibit_interface_type(parameters, nw_interface_type_cellular);
        nw_parameters_prohibit_interface_type(parameters, nw_interface_type_other);
        nw_parameters_set_include_peer_to_peer(parameters, false);
    } else {
        nw_parameters_set_include_peer_to_peer(parameters, true);
    }
    return parameters;
}

#pragma mark - Lifecycle

- (void)start {
    if (_running) return;
    _running = YES;
    [self setUp];
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    [self tearDown];
    [self updateState];
}

- (void)setUp {
    _run++;
    _browserReady = _listenerReady = _policyDenied = _radioOff = _failed = NO;
    [self updateState];
    [self updateHiddenAdvertisement];
    [self updatePublicListener];
    [self startBrowser];
    if (!_options.loopbackOnly) [self startPathMonitor];
}

- (void)tearDown {
    _run++;
    if (_browser) nw_browser_cancel(_browser);
    if (_hiddenListener) nw_listener_cancel(_hiddenListener);
    for (nw_listener_t listener in _retiringListeners) nw_listener_cancel(listener);
    [_retiringListeners removeAllObjects];
    if (_publicListener) nw_listener_cancel(_publicListener);
    if (_monitor) nw_path_monitor_cancel(_monitor);
    _browser = nil;
    _hiddenListener = _publicListener = nil;
    _hiddenListenerKey = nil;
    _monitor = nil;
    _hiddenName = _publicName = nil;
    // Said out loud rather than dropped, so whoever holds these endpoints starts their grace now.
    for (NSString *endpointID in _endpoints.allKeys) [self.delegate adapter:self didLoseEndpoint:endpointID];
    [_endpoints removeAllObjects];
    for (SZFriendsNetworkStream *stream in _connecting) [stream cancel];
}

- (void)updateState {
    SZFriendsAdapterState state = SZFriendsNetworkAdapterState(_running, _policyDenied, _radioOff, _failed,
                                                               _browserReady, _listenerReady);
    if (state == _state) return;
    _state = state;
    [self.delegate adapter:self didChangeState:state];
}

- (void)retryLater {
    NSUInteger run = _run;
    __weak SZFriendsNetworkAdapter *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_options.retryDelay * NSEC_PER_SEC)), _queue, ^{
        SZFriendsNetworkAdapter *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_run != run || !strongSelf->_running) return;
        // Straight from Unavailable to Starting: Nearby never shows the method as not asked in between.
        [strongSelf tearDown];
        [strongSelf setUp];
    });
}

- (void)noteError:(nw_error_t)error failed:(BOOL)failed {
    if (SZFriendsNetworkErrorIsPolicyDenied(error)) {
        _policyDenied = YES;
    } else if (failed) {
        _failed = YES;
        [self retryLater];
    }
    [self updateState];
}

#pragma mark - Advertising

- (void)advertisePresenceTag:(NSData *)tag
                callbackTags:(NSArray<NSData *> *)callbackTags
                 publicEntry:(BOOL)publicEntry {
    _tag = [tag copy];
    _callbackTags = [callbackTags copy];
    _publicEntry = publicEntry;
    if (!_running) return;
    [self updateHiddenAdvertisement];
    [self updatePublicListener];
}

- (NSString *)freshOwnName {
    NSString *name = SZFriendsRandomInstanceName();
    [_ownNames addObject:name];
    if (_ownNames.count > kOwnNamesRemembered) [_ownNames removeObjectAtIndex:0];
    return name;
}

- (nw_advertise_descriptor_t)descriptorNamed:(NSString *)name fields:(NSDictionary<NSString *, NSData *> *)fields {
    nw_advertise_descriptor_t descriptor = nw_advertise_descriptor_create_bonjour_service(
        name.UTF8String, _options.serviceType.UTF8String, "local");
    nw_txt_record_t txt = nw_txt_record_create_dictionary();
    for (NSString *key in fields) {
        nw_txt_record_set_key(txt, key.UTF8String, fields[key].bytes, fields[key].length);
    }
    nw_advertise_descriptor_set_txt_record_object(descriptor, txt);
    return descriptor;
}

// The window the hidden entry stands for: its presence tag, or the window index when it has none. A new key is a
// new window or a rotated presence secret.
- (id<NSCopying, NSObject>)hiddenKey {
    return _tag ?: @(SZFriendsPresenceWindowIndex(_options.clock()));
}

// ADR 0004 promises strangers cannot link one window to the next, but a listener's port stays with it: a stranger
// browsing would see the new tag and name on the old port. So each window gets its own listener, and with it a new
// port and name; the TXT within a window may change (callback tags, visibility) on the same listener.
- (void)updateHiddenAdvertisement {
    id<NSCopying, NSObject> key = [self hiddenKey];
    if (_hiddenListener && ![key isEqual:_hiddenListenerKey]) [self retireHiddenListener];
    NSDictionary<NSString *, NSData *> *fields =
        SZFriendsNetworkTXTFields(_tag, [_slots slotsForTags:_callbackTags rotationKey:key], NO);
    if (_hiddenListener) {
        nw_listener_set_advertise_descriptor(_hiddenListener, [self descriptorNamed:_hiddenName fields:fields]);
        return;
    }
    _hiddenListener = [self makeListenerPublic:NO];
    _hiddenListenerKey = [key copyWithZone:nil];
    _hiddenName = [self freshOwnName];
    nw_listener_set_advertise_descriptor(_hiddenListener, [self descriptorNamed:_hiddenName fields:fields]);
    nw_listener_start(_hiddenListener);
}

// Off the air at once, so a browser never sees the old entry beside the new one, but still accepting for a short
// overlap: a friend who resolved the old entry just before the window ended is already connecting to its port.
- (void)retireHiddenListener {
    nw_listener_t old = _hiddenListener;
    _hiddenListener = nil;
    _hiddenListenerKey = nil;
    _hiddenName = nil;
    _hiddenGeneration++;
    nw_listener_set_advertise_descriptor(old, NULL);
    [_retiringListeners addObject:old];
    __weak SZFriendsNetworkAdapter *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_options.listenerOverlap * NSEC_PER_SEC)), _queue, ^{
        nw_listener_cancel(old);
        SZFriendsNetworkAdapter *strongSelf = weakSelf;
        if (strongSelf) [strongSelf->_retiringListeners removeObject:old];
    });
}

- (nw_listener_t)makeListenerPublic:(BOOL)publicEntry {
    nw_listener_t listener = nw_listener_create([self parameters]);
    SZFriendsNoteNetworkObjectCreated();
    nw_listener_set_queue(listener, _queue);
    NSUInteger run = _run, generation = _hiddenGeneration;
    __weak SZFriendsNetworkAdapter *weakSelf = self;
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        SZFriendsNetworkAdapter *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_run != run) return;
        // A retired hidden listener's last words say nothing about the adapter.
        if (!publicEntry && strongSelf->_hiddenGeneration != generation) return;
        if (state == nw_listener_state_ready && !publicEntry) {
            strongSelf->_listenerReady = YES;
            [strongSelf updateState];
        } else if (state == nw_listener_state_waiting || state == nw_listener_state_failed) {
            [strongSelf noteError:error failed:state == nw_listener_state_failed];
        }
    });
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
        SZFriendsNetworkAdapter *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_run != run) {
            nw_connection_cancel(connection);
            return;
        }
        [strongSelf acceptConnection:connection publicEntry:publicEntry];
    });
    return listener;
}

- (void)updatePublicListener {
    if (!_running) return;
    if (_publicEntry && !_publicListener) {
        // A separate listener, so a connection says by its port which entry it came through.
        _publicListener = [self makeListenerPublic:YES];
        _publicName = [self freshOwnName];
        nw_listener_set_advertise_descriptor(
            _publicListener, [self descriptorNamed:_publicName fields:SZFriendsNetworkTXTFields(nil, @[], YES)]);
        nw_listener_start(_publicListener);
    } else if (!_publicEntry && _publicListener) {
        nw_listener_cancel(_publicListener);
        _publicListener = nil;
        _publicName = nil;
    }
}

- (NSArray<NSNumber *> *)hiddenPorts {
    NSMutableArray<NSNumber *> *ports = [NSMutableArray array];
    if (_hiddenListener) [ports addObject:@(nw_listener_get_port(_hiddenListener))];
    for (nw_listener_t listener in _retiringListeners) [ports addObject:@(nw_listener_get_port(listener))];
    return ports;
}

#pragma mark - Connections

- (void)acceptConnection:(nw_connection_t)connection publicEntry:(BOOL)publicEntry {
    SZFriendsNetworkStream *stream = [[SZFriendsNetworkStream alloc] initWithConnection:connection
                                                                        connectionQueue:_queue];
    // Admitted before the connection is even ready, so connections that never finish count too. Never refused: a
    // full listener or address closes its oldest connection that has not authenticated instead.
    id<SZFriendsByteStream> admitted = [_admission admitStream:stream
                                                      listener:publicEntry ? @"public" : @"hidden"
                                                       address:AdmissionKey(connection)];
    [_connecting addObject:stream];
    NSUInteger run = _run;
    __weak SZFriendsNetworkAdapter *weakSelf = self;
    [stream connectWithTimeout:_options.connectTimeout
                         ready:^(NSError *error) {
                             SZFriendsNetworkAdapter *strongSelf = weakSelf;
                             if (strongSelf) [strongSelf->_connecting removeObject:stream];
                             if (!strongSelf || error || strongSelf->_run != run) {
                                 [admitted close]; // gives its place back
                                 return;
                             }
                             [strongSelf deliverAcceptedStream:admitted
                                                         route:stream.pathRoute
                                                   publicEntry:publicEntry];
                         }];
}

- (void)deliverAcceptedStream:(id<SZFriendsByteStream>)stream
                        route:(SZFriendsRouteMethod)route
                  publicEntry:(BOOL)publicEntry {
    id<SZFriendsDiscoveryAdapterDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(adapter:didAcceptStream:route:publicEntry:)]) {
        [delegate adapter:self didAcceptStream:stream route:route publicEntry:publicEntry];
    } else {
        [delegate adapter:self didAcceptStream:stream route:route];
    }
}

- (void)openStreamToEndpoint:(NSString *)endpointID
                  completion:(void (^)(id<SZFriendsByteStream> _Nullable, NSError *_Nullable))completion {
    void (^done)(id<SZFriendsByteStream>, NSError *) = [completion copy];
    nw_endpoint_t endpoint = _endpoints[endpointID];
    if (!_running || !endpoint) {
        NSError *error = _running ? SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorUnknownEndpoint, endpointID)
                                  : SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorNotRunning, @"stopped");
        dispatch_async(_queue, ^{
            done(nil, error);
        });
        return;
    }
    nw_connection_t connection = nw_connection_create(endpoint, [self parameters]);
    SZFriendsNetworkStream *stream = [[SZFriendsNetworkStream alloc] initWithConnection:connection
                                                                        connectionQueue:_queue];
    [_connecting addObject:stream];
    __weak SZFriendsNetworkAdapter *weakSelf = self;
    [stream connectWithTimeout:_options.connectTimeout
                         ready:^(NSError *error) {
                             SZFriendsNetworkAdapter *strongSelf = weakSelf;
                             if (strongSelf) [strongSelf->_connecting removeObject:stream];
                             done(error ? nil : stream, error);
                         }];
}

@end

NSArray<NSNumber *> *SZFriendsNetworkAdapterHiddenPorts(id<SZFriendsDiscoveryAdapter> adapter) {
    return [adapter isKindOfClass:[SZFriendsNetworkAdapter class]] ? [(SZFriendsNetworkAdapter *)adapter hiddenPorts]
                                                                   : @[];
}

id<SZFriendsDiscoveryAdapter> SZFriendsMakeNetworkAdapterWithOptions(dispatch_queue_t queue,
                                                                      SZFriendsNetworkAdapterOptions *options) {
    return [[SZFriendsNetworkAdapter alloc] initWithQueue:queue options:options];
}

id<SZFriendsDiscoveryAdapter> SZFriendsMakeNetworkAdapter(dispatch_queue_t queue) {
    return SZFriendsMakeNetworkAdapterWithOptions(queue, [SZFriendsNetworkAdapterOptions new]);
}

id<SZFriendsDiscoveryAdapter> SZFriendsMakeLoopbackNetworkAdapter(dispatch_queue_t queue, NSString *serviceType) {
    SZFriendsNetworkAdapterOptions *options = [SZFriendsNetworkAdapterOptions new];
    options.loopbackOnly = YES;
    options.serviceType = serviceType;
    return SZFriendsMakeNetworkAdapterWithOptions(queue, options);
}
