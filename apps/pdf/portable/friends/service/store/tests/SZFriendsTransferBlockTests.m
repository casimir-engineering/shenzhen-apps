// Files by blocks on disk (ADR 0018 § 4 and 5): the offered tree, leaves before any part, blocks checked and written
// at their offsets, a corrupt block wanted again alone, durable batches with the prefix kept for older helpers, a
// restart that keeps blocks past the prefix and re-checks them, the publish check, and the sender's tree from staging.

#import <fcntl.h>
#import <sys/time.h>
#import <unistd.h>

#import "SZFriendsStoreTestSupport.h"

#import "service/transfer/SZFriendsBlockCopy.h"
#import "service/transfer/SZFriendsBlockExchange.h"
#import "service/transfer/SZFriendsBlockFlow.h"
#import "service/transfer/SZFriendsSlices.h"
#import "service/transfer/SZFriendsTransferBlocks.h"

static const NSUInteger MiB = 1 << 20;

SZFriendsTransfers *SZFTBlockTransfers(SZFriendsStore *store) {
    SZFriendsTransfers *transfers = [[SZFriendsTransfers alloc] initWithStore:store
                                                               stateDirectory:store.stateDirectory];
    transfers.freeBytesProvider = ^uint64_t(NSString *path) {
        (void)path;
        return 1ULL << 40;
    };
    return transfers;
}

static NSData *Leaves(NSData *contents, SZFriendsBlockGeometry geometry) {
    NSMutableData *leaves = [NSMutableData dataWithLength:geometry.blocks * 32];
    for (uint32_t i = 0; i < geometry.blocks; i++) {
        uint64_t offset = 0;
        NSUInteger length = 0;
        SZFriendsGeometrySpan(geometry, i, &offset, &length);
        SZFriendsTreeLeaf(i, (const uint8_t *)contents.bytes + offset, length, (uint8_t *)leaves.mutableBytes + i * 32);
    }
    return leaves;
}

// Sends block `index` in parts of 61,440 bytes; the last part's result.
static SZFriendsBlockPartResult SendBlock(SZFriendsTransfers *transfers, NSData *contents,
                                          SZFriendsBlockGeometry geometry, uint32_t index, BOOL corrupt) {
    uint64_t offset = 0;
    NSUInteger length = 0;
    SZFriendsGeometrySpan(geometry, index, &offset, &length);
    SZFriendsBlockPartResult result = SZFriendsBlockPartRefused;
    for (NSUInteger at = 0; at < length; at += 61440) {
        NSMutableData *part = [[contents subdataWithRange:NSMakeRange(offset + at, MIN(61440, length - at))] mutableCopy];
        if (corrupt && at == 0) ((uint8_t *)part.mutableBytes)[0] ^= 1;
        uint32_t block = 0;
        result = [transfers acceptBlockPart:part atOffset:offset + at forTransfer:@"b1" fromConversation:@"mei"
                                      block:&block error:NULL];
    }
    return result;
}

static BOOL MissingIs(SZFriendsTransfers *transfers, NSArray<NSNumber *> *pairs) {
    NSData *missing = [transfers blocksMissing:@"b1"];
    const uint32_t *got = missing.bytes;
    if (missing.length / 4 != pairs.count) return NO;
    for (NSUInteger i = 0; i < pairs.count; i++) {
        if (got[i] != pairs[i].unsignedIntValue) return NO;
    }
    return YES;
}

