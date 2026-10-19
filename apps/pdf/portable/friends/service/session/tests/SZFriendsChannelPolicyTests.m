// Who may talk to a listener, checked before any reply or application frame: hidden listeners refuse XX, the key
// policy refuses unknown and blocked keys, Add by ID tokens reach the policy, and wrong keys or certificates fail
// the handshake on whichever side notices.

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

static SZFChannelPair *SZFRunPair(SZFriendsHandshakeOptions *options, SZFriendsIdentity *initiator,
                                  SZFriendsIdentity *responder, NSDictionary *profile,
                                  SZFriendsRemoteKeyPolicy policy) {
    SZFChannelPair *pair = [SZFChannelPair pairWithOptions:options
                                         initiatorIdentity:initiator
                                         responderIdentity:responder
                                             publicProfile:profile
                                                    policy:policy];
    [pair start];
    SZF_CHECK(SZFWaitUntil(pair.queue, 5,
                           ^BOOL {
                               return (pair.initiatorClosed && pair.responderClosed) ||
                                      (pair.initiatorEstablished && pair.responderEstablished);
                           }),
              @"pair settles");
    SZFDrain(pair.queue);
    return pair;
}

// The responder must have said nothing at all and delivered nothing.
static void SZFExpectSilentRefusal(SZFChannelPair *pair, SZFriendsSessionError responderCode, NSString *label) {
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK(pair.responderStream.transcript.length == 0, @"%@: responder wrote %lu bytes", label,
                  (unsigned long)pair.responderStream.transcript.length);
        SZF_CHECK(!pair.responderEstablished && pair.responderFrames.count == 0, @"%@: nothing went live", label);
        SZF_CHECK(pair.responderClosed && pair.responderError.code == responderCode, @"%@: responder error %@", label,
                  pair.responderError);
        SZF_CHECK(pair.initiatorClosed && pair.initiatorError.code == SZFriendsSessionErrorStreamClosed,
                  @"%@: initiator sees the link close, got %@", label, pair.initiatorError);
    });
}

static void SZFTestHiddenListenerRefusesXX(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFChannelPair *pair = SZFRunPair(SZFOptions(SZFriendsHandshakeXX, nil), alice, bob, nil, nil);
    SZFExpectSilentRefusal(pair, SZFriendsSessionErrorRejected, @"XX to a hidden listener");
    SZF_CHECK(pair.policyCalls == 0, @"the policy is not even asked");
}

static void SZFTestPolicyRefusals(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    NSData *blocked = alice.publicKey;
    SZFriendsRemoteKeyPolicy blockAlice = ^BOOL(NSData *key, SZFriendsHandshakePattern pattern, NSData *token) {
        (void)pattern;
        (void)token;
        return ![key isEqualToData:blocked];
    };
    SZFChannelPair *ik = SZFRunPair(SZFOptions(SZFriendsHandshakeIK, bob), alice, bob, nil, blockAlice);
    SZFExpectSilentRefusal(ik, SZFriendsSessionErrorRejected, @"IK from a blocked key");
    SZF_CHECK([ik.policyIdentityKey isEqualToData:alice.publicKey] && ik.policyToken == nil,
              @"the policy saw the verified identity and no token");

    // XX on a public entry: message 2 is public by design, but a blocked key never gets past message 3.
    SZFChannelPair *xx = SZFRunPair(SZFOptions(SZFriendsHandshakeXX, nil), alice, bob, @{}, blockAlice);
    SZFOnQueue(xx.queue, ^{
        SZF_CHECK(!xx.responderEstablished && xx.responderFrames.count == 0 && xx.policyCalls == 1,
                  @"XX from a blocked key never goes live");
        SZF_CHECK(xx.responderError.code == SZFriendsSessionErrorRejected, @"rejected, got %@", xx.responderError);
    });

    // NN: the policy is asked before the reply, so it can rate-limit Add by ID floods.
    SZFChannelPair *nn = SZFRunPair(SZFOptions(SZFriendsHandshakeNN, nil), alice, bob, nil,
                                    ^BOOL(NSData *key, SZFriendsHandshakePattern pattern, NSData *token) {
                                        return key == nil && token == nil && pattern == SZFriendsHandshakeNN && NO;
                                    });
    SZFExpectSilentRefusal(nn, SZFriendsSessionErrorRejected, @"NN refused by the policy");
}

