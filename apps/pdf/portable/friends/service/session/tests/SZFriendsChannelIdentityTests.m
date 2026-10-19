// What a channel says about who is on the other end beyond the identity key: the certificate the peer presented
// (the helper's key-change path keeps a changed static key for review only with it) and the host-issued Friends ID
// attestation that travels beside the certificate, never in NN, and that the codec bounds in PROFILE too.

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

static void SZFTestCertificateAndAttestation(SZFriendsHandshakePattern pattern) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFChannelPair *pair = [SZFChannelPair pairWithOptions:SZFOptions(pattern, bob)
                                         initiatorIdentity:alice
                                         responderIdentity:bob
                                             publicProfile:pattern == SZFriendsHandshakeXX ? @{} : nil
                                                    policy:nil];
    NSData *aliceAttestation = SZFRandomBytes(SZFriendsAttestationMax), *bobAttestation = SZFRandomBytes(1);
    pair.initiator.localAttestation = aliceAttestation;
    pair.responder.localAttestation = bobAttestation;
    __block NSData *attestationAtProfile = nil;
    pair.initiator.onPublicProfile = ^BOOL(NSDictionary<NSNumber *, NSData *> *profile) {
        (void)profile;
        attestationAtProfile = pair.initiator.remoteAttestation;
        return YES;
    };
    [pair start];
    SZF_CHECK([pair waitUntilBothEstablished], @"pattern %u establishes", pattern);
    SZFOnQueue(pair.queue, ^{
        SZFriendsSecureChannel *i = pair.initiator, *r = pair.responder;
        if (pattern == SZFriendsHandshakeNN) {
            SZF_CHECK(i.remoteCertificate == nil && r.remoteCertificate == nil, @"NN presents no certificate");
            SZF_CHECK(i.remoteAttestation == nil && r.remoteAttestation == nil,
                      @"NN never carries an attestation: it would name the person");
            // NN message 1 travels in clear, so an attestation in it would be on the wire for anyone to read.
            NSData *wire = pair.initiatorStream.transcript;
            SZF_CHECK([wire rangeOfData:aliceAttestation options:0 range:NSMakeRange(0, wire.length)].location ==
                          NSNotFound,
                      @"nor does it reach the wire");
            return;
        }
        SZF_CHECK([r.remoteCertificate isEqualToData:alice.staticCertificate] &&
                      [i.remoteCertificate isEqualToData:bob.staticCertificate],
                  @"pattern %u: each side keeps the certificate the other presented", pattern);
        SZF_CHECK([r.remoteAttestation isEqualToData:aliceAttestation] &&
                      [i.remoteAttestation isEqualToData:bobAttestation],
                  @"pattern %u: attestations travel both ways, the largest allowed included", pattern);
        if (pattern == SZFriendsHandshakeXX) {
            SZF_CHECK([attestationAtProfile isEqualToData:bobAttestation], @"a browser sees it with the profile");
        }
    });
    SZFOnQueue(pair.queue, ^{
        [pair.initiator close];
    });
}

