// friends-sync-check: what a removed computer, a device with a runaway clock and a deletion claiming too much can still
// do to the person's other computers. A revoked device's events count only as far as the device that revoked it held
// them, and what reached a device before the removal goes when the removal's record does (keeping a change made there
// meanwhile, and telling the views when the profile changes); a void device's events are left out; an event far
// ahead of our clock is refused; a deletion takes only what its device could have seen; the Friends ID never travels
// by sync; after a revocation the first authorized device draws new secrets for the others, or the next one when the
// first is away; and a removed device stops syncing for that reason.

#import "SZFriendsSyncTestSupport.h"

SZFriendsOutboxEntry *SZFSQueueMessage(SZFSDevice *device, NSString *conversation, NSString *itemID);
SZFriendsTransferRecord *SZFSStageFile(SZFSDevice *device, NSString *conversation, NSString *itemID, uint64_t size);

static SZFriendsDeviceChain *Revoke(SZFSDevice *by, SZFSDevice *revoked) {
    SZFriendsDeviceChain *chain = [by.store.ownDeviceChain chainByRevokingDeviceKey:revoked.identity.publicKey
                                                                           signedBy:by.identity
                                                                               date:[NSDate date]
                                                                              error:NULL];
    SZFSExpect(chain != nil && [by.store mergeOwnDeviceChain:chain error:NULL] == SZFriendsChainMergeChanged,
               @"%@ revokes %@", by.name, revoked.name);
    return chain;
}

static SZFriendsSyncEvent *Forged(SZFSDevice *author, SZFSDevice *holder, SZFriendsSyncKind kind, uint64_t lamport,
                                  NSString *scope, NSData *body) {
    uint64_t seq = [[holder.store syncVector][author.identity.publicKey] unsignedLongLongValue] + 1;
    return [SZFriendsSyncEvent eventSignedBy:author.identity rootKey:holder.engine.rootKey kind:kind seq:seq
                                     lamport:lamport date:[NSDate date] scope:scope subject:@"" body:body];
}

static void TestRevokedDeviceCountsUntilRemoved(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"revoked", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFSSyncAll(devices);
    SZFSInsertMessage(c, @"mei", @"c1", @"written before its removal", SZFriendsDirectionOutgoing, 4000);
    [c.engine captureLocalChanges];
    SZFSExpect(SZFSDeliver(c, a), @"A has C's message");
    Revoke(a, c);
    SZFSExpect([a.engine recordRevocationOfDeviceKey:c.identity.publicKey error:NULL], @"A records what it held of C");
    // The stolen computer keeps writing.
    SZFSInsertMessage(c, @"mei", @"c2", @"written after its removal", SZFriendsDirectionOutgoing, 4001);
    [c.engine captureLocalChanges];
    SZFSExpect(SZFSDeliver(a, b), @"B hears the revocation");
    SZFSExpect([b.store.ownDeviceChain revokesDeviceKey:c.identity.publicKey], @"C is revoked on B");
    SZFSExpect(SZFSDeliver(c, b), @"what C sends is no reason to end the exchange");
    SZFSExpect([b.store itemWithID:@"c1" inConversation:@"mei"] != nil, @"what A held of C counts");
    SZFSExpect([b.store itemWithID:@"c2" inConversation:@"mei"] == nil, @"what C wrote after its removal does not");
    // The same through A: A never takes it either.
    SZFSExpect(SZFSDeliver(c, a) && [a.store itemWithID:@"c2" inConversation:@"mei"] == nil, @"nor on A");
}

