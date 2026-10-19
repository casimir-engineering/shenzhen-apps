// ADR 0001 over the transport's streams, with the session area's real secure channel and chunk flow: Noise IK as a
// friend dials, CHUNK frames under the 8 MiB window, PROGRESS back, and DONE with the BLAKE2b-256 the receiver
// recomputes. This is what "ADR 0001 runs unchanged above the data channel" (ADR 0009) means in practice.

#import "SZFOnlineTestSupport.h"

#import "service/identity/SZFriendsIdentity.h"

#include <sodium.h>

// Pseudo-random content: a pool of whole chunks, so every chunk (60 KiB at most, at offsets that are multiples of
// 60 KiB) is one contiguous slice of it.
static const NSUInteger kPoolChunks = 64;
// The receiver reports progress at least this often, well inside the window.
static const uint64_t kProgressStep = 1024 * 1024;

static NSData *ContentPool(NSUInteger chunkBytes) {
    static NSMutableData *pool;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pool = [NSMutableData dataWithLength:chunkBytes * kPoolChunks];
        randombytes_buf(pool.mutableBytes, pool.length);
    });
    return pool;
}

static SZFriendsIdentity *NewIdentity(void) {
    NSMutableData *seed = [NSMutableData dataWithLength:32], *staticKey = [NSMutableData dataWithLength:32];
    randombytes_buf(seed.mutableBytes, seed.length);
    randombytes_buf(staticKey.mutableBytes, staticKey.length);
    return [SZFriendsIdentity identityWithSigningSeed:seed staticPrivateKey:staticKey];
}

@interface SZFOTransferRun : NSObject
@property(nonatomic) BOOL verified, failed;
@end

@implementation SZFOTransferRun
@end

BOOL SZFOTransfer(id<SZFriendsByteStream> initiatorStream, id<SZFriendsByteStream> responderStream, uint64_t bytes,
                  NSTimeInterval timeout, NSTimeInterval *seconds) {
    if (sodium_init() < 0) return NO;
    dispatch_queue_t queue = dispatch_queue_create("szfo.transfer", DISPATCH_QUEUE_SERIAL);
    SZFriendsIdentity *alice = NewIdentity(), *bob = NewIdentity();
    SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
    options.pattern = SZFriendsHandshakeIK;
    options.route = SZFriendsRouteMethodInternet;
    options.remoteStaticKey = bob.staticPublicKey;
    options.expectedIdentityKey = bob.publicKey;
    SZFriendsSecureChannel *initiator = [[SZFriendsSecureChannel alloc] initAsInitiatorWithStream:initiatorStream
                                                                                         identity:alice
                                                                                          options:options
                                                                                            queue:queue];
    NSData *aliceKey = alice.publicKey;
    SZFriendsSecureChannel *responder = [[SZFriendsSecureChannel alloc]
        initAsResponderWithStream:responderStream
                         identity:bob
                    publicProfile:nil
                        keyPolicy:^BOOL(NSData *remoteIdentityKey, SZFriendsHandshakePattern pattern, NSData *token) {
                            (void)token;
                            return pattern == SZFriendsHandshakeIK && [remoteIdentityKey isEqualToData:aliceKey];
                        }
                            queue:queue];
    SZFOTransferRun *run = [SZFOTransferRun new];
    NSData *offerID = SZFOBytes(0x17, 16);
    NSUInteger chunkBytes = SZFriendsChunkBytesForRoute(SZFriendsRouteMethodInternet);
    NSData *pool = ContentPool(chunkBytes);
    SZFriendsChunkSender *sender = [[SZFriendsChunkSender alloc] initWithOfferID:offerID
                                                                            size:bytes
                                                                    resumeOffset:0
                                                                           route:SZFriendsRouteMethodInternet];
    SZFriendsChunkReceiver *receiver = [[SZFriendsChunkReceiver alloc] initWithOfferID:offerID
                                                                                  size:bytes
                                                                        verifiedOffset:0
                                                                                 route:SZFriendsRouteMethodInternet];
    __block crypto_generichash_state sent, received;
    crypto_generichash_init(&sent, NULL, 0, 32);
    crypto_generichash_init(&received, NULL, 0, 32);
    __block BOOL doneSent = NO;
    // The channels hold these blocks; the blocks reach the channels weakly (this function keeps both alive).
    __weak SZFriendsSecureChannel *weakInitiator = initiator, *weakResponder = responder;
    __block NSDate *started = nil;

    void (^pump)(void) = ^{
        uint64_t offset = 0;
        NSUInteger length = 0;
        while ([sender getNextChunkOffset:&offset length:&length]) {
            NSData *slice = [pool subdataWithRange:NSMakeRange((NSUInteger)(offset % pool.length), length)];
            crypto_generichash_update(&sent, slice.bytes, slice.length);
            SZFriendsFrame *chunk = [sender chunkFrameWithData:slice];
            if (chunk == nil || ![weakInitiator sendFrame:chunk]) run.failed = YES;
        }
        if (sender.allSent && !doneSent) {
            doneSent = YES;
            NSMutableData *digest = [NSMutableData dataWithLength:32];
            crypto_generichash_final(&sent, digest.mutableBytes, 32);
            SZFriendsFrame *done = [SZFriendsFrame frameWithType:SZFriendsFrameTypeDone
                                                          fields:@{@(SZFriendsFieldID) : offerID,
                                                                   @(SZFriendsFieldDigest) : digest}];
            if (![weakInitiator sendFrame:done]) run.failed = YES;
        }
    };
    initiator.onEstablished = ^{
        started = [NSDate date];
        pump();
    };
    initiator.onFrame = ^(SZFriendsFrame *frame) {
        if (frame.type != SZFriendsFrameTypeProgress) return;
        if (![sender handleProgressFrame:frame error:NULL]) run.failed = YES;
        pump();
    };
    responder.onFrame = ^(SZFriendsFrame *frame) {
        if (frame.type == SZFriendsFrameTypeChunk) {
            NSData *data = [receiver acceptChunkFrame:frame error:NULL];
            if (data == nil) {
                run.failed = YES;
                return;
            }
            crypto_generichash_update(&received, data.bytes, data.length);
            if (receiver.complete || receiver.receivedOffset - receiver.reportedOffset >= kProgressStep) {
                SZFriendsFrame *progress = [receiver progressFrameForDurableOffset:receiver.receivedOffset];
                if (progress) [weakResponder sendFrame:progress];
            }
        } else if (frame.type == SZFriendsFrameTypeDone) {
            NSData *claimed = [receiver acceptDoneFrame:frame error:NULL];
            NSMutableData *digest = [NSMutableData dataWithLength:32];
            crypto_generichash_final(&received, digest.mutableBytes, 32);
            if (claimed != nil && [claimed isEqualToData:digest]) run.verified = YES;
            else run.failed = YES;
        }
    };
    void (^closed)(NSError *) = ^(NSError *error) {
        if (!run.verified && error) run.failed = YES;
    };
    initiator.onClose = closed;
    responder.onClose = closed;
    dispatch_sync(queue, ^{
        [responder start];
        [initiator start];
    });
    BOOL ok = SZFOWaitUntil(queue, timeout, ^BOOL {
        return run.verified || run.failed;
    });
    __block BOOL verified = NO;
    dispatch_sync(queue, ^{
        verified = run.verified && !run.failed;
        if (seconds && started) *seconds = -[started timeIntervalSinceNow];
        [initiator close];
        [responder close];
    });
    return ok && verified;
}
