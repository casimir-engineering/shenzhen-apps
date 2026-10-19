// Shared test pieces (SZFriendsNATTestSupport.h).

#import "SZFriendsNATTestSupport.h"

#import "service/online/nat/SZFriendsNATStun.h"

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <unistd.h>

int SZFTestFailures = 0;

BOOL SZFTestWait(dispatch_semaphore_t semaphore, NSTimeInterval seconds) {
    seconds = MIN(seconds, 10.0);
    return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) == 0;
}

void SZFTestSync(dispatch_queue_t queue, dispatch_block_t block) {
    dispatch_sync(queue, block);
}

dispatch_queue_t SZFTestQueue(const char *name) {
    return dispatch_queue_create(name, DISPATCH_QUEUE_SERIAL);
}

// `reuse`: SO_REUSEADDR, for servers; never for a port window, which must be free for sockets that do not set it
// (a wildcard socket of another process on the same port lets a reusing bind through but not theirs).
static int BindSocket(SZFriendsNATEndpoint *endpoint, int type, BOOL reuse) {
    int fd = socket(endpoint.family, type, 0);
    if (fd < 0) return -1;
    int on = 1;
    if (reuse) setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    if (endpoint.family == AF_INET6) setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, sizeof on);
    struct sockaddr_storage storage;
    socklen_t length = [endpoint getSockaddr:&storage];
    if (bind(fd, (struct sockaddr *)&storage, length) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int BoundSocket(SZFriendsNATEndpoint *endpoint, int type) {
    return BindSocket(endpoint, type, YES);
}

static SZFriendsNATEndpoint *LocalEndpoint(int fd) {
    struct sockaddr_storage storage;
    socklen_t length = sizeof storage;
    getsockname(fd, (struct sockaddr *)&storage, &length);
    return [SZFriendsNATEndpoint endpointWithSockaddr:(struct sockaddr *)&storage length:length];
}

@implementation SZFTestUDPServer {
    int _fd;
    dispatch_queue_t _queue;
    dispatch_source_t _reader;
    SZFTestUDPHandler _handler;
    NSUInteger _received;
}

- (instancetype)initWithHost:(NSString *)host port:(uint16_t)port handler:(SZFTestUDPHandler)handler {
    if ((self = [super init])) {
        SZFriendsNATEndpoint *endpoint = [SZFriendsNATEndpoint endpointWithHost:host port:port];
        if (endpoint == nil || !SZFriendsNATLoopbackOnlyAllows(endpoint)) return nil;
        _fd = BoundSocket(endpoint, SOCK_DGRAM);
        if (_fd < 0) return nil;
        fcntl(_fd, F_SETFL, fcntl(_fd, F_GETFL) | O_NONBLOCK);
        _endpoint = LocalEndpoint(_fd);
        _handler = [handler copy];
        _queue = SZFTestQueue("szf.test.udp");
        int fd = _fd;
        __weak SZFTestUDPServer *weakSelf = self;
        _reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
        dispatch_source_set_event_handler(_reader, ^{
            [weakSelf readAvailable];
        });
        dispatch_source_set_cancel_handler(_reader, ^{
            close(fd);
        });
        dispatch_resume(_reader);
    }
    return self;
}

- (void)readAvailable {
    for (;;) {
        uint8_t buffer[2048];
        struct sockaddr_storage from;
        socklen_t length = sizeof from;
        ssize_t received = recvfrom(_fd, buffer, sizeof buffer, 0, (struct sockaddr *)&from, &length);
        if (received < 0) return;
        @synchronized(self) {
            _received++;
        }
        SZFriendsNATEndpoint *source = [SZFriendsNATEndpoint endpointWithSockaddr:(struct sockaddr *)&from
                                                                          length:length];
        for (NSData *reply in _handler([NSData dataWithBytes:buffer length:(size_t)received], source)) {
            sendto(_fd, reply.bytes, reply.length, 0, (struct sockaddr *)&from, length);
        }
    }
}

- (NSUInteger)received {
    @synchronized(self) {
        return _received;
    }
}

- (void)sendData:(NSData *)data to:(SZFriendsNATEndpoint *)destination {
    struct sockaddr_storage storage;
    socklen_t length = [destination getSockaddr:&storage];
    sendto(_fd, data.bytes, data.length, 0, (struct sockaddr *)&storage, length);
}

- (void)close {
    if (_reader != nil) dispatch_source_cancel(_reader);
    _reader = nil;
}

- (void)dealloc {
    [self close];
}

@end

SZFTestUDPServer *SZFTestStunServer(NSString *host, int32_t portShift) {
    SZFTestUDPHandler handler = ^NSArray<NSData *> *(NSData *packet, SZFriendsNATEndpoint *from) {
        SZFriendsStunMessage message;
        if (!SZFriendsStunParse(packet.bytes, packet.length, &message) ||
            message.type != SZFriendsStunTypeBindingRequest) {
            return @[];
        }
        SZFriendsNATEndpoint *mapped = [from endpointWithPort:(uint16_t)((int32_t)from.port + portShift)];
        struct sockaddr_storage storage;
        [mapped getSockaddr:&storage];
        uint8_t answer[128];
        size_t length = SZFriendsStunWriteBindingSuccess(answer, sizeof answer, message.transaction,
                                                         (struct sockaddr *)&storage, NULL, 0);
        return @[ [NSData dataWithBytes:answer length:length] ];
    };
    return [[SZFTestUDPServer alloc] initWithHost:host port:0 handler:handler];
}

@implementation SZFTestTCPServer {
    int _fd;
    pthread_t _thread;
    void (^_handler)(int);
    volatile BOOL _closing;
    NSUInteger _accepted;
}

static void *AcceptLoop(void *context) {
    SZFTestTCPServer *server = (__bridge SZFTestTCPServer *)context;
    [server acceptLoop];
    return NULL;
}

- (instancetype)initWithHost:(NSString *)host handler:(void (^)(int))handler {
    if ((self = [super init])) {
        SZFriendsNATEndpoint *endpoint = [SZFriendsNATEndpoint endpointWithHost:host port:0];
        if (endpoint == nil || !SZFriendsNATLoopbackOnlyAllows(endpoint)) return nil;
        _fd = BoundSocket(endpoint, SOCK_STREAM);
        if (_fd < 0 || listen(_fd, 8) != 0) return nil;
        _endpoint = LocalEndpoint(_fd);
        _handler = [handler copy];
        pthread_create(&_thread, NULL, AcceptLoop, (__bridge void *)self);
    }
    return self;
}

- (void)acceptLoop {
    while (!_closing) {
        struct pollfd poller = {_fd, POLLIN, 0};
        if (poll(&poller, 1, 100) <= 0) continue;
        int client = accept(_fd, NULL, NULL);
        if (client < 0) continue;
        @synchronized(self) {
            _accepted++;
        }
        void (^handler)(int) = _handler;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            handler(client);
        });
    }
}