static void TestReceiveByBlocksThroughARestart(void) {
    NSString *directory = SZFTTemporaryDirectory(@"blocks");
    SZFriendsStore *store = SZFTOpenStore(directory);
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = SZFTBlockTransfers(store);
    NSData *contents = SZFTRandomData(5 * MiB + 123);
    SZFriendsBlockGeometry geometry;
    SZFriendsGeometryForSize(contents.length, &geometry);
    NSData *leaves = Leaves(contents, geometry);
    NSData *root = SZFriendsTreeRootOfLeaves(geometry, leaves);
    NSError *error = nil;
    [transfers recordIncomingOfferWithID:@"b1" conversationID:@"mei" fileName:@"Model.step" uniformType:nil
                                    size:contents.length contentDigest:SZFTBlake2b(contents) sentAt:[NSDate date]
                                   error:NULL];
    SZFTExpect(![transfers recordOfferedTree:@"b1" conversation:@"kenji" geometry:geometry root:root],
               @"only the friend who offered it");
    SZFTExpect([transfers recordOfferedTree:@"b1" conversation:@"mei" geometry:geometry root:root] &&
                   [transfers hasOfferedTree:@"b1"], @"the offered tree is kept");
    [transfers acceptTransfer:@"b1" automatically:NO error:NULL];
    SZFTExpect([transfers beginBlocks:@"b1" conversation:@"mei" error:&error], @"by blocks: %@", error);
    SZFTExpect(SendBlock(transfers, contents, geometry, 0, NO) == SZFriendsBlockPartEarly,
               @"a part before the leaves is dropped (a lane overtook HASHES), not taken");
    NSData *head = [leaves subdataWithRange:NSMakeRange(0, 3 * 32)];
    NSData *tail = [leaves subdataWithRange:NSMakeRange(3 * 32, leaves.length - 3 * 32)];
    SZFTExpect(![transfers acceptBlockHashes:tail index:2 forTransfer:@"b1" fromConversation:@"mei" error:NULL],
               @"leaves in order");
    NSMutableData *wrong = [tail mutableCopy];
    ((uint8_t *)wrong.mutableBytes)[0] ^= 1;
    SZFTExpect([transfers acceptBlockHashes:head index:0 forTransfer:@"b1" fromConversation:@"mei" error:NULL] &&
                   ![transfers acceptBlockHashes:wrong index:3 forTransfer:@"b1" fromConversation:@"mei" error:NULL],
               @"leaves that do not hash to the root are refused");
    SZFTExpect([transfers acceptBlockHashes:head index:0 forTransfer:@"b1" fromConversation:@"mei" error:NULL] &&
                   [transfers acceptBlockHashes:tail index:3 forTransfer:@"b1" fromConversation:@"mei" error:NULL],
               @"the right leaves, from the start again");
    SZFTExpect(SendBlock(transfers, contents, geometry, 0, NO) == SZFriendsBlockPartWritten &&
                   SendBlock(transfers, contents, geometry, 1, NO) == SZFriendsBlockPartWritten,
               @"blocks 0 and 1 check");
    SZFTExpect(SendBlock(transfers, contents, geometry, 0, NO) == SZFriendsBlockPartLate, @"a late copy is dropped");
    SZFTExpect(SendBlock(transfers, contents, geometry, 2, YES) == SZFriendsBlockPartCorrupt, @"a corrupt block");
    SZFTExpect(SendBlock(transfers, contents, geometry, 4, NO) == SZFriendsBlockPartWritten, @"block 4, out of order");
    SZFTExpect([transfers transferWithID:@"b1"].verifiedBytes == 0 && transfers.blocksPending, @"not durable yet");
    [transfers flushDueBlocks:YES];
    NSData *complete = nil, *durable = nil;
    [transfers takeBlockHave:@"b1" complete:&complete durable:&durable];
    const uint32_t *have = complete.bytes;
    SZFTExpect(complete.length == 16 && have[0] == 0 && have[1] == 2 && have[2] == 4 && have[3] == 1 &&
                   [durable isEqualToData:complete], @"HAVE: blocks 0, 1 and 4, written and durable");
    SZFTExpect([transfers transferWithID:@"b1"].verifiedBytes == 2 * MiB, @"the prefix, for older helpers");
    SZFTExpect(MissingIs(transfers, @[ @2, @2, @5, @1 ]), @"wanted again: 2 (corrupt), 3 and 5");

    // A restart: the blocks past the prefix stay, re-checked; one changed on disk meanwhile is wanted again.
    [store close];
    NSString *partial = SZFTScalar(SZFTOpenStore(directory), @"SELECT partial_path FROM transfers WHERE transfer_id = 'b1'", @[]);
    int fd = open(partial.fileSystemRepresentation, O_RDWR);
    pwrite(fd, "x", 1, 1 * MiB + 7);
    close(fd);
    SZFriendsStore *reopened = SZFTOpenStore(directory);
    SZFriendsTransfers *again = SZFTBlockTransfers(reopened);
    SZFTExpect([again beginBlocks:@"b1" conversation:@"mei" error:&error], @"resumes by blocks: %@", error);
    SZFTExpect(MissingIs(again, @[ @1, @3, @5, @1 ]), @"block 4 kept, block 1 changed on disk wanted again");
    SZFTExpect([again transferWithID:@"b1"].verifiedBytes == 1 * MiB, @"the prefix follows what checked");
    for (uint32_t block = 1; block < geometry.blocks; block++) {
        if (block != 4) SendBlock(again, contents, geometry, block, NO);
    }
    SZFTExpect([again blocksAllDurable:@"b1"], @"complete and durable");
    SZFTExpect([again finishBlockTransfer:@"b1" fromConversation:@"mei" error:&error], @"published: %@", error);
    SZFriendsTransferRecord *record = [again transferWithID:@"b1"];
    SZFTExpect(record.state == SZFriendsTransferStateReceived &&
                   [[NSData dataWithContentsOfFile:record.receivedPath] isEqualToData:contents],
               @"the bytes that were offered");
    NSString *map = [partial.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"b1.map"];
    SZFTExpect(![NSFileManager.defaultManager fileExistsAtPath:map], @"the map goes with it");
}

