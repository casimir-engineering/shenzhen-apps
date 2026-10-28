// Store suite entry point, and the tests of opening, people, profile, settings and Add by ID requests.
// Usage: SZFriendsStoreTests <fixtures dir> | --write-v1-fixture <path> | --child <mode> <dir> <fd>

#import <signal.h>
#import <sys/stat.h>
#import <unistd.h>

#import "SZFriendsStoreTestSupport.h"

static void TestOpenIsPrivateDurableAndSingleWriter(void) {
    NSString *directory = [SZFTTemporaryDirectory(@"open") stringByAppendingPathComponent:@"deeper/state"];
    SZFriendsStore *store = SZFTOpenStore(directory);
    SZFTExpect(store.schemaVersion == SZFriendsStoreSchemaVersion, @"schema %ld", (long)store.schemaVersion);
    SZFTExpect(SZFTFileMode(directory) == 0700, @"state directory mode %lo", (unsigned long)SZFTFileMode(directory));
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) {
        NSString *path = [store.databasePath stringByAppendingString:suffix];
        SZFTExpect(SZFTFileMode(path) == 0600, @"%@ mode %lo", path.lastPathComponent,
            (unsigned long)SZFTFileMode(path));
    }
    NSDictionary<NSString *, NSNumber *> *pragmas = @{
        @"synchronous" : @2, @"fullfsync" : @1, @"checkpoint_fullfsync" : @1, @"foreign_keys" : @1,
        @"trusted_schema" : @0
    };
    for (NSString *pragma in pragmas) {
        id value = SZFTScalar(store, [@"PRAGMA " stringByAppendingString:pragma], @[]);
        SZFTExpect([value isEqual:pragmas[pragma]], @"PRAGMA %@ = %@", pragma, value);
    }
    SZFTExpect([SZFTScalar(store, @"PRAGMA journal_mode", @[]) isEqual:@"wal"], @"WAL");
    __block NSNumber *queryOnly = nil;
    __block BOOL readerWrote = YES;
    [store performRead:^(SZFriendsStoreDB *db) {
        queryOnly = [db scalar:@"PRAGMA query_only" binds:nil error:NULL];
        readerWrote = [db exec:@"INSERT INTO meta(key, value) VALUES ('x', 'y')" error:NULL];
    }];
    SZFTExpect(queryOnly.intValue == 1 && !readerWrote, @"the read connection must not write");
    SZFTExpect([SZFTScalar(store, @"SELECT value FROM meta WHERE key = 'min_reader_version'", @[]) isEqual:@"2"],
               @"min_reader_version (v2 raised it)");
    SZFTExpect(store.searchUsesIndex == SZFTIndexExpected(), @"system SQLite keeps the trigram index from 3.44 on");
    [store close];
    NSError *error = nil;
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    SZFTExpect(![store savePerson:person error:&error] && error, @"a closed store refuses writes");
    SZFTExpect(store.peopleByLatestInteraction.count == 0, @"a closed store reads nothing");
}

static void TestPeople(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"people"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFTAddPerson(store, @"lena", 3, SZFriendsRelationIncomingRequest, 3000);
    SZFTAddPerson(store, @"priya", 5, SZFriendsRelationFriend, 2000);
    NSArray *order = [store.peopleByLatestInteraction valueForKey:@"conversationID"];
    SZFTExpect([order isEqual:(@[ @"lena", @"priya", @"mei" ])], @"list order %@", order);
    SZFriendsPersonRecord *fresh = [[SZFriendsPersonRecord alloc] init];
    fresh.identityKey = SZFTBytes(9, 32);
    fresh.picture = [SZFriendsPicture animalWithSet:1 index:7];
    fresh.relation = SZFriendsRelationOutgoingRequest;
    fresh.presenceSecret = SZFTBytes(4, 32);
    fresh.callbackToken = SZFTBytes(6, 16);
    SZFTExpect([store savePerson:fresh error:NULL], @"save");
    SZFTExpect(fresh.conversationID.length == 32, @"a new conversation id is written back: %@", fresh.conversationID);
    SZFriendsPersonRecord *read = [store personWithIdentityKey:SZFTBytes(9, 32)];
    SZFTExpect([read.conversationID isEqualToString:fresh.conversationID], @"lookup by key");
    SZFTExpect([read.picture isEqual:[SZFriendsPicture animalWithSet:1 index:7]], @"picture round trip");
    SZFTExpect([read.presenceSecret isEqualToData:SZFTBytes(4, 32)] && [read.callbackToken isEqualToData:SZFTBytes(6,
        16)],
               @"secrets round trip");
    SZFTExpect(!read.autoAccept, @"automatic acceptance is off by default");
    NSError *error = nil;
    SZFriendsPersonRecord *thief = [[SZFriendsPersonRecord alloc] init];
    thief.conversationID = @"thief";
    thief.identityKey = SZFTBytes(1, 32);
    SZFTExpect(![store savePerson:thief error:&error] && error.code == SZFriendsStoreErrorConstraint,
               @"an identity key belongs to one person: %@", error);
    thief.identityKey = SZFTBytes(2, 31);
    SZFTExpect(![store savePerson:thief error:&error] && error.code == SZFriendsStoreErrorInvalid, @"key length");
    thief.identityKey = nil;
    thief.conversationID = @"bad id!";
    SZFTExpect(![store savePerson:thief error:&error] && error.code == SZFriendsStoreErrorInvalid, @"id charset");
}

