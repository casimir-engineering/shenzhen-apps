// SZFriendsSecureChannel: the preamble, the Noise handshake messages, their payloads and the key policy.
// Payload layout per message: SZFriendsHandshakePayload.h.

#import "service/session/SZFriendsSecureChannelInternal.h"

#import <sodium.h>

#import "service/identity/SZFriendsIdentity.h"
#import "service/session/SZFriendsFrameSchema.h"
#import "service/session/SZFriendsHandshakePayload.h"

@implementation SZFriendsSecureChannel (Handshake)

#pragma mark - Setup

- (BOOL)initializeHandshakeWithPreamble:(const uint8_t *)preamble {
    NSMutableData *prologue = [NSMutableData dataWithBytes:SZFriendsPrologueLabel length:sizeof SZFriendsPrologueLabel];
    [prologue appendBytes:preamble length:4];
    uint8_t staticPrivate[SZFRIENDS_NOISE_DHLEN];
    const uint8_t *staticKey = NULL;
    if (self.pattern != SZFriendsHandshakeNN) {
        NSData *privateKey = [_identity staticPrivateKey];
        if (privateKey.length != SZFRIENDS_NOISE_DHLEN) {
            return NO;
        }
        memcpy(staticPrivate, privateKey.bytes, sizeof staticPrivate);
        staticKey = staticPrivate;
        // The identity header asks callers to zero their copy; only a mutable one can be zeroed in place.
        if ([privateKey isKindOfClass:[NSMutableData class]]) {
            sodium_memzero(((NSMutableData *)privateKey).mutableBytes, privateKey.length);
        }
    }
    const uint8_t *remoteStatic = NULL;
    if (self.isInitiator && self.pattern == SZFriendsHandshakeIK) {
        remoteStatic = _options.remoteStaticKey.bytes;
    }
    int result = szfriends_handshake_init(&_handshake, (szfriends_noise_pattern)self.pattern, self.isInitiator,
                                          prologue.bytes, prologue.length, staticKey, remoteStatic);
    sodium_memzero(staticPrivate, sizeof staticPrivate);
    return result == SZFRIENDS_NOISE_OK;
}

- (SZFriendsHandshakePayload *)localPayloadWithCertificate:(BOOL)withCertificate {
    SZFriendsHandshakePayload *payload = [SZFriendsHandshakePayload localPayload];
    payload.capabilities = self.localCapabilities;
    if (withCertificate) {
        payload.certificate = _identity.staticCertificate;
        // The attestation names our identity, so it goes only where the certificate already does.
        payload.attestation = self.localAttestation;
    }
    return payload;
}

// The next handshake message for `payload`, framed with its u16 length; nil after failing the channel.
- (NSData *)framedHandshakeMessage:(SZFriendsHandshakePayload *)payload {
    NSError *error = nil;
    NSData *encoded = payload ? [payload encodedDataWithError:&error] : [NSData data];
    int overhead = szfriends_handshake_overhead(&_handshake);
    if (encoded == nil || overhead < 0) {
        [self failWithCode:SZFriendsSessionErrorFrameInvalid reason:@"handshake payload does not encode"];
        return nil;
    }
    NSMutableData *output = [NSMutableData dataWithLength:2 + (NSUInteger)overhead + encoded.length];
    uint8_t *bytes = output.mutableBytes;
    size_t written = 0;
    int result = szfriends_handshake_write(&_handshake, encoded.bytes, encoded.length, bytes + 2, output.length - 2,
                                           &written);
    if (result != SZFRIENDS_NOISE_OK) {
        [self failWithCode:result == SZFRIENDS_NOISE_ERR_SIZE ? SZFriendsSessionErrorFrameInvalid
                                                               : SZFriendsSessionErrorHandshakeFailed
                    reason:@"handshake message could not be written"];
        return nil;
    }
    bytes[0] = (uint8_t)(written >> 8);
    bytes[1] = (uint8_t)written;
    output.length = 2 + written;
    return output;
}

