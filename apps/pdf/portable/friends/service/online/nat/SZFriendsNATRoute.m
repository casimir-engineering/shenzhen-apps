// Route lookups through the routing socket (SZFriendsNATRoute.h). RTM_GET needs no privilege, sends nothing on the
// network, and answers within the call.

#import "service/online/nat/SZFriendsNATRoute.h"

#import "service/online/SZFriendsOnlineTransport.h"

#include <errno.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

// Socket addresses in routing messages are padded to four bytes (the kernel's SA_SIZE on Darwin).
static size_t RoundUp(size_t length) {
    return length > 0 ? 1 + ((length - 1) | (sizeof(uint32_t) - 1)) : sizeof(uint32_t);
}

// The kernel writes a link-local IPv6 address with its scope inside the address (KAME's embedded form): bytes 2 and 3
// hold the interface index. Moved to sin6_scope_id so the address reads as on the wire.
static SZFriendsNATEndpoint *EndpointFromRouteSockaddr(const struct sockaddr *sockaddr) {
    if (sockaddr->sa_family == AF_INET6 && sockaddr->sa_len >= sizeof(struct sockaddr_in6)) {
        struct sockaddr_in6 copy;
        memcpy(&copy, sockaddr, sizeof copy);
        if (IN6_IS_ADDR_LINKLOCAL(&copy.sin6_addr) || IN6_IS_ADDR_MC_LINKLOCAL(&copy.sin6_addr)) {
            uint16_t embedded = (uint16_t)((copy.sin6_addr.s6_addr[2] << 8) | copy.sin6_addr.s6_addr[3]);
            if (embedded != 0 && copy.sin6_scope_id == 0) copy.sin6_scope_id = embedded;
            copy.sin6_addr.s6_addr[2] = 0;
            copy.sin6_addr.s6_addr[3] = 0;
        }
        return [SZFriendsNATEndpoint endpointWithSockaddr:(struct sockaddr *)&copy length:sizeof copy];
    }
    if (sockaddr->sa_family == AF_INET && sockaddr->sa_len >= sizeof(struct sockaddr_in)) {
        return [SZFriendsNATEndpoint endpointWithSockaddr:sockaddr length:sockaddr->sa_len];
    }
    return nil;
}

@implementation SZFriendsNATRoute

- (instancetype)initWithInterface:(NSString *)name
                          gateway:(SZFriendsNATEndpoint *)gateway
                     localAddress:(SZFriendsNATEndpoint *)localAddress {
    if ((self = [super init])) {
        _interfaceName = [name copy];
        _gateway = [gateway endpointWithPort:0];
        _localAddress = [localAddress endpointWithPort:0];
        _physical = SZFriendsOnlineInterfaceMayOfferHostCandidates(name.UTF8String);
        _networkKey = [NSString stringWithFormat:@"%@|%@", name, _gateway.host ?: @"-"];
    }
    return self;
}

+ (instancetype)defaultRouteForFamily:(sa_family_t)family {
    SZFriendsNATEndpoint *documentation = family == AF_INET6 ? [SZFriendsNATEndpoint endpointWithHost:@"2001:db8::1"
                                                                                                 port:0]
                                                             : [SZFriendsNATEndpoint endpointWithHost:@"192.0.2.1"
                                                                                                 port:0];
    return documentation != nil ? [self routeToDestination:documentation] : nil;
}

+ (instancetype)routeToDestination:(SZFriendsNATEndpoint *)destination {
    int routing = socket(PF_ROUTE, SOCK_RAW, destination.family);
    if (routing < 0) return nil;
    // The answer comes back on this socket within the call; the timeout only guards a kernel that never answers.
    struct timeval timeout = {1, 0};
    setsockopt(routing, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);

    union {
        struct rt_msghdr header;
        uint8_t bytes[2048];
    } message;
    memset(&message, 0, sizeof message);
    static int sequence;
    int seq = __atomic_add_fetch(&sequence, 1, __ATOMIC_RELAXED);
    struct rt_msghdr *request = &message.header;
    request->rtm_version = RTM_VERSION;
    request->rtm_type = RTM_GET;
    request->rtm_flags = RTF_UP | RTF_HOST;
    request->rtm_addrs = RTA_DST | RTA_IFP;
    request->rtm_seq = seq;
    request->rtm_pid = getpid();
    uint8_t *at = message.bytes + sizeof *request;
    struct sockaddr_storage storage;
    socklen_t length = [destination getSockaddr:&storage];
    memcpy(at, &storage, length);
    at += RoundUp(length);
    struct sockaddr_dl link = {0};
    link.sdl_len = sizeof link;
    link.sdl_family = AF_LINK;
    memcpy(at, &link, sizeof link);
    at += RoundUp(sizeof link);
    request->rtm_msglen = (u_short)(at - message.bytes);

    if (write(routing, &message, request->rtm_msglen) < 0) {
        close(routing);
        return nil;
    }
    ssize_t received;
    pid_t pid = getpid();
    for (;;) {
        received = read(routing, &message, sizeof message);
        if (received < 0 && errno == EINTR) continue;
        if (received < (ssize_t)sizeof(struct rt_msghdr)) break;
        if (message.header.rtm_type == RTM_GET && message.header.rtm_seq == seq && message.header.rtm_pid == pid) {
            break;
        }
    }
    close(routing);
    if (received < (ssize_t)sizeof(struct rt_msghdr) || message.header.rtm_errno != 0 ||
        message.header.rtm_msglen > (size_t)received) {
        return nil;
    }

    NSString *name = nil;
    SZFriendsNATEndpoint *gateway = nil, *local = nil;
    const uint8_t *cursor = message.bytes + sizeof(struct rt_msghdr);
    const uint8_t *end = message.bytes + message.header.rtm_msglen;
    for (int bit = 0; bit < RTAX_MAX; bit++) {
        if (!(message.header.rtm_addrs & (1 << bit))) continue;
        if (cursor + sizeof(struct sockaddr) > end) break;
        const struct sockaddr *sockaddr = (const struct sockaddr *)cursor;
        size_t step = RoundUp(sockaddr->sa_len);
        if (cursor + step > end || (sockaddr->sa_len > 0 && cursor + sockaddr->sa_len > end)) break;
        if (bit == RTAX_GATEWAY && (message.header.rtm_flags & RTF_GATEWAY)) {
            gateway = EndpointFromRouteSockaddr(sockaddr);
        } else if (bit == RTAX_IFA) {
            local = EndpointFromRouteSockaddr(sockaddr);
        } else if (bit == RTAX_IFP && sockaddr->sa_family == AF_LINK) {
            const struct sockaddr_dl *dl = (const struct sockaddr_dl *)sockaddr;
            if (dl->sdl_nlen > 0 && dl->sdl_nlen < IFNAMSIZ &&
                offsetof(struct sockaddr_dl, sdl_data) + dl->sdl_nlen <= dl->sdl_len) {
                name = [[NSString alloc] initWithBytes:dl->sdl_data length:dl->sdl_nlen
                                              encoding:NSASCIIStringEncoding];
            }
        }
        cursor += step;
    }
    if (name == nil && message.header.rtm_index > 0) {
        char buffer[IF_NAMESIZE];
        if (if_indextoname(message.header.rtm_index, buffer) != NULL) name = @(buffer);
    }
    if (name.length == 0) return nil;
    return [[self alloc] initWithInterface:name gateway:gateway localAddress:local];
}

@end