static void TestTheSenderSideFromStaging(void) {
    NSString *directory = SZFTTemporaryDirectory(@"blocks-send");
    SZFriendsStore *store = SZFTOpenStore(directory);
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = SZFTBlockTransfers(store);
    NSData *contents = SZFTRandomData(3 * MiB + 7);
    NSString *source = [SZFTTemporaryDirectory(@"blocks-source") stringByAppendingPathComponent:@"Part.step"];
    [contents writeToFile:source atomically:YES];
    SZFriendsTransferRecord *record = [transfers stageOutgoingFileAtPath:source revision:nil conversationID:@"mei"
                                                                   error:NULL];
    SZFriendsBlockGeometry geometry;
    NSData *root = nil, *leaves = nil;
    SZFTExpect([transfers senderTreeForTransfer:record compute:NO geometry:&geometry root:&root leaves:&leaves],
               @"staging wrote the tree beside the snapshot");
    SZFTExpect(geometry.blocks == 4 && [leaves isEqualToData:Leaves(contents, geometry)] &&
                   [record.contentDigest isEqualToData:SZFTBlake2b(contents)],
               @"the leaves and the digest from one pass");
    NSData *block = [transfers readOutgoingBlock:3 ofTransfer:record geometry:geometry];
    SZFTExpect(block.length == 7 && [block isEqualToData:[contents subdataWithRange:NSMakeRange(3 * MiB, 7)]],
               @"the last block is short");
    BOOL first = NO;
    NSError *error = nil;
    SZFTExpect([transfers peerTookBlocks:record.transferID fromConversation:@"kenji" first:&first error:&error] == nil,
               @"only the friend it was offered to");
    [transfers markOfferDelivered:record.transferID fromConversation:@"mei" error:NULL];
    SZFTExpect([transfers peerTookBlocks:record.transferID fromConversation:@"mei" first:&first error:&error] && first &&
                   [transfers transferWithID:record.transferID].state == SZFriendsTransferStateSending,
               @"taken by blocks: Sending, %@", error);
}


#pragma mark - Bytes already here (ADR 0018 § 9.5)

