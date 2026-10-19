// Link payloads (SZFriendsLinkWire.h; PROTOCOL.md § Links, the app's URL): strict parsing and building.

#import "service/links/SZFriendsLinkWire.h"

const NSUInteger SZFriendsLinkPayloadMax = 512;
const NSUInteger SZFriendsLinkNameMax = 160;
const NSUInteger SZFriendsLinkInviteLength = 16;

static const uint8_t SZFriendsLinkVersion = 1;
static const NSUInteger SZFriendsLinkIDMinBytes = 3, SZFriendsLinkIDMaxBytes = 64;
static const NSUInteger SZFriendsLinkIDBytes = 16, SZFriendsLinkSecretBytes = 32;

#pragma mark - base64url

static int SZFriendsLinkBase64Value(unichar c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '-') return 62;
    if (c == '_') return 63;
    return -1;
}

NSData *SZFriendsLinkBase64URLDecode(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length % 4 == 1) return nil;
    NSMutableData *out = [NSMutableData dataWithCapacity:text.length * 3 / 4];
    uint32_t buffer = 0;
    int bits = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        int value = SZFriendsLinkBase64Value([text characterAtIndex:i]);
        if (value < 0) return nil;
        buffer = (buffer << 6) | (uint32_t)value;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            uint8_t byte = (uint8_t)(buffer >> bits);
            [out appendBytes:&byte length:1];
        }
    }
    // Canonical: the bits left over (2 or 4) must be zero, so one string names one byte sequence.
    if (bits > 0 && (buffer & ((1u << bits) - 1)) != 0) return nil;
    return out;
}

