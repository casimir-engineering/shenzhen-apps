// Session descriptions and ICE server URLs: what the transport accepts from the authenticated exchange and hands to
// libdatachannel. The fingerprint check here is half of rule 4 in SZFriendsOnlineTransport.h; libdatachannel's
// DTLS verification against the applied SDP is the other half.

#import "service/online/transport/SZFriendsOnlineTransportInternal.h"

// Credentials and host names in a TURN URI are short; anything longer is not from the signed host list.
static const NSUInteger kURIFieldMax = 512;

NSData *SZFriendsOnlineFingerprintFromHex(NSString *hex) {
    NSArray<NSString *> *pairs = [hex componentsSeparatedByString:@":"];
    if (pairs.count != SZFriendsOnlineFingerprintLength) return nil;
    NSMutableData *bytes = [NSMutableData dataWithCapacity:SZFriendsOnlineFingerprintLength];
    for (NSString *pair in pairs) {
        if (pair.length != 2) return nil;
        unsigned value = 0;
        for (NSUInteger i = 0; i < 2; i++) {
            unichar c = [pair characterAtIndex:i];
            unsigned digit;
            if (c >= '0' && c <= '9') digit = c - '0';
            else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
            else return nil;
            value = value * 16 + digit;
        }
        uint8_t byte = (uint8_t)value;
        [bytes appendBytes:&byte length:1];
    }
    return bytes;
}

static BOOL IsPrintableASCII(NSString *text) {
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c != '\r' && c != '\n' && (c < 0x20 || c > 0x7E)) return NO;
    }
    return YES;
}

@implementation SZFriendsOnlineDescription

+ (instancetype)descriptionWithSDP:(NSString *)sdp error:(NSError **)error {
    NSString *reason = nil;
    SZFriendsOnlineDescription *description = [[self alloc] initWithSDP:sdp reason:&reason];
    if (description == nil && error) {
        SZFriendsOnlineError code = [reason isEqualToString:@"fingerprint"] ? SZFriendsOnlineErrorFingerprintMismatch
                                                                           : SZFriendsOnlineErrorDescriptionInvalid;
        *error = SZFriendsOnlineMakeError(code, [NSString stringWithFormat:@"description refused: %@", reason]);
    }
    return description;
}

