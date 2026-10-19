// Candidates: strict parsing, address classes and the rules on what is offered and dialled (ADR 0009 § Who may
// reach the stack, ADR 0011 § VPN and tunnels). Pure apart from the interface and route lookups, which also take
// injected tables, so the suite tests every rule without a peer connection.

#import "service/online/transport/SZFriendsOnlineTransportInternal.h"

#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netinet/in.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

// RFC 8839: a foundation is 1 to 32 ice-chars.
static const NSUInteger kFoundationMax = 32;
// A candidate line is short; anything longer is not one we sent or would apply.
static const NSUInteger kLineMax = 512;

NSError *SZFriendsOnlineMakeError(SZFriendsOnlineError code, NSString *reason) {
    return [NSError errorWithDomain:SZFriendsOnlineErrorDomain
                               code:code
                           userInfo:@{NSLocalizedFailureReasonErrorKey : reason}];
}

#pragma mark - Addresses

static SZFriendsOnlineAddressClass ClassifyIPv4(const uint8_t b[4]) {
    if (b[0] == 0) return SZFriendsOnlineAddressUnusable;   // "this network"
    if (b[0] == 127) return SZFriendsOnlineAddressLoopback;
    if (b[0] >= 224) return SZFriendsOnlineAddressUnusable; // multicast, reserved, broadcast
    if (b[0] == 169 && b[1] == 254) return SZFriendsOnlineAddressUnusable; // link-local
    if (b[0] == 10) return SZFriendsOnlineAddressPrivate;
    if (b[0] == 172 && (b[1] & 0xF0) == 16) return SZFriendsOnlineAddressPrivate;
    if (b[0] == 192 && b[1] == 168) return SZFriendsOnlineAddressPrivate;
    if (b[0] == 100 && (b[1] & 0xC0) == 64) return SZFriendsOnlineAddressPrivate; // shared address space (CGNAT)
    return SZFriendsOnlineAddressPublicIPv4;
}

