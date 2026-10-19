// ID attestations (HOST-PROTOCOL.md § ID attestations): the wire form, and the check a requester runs on the one an
// Add by ID answer shows. Mirrors signAttestation and checkAttestation in portable/server/friends/src/attestation.js;
// the shared vectors (server/friends/test/vectors/host-list-v1.json, "attestations") hold both sides to the same
// bytes and the same verdicts.

#import "service/host/SZFriendsHostInternal.h"

#import <sodium.h>

NSString *const SZFriendsHostAttestationDomain = @"SZFriends id attestation v1";
const NSInteger SZFriendsHostAttestationMaxAgeDays = 30;
// Far more than an attestation needs (about 250 bytes); a bound so a peer cannot hand the parser megabytes.
static const NSUInteger SZFriendsHostAttestationMaxBytes = 1024;

NSData *SZFriendsHostAttestationMessage(NSString *hostID, NSString *friendsID, NSData *identityKey, NSString *day) {
    return SZFriendsHostLengthPrefixed(@[ hostID, friendsID, identityKey, day ]);
}

// `pattern` must match the whole string. Patterns end in \z, not $: ICU's $ also matches before a final newline,
// which the host's JavaScript patterns refuse.
static BOOL SZFHAMatches(id value, NSString *pattern) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
    NSString *string = value;
    return [expression numberOfMatchesInString:string options:0 range:NSMakeRange(0, string.length)] == 1;
}

// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's days_from_civil), so day arithmetic never
// depends on a calendar object, a time zone or daylight saving.
static long SZFHADaysFromCivil(long year, long month, long day) {
    year -= month <= 2;
    long era = (year >= 0 ? year : year - 399) / 400;
    long yearOfEra = year - era * 400;
    long dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1;
    long dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear;
    return era * 146097 + dayOfEra - 719468;
}

// The day number of "YYYY-MM-DD" when it is a real calendar day, else NO. The host service refuses the same days
// (2026-02-30 is not 2 March), so both sides agree on what is malformed.
static BOOL SZFHADayNumber(id value, long *out) {
    if (!SZFHAMatches(value, @"^[0-9]{4}-[0-9]{2}-[0-9]{2}\\z")) return NO;
    NSString *day = value;
    long year = [[day substringWithRange:NSMakeRange(0, 4)] integerValue];
    long month = [[day substringWithRange:NSMakeRange(5, 2)] integerValue];
    long date = [[day substringWithRange:NSMakeRange(8, 2)] integerValue];
    static const long lengths[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    BOOL leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    if (month < 1 || month > 12) return NO;
    long length = lengths[month - 1] + (month == 2 && leap ? 1 : 0);
    if (date < 1 || date > length) return NO;
    if (out) *out = SZFHADaysFromCivil(year, month, date);
    return YES;
}

@implementation SZFriendsHostAttestation

+ (instancetype)attestationFromDictionary:(id)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *wire = dictionary;
    NSData *key = SZFriendsHostBase64URLDecode(wire[@"identity_key"], crypto_sign_PUBLICKEYBYTES);
    NSData *signature = SZFriendsHostBase64URLDecode(wire[@"sig"], crypto_sign_BYTES);
    // The host checks IDs by syntax, never by word list (lists change between app versions), and so does this.
    if (!SZFHAMatches(wire[@"host_id"], @"^[a-z0-9][a-z0-9-]{0,31}\\z") ||
        !SZFHAMatches(wire[@"friends_id"], @"^[a-z]{3,8}(-[a-z]{3,8}){1,2}\\z") ||
        !SZFHADayNumber(wire[@"day"], NULL) || key == nil || signature == nil) {
        return nil;
    }
    SZFriendsHostAttestation *attestation = [[SZFriendsHostAttestation alloc] init];
    attestation->_hostID = [wire[@"host_id"] copy];
    attestation->_friendsID = [wire[@"friends_id"] copy];
    attestation->_identityKey = key;
    attestation->_day = [wire[@"day"] copy];
    attestation->_signature = signature;
    return attestation;
}

+ (instancetype)attestationFromData:(NSData *)data {
    if (data.length == 0 || data.length > SZFriendsHostAttestationMaxBytes) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [self attestationFromDictionary:object];
}

- (NSDictionary<NSString *, NSString *> *)dictionary {
    return @{
        @"host_id" : _hostID,
        @"friends_id" : _friendsID,
        @"identity_key" : SZFriendsHostBase64URLEncode(_identityKey),
        @"day" : _day,
        @"sig" : SZFriendsHostBase64URLEncode(_signature),
    };
}

- (NSData *)encodedData {
    return [NSJSONSerialization dataWithJSONObject:[self dictionary] options:NSJSONWritingSortedKeys error:NULL];
}

@end

SZFriendsHostAttestationVerdict SZFriendsHostAttestationCheck(SZFriendsHostAttestation *attestation,
                                                              SZFriendsHostList *list, NSString *friendsID,
                                                              NSData *identityKey, NSDate *now) {
    long day = 0;
    if (attestation == nil || !SZFHADayNumber(attestation.day, &day)) return SZFriendsHostAttestationMalformed;
    SZFriendsHostEntry *host = nil;
    for (SZFriendsHostEntry *entry in list.entries) {
        if ([entry.hostID isEqualToString:attestation.hostID]) host = entry;
    }
    if (host == nil || (host.roles & SZFriendsHostRoleRendezvous) == 0) return SZFriendsHostAttestationUnknownHost;
    NSMutableData *signedBytes = [[SZFriendsHostAttestationDomain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [signedBytes appendData:SZFriendsHostAttestationMessage(attestation.hostID, attestation.friendsID,
                                                            attestation.identityKey, attestation.day)];
    if (host.publicKey.length != crypto_sign_PUBLICKEYBYTES ||
        crypto_sign_verify_detached(attestation.signature.bytes, signedBytes.bytes, signedBytes.length,
                                    host.publicKey.bytes) != 0) {
        return SZFriendsHostAttestationBadSignature;
    }
    if (![attestation.friendsID isEqualToString:friendsID ?: @""] ||
        ![attestation.identityKey isEqualToData:identityKey ?: [NSData data]]) {
        return SZFriendsHostAttestationWrongHolder;
    }
    long today = (long)floor(now.timeIntervalSince1970 / 86400.0);
    if (day > today + 1 || day < today - SZFriendsHostAttestationMaxAgeDays) return SZFriendsHostAttestationExpired;
    return SZFriendsHostAttestationValid;
}
