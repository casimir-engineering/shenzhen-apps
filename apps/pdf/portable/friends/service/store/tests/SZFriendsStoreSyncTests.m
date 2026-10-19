// What the store keeps for sync between own devices (schema v9, SZFriendsStoreSync.h): v8 to v9 keeps everything, the
// event log stays contiguous per author and keeps a copy once, items copied from another device keep the earliest
// time and stay deleted once a deletion took them (even when the friend delivers them again), a deletion takes
// exactly the items its vector covers and drops the bodies that carried them, synced outbox entries arrive queued, the
// read marker drives the unread count, and Reset Friends forgets all of it.

#import "SZFriendsStoreTestSupport.h"

#import "service/store/SZFriendsStoreSync.h"

static SZFriendsSyncLogEvent *SZFTEvent(NSData *author, uint64_t seq, NSString *subject, NSData *_Nullable body) {
    SZFriendsSyncLogEvent *event = [[SZFriendsSyncLogEvent alloc] init];
    event.author = author;
    event.seq = seq;
    event.lamport = seq;
    event.kind = 5;
    event.scope = @"k:x";
    event.subject = subject;
    event.header = SZFTBytes((uint8_t)seq, 40);
    event.body = body;
    return event;
}

static void TestMigrationKeepsEverything(void) {
    NSString *directory = SZFTTemporaryDirectory(@"sync-migrate");
    SZFriendsStoreOptions *v8 = [[SZFriendsStoreOptions alloc] init];
    v8.migrations = [SZFriendsStoreShippedMigrations() subarrayWithRange:NSMakeRange(0, 8)];
    NSError *error = nil;
    SZFriendsStore *older = SZFTOpenStoreWithOptions(directory, v8, &error);
    SZFTExpect(older.schemaVersion == 8, @"a v8 store: %@", error);
    SZFTAddPerson(older, @"mei", 1, SZFriendsRelationFriend, 1000);
    [older insertItem:SZFTMessage(@"mei", @"m1", @"kept", 1000, SZFriendsDirectionIncoming) error:NULL];
    [older close];
    SZFriendsStore *store = SZFTOpenStore(directory);
    SZFTExpect(store.schemaVersion == 9 && [store itemWithID:@"m1" inConversation:@"mei"] != nil, @"v8 to v9 keeps it");
    SZFTExpect([store syncEventCount] == 0 && [store syncVector].count == 0, @"and starts with an empty log");
    int64_t last = 0;
    SZFTExpect([store itemsWithoutSyncOriginAfterRow:0 limit:10 lastRow:&last].count == 1 && last > 0,
               @"what was there before is found by the first scan");
}

static void TestLogIsContiguous(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"sync-log"));
    NSData *a = SZFTBytes(0xa1, 32), *b = SZFTBytes(0xb1, 32);
    BOOL appended = NO;
    NSError *error = nil;
    SZFTExpect([store appendSyncEvent:SZFTEvent(a, 1, @"x1", SZFTBytes(1, 3)) appended:&appended error:&error] &&
                   appended,
               @"first: %@", error);
    SZFTExpect([store appendSyncEvent:SZFTEvent(a, 1, @"x1", SZFTBytes(1, 3)) appended:&appended error:NULL] &&
                   !appended,
               @"a copy is kept once");
    SZFTExpect(![store appendSyncEvent:SZFTEvent(a, 3, @"x3", nil) appended:&appended error:&error] &&
                   error.code == SZFriendsStoreErrorInvalid,
               @"a gap is refused");
    [store appendSyncEvent:SZFTEvent(a, 2, @"x2", nil) appended:NULL error:NULL];
    [store appendSyncEvent:SZFTEvent(b, 1, @"y1", nil) appended:NULL error:NULL];
    SZFTExpect([[store syncVector] isEqualToDictionary:(@{a : @2, b : @1})], @"vector %@", [store syncVector]);
    NSArray<SZFriendsSyncLogEvent *> *missing = [store syncEventsMissingFrom:@{a : @1} limit:10];
    SZFTExpect(missing.count == 2 && [missing[0].subject isEqualToString:@"x2"] && missing[0].body == nil &&
                   [missing[1].subject isEqualToString:@"y1"],
               @"what a vector lacks, each author's in order");
    SZFTExpect([store unappliedSyncEvents].count == 3 && [store markSyncEventApplied:a seq:1 error:NULL] &&
                   [store unappliedSyncEvents].count == 2,
               @"applied marks");
}

