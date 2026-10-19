// TCP simultaneous open (SZFriendsNATTCPPath.h).

#import "service/online/nat/SZFriendsNATTCPPath.h"

#import "service/online/nat/SZFriendsNATPrediction.h"
#import "service/online/nat/SZFriendsNATRoute.h"
#import "service/online/nat/SZFriendsNATSocketStream.h"
#import "service/online/nat/SZFriendsNATStun.h"

#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <unistd.h>

enum {
    kBindAttempts = 5,          // ports tried when IPv6 cannot take the port IPv4 got
    kQuickRedials = 20,         // refusals answered with a quick redial before calling only once a second
    kPreferenceHostIPv6 = 65535,
    kPreferenceHostIPv4 = 60000,
    kPreferenceMapped = 50000,
};

static NSError *PathError(SZFriendsNATError code) {
    return [NSError errorWithDomain:SZFriendsNATErrorDomain code:code userInfo:nil];
}

@implementation SZFriendsNATTCPPathConfiguration

- (instancetype)init {
    if ((self = [super init])) {
        _purpose = SZFriendsOnlinePurposeFriend;
        _budget = 5;
        _redialAfterSilence = 1;
        _redialAfterRefusal = 0.01;
        _stunBudget = 2;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    SZFriendsNATTCPPathConfiguration *copy = [[[self class] allocWithZone:zone] init];
    copy.purpose = _purpose;
    copy.localPort = _localPort;
    copy.stunServer = _stunServer;
    copy.budget = _budget;
    copy.redialAfterSilence = _redialAfterSilence;
    copy.redialAfterRefusal = _redialAfterRefusal;
    copy.stunBudget = _stunBudget;
    copy.loopbackOnly = _loopbackOnly;
    return copy;
}

@end

// One connect() in flight from the path's port: a socket, its writability source, and its silence timer.
@interface SZFriendsNATTCPAttempt : NSObject
@property(nonatomic) int fd;
@property(nonatomic, strong, nullable) dispatch_source_t writer;
@property(nonatomic, strong, nullable) dispatch_source_t timer;
@property(nonatomic) NSUInteger refusals; // so far: past kQuickRedials, a refused endpoint is called once a second
@end

@implementation SZFriendsNATTCPAttempt
- (instancetype)init {
    if ((self = [super init])) _fd = -1; // no socket yet: never descriptor 0
    return self;
}

- (void)stopKeepingDescriptor:(BOOL)keep {
    if (_timer != nil) dispatch_source_cancel(_timer);
    _timer = nil;
    int fd = _fd;
    _fd = -1;
    if (_writer != nil) {
        if (!keep) {
            dispatch_source_set_cancel_handler(_writer, ^{
                close(fd);
            });
        }
        dispatch_source_cancel(_writer);
        _writer = nil;
    } else if (fd >= 0 && !keep) {
        close(fd);
    }
}
@end

@implementation SZFriendsNATTCPPath {
    SZFriendsNATTCPPathConfiguration *_configuration;
    __weak id<SZFriendsNATTCPPathDelegate> _delegate;
    dispatch_queue_t _queue;
    int _anchors[2]; // one socket per family holding the port; never listening, never connected
    NSMutableDictionary<SZFriendsNATEndpoint *, SZFriendsNATTCPAttempt *> *_attempts;
    NSMutableSet<NSString *> *_offered;
    int _stunFD;
    dispatch_source_t _stunWriter, _stunReader, _budgetTimer, _stunTimer;
    BOOL _stunWriterSuspended;
    NSMutableData *_stunBuffer;
    uint8_t _stunTransaction[SZFriendsStunTransactionLength];
    BOOL _started, _finished, _gatheringDone;
}

- (instancetype)initWithConfiguration:(SZFriendsNATTCPPathConfiguration *)configuration
                             delegate:(id<SZFriendsNATTCPPathDelegate>)delegate
                                queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _configuration = [configuration copy];
        _delegate = delegate;
        _queue = queue;
        _anchors[0] = _anchors[1] = -1;
        _stunFD = -1;
        _attempts = [NSMutableDictionary dictionary];
        _offered = [NSMutableSet set];
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (SZFriendsNATEndpoint *)bindAddressForFamily:(sa_family_t)family port:(uint16_t)port {
    NSString *host = family == AF_INET6 ? (_configuration.loopbackOnly ? @"::1" : @"::")
                                        : (_configuration.loopbackOnly ? @"127.0.0.1" : @"0.0.0.0");
    return [SZFriendsNATEndpoint endpointWithHost:host port:port];
}

// A TCP socket bound to the path's port with address and port reuse, so every attempt and the STUN connection share
// it (each a different four-tuple). -1 on failure.
- (int)socketForFamily:(sa_family_t)family port:(uint16_t)port {
    int fd = socket(family, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) return -1;
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, sizeof on);
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    if (family == AF_INET6) setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, sizeof on);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    struct sockaddr_storage storage;
    socklen_t length = [[self bindAddressForFamily:family port:port] getSockaddr:&storage];
    if (bind(fd, (struct sockaddr *)&storage, length) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

- (BOOL)bindAnchors {
    for (int attempt = 0; attempt < kBindAttempts; attempt++) {
        int v4 = [self socketForFamily:AF_INET port:_configuration.localPort];
        if (v4 < 0) return NO;
        struct sockaddr_storage storage;
        socklen_t length = sizeof storage;
        getsockname(v4, (struct sockaddr *)&storage, &length);
        uint16_t port = [SZFriendsNATEndpoint endpointWithSockaddr:(struct sockaddr *)&storage length:length].port;
        int v6 = [self socketForFamily:AF_INET6 port:port];
        if (v6 >= 0 || _configuration.localPort != 0) {
            _anchors[0] = v4;
            _anchors[1] = v6; // -1 when this Mac has no IPv6 at all: IPv4 alone then
            _localPort = port;
            return YES;
        }
        close(v4);
    }
    return NO;
}

- (BOOL)start:(NSError **)error {
    SZFriendsOnlinePurpose purpose = _configuration.purpose;
    if (_started || (purpose != SZFriendsOnlinePurposeFriend && purpose != SZFriendsOnlinePurposeFirstContact)) {
        if (error) *error = PathError(SZFriendsNATErrorUnsupported);
        return NO;
    }
    _started = YES;
    if (![self bindAnchors]) {
        if (error) *error = PathError(SZFriendsNATErrorSocket);
        return NO;
    }
    __weak SZFriendsNATTCPPath *weakSelf = self;
    _budgetTimer = [self timerAfter:_configuration.budget handler:^{
        [weakSelf failWithError:PathError(SZFriendsNATErrorTimedOut)];
    }];
    dispatch_async(_queue, ^{
        [weakSelf gatherHostCandidates];
        [weakSelf startStun];
    });
    return YES;
}

- (dispatch_source_t)timerAfter:(NSTimeInterval)seconds handler:(dispatch_block_t)handler {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, (uint64_t)(0.005 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, handler);
    dispatch_resume(timer);
    return timer;
}

#pragma mark Candidates

// Which addresses a path offers or dials: global ones; private ones for friends only; loopback only in tests.
static BOOL AllowsAddress(SZFriendsNATEndpoint *endpoint, SZFriendsOnlinePurpose purpose, BOOL loopbackOnly) {
    if (loopbackOnly) return SZFriendsNATLoopbackOnlyAllows(endpoint);
    if (endpoint.scope == SZFriendsNATAddressScopeGlobal) return YES;
    return endpoint.scope == SZFriendsNATAddressScopePrivate &&
           SZFriendsOnlinePurposeMayOfferPrivateHostCandidates(purpose);
}

SZFriendsOnlineDefaultRoutes SZFriendsNATReadDefaultRoutes(void) {
    SZFriendsOnlineDefaultRoutes routes = SZFriendsOnlineDefaultRoutesMake(NULL, NULL);
    for (int ipv6 = 0; ipv6 < 2; ipv6++) {
        for (unsigned i = 0; i < SZFriendsOnlineInternetRouteProbeCount; i++) {
            const char *probe = SZFriendsOnlineInternetRouteProbe(ipv6 ? AF_INET6 : AF_INET, i);
            SZFriendsNATEndpoint *destination = [SZFriendsNATEndpoint endpointWithHost:@(probe) port:0];
            SZFriendsNATRoute *route = destination != nil ? [SZFriendsNATRoute routeToDestination:destination] : nil;
            SZFriendsOnlineDefaultRoutesAdd(&routes, ipv6, route.interfaceName.UTF8String);
        }
    }
    return routes;
}

NSArray<SZFriendsNATEndpoint *> *SZFriendsNATTCPHostAddresses(const struct ifaddrs *list,
                                                             SZFriendsOnlinePurpose purpose,
                                                             const SZFriendsOnlineDefaultRoutes *routes,
                                                             BOOL loopbackOnly) {
    NSMutableArray<SZFriendsNATEndpoint *> *addresses = [NSMutableArray array];
    for (const struct ifaddrs *entry = list; entry != NULL; entry = entry->ifa_next) {
        if (entry->ifa_addr == NULL || !(entry->ifa_flags & IFF_UP)) continue;
        sa_family_t family = entry->ifa_addr->sa_family;
        if (family != AF_INET && family != AF_INET6) continue;
        socklen_t length = family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6);
        SZFriendsNATEndpoint *address = [SZFriendsNATEndpoint endpointWithSockaddr:entry->ifa_addr length:length];
        BOOL ipv6 = family == AF_INET6;
        BOOL offered = loopbackOnly || SZFriendsOnlineMayOfferHostCandidate(entry->ifa_name, ipv6, routes);
        if (address != nil && offered && AllowsAddress(address, purpose, loopbackOnly)) {
            [addresses addObject:[address endpointWithPort:0]];
        }
    }
    return addresses;
}

