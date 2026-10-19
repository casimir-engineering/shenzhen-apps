// What every attempt shares (SZFriendsOnlineDriverInternal.h): the transport made on the first attempt, the host's
// STUN servers, this network's NAT class, the clock, the technique log and the test hooks.

#import "service/online/driver/SZFriendsOnlineDriverInternal.h"

#import "service/online/nat/SZFriendsNATClassifier.h"
#import "service/online/nat/SZFriendsNATPortMapping.h"
#import "service/online/nat/SZFriendsNATProber.h"
#import "service/online/nat/SZFriendsNATRoute.h"

// The transport's loopback configuration, for the e2e online helper only (SZFriendsOnlineDriverTestHooks): declared
// here rather than by including the transport's internal header, which carries much more.
@interface SZFriendsOnlineDataChannelTransport (SZFriendsOnlineDriverTesting)
- (instancetype)initForTestingWithBindAddress:(NSString *)bindAddress;
@end

static BOOL gLoopbackOnly;
static BOOL (^gDirectPathsBlocked)(void);
static NSHashTable *gDrivers;

@implementation SZFriendsOnlineDriverTestHooks

+ (BOOL)loopbackOnly {
    return gLoopbackOnly;
}

+ (void)setLoopbackOnly:(BOOL)loopbackOnly {
    gLoopbackOnly = loopbackOnly;
}

+ (BOOL (^)(void))directPathsBlocked {
    return gDirectPathsBlocked;
}

+ (void)setDirectPathsBlocked:(BOOL (^)(void))blocked {
    gDirectPathsBlocked = [blocked copy];
}

+ (void)simulateNetworkChange {
    NSArray *drivers = nil;
    @synchronized(self) {
        drivers = gDrivers.allObjects;
    }
    for (SZFriendsOnlineDriver *driver in drivers) [driver networkChanged];
}

+ (void)registerDriver:(SZFriendsOnlineDriver *)driver {
    @synchronized(self) {
        if (gDrivers == nil) gDrivers = [NSHashTable weakObjectsHashTable];
        [gDrivers addObject:driver];
    }
}

@end

// How many attempts the technique log keeps: enough for a support question, small enough to read at once.
static const NSUInteger kTechniqueLogCapacity = 200;

@implementation SZFriendsOnlineContext {
    id<SZFriendsOnlineTransport> _transport;
    SZFriendsNATClassCache *_classCache;
    SZFriendsNATClassifier *_classifier;
    NSString *_classifiedNetwork;
    SZFriendsTechniqueLog *_log;
}

- (instancetype)initWithIdentity:(SZFriendsIdentity *)identity queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _identity = identity;
        _queue = queue;
        _loopbackOnly = gLoopbackOnly;
        _usesDispatchTimers = YES;
        _classCache = [[SZFriendsNATClassCache alloc] init];
        _clock = ^NSTimeInterval { return SZFriendsInstantNow().continuous; };
        _random = ^double { return arc4random_uniform(1u << 30) / (double)(1u << 30); };
        BOOL loopback = _loopbackOnly;
        _portMappingFactory = ^id(uint16_t port, id delegate) {
            // Never in loopback tests: a router is another machine. UPnP stays out until the local fix to miniupnpc's
            // getHTTPResponse (ext/miniupnpc/VENDORED.md § Local changes) is committed and its fuzz target has run
            // clean again: PCP and NAT-PMP are our own, fuzzed code.
            SZFriendsNATPortMappingConfiguration *configuration =
                loopback ? nil : [SZFriendsNATPortMappingConfiguration configurationForPort:port];
            if (configuration == nil) return nil;
            configuration.upnp = nil;
            return [[SZFriendsNATPortMapping alloc] initWithConfiguration:configuration delegate:delegate queue:queue];
        };
        _proberFactory = ^id(id configuration) {
            return [[SZFriendsNATProber alloc] initWithConfiguration:configuration];
        };
    }
    return self;
}

#pragma mark - The transport, on first use

- (BOOL)transportCreated {
    return _transport != nil;
}