// Handshake messages are small and precede every transport frame, so they skip the send queues.
- (void)writeHandshakeBytes:(NSData *)data {
    if (!self.isInitiator) {
        _responderReplied = YES; // from here a refusal no longer hides behind the refusal deadline
    }
    __weak typeof(self) weakSelf = self;
    [_stream writeData:data
            completion:^(NSError *error) {
                if (error) {
                    [weakSelf streamClosedWithError:error];
                }
            }];
}

- (void)finishHandshake {
    uint8_t hash[SZFRIENDS_NOISE_HASHLEN];
    szfriends_handshake_hash(&_handshake, hash);
    self.handshakeHash = [NSData dataWithBytes:hash length:sizeof hash];
    sodium_memzero(hash, sizeof hash);
    int result = szfriends_handshake_split(&_handshake, &_sendCipher, &_receiveCipher);
    szfriends_handshake_clear(&_handshake);
    if (result != SZFRIENDS_NOISE_OK) {
        [self failWithCode:SZFriendsSessionErrorHandshakeFailed reason:@"split failed"];
        return;
    }
    _hasTransportKeys = YES;
    if (self.isInitiator) {
        [self becomeEstablished];
    } else {
        _state = SZFriendsChannelStateAwaitingHello;
    }
}

#pragma mark - Initiator

- (void)startInitiatorHandshake {
    SZFriendsHandshakePattern pattern = self.pattern;
    NSData *token = _options.requestToken;
    // XX and IK declare the route they run over; the session race on both sides is judged from it.
    SZFriendsRouteMethod route = self.initiatorRoute;
    BOOL routeKnown = route >= SZFriendsRouteMethodLAN && route <= SZFriendsRouteMethodRelay;
    if (pattern > SZFriendsHandshakeNN || (pattern != SZFriendsHandshakeNN && !routeKnown) ||
        (pattern == SZFriendsHandshakeIK && _options.remoteStaticKey.length != SZFRIENDS_NOISE_DHLEN) ||
        (token != nil && (pattern != SZFriendsHandshakeIK || token.length != 16))) {
        [self failWithCode:SZFriendsSessionErrorHandshakeFailed reason:@"handshake options do not fit the pattern"];
        return;
    }
    uint8_t preamble[4] = {'S', 'Z', SZFriendsSessionMajor, pattern};
    if (![self initializeHandshakeWithPreamble:preamble]) {
        [self failWithCode:SZFriendsSessionErrorHandshakeFailed reason:@"handshake could not start"];
        return;
    }
    SZFriendsHandshakePayload *payload = nil; // XX message 1 is plaintext and says nothing
    if (pattern == SZFriendsHandshakeNN) {
        payload = [self localPayloadWithCertificate:NO];
    } else if (pattern == SZFriendsHandshakeIK) {
        payload = [self localPayloadWithCertificate:YES];
        payload.hasRouteClass = YES;
        payload.routeClass = (uint8_t)self.initiatorRoute;
        payload.requestToken = token;
        payload.lane = _options.lane;
    }
    NSData *message = [self framedHandshakeMessage:payload];
    if (message == nil) {
        return;
    }
    NSMutableData *output = [NSMutableData dataWithBytes:preamble length:sizeof preamble];
    [output appendData:message];
    [self writeHandshakeBytes:output];
}