- (BOOL)allowsAddress:(SZFriendsNATEndpoint *)endpoint {
    return AllowsAddress(endpoint, _configuration.purpose, _configuration.loopbackOnly);
}

- (void)offer:(SZFriendsNATEndpoint *)endpoint type:(SZFriendsNATCandidateType)type preference:(uint16_t)preference {
    if (_finished || endpoint == nil || _anchors[endpoint.family == AF_INET6 ? 1 : 0] < 0) return;
    NSString *line = SZFriendsNATCandidateLine([endpoint endpointWithPort:endpoint.port ?: _localPort], type, YES,
                                               preference);
    if ([_offered containsObject:line]) return;
    [_offered addObject:line];
    [_delegate tcpPath:self didGatherLocalCandidate:line];
}

- (void)gatherHostCandidates {
    if (_finished) return;
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return;
    // Read for every path: a VPN that came up or went down since the last attempt is followed.
    SZFriendsOnlineDefaultRoutes routes = _configuration.loopbackOnly ? SZFriendsOnlineDefaultRoutesMake(NULL, NULL)
                                                                      : SZFriendsNATReadDefaultRoutes();
    NSArray<SZFriendsNATEndpoint *> *addresses =
        SZFriendsNATTCPHostAddresses(list, _configuration.purpose, &routes, _configuration.loopbackOnly);
    freeifaddrs(list);
    for (SZFriendsNATEndpoint *address in addresses) {
        [self offer:[address endpointWithPort:_localPort]
                  type:SZFriendsNATCandidateTypeHost
            preference:address.family == AF_INET6 ? kPreferenceHostIPv6 : kPreferenceHostIPv4];
    }
}