static SZFriendsOnlineAddressClass ClassifyIPv6(const uint8_t b[16]) {
    static const uint8_t loopback[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    if (memcmp(b, loopback, 16) == 0) return SZFriendsOnlineAddressLoopback;
    if ((b[0] & 0xE0) == 0x20) return SZFriendsOnlineAddressGlobalIPv6; // 2000::/3
    if ((b[0] & 0xFE) == 0xFC) return SZFriendsOnlineAddressPrivate;    // fc00::/7
    // Everything else: ::, IPv4-mapped and -compatible forms (which could smuggle 127.0.0.1 or a private address
    // past the IPv4 rules), multicast, link-local, site-local and unassigned space.
    return SZFriendsOnlineAddressUnusable;
}

// Numeric addresses only: a name would need resolving (DNS, or a browser's mDNS host name), and could then point
// anywhere. A scope ("%en0") only belongs on link-local addresses, which are refused anyway.
static BOOL ParseAddress(NSString *address, struct in6_addr *v6, struct in_addr *v4, BOOL *isIPv6) {
    const char *text = address.UTF8String;
    if (text == NULL || strlen(text) > INET6_ADDRSTRLEN || strchr(text, '%') != NULL) return NO;
    if (inet_pton(AF_INET, text, v4) == 1) {
        *isIPv6 = NO;
        return YES;
    }
    if (inet_pton(AF_INET6, text, v6) == 1) {
        *isIPv6 = YES;
        return YES;
    }
    return NO;
}

SZFriendsOnlineAddressClass SZFriendsOnlineClassifyAddress(NSString *address) {
    struct in6_addr v6;
    struct in_addr v4;
    BOOL isIPv6 = NO;
    if (!ParseAddress(address, &v6, &v4, &isIPv6)) return SZFriendsOnlineAddressUnusable;
    return isIPv6 ? ClassifyIPv6(v6.s6_addr) : ClassifyIPv4((const uint8_t *)&v4.s_addr);
}

#pragma mark - Interfaces and routes (lead decision 9)

// The interface the kernel would send a packet to `destination` through, as `route -n get` asks it: RTM_GET on a
// routing socket needs no privilege, sends nothing on the network and answers within the call. NO without a route.
static BOOL RouteInterface(const char *destination, char name[IFNAMSIZ]) {
    struct sockaddr_storage target;
    memset(&target, 0, sizeof target);
    struct sockaddr_in *in = (struct sockaddr_in *)&target;
    struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)&target;
    if (inet_pton(AF_INET, destination, &in->sin_addr) == 1) {
        in->sin_len = sizeof *in;
        in->sin_family = AF_INET;
    } else if (inet_pton(AF_INET6, destination, &in6->sin6_addr) == 1) {
        in6->sin6_len = sizeof *in6;
        in6->sin6_family = AF_INET6;
    } else {
        return NO;
    }
    int routing = socket(PF_ROUTE, SOCK_RAW, target.ss_family);
    if (routing < 0) return NO;
    struct timeval timeout = {1, 0}; // the answer comes within the call; this only guards a kernel that never answers
    setsockopt(routing, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    union {
        struct rt_msghdr header;
        uint8_t bytes[1024];
    } message;
    memset(&message, 0, sizeof message);
    static int sequence;
    const int seq = __atomic_add_fetch(&sequence, 1, __ATOMIC_RELAXED);
    const pid_t pid = getpid();
    message.header.rtm_version = RTM_VERSION;
    message.header.rtm_type = RTM_GET;
    message.header.rtm_flags = RTF_UP | RTF_HOST;
    message.header.rtm_addrs = RTA_DST | RTA_IFP;
    message.header.rtm_seq = seq;
    message.header.rtm_pid = pid;
    // Socket addresses in routing messages are padded to four bytes; an empty link address asks for the interface.
    size_t at = sizeof message.header;
    memcpy(message.bytes + at, &target, target.ss_len);
    at += (target.ss_len + 3u) & ~3u;
    struct sockaddr_dl link = {.sdl_len = sizeof link, .sdl_family = AF_LINK};
    memcpy(message.bytes + at, &link, sizeof link);
    at += (sizeof link + 3u) & ~3u;
    message.header.rtm_msglen = (u_short)at;
    ssize_t received = -1;
    if (write(routing, &message, at) == (ssize_t)at) {
        for (;;) {
            received = read(routing, &message, sizeof message);
            if (received < 0 && errno == EINTR) continue;
            if (received < (ssize_t)sizeof message.header) break;
            if (message.header.rtm_type == RTM_GET && message.header.rtm_seq == seq && message.header.rtm_pid == pid) {
                break;
            }
        }
    }
    close(routing);
    if (received < (ssize_t)sizeof message.header || message.header.rtm_errno != 0 ||
        message.header.rtm_msglen > (size_t)received) {
        return NO;
    }
    name[0] = '\0';
    const uint8_t *cursor = message.bytes + sizeof message.header, *end = message.bytes + message.header.rtm_msglen;
    for (int bit = 0; bit < RTAX_MAX && cursor + sizeof(struct sockaddr) <= end; bit++) {
        if (!(message.header.rtm_addrs & (1 << bit))) continue;
        const struct sockaddr *sockaddr = (const struct sockaddr *)(const void *)cursor;
        if (sockaddr->sa_len > end - cursor) break;
        const struct sockaddr_dl *dl = (const struct sockaddr_dl *)(const void *)sockaddr;
        if (bit == RTAX_IFP && sockaddr->sa_family == AF_LINK && dl->sdl_nlen > 0 && dl->sdl_nlen < IFNAMSIZ &&
            offsetof(struct sockaddr_dl, sdl_data) + dl->sdl_nlen <= dl->sdl_len) {
            memcpy(name, dl->sdl_data, dl->sdl_nlen);
            name[dl->sdl_nlen] = '\0';
        }
        cursor += sockaddr->sa_len > 0 ? (sockaddr->sa_len + 3u) & ~3u : sizeof(uint32_t);
    }
    if (name[0] == '\0' && message.header.rtm_index > 0) {
        char buffer[IF_NAMESIZE];
        if (if_indextoname(message.header.rtm_index, buffer) != NULL) strlcpy(name, buffer, IFNAMSIZ);
    }
    return name[0] != '\0';
}

SZFriendsOnlineDefaultRoutes SZFriendsOnlineReadDefaultRoutes(void) {
    SZFriendsOnlineDefaultRoutes routes = SZFriendsOnlineDefaultRoutesMake(NULL, NULL);
    for (int ipv6 = 0; ipv6 < 2; ipv6++) {
        for (unsigned i = 0; i < SZFriendsOnlineInternetRouteProbeCount; i++) {
            char name[IFNAMSIZ];
            if (RouteInterface(SZFriendsOnlineInternetRouteProbe(ipv6 ? AF_INET6 : AF_INET, i), name)) {
                SZFriendsOnlineDefaultRoutesAdd(&routes, ipv6, name);
            }
        }
    }
    return routes;
}

NSString *SZFriendsOnlineOfferingInterfaceForAddress(NSString *address, const struct ifaddrs *list,
                                                     const SZFriendsOnlineDefaultRoutes *routes) {
    struct in6_addr v6;
    struct in_addr v4;
    BOOL isIPv6 = NO;
    if (!ParseAddress(address, &v6, &v4, &isIPv6)) return nil;
    NSString *name = nil;
    for (const struct ifaddrs *entry = list; entry != NULL && name == nil; entry = entry->ifa_next) {
        const struct sockaddr *sa = entry->ifa_addr;
        if (sa == NULL || entry->ifa_name == NULL) continue;
        if (!isIPv6 && sa->sa_family == AF_INET) {
            const struct sockaddr_in *in = (const struct sockaddr_in *)(const void *)sa;
            if (in->sin_addr.s_addr == v4.s_addr) name = @(entry->ifa_name);
        } else if (isIPv6 && sa->sa_family == AF_INET6) {
            const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)(const void *)sa;
            if (memcmp(&in6->sin6_addr, &v6, sizeof v6) == 0) name = @(entry->ifa_name);
        }
    }
    if (name == nil || SZFriendsOnlineClassifyAddress(address) == SZFriendsOnlineAddressLoopback) return name;
    return SZFriendsOnlineDefaultRouteAllowsHostCandidates(routes, isIPv6) ? name : nil;
}

