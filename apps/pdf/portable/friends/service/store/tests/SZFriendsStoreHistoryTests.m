// History: idempotent inserts, ordering, windows, read marks, and the delete actions.

#import <sys/stat.h>

#import "SZFriendsStoreTestSupport.h"

static NSArray<NSString *> *ItemIDs(NSArray<SZFriendsItemRecord *> *items) { return [items valueForKey:@"itemID"]; }

static void TestInsertIsIdempotentBySenderAndID(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"dedupe"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsItemRecord *item = SZFTMessage(@"mei", @"0123456789abcdef0123456789abcdef", @"hello", 2000,
                                            SZFriendsDirectionIncoming);
    SZFTExpect([store insertItem:item error:NULL], @"first delivery");
    SZFTExpect([store insertItem:item error:NULL], @"a redelivery after a lost ACK is acknowledged again");
    SZFriendsItemRecord *echo = [item copy];
    echo.direction = SZFriendsDirectionOutgoing;
    echo.text = @"different";
    SZFTExpect([store insertItem:echo error:NULL], @"an id already in the conversation names that item");
    BOOL earlier = YES;
    NSArray *items = [store itemsInConversation:@"mei" beforeItemID:nil limit:10 hasEarlier:&earlier];
    SZFTExpect(items.count == 1 && !earlier, @"one item, got %lu", (unsigned long)items.count);
    SZFTExpect([[items.firstObject text] isEqualToString:@"hello"], @"the first copy stays");
    SZFTExpect([store personWithConversationID:@"mei"].unreadCount == 1, @"counted unread once");
    NSError *error = nil;
    SZFTExpect(![store insertItem:SZFTMessage(@"nobody", @"x1", @"?", 1, SZFriendsDirectionIncoming) error:&error] &&
                   error.code == SZFriendsStoreErrorNotFound, @"unknown conversation");
    SZFTExpect(![store insertItem:SZFTMessage(@"mei", @"bad id", @"?", 1, SZFriendsDirectionIncoming) error:&error] &&
                   error.code == SZFriendsStoreErrorInvalid, @"bad item id");
}

static void TestSenderClockIsClamped(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"clamp"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsItemRecord *fast = SZFTMessage(@"mei", @"fast", @"from the future", 9000, SZFriendsDirectionIncoming);
    fast.receivedAt = [NSDate dateWithTimeIntervalSince1970:5000];
    [store insertItem:fast error:NULL];
    SZFriendsItemRecord *mine = SZFTMessage(@"mei", @"mine", @"mine", 6000, SZFriendsDirectionOutgoing);
    [store insertItem:mine error:NULL];
    NSArray<SZFriendsItemRecord *> *items = [store itemsInConversation:@"mei" beforeItemID:nil limit:10
                                                            hasEarlier:NULL];
    SZFTExpect([ItemIDs(items) isEqual:(@[ @"fast", @"mine" ])], @"order %@", ItemIDs(items));
    SZFTExpect(items.firstObject.sentAt.timeIntervalSince1970 == 5000, @"clamped to receipt: %@",
               items.firstObject.sentAt);
    SZFTExpect([store personWithConversationID:@"mei"].lastInteractionAt.timeIntervalSince1970 == 6000,
               @"latest interaction follows new items");
}

