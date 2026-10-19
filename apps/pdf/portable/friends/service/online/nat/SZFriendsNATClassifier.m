// The two-port NAT classifier and the class cache (SZFriendsNATClassifier.h).

#import "service/online/nat/SZFriendsNATClassifier.h"

#import "service/online/nat/SZFriendsNATStun.h"

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

@implementation SZFriendsNATClassification

+ (instancetype)classificationWithPrimary:(SZFriendsNATEndpoint *)primary secondary:(SZFriendsNATEndpoint *)secondary {
    return [[self alloc] initWithPrimary:primary secondary:secondary];
}

- (instancetype)initWithPrimary:(SZFriendsNATEndpoint *)primary secondary:(SZFriendsNATEndpoint *)secondary {
    if ((self = [super init])) {
        _mappedPrimary = primary;
        _mappedSecondary = secondary;
        if (primary != nil && secondary != nil && [primary hasSameAddressAs:secondary]) {
            if (primary.port == secondary.port) {
                _natClass = SZFriendsNATClassEndpointIndependent;
            } else {
                _natClass = SZFriendsNATClassPerDestination;
                _step = (int32_t)secondary.port - (int32_t)primary.port;
                _predictable = abs(_step) <= SZFriendsNATPredictableStepMax;
            }
        }
    }
    return self;
}

@end

static NSError *NATError(SZFriendsNATError code) {
    return [NSError errorWithDomain:SZFriendsNATErrorDomain code:code userInfo:nil];
}

@implementation SZFriendsNATClassifier {
    SZFriendsNATEndpoint *_servers[2];
    BOOL _loopbackOnly;
    int _socket;
    dispatch_queue_t _queue;
    dispatch_source_t _reader;
    NSMutableArray<dispatch_source_t> *_timers;
    uint8_t _transactions[2][SZFriendsStunTransactionLength];
    SZFriendsNATEndpoint *_mapped[2];
    void (^_completion)(SZFriendsNATClassification *, NSError *);
    BOOL _started;
}

- (instancetype)initWithPrimary:(SZFriendsNATEndpoint *)primary
                      secondary:(SZFriendsNATEndpoint *)secondary
                   loopbackOnly:(BOOL)loopbackOnly {
    if ((self = [super init])) {
        _servers[0] = primary;
        _servers[1] = secondary;
        _loopbackOnly = loopbackOnly;
        _socket = -1;
        _retransmits = @[ @0.25, @0.75, @1.5 ];
        _budget = 2.5;
        _timers = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)allowsServer:(SZFriendsNATEndpoint *)server {
    if (server == nil || server.port == 0 || server.family != _servers[0].family) return NO;
    return _loopbackOnly ? SZFriendsNATLoopbackOnlyAllows(server) : server.scope == SZFriendsNATAddressScopeGlobal;
}

- (void)classifyOnQueue:(dispatch_queue_t)queue
             completion:(void (^)(SZFriendsNATClassification *, NSError *))completion {
    if (_started) return;
    _started = YES;
    _queue = queue;
    _completion = [completion copy];
    if (![self allowsServer:_servers[0]] || ![self allowsServer:_servers[1]]) {
        dispatch_async(queue, ^{
            [self finishWithError:NATError(SZFriendsNATErrorAddressRefused)];
        });
        return;
    }
    _socket = socket(_servers[0].family, SOCK_DGRAM, IPPROTO_UDP);
    if (_socket < 0) {
        dispatch_async(queue, ^{
            [self finishWithError:NATError(SZFriendsNATErrorSocket)];
        });
        return;
    }
    fcntl(_socket, F_SETFL, fcntl(_socket, F_GETFL) | O_NONBLOCK);
    int fd = _socket;
    __weak SZFriendsNATClassifier *weakSelf = self;
    _reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, queue);
    dispatch_source_set_event_handler(_reader, ^{
        [weakSelf readAvailable];
    });
    dispatch_source_set_cancel_handler(_reader, ^{
        close(fd);
    });
    dispatch_resume(_reader);
    for (int i = 0; i < 2; i++) SZFriendsStunRandomTransaction(_transactions[i]);
    for (NSNumber *delay in _retransmits) {
        if (delay.doubleValue < _budget) [self after:delay.doubleValue run:^{
            [weakSelf sendRequests];
        }];
    }
    [self after:_budget run:^{
        [weakSelf finishWithError:nil];
    }];
    [self sendRequests];
}

- (void)after:(NSTimeInterval)seconds run:(dispatch_block_t)block {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, (uint64_t)(0.01 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, block);
    dispatch_resume(timer);
    [_timers addObject:timer];
}

