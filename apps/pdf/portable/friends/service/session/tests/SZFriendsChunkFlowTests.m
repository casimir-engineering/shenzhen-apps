// SZFriendsChunkSender and SZFriendsChunkReceiver as pure state machines: chunk sizes per route, the window,
// PROGRESS rules, offsets and lengths checked against the transfer, resume points and DONE.

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

static SZFriendsFrame *SZFChunk(NSData *offerID, uint64_t offset, NSData *data) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeChunk
                                  fields:@{
                                      @(SZFriendsFieldID) : offerID,
                                      @(SZFriendsFieldOffset) : [SZFriendsFrame fieldWithUInt64:offset
                                                                                            tag:SZFriendsFieldOffset],
                                      @(SZFriendsFieldData) : data,
                                  }];
}

static SZFriendsFrame *SZFProgress(NSData *offerID, uint64_t offset) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeProgress
                                  fields:@{
                                      @(SZFriendsFieldID) : offerID,
                                      @(SZFriendsFieldOffset) : [SZFriendsFrame fieldWithUInt64:offset
                                                                                            tag:SZFriendsFieldOffset],
                                  }];
}

static void SZFTestSenderWindow(void) {
    NSData *offer = SZFBytes(0x42, 16);
    SZF_CHECK([[SZFriendsChunkSender alloc] initWithOfferID:SZFBytes(1, 15) size:10 resumeOffset:0 chunkBytes:4
                                                     window:8] == nil,
              @"offer IDs are 16 bytes");
    SZF_CHECK([[SZFriendsChunkSender alloc] initWithOfferID:offer size:10 resumeOffset:11 chunkBytes:4 window:8] == nil,
              @"a resume point past the end is refused");
    SZF_CHECK([[SZFriendsChunkSender alloc] initWithOfferID:offer size:10 resumeOffset:0 chunkBytes:9 window:8] == nil,
              @"a chunk larger than the window could never move");

    SZFriendsChunkSender *sender = [[SZFriendsChunkSender alloc] initWithOfferID:offer
                                                                            size:10
                                                                    resumeOffset:0
                                                                      chunkBytes:4
                                                                          window:8];
    uint64_t offset = 99;
    NSUInteger length = 99;
    SZF_CHECK([sender getNextChunkOffset:&offset length:&length] && offset == 0 && length == 4, @"first chunk");
    SZF_CHECK([sender chunkFrameWithData:SZFBytes(1, 3)] == nil && sender.sentOffset == 0, @"wrong length refused");
    SZFriendsFrame *first = [sender chunkFrameWithData:SZFBytes(1, 4)];
    SZF_CHECK(first && SZFriendsEncodeFrame(first, NULL) && sender.sentOffset == 4, @"first chunk built");
    [sender chunkFrameWithData:SZFBytes(2, 4)];
    SZF_CHECK(![sender getNextChunkOffset:&offset length:&length], @"window of 8 is full");
    NSError *error = nil;
    SZF_CHECK(![sender handleProgressFrame:SZFProgress(offer, 9) error:&error] &&
                  error.code == SZFriendsSessionErrorProtocol,
              @"PROGRESS for bytes never sent");
    SZF_CHECK(![sender handleProgressFrame:SZFProgress(SZFBytes(0x43, 16), 4) error:NULL], @"another offer's PROGRESS");
    SZF_CHECK([sender handleProgressFrame:SZFProgress(offer, 4) error:NULL] && sender.durableOffset == 4,
              @"PROGRESS 4");
    SZF_CHECK([sender handleProgressFrame:SZFProgress(offer, 4) error:NULL], @"a repeated PROGRESS is harmless");
    SZF_CHECK(![sender handleProgressFrame:SZFProgress(offer, 3) error:NULL], @"PROGRESS going backwards");
    SZF_CHECK([sender getNextChunkOffset:&offset length:&length] && offset == 8 && length == 2,
              @"the last chunk is short");
    [sender chunkFrameWithData:SZFBytes(3, 2)];
    SZF_CHECK(sender.allSent && !sender.acknowledged, @"all sent, not yet acknowledged");
    SZF_CHECK([sender handleProgressFrame:SZFProgress(offer, 10) error:NULL] && sender.acknowledged, @"acknowledged");

    // Full-size chunks only: one that would cross the window waits rather than going out short.
    SZFriendsChunkSender *waiting = [[SZFriendsChunkSender alloc] initWithOfferID:offer
                                                                             size:100
                                                                     resumeOffset:0
                                                                       chunkBytes:6
                                                                           window:10];
    [waiting chunkFrameWithData:SZFBytes(0, 6)];
    SZF_CHECK(![waiting getNextChunkOffset:&offset length:&length], @"6 + 6 > 10: wait for PROGRESS");

    SZFriendsChunkSender *bluetooth = [[SZFriendsChunkSender alloc] initWithOfferID:offer
                                                                               size:1 << 20
                                                                       resumeOffset:4096
                                                                              route:SZFriendsRouteMethodBluetooth];
    SZF_CHECK([bluetooth getNextChunkOffset:&offset length:&length] && offset == 4096 && length == 4096,
              @"Bluetooth: 4 KiB chunks from the resume point");
    NSUInteger chunks = 0;
    while ([bluetooth getNextChunkOffset:&offset length:&length]) {
        [bluetooth chunkFrameWithData:SZFBytes(0, length)];
        chunks++;
    }
    SZF_CHECK(chunks == 64 && bluetooth.sentOffset == 4096 + 256 * 1024, @"Bluetooth window: 256 KiB in flight");
}

