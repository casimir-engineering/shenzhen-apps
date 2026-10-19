// A real channel against a scripted raw peer: exact rekey boundaries read in clear, unknown types and tags,
// frames before HELLO, malformed and truncated transport messages, NN rules, and handshake payload checks.

#import "SZFScriptedPeer.h"
#import "SZFriendsSessionTests.h"

#import "service/session/SZFriendsSecureChannelInternal.h"

@interface SZFPeerFixture : NSObject
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) SZFriendsSecureChannel *channel;
@property(nonatomic) SZFScriptedPeer *peer;
@property(nonatomic) SZFriendsIdentity *channelIdentity, *peerIdentity;
@property(nonatomic) NSMutableArray<SZFriendsFrame *> *frames;
@property(nonatomic) BOOL established, closed;
@property(nonatomic, nullable) NSError *error;
@end

@implementation SZFPeerFixture

- (instancetype)initWithChannelBuilder:(SZFriendsSecureChannel * (^)(SZFMemoryStream *, dispatch_queue_t,
                                                                      SZFriendsIdentity *))builder {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("szfriends.session.peer", DISPATCH_QUEUE_SERIAL);
        _channelIdentity = [SZFriendsIdentity szf_newIdentity];
        _peerIdentity = [SZFriendsIdentity szf_newIdentity];
        _frames = [NSMutableArray array];
        NSArray<SZFMemoryStream *> *streams = [SZFMemoryStream pair];
        _channel = builder(streams[0], _queue, _channelIdentity);
        _peer = [[SZFScriptedPeer alloc] initWithStream:streams[1] queue:_queue identity:_peerIdentity];
        __weak SZFPeerFixture *weakSelf = self;
        _channel.onEstablished = ^{
            weakSelf.established = YES;
        };
        _channel.onFrame = ^(SZFriendsFrame *frame) {
            [weakSelf.frames addObject:frame];
        };
        _channel.onClose = ^(NSError *error) {
            weakSelf.closed = YES;
            weakSelf.error = error;
        };
    }
    return self;
}

// The channel dials IK to the peer, which answers with a valid certificate unless `payload` says otherwise.
+ (instancetype)channelInitiatorWithResponderPayload:(NSData *)payload {
    __block SZFriendsIdentity *peerIdentity = nil;
    SZFPeerFixture *fixture = [[self alloc] initWithChannelBuilder:^SZFriendsSecureChannel *(
                                                SZFMemoryStream *stream, dispatch_queue_t queue,
                                                SZFriendsIdentity *identity) {
        SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
        options.pattern = SZFriendsHandshakeIK;
        options.route = SZFriendsRouteMethodLAN;
        return [[SZFriendsSecureChannel alloc] initAsInitiatorWithStream:stream
                                                                identity:identity
                                                                 options:options
                                                                   queue:queue];
    }];
    peerIdentity = fixture.peerIdentity;
    fixture.channel->_options.remoteStaticKey = peerIdentity.staticPublicKey;
    [fixture.peer respondWithPayloads:@{@1 : payload ?: SZFPeerPayload(peerIdentity, -1, nil)}];
    SZFOnQueue(fixture.queue, ^{
        [fixture.channel start];
    });
    SZFDrain(fixture.queue);
    return fixture;
}

