// friends-sync-check: the engine's rules one at a time. Nothing is recorded before another device exists, and then the
// whole history is; messages are a set (a duplicate changes nothing, the same message reaching two devices keeps the
// earliest time); read markers take the maximum; people's field groups, the profile and settings take the later
// clock; events wait for what they need; events from outside our chain, or with a gap, are refused.

#import "SZFriendsSyncTestSupport.h"

#import "avatars/SZFriendsAvatars.h"

static void TestInactiveRecordsNothing(void) {
    SZFSDevice *lone = SZFSLoneDevice(@"lone", 0x21);
    NSString *conversation = SZFSAddFriend(lone, 0x90, nil).conversationID;
    SZFSInsertMessage(lone, conversation, @"m1", @"hi", SZFriendsDirectionIncoming, 1000);
    SZFSExpect(!lone.engine.active && [lone.engine captureLocalChanges] == 0 && [lone.store syncEventCount] == 0,
               @"a single device records nothing");
    NSError *error = nil;
    SZFSExpect(![lone.engine receiveEvents:@[] error:&error] && error.code == SZFriendsSyncErrorInactive,
               @"and takes nothing: %@", error);
    SZFSExpect([lone.engine deleteHistoryInConversation:conversation error:NULL] &&
                   [lone.store itemWithID:@"m1" inConversation:conversation] == nil,
               @"deleting history without sync is the store's own deletion");
}

static void TestBackfillAndDuplicates(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"backfill", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    NSString *conversation = SZFSAddFriend(a, 0x90, @"mei").conversationID;
    SZFSInsertMessage(a, conversation, @"m1", @"早上好", SZFriendsDirectionIncoming, 1000);
    SZFSInsertMessage(a, conversation, @"m2", @"see you", SZFriendsDirectionOutgoing, 1001);
    NSUInteger recorded = [a.engine captureLocalChanges];
    SZFSExpect(recorded >= 4, @"history from before sync becomes events: %lu", (unsigned long)recorded);
    SZFSExpect([a.engine captureLocalChanges] == 0, @"and only once");
    SZFSExpect(SZFSDeliver(a, b), @"delivered");
    SZFSExpect([[b.store personWithConversationID:@"mei"].name isEqualToString:@"Friend 144"],
               @"the friend arrives under the same conversation id");
    SZFSExpect([[b.store itemWithID:@"m1" inConversation:@"mei"].text isEqualToString:@"早上好"], @"message arrives");
    SZFSExpect([SZFSDump(a) isEqualToString:SZFSDump(b)], @"same store:\n%@\n---\n%@", SZFSDump(a), SZFSDump(b));
    // The same events again, as a retry after a lost acknowledgement would bring them: nothing changes.
    NSString *before = SZFSDump(b);
    NSArray<SZFriendsSyncEvent *> *all = [a.engine eventsMissingFrom:@{} limit:1000];
    SZFSExpect([b.engine receiveEvents:all error:NULL], @"duplicates accepted");
    SZFSExpect([before isEqualToString:SZFSDump(b)] && [b.engine captureLocalChanges] == 0,
               @"duplicates change nothing and echo nothing");
}

static void TestSameMessageOnTwoDevices(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"twice", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFSSyncAll(devices);
    // The friend's helper delivered the same message to both, B first.
    SZFSInsertMessage(b, @"mei", @"m1", @"hello", SZFriendsDirectionIncoming, 2000);
    SZFSInsertMessage(a, @"mei", @"m1", @"hello", SZFriendsDirectionIncoming, 2005);
    SZFSSyncAll(devices);
    SZFriendsItemRecord *onA = [a.store itemWithID:@"m1" inConversation:@"mei"];
    SZFSExpect(onA.receivedAt.timeIntervalSince1970 == 2000.25, @"the earliest arrival: %f",
               onA.receivedAt.timeIntervalSince1970);
    SZFSExpect([SZFSDump(a) isEqualToString:SZFSDump(b)], @"same store:\n%@\n---\n%@", SZFSDump(a), SZFSDump(b));
    SZFSExpect([b.store personWithConversationID:@"mei"].unreadCount == 1, @"one unread message, not two");
}