- (void)sendRequests {
    for (int i = 0; i < 2; i++) {
        if (_mapped[i] != nil) continue; // answered: asking again would only cost the server
        uint8_t request[64];
        size_t length = SZFriendsStunWriteBindingRequest(request, sizeof request, _transactions[i], NULL, NULL, 0);
        struct sockaddr_storage storage;
        socklen_t addressLength = [_servers[i] getSockaddr:&storage];
        sendto(_socket, request, length, 0, (struct sockaddr *)&storage, addressLength);
    }
}

- (void)readAvailable {
    for (;;) {
        uint8_t buffer[SZFriendsStunMessageMax + 1];
        struct sockaddr_storage from;
        socklen_t fromLength = sizeof from;
        ssize_t received = recvfrom(_socket, buffer, sizeof buffer, 0, (struct sockaddr *)&from, &fromLength);
        if (received < 0) return;
        SZFriendsNATEndpoint *source = [SZFriendsNATEndpoint endpointWithSockaddr:(struct sockaddr *)&from
                                                                          length:fromLength];
        SZFriendsStunMessage message;
        if (source == nil || !SZFriendsStunParse(buffer, (size_t)received, &message)) continue;
        if (message.type != SZFriendsStunTypeBindingSuccess || !message.hasMappedAddress) continue;
        for (int i = 0; i < 2; i++) {
            if (_mapped[i] != nil || ![source isEqual:_servers[i]]) continue;
            if (memcmp(message.transaction, _transactions[i], SZFriendsStunTransactionLength) != 0) continue;
            _mapped[i] = [SZFriendsNATEndpoint endpointWithSockaddr:(struct sockaddr *)&message.mappedAddress
                                                            length:message.mappedAddressLength];
        }
        if (_mapped[0] != nil && _mapped[1] != nil) {
            [self finishWithError:nil];
            return;
        }
    }
}

- (void)finishWithError:(NSError *)error {
    void (^completion)(SZFriendsNATClassification *, NSError *) = _completion;
    if (completion == nil) return;
    _completion = nil;
    [self stop];
    if (error == nil && _mapped[0] == nil && _mapped[1] == nil) error = NATError(SZFriendsNATErrorTimedOut);
    completion(error != nil ? nil : [SZFriendsNATClassification classificationWithPrimary:_mapped[0]
                                                                                secondary:_mapped[1]],
               error);
}

- (void)stop {
    for (dispatch_source_t timer in _timers) dispatch_source_cancel(timer);
    [_timers removeAllObjects];
    if (_reader != nil) {
        dispatch_source_cancel(_reader);
        _reader = nil;
    }
}

- (void)cancel {
    _completion = nil;
    [self stop];
}

@end

static NSTimeInterval MonotonicNow(void) {
    return (NSTimeInterval)clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e9;
}

@implementation SZFriendsNATClassCache {
    NSTimeInterval _maximumAge;
    NSTimeInterval (^_clock)(void);
    NSMutableDictionary<NSString *, SZFriendsNATClassification *> *_entries;
    NSMutableDictionary<NSString *, NSNumber *> *_times;
}

- (instancetype)initWithMaximumAge:(NSTimeInterval)maximumAge clock:(NSTimeInterval (^)(void))clock {
    if ((self = [super init])) {
        _maximumAge = maximumAge;
        _clock = [clock copy];
        if (_clock == nil) {
            _clock = ^NSTimeInterval {
                return MonotonicNow();
            };
        }
        _entries = [NSMutableDictionary dictionary];
        _times = [NSMutableDictionary dictionary];
    }
    return self;
}

- (instancetype)init {
    return [self initWithMaximumAge:30 * 60 clock:nil];
}

- (SZFriendsNATClassification *)classificationForNetwork:(NSString *)networkKey {
    @synchronized(self) {
        NSNumber *time = _times[networkKey];
        if (time == nil) return nil;
        if (_clock() - time.doubleValue > _maximumAge) {
            [_entries removeObjectForKey:networkKey];
            [_times removeObjectForKey:networkKey];
            return nil;
        }
        return _entries[networkKey];
    }
}

- (void)setClassification:(SZFriendsNATClassification *)classification forNetwork:(NSString *)networkKey {
    @synchronized(self) {
        _entries[networkKey] = classification;
        _times[networkKey] = @(_clock());
    }
}

- (void)networkDidChange {
    @synchronized(self) {
        [_entries removeAllObjects];
        [_times removeAllObjects];
    }
}

@end
