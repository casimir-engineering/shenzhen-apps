// A hard-NAT probe run's UDP socket (SZFriendsNATProbeSocket.h).

#import "service/online/nat/SZFriendsNATProbeSocket.h"

#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <sys/resource.h>
#include <unistd.h>

enum { kFileLimitWanted = 1024 };

@implementation SZFriendsNATProbeSocket {
    dispatch_source_t _reader;
}

+ (instancetype)socketWithFamily:(sa_family_t)family
                    loopbackOnly:(BOOL)loopbackOnly
                            port:(uint16_t)port
                           queue:(dispatch_queue_t)queue
                 openDescriptors:(dispatch_group_t)openDescriptors
                        readable:(void (^)(SZFriendsNATProbeSocket *))readable {
    int fd = socket(family, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) return nil;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    NSString *any = family == AF_INET6 ? (loopbackOnly ? @"::1" : @"::") : (loopbackOnly ? @"127.0.0.1" : @"0.0.0.0");
    struct sockaddr_storage storage;
    socklen_t length = [[SZFriendsNATEndpoint endpointWithHost:any port:port] getSockaddr:&storage];
    if (bind(fd, (struct sockaddr *)&storage, length) != 0) {
        close(fd);
        return nil;
    }
    length = sizeof storage;
    getsockname(fd, (struct sockaddr *)&storage, &length);
    SZFriendsNATProbeSocket *probeSocket = [[self alloc] initWithDescriptor:fd];
    probeSocket->_port = [SZFriendsNATEndpoint endpointWithSockaddr:(struct sockaddr *)&storage length:length].port;
    dispatch_source_t reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, queue);
    __weak SZFriendsNATProbeSocket *weakSocket = probeSocket;
    dispatch_source_set_event_handler(reader, ^{
        SZFriendsNATProbeSocket *strongSocket = weakSocket;
        if (strongSocket != nil) readable(strongSocket);
    });
    dispatch_group_enter(openDescriptors);
    dispatch_source_set_cancel_handler(reader, ^{
        close(fd);
        dispatch_group_leave(openDescriptors);
    });
    probeSocket->_reader = reader;
    dispatch_resume(reader);
    return probeSocket;
}

- (instancetype)initWithDescriptor:(int)fd {
    if ((self = [super init])) _fd = fd;
    return self;
}

- (void)sendBytes:(const uint8_t *)bytes length:(size_t)length to:(SZFriendsNATEndpoint *)destination {
    struct sockaddr_storage storage;
    socklen_t addressLength = [destination getSockaddr:&storage];
    sendto(_fd, bytes, length, 0, (struct sockaddr *)&storage, addressLength);
}

- (void)close {
    dispatch_source_cancel(_reader); // its cancel handler closes the descriptor
}

+ (void)raiseFileLimit {
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) != 0 || limit.rlim_cur >= kFileLimitWanted) return;
    rlim_t wanted = MIN((rlim_t)kFileLimitWanted, MIN(limit.rlim_max, (rlim_t)OPEN_MAX));
    if (wanted > limit.rlim_cur) {
        limit.rlim_cur = wanted;
        setrlimit(RLIMIT_NOFILE, &limit);
    }
}

@end
