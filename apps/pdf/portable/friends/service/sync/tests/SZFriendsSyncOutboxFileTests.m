// friends-sync-check: outbox and files across devices. A message written on one device can leave from another (the
// sibling gets the entry queued), delivered is final whoever delivered it, file offers stay with the device holding
// the file; file records reach every device at once with who holds the bytes, small files are wanted at once,
// larger ones only when asked, and files in You whatever their size.

#import "SZFriendsSyncTestSupport.h"

SZFriendsTransferRecord *SZFSStageFile(SZFSDevice *device, NSString *conversation, NSString *itemID, uint64_t size);

SZFriendsTransferRecord *SZFSStageFile(SZFSDevice *device, NSString *conversation, NSString *itemID, uint64_t size) {
    NSString *source = [device.directory stringByAppendingPathComponent:[itemID stringByAppendingString:@".pdf"]];
    [NSFileManager.defaultManager createFileAtPath:source contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:source];
    if (size <= 4 * 1024 * 1024) {
        NSMutableData *bytes = [NSMutableData dataWithLength:(NSUInteger)size];
        for (NSUInteger i = 0; i < bytes.length; i++) ((uint8_t *)bytes.mutableBytes)[i] = (uint8_t)(i * 31 + 7);
        [handle writeData:bytes];
    } else {
        [handle truncateFileAtOffset:size]; // sparse: only its size matters to the policy
    }
    [handle closeFile];
    SZFriendsTransfers *transfers = [[SZFriendsTransfers alloc] initWithStore:device.store
                                                              stateDirectory:device.directory];
    transfers.freeBytesProvider = ^uint64_t(NSString *path) {
        (void)path;
        return 1ull << 40;
    };
    NSError *error = nil;
    SZFriendsTransferRecord *record = [transfers stageOutgoingFileAtPath:source revision:nil
                                                          conversationID:conversation error:&error];
    if (record == nil) {
        fprintf(stderr, "staging failed: %s\n", error.localizedDescription.UTF8String);
        abort();
    }
    SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
    item.itemID = itemID;
    item.conversationID = conversation;
    item.kind = SZFriendsItemKindTransfer;
    item.direction = SZFriendsDirectionOutgoing;
    item.transferID = record.transferID;
    item.sentAt = item.receivedAt = [NSDate dateWithTimeIntervalSince1970:4000];
    [device.store insertItem:item error:NULL];
    return record;
}

SZFriendsOutboxEntry *SZFSQueueMessage(SZFSDevice *device, NSString *conversation, NSString *itemID);

SZFriendsOutboxEntry *SZFSQueueMessage(SZFSDevice *device, NSString *conversation, NSString *itemID) {
    SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
    item.itemID = itemID;
    item.conversationID = conversation;
    item.kind = SZFriendsItemKindMessage;
    item.direction = SZFriendsDirectionOutgoing;
    item.text = @"written on the laptop";
    item.sentAt = item.receivedAt = [NSDate dateWithTimeIntervalSince1970:3000];
    SZFriendsOutboxEntry *entry = [[SZFriendsOutboxEntry alloc] init];
    entry.entryID = [itemID stringByAppendingString:@"-e"];
    entry.conversationID = conversation;
    entry.kind = SZFriendsOutboxKindMessage;
    entry.itemID = itemID;
    entry.createdAt = item.sentAt;
    if (![[[SZFriendsOutbox alloc] initWithStore:device.store] enqueue:entry item:item error:NULL]) abort();
    return entry;
}

