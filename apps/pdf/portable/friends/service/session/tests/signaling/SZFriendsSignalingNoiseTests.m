// Noise signalling: IK between friends (the gating rule's authenticated offer and answer), NN for Add by ID online,
// and every way a responder must refuse message 1 in silence.

#import <Foundation/Foundation.h>

#import <sodium.h>

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSignalingTests.h"
#import "service/session/SZFriendsSignaling.h"
#import "service/session/szfriends_noise.h"

static NSArray *SZFSTOffer(void) {
    return @[
        [SZFriendsSignalItem descriptionWithConnection:0 kind:1 sdp:@"v=0\r\na=setup:actpass\r\n"
                                           fingerprint:SZFBytes(0xaa, 32)],
        [SZFriendsSignalItem natWithClass:SZFriendsSignalNATIndependent step:0],
    ];
}

static SZFriendsRemoteKeyPolicy SZFSTAllow(NSMutableArray *calls) {
    return ^BOOL(NSData *key, SZFriendsHandshakePattern pattern, NSData *token) {
        [calls addObject:@[ key ?: [NSNull null], @(pattern), token ?: [NSNull null] ]];
        return YES;
    };
}

static SZFriendsSignalingSession *SZFSTRespond(NSData *message, SZFriendsIdentity *identity, NSDate *now,
                                               SZFriendsReplayCache *cache, SZFriendsRemoteKeyPolicy policy,
                                               NSArray **items, NSError **error) {
    return [SZFriendsSignalingSession responderForMessage:message
                                                 identity:identity
                                                  allowed:@[ @(SZFriendsHandshakeIK), @(SZFriendsHandshakeNN) ]
                                              replayCache:cache
                                                keyPolicy:policy
                                                      now:now
                                                    items:items
                                                    error:error];
}

static SZFriendsReplayCache *SZFSTCache(void) {
    return [[SZFriendsReplayCache alloc] initWithCapacity:64 clock:nil];
}

static SZFriendsSignalingSession *SZFSTDial(SZFriendsIdentity *from, SZFriendsIdentity *to, NSData *token) {
    return [[SZFriendsSignalingSession alloc] initIKInitiatorWithIdentity:from
                                                          remoteStaticKey:to.staticPublicKey
                                                      expectedIdentityKey:to.publicKey
                                                             requestToken:token];
}

