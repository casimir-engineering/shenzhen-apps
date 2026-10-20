// Migrations: from empty, from the committed v1 fixture, additive and breaking upgrades, failures, backups; and the
// generator that wrote the fixture.

#import <sqlite3.h>

#import "SZFriendsStoreTestSupport.h"

// Fixture clock (portable/friends/README.md § Fixtures): Monday 12 October 2026, 06:47:48Z.
static const NSTimeInterval SZFTFixtureNow = 1791787668;

static SZFriendsStoreOptions *WithExtra(NSArray<SZFriendsStoreMigration *> *extra) {
    SZFriendsStoreOptions *options = [[SZFriendsStoreOptions alloc] init];
    options.migrations = [SZFriendsStoreShippedMigrations() arrayByAddingObjectsFromArray:extra];
    return options;
}

// Test migrations come after every shipped one, numbered from the newest shipped schema so they never collide with a
// real migration.
static NSInteger SZFTNext(void) { return SZFriendsStoreSchemaVersion + 1; }

static NSString *BackupName(NSInteger version) {
    return [NSString stringWithFormat:@"friends.sqlite.before-v%ld", (long)version];
}

static SZFriendsStoreMigration *AdditiveNext(void) {
    return [SZFriendsStoreMigration migrationToVersion:SZFTNext() minReaderVersion:0 apply:^BOOL(SZFriendsStoreDB *db,
                                                                                               NSError **error) {
        return [db exec:@"ALTER TABLE friends ADD COLUMN nickname TEXT; CREATE TABLE stickers (id TEXT PRIMARY KEY)"
                  error:error];
    }];
}

static SZFriendsStoreMigration *BreakingAfterNext(void) {
    return [SZFriendsStoreMigration migrationToVersion:SZFTNext() + 1 minReaderVersion:SZFTNext() + 1
                                                 apply:^BOOL(SZFriendsStoreDB *db, NSError **error) {
        return [db exec:@"ALTER TABLE messages ADD COLUMN edited_at REAL" error:error];
    }];
}

static id _Nullable RawScalar(NSString *path, NSString *sql) {
    sqlite3 *db = NULL;
    id value = nil;
    if (sqlite3_open_v2(path.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK &&
            sqlite3_step(statement) == SQLITE_ROW) {
            value = sqlite3_column_type(statement, 0) == SQLITE_TEXT ? SZFriendsColumnText(statement, 0)
                                                                     : @(sqlite3_column_int64(statement, 0));
        }
        sqlite3_finalize(statement);
    }
    sqlite3_close(db);
    return value;
}

// A state directory holding exactly what a v1 helper wrote: the committed fixture, loaded with plain SQLite.
static NSString *DirectoryFromV1Fixture(NSString *label) {
    NSString *directory = SZFTTemporaryDirectory(label);
    NSString *fixture = [SZFTFixturesDirectory stringByAppendingPathComponent:@"store-v1.sql"];
    NSString *sql = [NSString stringWithContentsOfFile:fixture encoding:NSUTF8StringEncoding error:NULL];
    sqlite3 *db = NULL;
    char *message = NULL;
    NSString *path = [directory stringByAppendingPathComponent:@"friends.sqlite"];
    int rc = sql ? sqlite3_open(path.fileSystemRepresentation, &db) : SQLITE_ERROR;
    if (rc == SQLITE_OK) rc = sqlite3_exec(db, sql.UTF8String, NULL, NULL, &message);
    SZFTExpect(rc == SQLITE_OK, @"loading %@: %s", fixture, message ?: "missing fixture");
    sqlite3_free(message);
    sqlite3_close(db);
    return directory;
}

static NSArray *Schema(SZFriendsStore *store) {
    __block NSMutableArray *rows = [NSMutableArray array];
    [store performOnWriter:^(SZFriendsStoreDB *db) {
        [db run:@"SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
            binds:nil
              row:^(sqlite3_stmt *s) {
                  [rows addObject:@[ SZFriendsColumnText(s, 0) ?: @"", SZFriendsColumnText(s, 1) ?: @"",
                                     SZFriendsColumnText(s, 2) ?: @"" ]];
              }
            error:NULL];
    }];
    return rows;
}