static void TestSavingAStaleCopyLosesNothing(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"stale"));
    SZFriendsPersonRecord *stale = SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFTExpect([store insertItem:SZFTMessage(@"mei", @"m1", @"hello", 5000, SZFriendsDirectionIncoming) error:NULL],
               @"insert");
    stale.name = @"Mei Lin";
    SZFTExpect([store savePerson:stale error:NULL], @"save stale copy");
    SZFriendsPersonRecord *read = [store personWithConversationID:@"mei"];
    SZFTExpect(read.unreadCount == 1, @"unread kept: %ld", (long)read.unreadCount);
    SZFTExpect(read.lastInteractionAt.timeIntervalSince1970 == 5000, @"interaction kept: %@", read.lastInteractionAt);
    SZFTExpect([read.name isEqualToString:@"Mei Lin"], @"other fields saved");
}

static void TestAutomaticAcceptanceSwitchRules(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"autoaccept"));
    SZFriendsPersonRecord *mei = SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    mei.autoAccept = YES;
    mei.verified = YES;
    [store savePerson:mei error:NULL];
    SZFTExpect([store personWithConversationID:@"mei"].autoAccept, @"switch on");
    mei.relation = SZFriendsRelationBlocked;
    [store savePerson:mei error:NULL];
    SZFTExpect(![store personWithConversationID:@"mei"].autoAccept, @"blocking turns it off");
    mei = [store personWithConversationID:@"mei"];
    mei.relation = SZFriendsRelationFriend;
    [store savePerson:mei error:NULL];
    SZFTExpect(![store personWithConversationID:@"mei"].autoAccept, @"unblocking does not turn it back on");
    mei.autoAccept = YES;
    mei.keyChangePending = YES;
    [store savePerson:mei error:NULL];
    SZFTExpect(![store personWithConversationID:@"mei"].autoAccept, @"a pending key change turns it off");
    mei = [store personWithConversationID:@"mei"];
    mei.keyChangePending = NO;
    mei.autoAccept = YES;
    [store savePerson:mei error:NULL];
    SZFTExpect([store personWithConversationID:@"mei"].autoAccept, @"on again after review");
}

