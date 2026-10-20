// Crash safety: a child process is killed with SIGKILL mid-transaction, mid-migration, mid-transfer and between
// publishing's rename and its commit; the parent then checks nothing acknowledged is lost, duplicated or claimed.

#import <unistd.h>

#import "SZFriendsStoreTestSupport.h"

static const NSUInteger MiB = 1 << 20;
static int SZFTChildFD = -1;

// A test migration after every shipped one.
static NSInteger SZFTNextVersion(void) { return SZFriendsStoreSchemaVersion + 1; }

static SZFriendsStoreMigration *MigrationNext(BOOL stall) {
    return [SZFriendsStoreMigration migrationToVersion:SZFTNextVersion() minReaderVersion:0
                                                 apply:^BOOL(SZFriendsStoreDB *db, NSError **error) {
        if (![db exec:@"ALTER TABLE friends ADD COLUMN nickname TEXT" error:error]) return NO;
        if (stall) {
            SZFTTell(SZFTChildFD, @"mid");
            sleep(30);
        }
        return YES;
    }];
}

static SZFriendsStoreOptions *WithNext(BOOL stall) {
    SZFriendsStoreOptions *options = [[SZFriendsStoreOptions alloc] init];
    options.migrations = [SZFriendsStoreShippedMigrations() arrayByAddingObject:MigrationNext(stall)];
    return options;
}

static SZFriendsTransfers *Transfers(SZFriendsStore *store) {
    SZFriendsTransfers *transfers = [[SZFriendsTransfers alloc] initWithStore:store
        stateDirectory:store.stateDirectory];
    transfers.freeBytesProvider = ^uint64_t(NSString *path) {
        (void)path;
        return 1ULL << 40;
    };
    return transfers;
}

static const char *SZFTStallPoint = "transfer.after_rename";

static void StallAtPoint(const char *point) {
    if (strcmp(point, SZFTStallPoint) != 0) return;
    SZFTTell(SZFTChildFD, @"mid");
    sleep(30);
}

int SZFTRunChild(int argc, const char *argv[]) {
    if (argc != 5) return 2;
    NSString *mode = @(argv[2]);
    NSString *directory = @(argv[3]);
    SZFTChildFD = atoi(argv[4]);
    if ([mode isEqualToString:@"migrate"]) {
        SZFTOpenStoreWithOptions(directory, WithNext(YES), NULL);
        return 1; // never reached unless the parent failed to kill us
    }
    SZFriendsStore *store = SZFTOpenStore(directory);
    if ([mode isEqualToString:@"insert"]) {
        for (int i = 0; i < 20; i++) {
            NSString *itemID = [NSString stringWithFormat:@"acked-%d", i];
            // Told only after the commit returned: exactly what an ACK may promise (ADR 0001).
            if ([store insertItem:SZFTMessage(@"mei", itemID, [@"acknowledged " stringByAppendingString:itemID],
                100 + i,
                                              SZFriendsDirectionIncoming)
                            error:NULL]) {
                SZFTTell(SZFTChildFD, [@"acked " stringByAppendingString:itemID]);
            }
        }
        [store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **error) {
            for (int i = 0; i < 10; i++) {
                NSString *itemID = [NSString stringWithFormat:@"pending-%d", i];
                SZFriendsStoreInsertItem(db, SZFTMessage(@"mei", itemID, @"never acknowledged", 500 + i,
                                                         SZFriendsDirectionIncoming), NULL, error);
            }
            SZFTTell(SZFTChildFD, @"mid");
            sleep(30);
            return YES;
        } error:NULL];
        return 1;
    }
    NSData *contents = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"contents.bin"]];
    SZFriendsTransfers *transfers = Transfers(store);
    if ([mode isEqualToString:@"chunks"]) {
        transfers.receiver.clock = ^NSDate * { return [NSDate dateWithTimeIntervalSince1970:0]; };
        for (NSUInteger i = 0; i < 5; i++) {
            [transfers appendChunk:[contents subdataWithRange:NSMakeRange(i * MiB, MiB)] atOffset:i * MiB
                        toTransfer:@"c1" fromConversation:@"mei" error:NULL];
        }
        SZFTTell(SZFTChildFD, @"mid");
        sleep(30);
        return 1;
    }
    // Across volumes, stopped with the hidden part file written, or renamed with the staged file still there.
    if ([mode isEqualToString:@"copy-part"] || [mode isEqualToString:@"copy-renamed"]) {
        SZFriendsPublishAcrossVolumes = YES;
        SZFTStallPoint = [mode isEqualToString:@"copy-part"] ? "received.part_written" : "received.part_renamed";
        mode = @"publish";
    }
    if ([mode isEqualToString:@"publish"]) {
        [transfers appendChunk:contents atOffset:0 toTransfer:@"p1" fromConversation:@"mei" error:NULL];
        SZFriendsStoreTestHook = StallAtPoint;
        [transfers finishTransfer:@"p1" finalDigest:SZFTBlake2b(contents) fromConversation:@"mei" error:NULL];
        return 1;
    }
    return 2;
}

