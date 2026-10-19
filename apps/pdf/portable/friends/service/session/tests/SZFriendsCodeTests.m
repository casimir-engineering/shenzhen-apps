// Comparison codes: golden derivations (cross-checked with Python's hashlib), the exchange between two channels
// in either call order, refusals, and a responder whose reveal breaks its commitment.

#import <sodium.h>

#import "SZFScriptedPeer.h"
#import "SZFriendsSessionTests.h"

static void SZFTestGoldenCodes(void) {
    NSMutableData *h = [NSMutableData dataWithLength:64];
    for (int i = 0; i < 64; i++) {
        ((uint8_t *)h.mutableBytes)[i] = (uint8_t)i;
    }
    NSData *nA = SZFBytes(0xA5, 32), *nR = SZFBytes(0x5A, 32);
    SZF_CHECK([SZFHexString(SZFriendsCodeCommitment(h, nR))
                  isEqualToString:@"21fd0626d08ed7ec66a8c7dc30159f48296d8c2ae5bc168f64efa571e6666f2c"],
              @"commitment");
    SZF_CHECK([SZFriendsComparisonCode(h, nA, nR) isEqualToString:@"934422"], @"code");
    NSData *padNonce = SZFHex(@"0500000000000000000000000000000000000000000000000000000000000000");
    SZF_CHECK([SZFriendsComparisonCode(h, nA, padNonce) isEqualToString:@"047901"], @"leading zero kept");
    SZF_CHECK(![SZFriendsComparisonCode(h, nR, nA) isEqualToString:@"934422"], @"nonce order matters");
}

typedef struct {
    NSString *__strong initiatorCode, *responderCode;
    NSError *__strong initiatorError, *responderError;
} SZFCodes;

static SZFCodes SZFRunExchange(SZFriendsHandshakePattern pattern, BOOL responderFirst, BOOL beforeLive) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFChannelPair *pair = [SZFChannelPair pairWithOptions:SZFOptions(pattern, bob)
                                         initiatorIdentity:alice
                                         responderIdentity:bob
                                             publicProfile:pattern == SZFriendsHandshakeXX ? @{} : nil
                                                    policy:nil];
    __block SZFCodes codes = {nil, nil, nil, nil};
    __block int finished = 0;
    void (^runInitiator)(void) = ^{
        [pair.initiator runComparisonCodeExchange:^(NSString *code, NSError *error) {
            codes.initiatorCode = code;
            codes.initiatorError = error;
            finished++;
        }];
    };
    void (^runResponder)(void) = ^{
        [pair.responder runComparisonCodeExchange:^(NSString *code, NSError *error) {
            codes.responderCode = code;
            codes.responderError = error;
            finished++;
        }];
    };
    if (beforeLive) {
        SZFOnQueue(pair.queue, ^{
            responderFirst ? runResponder() : runInitiator();
            responderFirst ? runInitiator() : runResponder();
        });
        [pair start];
    } else {
        [pair start];
        SZF_CHECK([pair waitUntilBothEstablished], @"established");
        SZFOnQueue(pair.queue, responderFirst ? runResponder : runInitiator);
        SZFDrain(pair.queue);
        SZFOnQueue(pair.queue, responderFirst ? runInitiator : runResponder);
    }
    SZF_CHECK(SZFWaitUntil(pair.queue, 5,
                           ^BOOL {
                               return finished == 2;
                           }),
              @"both completions run");
    SZFOnQueue(pair.queue, ^{
        [pair.initiator runComparisonCodeExchange:^(NSString *code, NSError *error) {
            SZF_CHECK(code == nil && error.code == SZFriendsSessionErrorProtocol, @"a second run is refused");
            finished++;
        }];
    });
    SZF_CHECK(SZFWaitUntil(pair.queue, 5,
                           ^BOOL {
                               return finished == 3;
                           }),
              @"refusal arrives");
    return codes;
}

static void SZFTestExchange(void) {
    for (int pattern = SZFriendsHandshakeXX; pattern <= SZFriendsHandshakeIK; pattern++) {
        for (int order = 0; order < 4; order++) {
            SZFCodes codes = SZFRunExchange((SZFriendsHandshakePattern)pattern, (order & 1) != 0, (order & 2) != 0);
            SZF_CHECK(codes.initiatorCode.length == 6 && [codes.initiatorCode isEqualToString:codes.responderCode],
                      @"pattern %d order %d: codes %@ and %@ (%@ %@)", pattern, order, codes.initiatorCode,
                      codes.responderCode, codes.initiatorError, codes.responderError);
        }
    }
    SZFCodes nn = SZFRunExchange(SZFriendsHandshakeNN, NO, NO);
    SZF_CHECK(nn.initiatorCode == nil && nn.responderCode == nil && nn.initiatorError && nn.responderError,
              @"NN has no identities to compare");
}