static NSArray<NSString *> *Backups(NSString *directory) {
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL]) {
        if ([name hasPrefix:@"friends.sqlite.before-v"]) [names addObject:name];
    }
    return names;
}

static void TestFromEmptyAndFromTheV1Fixture(void) {
    SZFriendsStore *fresh = SZFTOpenStore(SZFTTemporaryDirectory(@"empty"));
    SZFTExpect(fresh.schemaVersion == SZFriendsStoreSchemaVersion && Backups(fresh.stateDirectory).count == 0,
               @"a new store needs no backup");
    SZFTExpect([SZFTScalar(fresh, @"SELECT value FROM meta WHERE key = 'store_id'", @[]) length] == 32, @"store id");
    NSString *directory = DirectoryFromV1Fixture(@"v1");
    SZFriendsStore *store = SZFTOpenStore(directory);
    SZFTExpect(store.schemaVersion == SZFriendsStoreSchemaVersion &&
                   [Backups(directory) isEqual:@[ BackupName(SZFriendsStoreSchemaVersion) ]],
               @"the v1 fixture migrates, backed up first: %@", Backups(directory));
    // v2 locks out v1 helpers: they would read an answered Add by ID as still pending (SZFriendsStoreSchema.m).
    SZFTExpect([SZFTScalar(store, @"SELECT value FROM meta WHERE key = 'min_reader_version'", @[]) isEqual:@"2"],
               @"min_reader_version 2");
    SZFTExpect([store personWithConversationID:@"c_mei"].pendingStaticKey == nil &&
                   [SZFTScalar(store, @"SELECT count(*) FROM id_request_answers", @[]) integerValue] == 0,
               @"v2's columns and table start empty");
    SZFTExpect(store.peopleByLatestInteraction.count == 4, @"people: %lu",
        (unsigned long)store.peopleByLatestInteraction.count);
    SZFTExpect([[store personWithConversationID:@"c_mei"].name isEqualToString:@"Mei Lin"], @"Mei");
    SZFTExpect([store personWithConversationID:@"c_mei"].autoAccept, @"her switch");
    SZFTExpect([store.profileName isEqualToString:@"Raph"] && [store.friendsID isEqualToString:@"maple-river"],
               @"profile");
    NSArray *hits = [[store searchFor:@"合同" conversationIDs:nil limit:10] valueForKey:@"itemID"];
    SZFTExpect([hits isEqual:@[ @"m_contract" ]], @"the index is built from fixture rows: %@", hits);
    SZFTExpect([Schema(store) isEqual:Schema(fresh)], @"migrating the fixture yields exactly a fresh schema");
    SZFTExpect([SZFTScalar(store, @"PRAGMA integrity_check", @[]) isEqual:@"ok"], @"integrity");
}

static void TestAdditiveMigrationKeepsOlderHelpersWorking(void) {
    NSString *directory = DirectoryFromV1Fixture(@"additive");
    NSError *error = nil;
    SZFriendsStore *upgraded = SZFTOpenStoreWithOptions(directory, WithExtra(@[ AdditiveNext() ]), &error);
    SZFTExpect(upgraded.schemaVersion == SZFTNext(), @"migrated to v%ld: %@", (long)SZFTNext(), error);
    SZFTExpect([Backups(directory) isEqual:@[ BackupName(SZFTNext()) ]], @"backup: %@", Backups(directory));
    NSString *backup = [directory stringByAppendingPathComponent:BackupName(SZFTNext())];
    SZFTExpect(SZFTFileMode(backup) == 0600, @"the backup is as private as the store");
    SZFTExpect([RawScalar(backup, @"PRAGMA user_version") integerValue] == 1 &&
                   [RawScalar(backup, @"SELECT count(*) FROM friends") integerValue] == 4,
                       @"the backup is the v1 store");
    SZFTExpect(upgraded.peopleByLatestInteraction.count == 4, @"data intact");
    [upgraded close];
    SZFriendsStore *older = SZFTOpenStoreWithOptions(directory, nil, &error);
    SZFTExpect(older && older.schemaVersion == SZFTNext(),
               @"a helper of the shipped schema still opens an additively upgraded store: %@", error);
    SZFTExpect([older insertItem:SZFTMessage(@"c_mei", @"m_after", @"written by an older helper", SZFTFixtureNow + 60,
                                             SZFriendsDirectionIncoming)
                           error:&error], @"and writes to it: %@", error);
    [older close];
}

