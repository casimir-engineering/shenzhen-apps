#import "SPDFMacAIWebAddress.h"
#include <arpa/inet.h>

NSString* const SPDFMacAIWebErrorDomain = @"ShenzhenPDF.AI.Web";
NSString* const SPDFMacAIWebHTTPStatusKey = @"status";

NSError* SPDFMacAIWebMakeError(SPDFMacAIWebError code, NSString* message) {
    return [NSError errorWithDomain:SPDFMacAIWebErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey : message ?: @"The page could not be opened."}];
}

// The longest URL a tool call may name; longer ones are refused rather than clipped into a different address.
static const NSUInteger kMaximumURLLength = 2048;

SPDFMacAIWebAddressKind SPDFMacAIWebClassifyIPv4(const uint8_t a[4]) {
    if (a[0] == 0) return SPDFMacAIWebAddressReserved; // "this network"; 0.0.0.0 reaches this Mac on macOS
    if (a[0] == 127) return SPDFMacAIWebAddressLoopback;
    if (a[0] == 10 || (a[0] == 172 && (a[1] & 0xF0) == 16) || (a[0] == 192 && a[1] == 168))
        return SPDFMacAIWebAddressPrivate;
    if (a[0] == 169 && a[1] == 254) return SPDFMacAIWebAddressLinkLocal;
    if (a[0] == 100 && (a[1] & 0xC0) == 64) return SPDFMacAIWebAddressShared;
    if (a[0] >= 224 && a[0] <= 239) return SPDFMacAIWebAddressMulticast;
    if (a[0] >= 240) return SPDFMacAIWebAddressReserved; // includes 255.255.255.255
    // IETF protocol assignments, the three documentation networks and the retired 6to4 relay anycast prefix.
    if (a[0] == 192 && a[1] == 0 && (a[2] == 0 || a[2] == 2)) return SPDFMacAIWebAddressReserved;
    if ((a[0] == 192 && a[1] == 88 && a[2] == 99) || (a[0] == 198 && a[1] == 51 && a[2] == 100) ||
        (a[0] == 203 && a[1] == 0 && a[2] == 113))
        return SPDFMacAIWebAddressReserved;
    // 198.18.0.0/15 (benchmarking) stays allowed on purpose: proxy apps in "fake IP" mode (Surge, Clash) answer every
    // name with an address there and carry the connection to the real site, so refusing it would refuse every page.
    return SPDFMacAIWebAddressPublic;
}

static BOOL Zero(const uint8_t* bytes, size_t count) {
    for (size_t index = 0; index < count; index++) if (bytes[index]) return NO;
    return YES;
}

SPDFMacAIWebAddressKind SPDFMacAIWebClassifyIPv6(const uint8_t a[16]) {
    if (Zero(a, 10) && a[10] == 0xFF && a[11] == 0xFF) return SPDFMacAIWebClassifyIPv4(a + 12); // ::ffff:a.b.c.d
    if (Zero(a, 12)) { // ::, ::1 and the retired IPv4-compatible ::a.b.c.d
        return Zero(a + 12, 3) && a[15] == 1 ? SPDFMacAIWebAddressLoopback : SPDFMacAIWebAddressReserved;
    }
    if (a[0] == 0x00 && a[1] == 0x64 && a[2] == 0xFF && a[3] == 0x9B) {
        // NAT64's well-known prefix carries the IPv4 destination; 64:ff9b:1::/48 is for local use.
        return Zero(a + 4, 8) ? SPDFMacAIWebClassifyIPv4(a + 12) : SPDFMacAIWebAddressReserved;
    }
    if (a[0] == 0xFF) return SPDFMacAIWebAddressMulticast;
    if (a[0] == 0xFE && (a[1] & 0xC0) == 0x80) return SPDFMacAIWebAddressLinkLocal;
    if ((a[0] == 0xFE && (a[1] & 0xC0) == 0xC0) || (a[0] & 0xFE) == 0xFC) return SPDFMacAIWebAddressPrivate;
    // Only global unicast (2000::/3) reaches the internet; the rest is reserved, discard-only or not yet assigned.
    if ((a[0] & 0xE0) != 0x20) return SPDFMacAIWebAddressReserved;
    if (a[0] == 0x20 && a[1] == 0x02) return SPDFMacAIWebClassifyIPv4(a + 2); // 6to4 embeds its IPv4 gateway
    // 2001::/23 holds Teredo (which tunnels to an obfuscated IPv4 address), benchmarking and other protocol
    // assignments; 2001:db8::/32 and 3fff::/20 are documentation. No web page lives there.
    if (a[0] == 0x20 && a[1] == 0x01 && a[2] <= 0x01) return SPDFMacAIWebAddressReserved;
    if (a[0] == 0x20 && a[1] == 0x01 && a[2] == 0x0D && a[3] == 0xB8) return SPDFMacAIWebAddressReserved;
    if (a[0] == 0x3F && a[1] == 0xFF && (a[2] & 0xF0) == 0) return SPDFMacAIWebAddressReserved;
    return SPDFMacAIWebAddressPublic;
}

