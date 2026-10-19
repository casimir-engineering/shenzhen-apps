// Fault injection on live sessions: every byte of a recorded XX and IK exchange corrupted in turn, the link cut at
// every byte, a transport message delivered twice, an IK session replayed to a fresh responder, one-byte slices
// and delayed delivery. The invariant everywhere: a damaged session never delivers a frame it did not send.

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

#import "service/session/SZFriendsSecureChannelInternal.h"

static NSString *const kRequest = @"is the contract signed?";
static NSString *const kReply = @"yes, sent it this morning";

typedef struct {
    BOOL requestDelivered; // the responder got kRequest, intact
    BOOL replyDelivered;   // the initiator got kReply, intact
    BOOL foreignFrame;     // either side got anything else
    BOOL closed;           // either side closed
    NSUInteger initiatorBytes, responderBytes;
} SZFExchangeResult;

// Initiator sends kRequest as soon as it is live; the responder answers kReply. `configure` adjusts the streams.
static SZFExchangeResult SZFRunExchange(SZFriendsHandshakePattern pattern, SZFriendsIdentity *alice,
                                        SZFriendsIdentity *bob, void (^configure)(SZFChannelPair *pair)) {
    SZFChannelPair *pair = [SZFChannelPair pairWithOptions:SZFOptions(pattern, bob)
                                         initiatorIdentity:alice
                                         responderIdentity:bob
                                             publicProfile:pattern == SZFriendsHandshakeXX ? @{} : nil
                                                    policy:nil];
    __weak SZFChannelPair *weakPair = pair;
    pair.initiator.onEstablished = ^{
        weakPair.initiatorEstablished = YES;
        [weakPair.initiator sendFrame:SZFMessageFrame(kRequest)];
    };
    pair.responder.onFrame = ^(SZFriendsFrame *frame) {
        [weakPair.responderFrames addObject:frame];
        [weakPair.responder sendFrame:SZFMessageFrame(kReply)];
    };
    if (configure) {
        configure(pair);
    }
    [pair start];
    SZFDrain(pair.queue);
    __block SZFExchangeResult result = {NO, NO, NO, NO, 0, 0};
    SZFOnQueue(pair.queue, ^{
        for (SZFriendsFrame *frame in pair.responderFrames) {
            if ([[frame stringForTag:SZFriendsFieldText] isEqualToString:kRequest]) {
                result.requestDelivered = YES;
            } else {
                result.foreignFrame = YES;
            }
        }
        for (SZFriendsFrame *frame in pair.initiatorFrames) {
            if ([[frame stringForTag:SZFriendsFieldText] isEqualToString:kReply]) {
                result.replyDelivered = YES;
            } else {
                result.foreignFrame = YES;
            }
        }
        result.closed = pair.initiatorClosed || pair.responderClosed;
        result.initiatorBytes = pair.initiatorStream.transcript.length;
        result.responderBytes = pair.responderStream.transcript.length;
        // Stalled sessions (a corrupted length now waits for bytes that never come) are ended here.
        [pair.initiator close];
        [pair.responder close];
    });
    SZFDrain(pair.queue);
    return result;
}

static void SZFTestEveryByteCorrupted(SZFriendsHandshakePattern pattern) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFExchangeResult clean = SZFRunExchange(pattern, alice, bob, nil);
    SZF_CHECK(clean.requestDelivered && clean.replyDelivered && !clean.foreignFrame, @"pattern %u: clean exchange",
              pattern);
    NSUInteger tampered = 0, undetected = 0;
    for (int direction = 0; direction < 2; direction++) {
        NSUInteger length = direction == 0 ? clean.initiatorBytes : clean.responderBytes;
        for (NSUInteger index = 0; index < length; index++) {
            SZFExchangeResult result = SZFRunExchange(pattern, alice, bob, ^(SZFChannelPair *pair) {
                SZFMemoryStream *stream = direction == 0 ? pair.initiatorStream : pair.responderStream;
                stream.filter = ^NSData *(NSData *write, uint64_t offset) {
                    if (index < offset || index >= offset + write.length) {
                        return write;
                    }
                    NSMutableData *copy = [write mutableCopy];
                    ((uint8_t *)copy.mutableBytes)[index - offset] ^= 0x41;
                    return copy;
                };
            });
            tampered++;
            SZF_CHECK(!result.foreignFrame, @"pattern %u: byte %lu of direction %d delivered a forged frame", pattern,
                      (unsigned long)index, direction);
            if (result.requestDelivered && result.replyDelivered) {
                undetected++;
                SZF_CHECK(NO, @"pattern %u: corrupting byte %lu of direction %d went unnoticed", pattern,
                          (unsigned long)index, direction);
            }
        }
    }
    SZF_CHECK(tampered > 200, @"pattern %u: only %lu bytes exercised", pattern, (unsigned long)tampered);
    printf("tamper pattern %u: %lu single-byte corruptions, %lu undetected\n", pattern, (unsigned long)tampered,
           (unsigned long)undetected);
}