- (void)finishGathering {
    if (_gatheringDone || _finished) return;
    _gatheringDone = YES;
    if (_stunTimer != nil) dispatch_source_cancel(_stunTimer);
    _stunTimer = nil;
    [_delegate tcpPathDidFinishGathering:self];
}

#pragma mark STUN over TCP

- (void)startStun {
    SZFriendsNATEndpoint *server = _configuration.stunServer;
    BOOL allowed = server != nil && server.port != 0 &&
                   (_configuration.loopbackOnly ? SZFriendsNATLoopbackOnlyAllows(server)
                                                : server.scope == SZFriendsNATAddressScopeGlobal);
    int fd = allowed ? [self socketForFamily:server.family port:_localPort] : -1;
    if (fd < 0 || _finished) {
        if (fd >= 0) close(fd);
        [self finishGathering];
        return;
    }
    struct sockaddr_storage storage;
    socklen_t length = [server getSockaddr:&storage];
    if (connect(fd, (struct sockaddr *)&storage, length) != 0 && errno != EINPROGRESS) {
        close(fd);
        [self finishGathering];
        return;
    }
    _stunFD = fd;
    _stunBuffer = [NSMutableData data];
    SZFriendsStunRandomTransaction(_stunTransaction);
    SZFriendsNATSharedDescriptor *shared = [[SZFriendsNATSharedDescriptor alloc] initWithDescriptor:fd holders:2];
    __weak SZFriendsNATTCPPath *weakSelf = self;
    _stunWriter = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)fd, 0, _queue);
    dispatch_source_set_event_handler(_stunWriter, ^{
        [weakSelf stunConnected];
    });
    dispatch_source_set_cancel_handler(_stunWriter, ^{
        [shared letGo];
    });
    dispatch_resume(_stunWriter);
    _stunReader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
    dispatch_source_set_event_handler(_stunReader, ^{
        [weakSelf stunReadable];
    });
    dispatch_source_set_cancel_handler(_stunReader, ^{
        [shared letGo];
    });
    dispatch_resume(_stunReader);
    _stunTimer = [self timerAfter:_configuration.stunBudget handler:^{
        [weakSelf finishGathering];
    }];
}