// B heard the stolen computer's late events before it heard of the removal: when the removal's record reaches B, they
// go, as erased history goes, and the values they wrote fall back to what the events left say.
static void TestLateEventsDroppedEverywhere(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"late", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    SZFSAddFriend(a, 0x90, @"mei");
    a.store.profileName = @"Raph";
    [a.engine captureLocalChanges];
    SZFSSyncAll(devices);
    Revoke(a, c);
    SZFSExpect([a.engine recordRevocationOfDeviceKey:c.identity.publicKey error:NULL], @"A records what it held of C");
    // The stolen computer writes on; B, which has not heard of the removal, takes it.
    SZFSInsertMessage(c, @"mei", @"late", @"written after its removal", SZFriendsDirectionOutgoing, 4100);
    c.store.profileName = @"Thief";
    [c.engine captureLocalChanges];
    SZFSExpect(SZFSDeliver(c, b), @"B takes C's events");
    SZFSExpect([b.store itemWithID:@"late" inConversation:@"mei"] != nil && [b.store.profileName isEqual:@"Thief"],
               @"for now B shows them");
    SZFSExpect(SZFSDeliver(a, b), @"the removal and its record reach B");
    SZFSExpect([b.store itemWithID:@"late" inConversation:@"mei"] == nil, @"the late message goes from B");
    SZFSExpect([b.store.profileName isEqualToString:@"Raph"], @"the name falls back: %@", b.store.profileName);
    SZFSExpect([[b.store syncVector][c.identity.publicKey] isEqual:[a.store syncVector][c.identity.publicKey]],
               @"B holds of C what A held");
    SZFSExpect(SZFSDeliver(b, a) && [a.store itemWithID:@"late" inConversation:@"mei"] == nil, @"nothing reaches A");
    SZFSSyncAll(@[ a, b ]);
    SZFSExpect([SZFSDump(a) isEqualToString:SZFSDump(b)], @"A and B hold the same");
}

// The late events were the only ones to write a value (the name, a read marker): on B it goes back to never written,
// as on A, which never had them, and B sends nothing for it.
static void TestLateOnlyWriterCleared(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"alone", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFSInsertMessage(a, @"mei", @"m1", @"unread everywhere", SZFriendsDirectionIncoming, 4200);
    SZFSSyncAll(devices);
    Revoke(a, c);
    SZFSExpect([a.engine recordRevocationOfDeviceKey:c.identity.publicKey error:NULL], @"A records what it held of C");
    c.store.profileName = @"Thief";
    [c.store markConversationRead:SZFSConversation(c, 0x90) error:NULL];
    [c.engine captureLocalChanges];
    NSString *mei = SZFSConversation(b, 0x90);
    SZFSExpect(SZFSDeliver(c, b), @"B takes C's events");
    SZFSExpect([b.store.profileName isEqual:@"Thief"] && [b.store personWithConversationID:mei].unreadCount == 0,
               @"for now B shows them");
    SZFSExpect(SZFSDeliver(a, b), @"the removal and its record reach B");
    SZFSExpect(b.store.profileName == nil, @"no name, as on A: %@", b.store.profileName);
    SZFSExpect(b.store.profilePicture.kind == SZFriendsPictureKindPlaceholder, @"no picture either");
    SZFSExpect([b.store personWithConversationID:mei].unreadCount == 1, @"the message is unread again");
    SZFSExpect([b.store syncRegisterForKey:@"profile"].value == nil &&
                   [b.store syncRegisterForKey:SZFriendsSyncReadKey(mei)].value == nil,
               @"neither was ever written");
    SZFSExpect([b.engine captureLocalChanges] == 0, @"B has nothing of its own to send for them");
    SZFSSyncAll(@[ a, b ]);
    SZFSExpect(a.store.profileName == nil, @"nothing reaches A: %@", a.store.profileName);
    SZFSExpect([SZFSDump(a) isEqualToString:SZFSDump(b)], @"A and B hold the same:\n%@\n---\n%@", SZFSDump(a),
               SZFSDump(b));
}

// A removal's record can apply outside an exchange (one that waited for its chain applies with the next events), so
// before B's next capture. A name typed on B over the removed computer's is B's own change, which the purge keeps.
static void TestUnsentNameKept(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"unsent", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    a.store.profileName = @"Raph";
    [a.engine captureLocalChanges];
    SZFSSyncAll(devices);
    SZFriendsDeviceChain *chain = Revoke(a, c);
    SZFSExpect([a.engine recordRevocationOfDeviceKey:c.identity.publicKey error:NULL], @"A records what it held of C");
    c.store.profileName = @"Thief";
    [c.engine captureLocalChanges];
    SZFSExpect(SZFSDeliver(c, b) && [b.store.profileName isEqual:@"Thief"], @"B shows C's late name");
    b.store.profileName = @"Raph B"; // typed on B, not recorded yet
    SZFSExpect([b.store mergeOwnDeviceChain:chain error:NULL] == SZFriendsChainMergeChanged, @"B hears of the removal");
    uint64_t covered = [[a.store syncVector][c.identity.publicKey] unsignedLongLongValue];
    SZFSExpect([b.engine dropEventsOfDevice:c.identity.publicKey after:covered], @"C's late events go from B");
    SZFSExpect([b.store.profileName isEqualToString:@"Raph B"], @"the name typed on B stays: %@", b.store.profileName);
    SZFSSyncAll(@[ a, b ]);
    SZFSExpect([a.store.profileName isEqualToString:@"Raph B"], @"and reaches A: %@", a.store.profileName);
}