// The peer dials the channel (a responder that accepts every key) with `pattern`. `payloads` builds the peer's
// handshake payloads from its identity; nil sends what an honest channel would.
+ (instancetype)channelResponderWithPattern:(szfriends_noise_pattern)pattern
                                   payloads:(NSDictionary * (^)(SZFriendsIdentity *peer))payloads {
    SZFPeerFixture *fixture = [[self alloc] initWithChannelBuilder:^SZFriendsSecureChannel *(
                                                SZFMemoryStream *stream, dispatch_queue_t queue,
                                                SZFriendsIdentity *identity) {
        return [[SZFriendsSecureChannel alloc]
            initAsResponderWithStream:stream
                             identity:identity
                        publicProfile:@{}
                            keyPolicy:^BOOL(NSData *k, SZFriendsHandshakePattern p, NSData *t) {
                                (void)k, (void)p, (void)t;
                                return YES;
                            }
                                queue:queue];
    }];
    // The scripted peer's refusal checks are about which refusal, not when: see SZFriendsChannelRefusalTests.
    [fixture.channel setScheduler:SZFImmediateScheduler()];
    SZFriendsIdentity *peer = fixture.peerIdentity;
    NSDictionary *chosen = payloads ? payloads(peer) : @{
        @0 : pattern == SZFRIENDS_NOISE_NN   ? SZFPeerPayload(nil, -1, nil)
             : pattern == SZFRIENDS_NOISE_IK ? SZFPeerPayload(peer, SZFriendsRouteMethodLAN, nil)
                                             : [NSData data],
        @2 : SZFPeerPayload(peer, SZFriendsRouteMethodLAN, nil),
    };
    SZFOnQueue(fixture.queue, ^{
        [fixture.channel start];
        [fixture.peer initiatePattern:pattern
                         remoteStatic:pattern == SZFRIENDS_NOISE_IK ? fixture.channelIdentity.staticPublicKey : nil
                             payloads:chosen];
    });
    SZFDrain(fixture.queue);
    return fixture;
}

- (void)peerSends:(NSData *)plaintext {
    SZFOnQueue(_queue, ^{
        [self.peer sendPlaintext:plaintext];
    });
    SZFDrain(_queue);
}

@end

static NSData *SZFHello(void) {
    return SZFPlaintext(SZFriendsFrameTypeHello, @{});
}

static void SZFTestRekeyBoundaryInClear(void) {
    for (int follow = 1; follow >= 0; follow--) {
        SZFPeerFixture *fixture = [SZFPeerFixture channelInitiatorWithResponderPayload:nil];
        fixture.peer.followRekeys = follow;
        SZF_CHECK(fixture.established && fixture.peer.handshakeDone, @"IK to the scripted peer");
        SZFOnQueue(fixture.queue, ^{
            [fixture.channel setRekeyAfterBytes:100 interval:SZFriendsRekeyAfterInterval];
            for (int i = 0; i < 3; i++) {
                [fixture.channel sendFrame:SZFMessageFrame(@"0123456789")];
            }
        });
        SZFDrain(fixture.queue);
        SZFOnQueue(fixture.queue, ^{
            NSArray<NSData *> *plaintexts = fixture.peer.plaintexts;
            if (follow) {
                // The check runs before each send: HELLO (1 byte) and three 44-byte messages reach 133 bytes, but
                // the count was 89 when the third went out, so no REKEY yet.
                SZF_CHECK(plaintexts.count == 4, @"HELLO and three messages, got %lu", (unsigned long)plaintexts.count);
            }
        });
        SZFOnQueue(fixture.queue, ^{
            [fixture.channel sendFrame:SZFMessageFrame(@"after the boundary")];
        });
        SZFDrain(fixture.queue);
        SZFOnQueue(fixture.queue, ^{
            NSArray<NSData *> *plaintexts = fixture.peer.plaintexts;
            if (follow) {
                NSData *rekey = SZFPlaintext(SZFriendsFrameTypeRekey, @{});
                SZF_CHECK(plaintexts.count == 6 && [plaintexts[4] isEqualToData:rekey],
                          @"REKEY goes right before the first frame sent past 100 bytes");
                SZF_CHECK(!fixture.peer.failed && [SZFriendsDecodeFrame(plaintexts[5], NULL)
                                                      stringForTag:SZFriendsFieldText] != nil,
                          @"the peer decrypts after rekeying");
            } else {
                SZF_CHECK(plaintexts.count == 5 && fixture.peer.failed,
                          @"without Rekey() the next message no longer decrypts: the key really changed");
            }
        });
    }
}

