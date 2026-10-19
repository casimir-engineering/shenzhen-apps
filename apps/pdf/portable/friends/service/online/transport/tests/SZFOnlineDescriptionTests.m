// Session descriptions, ICE server URLs and the pre-authentication rule as -openConnection: sees it. Refused
// requests never create a peer connection.

#import "SZFOnlineTestSupport.h"

static NSString *const kFingerprint = @"0A:1B:2C:3D:4E:5F:60:71:82:93:A4:B5:C6:D7:E8:F9:0A:1B:2C:3D:4E:5F:60:71:82:93:"
                                      @"A4:B5:C6:D7:E8:F9";

static NSString *Offer(NSString *extra) {
    NSArray<NSString *> *lines = @[
        @"v=0", @"o=rtc 4107 0 IN IP4 127.0.0.1", @"s=-", @"t=0 0", @"a=group:BUNDLE 0", @"a=setup:actpass",
        @"a=ice-ufrag:abcd", @"a=ice-pwd:0123456789abcdefghijklmn", @"a=ice-options:ice2,trickle",
        [@"a=fingerprint:sha-256 " stringByAppendingString:kFingerprint],
        @"m=application 9 UDP/DTLS/SCTP webrtc-datachannel", @"c=IN IP4 0.0.0.0", @"a=mid:0", @"a=sendrecv",
        @"a=sctp-port:5000", @"a=max-message-size:65536",
        @"a=candidate:1 1 UDP 2122317823 192.168.1.10 54321 typ host", @"a=end-of-candidates", extra
    ];
    return [lines componentsJoinedByString:@"\r\n"];
}

static NSInteger ErrorCode(NSString *sdp) {
    NSError *error = nil;
    SZFriendsOnlineDescription *description = [SZFriendsOnlineDescription descriptionWithSDP:sdp error:&error];
    if (description != nil) return 0;
    SZFO_CHECK([error.domain isEqualToString:SZFriendsOnlineErrorDomain]);
    return error.code;
}

static void TestDescriptions(void) {
    SZFriendsOnlineDescription *offer = [SZFriendsOnlineDescription descriptionWithSDP:Offer(@"") error:NULL];
    SZFO_CHECK(offer != nil);
    SZFO_CHECK([offer.fingerprint isEqualToData:SZFriendsOnlineFingerprintFromHex(kFingerprint)]);
    SZFO_CHECK(offer.fingerprint.length == SZFriendsOnlineFingerprintLength && [offer.mid isEqualToString:@"0"]);
    SZFO_CHECK(offer.candidates.count == 1 && [offer.candidates[0] hasPrefix:@"candidate:1 1 UDP"],
               "candidates leave the SDP to pass the candidate rules");
    SZFO_CHECK(![offer.sdp containsString:@"candidate"] && [offer.sdp hasSuffix:@"\r\n"]);
    SZFO_CHECK(ErrorCode([Offer(@"") stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]) == 0, "LF too");

    NSString *swapped = [kFingerprint stringByReplacingOccurrencesOfString:@"0A" withString:@"0B"];
    NSString *other = [@"a=fingerprint:sha-256 " stringByAppendingString:swapped];
    SZFO_CHECK(ErrorCode(Offer(other)) == SZFriendsOnlineErrorFingerprintMismatch, "two fingerprints, one swapped");
    SZFO_CHECK(ErrorCode(Offer([@"a=fingerprint:sha-256 " stringByAppendingString:kFingerprint])) == 0, "a repeat");
    SZFO_CHECK(ErrorCode(Offer(@"a=fingerprint:sha-1 0A:1B:2C:3D:4E:5F:60:71:82:93:A4:B5:C6:D7:E8:F9:0A:1B:2C:3D")) ==
               SZFriendsOnlineErrorFingerprintMismatch, "another algorithm could be checked instead");
    NSString *none = [Offer(@"") stringByReplacingOccurrencesOfString:@"a=fingerprint:" withString:@"a=fingerprinx:"];
    SZFO_CHECK(ErrorCode(none) == SZFriendsOnlineErrorFingerprintMismatch, "nothing to check DTLS against");

    const NSInteger invalid = SZFriendsOnlineErrorDescriptionInvalid;
    SZFO_CHECK(ErrorCode(Offer(@"m=audio 9 UDP/TLS/RTP/SAVPF 111")) == invalid, "media");
    SZFO_CHECK(ErrorCode(Offer(@"m=application 9 UDP/DTLS/SCTP webrtc-datachannel")) == invalid, "two sections");
    SZFO_CHECK(ErrorCode([Offer(@"") stringByReplacingOccurrencesOfString:@"a=ice-pwd" withString:@"a=ice-pwx"]) ==
               invalid);
    SZFO_CHECK(ErrorCode([Offer(@"") stringByReplacingOccurrencesOfString:@"v=0" withString:@"v=1"]) == invalid);
    SZFO_CHECK(ErrorCode([Offer(@"") stringByReplacingOccurrencesOfString:@"a=mid:0" withString:@"a=mix:0"]) ==
               invalid);
    SZFO_CHECK(ErrorCode(Offer(@"a=x:\u00e9")) == invalid && ErrorCode(Offer(@"a=x:\x01")) == invalid);
    SZFO_CHECK(ErrorCode(Offer([@"a=x:" stringByPaddingToLength:4000 withString:@"y" startingAtIndex:0])) == invalid,
               "over SZFriendsOnlineSignalPayloadMax");
    SZFO_CHECK(ErrorCode(@"") == invalid);

    SZFO_CHECK(SZFriendsOnlineFingerprintFromHex([kFingerprint lowercaseString]) != nil);
    SZFO_CHECK(SZFriendsOnlineFingerprintFromHex([kFingerprint substringFromIndex:3]) == nil);
    SZFO_CHECK(SZFriendsOnlineFingerprintFromHex([kFingerprint stringByReplacingOccurrencesOfString:@"0A"
                                                                                         withString:@"0G"]) == nil);
}