static void TestBreakingMigrationLocksOutOlderHelpers(void) {
    NSString *directory = DirectoryFromV1Fixture(@"breaking");
    NSError *error = nil;
    SZFriendsStore *next = SZFTOpenStoreWithOptions(directory, WithExtra(@[ AdditiveNext() ]), &error);
    [next close];
    SZFriendsStore *breaking = SZFTOpenStoreWithOptions(directory, WithExtra(@[ AdditiveNext(), BreakingAfterNext() ]),
                                                        &error);
    SZFTExpect(breaking.schemaVersion == SZFTNext() + 1, @"breaking: %@", error);
    SZFTExpect([Backups(directory) isEqual:@[ BackupName(SZFTNext() + 1) ]], @"only the latest backup is kept: %@",
               Backups(directory));
    [breaking close];
    NSString *path = [directory stringByAppendingPathComponent:@"friends.sqlite"];
    NSData *before = [NSData dataWithContentsOfFile:path];
    SZFriendsStore *older = SZFTOpenStoreWithOptions(directory, nil, &error);
    SZFTExpect(!older && error.code == SZFriendsStoreErrorNewerSchema, @"an older helper refuses: %@", error);
    SZFTExpect([[NSData dataWithContentsOfFile:path] isEqualToData:before], @"and leaves the file exactly as it was");
}

static void TestFailedMigrationLeavesTheOriginal(void) {
    NSString *directory = DirectoryFromV1Fixture(@"failing");
    SZFriendsStoreMigration *broken = [SZFriendsStoreMigration
        migrationToVersion:SZFTNext()
          minReaderVersion:0
                     apply:^BOOL(SZFriendsStoreDB *db, NSError **error) {
                         return [db exec:@"CREATE TABLE half_done (x); SELECT * FROM no_such_table" error:error];
                     }];
    NSError *error = nil;
    SZFTExpect(!SZFTOpenStoreWithOptions(directory, WithExtra(@[ broken ]), &error) &&
                   error.code == SZFriendsStoreErrorMigrationFailed, @"fails: %@", error);
    NSString *path = [directory stringByAppendingPathComponent:@"friends.sqlite"];
    SZFTExpect([RawScalar(path, @"PRAGMA user_version") integerValue] == SZFriendsStoreSchemaVersion,
               @"still at the last migration that succeeded");
    SZFTExpect([RawScalar(path, @"SELECT count(*) FROM sqlite_master WHERE name = 'half_done'") integerValue] == 0,
               @"the half-done change rolled back");
    SZFTExpect([Backups(directory) isEqual:@[ BackupName(SZFTNext()) ]], @"the backup stays");
    SZFriendsStore *store = SZFTOpenStoreWithOptions(directory, nil, &error);
    SZFTExpect(store.peopleByLatestInteraction.count == 4, @"the original still works: %@", error);
}

