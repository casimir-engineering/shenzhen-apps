// Two block exchanges end to end over emulated lanes (ADR 0018 § 6 and 7): a corrupt part and a cut, with and without
// pieces and slices, and a group that outlives its first session; and how slices and pieces map onto blocks and are
// acknowledged (§ 3). Part of SZFTRunTransferBlockTests, in its order.

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

static NSArray<NSArray<NSNumber *> *> *Offsets(NSArray<SZFriendsFrame *> *frames) {
    NSMutableArray *out = [NSMutableArray array];
    for (SZFriendsFrame *frame in frames) {
        uint64_t offset = 0;
        [frame getUInt64:&offset forTag:SZFriendsFieldOffset];
        [out addObject:@[ @(offset), @([frame dataForTag:SZFriendsFieldData].length) ]];
    }
    return out;
}

static void TestSlicesAndPiecesMapOntoBlocks(void) {
    SZFriendsBlockGeometry blocks;
    SZFriendsGeometryForSize(3 * MiB + 7, &blocks);
    SZFriendsSliceSend *send = [[SZFriendsSliceSend alloc] initWithGeometry:blocks pieces:YES];
    uint32_t a[] = {1, 2}, b[] = {3, 1}, c[] = {15, 2, 64, 1};
    SZFTExpect(send.units.blocks == 13, @"13 slices");
    SZFTExpect(SZFTPairsAre([send unitsOfBlocks:[NSData dataWithBytes:a length:8]], @[ @4, @8 ]), @"blocks 1-2");
    SZFTExpect(SZFTPairsAre([send unitsOfBlocks:[NSData dataWithBytes:b length:8]], @[ @12, @1 ]), @"the short last block");
    SZFTExpect(SZFTPairsAre([send unitsOfPieces:[NSData dataWithBytes:c length:16]], @[ @0, @2, @4, @1 ]), @"pieces");
    SZFTExpect([send blockOfUnit:7] == 1, @"slice 7 is in block 1");
    SZFriendsSliceSend *whole = [[SZFriendsSliceSend alloc] initWithGeometry:blocks pieces:NO];
    SZFTExpect(whole.units.blocks == 4 && SZFTPairsAre([whole unitsOfBlocks:[NSData dataWithBytes:a length:8]], @[ @1, @2 ]),
               @"a peer without pieces: whole blocks");
}

static void TestAcknowledgedPiecesAreNotSentAgain(void) {
    SZFriendsBlockGeometry blocks;
    SZFriendsGeometryForSize(2 * MiB, &blocks);
    SZFriendsSliceSend *send = [[SZFriendsSliceSend alloc] initWithGeometry:blocks pieces:YES];
    NSData *id_ = SZFTBytes(1, 16);
    [send keepBlock:0 data:SZFTBytes(9, MiB)];
    SZFTExpect([send partsOfUnit:1 transferID:id_ partBytes:61440].count == 5, @"256 KiB in 60 KiB parts");
    uint32_t some[] = {16, 4, 31, 1}, rest[] = {20, 11}, again[] = {30, 2}, block0[] = {0, 1};
    SZFTExpect([send havePieces:[NSData dataWithBytes:some length:16]].length == 0, @"slice 1 not whole yet");
    NSArray *left = Offsets([send partsOfUnit:1 transferID:id_ partBytes:16384]);
    SZFTExpect(left.count == 11 && [left[0] isEqual:(@[ @(20 * 16384), @16384 ])], @"the rest of slice 1: %@", left);
    SZFTExpect(SZFTPairsAre([send havePieces:[NSData dataWithBytes:rest length:8]], @[ @1, @1 ]), @"slice 1 acknowledged");
    SZFTExpect([send partsOfUnit:1 transferID:id_ partBytes:16384].count == 0, @"nothing left of it");
    [send wantBlocks:[NSData data] pieces:[NSData dataWithBytes:again length:8]];
    SZFTExpect([Offsets([send partsOfUnit:1 transferID:id_ partBytes:61440]) isEqual:(@[ @[ @(30 * 16384), @32768 ] ])],
               @"wanted again: pieces 30 and 31 go again");
    [send wantBlocks:[NSData dataWithBytes:block0 length:8] pieces:[NSData data]];
    NSArray *all = Offsets([send partsOfUnit:1 transferID:id_ partBytes:MiB]);
    NSUInteger total = 0;
    for (NSArray *part in all) total += [part[1] unsignedIntegerValue];
    SZFTExpect([all[0][0] unsignedLongLongValue] == (1u << 18) && total == (1u << 18), @"parts at most 60 KiB");
}

#pragma mark - Two exchanges, one session between them

// Frames from one side wait here until the other side takes them.
@interface SZFTPipe : NSObject
@property(nonatomic, strong) NSMutableArray<SZFriendsFrame *> *toReceiver;
@property(nonatomic, strong) NSMutableArray<SZFriendsFrame *> *toSender;
@end
@implementation SZFTPipe
@end

// Both ends set capability bit 3 (pieces in WANT and HAVE, slices) while this is YES.
static BOOL gPieces = NO;