- (instancetype)initWithSDP:(NSString *)sdp reason:(NSString **)reason {
    if (sdp.length == 0 || [sdp lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > SZFriendsOnlineSignalPayloadMax ||
        !IsPrintableASCII(sdp)) {
        *reason = @"size or characters";
        return nil;
    }
    NSArray<NSString *> *lines = [[sdp stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
        componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSData *fingerprint = nil;
    NSString *mid = nil;
    NSUInteger mediaSections = 0;
    BOOL ufrag = NO, password = NO;
    for (NSString *line in lines) {
        if (line.length == 0) continue;
        if ([line hasPrefix:@"a=candidate:"]) {
            [candidates addObject:[line substringFromIndex:2]];
            continue;
        }
        if ([line isEqualToString:@"a=end-of-candidates"]) continue;
        if ([line hasPrefix:@"m="]) {
            mediaSections++;
            // One data channel section and nothing else: no audio, no video (libdatachannel is built without media).
            if (![line hasPrefix:@"m=application "] || ![line hasSuffix:@" webrtc-datachannel"]) {
                *reason = @"not a data channel section";
                return nil;
            }
        } else if ([line hasPrefix:@"a=fingerprint:"]) {
            NSString *value = [line substringFromIndex:14];
            NSData *parsed = [value.lowercaseString hasPrefix:@"sha-256 "]
                                 ? SZFriendsOnlineFingerprintFromHex([value substringFromIndex:8])
                                 : nil;
            // Another algorithm, or a second different SHA-256: DTLS could then be checked against either.
            if (parsed == nil || (fingerprint != nil && ![fingerprint isEqualToData:parsed])) {
                *reason = @"fingerprint";
                return nil;
            }
            fingerprint = parsed;
        } else if ([line hasPrefix:@"a=mid:"] && mid == nil) {
            mid = [line substringFromIndex:6];
        } else if ([line hasPrefix:@"a=ice-ufrag:"]) {
            ufrag = YES;
        } else if ([line hasPrefix:@"a=ice-pwd:"]) {
            password = YES;
        }
        [kept addObject:line];
    }
    if (kept.count == 0 || ![kept[0] isEqualToString:@"v=0"] || mediaSections != 1 || !ufrag || !password ||
        mid.length == 0 || mid.length > 32) {
        *reason = @"incomplete";
        return nil;
    }
    if (fingerprint == nil) {
        *reason = @"fingerprint";
        return nil;
    }
    if (!(self = [super init])) return nil;
    _sdp = [[kept componentsJoinedByString:@"\r\n"] stringByAppendingString:@"\r\n"];
    _candidates = [candidates copy];
    _fingerprint = [fingerprint copy];
    _mid = [mid copy];
    return self;
}

@end

#pragma mark - ICE server URLs

// host, host:port, [v6] or [v6]:port; the host a DNS name or a literal, nothing else.
static BOOL IsHostPort(NSString *text) {
    if (text.length == 0 || text.length > kURIFieldMax) return NO;
    NSCharacterSet *allowed = [NSCharacterSet
        characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]"];
    if ([text rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return NO;
    NSString *port = nil;
    if ([text hasPrefix:@"["]) {
        NSRange close = [text rangeOfString:@"]"];
        if (close.location == NSNotFound || close.location < 2) return NO;
        NSString *rest = [text substringFromIndex:close.location + 1];
        if (rest.length > 0) {
            if (![rest hasPrefix:@":"]) return NO;
            port = [rest substringFromIndex:1];
        }
    } else {
        NSArray<NSString *> *parts = [text componentsSeparatedByString:@":"];
        if (parts.count > 2 || parts[0].length == 0 || [parts[0] containsString:@"["]) return NO;
        if (parts.count == 2) port = parts[1];
    }
    if (port != nil) {
        NSInteger value = port.integerValue;
        if (port.length == 0 || port.length > 5 || value <= 0 || value > 65535 ||
            ![port isEqualToString:[NSString stringWithFormat:@"%ld", (long)value]]) {
            return NO;
        }
    }
    return YES;
}

BOOL SZFriendsOnlineSTUNURIIsValid(NSString *uri) {
    return [uri hasPrefix:@"stun:"] && IsHostPort([uri substringFromIndex:5]);
}

static NSString *PercentEncoded(NSString *text) {
    NSCharacterSet *unreserved =
        [NSCharacterSet characterSetWithCharactersInString:
                            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];
    return [text stringByAddingPercentEncodingWithAllowedCharacters:unreserved];
}

NSString *SZFriendsOnlineTURNServerURL(id<SZFriendsOnlineRelayCredentials> relay, NSDate *now, NSError **error) {
    NSString *uri = relay.turnURI;
    NSString *hostPort = nil;
    if ([uri hasPrefix:@"turn:"]) {
        hostPort = [uri substringFromIndex:5];
        // libjuice relays over UDP only (ADR 0009 § Gaps): a TCP or TLS URI is not one this stack can use.
        if ([hostPort hasSuffix:@"?transport=udp"]) hostPort = [hostPort substringToIndex:hostPort.length - 14];
    }
    NSString *reason = nil;
    if (hostPort == nil || !IsHostPort(hostPort)) {
        reason = @"not a TURN over UDP URI";
    } else if (relay.username.length == 0 || relay.username.length > kURIFieldMax || relay.credential.length == 0 ||
               relay.credential.length > kURIFieldMax) {
        reason = @"credentials missing";
    } else if (relay.expires == nil || [relay.expires compare:now] != NSOrderedDescending) {
        reason = @"credentials expired";
    }
    if (reason != nil) {
        if (error) *error = SZFriendsOnlineMakeError(SZFriendsOnlineErrorNotAuthorized, reason);
        return nil;
    }
    return [NSString stringWithFormat:@"turn:%@:%@@%@?transport=udp", PercentEncoded(relay.username),
                                      PercentEncoded(relay.credential), hostPort];
}
