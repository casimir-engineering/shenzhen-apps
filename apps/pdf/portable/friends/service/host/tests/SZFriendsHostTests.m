// The host area's suite: encodings and the shared interop vectors, host-list verification, the cache's floor and
// rollback rules, the check-in state machine with a scripted socket, the real client against the Node host service
// on loopback, then protocol 2 (online Friends) scripted and against the service with FRIENDS_M2 on. Prints
// "SZFriendsHostTests passed" and exits 0 when everything holds.
//
// Environment (set by host.mk): SZFRIENDS_HOST_VECTORS, SZFRIENDS_HOST_RESOURCES, SZFRIENDS_HOST_SERVER_DIR.

#import "SZFriendsHostOnlineTests.h"
#import "SZFriendsHostTestSupport.h"

#import <sodium.h>

#pragma mark - Encodings and vectors

void SZFHRunCodecTests(void) {
    SZFHExpect([SZFriendsHostBase64URLDecode(@"AA", 0) isEqualToData:[NSData dataWithBytes:"\0" length:1]], @"AA");
    for (NSString *bad in @[ @"AB", @"AA==", @"A", @"+/8", @"AA ", @"AA\n" ]) {
        SZFHExpect(SZFriendsHostBase64URLDecode(bad, 0) == nil, @"accepted non-canonical base64url %@", bad);
    }
    SZFHExpect(SZFriendsHostBase64URLDecode(@"AAAA", 2) == nil, @"length not enforced");
    SZFHExpect(SZFriendsHostBase64URLDecode(@42, 0) == nil, @"non-string accepted");

    NSDictionary *vectors = SZFHVectors();
    SZFHExpect(vectors != nil, @"no vectors at SZFRIENDS_HOST_VECTORS");
    NSDictionary *checkin = vectors[@"checkin"];
    NSDictionary *release = vectors[@"release"];
    SZFHTestIdentity *identity = [SZFHTestIdentity identityWithSeed:SZFHHex(vectors[@"keys"][@"identity"][@"seed"])];
    SZFHExpect([SZFriendsHostBase64URLEncode(identity.publicKey) isEqualToString:checkin[@"identity_key"]],
               @"identity seed gives another key than node's");
    NSData *challenge = SZFriendsHostBase64URLDecode(checkin[@"challenge"], 32);
    NSData *message = SZFriendsHostCheckinMessage(checkin[@"host_id"], challenge, identity.publicKey,
                                                  checkin[@"friends_id"], [checkin[@"reserved"] boolValue],
                                                  checkin[@"app_version"], [checkin[@"protocol"] integerValue],
                                                  [checkin[@"list_version"] integerValue], nil, nil);
    NSMutableData *signedBytes = [[SZFriendsHostCheckinDomain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [signedBytes appendData:message];
    SZFHExpect([SZFHHexString(signedBytes) isEqualToString:checkin[@"signed_bytes_hex"]],
               @"check-in bytes differ from the host's");
    NSData *signature = [identity signatureForMessage:message domain:SZFriendsHostCheckinDomain];
    SZFHExpect([SZFriendsHostBase64URLEncode(signature) isEqualToString:checkin[@"sig"]],
               @"check-in signature differs");

    NSData *releaseMessage = SZFriendsHostReleaseMessage(release[@"host_id"], challenge, identity.publicKey,
                                                         release[@"friends_id"]);
    NSMutableData *releaseBytes = [[SZFriendsHostReleaseDomain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [releaseBytes appendData:releaseMessage];
    SZFHExpect([SZFHHexString(releaseBytes) isEqualToString:release[@"signed_bytes_hex"]], @"release bytes differ");
    SZFHExpect([SZFriendsHostBase64URLEncode([identity signatureForMessage:releaseMessage
                                                                    domain:SZFriendsHostReleaseDomain])
                   isEqualToString:release[@"sig"]],
               @"release signature differs");

    NSDictionary *urls = @{
        @"wss://friends.example.test/v1" : @YES, @"ws://127.0.0.1:9/v1" : @YES, @"ws://[::1]:9/v1" : @YES,
        @"ws://localhost:9/v1" : @YES, @"ws://friends.example.test/v1" : @NO, @"https://friends.example.test/v1" : @NO,
        @"wss://user@friends.example.test/v1" : @NO, @"wss://friends.example.test/v1#x" : @NO
    };
    for (NSString *url in urls) {
        SZFHExpect(SZFriendsHostURLAllowed([NSURL URLWithString:url]) == [urls[url] boolValue], @"URL rule: %@", url);
    }
    SZFHExpect(SZFriendsHostEncodeMessage(@"x", @{@"pad" : [@"" stringByPaddingToLength:70000
                                                                              withString:@"a"
                                                                         startingAtIndex:0]}) == nil,
               @"oversized message encoded");
    SZFHExpect(SZFriendsHostDecodeMessage([@"[1]" dataUsingEncoding:NSUTF8StringEncoding]) == nil, @"array decoded");
    // 3: a device checks in for its person (HOST-PROTOCOL.md § Devices); the host's HOST_PROTOCOL_VERSION agrees.
    SZFHExpect(SZFriendsHostProtocolVersion == 3, @"protocol version moved without the host document");
}

#pragma mark - Host lists

static NSArray<NSData *> *SZFHPinnedVectorKeys(void) {
    NSMutableArray *keys = [NSMutableArray array];
    for (NSString *key in SZFHVectors()[@"pinned"]) [keys addObject:SZFriendsHostBase64URLDecode(key, 32)];
    return keys;
}

void SZFHRunListTests(void) {
    NSArray<NSData *> *pinned = SZFHPinnedVectorKeys();
    NSArray *vectors = SZFHVectors()[@"host_lists"];
    SZFHExpect(vectors.count >= 10, @"too few host-list vectors");
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    for (NSDictionary *vector in vectors) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:vector[@"envelope"] options:0 error:NULL];
        NSError *error = nil;
        SZFriendsHostList *list = [SZFriendsHostList listFromSignedData:data pinnedKeys:pinned error:&error];
        BOOL valid = [vector[@"valid"] boolValue];
        SZFHExpect((list != nil) == valid, @"%@: expected %@ (%@)", vector[@"name"], valid ? @"valid" : @"refused",
                   error.localizedDescription);
        if (!list || !valid) continue;
        NSDictionary *expected = vector[@"expected"];
        SZFHExpect(list.version == [expected[@"version"] integerValue], @"%@: version", vector[@"name"]);
        SZFHExpect(list.newIDWords == [expected[@"new_id_words"] integerValue], @"%@: words", vector[@"name"]);
        SZFHExpect([list.issuedAt isEqualToDate:[formatter dateFromString:expected[@"issued_at"]]], @"issued_at");
        SZFHExpect([list.signedData isEqualToData:data], @"signed bytes not kept");
        NSArray *hosts = expected[@"hosts"];
        SZFHExpect(list.entries.count == hosts.count, @"%@: host count", vector[@"name"]);
        for (NSUInteger i = 0; i < MIN(hosts.count, list.entries.count); i++) {
            SZFriendsHostEntry *entry = list.entries[i];
            NSDictionary *host = hosts[i];
            NSDictionary *roles = @{@"rendezvous" : @1, @"relay" : @2, @"both" : @3};
            SZFHExpect([entry.hostID isEqualToString:host[@"id"]], @"host %lu id", (unsigned long)i);
            SZFHExpect(entry.roles == [roles[host[@"role"]] unsignedIntegerValue], @"host %lu roles", (unsigned long)i);
            SZFHExpect(entry.priority == [host[@"priority"] integerValue], @"host %lu priority", (unsigned long)i);
            SZFHExpect([entry.region isEqualToString:host[@"region"]], @"host %lu region", (unsigned long)i);
            SZFHExpect([[entry.urls valueForKey:@"absoluteString"] isEqualToArray:host[@"urls"]], @"host urls");
            SZFHExpect([SZFriendsHostBase64URLEncode(entry.publicKey) isEqualToString:host[@"public_key"]],
                       @"host %lu key", (unsigned long)i);
        }
    }

    // The pinned-keys file and bundled list the helper ships: the production primary and backup keys (TEST keys
    // would make friends-host-release-check fail), and a list that verifies with them.
    NSString *resources = SZFHEnv(@"SZFRIENDS_HOST_RESOURCES");
    BOOL testKeys = NO;
    NSError *error = nil;
    NSArray<NSData *> *keys = SZFriendsHostPinnedKeysFromData(
        [NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:@"pinned-keys.json"]] ?: [NSData data],
        &testKeys, &error);
    SZFHExpect(keys.count == 2 && !testKeys,
               @"the committed pinned keys should be the two production keys (%@)", error);
    NSString *bootstrapPath = [resources stringByAppendingPathComponent:@"bootstrap-hosts.json"];
    NSData *bootstrap = [NSData dataWithContentsOfFile:bootstrapPath];
    SZFriendsHostList *bundled = [SZFriendsHostList listFromSignedData:bootstrap ?: [NSData data]
                                                            pinnedKeys:keys ?: @[]
                                                                 error:&error];
    SZFHExpect(bundled != nil, @"the bundled list does not verify with the pinned keys: %@", error);
    SZFHExpect([bundled.entries.firstObject.urls.firstObject.absoluteString
                   isEqualToString:@"wss://friends.meerkat.orgabots.com/v1"],
               @"the bundled list should name the production host");
    NSData *production = [@"{\"keys\":[{\"name\":\"primary\","
                          @"\"public_key\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"test\":false}]}"
        dataUsingEncoding:NSUTF8StringEncoding];
    SZFHExpect(SZFriendsHostPinnedKeysFromData(production, &testKeys, NULL).count == 1 && !testKeys,
               @"an explicit test:false key counted as a test key");
    NSData *unflagged = [@"{\"keys\":[{\"public_key\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}]}"
        dataUsingEncoding:NSUTF8StringEncoding];
    SZFHExpect(SZFriendsHostPinnedKeysFromData(unflagged, &testKeys, NULL) && testKeys,
               @"an unflagged key must count as a test key");
    SZFHExpect(SZFriendsHostPinnedKeysFromData([@"{}" dataUsingEncoding:NSUTF8StringEncoding], NULL, NULL) == nil,
               @"empty pinned-keys file accepted");
}

#pragma mark - Cache

static NSData *SZFHList(SZFHSigner *signer, NSInteger version, NSString *region) {
    NSMutableDictionary *payload = [SZFHPayload(version, @[ @{@"id" : @"main-hk", @"url" : @"wss://h.example.test/v1",
                                                              @"priority" : @1} ]) mutableCopy];
    if (region) payload[@"new_id_words"] = @3;
    return [signer envelopeForPayload:payload];
}

void SZFHRunCacheTests(void) {
    SZFHSigner *primary = [SZFHSigner randomSigner];
    SZFHSigner *backup = [SZFHSigner randomSigner];
    SZFHSigner *stranger = [SZFHSigner randomSigner];
    NSArray<NSData *> *pinned = @[ primary.publicKey, backup.publicKey ];
    NSString *dir = SZFHTempDir();
    NSString *path = [dir stringByAppendingPathComponent:@"hosts.json"];
    NSData *bootstrap = SZFHList(primary, 2, nil);
    NSFileManager *files = [NSFileManager defaultManager];

    SZFriendsHostListCache *cache = [[SZFriendsHostListCache alloc] initWithCachePath:path
                                                                        bootstrapData:bootstrap
                                                                           pinnedKeys:pinned];
    SZFHExpect(cache.currentList.version == 2, @"no cache: the bundled list");
    SZFHExpect([[NSData dataWithContentsOfFile:path] isEqualToData:bootstrap], @"the bundled list was not cached");
    SZFHExpect(([[files attributesOfItemAtPath:path error:NULL] filePosixPermissions] & 0777) == 0600, @"cache mode");

    struct {
        NSData *cached;
        NSInteger expected;
        const char *name;
    } loads[] = {
        {SZFHList(primary, 3, nil), 3, "a newer cache wins"},
        {SZFHList(backup, 4, nil), 4, "a cache signed by the backup key wins"},
        {SZFHList(primary, 1, nil), 2, "an older cache is replaced by the bundled floor"},
        {SZFHList(primary, 2, @"other"), 2, "the bundled version with other contents loses to the bundled list"},
        {SZFHList(stranger, 9, nil), 2, "a cache signed by a dropped key is discarded"},
        {[@"{corrupt" dataUsingEncoding:NSUTF8StringEncoding], 2, "a corrupt cache is discarded"},
    };
    for (size_t i = 0; i < sizeof loads / sizeof loads[0]; i++) {
        [loads[i].cached writeToFile:path atomically:YES];
        SZFriendsHostListCache *loaded = [[SZFriendsHostListCache alloc] initWithCachePath:path
                                                                             bootstrapData:bootstrap
                                                                                pinnedKeys:pinned];
        SZFHExpect(loaded.currentList.version == loads[i].expected, @"%s: got v%ld", loads[i].name,
                   (long)loaded.currentList.version);
    }

    [files removeItemAtPath:path error:NULL];
    cache = [[SZFriendsHostListCache alloc] initWithCachePath:path bootstrapData:bootstrap pinnedKeys:pinned];
    NSError *error = nil;
    NSData *v3 = SZFHList(primary, 3, nil);
    SZFHExpect([cache offerSignedList:v3 error:&error] && cache.currentList.version == 3, @"newer list refused");
    SZFHExpect([[NSData dataWithContentsOfFile:path] isEqualToData:v3], @"newer list not written");
    SZFHExpect(![cache offerSignedList:v3 error:&error] && error.code == SZFriendsHostErrorAlreadyCurrent, @"same");
    SZFHExpect(![cache offerSignedList:SZFHList(primary, 3, @"other") error:&error] &&
                   error.code == SZFriendsHostErrorSubstituted,
               @"equal version with other bytes accepted");
    SZFHExpect(![cache offerSignedList:SZFHList(primary, 2, nil) error:&error] && error.code == SZFriendsHostErrorStale,
               @"rollback accepted");
    SZFHExpect(![cache offerSignedList:SZFHList(stranger, 5, nil) error:&error] &&
                   error.code == SZFriendsHostErrorBadSignature,
               @"unpinned signer accepted");
    SZFHExpect([cache offerSignedList:SZFHList(backup, 5, nil) error:&error], @"backup-signed list refused");
    SZFHExpect(cache.currentList.version == 5, @"backup-signed list not current");

    SZFriendsHostListCache *broken = [[SZFriendsHostListCache alloc]
        initWithCachePath:[dir stringByAppendingPathComponent:@"none.json"]
            bootstrapData:SZFHList(stranger, 2, nil)
               pinnedKeys:pinned];
    SZFHExpect(broken.currentList.version == 0 && broken.currentList.entries.count == 0,
               @"an unverifiable bundled list must leave nothing to connect to");
    [files removeItemAtPath:dir error:NULL];
}

// Every directory the suite made is gone once it ends: before, each run left 33 behind in TMPDIR (a harness's list
// cache, each live client's, the host service's data). Scans TMPDIR itself rather than trusting the bookkeeping.
static void SZFHTestNoTempDirsLeft(void) {
    SZFHRemoveTempDirs();
    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSTemporaryDirectory()
                                                                                       error:NULL];
    NSPredicate *ours = [NSPredicate predicateWithFormat:@"SELF BEGINSWITH %@", SZFHTempDirPrefix()];
    NSArray<NSString *> *left = [entries filteredArrayUsingPredicate:ours];
    SZFHExpect(left.count == 0, @"%lu temporary directories left behind: %@", (unsigned long)left.count, left);
}

int main(void) {
    @autoreleasepool {
        if (sodium_init() < 0) {
            fprintf(stderr, "sodium_init failed\n");
            return 1;
        }
        // Nothing here may hang the build: every wait is bounded, and this is the backstop.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{
            fprintf(stderr, "SZFriendsHostTests: timed out\n");
            _exit(2);
        });
        SZFHRunCodecTests();
        SZFHRunListTests();
        SZFHRunCacheTests();
        SZFHRunClientTests();
        SZFHRunReplyTests();
        SZFHRunAttestationTests();
        SZFHRunServerTests();
        SZFHRunDevicesTests();
        SZFHRunOnlineTests();
        SZFHRunOnlineServerTests();
        SZFHTestNoTempDirsLeft();
        if (SZFHFailures > 0) {
            fprintf(stderr, "SZFriendsHostTests: %d failure(s)\n", SZFHFailures);
            return 1;
        }
        printf("SZFriendsHostTests passed\n");
        return 0;
    }
}