// The person's name and picture show in every view: a profile another computer changed, or one worked out again when
// a removed computer's late change goes, tells the views so (onChange, profile-wide).
static void TestProfileChangesTold(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"told", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    SZFSSyncAll(devices);
    __block NSUInteger told = 0;
    b.engine.onChange = ^(NSSet<NSString *> *conversations) {
        if (conversations.count == 0) told++;
    };
    a.store.profileName = @"Raph";
    [a.engine captureLocalChanges];
    SZFSExpect(SZFSDeliver(a, b) && [b.store.profileName isEqual:@"Raph"] && told == 1,
               @"A's new name reaches B, and B's views hear of it: %lu", (unsigned long)told);
    SZFSSyncAll(devices);
    SZFriendsDeviceChain *chain = Revoke(a, c);
    SZFSExpect([a.engine recordRevocationOfDeviceKey:c.identity.publicKey error:NULL], @"A records what it held of C");
    c.store.profileName = @"Thief";
    [c.engine captureLocalChanges];
    SZFSExpect(SZFSDeliver(c, b) && [b.store.profileName isEqual:@"Thief"], @"B shows C's late name");
    SZFSExpect([b.store mergeOwnDeviceChain:chain error:NULL] == SZFriendsChainMergeChanged, @"B hears of the removal");
    told = 0;
    uint64_t covered = [[a.store syncVector][c.identity.publicKey] unsignedLongLongValue];
    SZFSExpect([b.engine dropEventsOfDevice:c.identity.publicKey after:covered], @"C's late events go from B");
    SZFSExpect([b.store.profileName isEqualToString:@"Raph"] && told == 1,
               @"the name falls back, and B's views hear of it: %@, %lu", b.store.profileName, (unsigned long)told);
}

// Delivered wins, but not when only a dropped late event said so: the outbox entry and the file record go back to
// what A's events say.
static void TestLateDeliveryUndone(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"undelivered", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFriendsOutboxEntry *entry = SZFSQueueMessage(a, @"mei", @"out1");
    SZFriendsTransferRecord *sent = SZFSStageFile(a, @"mei", @"f1", 1024);
    SZFSSyncAll(devices);
    Revoke(a, c);
    SZFSExpect([a.engine recordRevocationOfDeviceKey:c.identity.publicKey error:NULL], @"A records what it held of C");
    SZFriendsOutbox *atC = [[SZFriendsOutbox alloc] initWithStore:c.store];
    [atC applyEvent:SZFriendsOutboxEventWritten toEntry:entry.entryID error:NULL];
    [atC applyEvent:SZFriendsOutboxEventAcknowledged toEntry:entry.entryID error:NULL];
    [c.engine captureLocalChanges];
    SZFSExpect(SZFSDeliver(c, b), @"B takes C's delivery");
    SZFriendsSyncFileRecord *file = [b.store syncFileWithID:sent.transferID];
    SZFriendsTransferState queued = file.state;
    SZFSExpect(file != nil && !SZFriendsSyncFileStateIsFinal(queued), @"the file is not delivered yet");
    file.state = SZFriendsTransferStateDelivered;
    uint64_t seq = [[b.store syncVector][c.identity.publicKey] unsignedLongLongValue] + 1;
    NSString *scope = SZFriendsSyncRefForPerson([b.store syncPersonWithConversationID:file.conversationID]);
    SZFriendsSyncEvent *delivered = [SZFriendsSyncEvent eventSignedBy:c.identity rootKey:b.engine.rootKey
                                                                 kind:SZFriendsSyncKindFile seq:seq
                                                              lamport:[b.store syncLamport] + 1 date:[NSDate date]
                                                                scope:scope subject:sent.transferID
                                                                 body:SZFriendsSyncFileBody(file)];
    SZFSExpect([b.engine receiveEvents:@[ delivered ] error:NULL], @"and C's word that the file was delivered");
    SZFriendsOutbox *atB = [[SZFriendsOutbox alloc] initWithStore:b.store];
    SZFSExpect([atB entryWithID:entry.entryID].state == SZFriendsOutboxStateDelivered &&
                   [b.store syncFileWithID:sent.transferID].state == SZFriendsTransferStateDelivered,
               @"for now B shows both delivered");
    SZFSExpect(SZFSDeliver(a, b), @"the removal and its record reach B");
    SZFSExpect([atB entryWithID:entry.entryID].state == SZFriendsOutboxStateQueued, @"the message is queued again: %ld",
               (long)[atB entryWithID:entry.entryID].state);
    SZFSExpect([b.store syncFileWithID:sent.transferID].state == queued, @"the file is as A left it: %ld",
               (long)[b.store syncFileWithID:sent.transferID].state);
    SZFSSyncAll(@[ a, b ]);
    SZFSExpect([SZFSDump(a) isEqualToString:SZFSDump(b)], @"A and B hold the same:\n%@\n---\n%@", SZFSDump(a),
               SZFSDump(b));
}

