// Vector export: shared helpers, identity, Friends IDs, presence tags, the session race and comparison codes, and
// main(), which writes one JSON file per area (SZFVectorExport.h).
//
// Usage: SZFVectorExport <output directory> <store v1 fixture>

#import "SZFVectorExport.h"
#import "SZFVectorExportSession.h"

#import <sodium.h>

#import "service/discovery/SZFriendsDiscovery.h"
#import "service/identity/SZFriendsIdentityInternal.h"
#import "service/session/SZFriendsSession.h"

NSString *SZFHexString(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

NSData *SZFUTF8(NSString *string) { return [string dataUsingEncoding:NSUTF8StringEncoding]; }

NSData *SZFDerive(NSString *label, NSUInteger length) {
    NSData *input = SZFUTF8(label);
    NSMutableData *out = [NSMutableData dataWithLength:length];
    crypto_generichash(out.mutableBytes, length, input.bytes, input.length, NULL, 0);
    return out;
}

NSData *SZFDeriveClampedKey(NSString *label) {
    NSMutableData *key = [SZFDerive(label, 32) mutableCopy];
    uint8_t *bytes = key.mutableBytes;
    bytes[0] &= 248;
    bytes[31] &= 127;
    bytes[31] |= 64;
    return key;
}

#pragma mark - Identity

SZFriendsIdentity *SZFVectorIdentity(NSString *name) {
    return [SZFriendsIdentity identityWithSigningSeed:SZFDerive([name stringByAppendingString:@" seed"], 32)
                                     staticPrivateKey:SZFDeriveClampedKey([name stringByAppendingString:@" static"])];
}

static NSDictionary *SZFIdentityEntry(NSString *name) {
    SZFriendsIdentity *identity = SZFVectorIdentity(name);
    return @{
        @"name" : name,
        @"signing_seed" : SZFHexString(SZFDerive([name stringByAppendingString:@" seed"], 32)),
        @"static_private" : SZFHexString(identity.staticPrivateKey),
        @"public_key" : SZFHexString(identity.publicKey),
        @"static_public" : SZFHexString(identity.staticPublicKey),
        @"static_certificate" : SZFHexString(identity.staticCertificate),
        @"identity_hash" : SZFHexString(identity.identityHash),
        @"secret_item" : SZFHexString([identity secretItem]),
    };
}

static NSDictionary *SZFExportIdentity(void) {
    NSMutableArray *signatures = [NSMutableArray array];
    SZFriendsIdentity *alice = SZFVectorIdentity(@"alice");
    for (NSString *domain in SZFriendsSignatureDomains()) {
        NSData *message = SZFDerive([@"message for " stringByAppendingString:domain], 40);
        [signatures addObject:@{
            @"identity" : @"alice",
            @"domain" : domain,
            @"message" : SZFHexString(message),
            @"signature" : SZFHexString([alice signatureForMessage:message domain:domain]),
        }];
    }
    // REQUEST_BY_ID (ADR 0001 Corrections): signed over h || token || callback secret || static key || Friends ID.
    NSData *h = SZFDerive(@"request-by-id handshake hash", 64);
    NSData *token = SZFDerive(@"request-by-id token", 16);
    NSData *callback = SZFDerive(@"request-by-id callback", 32);
    SZFriendsFrame *request = SZFriendsMakeRequestByIDFrame(alice, @"maple-otter", token, callback, h);
    NSData *requestFrame = SZFriendsEncodeFrame(request, NULL);
    NSData *inviteToken = SZFDerive(@"invite token", 16);
    return @{
        @"identities" : @[ SZFIdentityEntry(@"alice"), SZFIdentityEntry(@"bob"), SZFIdentityEntry(@"carol") ],
        @"signature_domains" : SZFriendsSignatureDomains(),
        @"signatures" : signatures,
        @"request_by_id" : @{
            @"identity" : @"alice",
            @"friends_id" : @"maple-otter",
            @"handshake_hash" : SZFHexString(h),
            @"token" : SZFHexString(token),
            @"callback_secret" : SZFHexString(callback),
            @"frame" : SZFHexString(requestFrame),
            @"verified_identity_key" : SZFHexString(SZFriendsVerifyRequestByIDFrame(request, h)),
        },
        @"invite_proof" : @{
            @"invite_token" : SZFHexString(inviteToken),
            @"handshake_hash" : SZFHexString(h),
            @"proof" : SZFHexString(SZFriendsInviteProof(inviteToken, h)),
        },
    };
}

#pragma mark - Friends IDs

static NSString *SZFFullWidth(NSString *ascii) {
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < ascii.length; i++) {
        unichar c = [ascii characterAtIndex:i];
        unichar wide = (c >= '!' && c <= '~') ? (unichar)(c - '!' + 0xFF01) : c;
        [out appendString:[NSString stringWithCharacters:&wide length:1]];
    }
    return out;
}