NSString *SZFriendsOnlineInterfaceForAddress(NSString *address) {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return nil;
    // Read again for every candidate: a VPN that comes up or goes down is followed at once.
    SZFriendsOnlineDefaultRoutes routes = SZFriendsOnlineReadDefaultRoutes();
    NSString *name = SZFriendsOnlineOfferingInterfaceForAddress(address, list, &routes);
    freeifaddrs(list);
    return name;
}

#pragma mark - Candidates

static BOOL IsIceChars(NSString *text, NSUInteger max) {
    if (text.length == 0 || text.length > max) return NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '+' || c == '/';
        if (!ok) return NO;
    }
    return YES;
}

static BOOL ParseUnsigned(NSString *text, uint64_t max, uint64_t *value) {
    if (text.length == 0 || text.length > 10) return NO;
    uint64_t result = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
        result = result * 10 + (uint64_t)(c - '0');
    }
    if (result > max) return NO;
    *value = result;
    return YES;
}

@implementation SZFriendsOnlineCandidate

+ (instancetype)candidateWithLine:(NSString *)line {
    return [[self alloc] initWithLine:line];
}

- (instancetype)initWithLine:(NSString *)line {
    if (line.length == 0 || line.length > kLineMax) return nil;
    NSString *value = [line hasPrefix:@"a="] ? [line substringFromIndex:2] : line;
    if (![value hasPrefix:@"candidate:"]) return nil;
    NSArray<NSString *> *tokens = [[value substringFromIndex:10] componentsSeparatedByString:@" "];
    // foundation component transport priority address port "typ" type, then name/value pairs.
    if (tokens.count < 8 || tokens.count % 2 != 0) return nil;
    if (!(self = [super init])) return nil;
    uint64_t component = 0, priority = 0, port = 0;
    if (!IsIceChars(tokens[0], kFoundationMax) || !ParseUnsigned(tokens[1], 256, &component) || component != 1 ||
        !ParseUnsigned(tokens[3], UINT32_MAX, &priority) || !ParseUnsigned(tokens[5], UINT16_MAX, &port) ||
        port == 0 || ![tokens[6] isEqualToString:@"typ"]) {
        return nil;
    }
    NSString *transport = tokens[2].uppercaseString;
    if (![transport isEqualToString:@"UDP"] && ![transport isEqualToString:@"TCP"]) return nil;
    _tcp = [transport isEqualToString:@"TCP"];
    NSDictionary<NSString *, NSNumber *> *types = @{
        @"host" : @(SZFriendsOnlineCandidateHost),
        @"srflx" : @(SZFriendsOnlineCandidateServerReflexive),
        @"prflx" : @(SZFriendsOnlineCandidatePeerReflexive),
        @"relay" : @(SZFriendsOnlineCandidateRelay),
    };
    if (types[tokens[7]] == nil) return nil;
    _type = types[tokens[7]].integerValue;
    struct in6_addr v6;
    struct in_addr v4;
    BOOL isIPv6 = NO;
    if (!ParseAddress(tokens[4], &v6, &v4, &isIPv6)) return nil;
    char canonical[INET6_ADDRSTRLEN];
    if (inet_ntop(isIPv6 ? AF_INET6 : AF_INET, isIPv6 ? (const void *)&v6 : (const void *)&v4, canonical,
                  sizeof canonical) == NULL) {
        return nil;
    }
    NSString *tcpType = nil;
    for (NSUInteger i = 8; i + 1 < tokens.count; i += 2) {
        if (tokens[i].length == 0 || tokens[i + 1].length == 0) return nil;
        uint64_t related = 0;
        if ([tokens[i] isEqualToString:@"rport"]) {
            if (!ParseUnsigned(tokens[i + 1], UINT16_MAX, &related)) return nil;
            _relatedPort = (uint16_t)related;
        } else if ([tokens[i] isEqualToString:@"tcptype"]) {
            tcpType = tokens[i + 1];
        }
    }
    // Only simultaneous-open TCP candidates (RFC 6544 "so"): libjuice's own active ones never pair two helpers.
    if (_tcp != (tcpType != nil) || (_tcp && ![tcpType isEqualToString:@"so"])) return nil;
    _foundation = [tokens[0] copy];
    _priority = (uint32_t)priority;
    _address = @(canonical);
    _port = (uint16_t)port;
    _ipv6 = isIPv6;
    _addressClass = isIPv6 ? ClassifyIPv6(v6.s6_addr) : ClassifyIPv4((const uint8_t *)&v4.s_addr);
    _line = [NSString stringWithFormat:@"candidate:%@ 1 %@ %u %@ %u typ %@%@", _foundation, _tcp ? @"TCP" : @"UDP",
                                       _priority, _address, (unsigned)_port, tokens[7], _tcp ? @" tcptype so" : @""];
    _endpoint = [NSString stringWithFormat:@"%@ %@ %u", _tcp ? @"TCP" : @"UDP", _address, (unsigned)_port];
    return self;
}