// A device C added on a branch that never saw C's removal is void: its events are left out, the rest of a batch still
// counts, and none of its events is offered on.
static void TestVoidAuthorsLeftOut(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"void", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    SZFSSyncAll(devices);
    SZFriendsIdentity *d = SZFSIdentity(0x44);
    NSData *root = b.engine.rootKey;
    SZFriendsDeviceChain *added = [c.store.ownDeviceChain chainByAddingDeviceKey:d.publicKey
                                                                       staticKey:d.staticPublicKey
                                                                         consent:SZFriendsDeviceConsent(d, root)
                                                                            name:@"Mac D" system:@"macOS 26.1"
                                                                        signedBy:c.identity date:[NSDate date]
                                                                           error:NULL];
    SZFSExpect(added != nil && [b.store mergeOwnDeviceChain:added error:NULL] != SZFriendsChainMergeRefused,
               @"B hears C added D");
    SZFriendsSyncFields *fields = [[SZFriendsSyncFields alloc] init];
    [fields setString:@"From D" forTag:2];
    SZFriendsSyncEvent *first = [SZFriendsSyncEvent eventSignedBy:d rootKey:root kind:SZFriendsSyncKindProfile seq:1
                                                          lamport:[b.store syncLamport] + 1 date:[NSDate date]
                                                            scope:@"" subject:@"" body:fields.encodedData];
    SZFSExpect([b.engine receiveEvents:@[ first ] error:NULL], @"D speaks for us, for now");
    // A removes C without having seen D's add: D rested on C, so D is void.
    SZFriendsDeviceChain *revoked = Revoke(a, c);
    SZFSExpect([b.store mergeOwnDeviceChain:revoked error:NULL] != SZFriendsChainMergeRefused, @"B hears it");
    NSInteger state = 0;
    for (SZFriendsDeviceRecord *device in [b.store devicesOfRootKey:root]) {
        if ([device.deviceKey isEqualToData:d.publicKey]) state = device.state;
    }
    SZFSExpect(state == SZFriendsChainDeviceVoid, @"D is void on B: %ld", (long)state);
    for (SZFriendsSyncEvent *event in [b.engine eventsMissingFrom:@{} limit:1000]) {
        SZFSExpect(![event.author isEqualToData:d.publicKey], @"B never offers D's events");
    }
    SZFriendsSyncEvent *second = [SZFriendsSyncEvent eventSignedBy:d rootKey:root kind:SZFriendsSyncKindProfile seq:2
                                                           lamport:[b.store syncLamport] + 1 date:[NSDate date]
                                                             scope:@"" subject:@"" body:fields.encodedData];
    a.store.profileName = @"Raph";
    [a.engine captureLocalChanges];
    NSMutableArray<SZFriendsSyncEvent *> *batch = [NSMutableArray arrayWithObject:second];
    [batch addObjectsFromArray:[a.engine eventsMissingFrom:[b.engine vector] limit:1000]];
    NSError *error = nil;
    SZFSExpect([b.engine receiveEvents:batch error:&error], @"a void author does not fail the batch: %@", error);
    SZFSExpect([b.store.profileName isEqualToString:@"Raph"], @"A's events in it count: %@", b.store.profileName);
    SZFSExpect([[b.store syncVector][d.publicKey] unsignedLongLongValue] == 1, @"D's second is left out");
}