static void TestWindowsAndOrder(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"windows"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    // Two items share a timestamp: display order is sender time, then id.
    NSArray *times = @[ @100, @200, @300, @300, @400, @500, @600 ];
    NSArray *ids = @[ @"a", @"b", @"d", @"c", @"e", @"f", @"g" ];
    for (NSUInteger i = 0; i < ids.count; i++) {
        [store insertItem:SZFTMessage(@"mei", ids[i], ids[i], [times[i] doubleValue], SZFriendsDirectionOutgoing)
                    error:NULL];
    }
    BOOL earlier = NO;
    NSArray *newest = [store itemsInConversation:@"mei" beforeItemID:nil limit:3 hasEarlier:&earlier];
    SZFTExpect([ItemIDs(newest) isEqual:(@[ @"e", @"f", @"g" ])] && earlier, @"newest window %@", ItemIDs(newest));
    NSArray *before = [store itemsInConversation:@"mei" beforeItemID:@"e" limit:3 hasEarlier:&earlier];
    SZFTExpect([ItemIDs(before) isEqual:(@[ @"c", @"d", @"e" ])] && earlier, @"window ending at e %@", ItemIDs(before));
    NSArray *start = [store itemsInConversation:@"mei" beforeItemID:@"b" limit:5 hasEarlier:&earlier];
    SZFTExpect([ItemIDs(start) isEqual:(@[ @"a", @"b" ])] && !earlier, @"start %@", ItemIDs(start));
    SZFTExpect([store itemsInConversation:@"mei" beforeItemID:@"zz" limit:5 hasEarlier:&earlier].count == 0,
               @"unknown anchor");
    NSArray *around = [store itemsInConversation:@"mei" aroundItemID:@"d" before:2 after:2];
    SZFTExpect([ItemIDs(around) isEqual:(@[ @"b", @"c", @"d", @"e", @"f" ])], @"around %@", ItemIDs(around));
    NSArray *edge = [store itemsInConversation:@"mei" aroundItemID:@"a" before:3 after:1];
    SZFTExpect([ItemIDs(edge) isEqual:(@[ @"a", @"b" ])], @"around the first %@", ItemIDs(edge));
    SZFTExpect(![store itemsInConversation:@"mei" aroundItemID:@"nope" before:1 after:1], @"unknown item");
    SZFTExpect([[store itemWithID:@"d" inConversation:@"mei"].text isEqualToString:@"d"], @"one item by id");
    SZFTExpect(![store itemWithID:@"d" inConversation:@"priya"] && ![store itemWithID:@"nope" inConversation:@"mei"],
               @"only in its own conversation");
}

static void TestEventsTransfersAndReadMarks(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"events"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsItemRecord *event = SZFTMessage(@"mei", @"ev1", @"ignored", 100, SZFriendsDirectionIncoming);
    event.kind = SZFriendsItemKindEvent;
    event.eventKind = @"key_changed";
    event.eventArguments = @{@"name" : @"Mei"};
    [store insertItem:event error:NULL];
    SZFriendsItemRecord *read = [store itemsInConversation:@"mei" beforeItemID:nil limit:5 hasEarlier:NULL].firstObject;
    SZFTExpect([read.eventKind isEqualToString:@"key_changed"] && [read.eventArguments isEqual:@{@"name" : @"Mei"}] &&
                   !read.text && read.outboxState == -1, @"event round trip");
    SZFTExpect([store personWithConversationID:@"mei"].unreadCount == 0, @"events are not unread messages");
    [store insertItem:SZFTMessage(@"mei", @"m1", @"hi", 200, SZFriendsDirectionIncoming) error:NULL];
    SZFTExpect([store markConversationRead:@"mei" error:NULL] && [store
        personWithConversationID:@"mei"].unreadCount == 0,
               @"read");
}

static NSArray<NSString *> *DatabaseFiles(SZFriendsStore *store) {
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:store.stateDirectory error:NULL]) {
        if ([name hasPrefix:@"friends.sqlite"]) [files addObject:[store.stateDirectory
            stringByAppendingPathComponent:name]];
    }
    return files;
}