// A refused remote leaves nothing behind, and an attestation over the limit fails the handshake instead of being cut.
static void SZFTestAttestationLimits(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFChannelPair *refused = [SZFChannelPair pairWithOptions:SZFOptions(SZFriendsHandshakeIK, bob)
                                            initiatorIdentity:alice
                                            responderIdentity:bob
                                                publicProfile:nil
                                                       policy:^BOOL(NSData *k, SZFriendsHandshakePattern p, NSData *t) {
                                                           (void)k, (void)p, (void)t;
                                                           return NO;
                                                       }];
    refused.initiator.localAttestation = SZFRandomBytes(40);
    [refused start];
    SZF_CHECK([refused waitUntilBothClosed], @"refused");
    SZFOnQueue(refused.queue, ^{
        SZF_CHECK(refused.responder.remoteCertificate == nil && refused.responder.remoteAttestation == nil &&
                      refused.responder.remoteIdentityKey == nil,
                  @"a refused remote is not adopted");
    });

    SZFChannelPair *tooLong = [SZFChannelPair pairWithOptions:SZFOptions(SZFriendsHandshakeIK, bob)
                                            initiatorIdentity:alice
                                            responderIdentity:bob
                                                publicProfile:nil
                                                       policy:nil];
    tooLong.initiator.localAttestation = SZFRandomBytes(SZFriendsAttestationMax + 1);
    [tooLong start];
    SZF_CHECK(SZFWaitUntil(tooLong.queue, 5,
                           ^BOOL {
                               return tooLong.initiatorClosed;
                           }),
              @"an oversized attestation ends the attempt");
    SZFOnQueue(tooLong.queue, ^{
        SZF_CHECK(tooLong.initiatorError.code == SZFriendsSessionErrorFrameInvalid && tooLong.policyCalls == 0,
                  @"before anything is sent: %@", tooLong.initiatorError);
        SZF_CHECK(tooLong.initiatorStream.transcript.length == 0, @"nothing written");
    });

    // PROFILE carries it too, within the same bound.
    NSData *attestation = SZFRandomBytes(SZFriendsAttestationMax);
    SZFriendsFrame *profile = [SZFriendsFrame frameWithType:SZFriendsFrameTypeProfile
                                                     fields:@{@(SZFriendsFieldAttestation) : attestation}];
    NSData *encoded = SZFriendsEncodeFrame(profile, NULL);
    SZF_CHECK([[SZFriendsDecodeFrame(encoded, NULL) dataForTag:SZFriendsFieldAttestation] isEqualToData:attestation],
              @"PROFILE round-trips an attestation");
    SZFriendsFrame *oversized =
        [SZFriendsFrame frameWithType:SZFriendsFrameTypeProfile
                               fields:@{@(SZFriendsFieldAttestation) : SZFRandomBytes(SZFriendsAttestationMax + 1)}];
    SZF_CHECK(SZFriendsEncodeFrame(oversized, NULL) == nil, @"the encoder refuses one over the bound");
    NSMutableData *raw = [NSMutableData dataWithBytes:(uint8_t[]){SZFriendsFrameTypeProfile, SZFriendsFieldAttestation,
                                                                  (SZFriendsAttestationMax + 1) >> 8,
                                                                  (SZFriendsAttestationMax + 1) & 0xff}
                                               length:4];
    [raw appendData:SZFRandomBytes(SZFriendsAttestationMax + 1)];
    SZF_CHECK(SZFriendsDecodeFrame(raw, NULL) == nil, @"and the decoder one a peer sends");
}

// The helper's key policy decides an Add by ID answer's slot by its attestation (ADR 0004, Review amendments, 9), so
// the policy must see it: it used to be adopted only after the policy said yes, so the policy always saw nil.
static void SZFTestAttestationReachesPolicy(SZFriendsHandshakePattern pattern, BOOL allow) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    __block __weak SZFriendsSecureChannel *responder = nil;
    __block NSData *seen = nil;
    SZFriendsRemoteKeyPolicy policy = ^BOOL(NSData *k, SZFriendsHandshakePattern p, NSData *t) {
        (void)k, (void)p, (void)t;
        seen = responder.remoteAttestation;
        return allow;
    };
    SZFChannelPair *pair = [SZFChannelPair pairWithOptions:SZFOptions(pattern, bob)
                                         initiatorIdentity:alice
                                         responderIdentity:bob
                                             publicProfile:pattern == SZFriendsHandshakeXX ? @{} : nil
                                                    policy:policy];
    responder = pair.responder;
    NSData *attestation = SZFRandomBytes(200);
    pair.initiator.localAttestation = attestation;
    [pair start];
    if (allow) SZF_CHECK([pair waitUntilBothEstablished], @"pattern %u establishes", pattern);
    else SZF_CHECK([pair waitUntilBothClosed], @"pattern %u is refused", pattern);
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK([seen isEqualToData:attestation], @"pattern %u: the policy sees the initiator's attestation",
                  pattern);
        SZF_CHECK(allow ? [pair.responder.remoteAttestation isEqualToData:attestation]
                        : pair.responder.remoteAttestation == nil,
                  @"pattern %u: kept when allowed, gone when refused", pattern);
        [pair.initiator close];
    });
}

void SZFRunChannelIdentityTests(void) {
    SZFTestCertificateAndAttestation(SZFriendsHandshakeIK);
    SZFTestCertificateAndAttestation(SZFriendsHandshakeXX);
    SZFTestCertificateAndAttestation(SZFriendsHandshakeNN);
    SZFTestAttestationLimits();
    SZFTestAttestationReachesPolicy(SZFriendsHandshakeIK, YES);
    SZFTestAttestationReachesPolicy(SZFriendsHandshakeIK, NO);
    SZFTestAttestationReachesPolicy(SZFriendsHandshakeXX, YES);
}