// v3 gives requests already waiting a start: when they were asked, else their latest interaction, so they lapse and
// the helper's IK window closes like any other (SZFriendsStoreSchema.m).
static void TestV3StartsTheRequestsAlreadyWaiting(void) {
    SZFriendsStore *fixture = SZFTOpenStore(DirectoryFromV1Fixture(@"v1-since"));
    SZFTExpect([[fixture personWithConversationID:@"c_lena"].pendingRequestSince
                   isEqualToDate:[NSDate dateWithTimeIntervalSince1970:1791785868]] &&
                   ![fixture personWithConversationID:@"c_mei"].pendingRequestSince,
               @"the fixture's request counts from its latest interaction; a friend has none");
    NSString *directory = SZFTTemporaryDirectory(@"v2");
    SZFriendsStoreOptions *v2 = [[SZFriendsStoreOptions alloc] init];
    v2.migrations = [SZFriendsStoreShippedMigrations() subarrayWithRange:NSMakeRange(0, 2)];
    NSError *error = nil;
    SZFriendsStore *older = SZFTOpenStoreWithOptions(directory, v2, &error);
    SZFTExpect(older.schemaVersion == 2, @"a v2 store: %@", error);
    NSString *insert = @"INSERT INTO friends (conversation_id, identity_pk, relation, request_at, last_interaction_at) "
                       @"VALUES (?, ?, ?, ?, ?)";
    SZFTScalar(older, insert, @[ @"in", SZFTBytes(1, 32), @(SZFriendsRelationIncomingRequest), @5000, @5500 ]);
    SZFTScalar(older, insert, @[ @"out", SZFTBytes(2, 32), @(SZFriendsRelationOutgoingRequest), [NSNull null], @6000 ]);
    SZFTScalar(older, insert, @[ @"fr", SZFTBytes(3, 32), @(SZFriendsRelationFriend), @4000, @7000 ]);
    [older close];
    SZFriendsStoreOptions *v3 = [[SZFriendsStoreOptions alloc] init];
    v3.migrations = [SZFriendsStoreShippedMigrations() subarrayWithRange:NSMakeRange(0, 3)];
    SZFriendsStore *atV3 = SZFTOpenStoreWithOptions(directory, v3, &error);
    SZFTExpect(atV3.schemaVersion == 3 && [Backups(directory) isEqual:@[ BackupName(3) ]], @"v2 to v3: %@", error);
    SZFTExpect([SZFTScalar(atV3, @"SELECT value FROM meta WHERE key = 'min_reader_version'", @[]) isEqual:@"2"],
               @"additive: v2 helpers still open it");
    // This code reads the newest schema's columns, so the rows are read once the store is current.
    [atV3 close];
    SZFriendsStore *store = SZFTOpenStoreWithOptions(directory, nil, &error);
    SZFTExpect([[store personWithConversationID:@"in"].pendingRequestSince
                   isEqualToDate:[NSDate dateWithTimeIntervalSince1970:5000]] &&
                   [[store personWithConversationID:@"out"].pendingRequestSince
                       isEqualToDate:[NSDate dateWithTimeIntervalSince1970:6000]] &&
                   ![store personWithConversationID:@"fr"].pendingRequestSince,
               @"backfilled from when they were asked");
}