BOOL SPDFMacAIWebParseIPv4(NSString* text, uint8_t out[4]) {
    NSData* ascii = [text dataUsingEncoding:NSASCIIStringEncoding];
    if (!ascii.length || ascii.length > 64) return NO;
    const char* bytes = (const char*)ascii.bytes;
    size_t length = ascii.length, index = 0;
    uint64_t parts[4];
    int count = 0;
    for (;;) {
        if (count == 4 || index >= length) return NO; // a fifth part, or an empty one ("1..2", "1.2.")
        int base = 10;
        if (bytes[index] == '0' && index + 1 < length && (bytes[index + 1] == 'x' || bytes[index + 1] == 'X')) {
            base = 16;
            index += 2;
        } else if (bytes[index] == '0') base = 8;
        uint64_t value = 0;
        size_t digits = 0;
        for (; index < length && bytes[index] != '.'; index++, digits++) {
            char c = bytes[index];
            int digit = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 :
                c >= 'A' && c <= 'F' ? c - 'A' + 10 : 99;
            if (digit >= base) return NO;
            value = value * (uint64_t)base + (uint64_t)digit;
            if (value > 0xFFFFFFFFull) return NO;
        }
        if (!digits) return NO; // "0x" with nothing after it
        parts[count++] = value;
        if (index == length) break;
        index++;
    }
    // inet_aton: the last part fills every byte the earlier ones left.
    uint64_t last = parts[count - 1], limit = 0xFFFFFFFFull >> (8 * (count - 1));
    if (last > limit) return NO;
    uint32_t value = (uint32_t)last;
    for (int part = 0; part < count - 1; part++) {
        if (parts[part] > 255) return NO;
        value |= (uint32_t)parts[part] << (24 - 8 * part);
    }
    out[0] = (uint8_t)(value >> 24); out[1] = (uint8_t)(value >> 16); out[2] = (uint8_t)(value >> 8);
    out[3] = (uint8_t)value;
    return YES;
}

BOOL SPDFMacAIWebParseAddress(NSString* text, SPDFMacAIWebAddressKind* kind, NSString** canonical) {
    if (![text isKindOfClass:NSString.class]) return NO;
    NSString* inner = text;
    if ([inner hasPrefix:@"["] && [inner hasSuffix:@"]"] && inner.length > 2)
        inner = [inner substringWithRange:NSMakeRange(1, inner.length - 2)];
    if ([inner containsString:@":"]) {
        // A zone ("%en0") only exists for link-local addresses; inet_pton refuses it too, but say so on purpose.
        if ([inner containsString:@"%"] || inner.length > 64) return NO;
        uint8_t bytes[16];
        if (inet_pton(AF_INET6, inner.UTF8String, bytes) != 1) return NO;
        char buffer[INET6_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET6, bytes, buffer, sizeof(buffer));
        if (kind) *kind = SPDFMacAIWebClassifyIPv6(bytes);
        if (canonical) *canonical = @(buffer);
        return YES;
    }
    uint8_t bytes[4];
    if (!SPDFMacAIWebParseIPv4(inner, bytes)) return NO;
    if (kind) *kind = SPDFMacAIWebClassifyIPv4(bytes);
    if (canonical) *canonical = [NSString stringWithFormat:@"%u.%u.%u.%u", bytes[0], bytes[1], bytes[2], bytes[3]];
    return YES;
}

