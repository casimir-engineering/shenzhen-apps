// Vector export: Friends' own Noise handshakes (ADR 0001: the real prologue, preamble and payloads, then transport
// frames and a rekey in each direction) from the helper's C state machine, and CPace with the join exchange's inputs
// and tags (ADR 0013) from its CPace and join code.

#import "SZFVectorExport.h"

#import <sodium.h>

#import "service/identity/SZFriendsCPace.h"
#import "service/identity/SZFriendsIdentityInternal.h"
#import "service/identity/SZFriendsJoinInternal.h"
#import "service/session/SZFriendsHandshakePayload.h"
#import "service/session/SZFriendsSession.h"
#import "service/session/szfriends_noise.h"

extern const char SZFriendsPrologueLabel[18];

static void SZFCheck(int status, const char *what) {
    if (status != SZFRIENDS_NOISE_OK) {
        fprintf(stderr, "SZFVectorExport: %s failed (%d)\n", what, status);
        exit(1);
    }
}

static SZFriendsIdentity *SZFNoiseIdentity(NSString *name) {
    return [SZFriendsIdentity identityWithSigningSeed:SZFDerive([name stringByAppendingString:@" seed"], 32)
                                     staticPrivateKey:SZFDeriveClampedKey([name stringByAppendingString:@" static"])];
}

static NSData *SZFPayload(NSString *kind, SZFriendsIdentity *alice, SZFriendsIdentity *bob) {
    SZFriendsHandshakePayload *payload = [SZFriendsHandshakePayload localPayload];
    if ([kind isEqualToString:@"empty"]) return [NSData data];
    if ([kind isEqualToString:@"xx2"]) {
        payload.certificate = bob.staticCertificate;
        payload.profile = @{
            @(SZFriendsFieldName) : SZFUTF8(@"Bob"),
            @(SZFriendsFieldPictureSet) : [SZFriendsFrame fieldWithUInt64:1 tag:SZFriendsFieldPictureSet],
            @(SZFriendsFieldPictureIndex) : [SZFriendsFrame fieldWithUInt64:2 tag:SZFriendsFieldPictureIndex],
        };
    } else if ([kind isEqualToString:@"xx3"]) {
        payload.certificate = alice.staticCertificate;
        payload.hasRouteClass = YES;
        payload.routeClass = 1;
        payload.attestation = SZFDerive(@"alice attestation", 64);
    } else if ([kind isEqualToString:@"ik1"]) {
        payload.certificate = alice.staticCertificate;
        payload.hasRouteClass = YES;
        payload.routeClass = 4;
        payload.requestToken = SZFDerive(@"ik callback token", 16);
    } else if ([kind isEqualToString:@"ik2"]) {
        payload.certificate = bob.staticCertificate;
    }
    return [payload encodedDataWithError:NULL];
}

static NSData *SZFFrame(SZFriendsFrameType type, NSDictionary *fields) {
    return SZFriendsEncodeFrame([SZFriendsFrame frameWithType:type fields:fields], NULL);
}

static void SZFAppendLength(NSMutableData *stream, NSData *message) {
    uint8_t length[2] = {(uint8_t)(message.length >> 8), (uint8_t)message.length};
    [stream appendBytes:length length:2];
    [stream appendData:message];
}

// Encrypts `plaintext` with `send`, checks `receive` decrypts it, and records it.
static NSDictionary *SZFTransport(NSString *direction, szfriends_cipher_state *send, szfriends_cipher_state *receive,
                                  NSData *plaintext, NSMutableData *stream) {
    uint64_t nonce = send->n;
    NSMutableData *ciphertext = [NSMutableData dataWithLength:plaintext.length + SZFRIENDS_NOISE_TAGLEN];
    size_t length = 0;
    SZFCheck(szfriends_cipher_encrypt(send, NULL, 0, plaintext.bytes, plaintext.length, ciphertext.mutableBytes,
                                      ciphertext.length, &length), "encrypt");
    NSMutableData *check = [NSMutableData dataWithLength:plaintext.length];
    SZFCheck(szfriends_cipher_decrypt(receive, NULL, 0, ciphertext.bytes, ciphertext.length, check.mutableBytes,
                                      check.length, &length), "decrypt");
    SZFAppendLength(stream, ciphertext);
    return @{@"direction" : direction, @"nonce" : @(nonce), @"plaintext" : SZFHexString(plaintext),
             @"ciphertext" : SZFHexString(ciphertext)};
}