// v4 adds via_assistant (everything older was the person's own) and the unconfirmed answer's ID, which counts only on
// an incoming request, so a row an older helper moved on from never shows the answer card's words.
static void TestV4AddsAssistantAndUnconfirmedAnswers(void) {
    NSString *directory = SZFTTemporaryDirectory(@"v3");
    SZFriendsStoreOptions *v3 = [[SZFriendsStoreOptions alloc] init];
    v3.migrations = [SZFriendsStoreShippedMigrations() subarrayWithRange:NSMakeRange(0, 3)];
    NSError *error = nil;
    SZFriendsStore *older = SZFTOpenStoreWithOptions(directory, v3, &error);
    SZFTExpect(older.schemaVersion == 3, @"a v3 store: %@", error);
    NSString *person = @"INSERT INTO friends (conversation_id, identity_pk, relation, last_interaction_at) "
                       @"VALUES (?, ?, ?, ?)";
    SZFTScalar(older, person, @[ @"in", SZFTBytes(1, 32), @(SZFriendsRelationIncomingRequest), @5000 ]);
    SZFTScalar(older, person, @[ @"fr", SZFTBytes(2, 32), @(SZFriendsRelationFriend), @6000 ]);
    SZFTScalar(older, @"INSERT INTO messages (conversation_id, item_id, kind, direction, body, sent_at, received_at) "
                      @"VALUES ('fr', 'm1', 0, 0, 'hi', 1, 1)",
               @[]);
    [older close];
    SZFriendsStoreOptions *v4 = [[SZFriendsStoreOptions alloc] init];
    v4.migrations = [SZFriendsStoreShippedMigrations() subarrayWithRange:NSMakeRange(0, 4)];
    SZFriendsStore *atV4 = SZFTOpenStoreWithOptions(directory, v4, &error);
    SZFTExpect(atV4.schemaVersion == 4 && [Backups(directory) isEqual:@[ BackupName(4) ]], @"v3 to v4: %@", error);
    // This code reads the newest schema's columns, so the rows are read once the store is current.
    [atV4 close];
    SZFriendsStore *store = SZFTOpenStoreWithOptions(directory, nil, &error);
    SZFTExpect(![store itemWithID:@"m1" inConversation:@"fr"].viaAssistant, @"older messages were the person's own");
    SZFTScalar(store, @"UPDATE friends SET unconfirmed_answer_id = 'tulip-canyon'", @[]);
    SZFTExpect([[store personWithConversationID:@"in"].unconfirmedAnswerID isEqualToString:@"tulip-canyon"] &&
                   ![store personWithConversationID:@"fr"].unconfirmedAnswerID,
               @"only an incoming request shows it");
    SZFTExpect([SZFTScalar(store, @"SELECT value FROM meta WHERE key = 'min_reader_version'", @[]) isEqual:@"2"],
               @"additive: v2 and v3 helpers still open it");
}

// v5 adds messages.cancelled: nothing written before it was cancelled, and older helpers keep opening the store.
static void TestV5AddsCancelledMessages(void) {
    NSString *directory = SZFTTemporaryDirectory(@"v4");
    SZFriendsStoreOptions *v4 = [[SZFriendsStoreOptions alloc] init];
    v4.migrations = [SZFriendsStoreShippedMigrations() subarrayWithRange:NSMakeRange(0, 4)];
    NSError *error = nil;
    SZFriendsStore *older = SZFTOpenStoreWithOptions(directory, v4, &error);
    SZFTExpect(older.schemaVersion == 4, @"a v4 store: %@", error);
    SZFTScalar(older, @"INSERT INTO friends (conversation_id, identity_pk, relation, last_interaction_at) "
                      @"VALUES ('fr', ?, ?, 6000)",
               @[ SZFTBytes(2, 32), @(SZFriendsRelationFriend) ]);
    SZFTScalar(older, @"INSERT INTO messages (conversation_id, item_id, kind, direction, body, sent_at, received_at) "
                      @"VALUES ('fr', 'm1', 0, 1, 'sent before v5', 1, 1)",
               @[]);
    [older close];
    SZFriendsStoreOptions *v5 = [[SZFriendsStoreOptions alloc] init];
    v5.migrations = [SZFriendsStoreShippedMigrations() subarrayWithRange:NSMakeRange(0, 5)];
    SZFriendsStore *store = SZFTOpenStoreWithOptions(directory, v5, &error);
    SZFTExpect(store.schemaVersion == 5 && [Backups(directory) isEqual:@[ BackupName(5) ]], @"v4 to v5: %@", error);
    SZFTExpect(![store itemWithID:@"m1" inConversation:@"fr"].cancelled, @"nothing sent before was cancelled");
    SZFTExpect([SZFTScalar(store, @"SELECT value FROM meta WHERE key = 'min_reader_version'", @[]) isEqual:@"2"],
               @"additive: older helpers still open it");
}