static void SZFSTIKRoundTrip(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    NSDate *now = [NSDate date];
    SZFriendsSignalingSession *caller = SZFSTDial(alice, bob, nil);
    caller.localAttestation = SZFBytes(0x33, 40);
    NSData *message1 = [caller openingMessageWithItems:SZFSTOffer() now:now error:NULL];
    SZF_CHECK(message1.length > 0 && message1.length <= SZFriendsSignalPayloadMax, @"no message 1");
    // Nothing readable in message 1 for the host: no SDP, no certificate, no identity key.
    NSData *sdp = [@"a=setup" dataUsingEncoding:NSUTF8StringEncoding];
    SZF_CHECK([message1 rangeOfData:sdp options:0 range:NSMakeRange(0, message1.length)].location == NSNotFound &&
                  [message1 rangeOfData:alice.publicKey options:0 range:NSMakeRange(0, message1.length)].location ==
                      NSNotFound,
              @"message 1 leaks to the host");

    NSMutableArray *calls = [NSMutableArray array];
    NSArray<SZFriendsSignalItem *> *items = nil;
    NSError *error = nil;
    SZFriendsSignalingSession *answerer = SZFSTRespond(message1, bob, now, SZFSTCache(), SZFSTAllow(calls), &items,
                                                       &error);
    SZF_CHECK(answerer != nil, @"responder refused: %@", error);
    SZF_CHECK(calls.count == 1 && [calls[0][0] isEqual:alice.publicKey], @"the policy saw %@", calls);
    SZF_CHECK([answerer.remoteIdentityKey isEqualToData:alice.publicKey] &&
                  [answerer.remoteStaticKey isEqualToData:alice.staticPublicKey] &&
                  [answerer.remoteAttestation isEqualToData:SZFBytes(0x33, 40)] && !answerer.established,
              @"the responder's view of the caller");
    SZF_CHECK(items.count == 2 && items[0].type == SZFriendsSignalItemDescription &&
                  [[items[0] dataForTag:SZFriendsSignalTagFingerprint] isEqualToData:SZFBytes(0xaa, 32)],
              @"the offer and fingerprint did not arrive");
    NSArray *answer = @[ [SZFriendsSignalItem descriptionWithConnection:0 kind:1 sdp:@"v=0\r\n"
                                                            fingerprint:SZFBytes(0xbb, 32)] ];
    NSData *message2 = [answerer replyWithItems:answer error:&error];
    SZF_CHECK(message2 && answerer.established, @"no message 2: %@", error);
    NSArray<SZFriendsSignalItem *> *reply = [caller readReply:message2 error:&error];
    SZF_CHECK(reply.count == 1 && caller.established && [caller.remoteIdentityKey isEqualToData:bob.publicKey],
              @"the caller did not authenticate the answerer: %@", error);
    SZF_CHECK([caller.handshakeHash isEqualToData:answerer.handshakeHash], @"handshake hashes differ");
    SZF_CHECK([[caller exportKeyWithLabel:@"probe"] isEqualToData:[answerer exportKeyWithLabel:@"probe"]] &&
                  ![[caller exportKeyWithLabel:@"probe"] isEqualToData:[caller exportKeyWithLabel:@"other"]],
              @"exported keys");

    // Trickled candidates, both ways, in order; a replayed or reordered payload kills the session.
    NSData *c1 = [caller sealItems:@[ [SZFriendsSignalItem candidateWithConnection:0 technique:1 line:@"candidate:a"] ]
                             error:NULL];
    NSData *c2 = [caller sealItems:@[ [SZFriendsSignalItem candidatesEndWithConnection:0] ] error:NULL];
    SZF_CHECK([[[answerer openPayload:c1 error:NULL].firstObject stringForTag:SZFriendsSignalTagCandidate]
                  isEqualToString:@"candidate:a"],
              @"candidate lost");
    NSData *back = [answerer sealItems:@[ [SZFriendsSignalItem endWithReason:SZFriendsSignalEndDone] ] error:NULL];
    SZF_CHECK([caller openPayload:back error:NULL].count == 1, @"answerer's payload lost");
    SZF_CHECK([answerer openPayload:c1 error:NULL] == nil, @"a replayed payload opened");
    SZF_CHECK([answerer openPayload:c2 error:NULL] == nil, @"a dead session opened a payload");
    // A payload too big fails without killing the session.
    NSArray *huge = @[ [SZFriendsSignalItem descriptionWithConnection:0 kind:1
                                                                   sdp:[@"" stringByPaddingToLength:3072
                                                                                         withString:@"a"
                                                                                    startingAtIndex:0]
                                                           fingerprint:SZFBytes(1, 32)],
                       [SZFriendsSignalItem frameItemWithData:SZFBytes(2, 1024)] ];
    SZF_CHECK([caller sealItems:huge error:NULL] == nil && [caller sealItems:SZFSTOffer() error:NULL] != nil,
              @"oversized items");
}