static NSDictionary *SZFHandshake(szfriends_noise_pattern pattern, NSArray<NSString *> *payloadKinds) {
    SZFriendsIdentity *alice = SZFNoiseIdentity(@"alice"), *bob = SZFNoiseIdentity(@"bob");
    NSString *name = pattern == SZFRIENDS_NOISE_XX ? @"XX" : pattern == SZFRIENDS_NOISE_IK ? @"IK" : @"NN";
    uint8_t preamble[4] = {'S', 'Z', SZFriendsSessionMajor, (uint8_t)pattern};
    NSMutableData *prologue = [NSMutableData dataWithBytes:SZFriendsPrologueLabel length:18];
    [prologue appendBytes:preamble length:4];
    NSData *aliceStatic = alice.staticPrivateKey, *bobStatic = bob.staticPrivateKey;
    NSData *ei = SZFDerive([name stringByAppendingString:@" initiator ephemeral"], 32);
    NSData *er = SZFDerive([name stringByAppendingString:@" responder ephemeral"], 32);
    BOOL statics = pattern != SZFRIENDS_NOISE_NN;
    szfriends_handshake_state initiator, responder;
    SZFCheck(szfriends_handshake_init(&initiator, pattern, 1, prologue.bytes, prologue.length,
                                      statics ? aliceStatic.bytes : NULL,
                                      pattern == SZFRIENDS_NOISE_IK ? bob.staticPublicKey.bytes : NULL), "init i");
    SZFCheck(szfriends_handshake_init(&responder, pattern, 0, prologue.bytes, prologue.length,
                                      statics ? bobStatic.bytes : NULL, NULL), "init r");
    SZFCheck(szfriends_handshake_set_fixed_ephemeral(&initiator, ei.bytes), "fixed e i");
    SZFCheck(szfriends_handshake_set_fixed_ephemeral(&responder, er.bytes), "fixed e r");

    NSMutableData *toResponder = [NSMutableData dataWithBytes:preamble length:4];
    NSMutableData *toInitiator = [NSMutableData data];
    NSMutableArray *messages = [NSMutableArray array];
    for (NSUInteger i = 0; i < payloadKinds.count; i++) {
        BOOL fromInitiator = i % 2 == 0;
        szfriends_handshake_state *writer = fromInitiator ? &initiator : &responder;
        szfriends_handshake_state *reader = fromInitiator ? &responder : &initiator;
        NSData *payload = SZFPayload(payloadKinds[i], alice, bob);
        NSMutableData *message = [NSMutableData dataWithLength:SZFRIENDS_NOISE_MAX_MESSAGE];
        size_t length = 0;
        SZFCheck(szfriends_handshake_write(writer, payload.bytes, payload.length, message.mutableBytes, message.length,
                                           &length), "write");
        message.length = length;
        NSMutableData *read = [NSMutableData dataWithLength:SZFRIENDS_NOISE_MAX_MESSAGE];
        SZFCheck(szfriends_handshake_read(reader, message.bytes, message.length, read.mutableBytes, read.length,
                                          &length), "read");
        if (length != payload.length || memcmp(read.bytes, payload.bytes, length) != 0) {
            fprintf(stderr, "SZFVectorExport: payload mismatch\n");
            exit(1);
        }
        SZFAppendLength(fromInitiator ? toResponder : toInitiator, message);
        [messages addObject:@{@"payload" : SZFHexString(payload), @"ciphertext" : SZFHexString(message)}];
    }
    uint8_t hi[SZFRIENDS_NOISE_HASHLEN], hr[SZFRIENDS_NOISE_HASHLEN];
    szfriends_handshake_hash(&initiator, hi);
    szfriends_handshake_hash(&responder, hr);
    if (memcmp(hi, hr, sizeof hi) != 0) exit(1);
    szfriends_cipher_state iSend, iReceive, rSend, rReceive;
    SZFCheck(szfriends_handshake_split(&initiator, &iSend, &iReceive), "split i");
    SZFCheck(szfriends_handshake_split(&responder, &rSend, &rReceive), "split r");

    NSData *msgID = SZFDerive(@"transport message id", 16);
    NSMutableArray *transport = [NSMutableArray array];
    [transport addObject:SZFTransport(@"i2r", &iSend, &rReceive, SZFFrame(SZFriendsFrameTypeHello, @{}), toResponder)];
    [transport addObject:SZFTransport(@"r2i", &rSend, &iReceive, SZFFrame(SZFriendsFrameTypeMessage, @{
        @(SZFriendsFieldID) : msgID,
        @(SZFriendsFieldSentAt) : [SZFriendsFrame fieldWithUInt64:1760600000789 tag:SZFriendsFieldSentAt],
        @(SZFriendsFieldText) : SZFUTF8(@"Got the gearbox, thanks")}), toInitiator)];
    [transport addObject:SZFTransport(@"i2r", &iSend, &rReceive,
                                      SZFFrame(SZFriendsFrameTypeAck, @{@(SZFriendsFieldID) : msgID}), toResponder)];
    // ADR 0001 § Rekey: REKEY under the old key, then Rekey() on that direction's two CipherStates.
    [transport addObject:SZFTransport(@"i2r", &iSend, &rReceive, SZFFrame(SZFriendsFrameTypeRekey, @{}), toResponder)];
    SZFCheck(szfriends_cipher_rekey(&iSend), "rekey");
    SZFCheck(szfriends_cipher_rekey(&rReceive), "rekey");
    [transport addObject:SZFTransport(@"i2r", &iSend, &rReceive, SZFFrame(SZFriendsFrameTypePing, @{}), toResponder)];
    [transport addObject:SZFTransport(@"r2i", &rSend, &iReceive, SZFFrame(SZFriendsFrameTypeRekey, @{}), toInitiator)];
    SZFCheck(szfriends_cipher_rekey(&rSend), "rekey");
    SZFCheck(szfriends_cipher_rekey(&iReceive), "rekey");
    [transport addObject:SZFTransport(@"r2i", &rSend, &iReceive, SZFFrame(SZFriendsFrameTypeClose, @{
        @(SZFriendsFieldReason) : [SZFriendsFrame fieldWithUInt64:0 tag:SZFriendsFieldReason]}), toInitiator)];

    return @{
        @"pattern" : name,
        @"pattern_byte" : @(pattern),
        @"protocol_name" : [NSString stringWithFormat:@"Noise_%@_25519_ChaChaPoly_BLAKE2b", name],
        @"prologue" : SZFHexString(prologue),
        @"preamble" : SZFHexString([NSData dataWithBytes:preamble length:4]),
        @"initiator" : @"alice",
        @"responder" : @"bob",
        @"initiator_static" : statics ? SZFHexString(aliceStatic) : [NSNull null],
        @"responder_static" : statics ? SZFHexString(bobStatic) : [NSNull null],
        @"responder_static_public" : SZFHexString(bob.staticPublicKey),
        @"initiator_ephemeral" : SZFHexString(ei),
        @"responder_ephemeral" : SZFHexString(er),
        @"messages" : messages,
        @"handshake_hash" : SZFHexString([NSData dataWithBytes:hi length:sizeof hi]),
        @"transport" : transport,
        @"stream_to_responder" : SZFHexString(toResponder),
        @"stream_to_initiator" : SZFHexString(toInitiator),
    };
}