// v11 adds friends.left_list_at: nobody was off the list before. It counts only for someone Removed or Blocked, and a
// save with any other relation clears it, so a new request brings them back; older helpers keep opening the store.
static void TestV11AddsLeavingTheList(void) {
    NSString *directory = SZFTTemporaryDirectory(@"v10");
    SZFriendsStoreOptions *v10 = [[SZFriendsStoreOptions alloc] init];
    v10.migrations = [SZFriendsStoreShippedMigrations() subarrayWithRange:NSMakeRange(0, 10)];
    NSError *error = nil;
    SZFriendsStore *older = SZFTOpenStoreWithOptions(directory, v10, &error);
    SZFTExpect(older.schemaVersion == 10, @"a v10 store: %@", error);
    NSString *person = @"INSERT INTO friends (conversation_id, identity_pk, relation, last_interaction_at) "
                       @"VALUES (?, ?, ?, ?)";
    SZFTScalar(older, person, @[ @"in", SZFTBytes(1, 32), @(SZFriendsRelationIncomingRequest), @5000 ]);
    SZFTScalar(older, person, @[ @"out", SZFTBytes(2, 32), @(SZFriendsRelationOutgoingRequest), @5100 ]);
    SZFTScalar(older, person, @[ @"fr", SZFTBytes(3, 32), @(SZFriendsRelationFriend), @5200 ]);
    SZFTScalar(older, person, @[ @"rm", SZFTBytes(4, 32), @(SZFriendsRelationRemoved), @5300 ]);
    SZFTScalar(older, person, @[ @"bl", SZFTBytes(5, 32), @(SZFriendsRelationBlocked), @5400 ]);
    [older close];
    SZFriendsStore *store = SZFTOpenStoreWithOptions(directory, nil, &error);
    SZFTExpect(store.schemaVersion == 11 && [Backups(directory) isEqual:@[ BackupName(11) ]], @"v10 to v11: %@",
               error);
    SZFTExpect([SZFTScalar(store, @"SELECT value FROM meta WHERE key = 'min_reader_version'", @[]) isEqual:@"2"],
               @"additive: older helpers still open it");
    for (NSString *conversationID in @[ @"in", @"out", @"fr", @"rm", @"bl" ]) {
        SZFTExpect(![store personWithConversationID:conversationID].leftListAt, @"nobody was off the list: %@",
                   conversationID);
    }
    SZFTScalar(store, @"UPDATE friends SET left_list_at = 6000", @[]);
    NSDate *left = [NSDate dateWithTimeIntervalSince1970:6000];
    SZFTExpect([[store personWithConversationID:@"rm"].leftListAt isEqualToDate:left] &&
                   [[store personWithConversationID:@"bl"].leftListAt isEqualToDate:left] &&
                   ![store personWithConversationID:@"in"].leftListAt &&
                   ![store personWithConversationID:@"out"].leftListAt &&
                   ![store personWithConversationID:@"fr"].leftListAt,
               @"only someone Removed or Blocked can be off the list, whatever an older helper wrote");
    // Saving keeps it for Removed and Blocked, and clears it for anything else: a new request brings them back.
    SZFriendsPersonRecord *removed = [store personWithConversationID:@"rm"];
    removed.leftListAt = [NSDate dateWithTimeIntervalSince1970:7000];
    SZFTExpect([store savePerson:removed error:&error] &&
                   [[store personWithConversationID:@"rm"].leftListAt
                       isEqualToDate:[NSDate dateWithTimeIntervalSince1970:7000]],
               @"a former friend stays off the list: %@", error);
    removed = [store personWithConversationID:@"rm"];
    removed.relation = SZFriendsRelationIncomingRequest;
    SZFTExpect([store savePerson:removed error:&error] && ![store personWithConversationID:@"rm"].leftListAt &&
                   [SZFTScalar(store, @"SELECT left_list_at IS NULL FROM friends WHERE conversation_id = 'rm'", @[])
                       integerValue] == 1,
               @"their new request brings them back, and the column is cleared: %@", error);
    SZFriendsPersonRecord *friend = [store personWithConversationID:@"fr"];
    friend.leftListAt = left;
    SZFTExpect([store savePerson:friend error:&error] &&
                   [SZFTScalar(store, @"SELECT left_list_at IS NULL FROM friends WHERE conversation_id = 'fr'", @[])
                       integerValue] == 1,
               @"a friend is never saved off the list: %@", error);
    SZFriendsPersonRecord *copy = [[store personWithConversationID:@"bl"] copy];
    SZFTExpect([copy.leftListAt isEqualToDate:left], @"copies keep it");
}

