// Pure pieces of the Network.framework adapter: TXT records, instance names, route classification, admission keys
// and state.

#import "service/discovery/SZFriendsDiscoveryInternal.h"

#include <arpa/inet.h>
#include <netinet/in.h>

NSErrorDomain const SZFriendsDiscoveryErrorDomain = @"SZFriendsDiscoveryErrorDomain";
NSString *const SZFriendsBonjourServiceType = @"_szfriends._tcp";

NSError *SZFriendsDiscoveryMakeError(SZFriendsDiscoveryError code, NSString *detail) {
    // Detail goes to the helper's log only; Nearby shows per-method states from the strings catalog.
    return [NSError errorWithDomain:SZFriendsDiscoveryErrorDomain
                               code:code
                           userInfo:@{NSDebugDescriptionErrorKey : detail}];
}

NSString *SZFriendsHexFromData(NSData *data) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

static int HexDigit(unichar c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

NSData *SZFriendsDataFromHex(NSString *hex) {
    if (hex.length % 2) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:hex.length / 2];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < hex.length; i += 2) {
        int high = HexDigit([hex characterAtIndex:i]), low = HexDigit([hex characterAtIndex:i + 1]);
        if (high < 0 || low < 0) return nil;
        bytes[i / 2] = (uint8_t)(high << 4 | low);
    }
    return data;
}

static NSData *ASCII(NSString *string) {
    return [string dataUsingEncoding:NSASCIIStringEncoding];
}

NSDictionary<NSString *, NSData *> *SZFriendsNetworkTXTFields(NSData *tag, NSArray<NSData *> *callbackTags,
                                                               BOOL publicEntry) {
    if (publicEntry) return @{@"v" : ASCII(@"1"), @"p" : ASCII(@"1")};
    NSMutableDictionary<NSString *, NSData *> *fields = [NSMutableDictionary dictionaryWithObject:ASCII(@"1")
                                                                                          forKey:@"v"];
    if (tag.length == SZFriendsPresenceTagLength) fields[@"t"] = ASCII(SZFriendsHexFromData(tag));
    NSMutableString *callbacks = [NSMutableString string];
    NSUInteger count = 0;
    for (NSData *callbackTag in callbackTags) {
        if (callbackTag.length != SZFriendsPresenceTagLength || count == SZFriendsCallbackTagsMax) continue;
        [callbacks appendString:SZFriendsHexFromData(callbackTag)];
        count++;
    }
    if (callbacks.length) fields[@"c"] = ASCII(callbacks);
    return fields;
}

static NSString *FieldString(NSDictionary<NSString *, NSData *> *fields, NSString *key) {
    NSData *value = fields[key];
    return value ? [[NSString alloc] initWithData:value encoding:NSASCIIStringEncoding] : nil;
}

BOOL SZFriendsNetworkParseTXT(NSDictionary<NSString *, NSData *> *fields,
                              NSData **tag,
                              NSArray<NSData *> **callbackTags,
                              BOOL *isPublic) {
    *tag = nil;
    *callbackTags = @[];
    *isPublic = NO;
    // Only version 1 is understood; a later format is ignored rather than misread.
    if (![FieldString(fields, @"v") isEqualToString:@"1"]) return NO;
    if ([FieldString(fields, @"p") isEqualToString:@"1"]) {
        *isPublic = YES;
        return YES; // a public entry carries no tag; anything else in it is ignored
    }
    NSData *presence = SZFriendsDataFromHex(FieldString(fields, @"t") ?: @"");
    if (presence.length == SZFriendsPresenceTagLength) *tag = presence;
    NSString *callbackHex = FieldString(fields, @"c") ?: @"";
    NSUInteger tagHexLength = SZFriendsPresenceTagLength * 2;
    if (callbackHex.length % tagHexLength == 0) {
        NSMutableArray<NSData *> *tags = [NSMutableArray array];
        for (NSUInteger i = 0; i < callbackHex.length && tags.count < SZFriendsCallbackTagsMax; i += tagHexLength) {
            NSData *callback = SZFriendsDataFromHex([callbackHex substringWithRange:NSMakeRange(i, tagHexLength)]);
            if (!callback) {
                [tags removeAllObjects];
                break;
            }
            [tags addObject:callback];
        }
        *callbackTags = tags;
    }
    return YES;
}

NSString *SZFriendsRandomInstanceName(void) {
    uint8_t bytes[8];
    arc4random_buf(bytes, sizeof bytes);
    return SZFriendsHexFromData([NSData dataWithBytes:bytes length:sizeof bytes]);
}

SZFriendsRouteMethod SZFriendsRouteForInterfaceName(NSString *interfaceName) {
    if ([interfaceName hasPrefix:@"awdl"] || [interfaceName hasPrefix:@"llw"]) {
        return SZFriendsRouteMethodPeerToPeerWiFi;
    }
    return SZFriendsRouteMethodLAN;
}

NSString *SZFriendsAdmissionKeyForAddress(const struct sockaddr *address) {
    if (address == NULL) return nil;
    char text[INET_ADDRSTRLEN];
    if (address->sa_family == AF_INET) {
        const struct sockaddr_in *v4 = (const struct sockaddr_in *)address;
        if (!inet_ntop(AF_INET, &v4->sin_addr, text, sizeof text)) return nil;
        return [@"4:" stringByAppendingString:@(text)];
    }
    if (address->sa_family != AF_INET6) return nil;
    const struct sockaddr_in6 *v6 = (const struct sockaddr_in6 *)address;
    uint8_t bytes[16];
    memcpy(bytes, v6->sin6_addr.s6_addr, sizeof bytes);
    // A dual-stack listener reports IPv4 peers as ::ffff:a.b.c.d. Their /64 is ::ffff:0:0 for every IPv4 peer, so
    // they are counted as the IPv4 address they are.
    if (IN6_IS_ADDR_V4MAPPED(&v6->sin6_addr)) {
        if (!inet_ntop(AF_INET, bytes + 12, text, sizeof text)) return nil;
        return [@"4:" stringByAppendingString:@(text)];
    }
    NSString *scope = @"";
    if (IN6_IS_ADDR_LINKLOCAL(&v6->sin6_addr)) {
        // The kernel may carry the interface in bytes 2 and 3 of a link-local address rather than in the scope id.
        uint32_t embedded = (uint32_t)bytes[2] << 8 | bytes[3];
        bytes[2] = bytes[3] = 0;
        scope = [NSString stringWithFormat:@"%%%u", v6->sin6_scope_id ? v6->sin6_scope_id : embedded];
    }
    return [NSString stringWithFormat:@"6:%02x%02x:%02x%02x:%02x%02x:%02x%02x/64%@", bytes[0], bytes[1], bytes[2],
                                      bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], scope];
}

SZFriendsAdapterState SZFriendsNetworkAdapterState(BOOL running, BOOL policyDenied, BOOL radioOff, BOOL failed,
                                                   BOOL browserReady, BOOL listenerReady) {
    if (!running) return SZFriendsAdapterStateNotAsked;
    // Denied first: with access refused nothing else can work, and the person can fix it in System Settings.
    if (policyDenied) return SZFriendsAdapterStateDenied;
    if (radioOff) return SZFriendsAdapterStateRadioOff;
    if (failed) return SZFriendsAdapterStateUnavailable;
    if (browserReady && listenerReady) return SZFriendsAdapterStateWorking;
    return SZFriendsAdapterStateStarting;
}