static void TestReadMarkers(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"read", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFSInsertMessage(a, @"mei", @"m1", @"one", SZFriendsDirectionIncoming, 1000);
    SZFSInsertMessage(a, @"mei", @"m2", @"two", SZFriendsDirectionIncoming, 1001);
    SZFSSyncAll(devices);
    SZFSExpect([b.store personWithConversationID:@"mei"].unreadCount == 2, @"unread on both");
    [a.store markConversationRead:@"mei" error:NULL];
    // Meanwhile a third message reaches B only.
    SZFSInsertMessage(b, @"mei", @"m3", @"three", SZFriendsDirectionIncoming, 1002);
    SZFSSyncAll(devices);
    SZFSExpect([a.store personWithConversationID:@"mei"].unreadCount == 1 &&
                   [b.store personWithConversationID:@"mei"].unreadCount == 1,
               @"read on A up to m2; m3 is still new on both");
    [b.store markConversationRead:@"mei" error:NULL];
    SZFSSyncAll(devices);
    SZFSExpect([a.store personWithConversationID:@"mei"].unreadCount == 0, @"read on B, read on A");
    // An older marker arriving late does not move it back.
    SZFriendsSyncRegister *marker = [a.store syncRegisterForKey:SZFriendsSyncReadKey(@"mei")];
    SZFriendsSyncFields *fields = [SZFriendsSyncFields fieldsWithData:marker.value];
    SZFSExpect([[fields stringForTag:3] isEqualToString:@"m3"], @"the maximum");
}

static void TestLastWriterWins(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"lww", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFSSyncAll(devices);
    // Apart: A blocks, B removes, C turns automatic acceptance on and renames.
    SZFriendsPersonRecord *onA = [a.store personWithConversationID:@"mei"];
    onA.relation = SZFriendsRelationBlocked;
    [a.store savePerson:onA error:NULL];
    [a.engine captureLocalChanges];
    SZFriendsPersonRecord *onB = [b.store personWithConversationID:@"mei"];
    onB.relation = SZFriendsRelationRemoved;
    [b.store savePerson:onB error:NULL];
    [b.engine captureLocalChanges];
    [b.engine captureLocalChanges];
    SZFriendsPersonRecord *onC = [c.store personWithConversationID:@"mei"];
    onC.autoAccept = YES;
    onC.name = @"Mei Lin";
    [c.store savePerson:onC error:NULL];
    [c.engine captureLocalChanges];
    SZFSSyncAll(devices);
    NSString *dump = SZFSDump(a);
    SZFSExpect([dump isEqualToString:SZFSDump(b)] && [dump isEqualToString:SZFSDump(c)], @"converged:\n%@\n%@\n%@",
               dump, SZFSDump(b), SZFSDump(c));
    SZFriendsPersonRecord *now = [a.store personWithConversationID:@"mei"];
    SZFSExpect([now.name isEqualToString:@"Mei Lin"], @"a change to another group survives the relation's");
    SZFSExpect(now.relation == SZFriendsRelationBlocked || now.relation == SZFriendsRelationRemoved, @"one wins");
}

static void TestProfileAndSettings(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"profile", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    a.store.profileName = @"Raph";
    a.store.profilePicture = [SZFriendsPicture animalWithSet:1 index:7];
    NSMutableData *secret = [NSMutableData dataWithLength:32];
    memset(secret.mutableBytes, 0x77, 32);
    a.store.ownPresenceSecret = secret;
    SZFSSyncAll(devices);
    SZFSExpect([b.store.profileName isEqualToString:@"Raph"] && b.store.profilePicture.animalIndex == 7,
               @"name and picture on every device");
    SZFSExpect([b.store.ownPresenceSecret isEqualToData:secret], @"friends find any device by one presence secret");
    SZFSExpect([b.engine ownDevicesSecret] != nil && [[a.engine ownDevicesSecret] isEqual:[b.engine ownDevicesSecret]],
               @"one own-devices secret");
    SZFSExpect(![[a.engine ownDevicesSecret] isEqualToData:secret], @"apart from the friends' one");
    b.store.profileName = @"Raphaël";
    SZFSSyncAll(devices);
    SZFSExpect([a.store.profileName isEqualToString:@"Raphaël"], @"the later change wins everywhere");
}

static void TestWaitsForWhatItNeeds(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"wait", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    SZFSAddFriend(a, 0x90, @"mei");
    [a.engine captureLocalChanges];
    SZFSDeliver(a, b);
    SZFSInsertMessage(b, @"mei", @"m1", @"from B", SZFriendsDirectionOutgoing, 3000);
    [b.engine captureLocalChanges];
    // C hears B's message before A's friend: it waits, then applies.
    NSArray<SZFriendsSyncEvent *> *fromB = [b.engine eventsMissingFrom:@{a.identity.publicKey : @1000} limit:100];
    SZFSExpect([c.engine receiveEvents:fromB error:NULL], @"taken");
    SZFSExpect([c.store itemWithID:@"m1" inConversation:@"mei"] == nil && [c.store unappliedSyncEvents].count > 0,
               @"the message waits for its conversation");
    SZFSDeliver(a, c);
    SZFSExpect([[c.store itemWithID:@"m1" inConversation:@"mei"].text isEqualToString:@"from B"], @"then applies");
    SZFSExpect([c.store unappliedSyncEvents].count == 0, @"nothing left waiting");
}