static void TestSiblingDelivers(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"sibling", 2);
    SZFSDevice *laptop = devices[0], *desktop = devices[1];
    SZFSAddFriend(laptop, 0x90, @"mei");
    SZFriendsOutboxEntry *entry = SZFSQueueMessage(laptop, @"mei", @"out1");
    SZFSSyncAll(devices);
    // The laptop went to sleep: the desktop has the message queued and delivers it.
    SZFriendsOutbox *desktopOutbox = [[SZFriendsOutbox alloc] initWithStore:desktop.store];
    SZFriendsOutboxEntry *queued = [desktopOutbox entryWithID:entry.entryID];
    SZFSExpect(queued.state == SZFriendsOutboxStateQueued && [queued.itemID isEqualToString:@"out1"],
               @"queued on the sibling: %@", queued);
    SZFSExpect([desktopOutbox pendingEntriesForConversation:@"mei"].count == 1, @"the sibling's delivery sees it");
    [desktopOutbox applyEvent:SZFriendsOutboxEventWritten toEntry:entry.entryID error:NULL];
    // Meanwhile the laptop wakes, gives up on its copy (expired), before hearing anything.
    SZFriendsOutbox *laptopOutbox = [[SZFriendsOutbox alloc] initWithStore:laptop.store];
    [laptopOutbox applyEvent:SZFriendsOutboxEventExpired toEntry:entry.entryID error:NULL];
    [laptop.engine captureLocalChanges];
    [desktopOutbox applyEvent:SZFriendsOutboxEventAcknowledged toEntry:entry.entryID error:NULL];
    SZFSSyncAll(devices);
    SZFSExpect([laptopOutbox entryWithID:entry.entryID].state == SZFriendsOutboxStateDelivered &&
                   [desktopOutbox entryWithID:entry.entryID].state == SZFriendsOutboxStateDelivered,
               @"delivered wins over failed, whatever the clocks");
    SZFSExpect([SZFSDump(laptop) isEqualToString:SZFSDump(desktop)], @"converged:\n%@\n---\n%@", SZFSDump(laptop),
               SZFSDump(desktop));
}

static void TestFileRecordsAndPolicy(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"files", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    SZFSAddFriend(a, 0x90, @"mei");
    [a.store ensureYouConversation:NULL];
    SZFriendsTransferRecord *small = SZFSStageFile(a, @"mei", @"f1", 200 * 1024);
    SZFriendsTransferRecord *large = SZFSStageFile(a, @"mei", @"f2", 25000001);
    SZFriendsTransferRecord *mine = SZFSStageFile(a, SZFriendsYouConversationID, @"f3", 30000000);
    SZFriendsOutboxEntry *offer = [[SZFriendsOutboxEntry alloc] init];
    offer.entryID = @"offer1";
    offer.conversationID = @"mei";
    offer.kind = SZFriendsOutboxKindOffer;
    offer.itemID = small.transferID;
    [[[SZFriendsOutbox alloc] initWithStore:a.store] enqueue:offer error:NULL];
    SZFSSyncAll(devices);
    SZFriendsSyncFileRecord *record = [b.store syncFileWithID:small.transferID];
    SZFSExpect(record != nil && [record.holders containsObject:a.identity.publicKey] && record.size == 200 * 1024,
               @"the record arrives at once with who holds the bytes");
    SZFSExpect([b.store itemWithID:@"f1" inConversation:@"mei"].transferID != nil, @"the history row too");
    SZFSExpect([b.store itemWithID:@"f3" inConversation:SZFriendsYouConversationID] != nil, @"You is on every device");
    NSMutableArray<NSString *> *wanted = [NSMutableArray array];
    for (SZFriendsSyncFileRecord *file in [b.engine filesWanted]) [wanted addObject:file.transferID];
    SZFSExpect([wanted containsObject:small.transferID] && [wanted containsObject:mine.transferID] &&
                   ![wanted containsObject:large.transferID],
               @"small and You files copy by themselves, a large one waits: %@", wanted);
    SZFSExpect([b.engine requestFile:large.transferID error:NULL], @"Get");
    SZFSExpect([[b.engine filesWanted].firstObject.transferID isEqualToString:large.transferID],
               @"asked for comes first");
    SZFSExpect([a.engine filesWanted].count == 0, @"A holds them all");
    SZFSExpect([b.store syncableOutboxEntries].count == 0, @"file offers stay with the device holding the file");
}

static void TestOversizedStaysHere(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"oversized", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFriendsOutboxEntry *entry = [[SZFriendsOutboxEntry alloc] init];
    entry.entryID = @"big";
    entry.conversationID = @"mei";
    entry.kind = SZFriendsOutboxKindRequest;
    entry.payload = [NSMutableData dataWithLength:SZFriendsSyncBodyMax + 1];
    [[[SZFriendsOutbox alloc] initWithStore:a.store] enqueue:entry error:NULL];
    SZFriendsOutboxEntry *small = SZFSQueueMessage(a, @"mei", @"m1");
    SZFSSyncAll(devices);
    SZFSExpect([[[SZFriendsOutbox alloc] initWithStore:b.store] entryWithID:small.entryID] != nil,
               @"a value too large for an event holds nothing else back");
    SZFSExpect([[[SZFriendsOutbox alloc] initWithStore:b.store] entryWithID:@"big"] == nil, @"and stays where it is");
}

void SZFSRunOutboxFileTests(void) {
    TestSiblingDelivers();
    TestOversizedStaysHere();
    TestFileRecordsAndPolicy();
}