static BOOL RunChildUntilMid(NSString *mode, NSString *directory, NSMutableArray<NSString *> *lines) {
    int fd = -1;
    pid_t pid = SZFTSpawnChild(mode, directory, &fd);
    BOOL reached = pid > 0 && SZFTWaitForLine(fd, @"mid", 10, lines);
    SZFTKillChild(pid);
    if (fd >= 0) close(fd);
    return reached;
}

static void TestKillDuringMessageInsert(void) {
    NSString *directory = SZFTTemporaryDirectory(@"crash-insert");
    SZFriendsStore *setup = SZFTOpenStore(directory);
    SZFTAddPerson(setup, @"mei", 1, SZFriendsRelationFriend, 1000);
    [setup close];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    SZFTExpect(RunChildUntilMid(@"insert", directory, lines), @"the child reached its open transaction: %@", lines);
    NSMutableSet *acked = [NSMutableSet set];
    for (NSString *line in lines) {
        if ([line hasPrefix:@"acked "]) [acked addObject:[line substringFromIndex:6]];
    }
    SZFriendsStore *store = SZFTOpenStore(directory);
    NSArray *items = [store itemsInConversation:@"mei" beforeItemID:nil limit:100 hasEarlier:NULL];
    NSSet *stored = [NSSet setWithArray:[items valueForKey:@"itemID"]];
    SZFTExpect(acked.count == 20 && [stored isEqualToSet:acked],
        @"every acknowledged message, once: %lu stored, %lu acked",
               (unsigned long)stored.count, (unsigned long)acked.count);
    SZFTExpect(items.count == stored.count, @"no duplicates");
    SZFTExpect([SZFTScalar(store, @"PRAGMA integrity_check", @[]) isEqual:@"ok"], @"integrity");
    SZFTExpect([store searchFor:@"acknowledged" conversationIDs:nil limit:50].count == 20, @"the index agrees");
    SZFTExpect([store searchFor:@"never" conversationIDs:nil limit:50].count == 0, @"the open transaction is gone");
    SZFTExpect([store insertItem:SZFTMessage(@"mei", @"acked-0", @"redelivered", 100, SZFriendsDirectionIncoming)
                           error:NULL] &&
                   [store itemsInConversation:@"mei" beforeItemID:nil limit:100 hasEarlier:NULL].count == 20,
               @"a redelivery after the crash is acknowledged, not duplicated");
}