static SZFriendsBlockExchange *Exchange(SZFriendsTransfers *transfers, NSString *conversation,
                                        NSMutableArray<SZFriendsFrame *> *outbox) {
    SZFriendsBlockExchange *exchange =
        [[SZFriendsBlockExchange alloc] initWithTransfers:transfers conversationID:conversation
                                                    route:SZFriendsRouteMethodLAN
                                                     send:^BOOL(SZFriendsFrame *frame) {
                                                         [outbox addObject:frame];
                                                         return YES;
                                                     }
                                                   queued:nil];
    exchange.pieces = gPieces;
    return exchange;
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
    SZFriendsTransfers *sending = SZFTBlockTransfers(senderStore), *receiving = SZFTBlockTransfers(receiverStore);
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

// A PART that overtook HASHES (a lane faster than the first session, a sender that took the WANT for the leaves'
// arrival): dropped rather than ending the session, and its block wanted again once the leaves check.
static void TestAPartBeforeTheLeavesIsWantedAgain(void) {
    SZFriendsStore *senderStore = SZFTOpenStore(SZFTTemporaryDirectory(@"early-send"));
    SZFriendsStore *receiverStore = SZFTOpenStore(SZFTTemporaryDirectory(@"early-receive"));
    SZFTAddPerson(senderStore, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFTAddPerson(receiverStore, @"ken", 3, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *sending = Transfers(senderStore), *receiving = Transfers(receiverStore);
    NSData *contents = SZFTRandomData(3 * MiB + 1);
    NSString *source = [SZFTTemporaryDirectory(@"early-source") stringByAppendingPathComponent:@"Early.step"];
    [contents writeToFile:source atomically:YES];
    SZFriendsTransferRecord *record = [sending stageOutgoingFileAtPath:source revision:nil conversationID:@"mei"
                                                                 error:NULL];
    NSString *transferID = record.transferID;
    NSMutableDictionary *fields = [@{@(SZFriendsFieldSize) : [SZFriendsFrame fieldWithUInt64:record.size
                                                                                          tag:SZFriendsFieldSize]}
        mutableCopy];
    [SZFriendsBlockExchange addTreeOfTransfer:record toFields:fields transfers:sending];
    [sending markOfferDelivered:transferID fromConversation:@"mei" error:NULL];
    SZFTPipe *pipe = [[SZFTPipe alloc] init];
    pipe.toReceiver = [NSMutableArray array];
    pipe.toSender = [NSMutableArray array];
    SZFriendsBlockExchange *sender = Exchange(sending, @"mei", pipe.toReceiver);
    SZFriendsBlockExchange *receiver = Exchange(receiving, @"ken", pipe.toSender);
    [receiving recordIncomingOfferWithID:transferID conversationID:@"ken" fileName:@"Early.step" uniformType:nil
                                    size:record.size contentDigest:record.contentDigest sentAt:[NSDate date]
                                   error:NULL];
    [receiver noteOffer:[SZFriendsFrame frameWithType:SZFriendsFrameTypeOffer fields:fields] transferID:transferID];
    [receiving acceptTransfer:transferID automatically:NO error:NULL];
    [receiver resumeIncoming:[receiving transferWithID:transferID]];
    [sender offerTakenByBlocks:transferID];
    // The first PART goes ahead of the HASHES.
    NSUInteger firstPart = NSNotFound;
    for (NSUInteger i = 0; i < pipe.toReceiver.count; i++) {
        if (pipe.toReceiver[i].type == SZFriendsFrameTypePart) {
            firstPart = i;
            break;
        }
    }
    SZFTExpect(firstPart != NSNotFound, @"parts queued");
    SZFriendsFrame *early = pipe.toReceiver[firstPart];
    [pipe.toReceiver removeObjectAtIndex:firstPart];
    [pipe.toReceiver insertObject:early atIndex:0];
    BOOL acknowledged = NO;
    Run(sender, receiver, pipe, 0, -1, &acknowledged);
    SZFriendsTransferRecord *received = [receiving transferWithID:transferID];
    SZFTExpect(acknowledged && received.state == SZFriendsTransferStateReceived &&
                   [[NSData dataWithContentsOfFile:received.receivedPath] isEqualToData:contents],
               @"the session goes on, and the file arrives whole");
}


// ADR 0018 § 6: the first session's route goes away mid-file while a lane lives; the group goes on, control frames
// move to the lane, and the file finishes on it without a new session.
static void TestTheGroupOutlivesItsFirstSession(void) {
    SZFriendsStore *senderStore = SZFTOpenStore(SZFTTemporaryDirectory(@"group-send"));
    SZFriendsStore *receiverStore = SZFTOpenStore(SZFTTemporaryDirectory(@"group-receive"));
    SZFTAddPerson(senderStore, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFTAddPerson(receiverStore, @"ken", 3, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *sending = SZFTBlockTransfers(senderStore), *receiving = SZFTBlockTransfers(receiverStore);
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

void SZFTRunBlockExchangeTests(void) {
    TestTwoExchangesWithACorruptPartAndACut();
    gPieces = YES; // the same with pieces and slices: the cut costs only what was in flight
    TestTwoExchangesWithACorruptPartAndACut();
    gPieces = NO;
    TestTheGroupOutlivesItsFirstSession();
    TestAPartBeforeTheLeavesIsWantedAgain();
}

void SZFTRunBlockPiecesTests(void) {
    TestSlicesAndPiecesMapOntoBlocks();
    TestAcknowledgedPiecesAreNotSentAgain();
}