static void SZFTestReceiverChecks(void) {
    NSData *offer = SZFBytes(0x42, 16);
    SZFriendsChunkReceiver *receiver = [[SZFriendsChunkReceiver alloc] initWithOfferID:offer
                                                                                  size:20
                                                                        verifiedOffset:4
                                                                            chunkBytes:4
                                                                                window:8];
    SZFriendsFrame *resume = receiver.resumeProgressFrame;
    uint64_t value = 0;
    SZF_CHECK(resume.type == SZFriendsFrameTypeProgress && [resume getUInt64:&value forTag:SZFriendsFieldOffset] &&
                  value == 4,
              @"a new session starts by reporting the verified count");
    NSError *error = nil;
    SZF_CHECK([receiver acceptChunkFrame:SZFChunk(SZFBytes(0x43, 16), 4, SZFBytes(0, 4)) error:&error] == nil &&
                  error.code == SZFriendsSessionErrorProtocol,
              @"a CHUNK for another offer");
    SZF_CHECK([receiver acceptChunkFrame:SZFChunk(offer, 0, SZFBytes(0, 4)) error:NULL] == nil,
              @"a CHUNK that rewinds");
    SZF_CHECK([receiver acceptChunkFrame:SZFChunk(offer, 8, SZFBytes(0, 4)) error:NULL] == nil, @"a CHUNK with a gap");
    SZF_CHECK([receiver acceptChunkFrame:SZFChunk(offer, 4, SZFBytes(0, 5)) error:NULL] == nil,
              @"a CHUNK larger than the route allows");
    NSData *accepted = [receiver acceptChunkFrame:SZFChunk(offer, 4, SZFBytes(1, 4)) error:NULL];
    SZF_CHECK([accepted isEqualToData:SZFBytes(1, 4)] &&
                  receiver.receivedOffset == 8,
              @"in-order chunk accepted");
    [receiver acceptChunkFrame:SZFChunk(offer, 8, SZFBytes(2, 4)) error:NULL];
    SZF_CHECK([receiver acceptChunkFrame:SZFChunk(offer, 12, SZFBytes(3, 4)) error:NULL] == nil,
              @"12 + 4 > last PROGRESS 4 + window 8: the sender overran its window");
    SZF_CHECK([receiver progressFrameForDurableOffset:13] == nil, @"cannot report bytes not received");
    SZF_CHECK([receiver progressFrameForDurableOffset:3] == nil, @"cannot report backwards");
    SZF_CHECK([receiver progressFrameForDurableOffset:12] != nil && receiver.reportedOffset == 12, @"PROGRESS 12");
    [receiver acceptChunkFrame:SZFChunk(offer, 12, SZFBytes(3, 4)) error:NULL];
    SZFriendsFrame *done = [SZFriendsFrame frameWithType:SZFriendsFrameTypeDone
                                                  fields:@{@(SZFriendsFieldID) : offer,
                                                           @(SZFriendsFieldDigest) : SZFBytes(9, 32)}];
    SZF_CHECK([receiver acceptDoneFrame:done error:&error] == nil, @"DONE before every byte arrived");
    SZF_CHECK([receiver acceptChunkFrame:SZFChunk(offer, 16, SZFBytes(4, 4)) error:NULL] && receiver.complete,
              @"complete at the declared size");
    SZF_CHECK([receiver acceptChunkFrame:SZFChunk(offer, 20, SZFBytes(5, 1)) error:NULL] == nil,
              @"nothing past the declared size");
    SZF_CHECK([[receiver acceptDoneFrame:done error:NULL] isEqualToData:SZFBytes(9, 32)],
              @"DONE hands over the digest");

    // Offsets near 2^64 cannot wrap the window arithmetic.
    SZFriendsChunkReceiver *huge = [[SZFriendsChunkReceiver alloc] initWithOfferID:offer
                                                                              size:UINT64_MAX
                                                                    verifiedOffset:UINT64_MAX - 4
                                                                        chunkBytes:4
                                                                            window:UINT64_MAX];
    SZF_CHECK([huge acceptChunkFrame:SZFChunk(offer, UINT64_MAX - 4, SZFBytes(0, 4)) error:NULL] != nil &&
                  huge.receivedOffset == UINT64_MAX,
              @"no wrap at the top of the range");
}

void SZFRunChunkFlowTests(void) {
    SZFTestSenderWindow();
    SZFTestReceiverChecks();
}