static void SZFSTIKRefusals(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *carol = [SZFriendsIdentity szf_newIdentity];
    NSDate *now = [NSDate date];
    NSMutableArray *calls = [NSMutableArray array];
    NSArray *items = nil;
    NSError *error = nil;
    NSData *message1 = [SZFSTDial(alice, bob, nil) openingMessageWithItems:SZFSTOffer() now:now error:NULL];

    SZF_CHECK(SZFSTRespond(message1, carol, now, SZFSTCache(), SZFSTAllow(calls), &items, &error) == nil &&
                  error.code == SZFriendsSessionErrorHandshakeFailed && calls.count == 0 && items == nil,
              @"a message sealed to bob opened at carol");
    SZFriendsReplayCache *cache = SZFSTCache();
    SZF_CHECK(SZFSTRespond(message1, bob, now, cache, SZFSTAllow(calls), &items, NULL) != nil, @"first delivery");
    SZF_CHECK(SZFSTRespond(message1, bob, now, cache, SZFSTAllow(calls), &items, &error) == nil &&
                  error.code == SZFriendsSessionErrorReplayed && items == nil && cache.count == 1,
              @"a replayed message 1 was accepted");
    SZF_CHECK(SZFSTRespond(message1, bob, [now dateByAddingTimeInterval:301], SZFSTCache(), SZFSTAllow(calls), &items,
                           &error) == nil &&
                  SZFSTRespond(message1, bob, [now dateByAddingTimeInterval:-301], SZFSTCache(), SZFSTAllow(calls),
                               &items, NULL) == nil,
              @"a message 1 outside the clock window was accepted");
    SZF_CHECK(SZFSTRespond(message1, bob, [now dateByAddingTimeInterval:250], SZFSTCache(), SZFSTAllow(calls), &items,
                           NULL) != nil,
              @"a message 1 within the clock window was refused");
    SZFriendsRemoteKeyPolicy refuse = ^BOOL(__unused NSData *key, __unused SZFriendsHandshakePattern pattern,
                                            __unused NSData *token) {
        return NO;
    };
    SZF_CHECK(SZFSTRespond(message1, bob, now, SZFSTCache(), refuse, &items, &error) == nil &&
                  error.code == SZFriendsSessionErrorRejected && items == nil,
              @"the policy's refusal was not final");
    SZF_CHECK([SZFriendsSignalingSession responderForMessage:message1
                                                    identity:bob
                                                     allowed:@[ @(SZFriendsHandshakeNN) ]
                                                 replayCache:SZFSTCache()
                                                   keyPolicy:SZFSTAllow(calls)
                                                         now:now
                                                       items:&items
                                                       error:&error] == nil &&
                  error.code == SZFriendsSessionErrorRejected,
              @"IK accepted where only NN is taken (Add by ID by Friends ID)");
    NSMutableData *tampered = [message1 mutableCopy];
    ((uint8_t *)tampered.mutableBytes)[tampered.length - 1] ^= 1;
    SZF_CHECK(SZFSTRespond(tampered, bob, now, SZFSTCache(), SZFSTAllow(calls), &items, NULL) == nil, @"tampered");
    NSMutableData *otherHeader = [message1 mutableCopy];
    ((uint8_t *)otherHeader.mutableBytes)[0] = 'X';
    SZF_CHECK(SZFSTRespond(otherHeader, bob, now, SZFSTCache(), SZFSTAllow(calls), &items, NULL) == nil, @"header");

    // An ADR 0001 IK message 1 (prologue "SZFriends session\0" || preamble) never opens as signalling.
    szfriends_handshake_state state;
    static const char sessionLabel[18] = "SZFriends session";
    NSMutableData *prologue = [NSMutableData dataWithBytes:sessionLabel length:sizeof sessionLabel];
    [prologue appendBytes:(uint8_t[]){'S', 'Z', 1, 1} length:4];
    NSData *alicePrivate = [alice staticPrivateKey];
    szfriends_handshake_init(&state, SZFRIENDS_NOISE_IK, 1, prologue.bytes, prologue.length, alicePrivate.bytes,
                             bob.staticPublicKey.bytes);
    NSData *payload = SZFriendsEncodeSignalItems(@[ [SZFriendsSignalItem itemWithType:SZFriendsSignalItemHello fields:@{
        @(SZFriendsSignalTagMinorMin) : SZFBytes(0, 2), @(SZFriendsSignalTagMinorMax) : SZFBytes(0, 2),
        @(SZFriendsSignalTagCertificate) : alice.staticCertificate,
        @(SZFriendsSignalTagTime) : SZFBytes(0, 8)}] ], 4000, NULL);
    NSMutableData *crossed = [NSMutableData dataWithBytes:(uint8_t[]){'S', SZFriendsHandshakeIK} length:2];
    NSMutableData *body = [NSMutableData dataWithLength:payload.length + 200];
    size_t written = 0;
    szfriends_handshake_write(&state, payload.bytes, payload.length, body.mutableBytes, body.length, &written);
    szfriends_handshake_clear(&state);
    [crossed appendBytes:body.bytes length:written];
    SZF_CHECK(SZFSTRespond(crossed, bob, [NSDate dateWithTimeIntervalSince1970:0], SZFSTCache(), SZFSTAllow(calls),
                           &items, &error) == nil &&
                  error.code == SZFriendsSessionErrorHandshakeFailed,
              @"a message under ADR 0001's prologue opened as signalling");

    // The caller checks message 2 names the identity it dialled.
    SZFriendsSignalingSession *wrongExpectation =
        [[SZFriendsSignalingSession alloc] initIKInitiatorWithIdentity:alice
                                                       remoteStaticKey:bob.staticPublicKey
                                                   expectedIdentityKey:carol.publicKey
                                                          requestToken:nil];
    NSData *dialled = [wrongExpectation openingMessageWithItems:@[] now:now error:NULL];
    SZFriendsSignalingSession *bobSide = SZFSTRespond(dialled, bob, now, SZFSTCache(), SZFSTAllow(calls), &items, NULL);
    NSData *reply = [bobSide replyWithItems:@[] error:NULL];
    SZF_CHECK(reply && [wrongExpectation readReply:reply error:&error] == nil && !wrongExpectation.established,
              @"an answer from another identity was accepted");
    SZF_CHECK([wrongExpectation sealItems:SZFSTOffer() error:NULL] == nil, @"a failed session still seals");

    // The holder's callback after Add by ID presents its token to the policy.
    [calls removeAllObjects];
    NSData *token = SZFBytes(0x7e, 16);
    NSData *callback = [SZFSTDial(alice, bob, token) openingMessageWithItems:@[] now:now error:NULL];
    SZFriendsSignalingSession *tokenSide = SZFSTRespond(callback, bob, now, SZFSTCache(), SZFSTAllow(calls), &items,
                                                        NULL);
    SZF_CHECK([tokenSide.presentedRequestToken isEqualToData:token] && [calls.firstObject[2] isEqual:token],
              @"the callback's token did not reach the policy");
    SZF_CHECK([[SZFriendsSignalingSession alloc] initIKInitiatorWithIdentity:alice
                                                             remoteStaticKey:bob.staticPublicKey
                                                         expectedIdentityKey:bob.publicKey
                                                                requestToken:SZFBytes(1, 15)] == nil,
              @"a 15-byte token accepted");
}