static NSDictionary *SZFExportFriendsID(void) {
    SZFriendsWordList *list = [SZFriendsWordList bundledList];
    SZFriendsIDCodec *codec = [[SZFriendsIDCodec alloc] initWithWordList:list];
    NSString *a = [list wordAtIndex:0], *b = [list wordAtIndex:1], *c = [list wordAtIndex:2047];
    NSString *d = [list wordAtIndex:1000];
    NSArray<NSString *> *inputs = @[
        [NSString stringWithFormat:@"%@-%@", a, b],
        [NSString stringWithFormat:@"  %@ %@  ", a.uppercaseString, b.capitalizedString],
        [NSString stringWithFormat:@"%@.%@_%@", a, b, c],
        [NSString stringWithFormat:@"%@—%@", a, b],
        [NSString stringWithFormat:@"%@–%@", a, b],
        [NSString stringWithFormat:@"%@−%@", a, b],
        [NSString stringWithFormat:@"%@。%@", a, b],
        [NSString stringWithFormat:@"%@　%@", a, b],
        [NSString stringWithFormat:@"%@ %@", a, b],
        [NSString stringWithFormat:@"%@\t%@\n", a, b],
        [NSString stringWithFormat:@"%@・%@", a, b],
        [NSString stringWithFormat:@"%@ %@", SZFFullWidth(a), SZFFullWidth(b)],
        [NSString stringWithFormat:@"%@--__..%@", a, b],
        [NSString stringWithFormat:@"%@-%@-%@-%@", a, b, c, d],
        [NSString stringWithFormat:@"%@", a],
        [NSString stringWithFormat:@"%@-notaword", a],
        [NSString stringWithFormat:@"%@-%@!", a, b],
        [NSString stringWithFormat:@"%@+%@", a, b],
        @"",
        @"   ",
        [[@"" stringByPaddingToLength:250 withString:@" " startingAtIndex:0]
            stringByAppendingFormat:@"%@-%@", a, b],
        [[@"" stringByPaddingToLength:240 withString:@" " startingAtIndex:0]
            stringByAppendingFormat:@"%@-%@", a, b],
    ];
    NSMutableArray *normalized = [NSMutableArray array];
    for (NSString *input in inputs) {
        NSString *result = [codec normalizedID:input];
        [normalized addObject:@{@"input" : input, @"normalized" : result ?: [NSNull null]}];
    }
    NSArray<NSArray<NSNumber *> *> *scripts = @[ @[ @0, @1 ], @[ @2047, @5, @9 ], @[ @1000, @1000 ] ];
    NSMutableArray *draws = [NSMutableArray array];
    for (NSArray<NSNumber *> *script in scripts) {
        __block NSUInteger next = 0;
        NSString *drawn = [codec randomIDWithWordCount:script.count
                                             generator:^uint32_t(uint32_t bound) {
                                                 (void)bound;
                                                 return script[next++].unsignedIntValue;
                                             }];
        [draws addObject:@{@"draws" : script, @"id" : drawn}];
    }
    NSMutableArray *wordCounts = [NSMutableArray array];
    for (NSNumber *listWords in @[ @2, @3, @0 ]) {
        for (NSNumber *collisions in @[ @0, @2, @3, @7 ]) {
            [wordCounts addObject:@{
                @"list_new_id_words" : listWords,
                @"collisions_in_a_row" : collisions,
                @"word_count" : @(SZFriendsWordCountForNewID(listWords.integerValue, collisions.unsignedIntegerValue)),
            }];
        }
    }
    return @{
        @"word_list_version" : @(list.version),
        @"word_count" : @(list.count),
        @"word_lines_sha256" : list.wordLinesDigest,
        @"pinned_digest" : SZFriendsWordListV1Digest,
        @"normalized" : normalized,
        @"random_ids" : draws,
        @"word_count_for_new_id" : wordCounts,
    };
}

#pragma mark - Presence, session race, comparison codes

