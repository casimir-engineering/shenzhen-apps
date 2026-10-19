// Receiving: chunk checks, durable progress, digest verification, publishing without overwrites, resume.

#import <sys/xattr.h>
#import <unistd.h>

#import "SZFriendsStoreTestSupport.h"

static SZFriendsTransfers *Receiver(SZFriendsStore *store) {
    SZFriendsTransfers *transfers = [[SZFriendsTransfers alloc] initWithStore:store
        stateDirectory:store.stateDirectory];
    transfers.freeBytesProvider = ^uint64_t(NSString *path) {
        (void)path;
        return 1ULL << 40;
    };
    return transfers;
}

static void Accept(SZFriendsTransfers *transfers, NSString *transferID, NSString *conversationID, NSString *name,
                   NSData *contents) {
    NSError *error = nil;
    SZFriendsTransferRecord *offer = [transfers recordIncomingOfferWithID:transferID conversationID:conversationID
                                                                 fileName:name uniformType:nil size:contents.length
                                                            contentDigest:SZFTBlake2b(contents)
                                                                   sentAt:[NSDate date] error:&error];
    BOOL accepted = offer && [transfers acceptTransfer:transferID automatically:NO error:&error];
    if (!accepted) fprintf(stderr, "accept %s failed: %s\n", transferID.UTF8String,
        error.localizedDescription.UTF8String);
}

static BOOL Send(SZFriendsTransfers *transfers, NSString *transferID, NSData *contents, NSUInteger from,
                 NSUInteger chunk) {
    for (NSUInteger offset = from; offset < contents.length; offset += chunk) {
        NSData *piece = [contents subdataWithRange:NSMakeRange(offset, MIN(chunk, contents.length - offset))];
        if (![transfers appendChunk:piece atOffset:offset toTransfer:transferID fromConversation:@"mei" error:NULL]) {
            return NO;
        }
    }
    return YES;
}

static NSString *Quarantine(NSString *path) {
    char value[256] = {0};
    ssize_t length = getxattr(path.fileSystemRepresentation, "com.apple.quarantine", value, sizeof value - 1, 0, 0);
    return length > 0 ? @(value) : @"";
}

