// ID attestations (HOST-PROTOCOL.md § ID attestations): the shared vectors' verdicts, the edges of the check, and the
// check-in client keeping the newest attestation a host gives it, across launches, for the helper to show when it
// answers an Add by ID. Before attestations nothing tied a Friends ID to a key and every one of these failed (the
// API did not exist, so the suite did not build). No network; the live host is in SZFriendsHostServerTests.m.

#import "SZFriendsHostHarness.h"
#import "SZFriendsHostTestSupport.h"

#import <sodium.h>

NSDictionary *SZFHAttestation(SZFHSigner *host, NSString *hostID, NSString *friendsID, NSData *identityKey,
                              NSString *day) {
    NSMutableData *bytes = [[SZFriendsHostAttestationDomain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [bytes appendData:SZFriendsHostAttestationMessage(hostID, friendsID, identityKey, day)];
    return @{
        @"host_id" : hostID,
        @"friends_id" : friendsID,
        @"identity_key" : SZFriendsHostBase64URLEncode(identityKey),
        @"day" : day,
        @"sig" : SZFriendsHostBase64URLEncode([host signatureOver:bytes]),
    };
}

NSString *SZFHUTCDay(NSDate *date) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyy-MM-dd";
    return [formatter stringFromDate:date];
}

static NSString *SZFHVerdictName(SZFriendsHostAttestationVerdict verdict) {
    NSArray *names = @[ @"valid", @"malformed", @"unknown_host", @"bad_signature", @"wrong_holder", @"expired" ];
    return verdict >= 0 && (NSUInteger)verdict < names.count ? names[verdict] : @"?";
}

static void SZFHTestAttestationVectors(void) {
    NSDictionary *vectors = SZFHVectors()[@"attestations"];
    NSMutableArray<NSData *> *pinned = [NSMutableArray array];
    for (NSString *key in SZFHVectors()[@"pinned"]) [pinned addObject:SZFriendsHostBase64URLDecode(key, 32)];
    NSData *envelope = [NSJSONSerialization dataWithJSONObject:vectors[@"list"] ?: @{} options:0 error:NULL];
    SZFriendsHostList *list = [SZFriendsHostList listFromSignedData:envelope pinnedKeys:pinned error:NULL];
    SZFHExpect(list != nil, @"the attestation vectors' list does not verify");
    NSDate *now = [[[NSISO8601DateFormatter alloc] init] dateFromString:vectors[@"now"] ?: @""];
    NSArray *cases = vectors[@"cases"];
    SZFHExpect(cases.count >= 10 && now != nil, @"too few attestation vectors");
    for (NSDictionary *vector in cases) {
        NSDictionary *wire = vector[@"attestation"];
        SZFriendsHostAttestation *attestation = [SZFriendsHostAttestation attestationFromDictionary:wire];
        NSData *claimedKey = SZFriendsHostBase64URLDecode(vector[@"claim"][@"identity_key"], 32);
        SZFriendsHostAttestationVerdict verdict =
            SZFriendsHostAttestationCheck(attestation, list, vector[@"claim"][@"friends_id"], claimedKey, now);
        SZFHExpect([SZFHVerdictName(verdict) isEqualToString:vector[@"verdict"]], @"%@: %@, the host says %@",
                   vector[@"name"], SZFHVerdictName(verdict), vector[@"verdict"]);
        if (vector[@"signed_bytes_hex"]) {
            NSMutableData *bytes =
                [[SZFriendsHostAttestationDomain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
            [bytes appendData:SZFriendsHostAttestationMessage(attestation.hostID, attestation.friendsID,
                                                              attestation.identityKey, attestation.day)];
            SZFHExpect([SZFHHexString(bytes) isEqualToString:vector[@"signed_bytes_hex"]], @"%@: signed bytes differ",
                       vector[@"name"]);
        }
        if (attestation) {
            SZFriendsHostAttestation *back = [SZFriendsHostAttestation attestationFromData:attestation.encodedData];
            SZFHExpect([back.dictionary isEqualToDictionary:wire], @"%@: round trip", vector[@"name"]);
        }
    }
}

static void SZFHTestAttestationEdges(void) {
    SZFHHarness *h = SZFHMakeHarness();
    NSData *key = h.identity.publicKey;
    NSDate *now = [NSDate date];
    SZFriendsHostList *list = h.cache.currentList;
    SZFriendsHostAttestation * (^make)(SZFHSigner *, NSString *, NSString *, NSDate *) =
        ^SZFriendsHostAttestation *(SZFHSigner *signer, NSString *hostID, NSString *friendsID, NSDate *day) {
            return [SZFriendsHostAttestation
                attestationFromDictionary:SZFHAttestation(signer, hostID, friendsID, key, SZFHUTCDay(day))];
        };
    NSDate *day = [now dateByAddingTimeInterval:-30 * 86400];
    SZFHExpect(SZFriendsHostAttestationCheck(make(h.mainHost, @"main-hk", @"maple-river", day), list, @"maple-river",
                                             key, now) == SZFriendsHostAttestationValid,
               @"thirty days old is still good");
    day = [now dateByAddingTimeInterval:-31 * 86400];
    SZFHExpect(SZFriendsHostAttestationCheck(make(h.mainHost, @"main-hk", @"maple-river", day), list, @"maple-river",
                                             key, now) == SZFriendsHostAttestationExpired,
               @"thirty-one days old has lapsed");
    day = [now dateByAddingTimeInterval:2 * 86400];
    SZFHExpect(SZFriendsHostAttestationCheck(make(h.mainHost, @"main-hk", @"maple-river", day), list, @"maple-river",
                                             key, now) == SZFriendsHostAttestationExpired,
               @"dated two days ahead");
    SZFHExpect(SZFriendsHostAttestationCheck(make(h.altHost, @"alt-sg", @"maple-river", now), list, @"maple-river",
                                             key, now) == SZFriendsHostAttestationValid,
               @"a replica attests with its own key");
    SZFHExpect(SZFriendsHostAttestationCheck(make(h.mainHost, @"relay-only", @"maple-river", now), list,
                                             @"maple-river", key, now) == SZFriendsHostAttestationUnknownHost,
               @"a relay never checks anyone in, so it cannot attest");
    SZFHExpect(SZFriendsHostAttestationCheck(make(h.mainHost, @"main-hk", @"maple-river", now), list, @"maple-river",
                                             [NSData data], now) == SZFriendsHostAttestationWrongHolder,
               @"a claimed key of the wrong length");
    SZFHExpect(SZFriendsHostAttestationCheck(nil, list, @"maple-river", key, now) == SZFriendsHostAttestationMalformed,
               @"nil");
    NSMutableDictionary *wire = [SZFHAttestation(h.mainHost, @"main-hk", @"maple-river", key, SZFHUTCDay(now))
        mutableCopy];
    for (NSArray *change in @[
             @[ @"friends_id", @"maple-river\n" ], @[ @"friends_id", @"Maple-River" ], @[ @"day", @"2026-02-30" ],
             @[ @"day", @"2026-10-12\n" ], @[ @"host_id", @"Main-HK" ], @[ @"identity_key", @"AAAA" ],
             @[ @"sig", @42 ]
         ]) {
        NSMutableDictionary *bad = [wire mutableCopy];
        bad[change[0]] = change[1];
        SZFHExpect([SZFriendsHostAttestation attestationFromDictionary:bad] == nil, @"accepted %@ = %@", change[0],
                   change[1]);
    }
    SZFHExpect([SZFriendsHostAttestation attestationFromDictionary:@[ wire ]] == nil, @"an array");
    NSMutableData *huge = [[SZFriendsHostAttestation attestationFromDictionary:wire].encodedData mutableCopy];
    [huge appendData:[NSMutableData dataWithLength:1024]];
    SZFHExpect([SZFriendsHostAttestation attestationFromData:huge] == nil, @"more than 1 KiB");
}

static NSString *SZFHAttestationPath(SZFHHarness *h) {
    NSString *dir = h.cache.cachePath.stringByDeletingLastPathComponent;
    return [dir stringByAppendingPathComponent:@"host-attestation.json"];
}

// A client over the same cache that never connected: what the next launch would see.
static SZFriendsCheckInClient *SZFHNextLaunch(SZFHHarness *h, SZFHTestIdentity *identity) {
    return [[SZFriendsCheckInClient alloc] initWithListCache:h.cache
                                                    identity:identity.asIdentity
                                                  appVersion:@"26.10.12-1"
                                               socketFactory:^id<SZFriendsHostSocket>(NSURL *url) {
                                                   return [[SZFHFakeSocket alloc] initWithURL:url];
                                               }
                                                       queue:h.queue];
}

static void SZFHTestClientKeepsAttestation(void) {
    SZFHHarness *h = SZFHMakeHarness();
    SZFHStart(h);
    SZFHFakeSocket *socket = SZFHSocket(h, 0);
    SZFHChallenge(h, socket, @"main-hk");
    NSString *today = SZFHUTCDay([NSDate date]);
    NSDictionary *attestation = SZFHAttestation(h.mainHost, @"main-hk", @"maple-river", h.identity.publicKey, today);
    SZFHWelcome(h, socket,
                @{@"reservation" : @"reserved", @"friends_id" : @"maple-river", @"attestation" : attestation});
    SZFHExpect([h.recorder saw:@"attestation maple-river main-hk"], @"no attestation callback: %@", h.recorder.events);
    SZFHExpect([[h.client attestationForFriendsID:@"maple-river"].dictionary isEqualToDictionary:attestation],
               @"the attestation was not kept");
    SZFHExpect([h.client attestationForFriendsID:@"maple-lake"] == nil, @"shown for another ID");
    NSString *path = SZFHAttestationPath(h);
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    SZFHExpect(attributes != nil && (attributes.filePosixPermissions & 0777) == 0600, @"not kept beside the cache");
    SZFHExpect([SZFHNextLaunch(h, h.identity) attestationForFriendsID:@"maple-river"] != nil,
               @"the next launch does not find it");
    SZFHExpect([SZFHNextLaunch(h, [SZFHTestIdentity randomIdentity]) attestationForFriendsID:@"maple-river"] == nil,
               @"another identity was handed this identity's attestation");
    SZFriendsCheckInClient *memoryOnly = SZFHNextLaunch(h, h.identity);
    memoryOnly.attestationPath = nil;
    SZFHExpect([memoryOnly attestationForFriendsID:@"maple-river"] == nil, @"read without a path");

    // Reset Friends forgets it, whatever the host answers.
    [h.client releaseIdentityWithCompletion:^(__unused BOOL released){
    }];
    SZFHDrain(h.queue);
    SZFHExpect([h.client attestationForFriendsID:@"maple-river"] == nil, @"shown after a release");
    SZFHExpect(![[NSFileManager defaultManager] fileExistsAtPath:path], @"left on disk after a release");
    [h.client stop];
}

static void SZFHTestAttestationAfterRename(void) {
    SZFHHarness *h = SZFHMakeHarness();
    SZFHStart(h);
    SZFHFakeSocket *socket = SZFHSocket(h, 0);
    SZFHChallenge(h, socket, @"main-hk");
    SZFHWelcome(h, socket, @{@"reservation" : @"taken", @"friends_id" : [NSNull null], @"attestation" : [NSNull null]});
    NSString *renamed = SZFHDrawID(1);
    NSDictionary *attestation =
        SZFHAttestation(h.mainHost, @"main-hk", renamed, h.identity.publicKey, SZFHUTCDay([NSDate date]));
    SZFHReply(h, socket, @{@"type" : @"reserve_result", @"reservation" : @"reserved", @"friends_id" : renamed,
                           @"attestation" : attestation});
    SZFHExpect([h.client attestationForFriendsID:renamed] != nil, @"no attestation for the new ID: %@",
               h.recorder.events);
    [h.client stop];
}

// Attestations a forger could slip into a believed reservation, or into one the client does not believe.
static void SZFHTestForgedAttestationsAreNotKept(void) {
    NSString *today = SZFHUTCDay([NSDate date]);
    for (int forgery = 0; forgery < 4; forgery++) {
        SZFHHarness *h = SZFHMakeHarness();
        SZFHStart(h);
        SZFHFakeSocket *socket = SZFHSocket(h, 0);
        SZFHChallenge(h, socket, @"main-hk");
        NSData *key = forgery == 1 ? [SZFHTestIdentity randomIdentity].publicKey : h.identity.publicKey;
        NSDictionary *attestation =
            SZFHAttestation(forgery == 0 ? h.altHost : h.mainHost, @"main-hk",
                            forgery == 2 ? @"otter-tulip" : @"maple-river", key, today);
        NSDictionary *welcome = @{@"type" : @"welcome", @"reservation" : @"reserved", @"friends_id" : @"maple-river",
                                  @"update_required" : @NO, @"attestation" : attestation};
        if (forgery == 3) {
            [socket deliver:welcome]; // unsigned, so neither the reservation nor its attestation is believed
            SZFHDrain(h.queue);
        } else {
            SZFHReply(h, socket, welcome);
        }
        SZFHExpect([h.client attestationForFriendsID:@"maple-river"] == nil &&
                       ![[NSFileManager defaultManager] fileExistsAtPath:SZFHAttestationPath(h)],
                   @"forgery %d was kept", forgery);
        [h.client stop];
    }
}

void SZFHRunAttestationTests(void) {
    SZFHTestAttestationVectors();
    SZFHTestAttestationEdges();
    SZFHTestClientKeepsAttestation();
    SZFHTestAttestationAfterRename();
    SZFHTestForgedAttestationsAreNotKept();
}
