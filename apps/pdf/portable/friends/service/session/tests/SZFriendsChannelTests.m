// Secure channels end to end over memory streams: XX, IK and NN round trips, what each side learns, browse-only
// XX, frame priority, DONE ordering, graceful close and the send rules.

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

static NSDictionary<NSNumber *, NSData *> *SZFProfile(void) {
    return @{
        @(SZFriendsFieldName) : [@"Mei Lin" dataUsingEncoding:NSUTF8StringEncoding],
        @(SZFriendsFieldPictureSet) : [SZFriendsFrame fieldWithUInt64:1 tag:SZFriendsFieldPictureSet],
        @(SZFriendsFieldPictureIndex) : [SZFriendsFrame fieldWithUInt64:3 tag:SZFriendsFieldPictureIndex],
    };
}

static SZFriendsFrame *SZFFrame(SZFriendsFrameType type, NSDictionary *fields) {
    return [SZFriendsFrame frameWithType:type fields:fields];
}

static void SZFTestRoundTrip(SZFriendsHandshakePattern pattern) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *bob = [SZFriendsIdentity szf_newIdentity];
    SZFriendsHandshakeOptions *options = SZFOptions(pattern, bob);
    options.route = SZFriendsRouteMethodPeerToPeerWiFi;
    SZFChannelPair *pair = [SZFChannelPair pairWithOptions:options
                                         initiatorIdentity:alice
                                         responderIdentity:bob
                                             publicProfile:pattern == SZFriendsHandshakeXX ? SZFProfile() : nil
                                                    policy:nil];
    __block NSDictionary *seenProfile = nil;
    pair.initiator.onPublicProfile = ^BOOL(NSDictionary<NSNumber *, NSData *> *profile) {
        seenProfile = profile;
        return YES;
    };
    [pair start];
    SZF_CHECK([pair waitUntilBothEstablished], @"pattern %u establishes", pattern);
    SZFOnQueue(pair.queue, ^{
        SZFriendsSecureChannel *i = pair.initiator, *r = pair.responder;
        SZF_CHECK(i.handshakeHash.length == 64 && [i.handshakeHash isEqualToData:r.handshakeHash],
                  @"pattern %u: both sides share h", pattern);
        SZF_CHECK(i.isInitiator && !r.isInitiator && i.pattern == pattern && r.pattern == pattern, @"roles");
        SZF_CHECK(i.negotiatedMinor == SZFriendsSessionMinor && r.negotiatedMinor == SZFriendsSessionMinor,
                  @"both speak this build's minor");
        if (pattern == SZFriendsHandshakeNN) {
            SZF_CHECK(i.remoteIdentityKey == nil && r.remoteIdentityKey == nil && r.remoteStaticKey == nil,
                      @"NN reveals no identity");
            SZF_CHECK(r.initiatorRoute == SZFriendsRouteMethodNone, @"NN carries no route class");
        } else {
            SZF_CHECK([i.remoteIdentityKey isEqualToData:bob.publicKey], @"initiator learns the responder's key");
            SZF_CHECK([r.remoteIdentityKey isEqualToData:alice.publicKey], @"responder learns the initiator's key");
            SZF_CHECK([r.remoteStaticKey isEqualToData:alice.staticPublicKey], @"responder learns the static key");
            SZF_CHECK([pair.policyIdentityKey isEqualToData:alice.publicKey] && pair.policyCalls == 1,
                      @"the policy saw the initiator's identity once");
            SZF_CHECK(r.initiatorRoute == SZFriendsRouteMethodPeerToPeerWiFi, @"route class travels");
        }
        if (pattern == SZFriendsHandshakeXX) {
            SZF_CHECK([seenProfile isEqualToDictionary:SZFProfile()], @"public profile in message 2");
        }
    });

    __block BOOL sent = NO;
    SZFOnQueue(pair.queue, ^{
        if (pattern == SZFriendsHandshakeNN) {
            SZFriendsFrame *request = SZFriendsMakeRequestByIDFrame(alice, @"maple-river", SZFBytes(1, 16),
                                                                    SZFBytes(2, 32), pair.initiator.handshakeHash);
            sent = [pair.initiator sendFrame:request] &&
                   [pair.responder sendFrame:SZFFrame(SZFriendsFrameTypeReceived, @{})];
            SZF_CHECK(![pair.initiator sendFrame:SZFMessageFrame(@"hi")], @"NN refuses MSG");
            SZF_CHECK(![pair.responder sendFrame:request], @"REQUEST_BY_ID only from the initiator");
        } else {
            sent = [pair.initiator sendFrame:SZFMessageFrame(@"hello from alice")] &&
                   [pair.responder sendFrame:SZFMessageFrame(@"hello from bob")];
            SZF_CHECK(![pair.initiator sendFrame:SZFFrame(SZFriendsFrameTypeReceived, @{})],
                      @"RECEIVED only in NN");
        }
        SZF_CHECK(![pair.initiator sendFrame:SZFFrame(SZFriendsFrameTypePing, @{})], @"PING belongs to the channel");
    });
    SZF_CHECK(sent, @"pattern %u: frames accepted", pattern);
    SZF_CHECK(SZFWaitUntil(pair.queue, 5,
                           ^BOOL {
                               return pair.initiatorFrames.count == 1 && pair.responderFrames.count == 1;
                           }),
              @"pattern %u: one frame each way", pattern);
    SZFOnQueue(pair.queue, ^{
        if (pattern == SZFriendsHandshakeNN) {
            SZFriendsFrame *request = pair.responderFrames.firstObject;
            SZF_CHECK(request.type == SZFriendsFrameTypeRequestByID, @"request arrives");
            SZF_CHECK([SZFriendsVerifyRequestByIDFrame(request, pair.responder.handshakeHash)
                          isEqualToData:alice.publicKey],
                      @"the responder verifies the request against its own session and learns the requester");
            SZF_CHECK(pair.initiatorFrames.firstObject.type == SZFriendsFrameTypeReceived, @"reply arrives");
        } else {
            SZF_CHECK([[pair.responderFrames.firstObject stringForTag:SZFriendsFieldText]
                          isEqualToString:@"hello from alice"],
                      @"message to the responder");
            SZF_CHECK([[pair.initiatorFrames.firstObject stringForTag:SZFriendsFieldText]
                          isEqualToString:@"hello from bob"],
                      @"message to the initiator");
        }
        [pair.initiator close];
    });
    SZF_CHECK([pair waitUntilBothClosed], @"close reaches both sides");
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK(pair.initiatorError == nil, @"a deliberate close reports no error");
        SZF_CHECK(pair.responderError.code == SZFriendsSessionErrorPeerClosed &&
                      [pair.responderError.userInfo[SZFriendsSessionCloseReasonKey] integerValue] ==
                          SZFriendsCloseReasonNormal,
                  @"the peer sees CLOSE(normal), got %@", pair.responderError);
    });
}