static void TestItemsOriginsAndDeletion(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"sync-items"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    NSData *a = SZFTBytes(0xa1, 32), *b = SZFTBytes(0xb1, 32);
    SZFriendsItemRecord *late = SZFTMessage(@"mei", @"m1", @"private words", 1000, SZFriendsDirectionIncoming);
    late.receivedAt = [NSDate dateWithTimeIntervalSince1970:1500];
    SZFTExpect([store mergeSyncedItem:late author:b seq:1 error:NULL], @"B's copy");
    SZFriendsItemRecord *early = SZFTMessage(@"mei", @"m1", @"private words", 1000, SZFriendsDirectionIncoming);
    early.receivedAt = [NSDate dateWithTimeIntervalSince1970:1200];
    SZFTExpect([store mergeSyncedItem:early author:a seq:1 error:NULL], @"A's copy");
    SZFTExpect([store itemWithID:@"m1" inConversation:@"mei"].receivedAt.timeIntervalSince1970 == 1200,
               @"the earliest arrival wins");
    [store mergeSyncedItem:SZFTMessage(@"mei", @"m2", @"stays", 1001, SZFriendsDirectionIncoming) author:b seq:2
                     error:NULL];
    [store appendSyncEvent:SZFTEvent(a, 1, @"m1", SZFTBytes(7, 4)) appended:NULL error:NULL];
    [store appendSyncEvent:SZFTEvent(b, 1, @"m1", SZFTBytes(7, 4)) appended:NULL error:NULL];
    [store appendSyncEvent:SZFTEvent(b, 2, @"m2", SZFTBytes(8, 4)) appended:NULL error:NULL];
    // A deletion that saw only A's first event: m1 goes (one of its origins is covered), m2 stays.
    NSArray<NSString *> *touched = [store deleteSyncedItemsInConversation:@"mei" coveredBy:@{a : @1} fileKind:8
                                                               outboxKind:7 error:NULL];
    SZFTExpect([touched isEqualToArray:@[ @"mei" ]], @"touched %@", touched);
    SZFTExpect([store itemWithID:@"m1" inConversation:@"mei"] == nil &&
                   [store itemWithID:@"m2" inConversation:@"mei"] != nil,
               @"exactly what the vector covers");
    SZFTExpect([store syncEventWithAuthor:b seq:1].body == nil && [store syncEventWithAuthor:a seq:1].body == nil &&
                   [store syncEventWithAuthor:b seq:2].body != nil,
               @"every event that carried m1 lost its body, and only those");
    SZFTExpect([store isSyncDeletedItem:@"m1" inConversation:@"mei"], @"marked deleted");
    SZFTExpect([store mergeSyncedItem:early author:a seq:9 error:NULL] &&
                   [store itemWithID:@"m1" inConversation:@"mei"] == nil,
               @"a later copy stays deleted");
    SZFTExpect([store insertItem:early error:NULL] && [store itemWithID:@"m1" inConversation:@"mei"] == nil,
               @"so does the friend delivering it again");
    NSString *database = [store.stateDirectory stringByAppendingPathComponent:@"friends.sqlite"];
    NSData *needle = [@"private words" dataUsingEncoding:NSUTF8StringEncoding];
    SZFTExpect(!SZFTFileContains(database, needle) &&
                   !SZFTFileContains([database stringByAppendingString:@"-wal"], needle),
               @"the text is gone from the file");
}

static void TestUnreadFromMarker(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"sync-unread"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    for (int i = 0; i < 3; i++) {
        SZFriendsItemRecord *item = SZFTMessage(@"mei", [NSString stringWithFormat:@"m%d", i], @"x", 1000 + i,
                                                SZFriendsDirectionIncoming);
        item.receivedAt = item.sentAt;
        [store insertItem:item error:NULL];
    }
    SZFriendsItemRecord *second = [store incomingItemInConversation:@"mei" newerCount:1];
    SZFTExpect([second.itemID isEqualToString:@"m1"] &&
                   [[store newestIncomingItemInConversation:@"mei"].itemID isEqualToString:@"m2"],
               @"positions from the newest");
    [store recountUnreadInConversation:@"mei" readThroughDate:second.receivedAt itemID:second.itemID error:NULL];
    SZFTExpect([store personWithConversationID:@"mei"].unreadCount == 1, @"read through m1: one left");
    [store recountUnreadInConversation:@"mei" readThroughDate:nil itemID:nil error:NULL];
    SZFTExpect([store personWithConversationID:@"mei"].unreadCount == 3, @"no marker: every incoming one");
}

static void TestOutboxAndReset(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"sync-outbox"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsOutboxEntry *entry = [[SZFriendsOutboxEntry alloc] init];
    entry.entryID = @"e1";
    entry.conversationID = @"mei";
    entry.kind = SZFriendsOutboxKindMessage;
    entry.state = SZFriendsOutboxStateSending;
    entry.itemID = @"m1";
    entry.createdAt = [NSDate dateWithTimeIntervalSince1970:1000];
    SZFTExpect([store mergeSyncedOutboxEntry:entry error:NULL], @"merged");
    SZFTExpect([[[SZFriendsOutbox alloc] initWithStore:store] entryWithID:@"e1"].state == SZFriendsOutboxStateQueued,
               @"another device's session is not ours: it waits here as queued");
    entry.kind = SZFriendsOutboxKindOffer;
    entry.entryID = @"e2";
    SZFTExpect(![store mergeSyncedOutboxEntry:entry error:NULL], @"file offers never sync");
    [store ensureYouConversation:NULL];
    SZFTExpect([store personWithConversationID:SZFriendsYouConversationID] != nil, @"You exists");
    [store appendSyncEvent:SZFTEvent(SZFTBytes(1, 32), 1, @"x", nil) appended:NULL error:NULL];
    SZFriendsSyncRegister *value = [[SZFriendsSyncRegister alloc] init];
    value.lamport = 3;
    value.author = SZFTBytes(1, 32);
    [store setSyncRegister:value forKey:@"profile" error:NULL];
    SZFTExpect([store deleteEverythingExceptReceivedFilesWithError:NULL], @"reset");
    SZFTExpect([store syncEventCount] == 0 && [store syncRegisterForKey:@"profile"] == nil, @"reset forgets sync");
}

void SZFTRunSyncTests(void) {
    TestMigrationKeepsEverything();
    TestLogIsContiguous();
    TestItemsOriginsAndDeletion();
    TestUnreadFromMarker();
    TestOutboxAndReset();
}
