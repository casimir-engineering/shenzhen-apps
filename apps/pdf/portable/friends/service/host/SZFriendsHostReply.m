// What the check-in client believes from a host (HOST-PROTOCOL.md § Signatures): a reservation answer counts only
// when its host_sig is the host key's signature over this connection's challenge and the reply's fields, checked
// against the public key the signed list gives that host, and a Friends ID only when the word list accepts it in
// canonical form. Each body mirrors welcomeBody, reserveResultBody and releasedBody in
// portable/server/friends/src/protocol.js; the shared vectors hold both sides to the same bytes.

#import "service/host/SZFriendsHostInternal.h"
#import "service/identity/SZFriendsIdentity.h"

#import <sodium.h>

NSString *const SZFriendsHostReplyDomain = @"SZFriends host reply v1";

// A JSON string field as signed: the string, or "" for null or anything else (which then fails to verify unless
// the host signed "" too, and the host never signs a non-string).
static NSString *SZFriendsHostReplyString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSString *SZFriendsHostReplyFlag(id value) {
    return [value isEqual:@YES] ? @"1" : @"0";
}

NSArray *SZFriendsHostWelcomeBody(NSString *requested, NSDictionary *message) {
    id list = message[@"host_list"];
    NSString *payload = [list isKindOfClass:[NSDictionary class]] ? SZFriendsHostReplyString(list[@"payload"]) : @"";
    return @[
        @"welcome", requested ?: @"", SZFriendsHostReplyString(message[@"reservation"]),
        SZFriendsHostReplyString(message[@"friends_id"]), SZFriendsHostReplyFlag(message[@"update_required"]),
        payload
    ];
}

NSArray *SZFriendsHostReserveResultBody(NSString *requested, NSDictionary *message) {
    return @[
        @"reserve_result", requested ?: @"", SZFriendsHostReplyString(message[@"reservation"]),
        SZFriendsHostReplyString(message[@"friends_id"])
    ];
}

NSArray *SZFriendsHostReleasedBody(NSDictionary *message) {
    return @[ @"released", SZFriendsHostReplyFlag(message[@"released"]) ];
}

NSData *SZFriendsHostReplyMessage(NSData *challenge, NSArray *body) {
    NSData *fields = SZFriendsHostLengthPrefixed(body);
    NSMutableData *digest = [NSMutableData dataWithLength:crypto_hash_sha256_BYTES];
    crypto_hash_sha256(digest.mutableBytes, fields.bytes, fields.length);
    return SZFriendsHostLengthPrefixed(@[ challenge, digest ]);
}

BOOL SZFriendsHostReplyVerifies(NSDictionary *message, NSArray *body, NSData *challenge, NSData *hostKey) {
    NSData *signature = SZFriendsHostBase64URLDecode(message[@"host_sig"], crypto_sign_BYTES);
    if (signature == nil || challenge.length != 32 || hostKey.length != crypto_sign_PUBLICKEYBYTES) return NO;
    NSMutableData *signedBytes = [[SZFriendsHostReplyDomain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [signedBytes appendData:SZFriendsHostReplyMessage(challenge, body)];
    return crypto_sign_verify_detached(signature.bytes, signedBytes.bytes, signedBytes.length, hostKey.bytes) == 0;
}

NSString *SZFriendsHostCanonicalID(id value, SZFriendsIDCodec *codec) {
    if (codec == nil || ![value isKindOfClass:[NSString class]] || [value length] > 64) return nil;
    NSString *normalized = [codec normalizedID:value];
    return [normalized isEqualToString:value] ? value : nil;
}