static void TestServerURLs(void) {
    for (NSString *uri in @[ @"stun:host.test:3478", @"stun:127.0.0.1:3478", @"stun:[::1]:3478", @"stun:host.test" ]) {
        SZFO_CHECK(SZFriendsOnlineSTUNURIIsValid(uri), "%@", uri);
    }
    for (NSString *uri in @[ @"stun:user@host.test", @"turn:host.test:3478", @"stun:host.test:99999",
                             @"stun:host.test:3478?transport=udp", @"stun:", @"stun:host test" ]) {
        SZFO_CHECK(!SZFriendsOnlineSTUNURIIsValid(uri), "%@", uri);
    }
    SZFORelayCredentials *relay = [SZFORelayCredentials new];
    relay.turnURI = @"turn:host.test:3478?transport=udp";
    relay.username = @"1760400000:Ab-_x";
    relay.credential = @"a+b/c=";
    relay.expires = [NSDate dateWithTimeIntervalSinceNow:300];
    NSString *url = SZFriendsOnlineTURNServerURL(relay, [NSDate date], NULL);
    SZFO_CHECK([url isEqualToString:@"turn:1760400000%3AAb-_x:a%2Bb%2Fc%3D@host.test:3478?transport=udp"],
               "the username's colon must not end it: %@", url);
    NSError *error = nil;
    relay.expires = [NSDate dateWithTimeIntervalSinceNow:-1];
    SZFO_CHECK(SZFriendsOnlineTURNServerURL(relay, [NSDate date], &error) == nil &&
               error.code == SZFriendsOnlineErrorNotAuthorized, "expired");
    relay.expires = [NSDate dateWithTimeIntervalSinceNow:300];
    for (NSString *uri in @[ @"turns:host.test:5349", @"turn:host.test:3478?transport=tcp", @"turn:u:p@host.test",
                             @"stun:host.test:3478" ]) {
        relay.turnURI = uri;
        SZFO_CHECK(SZFriendsOnlineTURNServerURL(relay, [NSDate date], NULL) == nil, "UDP relays only: %@", uri);
    }
}

static NSInteger OpenError(SZFriendsOnlineDataChannelTransport *transport, SZFORequest *request) {
    dispatch_queue_t queue = dispatch_queue_create("szfo.gating", DISPATCH_QUEUE_SERIAL);
    __block NSError *error = nil;
    __block id<SZFriendsOnlineConnection> connection = nil;
    SZFORecorder *recorder = [SZFORecorder new];
    dispatch_sync(queue, ^{
        connection = [transport openConnection:request delegate:recorder queue:queue error:&error];
        [connection close];
    });
    return connection != nil ? 0 : error.code;
}

