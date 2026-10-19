// friends-sync-check: two devices over SYNC messages. A device far behind catches up with at most SZFriendsSyncWindow
// EVENTS unacknowledged; new changes follow at once; a forged event ends the session; files copy whole, resume where a
// lost session left them, are refused when their bytes do not match the record, and a holder without the bytes says so.

#import "SZFriendsSyncTestSupport.h"

SZFriendsTransferRecord *SZFSStageFile(SZFSDevice *device, NSString *conversation, NSString *itemID, uint64_t size);

// Two exchanges joined by queues; run delivers until both are empty or the link is cut.
@interface SZFSPipe : NSObject
@property(nonatomic, strong) SZFriendsSyncExchange *a, *b;
@property(nonatomic, strong) NSMutableArray<NSData *> *toA, *toB;
@property(nonatomic) NSInteger inFlight, maxInFlight;
@property(nonatomic) NSInteger partsLeft; // cut the link after this many PART messages reach B (-1: never)
@property(nonatomic) BOOL broken;
@property(nonatomic, strong) NSMutableArray<NSData *> *wantsFromB;
@end

@implementation SZFSPipe
- (void)run {
    while (!self.broken && (self.toA.count > 0 || self.toB.count > 0)) {
        if (self.toB.count > 0) {
            NSData *message = self.toB.firstObject;
            [self.toB removeObjectAtIndex:0];
            if (((const uint8_t *)message.bytes)[0] == 5 && self.partsLeft >= 0 && self.partsLeft-- == 0) {
                self.broken = YES;
                break;
            }
            if (![self.b receiveMessage:message error:NULL]) self.broken = YES;
        }
        if (self.toA.count > 0) {
            NSData *message = self.toA.firstObject;
            [self.toA removeObjectAtIndex:0];
            if (((const uint8_t *)message.bytes)[0] == 3) self.inFlight--;
            if (![self.a receiveMessage:message error:NULL]) self.broken = YES;
        }
    }
}
@end

static SZFSPipe *SZFSConnect(SZFSDevice *a, SZFSDevice *b) {
    SZFSPipe *pipe = [[SZFSPipe alloc] init];
    pipe.toA = [NSMutableArray array];
    pipe.toB = [NSMutableArray array];
    pipe.wantsFromB = [NSMutableArray array];
    pipe.partsLeft = -1;
    __weak SZFSPipe *weak = pipe;
    pipe.a = [[SZFriendsSyncExchange alloc] initWithEngine:a.engine peerKey:b.identity.publicKey
                                                      send:^(NSData *message) {
                                                          SZFSPipe *strong = weak;
                                                          if (((const uint8_t *)message.bytes)[0] == 2) {
                                                              strong.inFlight++;
                                                              strong.maxInFlight = MAX(strong.maxInFlight,
                                                                                       strong.inFlight);
                                                          }
                                                          [strong.toB addObject:message];
                                                      }];
    pipe.b = [[SZFriendsSyncExchange alloc] initWithEngine:b.engine peerKey:a.identity.publicKey
                                                      send:^(NSData *message) {
                                                          SZFSPipe *strong = weak;
                                                          if (((const uint8_t *)message.bytes)[0] == 4) {
                                                              [strong.wantsFromB addObject:message];
                                                          }
                                                          [strong.toA addObject:message];
                                                      }];
    SZFriendsSyncExchange *exchangeA = pipe.a, *exchangeB = pipe.b;
    a.engine.onNewEvents = ^{ [exchangeA pump]; };
    b.engine.onNewEvents = ^{ [exchangeB pump]; };
    [pipe.a start];
    [pipe.b start];
    [pipe run];
    return pipe;
}

static void TestCatchUpWithinWindow(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"catchup", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    SZFSAddFriend(a, 0x90, @"mei");
    [a.store performSyncTransaction:^BOOL(NSError **error) {
        (void)error;
        for (int i = 0; i < 1500; i++) {
            SZFSInsertMessage(a, @"mei", [NSString stringWithFormat:@"m%04d", i], @"lorem ipsum dolor sit amet",
                              i % 3 ? SZFriendsDirectionIncoming : SZFriendsDirectionOutgoing, 1000 + i);
        }
        return YES;
    } error:NULL];
    [a.engine captureLocalChanges];
    SZFSPipe *pipe = SZFSConnect(a, b);
    SZFSExpect(!pipe.broken && pipe.maxInFlight <= (NSInteger)SZFriendsSyncWindow && pipe.maxInFlight > 1,
               @"window kept: at most %ld in flight", (long)pipe.maxInFlight);
    SZFSExpect(pipe.a.peerCaughtUp && pipe.b.peerCaughtUp, @"both caught up");
    SZFSExpect([SZFSDump(a) isEqualToString:SZFSDump(b)], @"same store after catching up");
    // Live: a new message on A reaches B as soon as it is captured.
    SZFSInsertMessage(a, @"mei", @"live", @"just now", SZFriendsDirectionIncoming, 9000);
    [a.engine captureLocalChanges];
    [pipe run];
    SZFSExpect([b.store itemWithID:@"live" inConversation:@"mei"] != nil, @"new changes follow at once");
}