static void TestProfileAndSettings(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"profile"));
    SZFTExpect(!store.profileName && store.profilePicture.kind == SZFriendsPictureKindPlaceholder, @"defaults");
    store.profileName = @"Raph";
    store.profilePicture = [SZFriendsPicture animalWithSet:1 index:3];
    store.friendsID = @"maple-river";
    store.friendsIDState = 2;
    store.previousFriendsID = @"maple-harbor";
    SZFTExpect([store.profileName isEqualToString:@"Raph"], @"name");
    SZFTExpect([store.profilePicture isEqual:[SZFriendsPicture animalWithSet:1 index:3]], @"picture");
    SZFTExpect([store.friendsID isEqualToString:@"maple-river"] && store.friendsIDState == 2, @"ID");
    store.previousFriendsID = nil;
    SZFTExpect(!store.previousFriendsID, @"dismissed notice");
    store.profileName = nil;
    SZFTExpect(!store.profileName, @"name cleared");
    store.idCollisionsInARow = 2;
    store.idCollisionsInARow = 0;
    SZFTExpect(store.idCollisionsInARow == 0, @"below three it resets");
    store.idCollisionsInARow = 3;
    store.idCollisionsInARow = 0;
    SZFTExpect(store.idCollisionsInARow == 3, @"three or more stays (ADR 0006)");
    store.idCollisionsInARow = 4;
    SZFTExpect(store.idCollisionsInARow == 4, @"and still counts up");
    store.nearbyPermissionsRequested = YES;
    store.ownPresenceSecret = SZFTBytes(7, 32);
    SZFTExpect(store.nearbyPermissionsRequested && [store.ownPresenceSecret isEqualToData:SZFTBytes(7, 32)],
        @"settings");
    NSDate *now = [NSDate date];
    store.visibilityDeadline = [now dateByAddingTimeInterval:300];
    store.visibilityDeadline = [now dateByAddingTimeInterval:600];
    SZFTExpect(fabs([store.visibilityDeadline timeIntervalSinceDate:now] - 300) < 0.01,
        @"a running deadline never extends");
    store.visibilityDeadline = [now dateByAddingTimeInterval:100];
    SZFTExpect(fabs([store.visibilityDeadline timeIntervalSinceDate:now] - 100) < 0.01, @"an earlier one applies");
    store.visibilityDeadline = nil;
    SZFTExpect(!store.visibilityDeadline, @"Stop clears it");
    store.visibilityDeadline = [now dateByAddingTimeInterval:-10];
    store.visibilityDeadline = [now dateByAddingTimeInterval:300];
    SZFTExpect(fabs([store.visibilityDeadline timeIntervalSinceDate:now] - 300) < 0.01, @"an expired one is replaced");
    [store close];
    SZFriendsStore *reopened = SZFTOpenStore(store.stateDirectory);
    SZFTExpect([reopened.friendsID isEqualToString:@"maple-river"] && reopened.nearbyPermissionsRequested,
               @"profile and settings survive a restart");
}

static SZFriendsIDRequestRecord *IDRequest(NSString *conversationID, uint8_t token, NSDate *created) {
    SZFriendsIDRequestRecord *request = [[SZFriendsIDRequestRecord alloc] init];
    request.conversationID = conversationID;
    request.targetFriendsID = @"orchid-summit";
    request.requestToken = SZFTBytes(token, 16);
    request.callbackSecret = SZFTBytes((uint8_t)(token + 100), 32);
    request.createdAt = created;
    request.expiresAt = [created dateByAddingTimeInterval:30 * 24 * 3600]; // longer than allowed: clamped
    return request;
}

static void TestIDRequestsAtMostFourForSevenDays(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"idrequests"));
    NSDate *now = [NSDate date];
    for (int i = 0; i < 6; i++) {
        SZFTAddPerson(store, [NSString stringWithFormat:@"r%d", i], (uint8_t)(10 + i), SZFriendsRelationOutgoingRequest,
                      1000);
    }
    for (int i = 0; i < 4; i++) {
        SZFTExpect([store saveIDRequest:IDRequest([NSString stringWithFormat:@"r%d", i], (uint8_t)i, now) error:NULL],
                   @"request %d", i);
    }
    NSError *error = nil;
    SZFTExpect(![store saveIDRequest:IDRequest(@"r4", 4, now) error:&error] &&
                   error.code == SZFriendsStoreErrorConstraint, @"a fifth is refused");
    SZFTExpect([store saveIDRequest:IDRequest(@"r0", 9, now) error:NULL], @"replacing one's own request is fine");
    SZFriendsIDRequestRecord *read = [store idRequestWithToken:SZFTBytes(9, 16)];
    SZFTExpect(fabs([read.expiresAt timeIntervalSinceDate:read.createdAt] - SZFriendsIDRequestLifetime) < 0.01,
               @"expiry clamped to 7 days");
    SZFTExpect(![store idRequestWithToken:SZFTBytes(0, 16)], @"the replaced token admits nobody");
    NSDate *later = [now dateByAddingTimeInterval:SZFriendsIDRequestLifetime + 1];
    SZFTExpect(![store idRequestWithToken:SZFTBytes(9, 16) atDate:later], @"an expired token admits nobody");
    SZFTExpect([store pendingIDRequestsAtDate:later].count == 0, @"none pending after 7 days");
    SZFTExpect([store pendingIDRequestsAtDate:now].count == 4, @"four pending now");
    NSDate *old = [now dateByAddingTimeInterval:-(SZFriendsIDRequestLifetime + 60)];
    SZFriendsStore *second = SZFTOpenStore(SZFTTemporaryDirectory(@"idexpired"));
    for (int i = 0; i < 5; i++) {
        SZFTAddPerson(second, [NSString stringWithFormat:@"r%d", i], (uint8_t)(10 + i),
            SZFriendsRelationOutgoingRequest,
                      1000);
        SZFTExpect([second saveIDRequest:IDRequest([NSString stringWithFormat:@"r%d", i], (uint8_t)i, i < 4 ? old : now)
                                   error:NULL],
                   @"expired requests do not count (%d)", i);
    }
    SZFTExpect([second pendingIDRequestsAtDate:now].count == 1, @"expired ones were dropped");
    SZFriendsIDRequestRecord *bad = IDRequest(@"r5", 1, now);
    bad.requestToken = SZFTBytes(1, 15);
    SZFTExpect(![store saveIDRequest:bad error:&error] && error.code == SZFriendsStoreErrorInvalid, @"token length");
    SZFTExpect(![store saveIDRequest:IDRequest(@"nobody", 77, now) error:&error] &&
                   error.code == SZFriendsStoreErrorNotFound, @"unknown conversation is not a rate limit");
    SZFTExpect([store deleteIDRequestForConversation:@"r1" error:NULL] && [store
        pendingIDRequestsAtDate:now].count == 3,
               @"delete");
}

