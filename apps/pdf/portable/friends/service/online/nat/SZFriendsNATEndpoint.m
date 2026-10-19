// Addresses and their scopes for the NAT techniques (SZFriendsNAT.h). The scope table follows the IANA special-purpose
// registries (RFC 6890 and its updates); anything not listed as global there stays out of what a prober may reach.

#import "service/online/nat/SZFriendsNAT.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <string.h>

NSErrorDomain const SZFriendsNATErrorDomain = @"SZFriendsNATErrorDomain";

static BOOL PrefixMatches(const uint8_t *bytes, const uint8_t *prefix, unsigned bits) {
    unsigned whole = bits / 8, rest = bits % 8;
    if (memcmp(bytes, prefix, whole) != 0) return NO;
    if (rest == 0) return YES;
    uint8_t mask = (uint8_t)(0xff << (8 - rest));
    return (bytes[whole] & mask) == (prefix[whole] & mask);
}

static SZFriendsNATAddressScope ScopeOfIPv4(const uint8_t *a) {
    static const struct {
        uint8_t prefix[4];
        unsigned bits;
        SZFriendsNATAddressScope scope;
    } table[] = {
        {{0, 0, 0, 0}, 32, SZFriendsNATAddressScopeUnspecified},
        {{255, 255, 255, 255}, 32, SZFriendsNATAddressScopeMulticast}, // limited broadcast
        {{127, 0, 0, 0}, 8, SZFriendsNATAddressScopeLoopback},
        {{169, 254, 0, 0}, 16, SZFriendsNATAddressScopeLinkLocal},
        {{224, 0, 0, 0}, 4, SZFriendsNATAddressScopeMulticast},
        {{10, 0, 0, 0}, 8, SZFriendsNATAddressScopePrivate},
        {{172, 16, 0, 0}, 12, SZFriendsNATAddressScopePrivate},
        {{192, 168, 0, 0}, 16, SZFriendsNATAddressScopePrivate},
        {{100, 64, 0, 0}, 10, SZFriendsNATAddressScopeShared},
        {{0, 0, 0, 0}, 8, SZFriendsNATAddressScopeReserved},
        {{192, 0, 0, 0}, 24, SZFriendsNATAddressScopeReserved},
        {{192, 0, 2, 0}, 24, SZFriendsNATAddressScopeReserved},
        {{192, 88, 99, 0}, 24, SZFriendsNATAddressScopeReserved},
        {{198, 18, 0, 0}, 15, SZFriendsNATAddressScopeReserved},
        {{198, 51, 100, 0}, 24, SZFriendsNATAddressScopeReserved},
        {{203, 0, 113, 0}, 24, SZFriendsNATAddressScopeReserved},
        {{240, 0, 0, 0}, 4, SZFriendsNATAddressScopeReserved},
    };
    for (size_t i = 0; i < sizeof table / sizeof table[0]; i++) {
        if (PrefixMatches(a, table[i].prefix, table[i].bits)) return table[i].scope;
    }
    return SZFriendsNATAddressScopeGlobal;
}

static SZFriendsNATAddressScope ScopeOfIPv6(const uint8_t *a) {
    static const uint8_t zero[16] = {0};
    static const uint8_t one[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    if (memcmp(a, zero, 16) == 0) return SZFriendsNATAddressScopeUnspecified;
    if (memcmp(a, one, 16) == 0) return SZFriendsNATAddressScopeLoopback;
    if (a[0] == 0xfe && (a[1] & 0xc0) == 0x80) return SZFriendsNATAddressScopeLinkLocal;
    if (a[0] == 0xff) return SZFriendsNATAddressScopeMulticast;
    if ((a[0] & 0xfe) == 0xfc) return SZFriendsNATAddressScopePrivate;
    if ((a[0] & 0xe0) != 0x20) return SZFriendsNATAddressScopeReserved; // outside 2000::/3, NAT64 64:ff9b:: included
    static const struct {
        uint8_t prefix[4];
        unsigned bits;
    } reserved[] = {
        {{0x20, 0x01, 0x0d, 0xb8}, 32}, // documentation
        {{0x20, 0x01, 0x00, 0x00}, 23}, // IETF protocol assignments, Teredo among them
        {{0x20, 0x02, 0x00, 0x00}, 16}, // 6to4: an IPv4 address in disguise
        {{0x3f, 0xff, 0x00, 0x00}, 20}, // documentation (RFC 9637)
    };
    for (size_t i = 0; i < sizeof reserved / sizeof reserved[0]; i++) {
        if (PrefixMatches(a, reserved[i].prefix, reserved[i].bits)) return SZFriendsNATAddressScopeReserved;
    }
    return SZFriendsNATAddressScopeGlobal;
}

SZFriendsNATAddressScope SZFriendsNATScopeOfAddress(const uint8_t *bytes, size_t length) {
    if (bytes == NULL) return SZFriendsNATAddressScopeReserved;
    if (length == 4) return ScopeOfIPv4(bytes);
    if (length == 16) return ScopeOfIPv6(bytes);
    return SZFriendsNATAddressScopeReserved;
}

@implementation SZFriendsNATEndpoint

- (instancetype)initWithAddress:(NSData *)address port:(uint16_t)port scopeID:(uint32_t)scopeID {
    if ((self = [super init])) {
        static const uint8_t mappedPrefix[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff};
        if (address.length == 16 && memcmp(address.bytes, mappedPrefix, 12) == 0) {
            address = [address subdataWithRange:NSMakeRange(12, 4)];
            scopeID = 0;
        }
        _address = [address copy];
        _family = address.length == 4 ? AF_INET : AF_INET6;
        _port = port;
        _scope = SZFriendsNATScopeOfAddress(address.bytes, address.length);
        _scopeID = _scope == SZFriendsNATAddressScopeLinkLocal && _family == AF_INET6 ? scopeID : 0;
        char text[INET6_ADDRSTRLEN] = {0};
        inet_ntop(_family, address.bytes, text, sizeof text);
        _host = @(text);
    }
    return self;
}

+ (instancetype)endpointWithAddress:(NSData *)address port:(uint16_t)port {
    if (address.length != 4 && address.length != 16) return nil;
    return [[self alloc] initWithAddress:address port:port scopeID:0];
}

+ (instancetype)endpointWithSockaddr:(const struct sockaddr *)sockaddr length:(socklen_t)length {
    if (sockaddr == NULL) return nil;
    if (sockaddr->sa_family == AF_INET && length >= (socklen_t)sizeof(struct sockaddr_in)) {
        const struct sockaddr_in *in = (const struct sockaddr_in *)sockaddr;
        return [[self alloc] initWithAddress:[NSData dataWithBytes:&in->sin_addr length:4]
                                        port:ntohs(in->sin_port)
                                     scopeID:0];
    }
    if (sockaddr->sa_family == AF_INET6 && length >= (socklen_t)sizeof(struct sockaddr_in6)) {
        const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)sockaddr;
        return [[self alloc] initWithAddress:[NSData dataWithBytes:&in6->sin6_addr length:16]
                                        port:ntohs(in6->sin6_port)
                                     scopeID:in6->sin6_scope_id];
    }
    return nil;
}

