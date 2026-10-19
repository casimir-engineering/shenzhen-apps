// friends-sync-check: "Erase chat history" on one device erases it on every device. A deletion takes exactly what the
// deleting device had (a message that reached another device meanwhile stays), wins over every copy of what it took
// (a copy arriving later stays deleted, whichever device it comes from), drops the text from every device's log and
// file, and erasing all history covers every conversation.

#import "SZFriendsSyncTestSupport.h"

static BOOL SZFSFileContains(NSString *path, NSData *needle) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data != nil && [data rangeOfData:needle options:0 range:NSMakeRange(0, data.length)].location != NSNotFound;
}

// Every file the store keeps in the device's state directory (the database and its journal among them).
static BOOL SZFSStoreFilesContain(SZFSDevice *device, NSString *text) {
    NSData *needle = [text dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:device.directory error:NULL]) {
        if (SZFSFileContains([device.directory stringByAppendingPathComponent:name], needle)) return YES;
    }
    return NO;
}

static void TestDeletionTakesWhatItSaw(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"tomb", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFSAddFriend(a, 0x91, @"lin");
    SZFSInsertMessage(a, @"mei", @"m1", @"secret contract terms", SZFriendsDirectionIncoming, 1000);
    SZFSInsertMessage(a, @"mei", @"m2", @"second message", SZFriendsDirectionOutgoing, 1001);
    SZFSInsertMessage(a, @"lin", @"l1", @"other chat", SZFriendsDirectionIncoming, 1002);
    SZFSSyncAll(devices);
    // While apart: a new message reaches B, and A erases the chat.
    SZFSInsertMessage(b, @"mei", @"m3", @"arrived on B meanwhile", SZFriendsDirectionIncoming, 1003);
    [b.engine captureLocalChanges];
    SZFSExpect([a.engine deleteHistoryInConversation:@"mei" error:NULL], @"erased on A");
    SZFSExpect([a.store itemWithID:@"m1" inConversation:@"mei"] == nil, @"gone on A at once");
    SZFSSyncAll(devices);
    for (SZFSDevice *device in devices) {
        SZFSExpect([device.store itemWithID:@"m1" inConversation:@"mei"] == nil &&
                       [device.store itemWithID:@"m2" inConversation:@"mei"] == nil,
                   @"what A had is gone on %@", device.name);
        SZFSExpect([device.store itemWithID:@"m3" inConversation:@"mei"] != nil,
                   @"what A had not seen stays on %@", device.name);
        SZFSExpect([device.store itemWithID:@"l1" inConversation:@"lin"] != nil, @"other chats stay on %@",
                   device.name);
        SZFSExpect(!SZFSStoreFilesContain(device, @"secret contract terms"), @"the text is gone from %@'s files",
                   device.name);
    }
    SZFSExpect([SZFSDump(a) isEqualToString:SZFSDump(c)], @"converged:\n%@\n---\n%@", SZFSDump(a), SZFSDump(c));
    SZFSExpect([a.store personWithConversationID:@"mei"].unreadCount == 1, @"m3 still unread");
}

static void TestLateCopiesStayDeleted(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"late", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFSSyncAll(devices);
    // The friend delivered m1 to A and to B; neither has heard of the other's copy when A erases.
    SZFSInsertMessage(a, @"mei", @"m1", @"twice delivered", SZFriendsDirectionIncoming, 2000);
    SZFSInsertMessage(b, @"mei", @"m1", @"twice delivered", SZFriendsDirectionIncoming, 2001);
    [b.engine captureLocalChanges];
    SZFSExpect([a.engine deleteHistoryInConversation:@"mei" error:NULL], @"erased on A");
    // C hears the deletion first, then B's copy, then A's: none of them brings it back.
    SZFSDeliver(a, c);
    SZFSDeliver(b, c);
    SZFSSyncAll(devices);
    for (SZFSDevice *device in devices) {
        SZFSExpect([device.store itemWithID:@"m1" inConversation:@"mei"] == nil, @"m1 stays deleted on %@",
                   device.name);
    }
    SZFSExpect([SZFSDump(a) isEqualToString:SZFSDump(b)], @"converged:\n%@\n---\n%@", SZFSDump(a), SZFSDump(b));
    // B's copy of the event that carried m1 lost its body too.
    SZFriendsSyncLogEvent *carried = nil;
    for (SZFriendsSyncLogEvent *event in [c.store syncEventsOfKind:SZFriendsSyncKindItem]) {
        if ([event.subject isEqualToString:@"m1"] && [event.author isEqualToData:b.identity.publicKey]) carried = event;
    }
    SZFSExpect(carried != nil && carried.body == nil, @"the copy's body is dropped where it landed");
}

static void TestEraseEverything(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"all", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFSAddFriend(a, 0x91, @"lin");
    SZFSInsertMessage(a, @"mei", @"m1", @"one", SZFriendsDirectionIncoming, 1000);
    SZFSInsertMessage(a, @"lin", @"l1", @"two", SZFriendsDirectionIncoming, 1001);
    SZFSSyncAll(devices);
    SZFSExpect([b.engine deleteHistoryInConversation:nil error:NULL], @"erase all on B");
    SZFSInsertMessage(a, @"lin", @"l2", @"after", SZFriendsDirectionIncoming, 1002);
    SZFSSyncAll(devices);
    for (SZFSDevice *device in devices) {
        SZFSExpect([device.store itemWithID:@"m1" inConversation:@"mei"] == nil &&
                       [device.store itemWithID:@"l1" inConversation:@"lin"] == nil,
                   @"every chat erased on %@", device.name);
        SZFSExpect([device.store itemWithID:@"l2" inConversation:@"lin"] != nil, @"later messages stay on %@",
                   device.name);
        SZFSExpect([device.store personWithConversationID:@"mei"] != nil, @"friends stay on %@", device.name);
    }
    SZFSExpect([SZFSDump(a) isEqualToString:SZFSDump(b)], @"converged:\n%@\n---\n%@", SZFSDump(a), SZFSDump(b));
}

static void TestDeletionBeforeTheMessages(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"first", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFSInsertMessage(a, @"mei", @"m1", @"never on C", SZFriendsDirectionIncoming, 1000);
    SZFSSyncAll(@[ a, b ]);
    SZFSExpect([b.engine deleteHistoryInConversation:@"mei" error:NULL], @"erased on B");
    // C first hears B (which holds the deletion and A's events with their bodies dropped), then A itself.
    SZFSDeliver(b, c);
    SZFSDeliver(a, c);
    SZFSExpect([c.store itemWithID:@"m1" inConversation:@"mei"] == nil, @"never appears on C");
    SZFSExpect(!SZFSStoreFilesContain(c, @"never on C"), @"and its text was never written there");
}

void SZFSRunDeletionTests(void) {
    TestDeletionTakesWhatItSaw();
    TestLateCopiesStayDeleted();
    TestEraseEverything();
    TestDeletionBeforeTheMessages();
}