static void TestRefusals(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"refuse", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    NSData *root = a.engine.rootKey;
    SZFriendsIdentity *outsider = SZFSIdentity(0x66);
    SZFriendsSyncEvent *foreign = [SZFriendsSyncEvent eventSignedBy:outsider rootKey:root kind:SZFriendsSyncKindProfile
                                                                seq:1 lamport:1 date:[NSDate date] scope:@""
                                                            subject:@"" body:[NSData data]];
    NSError *error = nil;
    SZFSExpect(![b.engine receiveEvents:@[ foreign ] error:&error] && error.code == SZFriendsSyncErrorUnauthorized,
               @"a device outside our chain: %@", error);
    a.store.profileName = @"one";
    [a.engine captureLocalChanges];
    a.store.profileName = @"two";
    [a.engine captureLocalChanges];
    NSArray<SZFriendsSyncEvent *> *events = [a.engine eventsMissingFrom:@{} limit:100];
    SZFSExpect(![b.engine receiveEvents:@[ events.lastObject ] error:&error] &&
                   error.code == SZFriendsSyncErrorOutOfOrder,
               @"a gap: %@", error);
    SZFSExpect([b.store syncVector][a.identity.publicKey] == nil && [b.store syncVector][outsider.publicKey] == nil,
               @"nothing of theirs stored");
}

static void TestChainTravels(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"chain", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    SZFSSyncAll(devices);
    SZFriendsDeviceChain *revoked = [a.store.ownDeviceChain chainByRevokingDeviceKey:c.identity.publicKey
                                                                            signedBy:a.identity date:[NSDate date]
                                                                               error:NULL];
    [a.store mergeOwnDeviceChain:revoked error:NULL];
    [a.engine captureLocalChanges];
    SZFSDeliver(a, b);
    SZFSExpect([b.store.ownDeviceChain revokesDeviceKey:c.identity.publicKey], @"a revocation reaches B as an event");
    SZFSExpect(![b.engine.otherDeviceKeys containsObject:c.identity.publicKey], @"and C is not ours any more");
}

// Taking someone off the list travels with their relation (tag 6): it reaches every device, a body for anyone never
// taken off carries no tag 6 (what older helpers wrote), and a later request from them brings them back everywhere.
static void TestLeavingTheListTravels(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"left", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFSSyncAll(devices);
    NSString *key = SZFriendsSyncPersonKey(@"mei", SZFriendsSyncGroupRelation);
    SZFriendsSyncFields *before = [SZFriendsSyncFields fieldsWithData:[b.store syncRegisterForKey:key].value];
    SZFSExpect(before && ![before hasTag:6], @"a friend's relation body has no tag 6");
    SZFriendsPersonRecord *onA = [a.store personWithConversationID:@"mei"];
    onA.relation = SZFriendsRelationRemoved;
    onA.leftListAt = [NSDate dateWithTimeIntervalSince1970:3000];
    [a.store savePerson:onA error:NULL];
    [a.engine captureLocalChanges];
    SZFSSyncAll(devices);
    SZFriendsPersonRecord *onB = [b.store personWithConversationID:@"mei"];
    SZFSExpect(onB.relation == SZFriendsRelationRemoved && onB.leftListAt.timeIntervalSince1970 == 3000,
               @"off B's list too: %ld %@", (long)onB.relation, onB.leftListAt);
    SZFSExpect([SZFSDump(a) isEqualToString:SZFSDump(b)], @"same store:\n%@\n---\n%@", SZFSDump(a), SZFSDump(b));
    // A new request from her reaches B first and brings her back on both.
    onB.relation = SZFriendsRelationIncomingRequest;
    onB.requestAt = [NSDate dateWithTimeIntervalSince1970:4000];
    [b.store savePerson:onB error:NULL];
    [b.engine captureLocalChanges];
    SZFSSyncAll(devices);
    onA = [a.store personWithConversationID:@"mei"];
    SZFSExpect(onA.relation == SZFriendsRelationIncomingRequest && onA.leftListAt == nil &&
                   [b.store personWithConversationID:@"mei"].leftListAt == nil,
               @"back on both lists: %ld %@", (long)onA.relation, onA.leftListAt);
    SZFriendsSyncFields *after = [SZFriendsSyncFields fieldsWithData:[a.store syncRegisterForKey:key].value];
    SZFSExpect(after && ![after hasTag:6], @"and the body drops tag 6 again");
    SZFSExpect([SZFSDump(a) isEqualToString:SZFSDump(b)], @"same store:\n%@\n---\n%@", SZFSDump(a), SZFSDump(b));
}

void SZFSRunEngineTests(void) {
    TestLeavingTheListTravels();
    TestInactiveRecordsNothing();
    TestBackfillAndDuplicates();
    TestSameMessageOnTwoDevices();
    TestReadMarkers();
    TestLastWriterWins();
    TestProfileAndSettings();
    TestWaitsForWhatItNeeds();
    TestRefusals();
    TestChainTravels();
}