- (void)stunConnected {
    if (_stunWriterSuspended) return;
    _stunWriterSuspended = YES;
    dispatch_suspend(_stunWriter); // writable once: send the request, then only read
    int error = 0;
    socklen_t length = sizeof error;
    getsockopt(_stunFD, SOL_SOCKET, SO_ERROR, &error, &length);
    if (error != 0) {
        [self finishGathering];
        return;
    }
    uint8_t request[64];
    size_t requestLength = SZFriendsStunWriteBindingRequest(request, sizeof request, _stunTransaction, NULL, NULL, 0);
    send(_stunFD, request, requestLength, 0);
}

- (void)stunReadable {
    uint8_t buffer[SZFriendsStunMessageMax];
    ssize_t received = read(_stunFD, buffer, sizeof buffer);
    if (received <= 0) {
        if (received == 0 || (errno != EAGAIN && errno != EINTR)) [self stopStunReading];
        return;
    }
    [_stunBuffer appendBytes:buffer length:(size_t)received];
    size_t frame = SZFriendsStunFramedLength(_stunBuffer.bytes, _stunBuffer.length);
    if (frame == 0) return;
    SZFriendsStunMessage message;
    BOOL parsed = frame != SIZE_MAX && SZFriendsStunParse(_stunBuffer.bytes, frame, &message);
    [self stopStunReading];
    if (parsed && message.type == SZFriendsStunTypeBindingSuccess && message.hasMappedAddress &&
        memcmp(message.transaction, _stunTransaction, sizeof _stunTransaction) == 0) {
        SZFriendsNATEndpoint *mapped =
            [SZFriendsNATEndpoint endpointWithSockaddr:(struct sockaddr *)&message.mappedAddress
                                               length:message.mappedAddressLength];
        if (mapped != nil && [self allowsAddress:mapped]) {
            [self offer:mapped type:SZFriendsNATCandidateTypeServerReflexive preference:kPreferenceMapped];
        }
    }
    [self finishGathering];
}

// The answer is in (or never will be): stop reading, but keep the connection, which keeps the NAT's mapping. The
// reader's letting go leaves the descriptor to the writer, which closes it at -stop.
- (void)stopStunReading {
    if (_stunReader != nil) dispatch_source_cancel(_stunReader);
    _stunReader = nil;
}

#pragma mark Dialling

- (BOOL)addRemoteCandidate:(NSString *)line error:(NSError **)error {
    SZFriendsNATCandidate *candidate = [SZFriendsNATCandidate candidateWithLine:line];
    SZFriendsNATEndpoint *remote = candidate.endpoint;
    BOOL ownPort = remote != nil && remote.port == _localPort && SZFriendsNATLoopbackOnlyAllows(remote);
    if (!_started || _finished || candidate == nil || !candidate.tcp || ![self allowsAddress:remote] || ownPort ||
        _anchors[remote.family == AF_INET6 ? 1 : 0] < 0 || _attempts.count >= SZFriendsNATTCPRemoteEndpointsMax) {
        if (error) *error = PathError(SZFriendsNATErrorAddressRefused);
        return NO;
    }
    if (_attempts[remote] != nil) return YES;
    _attempts[remote] = [SZFriendsNATTCPAttempt new];
    [self dial:remote];
    return YES;
}