// IK message 1 with its ephemeral key replaced by a low-order point: the responder's "es" is all zeros, which the
// helper refuses (ADR 0001: an all-zero X25519 result is a failure).
static NSDictionary *SZFLowOrder(NSDictionary *ik) {
    NSMutableData *message = [[NSMutableData alloc] init];
    NSString *hex = ik[@"messages"][0][@"ciphertext"];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        unsigned value = 0;
        sscanf([hex substringWithRange:NSMakeRange(i, 2)].UTF8String, "%02x", &value);
        uint8_t byte = (uint8_t)value;
        [message appendBytes:&byte length:1];
    }
    memset(message.mutableBytes, 0, 32);
    SZFriendsIdentity *bob = SZFNoiseIdentity(@"bob");
    NSMutableData *prologue = [NSMutableData dataWithBytes:SZFriendsPrologueLabel length:18];
    uint8_t preamble[4] = {'S', 'Z', SZFriendsSessionMajor, SZFRIENDS_NOISE_IK};
    [prologue appendBytes:preamble length:4];
    szfriends_handshake_state responder;
    SZFCheck(szfriends_handshake_init(&responder, SZFRIENDS_NOISE_IK, 0, prologue.bytes, prologue.length,
                                      bob.staticPrivateKey.bytes, NULL), "init");
    uint8_t out[1024];
    size_t length = 0;
    int status = szfriends_handshake_read(&responder, message.bytes, message.length, out, sizeof out, &length);
    return @{@"pattern" : @"IK", @"message" : SZFHexString(message), @"read_status" : @(status)};
}