static void SZFTestUnknownTypeAndTag(void) {
    SZFPeerFixture *fixture = [SZFPeerFixture channelInitiatorWithResponderPayload:nil];
    NSData *ident = SZFBytes(1, 16);
    [fixture peerSends:SZFPlaintext(SZFriendsFrameTypeAck, @{@1 : ident, @222 : SZFBytes(7, 9)})];
    SZF_CHECK(fixture.frames.count == 1 && fixture.frames[0].fields.count == 1 && !fixture.closed,
              @"an unknown tag is ignored and the frame delivered");
    [fixture peerSends:SZFPlaintext(99, @{})];
    SZF_CHECK(fixture.closed && fixture.error.code == SZFriendsSessionErrorFrameInvalid, @"unknown type closes: %@",
              fixture.error);
    SZFOnQueue(fixture.queue, ^{
        NSData *expectedClose = SZFPlaintext(SZFriendsFrameTypeClose, @{@(SZFriendsFieldReason) : SZFBytes(1, 1)});
        SZF_CHECK([fixture.peer.plaintexts.lastObject isEqualToData:expectedClose],
                  @"the channel says CLOSE(protocol error) first");
    });
}

static void SZFTestTransportViolations(void) {
    // Malformed fields inside a correctly encrypted message.
    SZFPeerFixture *fixture = [SZFPeerFixture channelInitiatorWithResponderPayload:nil];
    [fixture peerSends:SZFHex(@"0d0100ff00")];
    SZF_CHECK(fixture.closed && fixture.error.code == SZFriendsSessionErrorFrameInvalid, @"overrunning field: %@",
              fixture.error);

    // An empty plaintext (just the tag) and a message shorter than the tag.
    fixture = [SZFPeerFixture channelInitiatorWithResponderPayload:nil];
    [fixture peerSends:[NSData data]];
    SZF_CHECK(fixture.closed && fixture.error.code == SZFriendsSessionErrorFrameInvalid, @"empty plaintext");
    fixture = [SZFPeerFixture channelInitiatorWithResponderPayload:nil];
    SZFOnQueue(fixture.queue, ^{
        [fixture.peer sendRaw:SZFHex(@"00050102030405")];
    });
    SZFDrain(fixture.queue);
    SZF_CHECK(fixture.closed && fixture.error.code == SZFriendsSessionErrorDecryptFailed, @"shorter than a tag");

    // A zero length prefix.
    fixture = [SZFPeerFixture channelInitiatorWithResponderPayload:nil];
    SZFOnQueue(fixture.queue, ^{
        [fixture.peer sendRaw:SZFHex(@"0000")];
    });
    SZFDrain(fixture.queue);
    SZF_CHECK(fixture.closed && fixture.error.code == SZFriendsSessionErrorFrameInvalid, @"zero-length message");

    // A message cut short by the link: the channel delivers nothing partial and reports the closed link.
    fixture = [SZFPeerFixture channelInitiatorWithResponderPayload:nil];
    SZFOnQueue(fixture.queue, ^{
        [fixture.peer sendRaw:SZFHex(@"0040aabbcc")];
    });
    SZFDrain(fixture.queue);
    SZF_CHECK(!fixture.closed && fixture.frames.count == 0, @"a partial message waits");
}

// Several large messages in one delivery, ending mid-message: the channel compacts its buffer and must still find
// the next message where it starts.
static void SZFTestCoalescedDeliveries(void) {
    SZFPeerFixture *fixture = [SZFPeerFixture channelInitiatorWithResponderPayload:nil];
    NSString *text = [@"" stringByPaddingToLength:32000 withString:@"w" startingAtIndex:0];
    __block NSMutableData *blob = [NSMutableData data];
    SZFOnQueue(fixture.queue, ^{
        for (int i = 0; i < 4; i++) {
            [blob appendData:[fixture.peer sealPlaintext:SZFriendsEncodeFrame(SZFMessageFrame(text), NULL)]];
        }
        NSUInteger split = blob.length - 1000;
        [fixture.peer sendRaw:[blob subdataWithRange:NSMakeRange(0, split)]];
        [fixture.peer sendRaw:[blob subdataWithRange:NSMakeRange(split, blob.length - split)]];
    });
    SZFDrain(fixture.queue);
    SZF_CHECK(fixture.frames.count == 4 && !fixture.closed, @"four 32 KB messages across two deliveries, got %lu (%@)",
              (unsigned long)fixture.frames.count, fixture.error);
}