static void TestIdentifiersAndErrorCodes(void) {
    NSString *a = SZFriendsNewIdentifier(), *b = SZFriendsNewIdentifier();
    SZFTExpect(a.length == 32 && ![a isEqualToString:b] && SZFriendsStoreIsValidIdentifier(a), @"ids %@ %@", a, b);
    NSDictionary<NSNumber *, NSString *> *codes = @{
        @(SZFriendsStoreErrorDiskFull) : @"disk_full", @(SZFriendsStoreErrorFileMissing) : @"file_missing",
        @(SZFriendsStoreErrorFolderNotSupported) : @"folder_not_supported",
        @(SZFriendsStoreErrorSourceChanged) : @"source_changed", @(SZFriendsStoreErrorStale) : @"stale",
        @(SZFriendsStoreErrorNotFound) : @"not_found", @(SZFriendsStoreErrorInvalid) : @"invalid_field",
        @(SZFriendsStoreErrorDatabase) : @"internal"
    };
    for (NSNumber *code in codes) {
        NSError *error = SZFriendsStoreMakeError(code.integerValue, @"x");
        SZFTExpect([SZFriendsStoreProtocolErrorCode(error) isEqualToString:codes[code]], @"code %@", code);
    }
    SZFTExpect([SZFriendsStoreProtocolErrorCode(nil) isEqualToString:@"internal"], @"nil error");
}

void SZFTRunStoreTests(void) {
    TestOpenIsPrivateDurableAndSingleWriter();
    TestPeople();
    TestSavingAStaleCopyLosesNothing();
    TestAutomaticAcceptanceSwitchRules();
    TestProfileAndSettings();
    TestIDRequestsAtMostFourForSevenDays();
    TestIdentifiersAndErrorCodes();
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 2 && strcmp(argv[1], "--child") == 0) return SZFTRunChild(argc, argv);
        if (argc >= 3 && strcmp(argv[1], "--write-v1-fixture") == 0) return SZFTWriteV1Fixture(@(argv[2]));
        if (argc != 2) {
            fprintf(stderr, "usage: %s <fixtures dir>\n", argv[0]);
            return 2;
        }
        // A hung suite (a child that never answers, a lock that never frees) must fail rather than stall a release.
        alarm(300);
        SZFTFixturesDirectory = @(argv[1]);
        // Belt and braces: nothing here may reach the real Friends state, even through a default path.
        setenv("SZFRIENDS_STATE_DIR", SZFTTemporaryDirectory(@"env").fileSystemRepresentation, 1);
        SZFTRunStoreTests();
        SZFTRunHistoryTests();
        SZFTRunSearchTests();
        SZFTRunOutboxTests();
        SZFTRunTransferCheckTests();
        SZFTRunTransferTests();
        SZFTRunReceiveTests();
        SZFTRunReceivedFolderTests();
        SZFTRunTransferSafetyTests();
        SZFTRunKeyTests();
        SZFTRunAddByIDTests();
        SZFTRunRequestTests();
        SZFTRunLapseTests();
        SZFTRunMigrationTests();
        SZFTRunCrashTests();
        SZFTRunThumbnailTests();
        SZFTRunMentionSearchTests();
        SZFTRunDeviceTests();
        SZFTRunSyncTests();
        SZFTRemoveTemporaryRoot();
        if (SZFTFailures) {
            fprintf(stderr, "SZFriendsStoreTests: %d failure(s)\n", SZFTFailures);
            return 1;
        }
        printf("SZFriendsStoreTests passed\n");
        return 0;
    }
}