- (void)initiatorReadPayload:(SZFriendsHandshakePayload *)payload {
    if (self.pattern != SZFriendsHandshakeNN) {
        NSData *identityKey = [self identityKeyFromPayload:payload];
        if (identityKey == nil) {
            return;
        }
        NSData *expected = _options.expectedIdentityKey;
        if (expected != nil && ![identityKey isEqualToData:expected]) {
            [self failWithCode:SZFriendsSessionErrorHandshakeFailed reason:@"not the identity this attempt dialed"];
            return;
        }
        [self adoptRemoteIdentity:identityKey payload:payload];
    }
    if (![self acceptMinorRange:payload]) {
        return;
    }
    if (self.pattern == SZFriendsHandshakeXX) {
        BOOL proceed = !_options.browseOnly;
        BOOL (^onPublicProfile)(NSDictionary<NSNumber *, NSData *> *) = self.onPublicProfile;
        if (onPublicProfile) {
            proceed = onPublicProfile(payload.profile ?: @{});
        }
        if (_state == SZFriendsChannelStateClosed) {
            return;
        }
        if (!proceed) {
            // Browsing ends here: message 3 would reveal who we are.
            [self terminateWithError:nil closeReason:-1];
            return;
        }
        SZFriendsHandshakePayload *reply = [self localPayloadWithCertificate:YES];
        reply.hasRouteClass = YES;
        reply.routeClass = (uint8_t)self.initiatorRoute;
        NSData *message = [self framedHandshakeMessage:reply];
        if (message == nil) {
            return;
        }
        [self writeHandshakeBytes:message];
    }
    [self finishHandshake];
}

#pragma mark - Responder

- (BOOL)consumePreambleFromBytes:(const uint8_t *)bytes length:(NSUInteger)length {
    if (length != 4 || bytes[0] != 'S' || bytes[1] != 'Z' || bytes[2] != SZFriendsSessionMajor ||
        bytes[3] > SZFriendsHandshakeNN) {
        [self failWithCode:SZFriendsSessionErrorHandshakeFailed reason:@"unknown preamble"];
        return NO;
    }
    self.pattern = bytes[3];
    // A hidden listener answers only IK and NN; XX would hand a stranger our static key and profile.
    if (self.pattern == SZFriendsHandshakeXX && _publicProfile == nil) {
        [self failWithCode:SZFriendsSessionErrorRejected reason:@"XX reached a listener without a public entry"];
        return NO;
    }
    // The listener's per-pattern admission rate, before any Diffie-Hellman (SZFriendsByteStream).
    if ([_stream respondsToSelector:@selector(admitHandshakePattern:)] &&
        ![_stream admitHandshakePattern:self.pattern]) {
        [self failWithCode:SZFriendsSessionErrorRejected reason:@"the listener's admission rate is full"];
        return NO;
    }
    if (![self initializeHandshakeWithPreamble:bytes]) {
        [self failWithCode:SZFriendsSessionErrorHandshakeFailed reason:@"handshake could not start"];
        return NO;
    }
    _state = SZFriendsChannelStateHandshaking;
    return YES;
}

- (void)responderReadPayload:(SZFriendsHandshakePayload *)payload step:(int)step {
    SZFriendsHandshakePattern pattern = self.pattern;
    if (pattern == SZFriendsHandshakeXX && step == 1) {
        // Message 1 is plaintext; whatever it carries is ignored.
        SZFriendsHandshakePayload *reply = [self localPayloadWithCertificate:YES];
        reply.profile = _publicProfile;
        NSData *message = [self framedHandshakeMessage:reply];
        if (message != nil) {
            [self writeHandshakeBytes:message];
        }
        return;
    }
    NSData *identityKey = nil;
    if (pattern != SZFriendsHandshakeNN) {
        identityKey = [self identityKeyFromPayload:payload];
        if (identityKey == nil || ![self acceptRouteClass:payload]) {
            return;
        }
    }
    if (![self acceptMinorRange:payload]) {
        return;
    }
    NSData *token = pattern == SZFriendsHandshakeIK ? payload.requestToken : nil;
    // The policy may weigh the attestation (an Add by ID answer's slot, or its refusal), so it sees it unverified
    // first; a refused remote keeps nothing, as it never kept its identity.
    self.remoteAttestation = pattern != SZFriendsHandshakeNN ? payload.attestation : nil;
    if (![self askPolicyWithIdentity:identityKey token:token]) {
        self.remoteAttestation = nil;
        return;
    }
    self.presentedRequestToken = token;
    self.presentedLane = pattern == SZFriendsHandshakeIK ? payload.lane : nil;
    if (pattern != SZFriendsHandshakeNN) {
        [self adoptRemoteIdentity:identityKey payload:payload];
        // Known now: IK message 1 is fresh (the replay cache refused any repeat before the payload) and proves the
        // initiator's static key; XX message 3 proves it against our fresh ephemeral.
        [self reportAuthenticated];
    }
    if (pattern != SZFriendsHandshakeXX) {
        SZFriendsHandshakePayload *reply = [self localPayloadWithCertificate:pattern != SZFriendsHandshakeNN];
        NSData *message = [self framedHandshakeMessage:reply];
        if (message == nil) {
            return;
        }
        [self writeHandshakeBytes:message];
    }
    [self finishHandshake];
}