static void SZFTestCodeFramesFromInitiator(void) {
    // An initiator that sends its nonce before any commitment: the responder must not reveal anything.
    SZFPeerFixture *fixture = [SZFPeerFixture channelResponderWithPattern:SZFRIENDS_NOISE_IK payloads:nil];
    [fixture peerSends:SZFHello()];
    [fixture peerSends:SZFPlaintext(SZFriendsFrameTypeCodeNonce, @{@(SZFriendsFieldNonce) : SZFBytes(1, 32)})];
    SZF_CHECK(fixture.closed && fixture.error.code == SZFriendsSessionErrorProtocol, @"nonce before commit: %@",
              fixture.error);
    SZFOnQueue(fixture.queue, ^{
        for (NSData *plaintext in fixture.peer.plaintexts) {
            SZF_CHECK(SZFriendsDecodeFrame(plaintext, NULL).type != SZFriendsFrameTypeCodeReveal, @"nothing revealed");
        }
    });
    // A commitment sent to the responder, which is the side that commits.
    fixture = [SZFPeerFixture channelResponderWithPattern:SZFRIENDS_NOISE_XX payloads:nil];
    [fixture peerSends:SZFHello()];
    [fixture peerSends:SZFPlaintext(SZFriendsFrameTypeCodeCommit, @{@(SZFriendsFieldCommitment) : SZFBytes(1, 32)})];
    SZF_CHECK(fixture.closed && fixture.error.code == SZFriendsSessionErrorProtocol, @"commit from the initiator");
}

static void SZFTestResponderRules(void) {
    // Anything before HELLO closes the responder, which never goes live.
    SZFPeerFixture *fixture = [SZFPeerFixture channelResponderWithPattern:SZFRIENDS_NOISE_IK payloads:nil];
    SZF_CHECK(fixture.peer.handshakeDone && !fixture.established, @"handshake done, waiting for HELLO");
    [fixture peerSends:SZFriendsEncodeFrame(SZFMessageFrame(@"skipping HELLO"), NULL)];
    SZF_CHECK(fixture.closed && fixture.error.code == SZFriendsSessionErrorProtocol && fixture.frames.count == 0 &&
                  !fixture.established,
              @"a frame before HELLO closes: %@", fixture.error);

    // HELLO twice.
    fixture = [SZFPeerFixture channelResponderWithPattern:SZFRIENDS_NOISE_XX payloads:nil];
    [fixture peerSends:SZFHello()];
    SZF_CHECK(fixture.established, @"XX goes live on HELLO");
    [fixture peerSends:SZFHello()];
    SZF_CHECK(fixture.closed && fixture.error.code == SZFriendsSessionErrorProtocol, @"second HELLO closes");

    // NN carries REQUEST_BY_ID once and nothing else.
    NSData *request = SZFPlaintext(SZFriendsFrameTypeRequestByID, @{
        @(SZFriendsFieldFriendsID) : [@"maple-river" dataUsingEncoding:NSUTF8StringEncoding],
        @(SZFriendsFieldToken) : SZFBytes(1, 16),
        @(SZFriendsFieldCallbackSecret) : SZFBytes(2, 32),
        @(SZFriendsFieldCertificate) : SZFBytes(3, 96),
        @(SZFriendsFieldStaticKey) : SZFBytes(4, 32),
        @(SZFriendsFieldSignature) : SZFBytes(5, 64),
    });
    fixture = [SZFPeerFixture channelResponderWithPattern:SZFRIENDS_NOISE_NN payloads:nil];
    [fixture peerSends:SZFHello()];
    [fixture peerSends:request];
    SZF_CHECK(fixture.frames.count == 1 && !fixture.closed, @"one REQUEST_BY_ID passes");
    [fixture peerSends:request];
    SZF_CHECK(fixture.closed && fixture.frames.count == 1, @"a second REQUEST_BY_ID closes");
    fixture = [SZFPeerFixture channelResponderWithPattern:SZFRIENDS_NOISE_NN payloads:nil];
    [fixture peerSends:SZFHello()];
    [fixture peerSends:SZFriendsEncodeFrame(SZFMessageFrame(@"chat over NN"), NULL)];
    SZF_CHECK(fixture.closed && fixture.frames.count == 0, @"NN refuses MSG");
    fixture = [SZFPeerFixture channelResponderWithPattern:SZFRIENDS_NOISE_IK payloads:nil];
    [fixture peerSends:SZFHello()];
    [fixture peerSends:request];
    SZF_CHECK(fixture.closed && fixture.frames.count == 0, @"IK refuses REQUEST_BY_ID");
}