static void SZFTestBrowseOnly(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *bob = [SZFriendsIdentity szf_newIdentity];
    SZFriendsHandshakeOptions *options = SZFOptions(SZFriendsHandshakeXX, nil);
    options.browseOnly = YES;
    SZFChannelPair *pair = [SZFChannelPair pairWithOptions:options
                                         initiatorIdentity:alice
                                         responderIdentity:bob
                                             publicProfile:SZFProfile()
                                                    policy:nil];
    __block NSDictionary *profile = nil;
    pair.initiator.onPublicProfile = ^BOOL(NSDictionary<NSNumber *, NSData *> *p) {
        profile = p;
        return NO;
    };
    [pair start];
    SZF_CHECK([pair waitUntilBothClosed], @"browsing ends both sides");
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK([profile[@(SZFriendsFieldName)] isEqualToData:[@"Mei Lin" dataUsingEncoding:NSUTF8StringEncoding]],
                  @"the browser saw the name");
        SZF_CHECK(pair.initiatorError == nil, @"browsing closes without an error");
        // Preamble, then message 1 (32-byte ephemeral, empty payload): nothing that identifies the browser.
        SZF_CHECK(pair.initiatorStream.transcript.length == 4 + 2 + 32, @"browser sent %lu bytes",
                  (unsigned long)pair.initiatorStream.transcript.length);
        SZF_CHECK(pair.policyCalls == 0 && pair.responder.remoteIdentityKey == nil, @"responder learned no one");
        SZF_CHECK(!pair.responderEstablished, @"no session");
    });

    // browseOnly without a handler also stops after message 2.
    SZFChannelPair *silent = [SZFChannelPair pairWithOptions:options
                                           initiatorIdentity:alice
                                           responderIdentity:bob
                                               publicProfile:SZFProfile()
                                                      policy:nil];
    [silent start];
    SZF_CHECK([silent waitUntilBothClosed] && silent.initiatorStream.transcript.length == 38,
              @"browseOnly without a handler reveals nothing");
}

