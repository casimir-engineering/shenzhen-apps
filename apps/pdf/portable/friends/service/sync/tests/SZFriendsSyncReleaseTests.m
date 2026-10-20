// friends-sync-check, ADR 0016: a device that no longer has a file's bytes stops counting as one that holds them, on
// every device, whichever way its FILE HELD events reach them; what the person moved or deleted never copies back by
// itself, and Get brings it back into the folder received files go to; the device that sent a file holds it while the
// file it was sent from is unchanged.

#import "SZFriendsSyncTestSupport.h"

SZFriendsTransferRecord *SZFSStageFile(SZFSDevice *device, NSString *conversation, NSString *itemID, uint64_t size);

// One session between a and b, run until neither has anything left to say.
static void Session(SZFSDevice *a, SZFSDevice *b) {
    NSMutableArray<NSData *> *toA = [NSMutableArray array], *toB = [NSMutableArray array];
    SZFriendsSyncExchange *ea = [[SZFriendsSyncExchange alloc] initWithEngine:a.engine peerKey:b.identity.publicKey
                                                                          send:^(NSData *m) { [toB addObject:m]; }];
    SZFriendsSyncExchange *eb = [[SZFriendsSyncExchange alloc] initWithEngine:b.engine peerKey:a.identity.publicKey
                                                                          send:^(NSData *m) { [toA addObject:m]; }];
    [ea start];
    [eb start];
    for (NSUInteger rounds = 0; (toA.count > 0 || toB.count > 0) && rounds < 100000; rounds++) {
        if (toB.count > 0) {
            NSData *message = toB.firstObject;
            [toB removeObjectAtIndex:0];
            SZFSExpect([eb receiveMessage:message error:NULL], @"b took a message");
        }
        if (toA.count > 0) {
            NSData *message = toA.firstObject;
            [toA removeObjectAtIndex:0];
            SZFSExpect([ea receiveMessage:message error:NULL], @"a took a message");
        }
    }
    [ea stop];
    [eb stop];
}

static BOOL Holds(SZFSDevice *on, NSString *transferID, SZFSDevice *holder) {
    return [[on.store syncFileWithID:transferID].holders containsObject:holder.identity.publicKey];
}

static void TestDeletedCopyIsReleasedAndGetBringsItBack(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"release", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFriendsTransferRecord *file = SZFSStageFile(a, @"mei", @"f1", 20000);
    [a.engine captureLocalChanges];
    Session(a, b);
    SZFriendsTransferRecord *copy = [b.store transferRecordWithID:file.transferID];
    SZFSExpect(copy.receivedPath != nil && [b.engine localPathOfFile:file.transferID] != nil, @"a small file copies");
    Session(a, b);
    SZFSExpect(Holds(a, file.transferID, b) && Holds(b, file.transferID, b), @"b holds it, as a knows");

    // The person deletes it on b: b says it no longer holds it, and a hears so.
    [NSFileManager.defaultManager removeItemAtPath:copy.receivedPath error:NULL];
    [b.engine captureLocalChanges];
    SZFSExpect(!Holds(b, file.transferID, b), @"b no longer counts itself");
    Session(a, b);
    SZFSExpect(!Holds(a, file.transferID, b) && Holds(a, file.transferID, a), @"a hears b let it go");
    SZFSExpect([b.engine filesWanted].count == 0 && [b.engine localPathOfFile:file.transferID] == nil,
               @"what the person deleted does not copy back by itself");
    // c hears b's held and released together: b is not listed there either.
    Session(b, c);
    SZFSExpect(!Holds(c, file.transferID, b) && Holds(c, file.transferID, a), @"c: only a holds it");

    // Get: copied again from a into the folder received files go to, and b holds it again everywhere.
    SZFSExpect([b.engine requestFile:file.transferID error:NULL] && [b.engine filesWanted].count == 1, @"Get");
    Session(a, b);
    NSString *back = [b.engine localPathOfFile:file.transferID];
    SZFSExpect(back != nil && ![b.engine isFileRequested:file.transferID], @"back after Get: %@", back);
    SZFSExpect([[b.store transferRecordWithID:file.transferID].receivedPath isEqualToString:back],
               @"the row points at the new copy");
    Session(a, b);
    Session(b, c);
    SZFSExpect(Holds(a, file.transferID, b) && Holds(c, file.transferID, b), @"b holds it again, everywhere");
}

static void TestSenderHoldsWhileTheFileIsUnchanged(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"source", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFriendsTransferRecord *file = SZFSStageFile(a, @"mei", @"big", SZFriendsSyncAutoCopyMax + 1);
    SZFSExpect(file.sourcePath != nil && file.sourceModifiedNs != 0, @"where it was sent from is kept");
    // Delivered: the snapshot goes, and the file it was sent from still holds the same bytes.
    [NSFileManager.defaultManager removeItemAtPath:file.stagedPath error:NULL];
    [a.engine captureLocalChanges];
    SZFSExpect([[a.engine localPathOfFile:file.transferID] isEqualToString:file.sourcePath] &&
                   Holds(a, file.transferID, a),
               @"held from where it was sent");
    // The person edits that file: a no longer has what it sent.
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:file.sourcePath];
    [handle seekToFileOffset:10];
    [handle writeData:[@"edited" dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
    NSDate *later = [NSDate dateWithTimeIntervalSinceNow:5];
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate : later} ofItemAtPath:file.sourcePath
                                          error:NULL];
    [a.engine captureLocalChanges];
    SZFSExpect([a.engine localPathOfFile:file.transferID] == nil && !Holds(a, file.transferID, a),
               @"an edited file is not the file it sent");
    Session(a, b);
    SZFSExpect([b.store syncFileWithID:file.transferID].holders.count == 0, @"b sees nobody holds it");
}

void SZFSRunReleaseTests(void) {
    TestDeletedCopyIsReleasedAndGetBringsItBack();
    TestSenderHoldsWhileTheFileIsUnchanged();
}