- (void)dial:(SZFriendsNATEndpoint *)remote {
    SZFriendsNATTCPAttempt *attempt = _attempts[remote];
    if (_finished || attempt == nil) return;
    [attempt stopKeepingDescriptor:NO];
    __weak SZFriendsNATTCPPath *weakSelf = self;
    int fd = [self socketForFamily:remote.family port:_localPort];
    struct sockaddr_storage storage;
    socklen_t length = [remote getSockaddr:&storage];
    if (fd < 0 || (connect(fd, (struct sockaddr *)&storage, length) != 0 && errno != EINPROGRESS)) {
        if (fd >= 0) close(fd);
        attempt.timer = [self timerAfter:_configuration.redialAfterRefusal handler:^{
            [weakSelf dial:remote];
        }];
        return;
    }
    attempt.fd = fd;
    attempt.writer = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)fd, 0, _queue);
    dispatch_source_set_event_handler(attempt.writer, ^{
        [weakSelf attemptFinished:remote];
    });
    dispatch_resume(attempt.writer);
    attempt.timer = [self timerAfter:_configuration.redialAfterSilence handler:^{
        [weakSelf dial:remote];
    }];
}

- (void)attemptFinished:(SZFriendsNATEndpoint *)remote {
    SZFriendsNATTCPAttempt *attempt = _attempts[remote];
    if (_finished || attempt == nil || attempt.fd < 0) return;
    int error = 0;
    socklen_t length = sizeof error;
    getsockopt(attempt.fd, SOL_SOCKET, SO_ERROR, &error, &length);
    struct sockaddr_storage peer;
    socklen_t peerLength = sizeof peer;
    if (error == 0 && getpeername(attempt.fd, (struct sockaddr *)&peer, &peerLength) == 0) {
        int fd = attempt.fd;
        [attempt stopKeepingDescriptor:YES];
        [_attempts removeObjectForKey:remote];
        [self succeedWithDescriptor:fd ipv6:remote.family == AF_INET6];
        return;
    }
    // Refused (the peer's socket is not calling yet) or reset: call again shortly, from a fresh socket. A peer that
    // keeps refusing (its path is not running) is called once a second, so a LAN peer never gets a storm of SYNs.
    [attempt stopKeepingDescriptor:NO];
    attempt.refusals++;
    NSTimeInterval delay = attempt.refusals > kQuickRedials ? _configuration.redialAfterSilence
                                                            : _configuration.redialAfterRefusal;
    __weak SZFriendsNATTCPPath *weakSelf = self;
    attempt.timer = [self timerAfter:delay handler:^{
        [weakSelf dial:remote];
    }];
}

#pragma mark Ending

- (void)succeedWithDescriptor:(int)fd ipv6:(BOOL)ipv6 {
    [self stop];
    SZFriendsNATSocketStream *stream = [[SZFriendsNATSocketStream alloc] initWithConnectedSocket:fd];
    [_delegate tcpPath:self didOpenStream:stream ipv6:ipv6];
}

- (void)failWithError:(NSError *)error {
    if (_finished) return;
    [self stop];
    [_delegate tcpPath:self didFailWithError:error];
}

- (void)stop {
    _finished = YES;
    for (SZFriendsNATTCPAttempt *attempt in _attempts.allValues) [attempt stopKeepingDescriptor:NO];
    [_attempts removeAllObjects];
    [self stopStunReading];
    if (_stunWriter != nil) {
        // Resumed first: a suspended source never runs its cancel handler.
        if (_stunWriterSuspended) dispatch_resume(_stunWriter);
        _stunWriterSuspended = NO;
        dispatch_source_cancel(_stunWriter);
        _stunWriter = nil;
    }
    _stunFD = -1;
    for (dispatch_source_t timer in @[ _budgetTimer ?: [NSNull null], _stunTimer ?: [NSNull null] ]) {
        if (![timer isKindOfClass:[NSNull class]]) dispatch_source_cancel(timer);
    }
    _budgetTimer = _stunTimer = nil;
    for (int i = 0; i < 2; i++) {
        if (_anchors[i] >= 0) close(_anchors[i]);
        _anchors[i] = -1;
    }
}

- (void)close {
    [self stop];
}

@end