static void TestGating(SZFriendsOnlineDataChannelTransport *transport) {
    const NSInteger refused = SZFriendsOnlineErrorNotAuthorized;
    SZFORequest *request = [SZFORequest offererForPurpose:SZFriendsOnlinePurposeFriend];
    request.purpose = 0;
    SZFO_CHECK(OpenError(transport, request) == refused, "unknown purpose");
    request = [SZFORequest offererForPurpose:SZFriendsOnlinePurposeFriend];
    request.role = 0;
    SZFO_CHECK(OpenError(transport, request) == refused, "unknown role");
    request = [SZFORequest offererForPurpose:SZFriendsOnlinePurposeFriend];
    request.kind = 7;
    SZFO_CHECK(OpenError(transport, request) == refused, "unknown kind");
    request = [SZFORequest offererForPurpose:SZFriendsOnlinePurposeFriend];
    request.peer = SZFOBytes(1, 16);
    SZFO_CHECK(OpenError(transport, request) == refused, "a friend is a 32-byte identity key");
    request = [SZFORequest offererForPurpose:SZFriendsOnlinePurposeLink];
    request.peer = SZFOBytes(1, 32);
    SZFO_CHECK(OpenError(transport, request) == refused, "a link is a 16-byte link id");

    request = [SZFORequest offererForPurpose:SZFriendsOnlinePurposeFriend];
    request.role = SZFriendsOnlineRoleAnswerer;
    SZFO_CHECK(OpenError(transport, request) == refused, "an answerer without the authenticated offer");
    request.remoteOfferSDP = Offer(@"");
    request.remoteFingerprint = SZFOBytes(1, 31);
    SZFO_CHECK(OpenError(transport, request) == refused, "nor its fingerprint");
    request.remoteFingerprint = SZFOBytes(1, 32);
    SZFO_CHECK(OpenError(transport, request) == SZFriendsOnlineErrorFingerprintMismatch,
               "an offer whose SDP names another certificate than the signalling");
    request.remoteFingerprint = SZFriendsOnlineFingerprintFromHex(kFingerprint);
    request.remoteOfferSDP = @"v=0\r\n";
    SZFO_CHECK(OpenError(transport, request) == SZFriendsOnlineErrorDescriptionInvalid);
    request = [SZFORequest offererForPurpose:SZFriendsOnlinePurposeFriend];
    request.remoteOfferSDP = Offer(@"");
    SZFO_CHECK(OpenError(transport, request) == refused, "an offerer applies nothing remote before the answer");

    SZFORelayCredentials *relay = [SZFORelayCredentials new];
    relay.turnURI = @"turn:127.0.0.1:3478?transport=udp";
    relay.username = @"1:a";
    relay.credential = @"b";
    relay.expires = [NSDate dateWithTimeIntervalSinceNow:300];
    request = [SZFORequest offererForPurpose:SZFriendsOnlinePurposeFriend];
    request.kind = SZFriendsOnlineConnectionRelay;
    SZFO_CHECK(OpenError(transport, request) == refused, "a relay without credentials");
    request.kind = SZFriendsOnlineConnectionDirect;
    request.relay = relay;
    SZFO_CHECK(OpenError(transport, request) == refused, "credentials on a direct connection");
    request.kind = SZFriendsOnlineConnectionRelay;
    relay.expires = [NSDate dateWithTimeIntervalSinceNow:-5];
    SZFO_CHECK(OpenError(transport, request) == refused, "expired credentials");
    relay.expires = [NSDate dateWithTimeIntervalSinceNow:300];
    request.stunURI = @"stun:127.0.0.1:3478";
    SZFO_CHECK(OpenError(transport, request) == refused, "a relay connection gathers relay candidates only");

    request = [SZFORequest offererForPurpose:SZFriendsOnlinePurposeFriend];
    request.kind = SZFriendsOnlineConnectionProbeHandover;
    SZFO_CHECK(OpenError(transport, request) == refused, "a probe handover without the prober's port");
    request = [SZFORequest offererForPurpose:SZFriendsOnlinePurposeFriend];
    request.stunURI = @"stun:someone@stun.example:3478";
    SZFO_CHECK(OpenError(transport, request) == refused, "STUN URI");
    request.stunURI = @"stun:127.0.0.1:3478";
    SZFO_CHECK(OpenError(transport, request) == 0, "a well-formed friend's offerer opens");
}

void SZFORunDescriptionTests(void) {
    TestDescriptions();
    TestServerURLs();
}

void SZFORunGatingTests(void) {
    TestGating([[SZFriendsOnlineDataChannelTransport alloc] initForTestingWithBindAddress:@"127.0.0.1"]);
}