static void PlantTransferFiles(SZFriendsStore *store, NSString *conversationID, NSString *transferID,
                               NSString **outgoingPath, NSString **partialPath) {
    NSString *outgoing = [store.stateDirectory stringByAppendingPathComponent:@"outgoing"];
    NSString *partial = [store.stateDirectory stringByAppendingPathComponent:@"received/.partial"];
    [NSFileManager.defaultManager createDirectoryAtPath:outgoing withIntermediateDirectories:YES attributes:nil
        error:NULL];
    [NSFileManager.defaultManager createDirectoryAtPath:partial withIntermediateDirectories:YES attributes:nil
        error:NULL];
    *outgoingPath = [outgoing stringByAppendingPathComponent:transferID];
    *partialPath = [partial stringByAppendingPathComponent:[transferID stringByAppendingString:@".part"]];
    [[@"snapshot" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:*outgoingPath atomically:NO];
    [[@"partial" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:*partialPath atomically:NO];
    SZFriendsTransferRecord *record = [[SZFriendsTransferRecord alloc] init];
    record.transferID = transferID;
    record.conversationID = conversationID;
    record.outgoing = YES;
    record.fileName = @"Secret plan.pdf";
    record.size = 8;
    record.contentDigest = SZFTBytes(3, 32);
    record.stagedPath = *outgoingPath;
    NSString *partialCopy = *partialPath;
    [store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **error) {
        return SZFriendsTransferRowInsert(db, record, partialCopy, error);
    } error:NULL];
}

static void TestDeleteHistoryLeavesNoTrace(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"delete"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFTAddPerson(store, @"priya", 2, SZFriendsRelationFriend, 1000);
    NSString *secret = @"zebra-quartz-sentinel 合同机密条款";
    for (int i = 0; i < 50; i++) {
        NSString *text = [NSString stringWithFormat:@"%@ number %d", secret, i];
        [store insertItem:SZFTMessage(@"mei", [NSString stringWithFormat:@"s%d", i], text, 100 + i,
                                      SZFriendsDirectionIncoming)
                    error:NULL];
    }
    [store insertItem:SZFTMessage(@"priya", @"keep", @"priya keeps this", 300, SZFriendsDirectionIncoming) error:NULL];
    NSString *snapshot = nil, *partial = nil;
    PlantTransferFiles(store, @"mei", @"t1", &snapshot, &partial);
    NSString *received = [store.stateDirectory stringByAppendingPathComponent:@"received/Kept.pdf"];
    [[@"kept" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:received atomically:NO];
    NSString *backup = [store.databasePath stringByAppendingString:@".before-v1"];
    [[secret dataUsingEncoding:NSUTF8StringEncoding] writeToFile:backup atomically:NO];
    SZFTExpect([store searchFor:@"zebra" conversationIDs:nil limit:5].count > 0, @"found before");
    NSError *error = nil;
    SZFTExpect([store deleteHistoryInConversation:@"mei" error:&error], @"delete: %@", error);
    SZFTExpect([store searchFor:@"zebra" conversationIDs:nil limit:5].count == 0, @"not found after");
    SZFTExpect([store searchFor:@"合同" conversationIDs:nil limit:5].count == 0, @"short terms neither");
    SZFTExpect([store itemsInConversation:@"mei" beforeItemID:nil limit:5 hasEarlier:NULL].count == 0, @"items gone");
    SZFTExpect([store itemsInConversation:@"priya" beforeItemID:nil limit:5 hasEarlier:NULL].count == 1,
               @"other conversations untouched");
    SZFTExpect([store personWithConversationID:@"mei"] != nil, @"the friend stays");
    SZFTExpect(![NSFileManager.defaultManager fileExistsAtPath:snapshot] &&
                   ![NSFileManager.defaultManager fileExistsAtPath:partial], @"private copies removed");
    SZFTExpect([NSFileManager.defaultManager fileExistsAtPath:received], @"received files stay");
    SZFTExpect(![NSFileManager.defaultManager fileExistsAtPath:backup], @"backups holding history are removed");
    NSArray *needles = @[ [@"zebra-quartz-sentinel" dataUsingEncoding:NSUTF8StringEncoding],
                          [@"合同机密" dataUsingEncoding:NSUTF8StringEncoding] ];
    for (NSString *file in DatabaseFiles(store)) {
        for (NSData *needle in needles) SZFTExpect(!SZFTFileContains(file, needle), @"%@ still holds deleted text",
            file);
    }
    // Deleted rows leave their trigrams in the index's old segments until a merge, which would keep most of the
    // text recoverable; the index after deleting must be exactly what a rebuild from the remaining rows gives.
    NSString *indexSize = SZFTIndexExpected() ? @"SELECT sum(length(block)) FROM search_data" : @"SELECT 0";
    NSNumber *indexBytes = SZFTScalar(store, indexSize, @[]);
    [store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return SZFriendsStoreRebuildSearch(db, inner);
    } error:NULL];
    NSNumber *rebuiltBytes = SZFTScalar(store, indexSize, @[]);
    SZFTExpect([indexBytes isEqual:rebuiltBytes], @"no index remnants: %@ bytes, %@ after a rebuild", indexBytes,
               rebuiltBytes);
    SZFTExpect([store deleteHistoryInConversation:nil error:&error], @"delete all: %@", error);
    SZFTExpect([store itemsInConversation:@"priya" beforeItemID:nil limit:5 hasEarlier:NULL].count == 0, @"all gone");
}

static void TestResetKeepsReceivedFiles(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"reset"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    [store insertItem:SZFTMessage(@"mei", @"m1", @"hello there", 100, SZFriendsDirectionIncoming) error:NULL];
    store.profileName = @"Raph";
    store.nearbyPermissionsRequested = YES;
    NSString *storeID = SZFTScalar(store, @"SELECT value FROM meta WHERE key = 'store_id'", @[]);
    NSString *pictures = [store.stateDirectory stringByAppendingPathComponent:@"pictures"];
    [NSFileManager.defaultManager createDirectoryAtPath:pictures withIntermediateDirectories:YES attributes:nil
        error:NULL];
    [[@"x" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[pictures stringByAppendingPathComponent:@"a.jpg"]
                                                    atomically:NO];
    NSString *receivedDir = [store.stateDirectory stringByAppendingPathComponent:@"received"];
    [NSFileManager.defaultManager createDirectoryAtPath:receivedDir withIntermediateDirectories:YES attributes:nil
                                                  error:NULL];
    NSString *received = [receivedDir stringByAppendingPathComponent:@"Contract.pdf"];
    [[@"kept" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:received atomically:NO];
    NSError *error = nil;
    SZFTExpect([store deleteEverythingExceptReceivedFilesWithError:&error], @"reset: %@", error);
    SZFTExpect(store.peopleByLatestInteraction.count == 0 && !store.profileName && !store.nearbyPermissionsRequested,
               @"everything else is gone");
    SZFTExpect(![NSFileManager.defaultManager fileExistsAtPath:pictures], @"pictures removed");
    SZFTExpect([NSFileManager.defaultManager fileExistsAtPath:received], @"received files stay");
    NSString *newID = SZFTScalar(store, @"SELECT value FROM meta WHERE key = 'store_id'", @[]);
    SZFTExpect(newID.length && ![newID isEqualToString:storeID], @"a reset store is a new store");
    SZFTAddPerson(store, @"kenji", 4, SZFriendsRelationFriend, 1000);
    SZFTExpect(store.peopleByLatestInteraction.count == 1, @"the store stays usable");
    for (NSString *file in DatabaseFiles(store)) {
        SZFTExpect(!SZFTFileContains(file, [@"hello there" dataUsingEncoding:NSUTF8StringEncoding]), @"%@", file);
    }
}

void SZFTRunHistoryTests(void) {
    TestInsertIsIdempotentBySenderAndID();
    TestSenderClockIsClamped();
    TestWindowsAndOrder();
    TestEventsTransfersAndReadMarks();
    TestDeleteHistoryLeavesNoTrace();
    TestResetKeepsReceivedFiles();
}
