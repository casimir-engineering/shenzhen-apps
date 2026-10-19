// Encodings for the host protocol: strict base64url, the length-prefixed signed messages, JSON framing, the URL
// rule and the pinned-keys file. Each mirrors a function in portable/server/friends/src/ (keys.js, protocol.js,
// online-protocol.js, hostlist.js); the shared vectors in server/friends/test/vectors/host-list-v1.json hold both
// sides to the same bytes, and the host suite checks the protocol 2 ones against the running service.

#import "service/host/SZFriendsHostInternal.h"
#import "service/host/SZFriendsHostRendezvous.h"

#import <sodium.h>

NSErrorDomain const SZFriendsHostErrorDomain = @"SZFriendsHostErrorDomain";
NSString *const SZFriendsHostCheckinDomain = @"SZFriends checkin v1";
NSString *const SZFriendsHostReleaseDomain = @"SZFriends release v1";
NSString *const SZFriendsHostListDomain = @"SZFriends host list v1\n";
const NSUInteger SZFriendsHostMaxMessageBytes = 64 * 1024;
const NSUInteger SZFriendsHostMaxReservesPerConnection = 20;
const NSUInteger SZFriendsHostMaxDrawsPerLaunch = 40;
static const NSInteger SZFriendsHostWireVersion = 1;

NSError *SZFriendsHostMakeError(SZFriendsHostError code, NSString *description) {
    return [NSError errorWithDomain:SZFriendsHostErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}

NSString *SZFriendsHostBase64URLEncode(NSData *data) {
    NSString *standard = [data base64EncodedStringWithOptions:0];
    standard = [standard stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    standard = [standard stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [standard stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

NSData *SZFriendsHostBase64URLDecode(id value, NSUInteger length) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *string = value;
    if (string.length % 4 == 1) return nil;
    static NSCharacterSet *invalid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        invalid = [[NSCharacterSet
            characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"]
            invertedSet];
    });
    if ([string rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
    NSMutableString *standard = [[string stringByReplacingOccurrencesOfString:@"-" withString:@"+"] mutableCopy];
    [standard replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, standard.length)];
    while (standard.length % 4 != 0) [standard appendString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:standard options:0];
    if (data == nil) return nil;
    // Canonical form only: a string whose unused trailing bits are set decodes to the same bytes as another.
    if (![SZFriendsHostBase64URLEncode(data) isEqualToString:string]) return nil;
    if (length != 0 && data.length != length) return nil;
    return data;
}

NSData *SZFriendsHostLengthPrefixed(NSArray *fields) {
    NSMutableData *out = [NSMutableData data];
    for (id field in fields) {
        NSData *bytes = [field isKindOfClass:[NSString class]] ? [field dataUsingEncoding:NSUTF8StringEncoding]
                                                                : (NSData *)field;
        uint32_t length = CFSwapInt32HostToBig((uint32_t)bytes.length);
        [out appendBytes:&length length:sizeof length];
        [out appendData:bytes];
    }
    return out;
}

const NSInteger SZFriendsHostDevicesProtocol = 3;
const NSInteger SZFriendsHostCloseDeviceRevoked = 4002;

NSInteger SZFriendsHostProtocolForChallenge(NSDictionary<NSString *, id> *challenge) {
    id declared = challenge[@"protocol"];
    if (![declared isKindOfClass:[NSNumber class]] || [declared integerValue] < SZFriendsHostDevicesProtocol) return 2;
    return SZFriendsHostProtocolVersion;
}

NSData *SZFriendsHostCheckinMessage(NSString *hostID, NSData *challenge, NSData *identityKey, NSString *friendsID,
                                    BOOL reserved, NSString *appVersion, NSInteger protocol, NSInteger listVersion,
                                    NSData *_Nullable rootKey, NSData *_Nullable chain) {
    NSMutableArray *fields = [@[
        hostID, challenge, identityKey, friendsID, reserved ? @"1" : @"0", appVersion,
        [NSString stringWithFormat:@"%ld", (long)protocol], [NSString stringWithFormat:@"%ld", (long)listVersion]
    ] mutableCopy];
    if (protocol >= SZFriendsHostDevicesProtocol) {
        [fields addObject:rootKey ?: [NSData data]];
        NSMutableData *digest = [NSMutableData dataWithLength:crypto_hash_sha256_BYTES];
        if (chain != nil) crypto_hash_sha256(digest.mutableBytes, chain.bytes, chain.length);
        [fields addObject:chain != nil ? digest : [NSData data]];
    }
    return SZFriendsHostLengthPrefixed(fields);
}

NSData *SZFriendsHostReleaseMessage(NSString *hostID, NSData *challenge, NSData *identityKey, NSString *friendsID) {
    return SZFriendsHostLengthPrefixed(@[ hostID, challenge, identityKey, friendsID ]);
}

#pragma mark - Protocol 2 (HOST-PROTOCOL-ONLINE.md)

NSString *const SZFriendsHostRendezvousKeyDomain = @"SZFriends rendezvous key v1";
NSString *const SZFriendsHostRendezvousRecordDomain = @"SZFriends rendezvous record v1";

static NSData *SZFriendsHostSHA256(NSArray<NSData *> *parts) {
    crypto_hash_sha256_state state;
    crypto_hash_sha256_init(&state);
    for (NSData *part in parts) crypto_hash_sha256_update(&state, part.bytes, part.length);
    NSMutableData *digest = [NSMutableData dataWithLength:crypto_hash_sha256_BYTES];
    crypto_hash_sha256_final(&state, digest.mutableBytes);
    return digest;
}

NSData *SZFriendsHostRendezvousKey(NSData *identityKey) {
    if (identityKey.length != 32) return nil;
    return SZFriendsHostSHA256(@[ [SZFriendsHostRendezvousKeyDomain dataUsingEncoding:NSUTF8StringEncoding],
                                  identityKey ]);
}

NSData *SZFriendsHostRendezvousRecordMessage(NSString *hostID, NSData *rdvKey, uint64_t seq, int64_t expires,
                                             NSData *sealed) {
    return SZFriendsHostLengthPrefixed(@[
        hostID, rdvKey, [NSString stringWithFormat:@"%llu", (unsigned long long)seq],
        [NSString stringWithFormat:@"%lld", (long long)expires], SZFriendsHostSHA256(@[ sealed ])
    ]);
}

NSData *SZFriendsHostEncodeMessage(NSString *type, NSDictionary<NSString *, id> *fields) {
    NSMutableDictionary *message = [fields mutableCopy];
    message[@"type"] = type;
    message[@"v"] = @(SZFriendsHostWireVersion);
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:NULL];
    return data.length <= SZFriendsHostMaxMessageBytes ? data : nil;
}

NSDictionary<NSString *, id> *SZFriendsHostDecodeMessage(NSData *data) {
    if (data.length == 0 || data.length > SZFriendsHostMaxMessageBytes) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![object isKindOfClass:[NSDictionary class]] || ![object[@"type"] isKindOfClass:[NSString class]]) return nil;
    return object;
}

BOOL SZFriendsHostURLAllowed(NSURL *url) {
    if (url.user.length > 0 || url.password.length > 0 || url.fragment != nil || url.host.length == 0) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"wss"]) return YES;
    // Cleartext only on loopback, for the local test harness; NSURL reports [::1] as "::1".
    NSString *host = url.host.lowercaseString;
    BOOL loopback = [host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"::1"] ||
                    [host isEqualToString:@"localhost"];
    return [scheme isEqualToString:@"ws"] && loopback;
}

