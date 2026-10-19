// Transfers: staging outgoing snapshots, incoming offers, answers on both sides, and automatic acceptance.

#import <CommonCrypto/CommonDigest.h>
#import <unistd.h>

#import "SZFriendsStoreTestSupport.h"

static const uint64_t GiB = 1ULL << 30;

static SZFriendsTransfers *Transfers(SZFriendsStore *store, uint64_t freeBytes) {
    SZFriendsTransfers *transfers = [[SZFriendsTransfers alloc] initWithStore:store
        stateDirectory:store.stateDirectory];
    transfers.freeBytesProvider = ^uint64_t(NSString *path) {
        (void)path;
        return freeBytes;
    };
    return transfers;
}

static NSString *WriteFile(NSString *name, NSData *contents) {
    NSString *path = [SZFTTemporaryDirectory(@"sources") stringByAppendingPathComponent:name];
    [contents writeToFile:path atomically:NO];
    return path;
}

static NSData *SHA256(NSData *data) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return [NSData dataWithBytes:digest length:sizeof digest];
}

static void TestStagingBindsAnImmutableSnapshot(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"stage"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = Transfers(store, 100 * GiB);
    NSData *contents = SZFTRandomData(300000);
    NSString *source = WriteFile(@"Supplier contract v3.pdf", contents);
    NSError *error = nil;
    SZFriendsTransferRecord *record = [transfers stageOutgoingFileAtPath:source revision:nil conversationID:@"mei"
                                                                   error:&error];
    SZFTExpect(record && record.state == SZFriendsTransferStateQueued && record.outgoing, @"staged: %@", error);
    SZFTExpect([record.contentDigest isEqualToData:SZFTBlake2b(contents)] && record.size == contents.length,
               @"BLAKE2b-256 and size of the bytes");
    SZFTExpect([record.uniformType isEqualToString:@"com.adobe.pdf"], @"type %@", record.uniformType);
    SZFTExpect(SZFTFileMode(record.stagedPath) == 0600 &&
                   [record.stagedPath hasPrefix:[store.stateDirectory stringByAppendingPathComponent:@"outgoing"]],
               @"private snapshot in outgoing/");
    [SZFTRandomData(1000) writeToFile:source atomically:NO];
    SZFTExpect([[NSData dataWithContentsOfFile:record.stagedPath] isEqualToData:contents],
               @"editing the source afterwards changes nothing that is sent");
    SZFTExpect([[transfers transferWithID:record.transferID].contentDigest isEqualToData:record.contentDigest],
               @"persisted");
    SZFriendsTransferRecord *named = [transfers stageOutgoingFileAtPath:source displayName:@"../Quarterly: plan.pdf"
                                                               revision:nil conversationID:@"mei" error:NULL];
    SZFTExpect([named.fileName isEqualToString:@"-Quarterly- plan.pdf"], @"display name sanitized: %@", named.fileName);
}