static void TestForgedEventEndsSession(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"forged", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    a.store.profileName = @"Raph";
    [a.engine captureLocalChanges];
    SZFriendsSyncEvent *event = [a.engine eventsMissingFrom:@{} limit:1].firstObject;
    NSMutableData *header = [event.header mutableCopy];
    ((uint8_t *)header.mutableBytes)[header.length - 1] ^= 0x80;
    NSMutableData *message = [NSMutableData dataWithBytes:(uint8_t[]){2, 0, 1} length:3];
    [message appendBytes:(uint8_t[]){(uint8_t)(header.length >> 8), (uint8_t)header.length} length:2];
    [message appendData:header];
    [message appendBytes:(uint8_t[]){0} length:1];
    SZFriendsSyncExchange *exchange = [[SZFriendsSyncExchange alloc] initWithEngine:b.engine
                                                                           peerKey:a.identity.publicKey
                                                                              send:^(NSData *m) { (void)m; }];
    NSError *error = nil;
    SZFSExpect(![exchange receiveMessage:message error:&error] && error.code == SZFriendsSyncErrorForged,
               @"a forged event breaks the session: %@", error);
    SZFSExpect([b.store syncEventCount] == 0, @"nothing kept");
    uint8_t junk[] = {9, 1, 2};
    SZFSExpect(![exchange receiveMessage:[NSData dataWithBytes:junk length:3] error:NULL], @"unknown message");
}

static NSData *SZFSFileBytes(NSString *path) {
    return [NSData dataWithContentsOfFile:path];
}

static void TestFileCopies(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"copy", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFriendsTransferRecord *staged = SZFSStageFile(a, @"mei", @"f1", 300 * 1024 + 17);
    [a.engine captureLocalChanges];
    SZFSPipe *pipe = SZFSConnect(a, b);
    SZFriendsTransferRecord *copy = [b.store transferRecordWithID:staged.transferID];
    NSData *original = SZFSFileBytes(staged.stagedPath);
    SZFSExpect(copy.receivedPath != nil && [SZFSFileBytes(copy.receivedPath) isEqualToData:original],
               @"the bytes arrived whole: %@", copy);
    SZFSExpect([copy.receivedPath hasPrefix:b.engine.receivedDirectory], @"in received/");
    [pipe run];
    SZFSExpect([[a.store syncFileWithID:staged.transferID].holders containsObject:b.identity.publicKey],
               @"A learns B holds it too");
    SZFSExpect([b.engine filesWanted].count == 0, @"nothing left to copy");
}

static void TestCopyResumes(void) {
    // The session ends after five parts arrived; the next one goes on from there.
    NSArray<SZFSDevice *> *again = SZFSDevices(@"resume2", 2);
    SZFSDevice *c = again[0], *d = again[1];
    SZFSAddFriend(c, 0x90, @"mei");
    SZFriendsTransferRecord *file = SZFSStageFile(c, @"mei", @"f1", 1024 * 1024 + 5);
    [c.engine captureLocalChanges];
    SZFSDeliver(c, d);
    SZFSPipe *cut = [[SZFSPipe alloc] init];
    cut.toA = [NSMutableArray array];
    cut.toB = [NSMutableArray array];
    cut.wantsFromB = [NSMutableArray array];
    cut.partsLeft = 5;
    __weak SZFSPipe *weakCut = cut;
    cut.a = [[SZFriendsSyncExchange alloc] initWithEngine:c.engine peerKey:d.identity.publicKey
                                                     send:^(NSData *m) { [weakCut.toB addObject:m]; }];
    cut.b = [[SZFriendsSyncExchange alloc] initWithEngine:d.engine peerKey:c.identity.publicKey
                                                     send:^(NSData *m) { [weakCut.toA addObject:m]; }];
    [cut.a start];
    [cut.b start];
    [cut run];
    [cut.a stop];
    [cut.b stop];
    SZFSExpect(cut.broken && [d.store transferRecordWithID:file.transferID] == nil, @"cut mid-copy");
    SZFSPipe *second = SZFSConnect(c, d);
    SZFSExpect([d.store transferRecordWithID:file.transferID] != nil, @"the next session finishes it");
    NSData *firstWant = second.wantsFromB.firstObject;
    const uint8_t *wantBytes = firstWant.bytes;
    uint64_t offset = firstWant.length >= 11 ? SZFriendsSyncGetU64(wantBytes + firstWant.length - 10) : 0;
    SZFSExpect(offset == 5 * SZFriendsSyncFilePartMax, @"resumed from what arrived: %llu", offset);
}