BOOL SZFriendsHostJSONInteger(id value, long long minimum, long long maximum, long long *out) {
    if (![value isKindOfClass:[NSNumber class]]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    if (number != floor(number) || number < (double)minimum || number > (double)maximum) return NO;
    if (out) *out = (long long)number;
    return YES;
}

NSArray<NSData *> *SZFriendsHostPinnedKeysFromData(NSData *data, BOOL *containsTestKeys, NSError **error) {
    id object = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSArray *entries = [object isKindOfClass:[NSDictionary class]] ? object[@"keys"] : nil;
    if (![entries isKindOfClass:[NSArray class]] || entries.count == 0) {
        if (error) *error = SZFriendsHostMakeError(SZFriendsHostErrorMalformed, @"The pinned-keys file has no keys.");
        return nil;
    }
    NSMutableArray<NSData *> *keys = [NSMutableArray array];
    BOOL anyTest = NO;
    for (id entry in entries) {
        NSData *key =
            [entry isKindOfClass:[NSDictionary class]] ? SZFriendsHostBase64URLDecode(entry[@"public_key"], 32) : nil;
        if (key == nil) {
            if (error) *error = SZFriendsHostMakeError(SZFriendsHostErrorMalformed, @"A pinned key is not 32 bytes.");
            return nil;
        }
        // Only an explicit false counts as production; a missing flag is treated as a test key.
        if (![entry[@"test"] isEqual:@NO]) anyTest = YES;
        [keys addObject:key];
    }
    if (containsTestKeys) *containsTestKeys = anyTest;
    return keys;
}