+ (instancetype)endpointWithHost:(NSString *)host port:(uint16_t)port {
    const char *text = host.UTF8String;
    if (text == NULL || strlen(text) >= 64) return nil;
    char copy[64];
    strlcpy(copy, text, sizeof copy);
    uint32_t scopeID = 0;
    char *percent = strchr(copy, '%');
    if (percent != NULL) {
        *percent = '\0';
        const char *zone = percent + 1;
        char *end = NULL;
        unsigned long number = strtoul(zone, &end, 10);
        scopeID = (*zone != '\0' && end != NULL && *end == '\0') ? (uint32_t)number : if_nametoindex(zone);
        if (scopeID == 0) return nil;
    }
    uint8_t bytes[16];
    if (percent == NULL && inet_pton(AF_INET, copy, bytes) == 1) {
        return [[self alloc] initWithAddress:[NSData dataWithBytes:bytes length:4] port:port scopeID:0];
    }
    if (inet_pton(AF_INET6, copy, bytes) == 1) {
        SZFriendsNATEndpoint *endpoint = [[self alloc] initWithAddress:[NSData dataWithBytes:bytes length:16]
                                                                  port:port
                                                               scopeID:scopeID];
        // A zone on anything but a link-local address is a mistake, not an address.
        if (percent != NULL && endpoint.scope != SZFriendsNATAddressScopeLinkLocal) return nil;
        return endpoint;
    }
    return nil;
}

- (instancetype)endpointWithPort:(uint16_t)port {
    return [[SZFriendsNATEndpoint alloc] initWithAddress:_address port:port scopeID:_scopeID];
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}

- (socklen_t)getSockaddr:(struct sockaddr_storage *)storage {
    memset(storage, 0, sizeof *storage);
    if (_family == AF_INET) {
        struct sockaddr_in *in = (struct sockaddr_in *)storage;
        in->sin_len = sizeof *in;
        in->sin_family = AF_INET;
        in->sin_port = htons(_port);
        memcpy(&in->sin_addr, _address.bytes, 4);
        return sizeof *in;
    }
    struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)storage;
    in6->sin6_len = sizeof *in6;
    in6->sin6_family = AF_INET6;
    in6->sin6_port = htons(_port);
    in6->sin6_scope_id = _scopeID;
    memcpy(&in6->sin6_addr, _address.bytes, 16);
    return sizeof *in6;
}

- (BOOL)hasSameAddressAs:(SZFriendsNATEndpoint *)other {
    return other != nil && [_address isEqualToData:other.address] && _scopeID == other.scopeID;
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:[SZFriendsNATEndpoint class]]) return NO;
    SZFriendsNATEndpoint *other = object;
    return [self hasSameAddressAs:other] && _port == other.port;
}

- (NSUInteger)hash {
    return _address.hash ^ ((NSUInteger)_port << 16) ^ _scopeID;
}

- (NSString *)description {
    // Only for test failures: production code never logs an endpoint (ADR 0011 § Technique log).
    return _family == AF_INET6 ? [NSString stringWithFormat:@"[%@]:%u", _host, _port]
                               : [NSString stringWithFormat:@"%@:%u", _host, _port];
}

@end

NSArray<SZFriendsNATEndpoint *> *SZFriendsNATOwnAddresses(void) {
    NSMutableArray<SZFriendsNATEndpoint *> *addresses = [NSMutableArray array];
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return addresses;
    for (struct ifaddrs *entry = list; entry != NULL; entry = entry->ifa_next) {
        if (entry->ifa_addr == NULL) continue;
        socklen_t length = entry->ifa_addr->sa_family == AF_INET ? sizeof(struct sockaddr_in)
                                                                 : sizeof(struct sockaddr_in6);
        SZFriendsNATEndpoint *endpoint = [SZFriendsNATEndpoint endpointWithSockaddr:entry->ifa_addr length:length];
        if (endpoint != nil) [addresses addObject:[endpoint endpointWithPort:0]];
    }
    freeifaddrs(list);
    return addresses;
}