static void TestRecordsCountOnlyFromTheRevoker(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"record", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFSSyncAll(devices);
    SZFSInsertMessage(c, @"mei", @"c1", @"heard by B only", SZFriendsDirectionOutgoing, 5000);
    [c.engine captureLocalChanges];
    SZFSExpect(SZFSDeliver(c, b), @"B has C's message");
    NSNumber *heldOfC = [a.store syncVector][c.identity.publicKey];
    // A revokes C without having held c1, and no record of A's covers it.
    SZFriendsDeviceChain *chain = Revoke(a, c);
    SZFSExpect([b.store mergeOwnDeviceChain:chain error:NULL] != SZFriendsChainMergeRefused, @"B holds it too");
    // B claims to have held C's events at a revocation it never signed: nobody believes it.
    SZFSExpect([b.engine recordRevocationOfDeviceKey:c.identity.publicKey error:NULL], @"B records anyway");
    SZFSExpect(SZFSDeliver(b, a), @"A takes B's events");
    SZFSExpect([a.store itemWithID:@"c1" inConversation:@"mei"] == nil, @"but not C's through B's claim");
    SZFSExpect([[a.store syncVector][c.identity.publicKey] isEqual:heldOfC], @"nothing more of C's on A");
}

static void TestClockFarAhead(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"clock", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    a.store.profileName = @"Raph";
    [a.engine captureLocalChanges];
    SZFSSyncAll(devices);
    uint64_t clock = [a.store syncLamport];
    SZFriendsSyncFields *fields = [[SZFriendsSyncFields alloc] init];
    [fields setString:@"Forever" forTag:2];
    SZFriendsSyncEvent *runaway = Forged(b, a, SZFriendsSyncKindProfile, clock + SZFriendsSyncLamportMargin + 1, @"",
                                         fields.encodedData);
    NSError *error = nil;
    SZFSExpect(![a.engine receiveEvents:@[ runaway ] error:&error] && error.code == SZFriendsSyncErrorForged,
               @"a clock past the margin is refused: %@", error);
    SZFSExpect([a.store.profileName isEqualToString:@"Raph"], @"and changes nothing");
    SZFriendsSyncEvent *far = Forged(b, a, SZFriendsSyncKindProfile, clock + SZFriendsSyncLamportMargin, @"",
                                     fields.encodedData);
    SZFSExpect([a.engine receiveEvents:@[ far ] error:&error], @"up to the margin is taken: %@", error);
}

static void TestDeletionTakesOnlyWhatItCouldSee(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"bound", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFSInsertMessage(a, @"mei", @"old", @"seen by B", SZFriendsDirectionIncoming, 6000);
    SZFSSyncAll(devices);
    // B deletes Mei's chat claiming everything A will ever write.
    SZFriendsSyncFields *fields = [[SZFriendsSyncFields alloc] init];
    [fields setString:@"mei" forTag:1];
    [fields setData:SZFriendsSyncEncodeVector(@{a.identity.publicKey : @(1ull << 40)}) forTag:2];
    NSString *scope = [@"k:" stringByAppendingString:SZFriendsSyncHex([a.store personWithConversationID:@"mei"]
                                                                          .identityKey)];
    SZFriendsSyncEvent *greedy = Forged(b, a, SZFriendsSyncKindTombstone, [b.store syncLamport] + 1, scope,
                                        fields.encodedData);
    SZFSExpect([a.engine receiveEvents:@[ greedy ] error:NULL], @"A takes the deletion");
    SZFSExpect([a.store itemWithID:@"old" inConversation:@"mei"] == nil, @"what B had seen goes");
    SZFSInsertMessage(a, @"mei", @"new", @"arrived after the deletion", SZFriendsDirectionIncoming, 6001);
    SZFSSyncAll(devices);
    SZFSExpect([b.store itemWithID:@"new" inConversation:@"mei"] != nil, @"a later message stays on B");
    SZFSExpect([a.store itemWithID:@"new" inConversation:@"mei"] != nil, @"and on A");
}

