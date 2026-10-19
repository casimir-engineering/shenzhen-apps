// Resume and route migration as one mechanism, over real channels: a transfer starts over Bluetooth (4 KiB chunks,
// 256 KiB window), the link drops mid-chunk, and a new LAN session resumes from the recipient's durable count with
// 60 KiB chunks. The recipient keeps only bytes it made durable, as the store does, and checks the whole-file
// digest after DONE.

#import <sodium.h>

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

static NSData *SZFDigest(NSData *data) {
    uint8_t digest[32];
    crypto_generichash(digest, sizeof digest, data.bytes, data.length, NULL, 0);
    return [NSData dataWithBytes:digest length:sizeof digest];
}

// What outlives a session: the sender's file and the recipient's durable bytes.
@interface SZFTransfer : NSObject
@property(nonatomic) NSData *file, *offerID;
@property(nonatomic) NSMutableData *durable; // written, fsynced and committed: the store's verifiedBytes
@property(nonatomic) BOOL verified;           // DONE arrived and the digest matched
@end

@implementation SZFTransfer
@end

typedef struct {
    uint64_t resumedFrom;      // the offset the sender's PROGRESS-driven sender started at
    NSUInteger largestChunk;   // largest CHUNK the recipient accepted
    BOOL protocolViolation;    // a flow check failed
} SZFSessionStats;

static SZFSessionStats SZFRunTransferSession(SZFTransfer *transfer, SZFriendsRouteMethod route, uint64_t severAfter) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFriendsHandshakeOptions *options = SZFOptions(SZFriendsHandshakeIK, bob);
    options.route = route;
    SZFChannelPair *pair = [SZFChannelPair pairWithOptions:options
                                         initiatorIdentity:alice
                                         responderIdentity:bob
                                             publicProfile:nil
                                                    policy:nil];
    pair.initiatorStream.severAfterBytes = severAfter;
    __block SZFSessionStats stats = {UINT64_MAX, 0, NO};
    __block SZFriendsChunkSender *sender = nil;
    __block SZFriendsChunkReceiver *receiver = nil;
    __block BOOL doneSent = NO;
    NSMutableData *staging = [NSMutableData data]; // received but not yet durable: lost if the session drops
    __weak SZFChannelPair *weakPair = pair;

    void (^pump)(void) = ^{
        uint64_t offset;
        NSUInteger length;
        while ([sender getNextChunkOffset:&offset length:&length]) {
            NSData *bytes = [transfer.file subdataWithRange:NSMakeRange(offset, length)];
            [weakPair.initiator sendFrame:[sender chunkFrameWithData:bytes]];
        }
        if (sender.allSent && !doneSent) {
            doneSent = YES;
            [weakPair.initiator sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeDone
                                                                 fields:@{@(SZFriendsFieldID) : transfer.offerID,
                                                                          @(SZFriendsFieldDigest) :
                                                                              SZFDigest(transfer.file)}]];
        }
    };
    pair.initiator.onFrame = ^(SZFriendsFrame *frame) {
        if (frame.type != SZFriendsFrameTypeProgress) {
            return;
        }
        if (sender == nil) {
            // The helper would first check the offer is its own, to this friend, still accepted, and that the
            // source still hashes to the offered digest.
            uint64_t offset = 0;
            [frame getUInt64:&offset forTag:SZFriendsFieldOffset];
            stats.resumedFrom = offset;
            sender = [[SZFriendsChunkSender alloc] initWithOfferID:transfer.offerID
                                                              size:transfer.file.length
                                                      resumeOffset:offset
                                                             route:weakPair.initiator.initiatorRoute];
        } else if (![sender handleProgressFrame:frame error:NULL]) {
            stats.protocolViolation = YES;
            [weakPair.initiator closeWithReason:SZFriendsCloseReasonProtocolError];
            return;
        }
        pump();
    };
    pair.responder.onEstablished = ^{
        weakPair.responderEstablished = YES;
        receiver = [[SZFriendsChunkReceiver alloc] initWithOfferID:transfer.offerID
                                                              size:transfer.file.length
                                                    verifiedOffset:transfer.durable.length
                                                             route:weakPair.responder.initiatorRoute];
        [weakPair.responder sendFrame:receiver.resumeProgressFrame];
    };
    pair.responder.onFrame = ^(SZFriendsFrame *frame) {
        if (frame.type == SZFriendsFrameTypeChunk) {
            NSData *data = [receiver acceptChunkFrame:frame error:NULL];
            if (data == nil) {
                stats.protocolViolation = YES;
                [weakPair.responder closeWithReason:SZFriendsCloseReasonProtocolError];
                return;
            }
            stats.largestChunk = MAX(stats.largestChunk, data.length);
            [staging appendData:data];
            // Durable in 16 KiB batches, like the store's fsync cadence; PROGRESS reports only durable bytes.
            if (staging.length >= 16 * 1024 || receiver.complete) {
                [transfer.durable appendData:staging];
                staging.length = 0;
                [weakPair.responder sendFrame:[receiver progressFrameForDurableOffset:transfer.durable.length]];
            }
        } else if (frame.type == SZFriendsFrameTypeDone) {
            NSData *digest = [receiver acceptDoneFrame:frame error:NULL];
            transfer.verified = digest && [digest isEqualToData:SZFDigest(transfer.durable)];
        }
    };
    [pair start];
    SZF_CHECK(SZFWaitUntil(pair.queue, 8,
                           ^BOOL {
                               return transfer.verified || pair.initiatorClosed || pair.responderClosed;
                           }),
              @"session over route %ld settles", (long)route);
    SZFOnQueue(pair.queue, ^{
        [pair.initiator close];
        [pair.responder close];
    });
    SZFDrain(pair.queue);
    return stats;
}