- (void)adoptRemoteIdentity:(NSData *)identityKey payload:(SZFriendsHandshakePayload *)payload {
    self.remoteIdentityKey = identityKey;
    self.remoteCertificate = payload.certificate;
    self.remoteAttestation = payload.attestation;
}

- (void)reportAuthenticated {
    if (self.isInitiator || _toldAuthenticated) {
        return;
    }
    _toldAuthenticated = YES;
    if ([_stream respondsToSelector:@selector(sessionDidAuthenticate)]) {
        [_stream sessionDidAuthenticate];
    }
}

- (BOOL)askPolicyWithIdentity:(NSData *)identityKey token:(NSData *)token {
    SZFriendsRemoteKeyPolicy policy = _keyPolicy;
    BOOL allowed = policy ? policy(identityKey, self.pattern, token) : NO;
    if (_state == SZFriendsChannelStateClosed) {
        return NO;
    }
    if (!allowed) {
        [self failWithCode:SZFriendsSessionErrorRejected reason:@"the key policy refused the remote"];
        return NO;
    }
    return YES;
}

#pragma mark - Both sides

- (void)handleHandshakeMessage:(const uint8_t *)message length:(NSUInteger)length {
    BOOL firstAtResponder = !self.isInitiator && _handshake.step == 0;
    if (firstAtResponder && [_stream respondsToSelector:@selector(handshakeDidReceiveFirstMessage)]) {
        [_stream handshakeDidReceiveFirstMessage]; // the listener's deadline for a complete message 1 is met
    }
    BOOL recordsKey = firstAtResponder && self.pattern != SZFriendsHandshakeXX;
    BOOL equalise = firstAtResponder && self.pattern == SZFriendsHandshakeIK;
    _message1CertificateChecks = 0;
    NSMutableData *plaintext = [NSMutableData dataWithLength:length];
    size_t plaintextLength = 0;
    int result = szfriends_handshake_read(&_handshake, message, length, plaintext.mutableBytes, plaintext.length,
                                          &plaintextLength);
    _message1DH = equalise ? (NSUInteger)_handshake.dh_count : 0; // read now: a refusal clears the state
    SZFriendsHandshakePayload *payload = nil;
    if (result != SZFRIENDS_NOISE_OK) {
        [self failWithCode:SZFriendsSessionErrorHandshakeFailed reason:@"handshake message did not authenticate"];
    } else if (recordsKey && ![self isFreshMessage1:message length:length]) {
        // Refused inside; the work so far is the full path's, and equalised below like any IK message 1.
    } else {
        plaintext.length = plaintextLength;
        payload = [SZFriendsHandshakePayload payloadWithData:plaintext error:NULL];
        if (payload == nil) {
            [self failWithCode:SZFriendsSessionErrorHandshakeFailed reason:@"handshake payload does not parse"];
        } else if (self.isInitiator) {
            [self initiatorReadPayload:payload];
        } else {
            [self responderReadPayload:payload step:_handshake.step];
        }
    }
    if (equalise) {
        [self equaliseMessage1Work];
    }
}