// 7b-C1: junk opens and refused callers never enter the cache, so they cannot evict a friend's message 1 and let a
// captured copy through again.
static void SZFSTReplayCacheFlood(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    NSDate *now = [NSDate date];
    NSMutableArray *calls = [NSMutableArray array];
    NSArray *items = nil;
    NSError *error = nil;
    SZFriendsReplayCache *cache = [[SZFriendsReplayCache alloc] initWithCapacity:2 clock:nil];
    NSData *message1 = [SZFSTDial(alice, bob, nil) openingMessageWithItems:SZFSTOffer() now:now error:NULL];
    SZF_CHECK(SZFSTRespond(message1, bob, now, cache, SZFSTAllow(calls), &items, NULL) != nil, @"first delivery");
    SZFriendsRemoteKeyPolicy refuse = ^BOOL(__unused NSData *key, __unused SZFriendsHandshakePattern pattern,
                                            __unused NSData *token) {
        return NO;
    };
    for (int i = 0; i < 8; i++) {
        NSMutableData *junk = [NSMutableData dataWithBytes:(uint8_t[]){'S', SZFriendsHandshakeIK} length:2];
        [junk appendData:SZFRandomBytes(64)];
        SZF_CHECK(SZFSTRespond(junk, bob, now, cache, SZFSTAllow(calls), &items, NULL) == nil, @"junk accepted");
        NSData *stranger = [SZFSTDial([SZFriendsIdentity szf_newIdentity], bob, nil) openingMessageWithItems:@[]
                                                                                                         now:now
                                                                                                       error:NULL];
        SZF_CHECK(SZFSTRespond(stranger, bob, now, cache, refuse, &items, NULL) == nil, @"refused caller accepted");
    }
    SZF_CHECK(cache.count == 1, @"refused opens entered the replay cache: %lu", (unsigned long)cache.count);
    SZF_CHECK(SZFSTRespond(message1, bob, now, cache, SZFSTAllow(calls), &items, &error) == nil &&
                  error.code == SZFriendsSessionErrorReplayed,
              @"a flood of junk let a replayed message 1 through");
}

void SZFRunSignalingIKTests(void) {
    SZFSTIKRoundTrip();
    SZFSTIKRefusals();
    SZFSTReplayCacheFlood();
}

