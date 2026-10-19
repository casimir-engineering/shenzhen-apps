// Time and volume limits on live channels: the handshake timeout, the 24-hour session maximum (by clock and by
// timer), rekey after the byte threshold and after the interval, and the production defaults.

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

#import "service/session/SZFriendsSecureChannelInternal.h"

static SZFChannelPair *SZFIKPair(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    return [SZFChannelPair pairWithOptions:SZFOptions(SZFriendsHandshakeIK, bob)
                         initiatorIdentity:alice
                         responderIdentity:bob
                             publicProfile:nil
                                    policy:nil];
}

static void SZFTestDefaults(void) {
    SZF_CHECK(SZFriendsRekeyAfterBytes == 1ull << 30 && SZFriendsRekeyAfterInterval == 900 &&
                  SZFriendsSessionMaxAge == 86400 && SZFriendsHandshakeTimeout == 10,
              @"ADR 0001 limits");
    SZF_CHECK(SZFriendsNoiseMessageMax == 65535 && SZFriendsFramePlaintextMax == 65519 &&
                  SZFriendsFrameTextMax == 32768 && SZFriendsFramePictureMax == 49152,
              @"wire limits");
    SZF_CHECK(SZFriendsChunkBytesForRoute(SZFriendsRouteMethodBluetooth) == 4096 &&
                  SZFriendsChunkBytesForRoute(SZFriendsRouteMethodLAN) == 61440 &&
                  SZFriendsSendWindowForRoute(SZFriendsRouteMethodBluetooth) == 256 * 1024 &&
                  SZFriendsSendWindowForRoute(SZFriendsRouteMethodPeerToPeerWiFi) == 8 * 1024 * 1024,
              @"chunk sizes and windows per route");
    SZFChannelPair *pair = SZFIKPair();
    SZFOnQueue(pair.queue, ^{
        SZFriendsSecureChannel *channel = pair.initiator;
        SZF_CHECK(channel->_rekeyAfterBytes == SZFriendsRekeyAfterBytes &&
                      channel->_rekeyAfterInterval == SZFriendsRekeyAfterInterval &&
                      channel->_maxAge == SZFriendsSessionMaxAge &&
                      channel->_handshakeTimeout == SZFriendsHandshakeTimeout,
                  @"channels start from the header's constants");
    });
}

static void SZFTestHandshakeTimeout(void) {
    // A responder whose peer opens the link and says nothing.
    dispatch_queue_t queue = dispatch_queue_create("szfriends.session.timeout", DISPATCH_QUEUE_SERIAL);
    NSArray<SZFMemoryStream *> *streams = [SZFMemoryStream pair];
    __block NSError *closeError = nil;
    __block BOOL closed = NO;
    SZFriendsSecureChannel *responder =
        [[SZFriendsSecureChannel alloc] initAsResponderWithStream:streams[1]
                                                         identity:[SZFriendsIdentity szf_newIdentity]
                                                    publicProfile:nil
                                                        keyPolicy:^BOOL(NSData *k, SZFriendsHandshakePattern p,
                                                                        NSData *t) {
                                                            (void)k, (void)p, (void)t;
                                                            return YES;
                                                        }
                                                            queue:queue];
    responder.onClose = ^(NSError *error) {
        closed = YES;
        closeError = error;
    };
    SZFOnQueue(queue, ^{
        [responder setHandshakeTimeout:0.2];
        [streams[0] startWithQueue:queue];
        [responder start];
        [streams[0] writeData:[NSData dataWithBytes:"SZ" length:2] completion:nil]; // half a preamble, then nothing
    });
    SZF_CHECK(SZFWaitUntil(queue, 3,
                           ^BOOL {
                               return closed;
                           }),
              @"a silent peer is dropped");
    SZF_CHECK(closeError.code == SZFriendsSessionErrorTimedOut, @"timed out, got %@", closeError);
}