// IK message 1 sealed to another listener's static key fails at its 's' token after one Diffie-Hellman; one sealed to
// ours runs a second (ss) and a certificate check before the key policy refuses it. Both close at the same refusal
// deadline, but message 1 is processed on the helper's one serial queue, so an NN request queued right behind it is
// answered later on the long path: anyone holding a person's static key could find their hidden listener by timing
// that reply. So every IK message 1 costs what the full path costs: two X25519 operations and one certificate check,
// the missing ones run on throwaway inputs (our own certificate checks at full cost, since it verifies). What still
// differs is the policy's own lookup, and a certificate the initiator built to fail libsodium's cheap early checks.
- (void)equaliseMessage1Work {
    static const NSUInteger kFullPathDH = 2, kFullPathCertificateChecks = 1;
    _message1DummyDH = 0;
    _message1DummyCertificateChecks = 0;
    while (_message1DH + _message1DummyDH < kFullPathDH) {
        szfriends_noise_dummy_dh();
        _message1DummyDH++;
    }
    while (_message1CertificateChecks + _message1DummyCertificateChecks < kFullPathCertificateChecks) {
        (void)SZFriendsIdentityKeyFromCertificate(_identity.staticCertificate, _identity.staticPublicKey);
        _message1DummyCertificateChecks++;
    }
}

// IK and NN message 1 open with the initiator's ephemeral key in clear: once message 1 has decrypted, and before its
// payload is read, refuse one seen before, so a replayed message 1 never reaches the key policy twice
// (SZFriendsReplayCache). Only after decryption (Noise § 7.7), as signalling does: junk, and IK sealed to another
// listener's key, never enter the shared cache, so they cannot evict a friend's message 1 to replay it.
- (BOOL)isFreshMessage1:(const uint8_t *)message length:(NSUInteger)length {
    if (length < SZFRIENDS_NOISE_DHLEN) {
        [self failWithCode:SZFriendsSessionErrorHandshakeFailed reason:@"message 1 shorter than a key"];
        return NO;
    }
    if (![self.replayCache recordEphemeralKey:[NSData dataWithBytes:message length:SZFRIENDS_NOISE_DHLEN]]) {
        [self failWithCode:SZFriendsSessionErrorReplayed reason:@"message 1 repeats an ephemeral key"];
        return NO;
    }
    return YES;
}

// The certificate must bind the static key this handshake authenticated; the identity is the Ed25519 key it names.
- (NSData *)identityKeyFromPayload:(SZFriendsHandshakePayload *)payload {
    const uint8_t *remoteStatic = szfriends_handshake_remote_static(&_handshake);
    NSData *staticKey = remoteStatic ? [NSData dataWithBytes:remoteStatic length:SZFRIENDS_NOISE_DHLEN] : nil;
    NSData *identityKey = nil;
    if (staticKey && payload.certificate) {
        _message1CertificateChecks++;
        identityKey = SZFriendsIdentityKeyFromCertificate(payload.certificate, staticKey);
    }
    if (identityKey.length != 32) {
        [self failWithCode:SZFriendsSessionErrorHandshakeFailed reason:@"certificate does not bind the static key"];
        return nil;
    }
    self.remoteStaticKey = staticKey;
    return identityKey;
}

- (BOOL)acceptMinorRange:(SZFriendsHandshakePayload *)payload {
    uint16_t negotiated = 0;
    if (!payload.hasMinorRange ||
        !SZFriendsNegotiateMinor(0, SZFriendsSessionMinor, payload.minorMin, payload.minorMax, &negotiated)) {
        [self failWithCode:SZFriendsSessionErrorHandshakeFailed reason:@"no minor version in common"];
        return NO;
    }
    self.negotiatedMinor = negotiated;
    self.remoteCapabilities = payload.capabilities;
    return YES;
}

- (BOOL)acceptRouteClass:(SZFriendsHandshakePayload *)payload {
    if (!payload.hasRouteClass || payload.routeClass < SZFriendsRouteMethodLAN ||
        payload.routeClass > SZFriendsRouteMethodRelay) {
        [self failWithCode:SZFriendsSessionErrorHandshakeFailed reason:@"missing or unknown route class"];
        return NO;
    }
    self.initiatorRoute = (SZFriendsRouteMethod)payload.routeClass;
    return YES;
}

@end
