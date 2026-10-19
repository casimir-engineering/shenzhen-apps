// Transfer safety from the M1 security review: staging files named by this Mac, ids scoped to their sender and
// compared without case, published files checked against the disk, and no unchecked peer calls.

#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

#import "SZFriendsStoreTestSupport.h"

static SZFriendsTransfers *Roomy(SZFriendsStore *store) {
    SZFriendsTransfers *transfers = [[SZFriendsTransfers alloc] initWithStore:store
                                                               stateDirectory:store.stateDirectory];
    transfers.freeBytesProvider = ^uint64_t(NSString *path) {
        (void)path;
        return 1ULL << 40;
    };
    return transfers;
}

static SZFriendsTransferRecord *_Nullable Offer(SZFriendsTransfers *transfers, NSString *transferID,
                                                NSString *conversationID, NSData *contents, NSError **error) {
    return [transfers recordIncomingOfferWithID:transferID conversationID:conversationID fileName:@"Plan.pdf"
                                    uniformType:nil size:contents.length contentDigest:SZFTBlake2b(contents)
                                         sentAt:[NSDate date] error:error];
}

static BOOL Stream(SZFriendsTransfers *transfers, NSString *transferID, NSString *conversationID, NSData *contents,
                   NSUInteger from, NSUInteger to) {
    for (NSUInteger offset = from; offset < to; offset += 10000) {
        NSData *piece = [contents subdataWithRange:NSMakeRange(offset, MIN((NSUInteger)10000, to - offset))];
        if (![transfers appendChunk:piece atOffset:offset toTransfer:transferID fromConversation:conversationID
                              error:NULL]) {
            return NO;
        }
    }
    return YES;
}

static NSString *PartialPath(SZFriendsStore *store, NSString *transferID) {
    return SZFTScalar(store, @"SELECT partial_path FROM transfers WHERE transfer_id = ?", @[ transferID ]);
}