static void TestReceiveVerifyAndPublish(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"receive"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFTAddPerson(store, @"kenji", 3, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = Receiver(store);
    NSData *contents = SZFTRandomData(200000);
    NSError *error = nil;
    SZFTExpect(![transfers appendChunk:contents atOffset:0 toTransfer:@"r1" fromConversation:@"mei" error:&error],
               @"no chunk before an offer exists");
    [transfers recordIncomingOfferWithID:@"r1" conversationID:@"mei" fileName:@"Site photos.pdf" uniformType:nil
                                    size:contents.length contentDigest:SZFTBlake2b(contents) sentAt:[NSDate date]
                                   error:NULL];
    SZFTExpect(![transfers appendChunk:[contents subdataWithRange:NSMakeRange(0, 10)] atOffset:0 toTransfer:@"r1"
                      fromConversation:@"mei" error:&error], @"no chunk before acceptance (unsolicited)");
    [transfers acceptTransfer:@"r1" automatically:NO error:NULL];
    NSString *partial = SZFTScalar(store, @"SELECT partial_path FROM transfers WHERE transfer_id = 'r1'", @[]);
    SZFTExpect([Quarantine(partial) hasPrefix:@"0081;"], @"quarantined from the first byte: %@", Quarantine(partial));
    NSData *first = [contents subdataWithRange:NSMakeRange(0, 60000)];
    SZFTExpect(![transfers appendChunk:first atOffset:0 toTransfer:@"r1" fromConversation:@"kenji" error:&error] &&
                   error.code == SZFriendsStoreErrorInvalid, @"another friend's chunk is refused");
    SZFTExpect(![transfers appendChunk:first atOffset:5 toTransfer:@"r1" fromConversation:@"mei" error:&error],
               @"a chunk must start at the verified count");
    SZFTExpect(Send(transfers, @"r1", contents, 0, 60000), @"chunks");
    SZFTExpect(![transfers appendChunk:first atOffset:contents.length toTransfer:@"r1" fromConversation:@"mei"
                                 error:&error], @"nothing beyond the declared size");
    SZFTExpect([transfers transferWithID:@"r1"].verifiedBytes == contents.length,
        @"complete files are durable at once");
    SZFTExpect([transfers finishTransfer:@"r1" finalDigest:SZFTBlake2b(contents) fromConversation:@"mei" error:&error],
               @"finish: %@", error);
    SZFriendsTransferRecord *record = [transfers transferWithID:@"r1"];
    NSString *expected = [transfers.receivedDirectory stringByAppendingPathComponent:@"Site photos.pdf"];
    SZFTExpect(record.state == SZFriendsTransferStateReceived && [record.receivedPath isEqualToString:expected],
               @"published at %@", record.receivedPath);
    SZFTExpect([[NSData dataWithContentsOfFile:expected] isEqualToData:contents], @"the bytes that were offered");
    NSString *mark = Quarantine(expected);
    SZFTExpect([mark hasPrefix:@"0081;"] && [mark containsString:@";Shenzhen Friends;"], @"quarantine: %@", mark);
    SZFTExpect(![NSFileManager.defaultManager fileExistsAtPath:partial], @"no staging file left");
    SZFTExpect(![transfers finishTransfer:@"r1" finalDigest:SZFTBlake2b(contents) fromConversation:@"mei"
                                    error:&error], @"once only");
    // The same name again, plus a dangling symlink planted where the next name would go: neither is overwritten.
    NSString *outside = [SZFTTemporaryDirectory(@"outside") stringByAppendingPathComponent:@"stolen"];
    symlink(outside.fileSystemRepresentation,
            [transfers.receivedDirectory stringByAppendingPathComponent:@"Site photos 2.pdf"].fileSystemRepresentation);
    NSData *second = SZFTRandomData(1000);
    Accept(transfers, @"r2", @"mei", @"Site photos.pdf", second);
    Send(transfers, @"r2", second, 0, 400);
    [transfers finishTransfer:@"r2" finalDigest:SZFTBlake2b(second) fromConversation:@"mei" error:NULL];
    SZFTExpect([[transfers transferWithID:@"r2"].receivedPath.lastPathComponent isEqualToString:@"Site photos 3.pdf"],
               @"next free name: %@", [transfers transferWithID:@"r2"].receivedPath);
    SZFTExpect([[NSData dataWithContentsOfFile:expected] isEqualToData:contents], @"the first file is untouched");
    SZFTExpect(![NSFileManager.defaultManager fileExistsAtPath:outside], @"the symlink was not followed");
    SZFTExpect(![transfers cancelTransfer:@"r2" error:&error] &&
                   [NSFileManager.defaultManager fileExistsAtPath:[transfers transferWithID:@"r2"].receivedPath],
               @"Cancel cannot retract what arrived");
}

static NSString *SZFTRacePath;

static void PlantDuringPublish(const char *point) {
    if (strcmp(point, "transfer.before_rename") == 0 && SZFTRacePath) {
        [[@"someone else's file" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:SZFTRacePath atomically:NO];
        SZFTRacePath = nil; // once: the retry must find the next name free
    }
}

static void TestPublishingNeverOverwritesEvenInARace(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"race"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = Receiver(store);
    NSData *contents = SZFTRandomData(3000);
    Accept(transfers, @"x1", @"mei", @"Race.pdf", contents);
    Send(transfers, @"x1", contents, 0, 3000);
    // A file appears at the chosen name after it was chosen and before the rename.
    SZFTRacePath = [transfers.receivedDirectory stringByAppendingPathComponent:@"Race.pdf"];
    NSString *planted = SZFTRacePath;
    SZFriendsStoreTestHook = PlantDuringPublish;
    NSError *error = nil;
    BOOL finished = [transfers finishTransfer:@"x1" finalDigest:SZFTBlake2b(contents) fromConversation:@"mei"
                                        error:&error];
    SZFriendsStoreTestHook = NULL;
    SZFTExpect(finished, @"published: %@", error);
    SZFTExpect([[NSString stringWithContentsOfFile:planted encoding:NSUTF8StringEncoding error:NULL]
                   isEqualToString:@"someone else's file"], @"the file that appeared is untouched");
    SZFriendsTransferRecord *record = [transfers transferWithID:@"x1"];
    SZFTExpect([record.receivedPath.lastPathComponent isEqualToString:@"Race 2.pdf"] &&
                   [[NSData dataWithContentsOfFile:record.receivedPath] isEqualToData:contents],
               @"ours went to the next name: %@", record.receivedPath);
}

static void TestDigestMismatchThenTryAgain(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"mismatch"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = Receiver(store);
    NSData *contents = SZFTRandomData(5000);
    Accept(transfers, @"m1", @"mei", @"Report.pdf", contents);
    NSMutableData *corrupt = [contents mutableCopy];
    ((uint8_t *)corrupt.mutableBytes)[1234] ^= 0x40;
    Send(transfers, @"m1", corrupt, 0, 1000);
    NSError *error = nil;
    SZFTExpect(![transfers finishTransfer:@"m1" finalDigest:SZFTBlake2b(contents) fromConversation:@"mei"
                                    error:&error] &&
                   error.code == SZFriendsStoreErrorDigestMismatch, @"corrupted bytes are refused: %@", error);
    SZFriendsTransferRecord *record = [transfers transferWithID:@"m1"];
    SZFTExpect(record.state == SZFriendsTransferStateFailed && record.verifiedBytes == 0 &&
                   [record.failureReason isEqualToString:SZFriendsTransferFailureDigestMismatch], @"failed");
    NSArray *published = [NSFileManager.defaultManager contentsOfDirectoryAtPath:transfers.receivedDirectory
        error:NULL];
    SZFTExpect([published isEqual:@[ @".partial" ]], @"nothing published: %@", published);
    SZFTExpect([transfers retryTransfer:@"m1" error:&error], @"Try again: %@", error);
    SZFTExpect([transfers transferWithID:@"m1"].state == SZFriendsTransferStateReceiving, @"receiving again");
    SZFTExpect(Send(transfers, @"m1", contents, 0, 999), @"resent from zero");
    SZFTExpect([transfers finishTransfer:@"m1" finalDigest:SZFTBlake2b(contents) fromConversation:@"mei"
                                   error:&error], @"now it matches");
    Accept(transfers, @"m2", @"mei", @"Other.pdf", contents);
    Send(transfers, @"m2", contents, 0, 5000);
    SZFTExpect(![transfers finishTransfer:@"m2" finalDigest:SZFTBytes(9, 32) fromConversation:@"mei" error:&error] &&
                   error.code == SZFriendsStoreErrorDigestMismatch, @"DONE must carry the offered digest");
}

static void TestDurableProgressBatchesAndResumes(void) {
    NSString *directory = SZFTTemporaryDirectory(@"durable");
    SZFriendsStore *store = SZFTOpenStore(directory);
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = Receiver(store);
    __block NSDate *now = [NSDate dateWithTimeIntervalSince1970:1000000];
    transfers.receiver.clock = ^NSDate * { return now; };
    const NSUInteger MiB = 1 << 20;
    NSData *contents = SZFTRandomData(10 * MiB);
    Accept(transfers, @"d1", @"mei", @"Big.bin", contents);
    NSError *error = nil;
    for (NSUInteger i = 0; i < 3; i++) {
        [transfers appendChunk:[contents subdataWithRange:NSMakeRange(i * MiB, MiB)] atOffset:i * MiB toTransfer:@"d1"
                         fromConversation:@"mei" error:NULL];
    }
    SZFTExpect([transfers transferWithID:@"d1"].verifiedBytes == 0, @"3 MiB within a second is not committed yet");
    [transfers appendChunk:[contents subdataWithRange:NSMakeRange(3 * MiB, MiB)] atOffset:3 * MiB toTransfer:@"d1"
                     fromConversation:@"mei" error:NULL];
    SZFTExpect([transfers transferWithID:@"d1"].verifiedBytes == 4 * MiB, @"4 MiB commits");
    [transfers appendChunk:[contents subdataWithRange:NSMakeRange(4 * MiB, 1000)] atOffset:4 * MiB toTransfer:@"d1"
                     fromConversation:@"mei" error:NULL];
    SZFTExpect([transfers transferWithID:@"d1"].verifiedBytes == 4 * MiB, @"a small chunk waits");
    now = [now dateByAddingTimeInterval:1.5];
    [transfers appendChunk:[contents subdataWithRange:NSMakeRange(4 * MiB + 1000, 1000)] atOffset:4 * MiB + 1000
                toTransfer:@"d1" fromConversation:@"mei" error:NULL];
    SZFTExpect([transfers transferWithID:@"d1"].verifiedBytes == 4 * MiB + 2000, @"a second later it commits");
    [transfers appendChunk:[contents subdataWithRange:NSMakeRange(4 * MiB + 2000, 3000)] atOffset:4 * MiB + 2000
                toTransfer:@"d1" fromConversation:@"mei" error:NULL];
    SZFTExpect([transfers flushProgressWithError:&error] &&
                   [transfers transferWithID:@"d1"].verifiedBytes == 4 * MiB + 5000, @"flush commits the rest");
    [transfers appendChunk:[contents subdataWithRange:NSMakeRange(4 * MiB + 5000, 7000)] atOffset:4 * MiB + 5000
                toTransfer:@"d1" fromConversation:@"mei" error:NULL];
    // A restart forgets the 7000 bytes written after the last commit: resume starts from what is durable.
    [store close];
    SZFriendsStore *reopened = SZFTOpenStore(directory);
    SZFriendsTransfers *again = Receiver(reopened);
    SZFriendsTransferRecord *record = [again transferWithID:@"d1"];
    NSString *partial = SZFTScalar(reopened, @"SELECT partial_path FROM transfers WHERE transfer_id = 'd1'", @[]);
    NSNumber *size = [NSFileManager.defaultManager attributesOfItemAtPath:partial error:NULL][NSFileSize];
    SZFTExpect(record.verifiedBytes == 4 * MiB + 5000 && size.unsignedLongLongValue == record.verifiedBytes,
               @"staging file cut to the durable count: %llu vs %@", record.verifiedBytes, size);
    SZFTExpect([[again unfinishedIncomingTransfersForConversation:@"mei"] count] == 1, @"PROGRESS goes out for it");
    SZFTExpect(![again appendChunk:[contents subdataWithRange:NSMakeRange(4 * MiB + 12000, 10)] atOffset:4 * MiB + 12000
                        toTransfer:@"d1" fromConversation:@"mei" error:&error],
               @"not from where the old helper stopped writing");
    SZFTExpect(Send(again, @"d1", contents, (NSUInteger)record.verifiedBytes, 256 * 1024), @"resume");
    SZFTExpect([again finishTransfer:@"d1" finalDigest:SZFTBlake2b(contents) fromConversation:@"mei" error:&error],
               @"the digest rebuilt from the durable prefix matches: %@", error);
}

void SZFTRunReceiveTests(void) {
    TestReceiveVerifyAndPublish();
    TestPublishingNeverOverwritesEvenInARace();
    TestDigestMismatchThenTryAgain();
    TestDurableProgressBatchesAndResumes();
}