void SZFTRunMigrationTests(void) {
    TestV11AddsLeavingTheList();
    TestFromEmptyAndFromTheV1Fixture();
    TestV3StartsTheRequestsAlreadyWaiting();
    TestV4AddsAssistantAndUnconfirmedAnswers();
    TestV5AddsCancelledMessages();
    TestAdditiveMigrationKeepsOlderHelpersWorking();
    TestBreakingMigrationLocksOutOlderHelpers();
    TestFailedMigrationLeavesTheOriginal();
}

#pragma mark - Fixture generator

static void Seed(SZFriendsStore *store) {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:SZFTFixtureNow];
    store.profileName = @"Raph";
    store.profilePicture = [SZFriendsPicture animalWithSet:1 index:3];
    store.friendsID = @"maple-river";
    store.friendsIDState = 1;
    store.nearbyPermissionsRequested = YES;
    store.ownPresenceSecret = SZFTBytes(0x51, 32);
    NSArray *people = @[
        @[ @"c_mei", @"Mei Lin", @(SZFriendsRelationFriend), @1 ],
        @[ @"c_lena", @"Lena Weber", @(SZFriendsRelationIncomingRequest), @3 ],
        @[ @"c_priya", @"Priya", @(SZFriendsRelationFriend), @5 ],
        @[ @"c_kenji", @"Kenji", @(SZFriendsRelationBlocked), @7 ]
    ];
    for (NSArray *row in people) {
        SZFriendsPersonRecord *person = SZFTAddPerson(store, row[0], (uint8_t)[row[3] intValue], [row[2] integerValue],
                                                      SZFTFixtureNow - 600 * [row[3] intValue]);
        person.name = row[1];
        person.friendsID = [row[0] isEqualToString:@"c_mei"] ? @"orchid-summit" : nil;
        person.picture = [SZFriendsPicture animalWithSet:1 index:[row[3] integerValue]];
        person.verified = [row[0] isEqualToString:@"c_mei"];
        person.comparisonCode = @"418270";
        person.autoAccept = [row[0] isEqualToString:@"c_mei"];
        person.presenceSecret = SZFTBytes((uint8_t)(0x60 + [row[3] intValue]), 32);
        [store savePerson:person error:NULL];
    }
    NSArray *messages = @[
        @[ @"c_mei", @"m_contract", @"请把合同发给我", @(SZFTFixtureNow - 900), @0 ],
        @[ @"c_mei", @"m_reply", @"Sending the Café menu tonight", @(SZFTFixtureNow - 800), @1 ],
        @[ @"c_priya", @"m_priya", @"Site visit at 10?", @(SZFTFixtureNow - 700), @0 ]
    ];
    for (NSArray *row in messages) {
        [store insertItem:SZFTMessage(row[0], row[1], row[2], [row[3] doubleValue], [row[4] integerValue]) error:NULL];
    }
    SZFriendsOutbox *outbox = [[SZFriendsOutbox alloc] initWithStore:store];
    SZFriendsOutboxEntry *entry = [[SZFriendsOutboxEntry alloc] init];
    entry.entryID = @"e_reply";
    entry.conversationID = @"c_mei";
    entry.kind = SZFriendsOutboxKindMessage;
    entry.itemID = @"m_reply";
    entry.createdAt = [now dateByAddingTimeInterval:-800];
    entry.clientToken = @"fixture-token-0001";
    [outbox enqueue:entry error:NULL];
    SZFriendsTransferRecord *transfer = [[SZFriendsTransferRecord alloc] init];
    transfer.transferID = @"t_photos";
    transfer.conversationID = @"c_priya";
    transfer.state = SZFriendsTransferStateWaitingForYou;
    transfer.fileName = @"Site photos.pdf";
    transfer.uniformType = @"com.adobe.pdf";
    transfer.size = 2516582;
    transfer.contentDigest = SZFTBytes(0x77, 32);
    transfer.createdAt = [now dateByAddingTimeInterval:-650];
    [store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **error) {
        return SZFriendsTransferRowInsert(db, transfer, nil, error) &&
               [db run:@"UPDATE transfers SET updated_at = created_at" binds:nil row:nil error:error] &&
               [db run:@"UPDATE outbox SET updated_at = created_at" binds:nil row:nil error:error] &&
               [db exec:@"UPDATE meta SET value = 'fixture-store-v1' WHERE key = 'store_id';"
                        @"UPDATE meta SET value = '1791787668.000' WHERE key = 'created_at'" error:error];
    } error:NULL];
    SZFriendsItemRecord *offer = SZFTMessage(@"c_priya", @"t_photos", nil, SZFTFixtureNow - 650,
        SZFriendsDirectionIncoming);
    offer.kind = SZFriendsItemKindTransfer;
    offer.transferID = @"t_photos";
    [store insertItem:offer error:NULL];
}