static void TestStagingRefusals(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"refuse"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = Transfers(store, 100 * GiB);
    // Created before anything is staged: a new manager's recovery drops stages nobody offered.
    SZFriendsTransfers *full = Transfers(store, 1000);
    NSData *contents = [@"revision bytes" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *source = WriteFile(@"Doc.md", contents);
    SZFriendsRevision *revision = [[SZFriendsRevision alloc] init];
    revision.source = @"app";
    revision.documentID = @"d1";
    revision.revisionID = @"r1";
    revision.sha256 = SHA256(contents);
    revision.size = contents.length;
    NSError *error = nil;
    SZFriendsTransferRecord *bound = [transfers stageOutgoingFileAtPath:source revision:revision conversationID:@"mei"
                                                                  error:&error];
    SZFTExpect(bound && [bound.revision.revisionID isEqualToString:@"r1"], @"matching revision: %@", error);
    revision.sha256 = SHA256([@"newer bytes" dataUsingEncoding:NSUTF8StringEncoding]);
    NSUInteger before = [NSFileManager.defaultManager
                            contentsOfDirectoryAtPath:[store.stateDirectory stringByAppendingPathComponent:@"outgoing"]
                                                error:NULL].count;
    SZFTExpect(![transfers stageOutgoingFileAtPath:source revision:revision conversationID:@"mei" error:&error] &&
                   error.code == SZFriendsStoreErrorSourceChanged, @"a changed source is never substituted");
    NSUInteger after = [NSFileManager.defaultManager
                           contentsOfDirectoryAtPath:[store.stateDirectory stringByAppendingPathComponent:@"outgoing"]
                                               error:NULL].count;
    SZFTExpect(before == after, @"no snapshot left behind");
    revision.sha256 = nil;
    revision.size = 3;
    SZFTExpect(![transfers stageOutgoingFileAtPath:source revision:revision conversationID:@"mei" error:&error] &&
                   error.code == SZFriendsStoreErrorSourceChanged, @"size mismatch");
    SZFTExpect(![transfers stageOutgoingFileAtPath:@"/nonexistent/x.pdf" revision:nil conversationID:@"mei"
                                             error:&error] &&
                   [SZFriendsStoreProtocolErrorCode(error) isEqualToString:@"file_missing"], @"missing");
    SZFTExpect(![transfers stageOutgoingFileAtPath:SZFTTemporaryDirectory(@"folder") revision:nil conversationID:@"mei"
                                             error:&error] &&
                   [SZFriendsStoreProtocolErrorCode(error) isEqualToString:@"folder_not_supported"], @"folders");
    SZFTExpect(![transfers stageOutgoingFileAtPath:source revision:nil conversationID:@"ghost" error:&error] &&
                   error.code == SZFriendsStoreErrorNotFound, @"unknown conversation");
    SZFriendsSnapshotDisableClone = YES;
    SZFTExpect(![full stageOutgoingFileAtPath:source revision:nil conversationID:@"mei" error:&error] &&
                   [SZFriendsStoreProtocolErrorCode(error) isEqualToString:@"disk_full"], @"no room for a copy");
    SZFriendsSnapshotDisableClone = NO;
    SZFTExpect([transfers discardStagedTransfer:bound.transferID error:NULL] &&
                   ![transfers transferWithID:bound.transferID] &&
                   ![NSFileManager.defaultManager fileExistsAtPath:bound.stagedPath], @"discard an unsent stage");
}

static SZFriendsTransferRecord *Offer(SZFriendsTransfers *transfers, NSString *transferID, NSString *conversationID,
                                      NSString *name, NSData *contents, NSError **error) {
    return [transfers recordIncomingOfferWithID:transferID conversationID:conversationID fileName:name
                                    uniformType:@"com.adobe.pdf" size:contents.length
                                  contentDigest:SZFTBlake2b(contents) sentAt:[NSDate date] error:error];
}

static void TestIncomingOffers(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"offers"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFTAddPerson(store, @"kenji", 3, SZFriendsRelationFriend, 1000);
    SZFTAddPerson(store, @"troll", 5, SZFriendsRelationBlocked, 1000);
    SZFTAddPerson(store, @"lena", 7, SZFriendsRelationIncomingRequest, 1000);
    SZFriendsTransfers *transfers = Transfers(store, 100 * GiB);
    NSData *contents = SZFTRandomData(1000);
    NSError *error = nil;
    SZFriendsTransferRecord *offer = Offer(transfers, @"o1", @"mei", @"../../Site photos.pdf", contents, &error);
    SZFTExpect(offer.state == SZFriendsTransferStateWaitingForYou && [offer.fileName
        isEqualToString:@"-..-Site photos.pdf"],
               @"recorded and sanitized: %@ %@", offer.fileName, error);
    SZFTExpect(Offer(transfers, @"o1", @"mei", @"other.pdf", contents, NULL) != nil,
        @"a resent offer is the same offer");
    NSArray *items = [store itemsInConversation:@"mei" beforeItemID:nil limit:5 hasEarlier:NULL];
    SZFTExpect(items.count == 1 && [[items.firstObject text] isEqualToString:offer.fileName], @"one history row");
    SZFTExpect([store personWithConversationID:@"mei"].unreadCount == 1, @"unread");
    SZFTExpect(!Offer(transfers, @"o1", @"kenji", @"x.pdf", contents, &error) &&
        error.code == SZFriendsStoreErrorInvalid,
               @"another friend cannot reuse an offer id");
    SZFTExpect(!Offer(transfers, @"o2", @"troll", @"x.pdf", contents, &error), @"blocked people cannot offer files");
    SZFTExpect(!Offer(transfers, @"o3", @"lena", @"x.pdf", contents, &error), @"strangers cannot offer files");
    SZFTExpect(![transfers recordIncomingOfferWithID:@"o4" conversationID:@"mei" fileName:@"x" uniformType:nil size:1
                                       contentDigest:SZFTBytes(1, 31) sentAt:[NSDate date] error:&error],
               @"malformed digest");
    for (NSUInteger i = 1; i < SZFriendsTransferMaxPendingOffers; i++) {
        Offer(transfers, [NSString stringWithFormat:@"f%lu", (unsigned long)i], @"kenji", @"f.pdf", contents, NULL);
    }
    SZFTExpect(Offer(transfers, @"last", @"kenji", @"f.pdf", contents, NULL) != nil, @"the 200th is still fine");
    SZFTExpect(!Offer(transfers, @"flood", @"kenji", @"f.pdf", contents, &error), @"the 201st is a flood");
    SZFTExpect([transfers pendingIncomingOfferCountForConversation:@"kenji"] == SZFriendsTransferMaxPendingOffers,
               @"count");
}

static void TestAnswersOnBothSides(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"answers"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFTAddPerson(store, @"kenji", 3, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = Transfers(store, 100 * GiB);
    NSData *contents = SZFTRandomData(5000);
    NSError *error = nil;
    Offer(transfers, @"in1", @"mei", @"a.pdf", contents, NULL);
    SZFTExpect([transfers declineTransfer:@"in1" error:NULL], @"decline");
    SZFTExpect(![transfers declineTransfer:@"in1" error:&error] && error.code == SZFriendsStoreErrorStale, @"twice");
    SZFTExpect(![transfers acceptTransfer:@"in1" automatically:NO error:&error] &&
        error.code == SZFriendsStoreErrorStale,
               @"a declined offer cannot be accepted");
    Offer(transfers, @"in2", @"mei", @"b.pdf", contents, NULL);
    SZFriendsTransfers *tight = Transfers(store, 1000);
    SZFTExpect(![tight acceptTransfer:@"in2" automatically:NO error:&error] &&
                   [SZFriendsStoreProtocolErrorCode(error) isEqualToString:@"disk_full"], @"no room: %@", error);
    SZFTExpect([transfers transferWithID:@"in2"].state == SZFriendsTransferStateWaitingForYou, @"still waiting");
    SZFTExpect([transfers acceptTransfer:@"in2" automatically:NO error:&error], @"accept: %@", error);
    SZFTExpect([transfers transferWithID:@"in2"].state == SZFriendsTransferStateReceiving, @"receiving");
    SZFTExpect([transfers cancelTransfer:@"in2" error:NULL], @"cancel a running download");
    NSString *partials = [store.stateDirectory stringByAppendingPathComponent:@"received/.partial"];
    SZFTExpect([NSFileManager.defaultManager contentsOfDirectoryAtPath:partials error:NULL].count == 0,
               @"incomplete files are removed");
    NSString *source = WriteFile(@"Ours.pdf", contents);
    SZFriendsTransferRecord *ours = [transfers stageOutgoingFileAtPath:source revision:nil conversationID:@"mei"
        error:NULL];
    SZFTExpect(![transfers peerAnsweredTransfer:ours.transferID accepted:YES offset:0 fromConversation:@"kenji"
                                          error:&error] && error.code == SZFriendsStoreErrorInvalid,
               @"only the recipient answers");
    SZFTExpect([transfers markOfferDelivered:ours.transferID fromConversation:@"mei" error:NULL] &&
                   [transfers transferWithID:ours.transferID].state == SZFriendsTransferStateOffered, @"offered");
    SZFTExpect([transfers peerAnsweredTransfer:ours.transferID accepted:YES offset:0 fromConversation:@"mei"
        error:NULL],
               @"accepted");
    SZFTExpect([transfers transferWithID:ours.transferID].state == SZFriendsTransferStateSending, @"sending");
    SZFTExpect(![transfers peerAnsweredTransfer:ours.transferID accepted:YES offset:contents.length + 1
                               fromConversation:@"mei" error:&error], @"resume beyond the file");
    SZFTExpect([transfers peerAnsweredTransfer:ours.transferID accepted:YES offset:2048 fromConversation:@"mei"
                                         error:NULL], @"resume from their verified count");
    SZFTExpect(![transfers peerAnsweredTransfer:ours.transferID accepted:NO offset:0 fromConversation:@"mei"
        error:&error] &&
                   error.code == SZFriendsStoreErrorStale, @"a decline after acceptance is stale");
    SZFTExpect([transfers peerVerifiedTransfer:ours.transferID fromConversation:@"mei" error:NULL], @"delivered");
    SZFTExpect([transfers transferWithID:ours.transferID].state == SZFriendsTransferStateDelivered &&
                   ![NSFileManager.defaultManager fileExistsAtPath:ours.stagedPath], @"snapshot freed once delivered");
    SZFTExpect(![transfers cancelTransfer:ours.transferID error:&error] && error.code == SZFriendsStoreErrorStale,
               @"Cancel cannot retract a delivered file");
    SZFriendsTransferRecord *withdrawn = [transfers stageOutgoingFileAtPath:source revision:nil conversationID:@"mei"
                                                                      error:NULL];
    [transfers cancelTransfer:withdrawn.transferID error:NULL];
    SZFTExpect(![transfers peerAnsweredTransfer:withdrawn.transferID accepted:YES offset:0 fromConversation:@"mei"
                                          error:&error] && error.code == SZFriendsStoreErrorStale,
               @"a stale acceptance of a withdrawn offer changes nothing");
    SZFTExpect(![NSFileManager.defaultManager fileExistsAtPath:withdrawn.stagedPath], @"withdrawn snapshot removed");
    SZFriendsTransferRecord *tampered = [transfers stageOutgoingFileAtPath:source revision:nil conversationID:@"mei"
                                                                     error:NULL];
    [transfers markOfferDelivered:tampered.transferID fromConversation:@"mei" error:NULL];
    [SZFTRandomData(5000) writeToFile:tampered.stagedPath atomically:NO];
    SZFriendsTransfers *restarted = Transfers(store, 100 * GiB);
    SZFTExpect(![restarted peerAnsweredTransfer:tampered.transferID accepted:YES offset:0 fromConversation:@"mei"
                                          error:&error] && error.code == SZFriendsStoreErrorSourceChanged,
               @"a snapshot that no longer hashes to the offer is never sent");
    SZFriendsTransferRecord *failed = [restarted transferWithID:tampered.transferID];
    SZFTExpect(failed.state == SZFriendsTransferStateFailed &&
                   [failed.failureReason isEqualToString:SZFriendsTransferFailureSourceMissing], @"and fails");
}

static void TestAutomaticAcceptance(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"auto"));
    SZFriendsPersonRecord *mei = SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *roomy = Transfers(store, 100 * GiB);
    NSData *contents = SZFTRandomData(4000);
    Offer(roomy, @"a1", @"mei", @"a.pdf", contents, NULL);
    SZFTExpect([roomy applyAutomaticAcceptanceToTransfer:@"a1" error:NULL] == SZFriendsAutoAcceptAsk,
        @"off by default");
    NSError *error = nil;
    SZFTExpect(![roomy acceptTransfer:@"a1" automatically:YES error:&error] && error.code == SZFriendsStoreErrorStale,
               @"an automatic acceptance needs the switch");
    mei.autoAccept = YES;
    [store savePerson:mei error:NULL];
    SZFTExpect([roomy applyAutomaticAcceptanceToTransfer:@"a1" error:NULL] == SZFriendsAutoAcceptDownload, @"on");
    SZFriendsTransferRecord *record = [roomy transferWithID:@"a1"];
    SZFTExpect(record.state == SZFriendsTransferStateReceiving && record.acceptedAutomatically, @"downloading");
    Offer(roomy, @"a2", @"mei", @"b.pdf", contents, NULL);
    SZFriendsTransfers *tight = Transfers(store, GiB / 2);
    SZFTExpect([tight applyAutomaticAcceptanceToTransfer:@"a2" error:NULL] == SZFriendsAutoAcceptAskLowDisk, @"low");
    record = [tight transferWithID:@"a2"];
    SZFTExpect(record.state == SZFriendsTransferStateWaitingForYou && record.askedBecauseDiskLow,
               @"asks, and says why");
    SZFTExpect([tight acceptTransfer:@"a2" automatically:NO error:NULL], @"the person may still accept it");
    Offer(roomy, @"a3", @"mei", @"c.pdf", contents, NULL);
    mei = [store personWithConversationID:@"mei"];
    mei.keyChangePending = YES;
    [store savePerson:mei error:NULL];
    SZFTExpect([roomy applyAutomaticAcceptanceToTransfer:@"a3" error:NULL] == SZFriendsAutoAcceptAsk,
               @"a key change stops automatic downloads");
    SZFTExpect([roomy transferWithID:@"a3"].state == SZFriendsTransferStateWaitingForYou, @"still asks");
    // The transfer layer checks the key state itself, not only through the store clearing the switch: a row that
    // somehow holds both (a newer helper's write, a bug elsewhere) must still ask.
    [store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return [db exec:@"UPDATE friends SET auto_accept = 1, key_change_pending = 1 WHERE conversation_id = 'mei'"
                  error:inner];
    } error:NULL];
    NSError *decisionError = nil;
    SZFTExpect([roomy applyAutomaticAcceptanceToTransfer:@"a3" error:&decisionError] == SZFriendsAutoAcceptAsk &&
                   !decisionError, @"the decision itself asks while a key change is pending: %@", decisionError);
    SZFTExpect(![roomy acceptTransfer:@"a3" automatically:YES error:NULL], @"and so does the acceptance check");
}

void SZFTRunTransferTests(void) {
    TestStagingBindsAnImmutableSnapshot();
    TestStagingRefusals();
    TestIncomingOffers();
    TestAnswersOnBothSides();
    TestAutomaticAcceptance();
}