- (id<SZFriendsOnlineTransport>)transport {
    if (_transport != nil) return _transport;
    // The first attempt configures the stack (rtcSetThreadPoolSize) and nothing before: the helper's start pays
    // nothing for online Friends.
    SZFriendsOnlineDataChannelTransport *transport =
        _loopbackOnly ? [[SZFriendsOnlineDataChannelTransport alloc] initForTestingWithBindAddress:@"127.0.0.1"]
                      : [SZFriendsOnlineDataChannelTransport sharedTransport];
    __weak SZFriendsOnlineContext *weakSelf = self;
    BOOL loopback = _loopbackOnly;
    transport.sidePathFactory = ^id<SZFriendsOnlineSidePath>(id<SZFriendsOnlineConnectionRequest> request) {
        SZFriendsOnlineContext *strongSelf = weakSelf;
        if (strongSelf == nil || ![request isKindOfClass:[SZFriendsOnlineRequest class]]) return nil;
        SZFriendsOnlineRequest *ours = (SZFriendsOnlineRequest *)request;
        if (!ours.wantsTCPPath) return nil;
        SZFriendsOnlineTCPSidePath *path = [SZFriendsOnlineTCPSidePath sidePathForRequest:request
                                                                              stunServer:strongSelf.stunPrimary
                                                                            loopbackOnly:loopback];
        if (path != nil && ours.onSidePath) ours.onSidePath(path);
        return path;
    };
    _transport = transport;
    return _transport;
}

- (void)setTransport:(id<SZFriendsOnlineTransport>)transport {
    _transport = transport;
}

- (NSString *)stunURI {
    return self.stunPrimary ? SZFriendsOnlineNumericSTUNURI(self.stunPrimary) : nil;
}

- (BOOL)directPathsBlocked {
    BOOL (^blocked)(void) = gDirectPathsBlocked;
    return blocked != nil && blocked();
}

#pragma mark - NAT class (ADR 0011 § NAT class)

- (NSString *)networkKey {
    if (_loopbackOnly) return @"loopback";
    return [SZFriendsNATRoute defaultRouteForFamily:AF_INET].networkKey ?: @"none";
}

- (SZFriendsNATClassification *)currentClassification {
    return [_classCache classificationForNetwork:[self networkKey]];
}

- (SZFriendsNATClass)natClass {
    return [self currentClassification].natClass;
}

- (int16_t)natStep {
    SZFriendsNATClassification *classification = [self currentClassification];
    if (classification.natClass != SZFriendsNATClassPerDestination) return 0;
    return (int16_t)MAX(MIN(classification.step, INT16_MAX), INT16_MIN);
}

// Once per network while the class is unknown: two Binding requests from one socket, to the host's two STUN ports.
- (void)measureNATClass {
    if (_classifier != nil || self.stunPrimary == nil || self.stunSecondary == nil) return;
    NSString *network = [self networkKey];
    if ([_classCache classificationForNetwork:network] != nil) return;
    _classifier = [[SZFriendsNATClassifier alloc] initWithPrimary:self.stunPrimary
                                                        secondary:self.stunSecondary
                                                     loopbackOnly:_loopbackOnly];
    _classifiedNetwork = network;
    __weak SZFriendsOnlineContext *weakSelf = self;
    [_classifier classifyOnQueue:_queue
                      completion:^(SZFriendsNATClassification *classification, NSError *error) {
                          (void)error; // no answer leaves the class unknown: the plain checks are all there is
                          [weakSelf classifier:network finishedWith:classification];
                      }];
}

- (void)classifier:(NSString *)network finishedWith:(SZFriendsNATClassification *)classification {
    _classifier = nil;
    if (classification == nil || ![network isEqualToString:_classifiedNetwork]) return;
    [_classCache setClassification:classification forNetwork:network];
    if (self.onNATClassChanged) self.onNATClassChanged();
}

- (void)networkChanged {
    [_classifier cancel];
    _classifier = nil;
    _classifiedNetwork = nil;
    [_classCache networkDidChange];
}

#pragma mark - Technique log (ADR 0011 § Technique log)

- (SZFriendsTechniqueLog *)techniqueLog {
    if (_log != nil) return _log;
    NSData *data = self.techniqueLogPath ? [NSData dataWithContentsOfFile:self.techniqueLogPath] : nil;
    _log = data ? [[SZFriendsTechniqueLog alloc] initWithJSONData:data capacity:kTechniqueLogCapacity] : nil;
    if (_log == nil) _log = [[SZFriendsTechniqueLog alloc] initWithCapacity:kTechniqueLogCapacity];
    return _log;
}

- (void)appendLogEntry:(SZFriendsTechniqueLogEntry *)entry {
    SZFriendsTechniqueLog *log = self.techniqueLog;
    [log appendEntry:entry];
    // Numbers only (no address, port, key, ID or name), so the file says nothing about who was reached.
    if (self.techniqueLogPath) [[log JSONData] writeToFile:self.techniqueLogPath atomically:YES];
}

@end