static void SZFTestRequestToken(void) {
    SZFriendsIdentity *holder = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *requester = [SZFriendsIdentity szf_newIdentity];
    NSData *token = SZFRandomBytes(16);
    SZFriendsHandshakeOptions *options = SZFOptions(SZFriendsHandshakeIK, requester);
    options.requestToken = token;
    // The requester's listener accepts an unknown key only with a token it issued.
    SZFChannelPair *pair = SZFRunPair(options, holder, requester, nil,
                                      ^BOOL(NSData *key, SZFriendsHandshakePattern pattern, NSData *presented) {
                                          (void)key;
                                          return pattern == SZFriendsHandshakeIK && [presented isEqualToData:token];
                                      });
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK(pair.initiatorEstablished && pair.responderEstablished, @"callback with the token goes live");
        SZF_CHECK([pair.responder.presentedRequestToken isEqualToData:token], @"token exposed to the helper");
        SZF_CHECK([pair.policyToken isEqualToData:token], @"token reached the policy");
    });

    SZFriendsHandshakeOptions *wrong = SZFOptions(SZFriendsHandshakeIK, requester);
    wrong.requestToken = SZFRandomBytes(16);
    SZFChannelPair *refused = SZFRunPair(wrong, holder, requester, nil,
                                         ^BOOL(NSData *key, SZFriendsHandshakePattern pattern, NSData *presented) {
                                             (void)key;
                                             (void)pattern;
                                             return [presented isEqualToData:token];
                                         });
    SZFExpectSilentRefusal(refused, SZFriendsSessionErrorRejected, @"a token we never issued");

    // XX and IK must say which route they run over: the session race on both sides depends on it.
    SZFriendsHandshakeOptions *noRoute = SZFOptions(SZFriendsHandshakeIK, requester);
    noRoute.route = SZFriendsRouteMethodNone;
    SZFChannelPair *unrouted = SZFRunPair(noRoute, holder, requester, nil, nil);
    SZFOnQueue(unrouted.queue, ^{
        SZF_CHECK(unrouted.initiatorError.code == SZFriendsSessionErrorHandshakeFailed &&
                      unrouted.initiatorStream.transcript.length == 0,
                  @"IK without a route class never starts");
    });

    // A token only means something in IK; the initiator refuses to put one anywhere else.
    SZFriendsHandshakeOptions *xx = SZFOptions(SZFriendsHandshakeXX, nil);
    xx.requestToken = token;
    SZFChannelPair *misuse = SZFRunPair(xx, holder, requester, @{}, nil);
    SZFOnQueue(misuse.queue, ^{
        SZF_CHECK(misuse.initiatorError.code == SZFriendsSessionErrorHandshakeFailed &&
                      misuse.initiatorStream.transcript.length == 0,
                  @"XX with a token never starts");
    });
}

static void SZFTestWrongKeys(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *carol = [SZFriendsIdentity szf_newIdentity];

    // IK to the wrong static key: the responder cannot decrypt message 1 and answers nothing.
    SZFriendsHandshakeOptions *wrongStatic = SZFOptions(SZFriendsHandshakeIK, carol);
    SZFChannelPair *pair = SZFRunPair(wrongStatic, alice, bob, nil, nil);
    SZFExpectSilentRefusal(pair, SZFriendsSessionErrorHandshakeFailed, @"IK to another static key");
    SZF_CHECK(pair.policyCalls == 0, @"no policy question for a message that did not decrypt");

    // Right static, but the certificate names someone else: the initiator stops before HELLO.
    SZFriendsHandshakeOptions *expectCarol = SZFOptions(SZFriendsHandshakeIK, bob);
    expectCarol.expectedIdentityKey = carol.publicKey;
    SZFChannelPair *mismatch = SZFRunPair(expectCarol, alice, bob, nil, nil);
    SZFOnQueue(mismatch.queue, ^{
        SZF_CHECK(mismatch.initiatorError.code == SZFriendsSessionErrorHandshakeFailed, @"initiator refuses: %@",
                  mismatch.initiatorError);
        SZF_CHECK(!mismatch.responderEstablished && mismatch.responderFrames.count == 0,
                  @"the responder never goes live without HELLO");
    });

    // A responder presenting a certificate that does not bind its static key (copied from Carol).
    SZFriendsIdentity *impostor = [SZFriendsIdentity szf_newIdentity];
    [impostor szf_setCertificate:carol.staticCertificate];
    SZFriendsHandshakeOptions *toImpostor = SZFOptions(SZFriendsHandshakeIK, impostor);
    toImpostor.expectedIdentityKey = nil;
    SZFChannelPair *badCert = SZFRunPair(toImpostor, alice, impostor, nil, nil);
    SZFOnQueue(badCert.queue, ^{
        SZF_CHECK(badCert.initiatorError.code == SZFriendsSessionErrorHandshakeFailed && !badCert.responderEstablished,
                  @"unbound certificate refused, got %@", badCert.initiatorError);
    });

    // An initiator with an unbound certificate: the responder refuses before replying, without asking the policy.
    SZFriendsIdentity *badInitiator = [SZFriendsIdentity szf_newIdentity];
    [badInitiator szf_setCertificate:alice.staticCertificate];
    SZFChannelPair *badIK = SZFRunPair(SZFOptions(SZFriendsHandshakeIK, bob), badInitiator, bob, nil, nil);
    SZFExpectSilentRefusal(badIK, SZFriendsSessionErrorHandshakeFailed, @"IK with an unbound certificate");
    SZF_CHECK(badIK.policyCalls == 0, @"the policy never sees an unverified key");

    // Carol signs Bob's static key: the certificate verifies, but it names Carol, so IK expecting Bob fails.
    SZFriendsIdentity *claimsBob = [SZFriendsIdentity szf_newIdentity];
    [claimsBob szf_setCertificate:[carol szf_certificateForStaticKey:claimsBob.staticPublicKey]];
    SZFriendsHandshakeOptions *expectBob = SZFOptions(SZFriendsHandshakeIK, claimsBob);
    expectBob.expectedIdentityKey = bob.publicKey;
    SZFChannelPair *claimed = SZFRunPair(expectBob, alice, claimsBob, nil, nil);
    SZFOnQueue(claimed.queue, ^{
        SZF_CHECK(claimed.initiatorError.code == SZFriendsSessionErrorHandshakeFailed, @"identity is the cert's key");
    });
}

void SZFRunChannelPolicyTests(void) {
    SZFTestHiddenListenerRefusesXX();
    SZFTestPolicyRefusals();
    SZFTestRequestToken();
    SZFTestWrongKeys();
}