static void SZFTestCutAtEveryByte(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFExchangeResult clean = SZFRunExchange(SZFriendsHandshakeIK, alice, bob, nil);
    for (int direction = 0; direction < 2; direction++) {
        NSUInteger length = direction == 0 ? clean.initiatorBytes : clean.responderBytes;
        for (NSUInteger cut = 1; cut < length; cut++) {
            SZFExchangeResult result = SZFRunExchange(SZFriendsHandshakeIK, alice, bob, ^(SZFChannelPair *pair) {
                (direction == 0 ? pair.initiatorStream : pair.responderStream).severAfterBytes = cut;
            });
            SZF_CHECK(!result.foreignFrame && result.closed && !(result.requestDelivered && result.replyDelivered),
                      @"cut after %lu bytes of direction %d", (unsigned long)cut, direction);
        }
    }
}

static void SZFTestDuplicateDelivery(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    __block SZFChannelPair *kept = nil;
    // Writes from an IK initiator: 0 preamble and message 1, 1 HELLO, 2 the request.
    SZFExchangeResult result = SZFRunExchange(SZFriendsHandshakeIK, alice, bob, ^(SZFChannelPair *pair) {
        pair.initiatorStream.duplicateWriteIndex = 2;
        kept = pair;
    });
    SZF_CHECK(result.requestDelivered && !result.foreignFrame, @"the original arrives once");
    SZF_CHECK(kept.responderFrames.count == 1, @"the replayed copy is not delivered");
    SZF_CHECK(kept.responderError.code == SZFriendsSessionErrorDecryptFailed, @"replay inside a session closes it: %@",
              kept.responderError);
}

typedef struct {
    NSUInteger policyCalls, frames;
    BOOL established;
    NSInteger closeCode;
} SZFReplayOutcome;

// Every byte an initiator sent, replayed to a new responder with the same identity, an accepting policy and `cache`.
static SZFReplayOutcome SZFReplayToResponder(NSData *recorded, SZFriendsIdentity *identity,
                                             SZFriendsReplayCache *cache) {
    dispatch_queue_t queue = dispatch_queue_create("szfriends.session.replay", DISPATCH_QUEUE_SERIAL);
    NSArray<SZFMemoryStream *> *streams = [SZFMemoryStream pair];
    __block SZFReplayOutcome outcome = {0, 0, NO, 0};
    SZFriendsSecureChannel *responder = [[SZFriendsSecureChannel alloc]
        initAsResponderWithStream:streams[1]
                         identity:identity
                    publicProfile:nil
                        keyPolicy:^BOOL(NSData *key, SZFriendsHandshakePattern pattern, NSData *token) {
                            (void)key, (void)pattern, (void)token;
                            outcome.policyCalls++;
                            return YES;
                        }
                            queue:queue];
    responder.replayCache = cache;
    [responder setScheduler:SZFImmediateScheduler()];
    responder.onEstablished = ^{
        outcome.established = YES;
    };
    responder.onFrame = ^(SZFriendsFrame *frame) {
        (void)frame;
        outcome.frames++;
    };
    responder.onClose = ^(NSError *error) {
        outcome.closeCode = error.code;
    };
    SZFOnQueue(queue, ^{
        [streams[0] startWithQueue:queue];
        [responder start];
        [streams[0] writeData:recorded completion:nil];
    });
    SZFDrain(queue);
    __block SZFReplayOutcome result;
    SZFOnQueue(queue, ^{
        result = outcome;
    });
    return result;
}