static void TestKillDuringMigration(void) {
    NSString *directory = SZFTTemporaryDirectory(@"crash-migrate");
    SZFriendsStore *setup = SZFTOpenStore(directory);
    SZFTAddPerson(setup, @"mei", 1, SZFriendsRelationFriend, 1000);
    [setup insertItem:SZFTMessage(@"mei", @"m1", @"before the upgrade", 100, SZFriendsDirectionIncoming) error:NULL];
    [setup close];
    SZFTExpect(RunChildUntilMid(@"migrate", directory, nil), @"the child reached the middle of its migration");
    NSError *error = nil;
    SZFriendsStore *older = SZFTOpenStoreWithOptions(directory, nil, &error);
    SZFTExpect(older.schemaVersion == SZFriendsStoreSchemaVersion, @"still the shipped schema after the crash: %@",
               error);
    SZFTExpect([older itemsInConversation:@"mei" beforeItemID:nil limit:5 hasEarlier:NULL].count == 1, @"data intact");
    NSString *backup = [NSString stringWithFormat:@"friends.sqlite.before-v%ld", (long)SZFTNextVersion()];
    SZFTExpect([NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:backup]],
               @"the backup was written before migrating");
    [older close];
    SZFriendsStore *upgraded = SZFTOpenStoreWithOptions(directory, WithNext(NO), &error);
    SZFTExpect(upgraded.schemaVersion == SZFTNextVersion(), @"the next start completes it: %@", error);
}

static SZFriendsTransfers *PrepareDownload(NSString *directory, NSString *transferID, NSData *contents) {
    [contents writeToFile:[directory stringByAppendingPathComponent:@"contents.bin"] atomically:NO];
    SZFriendsStore *store = SZFTOpenStore(directory);
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = Transfers(store);
    [transfers recordIncomingOfferWithID:transferID conversationID:@"mei" fileName:@"Drawings.pdf" uniformType:nil
                                    size:contents.length contentDigest:SZFTBlake2b(contents) sentAt:[NSDate date]
                                   error:NULL];
    [transfers acceptTransfer:transferID automatically:NO error:NULL];
    [store close];
    return transfers;
}

static void TestKillMidTransfer(void) {
    NSString *directory = SZFTTemporaryDirectory(@"crash-chunks");
    NSData *contents = SZFTRandomData(6 * MiB);
    PrepareDownload(directory, @"c1", contents);
    SZFTExpect(RunChildUntilMid(@"chunks", directory, nil), @"the child wrote 5 MiB");
    SZFriendsStore *store = SZFTOpenStore(directory);
    NSString *partial = SZFTScalar(store, @"SELECT partial_path FROM transfers WHERE transfer_id = 'c1'", @[]);
    NSNumber *durable = SZFTScalar(store, @"SELECT verified_bytes FROM transfers WHERE transfer_id = 'c1'", @[]);
    NSNumber *onDisk = [NSFileManager.defaultManager attributesOfItemAtPath:partial error:NULL][NSFileSize];
    SZFTExpect(durable.unsignedLongLongValue == 4 * MiB &&
        onDisk.unsignedLongLongValue >= durable.unsignedLongLongValue,
               @"durable bytes never exceed the staging file: %@ of %@", durable, onDisk);
    SZFriendsTransfers *transfers = Transfers(store);
    onDisk = [NSFileManager.defaultManager attributesOfItemAtPath:partial error:NULL][NSFileSize];
    SZFTExpect(onDisk.unsignedLongLongValue == 4 * MiB, @"recovery cut the unconfirmed tail: %@", onDisk);
    SZFriendsTransferRecord *record = [transfers transferWithID:@"c1"];
    BOOL resumed = YES;
    for (uint64_t offset = record.verifiedBytes; offset < contents.length; offset += MiB) {
        NSData *piece = [contents subdataWithRange:NSMakeRange((NSUInteger)offset, MIN(MiB, contents.length - offset))];
        resumed = resumed && [transfers appendChunk:piece atOffset:offset toTransfer:@"c1" fromConversation:@"mei"
                                              error:NULL];
    }
    NSError *error = nil;
    SZFTExpect(resumed && [transfers finishTransfer:@"c1" finalDigest:SZFTBlake2b(contents) fromConversation:@"mei"
                                              error:&error],
               @"resumes and verifies: %@", error);
    NSString *published = [transfers transferWithID:@"c1"].receivedPath;
    SZFTExpect([SZFTBlake2b([NSData dataWithContentsOfFile:published]) isEqualToData:SZFTBlake2b(contents)],
               @"published file matches its digest");
}