static void TestFriendsIDStaysOff(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"id", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    b.store.friendsID = @"tulip-canyon";
    a.store.profileName = @"Raph";
    a.store.friendsID = @"walnut-garden"; // drawn after a collision on A
    SZFSSyncAll(devices);
    SZFSExpect([b.store.profileName isEqualToString:@"Raph"], @"the name travels");
    SZFSExpect([b.store.friendsID isEqualToString:@"tulip-canyon"], @"the ID does not: %@", b.store.friendsID);
}

static void TestSecretsRenewed(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"renew", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    a.store.ownPresenceSecret = SZFSIdentity(0x77).publicKey;
    [a.engine ensureOwnDevicesSecret];
    SZFSSyncAll(devices);
    NSData *oldPresence = a.store.ownPresenceSecret, *oldDevices = [a.engine ownDevicesSecret];
    SZFSExpect([a.engine renewSecretsAfterRevocation] == nil, @"nothing to renew before a revocation");
    SZFriendsDeviceChain *chain = Revoke(a, c);
    [b.store mergeOwnDeviceChain:chain error:NULL];
    SZFSExpect([b.engine renewSecretsAfterRevocation] == nil, @"B is not the first device: it draws nothing");
    NSData *fresh = [a.engine renewSecretsAfterRevocation];
    SZFSExpect(fresh.length == 32 && ![fresh isEqualToData:oldPresence], @"A draws a presence secret");
    SZFSExpect(![[a.engine ownDevicesSecret] isEqualToData:oldDevices], @"and an own-devices secret");
    SZFSExpect([a.engine renewSecretsAfterRevocation] == nil, @"once for that revocation");
    SZFSSyncAll(@[ a, b ]);
    SZFSExpect([b.store.ownPresenceSecret isEqualToData:fresh], @"B learns the presence secret");
    SZFSExpect([[b.engine ownDevicesSecret] isEqualToData:[a.engine ownDevicesSecret]], @"and the own-devices one");
    SZFSExpect(![[c.engine ownDevicesSecret] isEqualToData:[a.engine ownDevicesSecret]], @"C keeps the old one");
    // The old one stays known, so our devices can still find C by it and tell it it was removed.
    SZFSExpect([[a.engine previousOwnDevicesSecrets].firstObject isEqualToData:oldDevices] &&
                   [[b.engine previousOwnDevicesSecrets].firstObject isEqualToData:oldDevices],
               @"both keep the secret C still holds");
    // With the first device revoked, the next authorized one draws.
    chain = Revoke(b, a);
    SZFSExpect([b.engine renewSecretsAfterRevocation].length == 32, @"B draws once A is removed");
}

// The first computer is away when B removes C: after its wait B draws the secrets itself, and the first computer,
// back, takes B's rather than drawing its own.
static void TestSecretsRenewedWithTheFirstAway(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"away", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    a.store.ownPresenceSecret = SZFSIdentity(0x78).publicKey;
    [a.engine ensureOwnDevicesSecret];
    SZFSSyncAll(devices);
    NSData *old = b.store.ownPresenceSecret;
    Revoke(b, c);
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1760500000];
    b.engine.clock = ^NSDate * { return start; };
    SZFSExpect([b.engine renewSecretsAfterRevocation] == nil, @"B leaves it to the first computer at first");
    NSDate *due = [b.engine secretRenewalDueDate];
    SZFSExpect([due isEqualToDate:[start dateByAddingTimeInterval:SZFriendsSyncSecretRenewalWait]], @"due %@", due);
    b.engine.clock = ^NSDate * { return [start dateByAddingTimeInterval:SZFriendsSyncSecretRenewalWait - 1]; };
    SZFSExpect([b.engine renewSecretsAfterRevocation] == nil, @"not before its wait");
    b.engine.clock = ^NSDate * { return [start dateByAddingTimeInterval:SZFriendsSyncSecretRenewalWait]; };
    NSData *fresh = [b.engine renewSecretsAfterRevocation];
    SZFSExpect(fresh.length == 32 && ![fresh isEqualToData:old], @"then B draws");
    SZFSExpect([b.engine secretRenewalDueDate] == nil && [b.engine renewSecretsAfterRevocation] == nil, @"once");
    SZFSSyncAll(@[ a, b ]);
    SZFSExpect([a.engine renewSecretsAfterRevocation] == nil, @"the first computer, back, draws nothing");
    SZFSExpect([a.store.ownPresenceSecret isEqualToData:fresh], @"it has B's secret");
    SZFSExpect([[a.engine ownDevicesSecret] isEqualToData:[b.engine ownDevicesSecret]], @"and B's own-devices one");
}