static NSString *ReceiveByChunks(SZFriendsTransfers *transfers, NSString *transferID, NSString *conversation,
                                 NSString *name, NSData *data) {
    NSError *error = nil;
    [transfers recordIncomingOfferWithID:transferID conversationID:conversation fileName:name uniformType:nil
                                    size:data.length contentDigest:SZFTBlake2b(data) sentAt:[NSDate date] error:NULL];
    [transfers acceptTransfer:transferID automatically:NO error:NULL];
    for (NSUInteger at = (NSUInteger)[transfers transferWithID:transferID].verifiedBytes; at < data.length;
         at += 61440) {
        [transfers appendChunk:[data subdataWithRange:NSMakeRange(at, MIN(61440, data.length - at))] atOffset:at
                    toTransfer:transferID fromConversation:conversation error:NULL];
    }
    SZFTExpect([transfers finishTransfer:transferID finalDigest:SZFTBlake2b(data) fromConversation:conversation
                                   error:&error], @"received %@: %@", transferID, error);
    return [transfers transferWithID:transferID].receivedPath;
}

static void TestAFileHeldIsFilledLocallyAndNoOtherFriends(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"held"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFTAddPerson(store, @"kenji", 2, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = SZFTBlockTransfers(store);
    NSData *data = SZFTRandomData(300000);
    ReceiveByChunks(transfers, @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", @"mei", @"plan.pdf", data);
    // Offered again by Mei: every byte is here at acceptance, so only DONE has to come.
    NSString *again = @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    [transfers recordIncomingOfferWithID:again conversationID:@"mei" fileName:@"plan.pdf" uniformType:nil
                                    size:data.length contentDigest:SZFTBlake2b(data) sentAt:[NSDate date] error:NULL];
    [transfers acceptTransfer:again automatically:NO error:NULL];
    SZFTExpect([transfers transferWithID:again].verifiedBytes == data.length, @"filled locally at acceptance");
    NSError *error = nil;
    SZFTExpect([transfers finishTransfer:again finalDigest:SZFTBlake2b(data) fromConversation:@"mei" error:&error] &&
                   [[NSData dataWithContentsOfFile:[transfers transferWithID:again].receivedPath] isEqualToData:data],
               @"DONE alone publishes it: %@", error);
    // The same bytes from someone else come over the route: nothing of Mei's is used for them.
    NSString *other = @"cccccccccccccccccccccccccccccccc";
    [transfers recordIncomingOfferWithID:other conversationID:@"kenji" fileName:@"plan.pdf" uniformType:nil
                                    size:data.length contentDigest:SZFTBlake2b(data) sentAt:[NSDate date] error:NULL];
    [transfers acceptTransfer:other automatically:NO error:NULL];
    SZFTExpect([transfers transferWithID:other].verifiedBytes == 0, @"never another friend's file");
}

static void TestANewVersionTakesTheUnchangedBlocks(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"version"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = SZFTBlockTransfers(store);
    NSData *old = SZFTRandomData(5 * MiB);
    ReceiveByChunks(transfers, @"dddddddddddddddddddddddddddddddd", @"mei", @"Gearbox.step", old);
    // The new version changes block 2 and grows by a block.
    NSMutableData *changed = [old mutableCopy];
    ((uint8_t *)changed.mutableBytes)[2 * MiB + 100] ^= 0xff;
    [changed appendData:SZFTRandomData(MiB)];
    SZFriendsBlockGeometry geometry;
    SZFriendsGeometryForSize(changed.length, &geometry);
    NSData *leaves = Leaves(changed, geometry);
    [transfers recordIncomingOfferWithID:@"b1" conversationID:@"mei" fileName:@"Gearbox.step" uniformType:nil
                                    size:changed.length contentDigest:SZFTBlake2b(changed) sentAt:[NSDate date]
                                   error:NULL];
    [transfers recordOfferedTree:@"b1" conversation:@"mei" geometry:geometry
                            root:SZFriendsTreeRootOfLeaves(geometry, leaves)];
    [transfers acceptTransfer:@"b1" automatically:NO error:NULL];
    SZFTExpect([transfers beginBlocks:@"b1" conversation:@"mei" error:NULL] &&
                   [transfers acceptBlockHashes:leaves index:0 forTransfer:@"b1" fromConversation:@"mei" error:NULL],
               @"by blocks, leaves in");
    SZFTExpect(MissingIs(transfers, @[ @2, @1, @5, @1 ]), @"only the changed block and the new one");
    NSData *complete = nil, *durable = nil;
    [transfers takeBlockHave:@"b1" complete:&complete durable:&durable];
    const uint32_t *have = complete.bytes;
    SZFTExpect(complete.length == 16 && have[0] == 0 && have[1] == 2 && have[2] == 3 && have[3] == 2,
               @"HAVE: blocks 0-1 and 3-4 taken from the version before");
    SendBlock(transfers, changed, geometry, 2, NO);
    SendBlock(transfers, changed, geometry, 5, NO);
    NSError *error = nil;
    SZFTExpect([transfers blocksAllDurable:@"b1"] &&
                   [transfers finishBlockTransfer:@"b1" fromConversation:@"mei" error:&error] &&
                   [[NSData dataWithContentsOfFile:[transfers transferWithID:@"b1"].receivedPath]
                       isEqualToData:changed],
               @"the new version, whole: %@", error);
}

// The check before saving in its three steps ("Finishing…"): not before every block is here, one at a time, and
// nothing saved before it completes.
static void TestTheCheckInThreeSteps(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"check"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = SZFTBlockTransfers(store);
    NSData *contents = SZFTRandomData(2 * MiB + 5);
    SZFriendsBlockGeometry geometry;
    SZFriendsGeometryForSize(contents.length, &geometry);
    NSData *leaves = Leaves(contents, geometry);
    [transfers recordIncomingOfferWithID:@"b1" conversationID:@"mei" fileName:@"Board.kicad_pcb" uniformType:nil
                                    size:contents.length contentDigest:SZFTBlake2b(contents) sentAt:[NSDate date]
                                   error:NULL];
    [transfers recordOfferedTree:@"b1" conversation:@"mei" geometry:geometry
                            root:SZFriendsTreeRootOfLeaves(geometry, leaves)];
    [transfers acceptTransfer:@"b1" automatically:NO error:NULL];
    [transfers beginBlocks:@"b1" conversation:@"mei" error:NULL];
    [transfers acceptBlockHashes:leaves index:0 forTransfer:@"b1" fromConversation:@"mei" error:NULL];
    SZFTExpect([transfers beginBlockCheck:@"b1" fromConversation:@"mei" error:NULL] == nil, @"not before every block");
    for (uint32_t block = 0; block < geometry.blocks; block++) SendBlock(transfers, contents, geometry, block, NO);
    NSError *error = nil;
    SZFriendsBlockCheck *check = [transfers beginBlockCheck:@"b1" fromConversation:@"mei" error:&error];
    SZFTExpect(check != nil, @"begun: %@", error);
    SZFTExpect([transfers beginBlockCheck:@"b1" fromConversation:@"mei" error:&error] == nil &&
                   error.code == SZFriendsStoreErrorStale,
               @"one check at a time");
    [check run];
    SZFTExpect([transfers transferWithID:@"b1"].state == SZFriendsTransferStateReceiving, @"not saved before it ends");
    SZFTExpect([transfers completeBlockCheck:check error:&error] &&
                   [[NSData dataWithContentsOfFile:[transfers transferWithID:@"b1"].receivedPath]
                       isEqualToData:contents],
               @"saved once it completes: %@", error);
}

// ADR 0018 § 4, as 58cd7d62: Get again and own-device copies (and their received-blocks records) survive the
// recovery sweep at start, so they resume; a copy untouched for 30 days goes, and so does a stray file.
static void TestCopiesSurviveARestart(void) {
    NSString *directory = SZFTTemporaryDirectory(@"copies");
    SZFriendsStore *store = SZFTOpenStore(directory);
    SZFTBlockTransfers(store); // makes received/.partial
    NSString *partial = [[store.stateDirectory stringByAppendingPathComponent:@"received"]
        stringByAppendingPathComponent:@".partial"];
    NSString *again = [partial stringByAppendingPathComponent:@"again-0123456789abcdef0123456789abcdef"];
    NSString *againMap = [again stringByAppendingString:@".map"];
    NSString *sync = [partial stringByAppendingPathComponent:@"sync-fedcba9876543210fedcba9876543210"];
    NSString *old = [partial stringByAppendingPathComponent:@"again-00000000000000000000000000000000"];
    NSString *stray = [partial stringByAppendingPathComponent:@"leftover"];
    for (NSString *path in @[ again, againMap, sync, old, stray ]) [SZFTRandomData(100) writeToFile:path atomically:NO];
    struct timeval month[2] = {{time(NULL) - 31 * 24 * 3600, 0}, {time(NULL) - 31 * 24 * 3600, 0}};
    utimes(old.fileSystemRepresentation, month);
    [store close];
    SZFTBlockTransfers(SZFTOpenStore(directory)); // the sweep at start
    NSFileManager *files = NSFileManager.defaultManager;
    SZFTExpect([files fileExistsAtPath:again] && [files fileExistsAtPath:againMap] && [files fileExistsAtPath:sync],
               @"recent copies and their records stay");
    SZFTExpect(![files fileExistsAtPath:old] && ![files fileExistsAtPath:stray],
               @"a month-old copy and a stray file go");
}

// A copy by blocks (Get again, own devices) resumes from its map and checks the digest, as block_copy.rs's test.
static void TestACopyByBlocksResumesFromItsMap(void) {
    NSData *data = SZFTRandomData(3 * MiB + 9);
    SZFriendsBlockGeometry geometry;
    SZFriendsGeometryForSize(data.length, &geometry);
    NSData *leaves = Leaves(data, geometry), *root = SZFriendsTreeRootOfLeaves(geometry, leaves);
    NSString *partial = [SZFTTemporaryDirectory(@"block-copy") stringByAppendingPathComponent:@"again-x"];
    NSString *map = [partial stringByAppendingString:@".map"];
    SZFriendsBlockCopy *copy = [SZFriendsBlockCopy openWithSize:data.length digest:SZFTBlake2b(data) partial:partial];
    const uint32_t *missing = copy.missing.bytes;
    SZFTExpect(copy.missing.length == 8 && missing[0] == 0 && missing[1] == 4, @"every block, before a tree");
    uint32_t block = 0;
    SZFTExpect([copy acceptPart:[data subdataWithRange:NSMakeRange(0, 10)] offset:0 block:&block] ==
                   SZFriendsCopyPartRefused, @"nothing before the tree");
    BOOL done = NO;
    SZFTExpect([copy followRoot:root shift:geometry.shift] && [copy acceptHashes:leaves index:0 done:&done] && done,
               @"the tree and its leaves");
    SZFTExpect([copy acceptPart:[data subdataWithRange:NSMakeRange(MiB, MiB)] offset:MiB block:&block] ==
                   SZFriendsCopyPartWritten && block == 1, @"block 1 written");
    [copy pause];
    copy = nil;
    // A later session: block 1 is here, the rest is asked for.
    copy = [SZFriendsBlockCopy openWithSize:data.length digest:SZFTBlake2b(data) partial:partial];
    missing = copy.missing.bytes;
    SZFTExpect(copy.missing.length == 16 && missing[0] == 0 && missing[1] == 1 && missing[2] == 2 && missing[3] == 2,
               @"block 1 kept, the rest asked for");
    SZFTExpect([copy followRoot:root shift:geometry.shift], @"the same tree keeps what arrived");
    for (uint32_t b = 0; b < geometry.blocks; b++) {
        if (b == 1) continue;
        uint64_t offset = 0;
        NSUInteger length = 0;
        SZFriendsGeometrySpan(geometry, b, &offset, &length);
        [copy acceptPart:[data subdataWithRange:NSMakeRange(offset, length)] offset:offset block:&block];
    }
    SZFTExpect(copy.complete, @"complete");
    NSString *path = [copy finish];
    SZFTExpect(path != nil && [[NSData dataWithContentsOfFile:path] isEqualToData:data] &&
                   ![NSFileManager.defaultManager fileExistsAtPath:map],
               @"the file whole, its map gone");
}

#pragma mark - Pieces and slices (ADR 0018 § 3, as ac8317b0's tests)

BOOL SZFTPairsAre(NSData *pairs, NSArray<NSNumber *> *expected) {
    if (pairs.length / 4 != expected.count) return NO;
    const uint32_t *got = pairs.bytes;
    for (NSUInteger i = 0; i < expected.count; i++) {
        if (got[i] != expected[i].unsignedIntValue) return NO;
    }
    return YES;
}

static void TestPiecesThatArrivedAndPiecesStillMissing(void) {
    NSData *bytes = SZFTRandomData(3 * MiB);
    SZFriendsBlockGeometry geometry;
    SZFriendsGeometryForSize(bytes.length, &geometry);
    NSData *leaves = Leaves(bytes, geometry);
    SZFriendsBlockAssembly *assembly =
        [[SZFriendsBlockAssembly alloc] initWithGeometry:geometry root:SZFriendsTreeRootOfLeaves(geometry, leaves)];
    BOOL done = NO;
    [assembly acceptHashes:leaves index:0 done:&done];
    NSUInteger piece = 16384, at = MiB;
    uint32_t block = 0;
    NSData *data = nil;
    // Block 1: pieces 64 and 65 whole, 66 half; a part across pieces 69 and 70 completes neither.
    SZFTExpect([assembly acceptPart:[bytes subdataWithRange:NSMakeRange(at, 2 * piece + 100)] offset:at block:&block
                               data:&data] == SZFriendsPartPending, @"pending");
    NSUInteger odd = at + 5 * piece + 10;
    [assembly acceptPart:[bytes subdataWithRange:NSMakeRange(odd, piece)] offset:odd block:&block data:&data];
    SZFTExpect(SZFTPairsAre([assembly takeArrivedPieces], @[ @64, @2 ]), @"pieces 64 and 65 arrived");
    SZFTExpect([assembly takeArrivedPieces].length == 0, @"reported once");
    // Sent again (its HAVE went with a cut lane): acknowledged again, or the sender would wait for it forever.
    [assembly acceptPart:[bytes subdataWithRange:NSMakeRange(at, piece)] offset:at block:&block data:&data];
    SZFTExpect(SZFTPairsAre([assembly takeArrivedPieces], @[ @64, @1 ]), @"a piece sent again is acknowledged again");
    NSUInteger rest = at + 2 * piece + 100;
    [assembly acceptPart:[bytes subdataWithRange:NSMakeRange(rest, at + 3 * piece - rest)] offset:rest block:&block
                    data:&data];
    SZFTExpect(SZFTPairsAre([assembly takeArrivedPieces], @[ @66, @1 ]), @"the rest of piece 66");
    SZFTExpect(SZFTPairsAre([assembly missingBlocksBesidesPartial], @[ @0, @1, @2, @1 ]), @"blocks 0 and 2 whole");
    SZFTExpect(SZFTPairsAre([assembly missingPieces], @[ @67, @61 ]), @"in block 1, everything but pieces 64 to 66");
    for (NSUInteger offset = at + 3 * piece; offset < 2 * MiB;) {
        NSUInteger end = MIN(offset + 60000, 2 * MiB);
        [assembly acceptPart:[bytes subdataWithRange:NSMakeRange(offset, end - offset)] offset:offset block:&block
                        data:&data];
        offset = end;
    }
    SZFTExpect([assembly.complete contains:1] && [assembly takeArrivedPieces].length == 0 &&
                   [assembly missingPieces].length == 0,
               @"block 1 complete: no pieces left to report or want");
}

void SZFTRunTransferBlockTests(void) {
    TestReceiveByBlocksThroughARestart();
    TestTheSenderSideFromStaging();
    SZFTRunBlockExchangeTests();
    TestAFileHeldIsFilledLocallyAndNoOtherFriends();
    TestANewVersionTakesTheUnchangedBlocks();
    TestTheCheckInThreeSteps();
    TestCopiesSurviveARestart();
    TestACopyByBlocksResumesFromItsMap();
    TestPiecesThatArrivedAndPiecesStillMissing();
    SZFTRunBlockPiecesTests();
}