// Review finding "work before authentication, IK replay": a replayed IK message 1 used to reach the key policy (and
// cost a full reply) every time. Now the responder remembers message 1's ephemeral key and refuses a repeat before
// the policy, so the policy runs at most once per distinct message 1.
static void SZFTestReplayedSession(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    __block NSData *recorded = nil;
    __block SZFriendsReplayCache *cache = nil;
    SZFRunExchange(SZFriendsHandshakeIK, alice, bob, ^(SZFChannelPair *pair) {
        recorded = pair.initiatorStream.transcript; // filled as the session runs
        cache = pair.responder.replayCache;
    });
    SZF_CHECK(recorded.length > 100, @"recorded an IK session");

    SZFReplayOutcome replayed = SZFReplayToResponder(recorded, bob, cache);
    SZF_CHECK(replayed.policyCalls == 0, @"a replayed message 1 never reaches the policy, got %lu calls",
              (unsigned long)replayed.policyCalls);
    SZF_CHECK(!replayed.established && replayed.frames == 0, @"a replayed session never goes live");
    SZF_CHECK(replayed.closeCode == SZFriendsSessionErrorReplayed, @"refused as a replay, got %ld",
              (long)replayed.closeCode);
    SZFReplayOutcome again = SZFReplayToResponder(recorded, bob, cache);
    SZF_CHECK(again.policyCalls == 0 && again.closeCode == SZFriendsSessionErrorReplayed, @"and every time after");

    // What Noise alone allows (spec § 7.7): a responder that never saw it answers message 1 and asks the policy, and
    // only HELLO, which cannot replay, stops the session.
    SZFReplayOutcome fresh = SZFReplayToResponder(recorded, bob, [[SZFriendsReplayCache alloc] init]);
    SZF_CHECK(fresh.policyCalls == 1 && !fresh.established && fresh.frames == 0, @"message 1 replays to a new cache");
    SZF_CHECK(fresh.closeCode == SZFriendsSessionErrorDecryptFailed, @"HELLO fails to decrypt: %ld",
              (long)fresh.closeCode);
}

// The shared cache holds 65,536 keys. Message 1 that does not decrypt here (sealed to another listener, or junk) must
// not enter it, or a flood of them evicts a friend's message 1, which then replays to the policy (finding: replay
// cache eviction flood).
static NSData *SZFRecordIK(SZFriendsIdentity *alice, SZFriendsIdentity *bob) {
    __block NSData *recorded = nil;
    SZFRunExchange(SZFriendsHandshakeIK, alice, bob, ^(SZFChannelPair *pair) {
        recorded = pair.initiatorStream.transcript;
    });
    return recorded;
}

static void SZFTestReplayCacheFlood(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *carol = [SZFriendsIdentity szf_newIdentity];
    SZFriendsReplayCache *cache = [[SZFriendsReplayCache alloc] initWithCapacity:2 clock:nil];
    NSData *genuine = SZFRecordIK(alice, bob);
    SZFReplayOutcome first = SZFReplayToResponder(genuine, bob, cache);
    SZF_CHECK(first.policyCalls == 1 && cache.count == 1, @"first delivery reaches the policy once");
    for (int i = 0; i < 4; i++) {
        SZFReplayOutcome foreign = SZFReplayToResponder(SZFRecordIK(alice, carol), bob, cache);
        SZF_CHECK(foreign.policyCalls == 0 && foreign.closeCode == SZFriendsSessionErrorHandshakeFailed,
                  @"IK sealed to another listener is refused: %ld", (long)foreign.closeCode);
    }
    SZF_CHECK(cache.count == 1, @"message 1 that did not decrypt entered the cache: %lu", (unsigned long)cache.count);
    SZFReplayOutcome replayed = SZFReplayToResponder(genuine, bob, cache);
    SZF_CHECK(replayed.policyCalls == 0 && replayed.closeCode == SZFriendsSessionErrorReplayed,
              @"a flood let a replayed message 1 through: %lu calls, code %ld", (unsigned long)replayed.policyCalls,
              (long)replayed.closeCode);
}

static void SZFTestSlicedAndDelayed(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    for (int pattern = SZFriendsHandshakeXX; pattern <= SZFriendsHandshakeIK; pattern++) {
        SZFExchangeResult sliced = SZFRunExchange((SZFriendsHandshakePattern)pattern, alice, bob,
                                                  ^(SZFChannelPair *pair) {
                                                      pair.initiatorStream.byteByByte = YES;
                                                      pair.responderStream.byteByByte = YES;
                                                  });
        SZF_CHECK(sliced.requestDelivered && sliced.replyDelivered && !sliced.foreignFrame,
                  @"pattern %d reassembles one-byte deliveries", pattern);
        SZFExchangeResult delayed = SZFRunExchange((SZFriendsHandshakePattern)pattern, alice, bob,
                                                   ^(SZFChannelPair *pair) {
                                                       pair.initiatorStream.delay = 0.02;
                                                       pair.responderStream.delay = 0.03;
                                                   });
        SZF_CHECK(delayed.requestDelivered && delayed.replyDelivered, @"pattern %d with delay", pattern);
    }
}

void SZFRunChannelFaultTests(void) {
    SZFTestEveryByteCorrupted(SZFriendsHandshakeXX);
    SZFTestEveryByteCorrupted(SZFriendsHandshakeIK);
    SZFTestCutAtEveryByte();
    SZFTestDuplicateDelivery();
    SZFTestReplayedSession();
    SZFTestReplayCacheFlood();
    SZFTestSlicedAndDelayed();
}