NSString *SZFriendsLinkBase64URLEncode(NSData *data) {
    NSString *text = [data base64EncodedStringWithOptions:0];
    text = [text stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    text = [text stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [text stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

#pragma mark - Friend links

// Lowercase ASCII words joined by single hyphens: what a Friends ID looks like; the codec checks the words later.
static BOOL SZFriendsLinkIDShapeValid(NSData *bytes) {
    const uint8_t *b = bytes.bytes;
    if (bytes.length < SZFriendsLinkIDMinBytes || bytes.length > SZFriendsLinkIDMaxBytes) return NO;
    if (b[0] == '-' || b[bytes.length - 1] == '-') return NO;
    for (NSUInteger i = 0; i < bytes.length; i++) {
        BOOL letter = b[i] >= 'a' && b[i] <= 'z';
        if (!letter && !(b[i] == '-' && b[i - 1] != '-')) return NO;
    }
    return YES;
}

static BOOL SZFriendsLinkNameValid(NSString *name) {
    NSData *bytes = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (bytes == nil || bytes.length > SZFriendsLinkNameMax) return NO;
    NSCharacterSet *control = [NSCharacterSet controlCharacterSet];
    return [name rangeOfCharacterFromSet:control].location == NSNotFound;
}

@implementation SZFriendsFriendLinkPayload

- (NSData *)bytes {
    NSData *idBytes = [self.friendsID dataUsingEncoding:NSUTF8StringEncoding];
    NSData *nameBytes = [self.name ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
    if (self.identityKey.length != 32 || self.inviteToken.length != SZFriendsLinkInviteLength ||
        !SZFriendsLinkIDShapeValid(idBytes) || !SZFriendsLinkNameValid(self.name ?: @"")) {
        return nil;
    }
    NSMutableData *bytes = [NSMutableData dataWithBytes:&SZFriendsLinkVersion length:1];
    [bytes appendData:self.identityKey];
    [bytes appendData:self.inviteToken];
    uint8_t length = (uint8_t)idBytes.length;
    [bytes appendBytes:&length length:1];
    [bytes appendData:idBytes];
    length = (uint8_t)nameBytes.length;
    [bytes appendBytes:&length length:1];
    [bytes appendData:nameBytes];
    return bytes;
}

- (NSString *)payloadString {
    NSData *bytes = [self bytes];
    return bytes ? [@"f." stringByAppendingString:SZFriendsLinkBase64URLEncode(bytes)] : nil;
}

+ (instancetype)payloadFromBytes:(NSData *)data {
    const uint8_t *b = data.bytes;
    NSUInteger n = data.length, at = 1 + 32 + 16;
    if (n < at + 1 || b[0] != SZFriendsLinkVersion) return nil;
    NSUInteger idLength = b[at++];
    if (n < at + idLength + 1) return nil;
    NSData *idBytes = [data subdataWithRange:NSMakeRange(at, idLength)];
    at += idLength;
    NSUInteger nameLength = b[at++];
    if (n != at + nameLength || !SZFriendsLinkIDShapeValid(idBytes)) return nil;
    NSString *name = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(at, nameLength)]
                                           encoding:NSUTF8StringEncoding];
    if (name == nil || !SZFriendsLinkNameValid(name)) return nil;
    SZFriendsFriendLinkPayload *payload = [[SZFriendsFriendLinkPayload alloc] init];
    payload.identityKey = [data subdataWithRange:NSMakeRange(1, 32)];
    payload.inviteToken = [data subdataWithRange:NSMakeRange(33, 16)];
    payload.friendsID = [[NSString alloc] initWithData:idBytes encoding:NSASCIIStringEncoding];
    payload.name = name;
    return payload;
}

@end

#pragma mark - Download links

@implementation SZFriendsDownloadLinkPayload

- (NSString *)payloadString {
    if (self.linkID.length != SZFriendsLinkIDBytes || self.secret.length != SZFriendsLinkSecretBytes) return nil;
    NSMutableData *bytes = [NSMutableData dataWithBytes:&SZFriendsLinkVersion length:1];
    [bytes appendData:self.linkID];
    [bytes appendData:self.secret];
    return [@"d." stringByAppendingString:SZFriendsLinkBase64URLEncode(bytes)];
}

+ (instancetype)payloadFromBytes:(NSData *)data {
    const uint8_t *b = data.bytes;
    if (data.length != 1 + SZFriendsLinkIDBytes + SZFriendsLinkSecretBytes || b[0] != SZFriendsLinkVersion) {
        return nil;
    }
    SZFriendsDownloadLinkPayload *payload = [[SZFriendsDownloadLinkPayload alloc] init];
    payload.linkID = [data subdataWithRange:NSMakeRange(1, SZFriendsLinkIDBytes)];
    payload.secret = [data subdataWithRange:NSMakeRange(1 + SZFriendsLinkIDBytes, SZFriendsLinkSecretBytes)];
    return payload;
}

@end

id SZFriendsParseLinkPayload(id payload) {
    if (![payload isKindOfClass:[NSString class]]) return nil;
    NSString *text = payload;
    if (text.length < 3 || text.length > SZFriendsLinkPayloadMax || [text characterAtIndex:1] != '.') return nil;
    NSData *bytes = SZFriendsLinkBase64URLDecode([text substringFromIndex:2]);
    if (bytes == nil) return nil;
    switch ([text characterAtIndex:0]) {
    case 'f': return [SZFriendsFriendLinkPayload payloadFromBytes:bytes];
    case 'd': return [SZFriendsDownloadLinkPayload payloadFromBytes:bytes];
    default: return nil;
    }
}

NSString *SZFriendsLinkWebURL(NSString *origin, NSString *payload) {
    NSURL *url = [NSURL URLWithString:origin];
    BOOL web = [url.scheme isEqualToString:@"https"] || [url.scheme isEqualToString:@"http"];
    if (!web || url.host.length == 0 || url.path.length > 0 || url.query || url.fragment || url.user ||
        SZFriendsParseLinkPayload(payload) == nil) {
        return nil;
    }
    NSString *kind = [payload substringToIndex:1], *fragment = [payload substringFromIndex:2];
    return [NSString stringWithFormat:@"%@/%@#%@", origin, kind, fragment];
}