static void TestMismatchAndMissing(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"mismatch", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFriendsTransferRecord *bad = SZFSStageFile(a, @"mei", @"f1", 100 * 1024);
    SZFriendsTransferRecord *gone = SZFSStageFile(a, @"mei", @"f2", 1000);
    [a.engine captureLocalChanges];
    // Someone changed A's snapshot after the record was made; the other one is gone.
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:bad.stagedPath];
    [handle seekToFileOffset:5000];
    [handle writeData:[@"tampered" dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
    [NSFileManager.defaultManager removeItemAtPath:gone.stagedPath error:NULL];
    SZFSPipe *pipe = SZFSConnect(a, b);
    SZFSExpect(!pipe.broken, @"neither ends the session");
    SZFSExpect([b.store transferRecordWithID:bad.transferID] == nil, @"bytes that do not match are not kept");
    SZFSExpect([b.store transferRecordWithID:gone.transferID] == nil && pipe.b.filesInFlight == 0,
               @"a holder without the bytes says so, and nothing waits on it");
    NSString *partial = [b.engine.receivedDirectory stringByAppendingPathComponent:@".partial"];
    NSString *badPartial = [partial stringByAppendingPathComponent:[@"sync-" stringByAppendingString:bad.transferID]];
    SZFSExpect(![NSFileManager.defaultManager fileExistsAtPath:badPartial], @"the bad copy is removed");
}

// You: a message reaches "On all your computers" once every other device said it holds the event that carried it.
static void TestYouReachesEveryDevice(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"you", 3);
    SZFSDevice *a = devices[0], *b = devices[1], *c = devices[2];
    [a.store ensureYouConversation:NULL];
    SZFSInsertMessage(a, SZFriendsYouConversationID, @"y1", @"note to self", SZFriendsDirectionOutgoing, 7000);
    [a.engine captureLocalChanges];
    SZFSExpect(![a.engine itemReachedEveryDevice:@"y1" inConversation:SZFriendsYouConversationID], @"nowhere yet");
    SZFSConnect(a, b);
    SZFSExpect(![a.engine itemReachedEveryDevice:@"y1" inConversation:SZFriendsYouConversationID], @"C lacks it");
    SZFSExpect(![[a.engine itemsOnEveryDeviceInConversation:SZFriendsYouConversationID] containsObject:@"y1"],
               @"not in the set either");
    SZFSConnect(a, c);
    SZFSExpect([a.engine itemReachedEveryDevice:@"y1" inConversation:SZFriendsYouConversationID], @"everywhere");
    SZFSExpect([[a.engine itemsOnEveryDeviceInConversation:SZFriendsYouConversationID] containsObject:@"y1"],
               @"and in the set a snapshot reads");
}

// Get on a large file, then Cancel: the copy stops, and the file stays on the other computer until Get again.
static void TestCancelGet(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"cancel", 2);
    SZFSDevice *a = devices[0], *b = devices[1];
    SZFSAddFriend(a, 0x90, @"mei");
    SZFriendsTransferRecord *large = SZFSStageFile(a, @"mei", @"big", SZFriendsSyncAutoCopyMax + 1);
    [a.engine captureLocalChanges];
    SZFSDeliver(a, b);
    SZFSExpect([b.engine filesWanted].count == 0, @"a large file waits to be asked for");
    SZFSExpect([b.engine requestFile:large.transferID error:NULL] && [b.engine isFileRequested:large.transferID],
               @"Get");
    SZFSPipe *cut = [[SZFSPipe alloc] init];
    cut.toA = [NSMutableArray array];
    cut.toB = [NSMutableArray array];
    cut.partsLeft = 3;
    __weak SZFSPipe *weakCut = cut;
    cut.a = [[SZFriendsSyncExchange alloc] initWithEngine:a.engine peerKey:b.identity.publicKey
                                                     send:^(NSData *m) { [weakCut.toB addObject:m]; }];
    cut.b = [[SZFriendsSyncExchange alloc] initWithEngine:b.engine peerKey:a.identity.publicKey
                                                     send:^(NSData *m) { [weakCut.toA addObject:m]; }];
    [cut.a start];
    [cut.b start];
    [cut run];
    SZFSExpect([cut.b.copyingTransferID isEqualToString:large.transferID] && cut.b.copyingFraction > 0,
               @"copying: %@ %f", cut.b.copyingTransferID, cut.b.copyingFraction);
    SZFSExpect([cut.a.servingTransferID isEqualToString:large.transferID] && cut.a.servingFraction > 0,
               @"and A knows how far: %@", cut.a.servingTransferID);
    SZFSExpect([b.engine cancelFileRequest:large.transferID error:NULL], @"Cancel");
    [cut.b pump];
    SZFSExpect(cut.b.copyingTransferID == nil && ![b.engine isFileRequested:large.transferID] &&
                   [b.engine filesWanted].count == 0,
               @"the copy stops and nothing waits");
    [cut.a stop];
    [cut.b stop];
}

void SZFSRunExchangeTests(void) {
    TestYouReachesEveryDevice();
    TestCancelGet();
    TestCatchUpWithinWindow();
    TestForgedEventEndsSession();
    TestFileCopies();
    TestCopyResumes();
    TestMismatchAndMissing();
}