static void SZFTestResumeAcrossRoutes(void) {
    SZFTransfer *transfer = [[SZFTransfer alloc] init];
    transfer.file = SZFRandomBytes(300 * 1024 + 123);
    transfer.offerID = SZFRandomBytes(16);
    transfer.durable = [NSMutableData data];

    // Bluetooth, cut 100,000 bytes into the sender's stream: in the middle of some chunk.
    SZFSessionStats first = SZFRunTransferSession(transfer, SZFriendsRouteMethodBluetooth, 100000);
    SZF_CHECK(first.resumedFrom == 0 && first.largestChunk == 4096 && !first.protocolViolation,
              @"first session: from 0 in 4 KiB chunks");
    SZF_CHECK(!transfer.verified && transfer.durable.length > 0 && transfer.durable.length < 100000,
              @"the cut leaves a partial transfer (%lu durable bytes)", (unsigned long)transfer.durable.length);
    SZF_CHECK([transfer.durable isEqualToData:[transfer.file subdataWithRange:NSMakeRange(0, transfer.durable.length)]],
              @"durable bytes are a prefix of the file");
    uint64_t durableAfterCut = transfer.durable.length;

    // A faster route: the new session resumes exactly at the durable count, with the route's own chunk size.
    SZFSessionStats second = SZFRunTransferSession(transfer, SZFriendsRouteMethodLAN, 0);
    SZF_CHECK(second.resumedFrom == durableAfterCut, @"resumed from %llu, durable was %llu",
              (unsigned long long)second.resumedFrom, (unsigned long long)durableAfterCut);
    SZF_CHECK(second.largestChunk == 61440 && !second.protocolViolation, @"LAN moves 60 KiB chunks");
    SZF_CHECK(transfer.verified && [transfer.durable isEqualToData:transfer.file], @"the file arrives whole");

    // A session that resumes a finished transfer moves nothing and verifies at once.
    SZFTransfer *empty = [[SZFTransfer alloc] init];
    empty.file = [NSData data];
    empty.offerID = SZFRandomBytes(16);
    empty.durable = [NSMutableData data];
    SZFSessionStats nothing = SZFRunTransferSession(empty, SZFriendsRouteMethodLAN, 0);
    SZF_CHECK(nothing.largestChunk == 0 && empty.verified, @"an empty file is DONE straight away");
}

void SZFRunTransferResumeTests(void) {
    SZFTestResumeAcrossRoutes();
}