static NSDictionary *SZFExportPresenceRaceCode(void) {
    NSData *secret = SZFDerive(@"presence secret", 32);
    NSMutableArray *tags = [NSMutableArray array];
    for (NSNumber *window in @[ @0, @1, @2177777, @(-1), @(INT64_MAX) ]) {
        [tags addObject:@{
            @"window" : window,
            @"tag" : SZFHexString(SZFriendsPresenceTag(secret, window.longLongValue)),
        }];
    }
    NSMutableArray *windows = [NSMutableArray array];
    for (NSNumber *seconds in @[ @0, @899, @900, @1960000000.5, @(-1) ]) {
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:seconds.doubleValue];
        [windows addObject:@{@"unix_seconds" : seconds, @"window" : @(SZFriendsPresenceWindowIndex(date))}];
    }
    NSData *low = SZFDerive(@"race key low", 32), *high = [SZFDerive(@"race key low", 32) mutableCopy];
    ((uint8_t *)((NSMutableData *)high).mutableBytes)[0] ^= 0x80;
    if (memcmp(low.bytes, high.bytes, 32) > 0) {
        NSData *swap = low;
        low = high;
        high = swap;
    }
    NSData *prefix = [low subdataWithRange:NSMakeRange(0, 16)];
    NSMutableArray *race = [NSMutableArray array];
    NSArray<NSData *> *keys = @[ low, high, prefix ];
    for (NSNumber *routeA in @[ @0, @1, @2, @3, @4, @5, @9 ]) {
        for (NSNumber *routeB in @[ @1, @3, @4, @5 ]) {
            for (NSUInteger ka = 0; ka < keys.count; ka++) {
                for (NSUInteger kb = 0; kb < keys.count; kb++) {
                    BOOL wins = SZFriendsSessionAWins(routeA.integerValue, keys[ka], routeB.integerValue, keys[kb]);
                    [race addObject:@{@"route_a" : routeA, @"key_a" : @(ka), @"route_b" : routeB, @"key_b" : @(kb),
                                      @"a_wins" : @(wins)}];
                }
            }
        }
    }
    NSMutableArray *codes = [NSMutableArray array];
    for (NSString *label in @[ @"one", @"two", @"three" ]) {
        NSData *h = SZFDerive([@"code h " stringByAppendingString:label], 64);
        NSData *na = SZFDerive([@"code initiator nonce " stringByAppendingString:label], 32);
        NSData *nr = SZFDerive([@"code responder nonce " stringByAppendingString:label], 32);
        [codes addObject:@{
            @"handshake_hash" : SZFHexString(h),
            @"initiator_nonce" : SZFHexString(na),
            @"responder_nonce" : SZFHexString(nr),
            @"commitment" : SZFHexString(SZFriendsCodeCommitment(h, nr)),
            @"code" : SZFriendsComparisonCode(h, na, nr),
        }];
    }
    return @{
        @"presence" : @{@"secret" : SZFHexString(secret), @"tags" : tags, @"windows" : windows},
        @"session_race" : @{
            @"keys" : @[ SZFHexString(low), SZFHexString(high), SZFHexString(prefix) ],
            @"cases" : race,
        },
        @"comparison_codes" : codes,
    };
}

static BOOL SZFWrite(NSDictionary *object, NSString *directory, NSString *name) {
    NSMutableDictionary *withSource = [object mutableCopy];
    withSource[@"source"] = @"Exported by portable/friends/core-rs/tools/objc-vectors from the Objective-C helper's "
                            @"own code. Regenerate with `make friends-vectors-export`; do not edit by hand.";
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:withSource
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys |
                                                           NSJSONWritingWithoutEscapingSlashes
                                                     error:&error];
    NSMutableData *file = [json mutableCopy];
    [file appendBytes:"\n" length:1];
    NSString *path = [directory stringByAppendingPathComponent:name];
    if (json == nil || ![file writeToFile:path options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr, "SZFVectorExport: %s: %s\n", path.UTF8String, error.localizedDescription.UTF8String);
        return NO;
    }
    return YES;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        SZFInstallTranscriptRandom(); // before sodium_init, as libsodium requires
        if (argc != 3 || sodium_init() < 0) {
            fprintf(stderr, "usage: SZFVectorExport <output directory> <store v1 fixture>\n");
            return 2;
        }
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        BOOL ok = SZFWrite(SZFExportIdentity(), directory, @"objc-identity.json") &&
                  SZFWrite(SZFExportFriendsID(), directory, @"objc-friends-id.json") &&
                  SZFWrite(SZFExportPresenceRaceCode(), directory, @"objc-presence-race-code.json") &&
                  SZFWrite(SZFExportFrames(), directory, @"objc-frames.json") &&
                  SZFWrite(SZFExportNoise(), directory, @"objc-noise.json") &&
                  SZFWrite(SZFExportCPace(), directory, @"objc-cpace.json") &&
                  SZFWrite(SZFExportEdgeCases(), directory, @"objc-edge-cases.json") &&
                  SZFWrite(SZFExportBluetooth(), directory, @"objc-bluetooth.json") &&
                  SZFWrite(@{@"scenarios" : SZFExportSessionScenarios()}, directory, @"objc-session.json") &&
                  SZFWrite(SZFExportStore([NSString stringWithUTF8String:argv[2]]), directory, @"objc-store.json") &&
                  SZFWrite(SZFExportChain(), directory, @"objc-chain.json") &&
                  SZFWrite(SZFExportSync(), directory, @"objc-sync.json");
        return ok ? 0 : 1;
    }
}