- (NSUInteger)accepted {
    @synchronized(self) {
        return _accepted;
    }
}

- (void)close {
    if (_closing) return;
    _closing = YES;
    pthread_join(_thread, NULL);
    close(_fd);
}

- (void)dealloc {
    [self close];
}

@end

NSData *SZFTestReadSocket(int descriptor, NSUInteger length, NSTimeInterval seconds) {
    NSMutableData *data = [NSMutableData data];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MIN(seconds, 10.0)];
    while (data.length < length && deadline.timeIntervalSinceNow > 0) {
        struct pollfd poller = {descriptor, POLLIN, 0};
        if (poll(&poller, 1, (int)MAX(1, deadline.timeIntervalSinceNow * 1000)) <= 0) break;
        uint8_t buffer[4096];
        ssize_t received = read(descriptor, buffer, MIN(sizeof buffer, length - data.length));
        if (received <= 0) break;
        [data appendBytes:buffer length:(size_t)received];
    }
    return data;
}

NSArray<NSNumber *> *SZFTestHoldUDPPortWindow(NSUInteger count, uint16_t *firstPort) {
    for (int attempt = 0; attempt < 40; attempt++) {
        uint16_t base = (uint16_t)(20000 + arc4random_uniform(30000));
        NSMutableArray<NSNumber *> *held = [NSMutableArray array];
        for (NSUInteger i = 0; i < count; i++) {
            int fd = BindSocket([SZFriendsNATEndpoint endpointWithHost:@"127.0.0.1" port:(uint16_t)(base + i)],
                                SOCK_DGRAM, NO);
            if (fd < 0) break;
            [held addObject:@(fd)];
        }
        if (held.count == count) {
            *firstPort = base;
            return held;
        }
        for (NSNumber *fd in held) close(fd.intValue);
    }
    return @[];
}