static void TestKillBetweenRenameAndCommit(void) {
    NSString *directory = SZFTTemporaryDirectory(@"crash-publish");
    NSData *contents = SZFTRandomData(100000);
    SZFriendsTransfers *setup = PrepareDownload(directory, @"p1", contents);
    SZFTExpect(RunChildUntilMid(@"publish", directory, nil), @"the child renamed and stalled before committing");
    SZFriendsStore *store = SZFTOpenStore(directory);
    NSString *final = SZFTScalar(store, @"SELECT final_path FROM transfers WHERE transfer_id = 'p1'", @[]);
    SZFTExpect([SZFTScalar(store, @"SELECT publishing FROM transfers WHERE transfer_id = 'p1'", @[]) intValue] == 1 &&
                   [NSFileManager.defaultManager fileExistsAtPath:final], @"renamed, not yet recorded");
    SZFriendsTransfers *transfers = Transfers(store);
    SZFriendsTransferRecord *record = [transfers transferWithID:@"p1"];
    SZFTExpect(record.state == SZFriendsTransferStateReceived && [record.receivedPath isEqualToString:final],
               @"recovery records the published file");
    SZFTExpect([SZFTBlake2b([NSData dataWithContentsOfFile:final]) isEqualToData:SZFTBlake2b(contents)], @"digest");
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:setup.destinationDirectory error:NULL];
    SZFTExpect(names.count == 1, @"one file, no duplicate: %@", names);
}

// A copy across volumes stopped by a crash: a leftover hidden part file goes and the copy is redone; a copy already
// renamed is recorded as it is. Either way one complete file, no part file, no duplicate.
static void TestKillDuringCopyAcrossVolumes(NSString *mode) {
    NSString *directory = SZFTTemporaryDirectory([@"crash-" stringByAppendingString:mode]);
    NSData *contents = SZFTRandomData(100000);
    SZFriendsTransfers *setup = PrepareDownload(directory, @"p1", contents);
    SZFTExpect(RunChildUntilMid(mode, directory, nil), @"%@: the child stalled", mode);
    NSString *downloads = setup.destinationDirectory;
    BOOL leftover = NO;
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:downloads error:NULL]) {
        leftover = leftover || [name hasSuffix:@".part"];
    }
    SZFTExpect([mode isEqualToString:@"copy-part"] == leftover, @"%@: part file as the crash left it", mode);
    SZFriendsStore *store = SZFTOpenStore(directory);
    SZFriendsTransfers *transfers = Transfers(store);
    SZFriendsTransferRecord *record = [transfers transferWithID:@"p1"];
    SZFTExpect(record.state == SZFriendsTransferStateReceived &&
                   [SZFTBlake2b([NSData dataWithContentsOfFile:record.receivedPath]) isEqualToData:SZFTBlake2b(contents)],
               @"%@: recovered and complete: %@", mode, record.receivedPath);
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:downloads error:NULL];
    SZFTExpect([names isEqual:@[ @"Drawings.pdf" ]], @"%@: one file, no part, no duplicate: %@", mode, names);
    NSString *partial = [transfers.receivedDirectory stringByAppendingPathComponent:@".partial"];
    SZFTExpect([NSFileManager.defaultManager contentsOfDirectoryAtPath:partial error:NULL].count == 0,
               @"%@: no staging file left", mode);
}

void SZFTRunCrashTests(void) {
    TestKillDuringCopyAcrossVolumes(@"copy-part");
    TestKillDuringCopyAcrossVolumes(@"copy-renamed");
    TestKillDuringMessageInsert();
    TestKillDuringMigration();
    TestKillMidTransfer();
    TestKillBetweenRenameAndCommit();
}
