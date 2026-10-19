// friends-helper-check, orchestration part: the pure decisions and glue around nearby and the host check-in, tested
// without radios, sockets or a host. The flows themselves (requests, delivery, transfers, resume) run between two
// real helpers in friends-e2e-check. Shared pieces and the other test files: SZFriendsHelperNearbyTests.h.

#import "SZFriendsHelperNearbyTests.h"

#import <sodium.h>

#import "service/helper/SZFriendsHelperFacts.h"
#import "service/helper/SZFriendsHelperTesting.h"
#import "service/helper/SZFriendsHostCheckIn.h"
#import "service/helper/nearby/SZFriendsPeerLink.h"
#import "service/identity/SZFriendsIdentity.h"

int SZFNFailures = 0;

static NSString *SZFNBase64URL(NSData *data) {
    NSString *text = [data base64EncodedStringWithOptions:0];
    text = [text stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    text = [text stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [text stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

// A signed host list naming `url`, and the pinned-keys file it verifies with (ADR 0005 envelope).
void SZFNMakeList(NSString *url, NSData **list, NSData **keys) {
    unsigned char pk[crypto_sign_PUBLICKEYBYTES], sk[crypto_sign_SECRETKEYBYTES], hostKey[32];
    crypto_sign_keypair(pk, sk);
    randombytes_buf(hostKey, sizeof hostKey);
    NSDictionary *payload = @{
        @"version" : @3, @"issued_at" : @"2026-10-12T00:00:00Z", @"new_id_words" : @2,
        @"hosts" : @[ @{@"id" : @"main-hk", @"role" : @"rendezvous", @"urls" : @[ url ], @"turn_uris" : @[],
                        @"region" : @"Test", @"priority" : @1,
                        @"public_key" : SZFNBase64URL([NSData dataWithBytes:hostKey length:32])} ]
    };
    NSData *payloadBytes = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    NSMutableData *signedBytes = [[@"SZFriends host list v1\n" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [signedBytes appendData:payloadBytes];
    unsigned char signature[crypto_sign_BYTES];
    crypto_sign_detached(signature, NULL, signedBytes.bytes, signedBytes.length, sk);
    NSDictionary *envelope = @{@"payload" : SZFNBase64URL(payloadBytes),
                               @"sigs" : @[ @{@"key" : @"primary",
                                              @"sig" : SZFNBase64URL([NSData dataWithBytes:signature length:64])} ]};
    *list = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:NULL];
    NSDictionary *pinned = @{@"keys" : @[ @{@"name" : @"primary", @"public_key" :
                                                SZFNBase64URL([NSData dataWithBytes:pk length:32]), @"test" : @YES} ]};
    *keys = [NSJSONSerialization dataWithJSONObject:pinned options:0 error:NULL];
}

NSString *SZFNWrite(NSString *directory, NSString *name, NSData *data) {
    NSString *path = [directory stringByAppendingPathComponent:name];
    [data writeToFile:path atomically:YES];
    return path;
}

static void SZFNTestServiceTypes(void) {
    EXPECT(SZFriendsHelperTestServiceTypeIsValid(@"_szfe1234abcd._tcp"));
    EXPECT(SZFriendsHelperTestServiceTypeIsValid(@"_a-b._tcp"));
    EXPECT(!SZFriendsHelperTestServiceTypeIsValid(@"_szfriends._tcp"), "never the production type");
    EXPECT(!SZFriendsHelperTestServiceTypeIsValid(@"_._tcp"));
    EXPECT(!SZFriendsHelperTestServiceTypeIsValid(@"szfe._tcp"));
    EXPECT(!SZFriendsHelperTestServiceTypeIsValid(@"_sixteencharacter._tcp"), "DNS-SD names are 15 at most");
    EXPECT(!SZFriendsHelperTestServiceTypeIsValid(@"_bad name._tcp"));
    EXPECT(!SZFriendsHelperTestServiceTypeIsValid(@"_szfe._udp"));
    EXPECT(!SZFriendsHelperTestServiceTypeIsValid(nil));
}

// Under SZFRIENDS_STATE_DIR no real radio is ever made: nothing without a test type, loopback with one, and the
// harness's extras on top.
static void SZFNTestAdapterSelection(void) {
    dispatch_queue_t queue = dispatch_queue_create("szfn.adapters", DISPATCH_QUEUE_SERIAL);
    NSArray *none = SZFriendsHelperMakeAdapters(queue, @{@"SZFRIENDS_STATE_DIR" : @"/nonexistent"});
    EXPECT(none.count == 0, "%@", none);
    NSArray *bad = SZFriendsHelperMakeAdapters(queue, @{@"SZFRIENDS_STATE_DIR" : @"/x",
                                                        @"SZFRIENDS_TEST_SERVICE_TYPE" : @"_szfriends._tcp"});
    EXPECT(bad.count == 0, "the production type is never browsed from a test helper");
    NSArray *loopback = SZFriendsHelperMakeAdapters(queue, @{@"SZFRIENDS_STATE_DIR" : @"/x",
                                                             @"SZFRIENDS_TEST_SERVICE_TYPE" : @"_szfn1._tcp"});
    EXPECT(loopback.count == 1 && [loopback[0] method] == SZFriendsDiscoveryMethodNetwork, "%@", loopback);
    SZFriendsHelperTestHooks.extraAdapters = ^NSArray<id<SZFriendsDiscoveryAdapter>> *(dispatch_queue_t q) {
        (void)q;
        return @[];
    };
    EXPECT(SZFriendsHelperMakeAdapters(queue, @{@"SZFRIENDS_STATE_DIR" : @"/x"}).count == 0);
    SZFriendsHelperTestHooks.extraAdapters = nil;
}

// Tests and probes never check in, whatever the bundle holds, unless both test variables name a loopback list.
static void SZFNTestCheckInGate(NSString *scratch) {
    NSData *list = nil, *keys = nil, *remoteList = nil, *remoteKeys = nil;
    SZFNMakeList(@"ws://127.0.0.1:9/v1", &list, &keys);
    SZFNMakeList(@"wss://friends.example.org/v1", &remoteList, &remoteKeys);
    NSString *why = nil;
    EXPECT([SZFriendsCheckInSetup setupWithEnvironment:@{} bundledList:nil bundledKeys:nil why:&why] == nil && why);
    SZFriendsCheckInSetup *production = [SZFriendsCheckInSetup setupWithEnvironment:@{} bundledList:remoteList
                                                                        bundledKeys:remoteKeys why:NULL];
    EXPECT(production != nil && !production.loopbackOnly, "production checks in with its bundled list");
    NSDictionary *test = @{@"SZFRIENDS_STATE_DIR" : scratch};
    EXPECT([SZFriendsCheckInSetup setupWithEnvironment:test bundledList:remoteList bundledKeys:remoteKeys
                                                   why:&why] == nil,
           "a bundled list is ignored under SZFRIENDS_STATE_DIR (%@)", why);
    NSMutableDictionary *loopback = [test mutableCopy];
    loopback[@"SZFRIENDS_TEST_HOST_LIST"] = SZFNWrite(scratch, @"list.json", list);
    loopback[@"SZFRIENDS_TEST_HOST_KEYS"] = SZFNWrite(scratch, @"keys.json", keys);
    SZFriendsCheckInSetup *local = [SZFriendsCheckInSetup setupWithEnvironment:loopback bundledList:nil
                                                                   bundledKeys:nil why:&why];
    EXPECT(local != nil && local.loopbackOnly, "a loopback list is allowed (%@)", why);
    NSMutableDictionary *remote = [test mutableCopy];
    remote[@"SZFRIENDS_TEST_HOST_LIST"] = SZFNWrite(scratch, @"remote.json", remoteList);
    remote[@"SZFRIENDS_TEST_HOST_KEYS"] = SZFNWrite(scratch, @"remote-keys.json", remoteKeys);
    EXPECT([SZFriendsCheckInSetup setupWithEnvironment:remote bundledList:nil bundledKeys:nil why:NULL] == nil,
           "a test list naming another machine is refused");
    NSMutableDictionary *mismatched = [loopback mutableCopy];
    mismatched[@"SZFRIENDS_TEST_HOST_KEYS"] = remote[@"SZFRIENDS_TEST_HOST_KEYS"];
    EXPECT([SZFriendsCheckInSetup setupWithEnvironment:mismatched bundledList:nil bundledKeys:nil why:NULL] == nil,
           "a list that does not verify is refused");
    NSArray *pinned = SZFriendsHostPinnedKeysFromData(keys, NULL, NULL);
    SZFriendsHostList *parsed = [SZFriendsHostList listFromSignedData:list pinnedKeys:pinned error:NULL];
    EXPECT(parsed != nil && SZFriendsHostListIsLoopbackOnly(parsed));
}

static void SZFNTestLinkBookkeeping(void) {
    NSString *identifier = @"00112233445566778899aabbccddeeff";
    NSData *bytes = SZFriendsLinkBytesFromHex(identifier);
    EXPECT(bytes.length == 16 && [SZFriendsLinkHex(bytes) isEqualToString:identifier]);
    EXPECT(SZFriendsLinkBytesFromHex(@"00112233445566778899AABBCCDDEEFF") == nil, "only ids this Mac issues");
    EXPECT(SZFriendsLinkBytesFromHex(@"0011") == nil && SZFriendsLinkBytesFromHex(nil) == nil);
    SZFriendsPeerLink *link = [[SZFriendsPeerLink alloc] initWithChannel:(SZFriendsSecureChannel *)[NSObject new]
                                                                 purpose:SZFriendsLinkPurposeFriend
                                                                   route:SZFriendsRouteMethodLAN];
    // An offer and the CANCEL withdrawing it share the transfer id: ACKs answer them in the order they went out.
    [link expectAckForID:identifier token:@"offer-entry"];
    [link expectAckForID:identifier token:@"cancel-entry"];
    [link expectAckForID:@"ffff" token:@"other"];
    EXPECT([[link takeAckForID:identifier] isEqualToString:@"offer-entry"]);
    EXPECT([[link takeAckForID:identifier] isEqualToString:@"cancel-entry"]);
    EXPECT([link takeAckForID:identifier] == nil, "an extra ACK changes nothing");
    EXPECT([[link takeAckForID:@"ffff"] isEqualToString:@"other"]);
}

// The store's ID follows SZFriendsIDStatus through collisions, a reservation, a rename and the update notice.
static void SZFNTestCheckInGlue(NSString *scratch) {
    NSString *state = [scratch stringByAppendingPathComponent:@"state"];
    NSDictionary *env = @{@"SZFRIENDS_STATE_DIR" : state, @"SZFRIENDS_KEY_STORE" : @"file"};
    [[NSFileManager defaultManager] createDirectoryAtPath:state withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions : @0700} error:NULL];
    SZFriendsStatePaths *paths = [[SZFriendsStatePaths alloc] initWithStateDirectory:state];
    SZFriendsHelperServices *services =
        [[SZFriendsHelperServices alloc] initWithPaths:paths environment:env
                                             resources:[SZFriendsHelperResources loadFromBundle:[NSBundle mainBundle]]];
    [services open];
    EXPECT(services.store != nil && services.identity != nil && services.codec != nil, "services open");
    EXPECT(services.checkInSetup == nil, "no check-in without a test host list");
    if (services.store == nil || services.codec == nil) return;
    NSData *list = nil, *keys = nil;
    SZFNMakeList(@"ws://127.0.0.1:9/v1", &list, &keys);
    NSDictionary *loopback = @{@"SZFRIENDS_STATE_DIR" : state,
                               @"SZFRIENDS_TEST_HOST_LIST" : SZFNWrite(scratch, @"glue-list.json", list),
                               @"SZFRIENDS_TEST_HOST_KEYS" : SZFNWrite(scratch, @"glue-keys.json", keys)};
    SZFriendsCheckInSetup *setup = [SZFriendsCheckInSetup setupWithEnvironment:loopback bundledList:nil
                                                                   bundledKeys:nil why:NULL];
    SZFriendsHostListCache *cache = [[SZFriendsHostListCache alloc] initWithCachePath:paths.hostListPath
                                                                        bootstrapData:setup.bootstrapData
                                                                           pinnedKeys:setup.pinnedKeys];
    SZFriendsHelperCheckIn *checkIn = [[SZFriendsHelperCheckIn alloc] initWithServices:services setup:setup cache:cache
                                                                                 queue:dispatch_get_main_queue()];
    SZFriendsStore *store = services.store;
    NSString *original = store.friendsID;
    EXPECT(original.length > 0 && store.friendsIDState == SZFriendsIDStateUnreserved, "usable offline at once");
    EXPECT([[checkIn friendsIDForCollisionsInARow:0] isEqualToString:original], "the current ID first");
    NSString *first = [checkIn friendsIDForCollisionsInARow:1];
    EXPECT(![first isEqualToString:original] && [services.codec normalizedID:first] != nil, "%@", first);
    EXPECT(store.idCollisionsInARow == 1 && [store.friendsID isEqualToString:original],
           "the stored ID stays the known one until another is reserved");
    NSString *second = [checkIn friendsIDForCollisionsInARow:2];
    EXPECT(![second isEqualToString:first] && store.idCollisionsInARow == 2, "never the refused one again");
    [checkIn checkInDidRenameIDFrom:original to:second];
    EXPECT([store.friendsID isEqualToString:second] && store.friendsIDState == SZFriendsIDStateChanged &&
           [store.previousFriendsID isEqualToString:original] && store.idCollisionsInARow == 0,
           "renamed: %@ %ld %@", store.friendsID, (long)store.friendsIDState, store.previousFriendsID);
    [checkIn checkInDidReserveID:second];
    EXPECT(store.friendsIDState == SZFriendsIDStateChanged, "a later check-in keeps the unread notice");
    NSString *recorded = [services drawFriendsID];
    [checkIn checkInDidReserveID:recorded];
    EXPECT([store.friendsID isEqualToString:recorded] && store.friendsIDState == SZFriendsIDStateReserved,
           "the host's record for this key wins, without a notice");
    // Security review (host client): an ID from the host becomes the person's own and appears in the notice they
    // read, so one the word list could not have made is never stored, reserved or as a rename.
    NSString *hostile = [@"Apple Support\u202egnp.exe\n" stringByPaddingToLength:2022 withString:@"x"
                                                                  startingAtIndex:0];
    [checkIn checkInDidReserveID:hostile];
    [checkIn checkInDidRenameIDFrom:recorded to:hostile];
    [checkIn checkInDidReserveID:@"Maple-River"];
    EXPECT([store.friendsID isEqualToString:recorded] && store.friendsIDState == SZFriendsIDStateReserved,
           "a host answer that is not a Friends ID changes nothing: %@", store.friendsID);
    EXPECT(services.updateNeed == SZFriendsUpdateNeedNone);
    [checkIn checkInRequiresUpdate];
    EXPECT(services.updateNeed == SZFriendsUpdateNeedOnline, "online Friends needs an update");

    // An outgoing message with no outbox record says nothing about its delivery (was shown Delivered before).
    SZFriendsItemRecord *record = [[SZFriendsItemRecord alloc] init];
    record.itemID = @"00112233445566778899aabbccddeeff";
    record.kind = SZFriendsItemKindMessage;
    record.direction = SZFriendsDirectionOutgoing;
    record.sentAt = [NSDate date];
    record.outboxState = -1;
    EXPECT(SZFriendsItemFactsFromRecord(record, services).outboxState == -1);
    record.outboxState = SZFriendsOutboxStateFailed;
    record.outboxFailureReason = SZFriendsOutboxFailureNotDelivered30Days;
    EXPECT([SZFriendsItemFactsFromRecord(record, services).failureReason isEqual:@"not_delivered_30_days"]);
    [services close];
}

int main(void) {
    @autoreleasepool {
        if (sodium_init() < 0) return 1;
        char template[1024];
        NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfn.XXXXXX"];
        strlcpy(template, pattern.fileSystemRepresentation, sizeof(template));
        NSString *scratch = mkdtemp(template) ? @(template) : nil;
        if (scratch == nil) return 1;
        SZFNTestServiceTypes();
        SZFNTestAdapterSelection();
        SZFNTestCheckInGate(scratch);
        SZFNTestLinkBookkeeping();
        SZFNTestCheckInGlue(scratch);
        SZFNTestCallbackSecrets(scratch);
        SZFNTestAdmissionLimits(scratch);
        SZFNTestPresenceSecretOnlyToFriends(scratch);
        SZFNTestStrangerPictures(scratch);
        SZFNTestKeyPolicy(scratch);
        SZFNTestFriendsChains(scratch);
        SZFNTestOwnChainToFriends(scratch);
        SZFNTestOwnDeviceSync(scratch);
        SZFNTestFriendDevices(scratch);
        SZFNTestIdleClose(scratch);
        SZFNTestResetOrder(scratch);
        SZFNTestStrangerCap(scratch);
        SZFNTestStrangerFrames(scratch);
        SZFNTestStrangerLifetime(scratch);
        SZFNTestPendingRequestKeys(scratch);
        SZFNTestRequestCodes(scratch);
        SZFNTestRequestExpiry(scratch);
        SZFNTestAnswerAttestationVerdicts(scratch);
        SZFNTestCallbackShowsAttestation(scratch);
        SZFNTestAttestedAnswers(scratch);
        SZFNTestResetForgetsAttestation(scratch);
        SZFNTestUnconfirmedAcceptIsARequest(scratch);
        SZFNTestOutgoingRequestKeys(scratch);
        SZFNTestNNPerAddress(scratch);
        SZFNTestWrittenBeforeSend(scratch);
        SZFNTestDialRank(scratch);
        SZFNTestOnlineDelegate(scratch);
        SZFNTestOnlineReach(scratch);
        SZFNTestByIDOnline(scratch);
        SZFNTestJoin(scratch);
        SZFNTestDevices(scratch);
        SZFNTestFirstContact(scratch);
        SZFNTestLoopbackICE();
        [[NSFileManager defaultManager] removeItemAtPath:scratch error:NULL];
        if (SZFNFailures > 0) {
            fprintf(stderr, "SZFriendsHelperNearbyTests: %d failure(s)\n", SZFNFailures);
            return 1;
        }
        printf("SZFriendsHelperNearbyTests passed\n");
        return 0;
    }
}