@end

#pragma mark - Rules

BOOL SZFriendsOnlineMayUsePrivateAddresses(SZFriendsOnlinePurpose purpose) {
    return SZFriendsOnlinePurposeMayOfferPrivateHostCandidates(purpose);
}

static BOOL AddressAllowed(SZFriendsOnlineAddressClass addressClass, SZFriendsOnlinePurpose purpose,
                           BOOL allowLoopback) {
    switch (addressClass) {
    case SZFriendsOnlineAddressLoopback:
        return allowLoopback;
    case SZFriendsOnlineAddressPrivate:
        return SZFriendsOnlineMayUsePrivateAddresses(purpose);
    case SZFriendsOnlineAddressPublicIPv4:
    case SZFriendsOnlineAddressGlobalIPv6:
        return YES;
    case SZFriendsOnlineAddressUnusable:
        return NO;
    }
    return NO;
}

BOOL SZFriendsOnlineTestLinksUseLocalAddresses = NO;

// With SZFriendsOnlineTestLinksUseLocalAddresses, the testing transport (allowLoopback) also lets links and first
// contacts use what a test on one Mac has: loopback host candidates, and a local relay whose relayed address is en0's
// private one. Production never takes these paths.
static BOOL TestLinkAddresses(BOOL allowLoopback) {
    return allowLoopback && SZFriendsOnlineTestLinksUseLocalAddresses;
}

static BOOL TestRelayAllowed(SZFriendsOnlineCandidate *candidate, BOOL allowLoopback) {
    return TestLinkAddresses(allowLoopback) && candidate.type == SZFriendsOnlineCandidateRelay &&
           candidate.addressClass == SZFriendsOnlineAddressPrivate;
}