// Many queued CHUNKs, then a MESSAGE: the message overtakes the chunks still queued, and DONE stays behind them.
static void SZFTestPriorityAndOrder(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *bob = [SZFriendsIdentity szf_newIdentity];
    SZFChannelPair *pair = [SZFChannelPair pairWithOptions:SZFOptions(SZFriendsHandshakeIK, bob)
                                         initiatorIdentity:alice
                                         responderIdentity:bob
                                             publicProfile:nil
                                                    policy:nil];
    pair.initiatorStream.preferredWriteSize = 1024; // a small in-flight budget, like an L2CAP link
    [pair start];
    SZF_CHECK([pair waitUntilBothEstablished], @"established");
    NSData *offerID = SZFBytes(0x77, 16);
    SZFOnQueue(pair.queue, ^{
        SZFriendsChunkSender *sender = [[SZFriendsChunkSender alloc] initWithOfferID:offerID
                                                                                size:40 * 4096
                                                                        resumeOffset:0
                                                                               route:SZFriendsRouteMethodBluetooth];
        uint64_t offset;
        NSUInteger length;
        while ([sender getNextChunkOffset:&offset length:&length]) {
            [pair.initiator sendFrame:[sender chunkFrameWithData:SZFBytes((uint8_t)(offset / 4096), length)]];
        }
        [pair.initiator sendFrame:SZFFrame(SZFriendsFrameTypeDone, @{@(SZFriendsFieldID) : offerID,
                                                                     @(SZFriendsFieldDigest) : SZFBytes(0, 32)})];
        [pair.initiator sendFrame:SZFMessageFrame(@"jump the queue")];
    });
    SZF_CHECK(SZFWaitUntil(pair.queue, 5,
                           ^BOOL {
                               return pair.responderFrames.count == 42;
                           }),
              @"every frame arrives");
    SZFOnQueue(pair.queue, ^{
        NSUInteger messageIndex = NSNotFound, doneIndex = NSNotFound, lastChunk = 0;
        for (NSUInteger index = 0; index < pair.responderFrames.count; index++) {
            SZFriendsFrameType type = pair.responderFrames[index].type;
            if (type == SZFriendsFrameTypeMessage) {
                messageIndex = index;
            } else if (type == SZFriendsFrameTypeDone) {
                doneIndex = index;
            } else if (type == SZFriendsFrameTypeChunk) {
                lastChunk = index;
            }
        }
        SZF_CHECK(messageIndex < 10, @"the message overtook queued chunks (arrived %lu of 42)",
                  (unsigned long)messageIndex);
        SZF_CHECK(doneIndex == 41 && doneIndex > lastChunk, @"DONE after the last chunk");
    });
}