static void SZFTestPayloadChecks(void) {
    // No common minor version: closed before any reply.
    NSData *newer = SZFHex(@"180002000519000200091a000400000000"); // minor 5...9, capabilities 0
    SZFPeerFixture *fixture = [SZFPeerFixture channelResponderWithPattern:SZFRIENDS_NOISE_NN
                                                                 payloads:^NSDictionary *(SZFriendsIdentity *peer) {
                                                                     (void)peer;
                                                                     return @{@0 : newer};
                                                                 }];
    SZF_CHECK(fixture.closed && fixture.error.code == SZFriendsSessionErrorHandshakeFailed &&
                  !fixture.peer.handshakeDone,
              @"minor 5...9 shares nothing with 0...0: %@", fixture.error);

    // IK message 1 with no payload at all, without a route class, with one outside the enum, and with None.
    NSArray<NSDictionary * (^)(SZFriendsIdentity *)> *bad = @[
        ^NSDictionary *(SZFriendsIdentity *peer) {
            (void)peer;
            return @{};
        },
        ^NSDictionary *(SZFriendsIdentity *peer) {
            return @{@0 : SZFPeerPayload(peer, -1, nil)};
        },
        ^NSDictionary *(SZFriendsIdentity *peer) {
            return @{@0 : SZFPeerPayload(peer, 9, nil)};
        },
        ^NSDictionary *(SZFriendsIdentity *peer) {
            return @{@0 : SZFPeerPayload(peer, SZFriendsRouteMethodNone, nil)};
        },
    ];
    for (NSDictionary * (^payloads)(SZFriendsIdentity *) in bad) {
        fixture = [SZFPeerFixture channelResponderWithPattern:SZFRIENDS_NOISE_IK payloads:payloads];
        SZF_CHECK(fixture.closed && fixture.error.code == SZFriendsSessionErrorHandshakeFailed &&
                      !fixture.peer.handshakeDone,
                  @"IK message 1 payload refused: %@", fixture.error);
    }

    // The responder's message 2 without a certificate.
    SZFPeerFixture *noCert = [SZFPeerFixture channelInitiatorWithResponderPayload:SZFPeerPayload(nil, -1, nil)];
    SZF_CHECK(noCert.closed && noCert.error.code == SZFriendsSessionErrorHandshakeFailed && !noCert.established,
              @"IK message 2 must carry the certificate: %@", noCert.error);
}

void SZFRunScriptedPeerTests(void) {
    SZFTestRekeyBoundaryInClear();
    SZFTestUnknownTypeAndTag();
    SZFTestTransportViolations();
    SZFTestCoalescedDeliveries();
    SZFTestResponderRules();
    SZFTestCodeFramesFromInitiator();
    SZFTestPayloadChecks();
}