void SZFRunSignalingNNTests(void) {
    SZFriendsIdentity *requester = [SZFriendsIdentity szf_newIdentity], *holder = [SZFriendsIdentity szf_newIdentity];
    NSDate *now = [NSDate date];
    SZFriendsSignalingSession *caller = [[SZFriendsSignalingSession alloc] initNNInitiator];
    SZF_CHECK([[[SZFriendsSignalingSession alloc] initNNInitiator] openingMessageWithItems:SZFSTOffer()
                                                                                       now:now
                                                                                     error:NULL] == nil,
              @"NN message 1 is plaintext and must carry no description");
    NSData *message1 = [caller openingMessageWithItems:@[] now:now error:NULL];
    NSMutableArray *calls = [NSMutableArray array];
    NSArray *items = nil;
    SZFriendsSignalingSession *answerer = SZFSTRespond(message1, holder, now, SZFSTCache(), SZFSTAllow(calls), &items,
                                                       NULL);
    SZF_CHECK(answerer && items.count == 0 && calls.count == 1 && calls[0][0] == [NSNull null] &&
                  [calls[0][1] isEqual:@(SZFriendsHandshakeNN)] && answerer.remoteIdentityKey == nil,
              @"NN responder: %@", calls);
    NSData *message2 = [answerer replyWithItems:@[] error:NULL];
    SZF_CHECK([caller readReply:message2 error:NULL] != nil && caller.established && caller.remoteIdentityKey == nil,
              @"NN did not complete");
    // A plaintext message 1 carrying more than its Hello, as a careless or hostile caller could send, is refused.
    NSDictionary *range = @{@(SZFriendsSignalTagMinorMin) : SZFBytes(0, 2),
                            @(SZFriendsSignalTagMinorMax) : SZFBytes(0, 2)};
    NSData *helloOnly = SZFriendsEncodeSignalItems(
        @[ [SZFriendsSignalItem itemWithType:SZFriendsSignalItemHello fields:range] ], 100, NULL);
    NSMutableData *stuffed = [NSMutableData dataWithBytes:(uint8_t[]){'S', SZFriendsHandshakeNN} length:2];
    [stuffed appendData:SZFRandomBytes(32)]; // NN message 1: the initiator's ephemeral key, then the plaintext
    [stuffed appendData:helloOnly];
    SZF_CHECK(SZFSTRespond(stuffed, holder, now, SZFSTCache(), SZFSTAllow(calls), &items, NULL) != nil,
              @"a hand-made NN message 1 with only its Hello was refused");
    [stuffed appendData:SZFriendsEncodeSignalItems(SZFSTOffer(), 1000, NULL)];
    [stuffed replaceBytesInRange:NSMakeRange(2, 32) withBytes:SZFRandomBytes(32).bytes];
    SZF_CHECK(SZFSTRespond(stuffed, holder, now, SZFSTCache(), SZFSTAllow(calls), &items, NULL) == nil,
              @"an NN message 1 carrying a description was accepted");
    // REQUEST_BY_ID rides as a Frame item, signed over this exchange's handshake hash (ADR 0004 step 1).
    SZFriendsFrame *request = SZFriendsMakeRequestByIDFrame(requester, @"maple-river", SZFBytes(1, 16), SZFBytes(2, 32),
                                                            caller.handshakeHash);
    NSData *encoded = SZFriendsEncodeFrame(request, NULL);
    NSData *sealed = [caller sealItems:@[ [SZFriendsSignalItem frameItemWithData:encoded] ] error:NULL];
    NSArray<SZFriendsSignalItem *> *opened = [answerer openPayload:sealed error:NULL];
    SZFriendsFrame *received = SZFriendsDecodeFrame([opened.firstObject dataForTag:SZFriendsSignalTagFrame], NULL);
    SZF_CHECK([SZFriendsVerifyRequestByIDFrame(received, answerer.handshakeHash) isEqualToData:requester.publicKey],
              @"REQUEST_BY_ID did not verify inside the exchange");
    SZF_CHECK(SZFriendsVerifyRequestByIDFrame(received, SZFBytes(0, 64)) == nil,
              @"REQUEST_BY_ID verified for another exchange");
}