NSDictionary *SZFExportNoise(void) {
    NSDictionary *ik = SZFHandshake(SZFRIENDS_NOISE_IK, @[ @"ik1", @"ik2" ]);
    return @{
        @"prologue_label" : SZFHexString([NSData dataWithBytes:SZFriendsPrologueLabel length:18]),
        @"handshakes" : @[ SZFHandshake(SZFRIENDS_NOISE_XX, @[ @"empty", @"xx2", @"xx3" ]), ik,
                           SZFHandshake(SZFRIENDS_NOISE_NN, @[ @"local", @"local" ]) ],
        @"low_order" : SZFLowOrder(ik),
    };
}

#pragma mark - CPace

static NSData *SZFScalar(NSString *label) {
    NSData *wide = SZFDerive(label, 64);
    NSMutableData *scalar = [NSMutableData dataWithLength:crypto_core_ristretto255_SCALARBYTES];
    crypto_core_ristretto255_scalar_reduce(scalar.mutableBytes, wide.bytes);
    return scalar;
}

static NSDictionary *SZFCPaceRun(NSString *name, NSData *prs, NSData *ci, NSData *sid, NSData *ya, NSData *yb,
                                 NSData *adA, NSData *adB) {
    SZFriendsCPace *a = [[SZFriendsCPace alloc] initWithPassword:prs channelIdentifier:ci sessionID:sid scalar:ya];
    SZFriendsCPace *b = [[SZFriendsCPace alloc] initWithPassword:prs channelIdentifier:ci sessionID:sid scalar:yb];
    NSData *iskA = [a iskAsInitiatorWithAD:adA peerShare:b.share peerAD:adB];
    NSData *iskB = [b iskAsResponderWithAD:adB peerShare:a.share peerAD:adA];
    if (![iskA isEqualToData:iskB]) exit(1);
    return @{
        @"name" : name, @"prs" : SZFHexString(prs), @"ci" : SZFHexString(ci), @"sid" : SZFHexString(sid),
        @"ya" : SZFHexString(ya), @"yb" : SZFHexString(yb), @"ada" : SZFHexString(adA), @"adb" : SZFHexString(adB),
        @"generator_string" : SZFHexString(SZFriendsCPaceGeneratorString(prs, ci, sid)),
        @"generator" : SZFHexString(SZFriendsCPaceGenerator(prs, ci, sid)),
        @"share_a" : SZFHexString(a.share), @"share_b" : SZFHexString(b.share),
        @"k" : SZFHexString(SZFriendsCPaceScalarMultVfy(ya, b.share)), @"isk" : SZFHexString(iskA),
    };
}

static NSData *SZFHexData(NSString *hex) {
    NSMutableData *data = [NSMutableData data];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        unsigned value = 0;
        sscanf([hex substringWithRange:NSMakeRange(i, 2)].UTF8String, "%02x", &value);
        uint8_t byte = (uint8_t)value;
        [data appendBytes:&byte length:1];
    }
    return data;
}