static void SZFTestMaxAge(void) {
    // By clock: the first send after 24 hours closes with CLOSE(expired) instead of sending.
    SZFChannelPair *pair = SZFIKPair();
    __block NSTimeInterval now = 1000;
    NSTimeInterval (^clock)(void) = ^NSTimeInterval {
        return now;
    };
    // Only the initiator's clock moves, so the responder hears the CLOSE rather than expiring on its own.
    [pair.initiator setClock:clock];
    [pair start];
    SZF_CHECK([pair waitUntilBothEstablished], @"established");
    SZFOnQueue(pair.queue, ^{
        now += SZFriendsSessionMaxAge - 1;
        [pair.initiator sendFrame:SZFMessageFrame(@"just in time")];
    });
    SZF_CHECK(SZFWaitUntil(pair.queue, 5,
                           ^BOOL {
                               return pair.responderFrames.count == 1;
                           }),
              @"a day minus a second still sends");
    SZFOnQueue(pair.queue, ^{
        now += 1;
        [pair.initiator sendFrame:SZFMessageFrame(@"too late")];
    });
    SZF_CHECK([pair waitUntilBothClosed], @"an old session closes");
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK(pair.responderFrames.count == 1, @"nothing sent past the maximum age");
        SZF_CHECK(pair.initiatorError.code == SZFriendsSessionErrorExpired, @"expired: %@", pair.initiatorError);
        SZF_CHECK([pair.responderError.userInfo[SZFriendsSessionCloseReasonKey] integerValue] ==
                      SZFriendsCloseReasonExpired,
                  @"the peer learns why, so both redial");
    });

    // By timer: an idle session still closes.
    SZFChannelPair *idle = SZFIKPair();
    [idle.initiator setMaxAge:0.3];
    [idle start];
    SZF_CHECK([idle waitUntilBothEstablished], @"established");
    SZF_CHECK([idle waitUntilBothClosed], @"the age timer closes an idle session");
    SZF_CHECK(idle.initiatorError.code == SZFriendsSessionErrorExpired, @"expired by timer: %@", idle.initiatorError);
}

static void SZFTestRekeyByBytesAndTime(void) {
    SZFChannelPair *pair = SZFIKPair();
    __block NSTimeInterval now = 50;
    NSTimeInterval (^clock)(void) = ^NSTimeInterval {
        return now;
    };
    [pair.initiator setClock:clock];
    [pair.responder setClock:clock];
    [pair.initiator setRekeyAfterBytes:2000 interval:SZFriendsRekeyAfterInterval];
    [pair start];
    SZF_CHECK([pair waitUntilBothEstablished], @"established");
    NSString *text = [@"" stringByPaddingToLength:500 withString:@"r" startingAtIndex:0];
    SZFOnQueue(pair.queue, ^{
        for (int i = 0; i < 20; i++) {
            [pair.initiator sendFrame:SZFMessageFrame(text)];
        }
    });
    SZF_CHECK(SZFWaitUntil(pair.queue, 5,
                           ^BOOL {
                               return pair.responderFrames.count == 20;
                           }),
              @"every frame decrypts across rekeys");
    SZFOnQueue(pair.queue, ^{
        // HELLO (1 byte), then 534-byte frames: the count passes 2,000 after the 4th frame (2,137), so REKEY goes
        // before frames 5, 9, 13 and 17, each time 4 x 534 = 2,136 bytes after the last.
        SZF_CHECK(pair.initiator.rekeysSent == 4 && pair.responder.rekeysReceived == 4, @"rekeys sent %lu received %lu",
                  (unsigned long)pair.initiator.rekeysSent, (unsigned long)pair.responder.rekeysReceived);
        SZF_CHECK(pair.responder.rekeysSent == 0, @"each direction rekeys on its own");
        now += SZFriendsRekeyAfterInterval;
        [pair.responder sendFrame:SZFMessageFrame(@"fifteen minutes later")];
    });
    SZF_CHECK(SZFWaitUntil(pair.queue, 5,
                           ^BOOL {
                               return pair.initiatorFrames.count == 1;
                           }),
              @"the responder's frame arrives");
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK(pair.responder.rekeysSent == 1 && pair.initiator.rekeysReceived == 1,
                  @"15 minutes since the last rekey forces one");
    });
}

void SZFRunChannelLifetimeTests(void) {
    SZFTestDefaults();
    SZFTestHandshakeTimeout();
    SZFTestMaxAge();
    SZFTestRekeyByBytesAndTime();
}