// The first computer comes back after B drew, hears of the removal before B's secrets, and draws too: one draw wins
// on both, and the computer whose draw lost tells friends the winner, so none keeps a secret that matches nothing.
static void TestBothDrewOneRetells(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"both", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    a.store.ownPresenceSecret = SZFSIdentity(0x79).publicKey;
    [a.engine ensureOwnDevicesSecret];
    SZFSSyncAll(devices);
    SZFriendsDeviceChain *chain = Revoke(b, c);
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1760500000];
    b.engine.clock = ^NSDate * { return start; };
    SZFSExpect([b.engine renewSecretsAfterRevocation] == nil, @"B waits for the first computer");
    b.engine.clock = ^NSDate * { return [start dateByAddingTimeInterval:SZFriendsSyncSecretRenewalWait]; };
    NSData *drawnByB = [b.engine renewSecretsAfterRevocation];
    SZFSExpect([a.store mergeOwnDeviceChain:chain error:NULL] == SZFriendsChainMergeChanged, @"A hears of it");
    NSData *drawnByA = [a.engine renewSecretsAfterRevocation];
    SZFSExpect(drawnByA.length == 32 && drawnByB.length == 32, @"both drew");
    SZFSExpect(![a.engine takePresenceSecretRetell] && ![b.engine takePresenceSecretRetell], @"nothing to retell yet");
    SZFSSyncAll(@[ a, b ]);
    NSData *won = a.store.ownPresenceSecret;
    SZFSExpect([b.store.ownPresenceSecret isEqualToData:won] &&
                   ([won isEqualToData:drawnByA] || [won isEqualToData:drawnByB]),
               @"one draw holds on both");
    BOOL aRetells = [a.engine takePresenceSecretRetell], bRetells = [b.engine takePresenceSecretRetell];
    SZFSExpect(aRetells == [won isEqualToData:drawnByB] && bRetells == [won isEqualToData:drawnByA],
               @"the computer whose draw lost retells: A %d, B %d", aRetells, bRetells);
    SZFSExpect(![a.engine takePresenceSecretRetell] && ![b.engine takePresenceSecretRetell], @"once");
}

// Removed meanwhile, a device receiving EVENTS says why it stops, not that the message was malformed.
static void TestRemovedDeviceStopsSyncing(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"stops", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    SZFriendsDeviceChain *chain = Revoke(a, b);
    [b.store mergeOwnDeviceChain:chain error:NULL];
    SZFriendsSyncExchange *exchange = [[SZFriendsSyncExchange alloc] initWithEngine:b.engine
                                                                            peerKey:a.identity.publicKey
                                                                               send:^(NSData *message) {
                                                                                   (void)message;
                                                                               }];
    NSError *error = nil;
    uint8_t events[] = {2, 0, 0};
    SZFSExpect(![exchange receiveMessage:[NSData dataWithBytes:events length:3] error:&error] &&
                   [error.domain isEqualToString:SZFriendsSyncErrorDomain] && error.code == SZFriendsSyncErrorInactive,
               @"inactive, not malformed: %@", error);
}

void SZFSRunRevocationTests(void) {
    TestRevokedDeviceCountsUntilRemoved();
    TestLateEventsDroppedEverywhere();
    TestLateOnlyWriterCleared();
    TestUnsentNameKept();
    TestProfileChangesTold();
    TestLateDeliveryUndone();
    TestVoidAuthorsLeftOut();
    TestRecordsCountOnlyFromTheRevoker();
    TestClockFarAhead();
    TestDeletionTakesOnlyWhatItCouldSee();
    TestFriendsIDStaysOff();
    TestSecretsRenewed();
    TestSecretsRenewedWithTheFirstAway();
    TestBothDrewOneRetells();
    TestRemovedDeviceStopsSyncing();
}