static void SZFTestCloseFlushesControlFrames(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *bob = [SZFriendsIdentity szf_newIdentity];
    SZFChannelPair *pair = [SZFChannelPair pairWithOptions:SZFOptions(SZFriendsHandshakeIK, bob)
                                         initiatorIdentity:alice
                                         responderIdentity:bob
                                             publicProfile:nil
                                                    policy:nil];
    [pair start];
    SZF_CHECK([pair waitUntilBothEstablished], @"established");
    SZFOnQueue(pair.queue, ^{
        [pair.responder sendFrame:SZFFrame(SZFriendsFrameTypeAck, @{@(SZFriendsFieldID) : SZFBytes(5, 16)})];
        [pair.responder closeWithReason:SZFriendsCloseReasonSuperseded];
        SZF_CHECK(![pair.responder sendFrame:SZFMessageFrame(@"late")], @"nothing queues after close");
    });
    SZF_CHECK([pair waitUntilBothClosed], @"closed");
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK(pair.initiatorFrames.count == 1 && pair.initiatorFrames[0].type == SZFriendsFrameTypeAck,
                  @"the in-flight ACK went out before CLOSE");
        SZF_CHECK([pair.initiatorError.userInfo[SZFriendsSessionCloseReasonKey] integerValue] ==
                      SZFriendsCloseReasonSuperseded,
                  @"the loser says why");
    });
}

// REQUEST_BY_ID verifies only for the session it was signed in, only with every field intact, and only when the
// certificate binds the static key it carries.
static void SZFTestRequestByIDSignature(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *mallory = [SZFriendsIdentity szf_newIdentity];
    NSData *h = SZFRandomBytes(64), *token = SZFRandomBytes(16), *secret = SZFRandomBytes(32);
    SZFriendsFrame *request = SZFriendsMakeRequestByIDFrame(alice, @"maple-river", token, secret, h);
    SZF_CHECK(request && SZFriendsEncodeFrame(request, NULL), @"a valid frame");
    SZF_CHECK([SZFriendsVerifyRequestByIDFrame(request, h) isEqualToData:alice.publicKey], @"verifies");
    SZF_CHECK(SZFriendsVerifyRequestByIDFrame(request, SZFRandomBytes(64)) == nil, @"another session's hash");
    for (NSNumber *tag in @[ @(SZFriendsFieldFriendsID), @(SZFriendsFieldToken), @(SZFriendsFieldCallbackSecret),
                             @(SZFriendsFieldStaticKey), @(SZFriendsFieldSignature) ]) {
        NSMutableDictionary *fields = [request.fields mutableCopy];
        NSMutableData *value = [fields[tag] mutableCopy];
        ((uint8_t *)value.mutableBytes)[0] ^= 1;
        fields[tag] = value;
        SZF_CHECK(SZFriendsVerifyRequestByIDFrame(SZFFrame(SZFriendsFrameTypeRequestByID, fields), h) == nil,
                  @"field %@ cannot be swapped", tag);
    }
    NSMutableDictionary *borrowed = [request.fields mutableCopy];
    borrowed[@(SZFriendsFieldCertificate)] = mallory.staticCertificate;
    SZF_CHECK(SZFriendsVerifyRequestByIDFrame(SZFFrame(SZFriendsFrameTypeRequestByID, borrowed), h) == nil,
              @"a certificate for another static key");
    SZF_CHECK(SZFriendsMakeRequestByIDFrame(alice, @"", token, secret, h) == nil &&
                  SZFriendsMakeRequestByIDFrame(alice, @"maple-river", SZFRandomBytes(15), secret, h) == nil &&
                  SZFriendsMakeRequestByIDFrame(alice, @"maple-river", token, secret, SZFRandomBytes(32)) == nil,
              @"bad inputs build nothing");
}

void SZFRunChannelTests(void) {
    SZFTestRequestByIDSignature();
    SZFTestRoundTrip(SZFriendsHandshakeXX);
    SZFTestRoundTrip(SZFriendsHandshakeIK);
    SZFTestRoundTrip(SZFriendsHandshakeNN);
    SZFTestBrowseOnly();
    SZFTestPriorityAndOrder();
    SZFTestCloseFlushesControlFrames();
}