int SZFTWriteV1Fixture(NSString *path) {
    // The fixture records what v1 helpers wrote; from the day a v2 exists it is frozen (ADR 0003 § Verification).
    if (SZFriendsStoreSchemaVersion != 1) {
        fprintf(stderr, "store-v1.sql is frozen: schema v%ld exists, so v1 is no longer what this code writes\n",
                (long)SZFriendsStoreSchemaVersion);
        return 1;
    }
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"fixture"));
    Seed(store);
    NSMutableString *sql = [NSMutableString stringWithString:
        @"-- Shenzhen Friends store, schema v1, exactly as a v1 helper writes it (minus the FTS index, which every\n"
        @"-- helper rebuilds where its SQLite has trigram). Generated by `make -C portable friends-store-v1-fixture`\n"
        @"-- while v1 was the newest schema; frozen from the day v2 ships. The migration tests load it with plain\n"
        @"-- SQLite and open it with the current code. Names, keys and times are invented (fixture clock\n"
        @"-- 2026-10-12T06:47:48Z).\n"
        @"PRAGMA user_version = 1;\nBEGIN;\n"];
    [store performOnWriter:^(SZFriendsStoreDB *db) {
        NSMutableArray<NSString *> *tables = [NSMutableArray array];
        [db run:@"SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite%' AND "
                @"name <> 'search' AND name NOT LIKE 'search%' ORDER BY rowid"
            binds:nil
              row:^(sqlite3_stmt *s) {
                  [sql appendFormat:@"%@;\n", SZFriendsColumnText(s, 2)];
                  if ([SZFriendsColumnText(s, 0) isEqualToString:@"table"]) [tables addObject:SZFriendsColumnText(s,
                      1)];
              }
            error:NULL];
        for (NSString *table in tables) {
            NSMutableArray *columns = [NSMutableArray array];
            [db run:[NSString stringWithFormat:@"PRAGMA table_info(%@)", table] binds:nil
                row:^(sqlite3_stmt *s) { [columns addObject:SZFriendsColumnText(s, 1)]; }
              error:NULL];
            NSMutableArray *quoted = [NSMutableArray array];
            for (NSString *column in columns) [quoted addObject:[NSString stringWithFormat:@"quote(%@)", column]];
            NSString *select = [NSString stringWithFormat:@"SELECT 'INSERT INTO %@ (%@) VALUES (' || %@ || ');' "
                                                          @"FROM %@ ORDER BY 1",
                                                          table, [columns componentsJoinedByString:@", "],
                                                          [quoted componentsJoinedByString:@" || ', ' || "], table];
            [db run:select binds:nil row:^(sqlite3_stmt *s) { [sql appendFormat:@"%@\n", SZFriendsColumnText(s, 0)]; }
              error:NULL];
        }
    }];
    [sql appendString:@"COMMIT;\n"];
    SZFTRemoveTemporaryRoot();
    NSError *error = nil;
    if (![sql writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        fprintf(stderr, "cannot write %s: %s\n", path.UTF8String, error.localizedDescription.UTF8String);
        return 1;
    }
    printf("wrote %s\n", path.UTF8String);
    return 0;
}
