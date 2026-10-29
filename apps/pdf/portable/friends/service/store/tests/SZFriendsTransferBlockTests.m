// Files by blocks on disk (ADR 0018 § 4 and 5): the offered tree, leaves before any part, blocks checked and written
// at their offsets, a corrupt block wanted again alone, durable batches with the prefix kept for older helpers, a
// restart that keeps blocks past the prefix and re-checks them, the publish check, and the sender's tree from staging.

#import <fcntl.h>
#import <unistd.h>

#import "SZFriendsStoreTestSupport.h"

#import "service/transfer/SZFriendsBlockExchange.h"
#import "service/transfer/SZFriendsTransferBlocks.h"

static const NSUInteger MiB = 1 << 20;

static SZFriendsTransfers *Transfers(SZFriendsStore *store) {
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
    SZFriendsTransfers *transfers = Transfers(store);
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
    SZFTExpect(SendBlock(transfers, contents, geometry, 0, NO) == SZFriendsBlockPartRefused, @"no part before leaves");
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
    SZFriendsTransfers *again = Transfers(reopened);
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
    SZFriendsTransfers *transfers = Transfers(store);
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


#pragma mark - Two exchanges, one session between them

// Frames from one side wait here until the other side takes them.
@interface SZFTPipe : NSObject
@property(nonatomic, strong) NSMutableArray<SZFriendsFrame *> *toReceiver;
@property(nonatomic, strong) NSMutableArray<SZFriendsFrame *> *toSender;
@end
@implementation SZFTPipe
@end

static SZFriendsBlockExchange *Exchange(SZFriendsTransfers *transfers, NSString *conversation,
                                        NSMutableArray<SZFriendsFrame *> *outbox) {
    return [[SZFriendsBlockExchange alloc] initWithTransfers:transfers conversationID:conversation
                                                       route:SZFriendsRouteMethodLAN
                                                        send:^BOOL(SZFriendsFrame *frame) {
                                                            [outbox addObject:frame];
                                                            return YES;
                                                        }
                                                      queued:nil];
}

// Moves frames both ways until neither side has anything to say; flips the first byte of the `corrupt`th PART.
static void Run(SZFriendsBlockExchange *sender, SZFriendsBlockExchange *receiver, SZFTPipe *pipe,
                NSUInteger stopAfterParts, NSInteger corrupt, BOOL *acknowledged) {
    NSUInteger parts = 0;
    while (pipe.toReceiver.count || pipe.toSender.count) {
        while (pipe.toReceiver.count) {
            SZFriendsFrame *frame = pipe.toReceiver.firstObject;
            [pipe.toReceiver removeObjectAtIndex:0];
            if (frame.type == SZFriendsFrameTypePart) {
                if (stopAfterParts && parts == stopAfterParts) {
                    [pipe.toReceiver removeAllObjects]; // the route went away with these on it
                    [pipe.toSender removeAllObjects];
                    return;
                }
                if ((NSInteger)parts == corrupt) {
                    NSMutableDictionary *fields = [frame.fields mutableCopy];
                    NSMutableData *data = [fields[@(SZFriendsFieldData)] mutableCopy];
                    ((uint8_t *)data.mutableBytes)[0] ^= 1;
                    fields[@(SZFriendsFieldData)] = data;
                    frame = [SZFriendsFrame frameWithType:frame.type fields:fields];
                }
                parts++;
            }
            SZFTExpect([receiver handleFrame:frame], @"the receiver takes frame %u", frame.type);
        }
        [receiver flushDue];
        while (pipe.toSender.count) {
            SZFriendsFrame *frame = pipe.toSender.firstObject;
            [pipe.toSender removeObjectAtIndex:0];
            if (frame.type == SZFriendsFrameTypeAck) {
                *acknowledged = YES;
                continue;
            }
            SZFTExpect([sender handleFrame:frame], @"the sender takes frame %u", frame.type);
        }
        [sender pump];
    }
}

static void TestTwoExchangesWithACorruptPartAndACut(void) {
    SZFriendsStore *senderStore = SZFTOpenStore(SZFTTemporaryDirectory(@"exchange-send"));
    SZFriendsStore *receiverStore = SZFTOpenStore(SZFTTemporaryDirectory(@"exchange-receive"));
    SZFTAddPerson(senderStore, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFTAddPerson(receiverStore, @"ken", 3, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *sending = Transfers(senderStore), *receiving = Transfers(receiverStore);
    NSData *contents = SZFTRandomData(6 * MiB + 99);
    NSString *source = [SZFTTemporaryDirectory(@"exchange-source") stringByAppendingPathComponent:@"Model.step"];
    [contents writeToFile:source atomically:YES];
    SZFriendsTransferRecord *record = [sending stageOutgoingFileAtPath:source revision:nil conversationID:@"mei"
                                                                 error:NULL];
    NSString *transferID = record.transferID;
    NSMutableDictionary *fields = [@{@(SZFriendsFieldSize) : [SZFriendsFrame fieldWithUInt64:record.size
                                                                                          tag:SZFriendsFieldSize]}
        mutableCopy];
    [SZFriendsBlockExchange addTreeOfTransfer:record toFields:fields transfers:sending];
    SZFTExpect(fields[@(SZFriendsFieldTreeRoot)] != nil, @"our offer announces the tree");
    [sending markOfferDelivered:transferID fromConversation:@"mei" error:NULL];

    SZFTPipe *pipe = [[SZFTPipe alloc] init];
    pipe.toReceiver = [NSMutableArray array];
    pipe.toSender = [NSMutableArray array];
    SZFriendsBlockExchange *sender = Exchange(sending, @"mei", pipe.toReceiver);
    SZFriendsBlockExchange *receiver = Exchange(receiving, @"ken", pipe.toSender);
    [receiving recordIncomingOfferWithID:transferID conversationID:@"ken" fileName:@"Model.step" uniformType:nil
                                    size:record.size contentDigest:record.contentDigest sentAt:[NSDate date]
                                   error:NULL];
    [receiver noteOffer:[SZFriendsFrame frameWithType:SZFriendsFrameTypeOffer fields:fields] transferID:transferID];
    [receiving acceptTransfer:transferID automatically:NO error:NULL];
    NSMutableDictionary *reply = [NSMutableDictionary dictionary];
    [SZFriendsBlockExchange addBlocksToReply:reply forTransfer:transferID transfers:receiving];
    SZFTExpect(reply[@(SZFriendsFieldBlocks)] != nil, @"taken by blocks");
    SZFTExpect([receiver resumeIncoming:[receiving transferWithID:transferID]], @"WANT for every block");
    SZFTExpect([sender offerTakenByBlocks:transferID], @"the sender starts: leaves, then parts");
    SZFTExpect(sender.awaitingPeer && receiver.carriesTransfers, @"liveness watches the sender's side");
    BOOL acknowledged = NO;
    // Half-way the route goes away; the part after the 20th arrives corrupted first.
    Run(sender, receiver, pipe, 60, 20, &acknowledged);
    [sender sessionEnded];
    [receiver sessionEnded];
    SZFTExpect(!acknowledged && [receiving transferWithID:transferID].state == SZFriendsTransferStateReceiving,
               @"not done yet");
    uint64_t kept = [receiving transferWithID:transferID].verifiedBytes;
    SZFTExpect(kept >= MiB, @"what arrived is durable: %llu", kept);

    // A new session: the receiver asks for exactly what is missing, the sender serves it without hashing again.
    sender = Exchange(sending, @"mei", pipe.toReceiver);
    receiver = Exchange(receiving, @"ken", pipe.toSender);
    SZFTExpect([receiver resumeIncoming:[receiving transferWithID:transferID]], @"resumes by blocks");
    NSUInteger wanted = 0;
    for (SZFriendsFrame *frame in pipe.toSender) {
        NSData *ranges = SZFriendsFrameRanges(frame, SZFriendsFieldRanges);
        for (NSUInteger i = 0; i < ranges.length / 8; i++) wanted += ((const uint32_t *)ranges.bytes)[2 * i + 1];
    }
    SZFTExpect(wanted > 0 && wanted < 7, @"only the missing blocks are wanted: %lu", (unsigned long)wanted);
    Run(sender, receiver, pipe, 0, -1, &acknowledged);
    SZFriendsTransferRecord *received = [receiving transferWithID:transferID];
    SZFTExpect(acknowledged && received.state == SZFriendsTransferStateReceived &&
                   [[NSData dataWithContentsOfFile:received.receivedPath] isEqualToData:contents],
               @"received whole after a corrupt part and a cut, and acknowledged");
    // Late frames after the end: dropped, not refused (ADR 0018 § 3).
    NSData *wire = SZFTBytes(0, 16);
    NSMutableData *rangeField = [NSMutableData dataWithLength:8];
    ((uint8_t *)rangeField.mutableBytes)[7] = 1;
    SZFriendsFrame *strangeHave = [SZFriendsFrame frameWithType:SZFriendsFrameTypeHave
                                                         fields:@{@(SZFriendsFieldID) : wire,
                                                                  @(SZFriendsFieldRanges) : rangeField}];
    SZFTExpect(![sender handleFrame:strangeHave], @"a HAVE for nothing of ours is unsolicited");
    NSMutableData *ourWire = [NSMutableData data];
    for (NSUInteger i = 0; i < 32; i += 2) {
        uint8_t byte = (uint8_t)strtoul([[transferID substringWithRange:NSMakeRange(i, 2)] UTF8String], NULL, 16);
        [ourWire appendBytes:&byte length:1];
    }
    SZFriendsFrame *lateHave = [SZFriendsFrame frameWithType:SZFriendsFrameTypeHave
                                                      fields:@{@(SZFriendsFieldID) : ourWire,
                                                               @(SZFriendsFieldRanges) : rangeField}];
    [sender endTransfer:transferID];
    SZFTExpect([sender handleFrame:lateHave], @"a late HAVE for our transfer that ended is dropped");
    SZFTExpect([receiver handleFrame:SZFriendsPartFrame(ourWire, 0, [NSData dataWithBytes:"x" length:1])],
               @"a late PART for a file already received is dropped");
}

// One session between the two exchanges: what each side has sent the other on it, by lane id on each side.
@interface SZFTRoute : NSObject
@property(nonatomic) SZFriendsLaneID senderLane, receiverLane;
@property(nonatomic, strong) NSMutableArray<SZFriendsFrame *> *toReceiver, *toSender;
@property(nonatomic) BOOL gone;
@end
@implementation SZFTRoute
@end

static SZFTRoute *Route(SZFriendsLaneID senderLane, SZFriendsLaneID receiverLane) {
    SZFTRoute *route = [[SZFTRoute alloc] init];
    route.senderLane = senderLane;
    route.receiverLane = receiverLane;
    route.toReceiver = [NSMutableArray array];
    route.toSender = [NSMutableArray array];
    return route;
}

static BOOL (^Into(SZFTRoute *route, BOOL toReceiver))(SZFriendsFrame *) {
    return ^BOOL(SZFriendsFrame *frame) {
        if (route.gone) return NO;
        [toReceiver ? route.toReceiver : route.toSender addObject:frame];
        return YES;
    };
}

// Moves frames on every route still there until nothing moves; stops once `parts` PARTs have arrived (0: never).
static NSUInteger Move(SZFriendsBlockExchange *sender, SZFriendsBlockExchange *receiver, NSArray<SZFTRoute *> *routes,
                       NSUInteger parts, BOOL *acknowledged) {
    NSUInteger arrived = 0;
    for (BOOL moved = YES; moved;) {
        moved = NO;
        for (SZFTRoute *route in routes) {
            if (route.gone) continue;
            while (route.toReceiver.count) {
                SZFriendsFrame *frame = route.toReceiver.firstObject;
                [route.toReceiver removeObjectAtIndex:0];
                moved = YES;
                SZFTExpect([receiver handleFrame:frame lane:route.receiverLane], @"the receiver takes %u", frame.type);
                if (frame.type == SZFriendsFrameTypePart && ++arrived == parts) return arrived;
            }
            while (route.toSender.count) {
                SZFriendsFrame *frame = route.toSender.firstObject;
                [route.toSender removeObjectAtIndex:0];
                moved = YES;
                if (frame.type == SZFriendsFrameTypeAck) {
                    *acknowledged = YES;
                    continue;
                }
                SZFTExpect([sender handleFrame:frame lane:route.senderLane], @"the sender takes %u", frame.type);
            }
        }
        [receiver flushDue];
        [sender pump];
    }
    return arrived;
}

// ADR 0018 § 6: the first session's route goes away mid-file while a lane lives; the group goes on, control frames
// move to the lane, and the file finishes on it without a new session.
static void TestTheGroupOutlivesItsFirstSession(void) {
    SZFriendsStore *senderStore = SZFTOpenStore(SZFTTemporaryDirectory(@"group-send"));
    SZFriendsStore *receiverStore = SZFTOpenStore(SZFTTemporaryDirectory(@"group-receive"));
    SZFTAddPerson(senderStore, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFTAddPerson(receiverStore, @"ken", 3, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *sending = Transfers(senderStore), *receiving = Transfers(receiverStore);
    NSData *contents = SZFTRandomData(5 * MiB + 7);
    NSString *source = [SZFTTemporaryDirectory(@"group-source") stringByAppendingPathComponent:@"Board.kicad_pcb"];
    [contents writeToFile:source atomically:YES];
    SZFriendsTransferRecord *record = [sending stageOutgoingFileAtPath:source revision:nil conversationID:@"mei"
                                                                 error:NULL];
    NSString *transferID = record.transferID;
    NSMutableDictionary *fields = [@{@(SZFriendsFieldSize) : [SZFriendsFrame fieldWithUInt64:record.size
                                                                                          tag:SZFriendsFieldSize]}
        mutableCopy];
    [SZFriendsBlockExchange addTreeOfTransfer:record toFields:fields transfers:sending];
    [sending markOfferDelivered:transferID fromConversation:@"mei" error:NULL];

    // The head (lane 0 on both sides) and a lane, id 7 at the sender and 9 at the receiver.
    SZFTRoute *head = Route(SZFriendsHeadLane, SZFriendsHeadLane), *lane = Route(7, 9);
    SZFriendsBlockExchange *sender =
        [[SZFriendsBlockExchange alloc] initWithTransfers:sending conversationID:@"mei" route:SZFriendsRouteMethodLAN
                                                     send:Into(head, YES) queued:nil];
    SZFriendsBlockExchange *receiver =
        [[SZFriendsBlockExchange alloc] initWithTransfers:receiving conversationID:@"ken" route:SZFriendsRouteMethodLAN
                                                     send:Into(head, NO) queued:nil];
    NSData *h = SZFTBytes(5, 64);
    [sender formGroupWithHandshakeHash:h initiator:YES];
    [receiver formGroupWithHandshakeHash:h initiator:NO];
    NSData *token = nil;
    SZFTExpect([sender reserveLane:7 route:SZFriendsRouteMethodPeerToPeerWiFi token:&token] == 1 && token.length == 16,
               @"the dialer's first lane takes index 1");
    SZFTExpect([receiver admitLane:9 token:token route:SZFriendsRouteMethodPeerToPeerWiFi] == SZFriendsLaneAdmitted,
               @"its token admits it");
    [sender laneUp:7 send:Into(lane, YES) queued:nil];
    [receiver laneUp:9 send:Into(lane, NO) queued:nil];

    [receiving recordIncomingOfferWithID:transferID conversationID:@"ken" fileName:@"Board.kicad_pcb" uniformType:nil
                                    size:record.size contentDigest:record.contentDigest sentAt:[NSDate date]
                                   error:NULL];
    [receiver noteOffer:[SZFriendsFrame frameWithType:SZFriendsFrameTypeOffer fields:fields] transferID:transferID];
    [receiving acceptTransfer:transferID automatically:NO error:NULL];
    SZFTExpect([receiver resumeIncoming:[receiving transferWithID:transferID]], @"WANT for every block");
    SZFTExpect([sender offerTakenByBlocks:transferID], @"the sender starts");
    BOOL acknowledged = NO;
    NSArray *routes = @[ head, lane ];
    SZFTExpect(Move(sender, receiver, routes, 40, &acknowledged) == 40 && !acknowledged, @"under way");

    // The head's route goes, with what was on it.
    head.gone = YES;
    SZFTExpect(![sender laneDown:SZFriendsHeadLane] && sender.controlLane == 7, @"the sender's group goes on, on 7");
    SZFTExpect(![receiver laneDown:SZFriendsHeadLane] && receiver.controlLane == 9,
               @"the receiver's group goes on, on 9");
    // The blocks that were on the head's route go to the lane: the scheduler hears the head go down.
    Move(sender, receiver, routes, 0, &acknowledged);
    SZFriendsTransferRecord *received = [receiving transferWithID:transferID];
    SZFTExpect(acknowledged && received.state == SZFriendsTransferStateReceived &&
                   [[NSData dataWithContentsOfFile:received.receivedPath] isEqualToData:contents],
               @"finished on the lane, intact and acknowledged");
    SZFTExpect([sender laneDown:7], @"the last lane's end ends the group");
}

void SZFTRunTransferBlockTests(void) {
    TestReceiveByBlocksThroughARestart();
    TestTheSenderSideFromStaging();
    TestTwoExchangesWithACorruptPartAndACut();
    TestTheGroupOutlivesItsFirstSession();
}