// The review's probe: Mei's 'tx1' half received, then Kenji's 'TX1' accepted. On APFS the two once shared one
// staging file, Kenji's acceptance truncated it, and Mei's file was published as verified with zeros in it.
static void TestIdsDifferingInCaseNeverShareAFile(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"case"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFTAddPerson(store, @"kenji", 3, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = Roomy(store);
    NSData *meis = SZFTRandomData(100000);
    Offer(transfers, @"tx1", @"mei", meis, NULL);
    [transfers acceptTransfer:@"tx1" automatically:NO error:NULL];
    SZFTExpect(Stream(transfers, @"tx1", @"mei", meis, 0, 50000), @"half of Mei's file");
    NSError *error = nil;
    NSData *kenjis = SZFTRandomData(1000);
    SZFTExpect(!Offer(transfers, @"TX1", @"kenji", kenjis, &error) && error.code == SZFriendsStoreErrorInvalid,
               @"another friend's id differing only in case is refused: %@", error);
    [transfers acceptTransfer:@"TX1" automatically:NO error:NULL]; // what truncated Mei's file before
    SZFTExpect(!Offer(transfers, @"Tx1", @"mei", meis, &error) && error.code == SZFriendsStoreErrorInvalid,
               @"so is the same friend's id in other case");
    SZFTExpect(Offer(transfers, @"tx1", @"mei", meis, &error) != nil, @"the exact id again is a resend: %@", error);
    SZFTExpect(Stream(transfers, @"tx1", @"mei", meis, 50000, meis.length), @"the rest of Mei's file");
    SZFTExpect([transfers finishTransfer:@"tx1" finalDigest:SZFTBlake2b(meis) fromConversation:@"mei" error:&error],
               @"finish: %@", error);
    NSString *published = [transfers transferWithID:@"tx1"].receivedPath;
    SZFTExpect([[NSData dataWithContentsOfFile:published] isEqualToData:meis],
               @"the published file is exactly what Mei sent");
}

static void TestStagingFilesAreNamedByThisMac(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"names"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = Roomy(store);
    NSString *partials = [store.stateDirectory stringByAppendingPathComponent:@"received/.partial"];
    // What the sender's id used to name: a file someone left there and a symlink to elsewhere.
    NSData *planted = [@"not yours" dataUsingEncoding:NSUTF8StringEncoding];
    [planted writeToFile:[partials stringByAppendingPathComponent:@"r9.part"] atomically:NO];
    NSString *outside = [SZFTTemporaryDirectory(@"elsewhere") stringByAppendingPathComponent:@"target"];
    symlink(outside.fileSystemRepresentation,
            [partials stringByAppendingPathComponent:@"r8.part"].fileSystemRepresentation);
    NSData *contents = SZFTRandomData(3000);
    NSError *error = nil;
    for (NSString *transferID in @[ @"r9", @"r8" ]) {
        Offer(transfers, transferID, @"mei", contents, NULL);
        SZFTExpect([transfers acceptTransfer:transferID automatically:NO error:&error], @"accept %@: %@", transferID,
                   error);
        NSString *partial = PartialPath(store, transferID);
        SZFTExpect(partial && ![partial.lastPathComponent containsString:transferID] &&
                       [partial.stringByDeletingLastPathComponent.stringByStandardizingPath
                           isEqualToString:partials.stringByStandardizingPath],
                   @"a name of our own in .partial: %@", partial);
        SZFTExpect(SZFTFileMode(partial) == 0600, @"private");
    }
    SZFTExpect([[NSData dataWithContentsOfFile:[partials stringByAppendingPathComponent:@"r9.part"]]
                   isEqualToData:planted], @"the planted file was not opened, let alone emptied");
    SZFTExpect(![NSFileManager.defaultManager fileExistsAtPath:outside], @"the symlink was not followed");
    SZFTExpect(![PartialPath(store, @"r9") isEqualToString:PartialPath(store, @"r8")], @"one file per transfer");
}

// The streamed digest covers bytes as they arrived; what is published is the file. A change to the staging file
// after the last chunk must stop publication.
static void TestPublishingChecksTheFileOnDisk(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"disk"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = Roomy(store);
    NSData *contents = SZFTRandomData(40000);
    Offer(transfers, @"d1", @"mei", contents, NULL);
    [transfers acceptTransfer:@"d1" automatically:NO error:NULL];
    SZFTExpect(Stream(transfers, @"d1", @"mei", contents, 0, contents.length), @"every chunk");
    int other = open(PartialPath(store, @"d1").fileSystemRepresentation, O_WRONLY);
    SZFTExpect(other >= 0 && pwrite(other, "tampered", 8, 100) == 8, @"another writer changed the staging file");
    if (other >= 0) close(other);
    NSError *error = nil;
    SZFTExpect(![transfers finishTransfer:@"d1" finalDigest:SZFTBlake2b(contents) fromConversation:@"mei"
                                    error:&error] && error.code == SZFriendsStoreErrorDigestMismatch,
               @"refused although every chunk hashed right: %@", error);
    SZFriendsTransferRecord *record = [transfers transferWithID:@"d1"];
    SZFTExpect(record.state == SZFriendsTransferStateFailed && !record.receivedPath &&
                   [record.failureReason isEqualToString:SZFriendsTransferFailureDigestMismatch], @"failed");
    NSArray *published = [NSFileManager.defaultManager contentsOfDirectoryAtPath:transfers.receivedDirectory
                                                                           error:NULL];
    SZFTExpect([published isEqual:@[ @".partial" ]], @"nothing published: %@", published);
    // Recovery re-publishing after a crash checks the disk too.
    Offer(transfers, @"d2", @"mei", contents, NULL);
    [transfers acceptTransfer:@"d2" automatically:NO error:NULL];
    Stream(transfers, @"d2", @"mei", contents, 0, contents.length);
    NSString *final = [transfers.receivedDirectory stringByAppendingPathComponent:@"Plan.pdf"];
    SZFTScalar(store, @"UPDATE transfers SET publishing = 1, final_path = ? WHERE transfer_id = 'd2'", @[ final ]);
    NSMutableData *changed = [contents mutableCopy];
    ((uint8_t *)changed.mutableBytes)[7] ^= 1;
    [changed writeToFile:PartialPath(store, @"d2") atomically:NO];
    SZFriendsTransfers *restarted = Roomy(store);
    SZFTExpect([restarted transferWithID:@"d2"].state == SZFriendsTransferStateFailed &&
                   ![NSFileManager.defaultManager fileExistsAtPath:final], @"recovery does not publish it either");
}

// Every peer-named call needs the conversation that owns the transfer or entry; none waves an empty one through.
static void TestPeerCallsNeedTheOwningConversation(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"owners"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFTAddPerson(store, @"kenji", 3, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = Roomy(store);
    NSData *contents = SZFTRandomData(30000);
    Offer(transfers, @"in1", @"mei", contents, NULL);
    [transfers acceptTransfer:@"in1" automatically:NO error:NULL];
    NSString *nobody = nil; // what a session with no conversation would pass
    NSError *error = nil;
    NSData *first = [contents subdataWithRange:NSMakeRange(0, 10000)];
    SZFTExpect(![transfers appendChunk:first atOffset:0 toTransfer:@"in1" fromConversation:nobody error:&error] &&
                   error.code == SZFriendsStoreErrorInvalid, @"a chunk from no conversation is unsolicited");
    SZFTExpect(![transfers appendChunk:first atOffset:0 toTransfer:@"in1" fromConversation:@"" error:&error],
               @"so is one from an empty conversation");
    SZFTExpect(![transfers appendChunk:first atOffset:0 toTransfer:@"in1" fromConversation:@"kenji" error:&error],
               @"and one from another friend");
    SZFTExpect(Stream(transfers, @"in1", @"mei", contents, 0, contents.length),
               @"none of them disturbed Mei's own stream");
    SZFTExpect(![transfers finishTransfer:@"in1" finalDigest:SZFTBlake2b(contents) fromConversation:nobody
                                    error:&error], @"DONE from no conversation");
    SZFTExpect([transfers finishTransfer:@"in1" finalDigest:SZFTBlake2b(contents) fromConversation:@"mei"
                                   error:&error], @"Mei's DONE: %@", error);
    SZFTExpect([transfers transferWithID:@"in1" inConversation:@"mei"] &&
                   ![transfers transferWithID:@"in1" inConversation:@"kenji"], @"lookups scoped to the owner");
    NSString *source = [SZFTTemporaryDirectory(@"source") stringByAppendingPathComponent:@"Ours.pdf"];
    [contents writeToFile:source atomically:NO];
    SZFriendsTransferRecord *ours = [transfers stageOutgoingFileAtPath:source revision:nil conversationID:@"mei"
                                                                 error:NULL];
    SZFTExpect(![transfers markOfferDelivered:ours.transferID fromConversation:@"kenji" error:&error] &&
                   error.code == SZFriendsStoreErrorInvalid, @"Kenji cannot acknowledge an offer to Mei");
    SZFTExpect(![transfers markOfferDelivered:ours.transferID fromConversation:nobody error:&error],
               @"nor can no one");
    SZFTExpect([transfers markOfferDelivered:ours.transferID fromConversation:@"mei" error:&error] &&
                   [transfers transferWithID:ours.transferID].state == SZFriendsTransferStateOffered, @"Mei can");
    // The outbox: an ACK counts only from the conversation the entry is queued to.
    SZFriendsOutbox *outbox = [[SZFriendsOutbox alloc] initWithStore:store];
    SZFriendsOutboxEntry *entry = [[SZFriendsOutboxEntry alloc] init];
    entry.entryID = SZFriendsNewIdentifier();
    entry.conversationID = @"mei";
    entry.kind = SZFriendsOutboxKindMessage;
    [outbox enqueue:entry error:NULL];
    SZFTExpect(![outbox applyEvent:SZFriendsOutboxEventAcknowledged toEntry:entry.entryID fromConversation:@"kenji"
                             error:&error] && error.code == SZFriendsStoreErrorInvalid, @"Kenji's ACK is refused");
    SZFTExpect(![outbox applyEvent:SZFriendsOutboxEventAcknowledged toEntry:entry.entryID fromConversation:nobody
                             error:&error], @"an ACK from no conversation too");
    SZFTExpect([outbox entryWithID:entry.entryID].state == SZFriendsOutboxStateQueued, @"still queued");
    SZFTExpect([outbox applyEvent:SZFriendsOutboxEventAcknowledged toEntry:entry.entryID fromConversation:@"mei"
                            error:&error] &&
                   [outbox entryWithID:entry.entryID].state == SZFriendsOutboxStateDelivered, @"Mei's ACK delivers");
}

// What the swap hook below replaces with a symlink, and at which test point.
static NSString *SZFTSwapPath, *SZFTSwapTarget;
static const char *SZFTSwapPoint;

static void SwapForSymlink(const char *point) {
    if (!SZFTSwapPoint || strcmp(point, SZFTSwapPoint) != 0) return;
    unlink(SZFTSwapPath.fileSystemRepresentation);
    symlink(SZFTSwapTarget.fileSystemRepresentation, SZFTSwapPath.fileSystemRepresentation);
}

static SZFriendsTransferRecord *_Nullable StageSwapped(SZFriendsTransfers *transfers, NSString *path, NSData *checked,
                                                       const char *point, NSError **error) {
    unlink(path.fileSystemRepresentation);
    [checked writeToFile:path atomically:NO];
    SZFTSwapPath = path;
    SZFTSwapPoint = point;
    SZFriendsStoreTestHook = SwapForSymlink;
    SZFriendsTransferRecord *staged = [transfers stageOutgoingFileAtPath:path revision:nil conversationID:@"mei"
                                                                   error:error];
    SZFriendsStoreTestHook = NULL;
    SZFTSwapPoint = NULL;
    return staged;
}

// Wave-3 re-check, file promises: a promise source passes the drop's lstat with report.pdf, then swaps it for a
// symlink to ~/Documents/tax.pdf before the helper snapshots it. The snapshot once followed the link (stat,
// clonefile, copyfile) and sent tax.pdf under the name report.pdf.
static void TestSnapshotsNeverFollowASymlink(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"symlink"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = Roomy(store);
    NSString *tax = [SZFTTemporaryDirectory(@"documents") stringByAppendingPathComponent:@"tax.pdf"];
    NSData *secret = [@"the tax return nobody chose to send" dataUsingEncoding:NSUTF8StringEncoding];
    [secret writeToFile:tax atomically:NO];
    SZFTSwapTarget = tax;
    NSString *promises = SZFTTemporaryDirectory(@"promise");
    NSString *report = [promises stringByAppendingPathComponent:@"report.pdf"];
    NSData *checked = [@"the report the person dropped" dataUsingEncoding:NSUTF8StringEncoding];
    for (int copy = 0; copy < 2; copy++) {
        SZFriendsSnapshotDisableClone = copy == 1; // the clone and the copy alike
        unlink(report.fileSystemRepresentation);
        symlink(tax.fileSystemRepresentation, report.fileSystemRepresentation);
        NSError *error = nil;
        SZFTExpect(![transfers stageOutgoingFileAtPath:report revision:nil conversationID:@"mei" error:&error] &&
                       [SZFriendsStoreProtocolErrorCode(error) isEqualToString:@"file_missing"],
                   @"a symlink is refused, not followed (copy %d): %@", copy, error);
        SZFTExpect(!StageSwapped(transfers, report, checked, "snapshot.after_lstat", &error) &&
                       error.code == SZFriendsStoreErrorFileMissing,
                   @"so is one swapped in between the check and the open (copy %d): %@", copy, error);
        SZFriendsTransferRecord *staged = StageSwapped(transfers, report, checked, "snapshot.after_open", &error);
        SZFTExpect(staged && [[NSData dataWithContentsOfFile:staged.stagedPath] isEqualToData:checked] &&
                       [staged.contentDigest isEqualToData:SZFTBlake2b(checked)] && staged.size == checked.length,
                   @"swapped after the open, what was checked is what is sent (copy %d): %@", copy, error);
    }
    SZFriendsSnapshotDisableClone = NO;
    NSString *outgoing = [store.stateDirectory stringByAppendingPathComponent:@"outgoing"];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:outgoing error:NULL]) {
        NSString *path = [outgoing stringByAppendingPathComponent:name];
        SZFTExpect(!SZFTFileContains(path, secret), @"no snapshot holds the link's target: %@", name);
    }
    // A link to a folder is still a link: refused as one, never walked into.
    NSString *folderLink = [promises stringByAppendingPathComponent:@"Folder"];
    symlink(SZFTTemporaryDirectory(@"folder").fileSystemRepresentation, folderLink.fileSystemRepresentation);
    NSError *error = nil;
    SZFTExpect(![transfers stageOutgoingFileAtPath:folderLink revision:nil conversationID:@"mei" error:&error] &&
                   error.code == SZFriendsStoreErrorFileMissing, @"a link to a folder: %@", error);
    // Still a real clone: with no room at all only a clone succeeds, so a clone call that refused its flags and fell
    // back to copying every file would show here.
    SZFriendsTransfers *noRoom = [[SZFriendsTransfers alloc] initWithStore:store stateDirectory:store.stateDirectory];
    noRoom.freeBytesProvider = ^uint64_t(NSString *path) {
        (void)path;
        return 0;
    };
    unlink(report.fileSystemRepresentation);
    [checked writeToFile:report atomically:NO];
    SZFTExpect([noRoom stageOutgoingFileAtPath:report revision:nil conversationID:@"mei" error:&error] != nil,
               @"cloned from the descriptor, needing no space: %@", error);
}

void SZFTRunTransferSafetyTests(void) {
    TestIdsDifferingInCaseNeverShareAFile();
    TestStagingFilesAreNamedByThisMac();
    TestPublishingChecksTheFileOnDisk();
    TestPeerCallsNeedTheOwningConversation();
    TestSnapshotsNeverFollowASymlink();
}