static NSString* KindName(SPDFMacAIWebAddressKind kind) {
    switch (kind) {
        case SPDFMacAIWebAddressLoopback: return @"this Mac's own (loopback) address";
        case SPDFMacAIWebAddressPrivate: return @"a private network address";
        case SPDFMacAIWebAddressLinkLocal: return @"a link-local address";
        case SPDFMacAIWebAddressShared: return @"a carrier-grade NAT (shared) address";
        case SPDFMacAIWebAddressMulticast: return @"a multicast address";
        default: return @"a reserved address";
    }
}

static NSString* PrivateRefusal(NSString* host, SPDFMacAIWebAddressKind kind) {
    return [NSString stringWithFormat:@"%@ is %@, and open_page never opens pages on the user's own network or "
            "addresses that are not on the public internet. If the user needs that page, they can open it themselves.",
            host, KindName(kind)];
}

NSString* SPDFMacAIWebAddressRefusal(NSString* address) {
    SPDFMacAIWebAddressKind kind = SPDFMacAIWebAddressReserved;
    if (!SPDFMacAIWebParseAddress(address, &kind, NULL))
        return [NSString stringWithFormat:@"%@ is not an address open_page can connect to.", address];
    return kind == SPDFMacAIWebAddressPublic ? nil : PrivateRefusal(address, kind);
}

// Names that only mean something on the person's own network (RFC 6761, 6762 Appendix G, 8375) or are reserved and
// never public. Names that resolve to private addresses (127.0.0.1.nip.io) are caught after resolution instead.
static BOOL IsLocalName(NSString* host) {
    static NSArray<NSString*>* suffixes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        suffixes = @[@"localhost", @"local", @"localdomain", @"internal", @"intranet", @"private", @"corp", @"home",
                     @"lan", @"arpa", @"test", @"invalid", @"example"];
    });
    // A name without a dot is completed with the network's search domains, so it reaches a local host.
    if (![host containsString:@"."]) return YES;
    for (NSString* suffix in suffixes)
        if ([host isEqual:suffix] || [host hasSuffix:[@"." stringByAppendingString:suffix]]) return YES;
    return NO;
}

static BOOL ValidName(NSString* host) {
    static NSCharacterSet* invalid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        invalid = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-_."]
            .invertedSet;
    });
    if (!host.length || host.length > 253 || [host rangeOfCharacterFromSet:invalid].location != NSNotFound) return NO;
    for (NSString* label in [host componentsSeparatedByString:@"."])
        if (!label.length || label.length > 63) return NO;
    return YES;
}

// The resolver reads a name whose last label is a number ("2130706433", "10.1", "0x7f.1") as an IPv4 address, so
// such a host is judged as a number here and never handed to it as a name.
static BOOL LooksNumeric(NSString* host) {
    NSString* label = [host componentsSeparatedByString:@"."].lastObject;
    NSString* digits = @"0123456789";
    if ([label hasPrefix:@"0x"]) {
        label = [label substringFromIndex:2];
        digits = @"0123456789abcdef";
        if (!label.length) return YES; // "0x" alone: not a name, and not a number either
    }
    NSCharacterSet* other = [NSCharacterSet characterSetWithCharactersInString:digits].invertedSet;
    return label.length && [label rangeOfCharacterFromSet:other].location == NSNotFound;
}

@implementation SPDFMacAIWebTarget
- (instancetype)initWithURL:(NSURL*)URL host:(NSString*)host port:(uint16_t)port target:(NSString*)target
                     header:(NSString*)header literal:(NSString*)literal {
    if (!(self = [super init])) return nil;
    _URL = URL;
    _host = [host copy];
    _port = port;
    _requestTarget = [target copy];
    _hostHeader = [header copy];
    _literalAddress = [literal copy];
    return self;
}
@end

static BOOL Printable(NSString* text) {
    for (NSUInteger index = 0; index < text.length; index++) {
        unichar c = [text characterAtIndex:index];
        if (c < 0x21 || c > 0x7E) return NO;
    }
    return YES;
}

static SPDFMacAIWebTarget* Refuse(NSError** error, SPDFMacAIWebError code, NSString* message) {
    if (error) *error = SPDFMacAIWebMakeError(code, message);
    return nil;
}