SZFriendsOnlineTechnique SZFriendsOnlineLocalCandidateTechnique(SZFriendsOnlineCandidate *candidate,
                                                                SZFriendsOnlinePurpose purpose,
                                                                SZFriendsOnlineConnectionKind kind,
                                                                const char *interfaceName, BOOL allowLoopback) {
    SZFriendsOnlineAddressClass addressClass = candidate.addressClass;
    if (!AddressAllowed(addressClass, purpose, allowLoopback) && !TestRelayAllowed(candidate, allowLoopback)) {
        return SZFriendsOnlineTechniqueNone;
    }
    if (kind == SZFriendsOnlineConnectionRelay) {
        BOOL relay = candidate.type == SZFriendsOnlineCandidateRelay && !candidate.tcp;
        return relay ? SZFriendsOnlineTechniqueRelay : SZFriendsOnlineTechniqueNone;
    }
    if (candidate.tcp && kind != SZFriendsOnlineConnectionDirect) return SZFriendsOnlineTechniqueNone;
    switch (candidate.type) {
    case SZFriendsOnlineCandidateHost: {
        BOOL testLoopback = addressClass == SZFriendsOnlineAddressLoopback && allowLoopback;
        if (!testLoopback && !SZFriendsOnlineInterfaceMayOfferHostCandidates(interfaceName)) {
            return SZFriendsOnlineTechniqueNone;
        }
        // Links and first contacts are offered global IPv6 host addresses only (ADR 0009, lead decision).
        if (addressClass != SZFriendsOnlineAddressGlobalIPv6 && !SZFriendsOnlineMayUsePrivateAddresses(purpose) &&
            !(testLoopback && TestLinkAddresses(allowLoopback))) {
            return SZFriendsOnlineTechniqueNone;
        }
        if (candidate.tcp) return SZFriendsOnlineTechniqueTCPSimultaneousOpen;
        return addressClass == SZFriendsOnlineAddressGlobalIPv6 ? SZFriendsOnlineTechniqueHostIPv6
                                                                : SZFriendsOnlineTechniqueHostPrivate;
    }
    case SZFriendsOnlineCandidateServerReflexive:
        return candidate.tcp ? SZFriendsOnlineTechniqueTCPSimultaneousOpen : SZFriendsOnlineTechniqueServerReflexive;
    case SZFriendsOnlineCandidatePeerReflexive:
    case SZFriendsOnlineCandidateRelay:
        return SZFriendsOnlineTechniqueNone; // never gathered outside a relay connection; nothing to send
    }
    return SZFriendsOnlineTechniqueNone;
}

BOOL SZFriendsOnlineMayDialRemoteCandidate(SZFriendsOnlineCandidate *candidate, SZFriendsOnlinePurpose purpose,
                                           SZFriendsOnlineConnectionKind kind, BOOL allowLoopback) {
    BOOL allowed = AddressAllowed(candidate.addressClass, purpose, allowLoopback);
    if (!allowed && !TestRelayAllowed(candidate, allowLoopback)) return NO;
    if (candidate.type == SZFriendsOnlineCandidatePeerReflexive) return NO; // learnt from checks, never signalled
    BOOL relay = candidate.type == SZFriendsOnlineCandidateRelay;
    if (kind == SZFriendsOnlineConnectionRelay) return relay && !candidate.tcp;
    if (candidate.tcp) return kind == SZFriendsOnlineConnectionDirect && !relay;
    return YES;
}

SZFriendsOnlineTechnique SZFriendsOnlineTechniqueForPair(SZFriendsOnlineCandidate *local,
                                                         SZFriendsOnlineTechnique localTechnique,
                                                         SZFriendsOnlineCandidate *remote,
                                                         SZFriendsOnlineTechnique remoteTechnique,
                                                         SZFriendsOnlineConnectionKind kind) {
    if (local.type == SZFriendsOnlineCandidateRelay || remote.type == SZFriendsOnlineCandidateRelay) {
        return SZFriendsOnlineTechniqueRelay;
    }
    if (kind == SZFriendsOnlineConnectionProbeHandover) return SZFriendsOnlineTechniqueProbeHandover;
    for (NSInteger i = 0; i < 2; i++) {
        SZFriendsOnlineTechnique named = i == 0 ? SZFriendsOnlineTechniquePortMapping
                                                : SZFriendsOnlineTechniquePredictedPort;
        if (localTechnique == named || remoteTechnique == named) return named;
    }
    const SZFriendsOnlineTechnique reflexive = SZFriendsOnlineTechniqueServerReflexive;
    const SZFriendsOnlineCandidateType reflexiveType = SZFriendsOnlineCandidateServerReflexive;
    if (local.type == reflexiveType || remote.type == reflexiveType || localTechnique == reflexive ||
        remoteTechnique == reflexive) {
        return reflexive;
    }
    if (local.type == SZFriendsOnlineCandidatePeerReflexive || remote.type == SZFriendsOnlineCandidatePeerReflexive) {
        return SZFriendsOnlineTechniquePeerReflexive;
    }
    const SZFriendsOnlineAddressClass global = SZFriendsOnlineAddressGlobalIPv6;
    if (local.addressClass == global && remote.addressClass == global) {
        return SZFriendsOnlineTechniqueHostIPv6;
    }
    return SZFriendsOnlineTechniqueHostPrivate;
}