// The scripted peer plays the responder, commits to one nonce and reveals another (or the right one).
static void SZFTestCommitment(BOOL honest) {
    dispatch_queue_t queue = dispatch_queue_create("szfriends.session.codes", DISPATCH_QUEUE_SERIAL);
    NSArray<SZFMemoryStream *> *streams = [SZFMemoryStream pair];
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFriendsSecureChannel *channel =
        [[SZFriendsSecureChannel alloc] initAsInitiatorWithStream:streams[0]
                                                         identity:alice
                                                          options:SZFOptions(SZFriendsHandshakeIK, bob)
                                                            queue:queue];
    SZFScriptedPeer *peer = [[SZFScriptedPeer alloc] initWithStream:streams[1] queue:queue identity:bob];
    [peer respondWithPayloads:@{@1 : SZFPeerPayload(bob, -1, nil)}];
    __block NSString *code = nil;
    __block NSError *codeError = nil, *closeError = nil;
    __block BOOL completed = NO, closed = NO;
    channel.onClose = ^(NSError *error) {
        closed = YES;
        closeError = error;
    };
    NSData *committedNonce = SZFRandomBytes(32);
    NSData *revealedNonce = honest ? committedNonce : SZFRandomBytes(32);
    __weak SZFScriptedPeer *weakPeer = peer;
    peer.onPlaintext = ^(NSData *plaintext) {
        SZFriendsFrame *frame = SZFriendsDecodeFrame(plaintext, NULL);
        if (frame.type == SZFriendsFrameTypeHello) {
            [weakPeer sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeCodeCommit
                                                       fields:@{@(SZFriendsFieldCommitment) :
                                                                    SZFriendsCodeCommitment(weakPeer.handshakeHash,
                                                                                            committedNonce)}]];
        } else if (frame.type == SZFriendsFrameTypeCodeNonce) {
            [weakPeer sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeCodeReveal
                                                       fields:@{@(SZFriendsFieldNonce) : revealedNonce}]];
        }
    };
    SZFOnQueue(queue, ^{
        [channel runComparisonCodeExchange:^(NSString *c, NSError *e) {
            code = c;
            codeError = e;
            completed = YES;
        }];
        [channel start];
    });
    SZF_CHECK(SZFWaitUntil(queue, 5,
                           ^BOOL {
                               return completed;
                           }),
              @"exchange completes");
    SZFDrain(queue);
    SZFOnQueue(queue, ^{
        __block NSData *initiatorNonce = nil;
        for (NSData *plaintext in peer.plaintexts) {
            SZFriendsFrame *frame = SZFriendsDecodeFrame(plaintext, NULL);
            if (frame.type == SZFriendsFrameTypeCodeNonce) {
                initiatorNonce = [frame dataForTag:SZFriendsFieldNonce];
            }
        }
        if (honest) {
            NSString *expected = SZFriendsComparisonCode(peer.handshakeHash, initiatorNonce, committedNonce);
            SZF_CHECK([code isEqualToString:expected],
                      @"the initiator's code is the derivation over h and both nonces");
            SZF_CHECK(!closed, @"an honest exchange leaves the session open");
        } else {
            SZF_CHECK(code == nil && codeError.code == SZFriendsSessionErrorCodeMismatch, @"mismatch reported: %@",
                      codeError);
            SZF_CHECK(closed && closeError.code == SZFriendsSessionErrorCodeMismatch, @"and the channel closes: %@",
                      closeError);
            NSData *expectedClose = SZFPlaintext(SZFriendsFrameTypeClose, @{
                @(SZFriendsFieldReason) : SZFBytes(SZFriendsCloseReasonCodeMismatch, 1)
            });
            SZF_CHECK([peer.plaintexts.lastObject isEqualToData:expectedClose], @"telling the peer why");
        }
    });
}

static void SZFTestOutOfOrderCodeFrames(void) {
    // A responder that reveals before the initiator sent its nonce.
    dispatch_queue_t queue = dispatch_queue_create("szfriends.session.codes.order", DISPATCH_QUEUE_SERIAL);
    NSArray<SZFMemoryStream *> *streams = [SZFMemoryStream pair];
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFriendsSecureChannel *channel =
        [[SZFriendsSecureChannel alloc] initAsInitiatorWithStream:streams[0]
                                                         identity:alice
                                                          options:SZFOptions(SZFriendsHandshakeIK, bob)
                                                            queue:queue];
    SZFScriptedPeer *peer = [[SZFScriptedPeer alloc] initWithStream:streams[1] queue:queue identity:bob];
    [peer respondWithPayloads:@{@1 : SZFPeerPayload(bob, -1, nil)}];
    __block NSError *closeError = nil;
    channel.onClose = ^(NSError *error) {
        closeError = error;
    };
    SZFOnQueue(queue, ^{
        [channel start];
    });
    SZFDrain(queue);
    SZFOnQueue(queue, ^{
        [peer sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeCodeReveal
                                               fields:@{@(SZFriendsFieldNonce) : SZFRandomBytes(32)}]];
    });
    SZFDrain(queue);
    SZF_CHECK(closeError.code == SZFriendsSessionErrorProtocol, @"a reveal before the nonce closes: %@", closeError);
}

void SZFRunCodeTests(void) {
    SZFTestGoldenCodes();
    SZFTestExchange();
    SZFTestCommitment(YES);
    SZFTestCommitment(NO);
    SZFTestOutOfOrderCodeFrames();
}