SPDFMacAIWebTarget* SPDFMacAIWebTargetForURL(NSURL* URL, NSError** error) {
    if (error) *error = nil;
    NSString* invalid = @"That is not a web address open_page can open. Give a complete https:// URL.";
    if (![URL isKindOfClass:NSURL.class] || URL.absoluteString.length > kMaximumURLLength)
        return Refuse(error, SPDFMacAIWebErrorInvalidAddress, invalid);
    NSURLComponents* parts = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:YES];
    NSString* scheme = parts.scheme.lowercaseString;
    if (!parts || !scheme.length) return Refuse(error, SPDFMacAIWebErrorInvalidAddress, invalid);
    if (![scheme isEqual:@"https"]) {
        return Refuse(error, SPDFMacAIWebErrorNotHTTPS, [NSString stringWithFormat:@"open_page opens only https:// "
                      "pages, never %@: addresses.", scheme]);
    }
    if (parts.percentEncodedUser || parts.percentEncodedPassword) {
        return Refuse(error, SPDFMacAIWebErrorCredentials, @"open_page never opens an address that carries a user "
                      "name or password.");
    }
    NSString* host = nil;
    if (@available(macOS 13.0, *)) host = parts.encodedHost; // IDNA (punycode) form of an international name
    else host = parts.percentEncodedHost;
    host = host.lowercaseString;
    if ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
    if (!host.length) return Refuse(error, SPDFMacAIWebErrorInvalidAddress, invalid);
    NSNumber* port = parts.port;
    if (port && (port.integerValue < 1 || port.integerValue > 65535))
        return Refuse(error, SPDFMacAIWebErrorInvalidAddress, invalid);
    NSString* literal = nil;
    if ([host hasPrefix:@"["] || [host containsString:@":"]) {
        SPDFMacAIWebAddressKind kind = SPDFMacAIWebAddressReserved;
        NSString* decoded = [host stringByRemovingPercentEncoding] ?: host;
        if ([decoded containsString:@"%"]) { // a zone: only link-local addresses have one
            return Refuse(error, SPDFMacAIWebErrorPrivateAddress,
                          PrivateRefusal(decoded, SPDFMacAIWebAddressLinkLocal));
        }
        if (!SPDFMacAIWebParseAddress(host, &kind, &literal))
            return Refuse(error, SPDFMacAIWebErrorInvalidAddress, invalid);
        if (kind != SPDFMacAIWebAddressPublic)
            return Refuse(error, SPDFMacAIWebErrorPrivateAddress, PrivateRefusal(host, kind));
        host = literal;
    } else if (LooksNumeric(host)) {
        SPDFMacAIWebAddressKind kind = SPDFMacAIWebAddressReserved;
        if (!SPDFMacAIWebParseAddress(host, &kind, &literal))
            return Refuse(error, SPDFMacAIWebErrorInvalidAddress, invalid);
        if (kind != SPDFMacAIWebAddressPublic)
            return Refuse(error, SPDFMacAIWebErrorPrivateAddress, PrivateRefusal(host, kind));
        host = literal;
    } else {
        if (!ValidName(host)) return Refuse(error, SPDFMacAIWebErrorInvalidAddress, invalid);
        if (IsLocalName(host)) {
            return Refuse(error, SPDFMacAIWebErrorLocalName, [NSString stringWithFormat:@"%@ is a local network "
                          "name, and open_page never opens pages on the user's own network. If the user needs that "
                          "page, they can open it themselves.", host]);
        }
    }
    NSString* path = parts.percentEncodedPath.length ? parts.percentEncodedPath : @"/";
    NSString* query = parts.percentEncodedQuery;
    NSString* target = query ? [NSString stringWithFormat:@"%@?%@", path, query] : path;
    if (![path hasPrefix:@"/"] || !Printable(target)) return Refuse(error, SPDFMacAIWebErrorInvalidAddress, invalid);
    uint16_t number = port ? (uint16_t)port.integerValue : 443;
    NSString* authority = [literal containsString:@":"] ? [NSString stringWithFormat:@"[%@]", host] : host;
    NSURLComponents* normal = [NSURLComponents new];
    normal.scheme = @"https";
    normal.percentEncodedHost = authority;
    if (number != 443) normal.port = @(number);
    normal.percentEncodedPath = path;
    normal.percentEncodedQuery = query;
    NSURL* normalized = normal.URL;
    if (!normalized) return Refuse(error, SPDFMacAIWebErrorInvalidAddress, invalid);
    NSString* header = number == 443 ? authority : [NSString stringWithFormat:@"%@:%u", authority, number];
    return [[SPDFMacAIWebTarget alloc] initWithURL:normalized host:host port:number target:target header:header
                                           literal:literal];
}