NSDictionary *SZFExportCPace(void) {
    // draft-irtf-cfrg-cpace-13 Appendix B.3's inputs; its outputs are what SZFriendsCPaceTests checks.
    NSDictionary *draft = SZFCPaceRun(@"draft-13 B.3", SZFUTF8(@"Password"),
        SZFHexData(@"6f630b425f726573706f6e6465720b415f696e69746961746f72"),
        SZFHexData(@"7e4b4791d6a8ef019b936c79fb7f2c57"),
        SZFHexData(@"da3d23700a9e5699258aef94dc060dfda5ebb61f02a5ea77fad53f4ff0976d08"),
        SZFHexData(@"d2316b454718c35362d83d69df6320f38578ed5984651435e2949762d900b80d"), SZFUTF8(@"ADa"),
        SZFUTF8(@"ADb"));
    // The join exchange's own inputs (ADR 0013): PRS the typed code, CI from the request, sid the NN hash.
    SZFriendsIdentity *joiner = SZFNoiseIdentity(@"carol"), *approver = SZFNoiseIdentity(@"bob");
    NSData *requestID = SZFDerive(@"join request id", 16), *rootKey = SZFDerive(@"join root key", 32);
    NSData *ci = SZFriendsJoinChannelIdentifier(requestID, joiner.publicKey, joiner.staticPublicKey);
    NSData *adB = SZFriendsJoinApproverAD(approver.publicKey, rootKey);
    NSMutableDictionary *join = [SZFCPaceRun(@"join", SZFUTF8(@"48213907"), ci, SZFDerive(@"join nn hash", 64),
                                             SZFScalar(@"join ya"), SZFScalar(@"join yb"), joiner.publicKey, adB)
        mutableCopy];
    NSData *isk = SZFHexData(join[@"isk"]);
    NSData *consent = SZFDerive(@"join consent signature", 64), *body = SZFDerive(@"join welcome body", 48);
    join[@"request_id"] = SZFHexString(requestID);
    join[@"device_key"] = SZFHexString(joiner.publicKey);
    join[@"static_key"] = SZFHexString(joiner.staticPublicKey);
    join[@"approver_key"] = SZFHexString(approver.publicKey);
    join[@"root_key"] = SZFHexString(rootKey);
    join[@"responder_tag"] = SZFHexString(SZFriendsJoinTag(isk, SZFriendsJoinResponderTagDomain, nil));
    join[@"consent"] = SZFHexString(consent);
    join[@"initiator_tag"] = SZFHexString(SZFriendsJoinTag(isk, SZFriendsJoinInitiatorTagDomain, consent));
    join[@"welcome_body"] = SZFHexString(body);
    join[@"welcome_tag"] = SZFHexString(SZFriendsJoinTag(isk, SZFriendsJoinWelcomeTagDomain, body));

    NSData *scalar = SZFHexData(@"7cd0e075fa7955ba52c02759a6c90dbbfc10e6d40aea8d283e407d88cf538a05");
    NSMutableArray *vfy = [NSMutableArray array];
    for (NSString *point in @[ @"2c3c6b8c4f3800e7aef6864025b4ed79bd599117e427c41bd47d93d654b4a51c",
                               @"2b3c6b8c4f3800e7aef6864025b4ed79bd599117e427c41bd47d93d654b4a51c",
                               @"0000000000000000000000000000000000000000000000000000000000000000" ]) {
        NSData *product = SZFriendsCPaceScalarMultVfy(scalar, SZFHexData(point));
        [vfy addObject:@{@"scalar" : SZFHexString(scalar), @"point" : point,
                         @"product" : product ? SZFHexString(product) : [NSNull null]}];
    }
    NSMutableArray *lvcat = [NSMutableArray array];
    NSArray *parts = @[ SZFUTF8(@"1234"), SZFUTF8(@"5"), [NSData data], SZFUTF8(@"678"),
                        [NSMutableData dataWithLength:130] ];
    NSMutableArray *partsHex = [NSMutableArray array];
    for (NSData *part in parts) [partsHex addObject:SZFHexString(part)];
    [lvcat addObject:@{@"parts" : partsHex, @"lv_cat" : SZFHexString(SZFriendsCPaceLVCat(parts))}];
    return @{@"runs" : @[ draft, join ], @"scalar_mult_vfy" : vfy, @"lv_cat" : lvcat};
}
