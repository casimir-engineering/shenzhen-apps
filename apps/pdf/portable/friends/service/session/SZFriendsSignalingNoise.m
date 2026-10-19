// Noise signalling (SZFriendsSignaling.h): IK for friends and own devices, NN for Add by ID online, carried as
// opaque payloads by the host. The same C state machine as ADR 0001's channel, under its own prologue, with
// messages that are whole payloads rather than length-prefixed reads from a stream.

#import "service/session/SZFriendsSignaling.h"

#import <sodium.h>

#import "service/identity/SZFriendsIdentity.h"
#import "service/session/SZFriendsFrameSchema.h"
#import "service/session/szfriends_noise.h"

// "SZFriends signal v1" and its NUL, then the two header bytes of message 1.
static const char SZFriendsSignalPrologueLabel[20] = "SZFriends signal v1";
static const uint8_t SZFriendsSignalHeaderMagic = 'S';
static const NSUInteger SZFriendsSignalHeaderLength = 2;

static NSError *SZFriendsSignalError(SZFriendsSessionError code, NSString *reason) {
    return SZFriendsSessionMakeError(code, reason);
}

static NSData *SZFriendsSignalBigEndian(uint64_t value, NSUInteger width) {
    uint8_t bytes[8];
    for (NSUInteger i = 0; i < width; i++) bytes[i] = (uint8_t)(value >> (8 * (width - 1 - i)));
    return [NSData dataWithBytes:bytes length:width];
}

@interface SZFriendsSignalingSession ()
@property(nonatomic, readwrite) SZFriendsHandshakePattern pattern;
@property(nonatomic, readwrite) BOOL isInitiator;
@property(nonatomic, readwrite) BOOL established;
@property(nonatomic, readwrite) uint16_t negotiatedMinor;
@property(nonatomic, readwrite, nullable) NSData *remoteIdentityKey;
@property(nonatomic, readwrite, nullable) NSData *remoteStaticKey;
@property(nonatomic, readwrite, nullable) NSData *remoteCertificate;
@property(nonatomic, readwrite, nullable) NSData *remoteAttestation;
@property(nonatomic, readwrite, nullable) NSData *presentedRequestToken;
@property(nonatomic, readwrite, nullable) NSData *handshakeHash;
@end

@implementation SZFriendsSignalingSession {
    szfriends_handshake_state _handshake;
    szfriends_cipher_state _send;
    szfriends_cipher_state _receive;
    BOOL _dead;
    BOOL _wroteOrReadMessage1;
    SZFriendsIdentity *_identity;
    NSData *_expectedIdentityKey;
    NSData *_requestToken;
}

- (instancetype)initWithPattern:(SZFriendsHandshakePattern)pattern
                      initiator:(BOOL)initiator
                       identity:(SZFriendsIdentity *)identity
                remoteStaticKey:(NSData *)remoteStaticKey {
    if (!(self = [super init])) return nil;
    _pattern = pattern;
    _isInitiator = initiator;
    _identity = identity;
    uint8_t header[2] = {SZFriendsSignalHeaderMagic, (uint8_t)pattern};
    NSMutableData *prologue = [NSMutableData dataWithBytes:SZFriendsSignalPrologueLabel
                                                    length:sizeof SZFriendsSignalPrologueLabel];
    [prologue appendBytes:header length:sizeof header];
    NSData *privateKey = pattern == SZFriendsHandshakeIK ? [identity staticPrivateKey] : nil;
    if (pattern == SZFriendsHandshakeIK && privateKey.length != SZFRIENDS_NOISE_DHLEN) return nil;
    int result = szfriends_handshake_init(&_handshake, (szfriends_noise_pattern)pattern, initiator, prologue.bytes,
                                          prologue.length, privateKey.bytes, remoteStaticKey.bytes);
    if ([privateKey isKindOfClass:[NSMutableData class]]) {
        sodium_memzero(((NSMutableData *)privateKey).mutableBytes, privateKey.length);
    }
    return result == SZFRIENDS_NOISE_OK ? self : nil;
}

- (instancetype)initIKInitiatorWithIdentity:(SZFriendsIdentity *)identity
                            remoteStaticKey:(NSData *)remoteStaticKey
                        expectedIdentityKey:(NSData *)expectedIdentityKey
                               requestToken:(NSData *)requestToken {
    if (remoteStaticKey.length != SZFRIENDS_NOISE_DHLEN || expectedIdentityKey.length != 32 ||
        (requestToken != nil && requestToken.length != 16)) {
        return nil;
    }
    self = [self initWithPattern:SZFriendsHandshakeIK initiator:YES identity:identity remoteStaticKey:remoteStaticKey];
    if (self == nil) return nil;
    _expectedIdentityKey = [expectedIdentityKey copy];
    _requestToken = [requestToken copy];
    return self;
}

- (instancetype)initNNInitiator {
    return [self initWithPattern:SZFriendsHandshakeNN initiator:YES identity:nil remoteStaticKey:nil];
}

- (void)dealloc {
    szfriends_handshake_clear(&_handshake);
    szfriends_cipher_clear(&_send);
    szfriends_cipher_clear(&_receive);
}

// Every failure is final, as Noise requires after an error (spec § 5.3).
- (void)die {
    _dead = YES;
    szfriends_handshake_clear(&_handshake);
    szfriends_cipher_clear(&_send);
    szfriends_cipher_clear(&_receive);
}

- (BOOL)failWith:(NSError **)error code:(SZFriendsSessionError)code reason:(NSString *)reason {
    [self die];
    if (error) *error = SZFriendsSignalError(code, reason);
    return NO;
}

#pragma mark - Hello

- (SZFriendsSignalItem *)helloWithTime:(NSDate *)now token:(NSData *)token {
    NSMutableDictionary<NSNumber *, NSData *> *fields = [NSMutableDictionary dictionary];
    fields[@(SZFriendsSignalTagMinorMin)] = SZFriendsSignalBigEndian(0, 2);
    fields[@(SZFriendsSignalTagMinorMax)] = SZFriendsSignalBigEndian(SZFriendsSignalMinor, 2);
    if (_pattern == SZFriendsHandshakeIK) {
        fields[@(SZFriendsSignalTagCertificate)] = _identity.staticCertificate;
        if (_localAttestation) fields[@(SZFriendsSignalTagAttestation)] = _localAttestation;
        if (now) fields[@(SZFriendsSignalTagTime)] = SZFriendsSignalBigEndian((uint64_t)now.timeIntervalSince1970, 8);
        if (token) fields[@(SZFriendsSignalTagToken)] = token;
    }
    return [SZFriendsSignalItem itemWithType:SZFriendsSignalItemHello fields:fields];
}

// Checks the Hello that opens `items` and returns the rest; nil after failing the session.
- (NSArray<SZFriendsSignalItem *> *)acceptHelloIn:(NSArray<SZFriendsSignalItem *> *)items
                                              now:(NSDate *)now
                                            error:(NSError **)error {
    SZFriendsSignalItem *hello = items.firstObject;
    uint64_t minorMin = 0, minorMax = 0;
    if (hello.type != SZFriendsSignalItemHello || ![hello getUnsigned:&minorMin forTag:SZFriendsSignalTagMinorMin] ||
        ![hello getUnsigned:&minorMax forTag:SZFriendsSignalTagMinorMax] || minorMin > minorMax ||
        minorMin > SZFriendsSignalMinor) {
        [self failWith:error code:SZFriendsSessionErrorHandshakeFailed reason:@"no usable Hello"];
        return nil;
    }
    _negotiatedMinor = (uint16_t)MIN(minorMax, (uint64_t)SZFriendsSignalMinor);
    if (_pattern == SZFriendsHandshakeIK) {
        const uint8_t *remote = szfriends_handshake_remote_static(&_handshake);
        NSData *staticKey = remote ? [NSData dataWithBytes:remote length:SZFRIENDS_NOISE_DHLEN] : nil;
        NSData *certificate = [hello dataForTag:SZFriendsSignalTagCertificate];
        NSData *identityKey = staticKey && certificate ? SZFriendsIdentityKeyFromCertificate(certificate, staticKey)
                                                       : nil;
        if (identityKey.length != 32) {
            [self failWith:error code:SZFriendsSessionErrorHandshakeFailed reason:@"certificate does not bind"];
            return nil;
        }
        if (_isInitiator && ![identityKey isEqualToData:_expectedIdentityKey]) {
            [self failWith:error code:SZFriendsSessionErrorHandshakeFailed reason:@"not the identity dialled"];
            return nil;
        }
        uint64_t sent = 0;
        if (!_isInitiator && (![hello getUnsigned:&sent forTag:SZFriendsSignalTagTime] ||
                              fabs((double)sent - now.timeIntervalSince1970) > SZFriendsSignalClockSkewMax)) {
            [self failWith:error code:SZFriendsSessionErrorHandshakeFailed reason:@"message 1 is not current"];
            return nil;
        }
        _remoteIdentityKey = identityKey;
        _remoteStaticKey = staticKey;
        _remoteCertificate = certificate;
        _remoteAttestation = [hello dataForTag:SZFriendsSignalTagAttestation];
        if (!_isInitiator) _presentedRequestToken = [hello dataForTag:SZFriendsSignalTagToken];
    }
    return [items subarrayWithRange:NSMakeRange(1, items.count - 1)];
}

#pragma mark - Handshake messages

- (NSData *)writeHandshakeItems:(NSArray<SZFriendsSignalItem *> *)items
                         header:(BOOL)header
                          error:(NSError **)error {
    int overhead = szfriends_handshake_overhead(&_handshake);
    NSUInteger prefix = header ? SZFriendsSignalHeaderLength : 0;
    if (_dead || overhead < 0 || !szfriends_handshake_is_write_turn(&_handshake)) {
        [self failWith:error code:SZFriendsSessionErrorProtocol reason:@"not this side's handshake message"];
        return nil;
    }
    NSData *plaintext = SZFriendsEncodeSignalItems(items, SZFriendsSignalPayloadMax - prefix - (NSUInteger)overhead,
                                                   error);
    if (plaintext == nil) {
        [self die];
        return nil;
    }
    NSMutableData *output = [NSMutableData dataWithLength:prefix + (NSUInteger)overhead + plaintext.length];
    uint8_t *bytes = output.mutableBytes;
    if (header) {
        bytes[0] = SZFriendsSignalHeaderMagic;
        bytes[1] = (uint8_t)_pattern;
    }
    size_t written = 0;
    if (szfriends_handshake_write(&_handshake, plaintext.bytes, plaintext.length, bytes + prefix,
                                  output.length - prefix, &written) != SZFRIENDS_NOISE_OK) {
        [self failWith:error code:SZFriendsSessionErrorHandshakeFailed reason:@"handshake message not written"];
        return nil;
    }
    output.length = prefix + written;
    return output;
}

- (NSArray<SZFriendsSignalItem *> *)readHandshake:(const uint8_t *)bytes length:(NSUInteger)length
                                            error:(NSError **)error {
    NSMutableData *plaintext = [NSMutableData dataWithLength:length];
    size_t plaintextLength = 0;
    if (_dead || szfriends_handshake_read(&_handshake, bytes, length, plaintext.mutableBytes, plaintext.length,
                                          &plaintextLength) != SZFRIENDS_NOISE_OK) {
        [self failWith:error code:SZFriendsSessionErrorHandshakeFailed reason:@"handshake message did not open"];
        return nil;
    }
    plaintext.length = plaintextLength;
    NSArray *items = SZFriendsDecodeSignalItems(plaintext, NULL);
    if (items == nil) [self failWith:error code:SZFriendsSessionErrorHandshakeFailed reason:@"payload does not parse"];
    return items;
}

- (BOOL)finish:(NSError **)error {
    uint8_t hash[SZFRIENDS_NOISE_HASHLEN];
    szfriends_handshake_hash(&_handshake, hash);
    _handshakeHash = [NSData dataWithBytes:hash length:sizeof hash];
    sodium_memzero(hash, sizeof hash);
    int result = szfriends_handshake_split(&_handshake, &_send, &_receive);
    szfriends_handshake_clear(&_handshake);
    if (result != SZFRIENDS_NOISE_OK) return [self failWith:error code:SZFriendsSessionErrorHandshakeFailed
                                                     reason:@"split failed"];
    _established = YES;
    return YES;
}

- (NSData *)openingMessageWithItems:(NSArray<SZFriendsSignalItem *> *)items now:(NSDate *)now error:(NSError **)error {
    if (!_isInitiator || _wroteOrReadMessage1 || (_pattern == SZFriendsHandshakeNN && items.count > 0)) {
        [self failWith:error code:SZFriendsSessionErrorProtocol reason:@"message 1 out of place"];
        return nil;
    }
    _wroteOrReadMessage1 = YES;
    NSArray *all = [@[ [self helloWithTime:now token:_requestToken] ] arrayByAddingObjectsFromArray:items];
    return [self writeHandshakeItems:all header:YES error:error];
}

+ (instancetype)responderForMessage:(NSData *)message
                           identity:(SZFriendsIdentity *)identity
                            allowed:(NSArray<NSNumber *> *)allowedPatterns
                        replayCache:(SZFriendsReplayCache *)replayCache
                          keyPolicy:(SZFriendsRemoteKeyPolicy)keyPolicy
                                now:(NSDate *)now
                              items:(NSArray<SZFriendsSignalItem *> **)items
                              error:(NSError **)error {
    *items = nil;
    const uint8_t *bytes = message.bytes;
    NSUInteger prefix = SZFriendsSignalHeaderLength;
    if (message.length < prefix + SZFRIENDS_NOISE_DHLEN || message.length > SZFriendsSignalPayloadMax ||
        bytes[0] != SZFriendsSignalHeaderMagic ||
        (bytes[1] != SZFriendsHandshakeIK && bytes[1] != SZFriendsHandshakeNN)) {
        if (error) *error = SZFriendsSignalError(SZFriendsSessionErrorHandshakeFailed, @"not a signalling message 1");
        return nil;
    }
    SZFriendsHandshakePattern pattern = bytes[1];
    if (![allowedPatterns containsObject:@(pattern)]) {
        if (error) *error = SZFriendsSignalError(SZFriendsSessionErrorRejected, @"pattern not taken here");
        return nil;
    }
    SZFriendsSignalingSession *session = [[self alloc] initWithPattern:pattern
                                                            initiator:NO
                                                             identity:identity
                                                      remoteStaticKey:nil];
    if (session == nil) {
        if (error) *error = SZFriendsSignalError(SZFriendsSessionErrorHandshakeFailed, @"handshake could not start");
        return nil;
    }
    session->_wroteOrReadMessage1 = YES;
    NSArray *read = [session readHandshake:bytes + prefix length:message.length - prefix error:error];
    NSArray *rest = read ? [session acceptHelloIn:read now:now error:error] : nil;
    if (rest == nil) return nil;
    // NN message 1 is plaintext: anything in it beside the Hello is unauthenticated and unencrypted, so it is refused.
    if (pattern == SZFriendsHandshakeNN && rest.count > 0) {
        [session failWith:error code:SZFriendsSessionErrorHandshakeFailed reason:@"NN message 1 carries items"];
        return nil;
    }
    BOOL allowed = keyPolicy ? keyPolicy(session.remoteIdentityKey, pattern, session.presentedRequestToken) : NO;
    if (!allowed) {
        [session failWith:error code:SZFriendsSessionErrorRejected reason:@"the key policy refused the caller"];
        return nil;
    }
    // Only now, after decryption and the policy (Noise § 7.7): junk and strangers never enter the cache, so they
    // cannot evict a friend's message 1 and replay it. A replay reaches the pure policy again, then stops here.
    if (![replayCache recordEphemeralKey:[NSData dataWithBytes:bytes + prefix length:SZFRIENDS_NOISE_DHLEN]]) {
        [session failWith:error code:SZFriendsSessionErrorReplayed reason:@"message 1 repeats an ephemeral key"];
        return nil;
    }
    *items = rest;
    return session;
}

- (NSData *)replyWithItems:(NSArray<SZFriendsSignalItem *> *)items error:(NSError **)error {
    if (_isInitiator || !_wroteOrReadMessage1 || _established) {
        [self failWith:error code:SZFriendsSessionErrorProtocol reason:@"message 2 out of place"];
        return nil;
    }
    NSArray *all = [@[ [self helloWithTime:nil token:nil] ] arrayByAddingObjectsFromArray:items];
    NSData *message = [self writeHandshakeItems:all header:NO error:error];
    return message && [self finish:error] ? message : nil;
}

- (NSArray<SZFriendsSignalItem *> *)readReply:(NSData *)message error:(NSError **)error {
    if (!_isInitiator || !_wroteOrReadMessage1 || _established || _dead) {
        [self failWith:error code:SZFriendsSessionErrorProtocol reason:@"message 2 out of place"];
        return nil;
    }
    NSArray *read = [self readHandshake:message.bytes length:message.length error:error];
    NSArray *rest = read ? [self acceptHelloIn:read now:nil error:error] : nil;
    return rest && [self finish:error] ? rest : nil;
}

#pragma mark - Transport

- (NSData *)sealItems:(NSArray<SZFriendsSignalItem *> *)items error:(NSError **)error {
    if (!_established || _dead) {
        [self failWith:error code:SZFriendsSessionErrorProtocol reason:@"not established"];
        return nil;
    }
    NSData *plaintext = SZFriendsEncodeSignalItems(items, SZFriendsSignalPayloadMax - SZFRIENDS_NOISE_TAGLEN, error);
    if (plaintext == nil) return nil; // nothing was encrypted: the session stays usable
    NSMutableData *output = [NSMutableData dataWithLength:plaintext.length + SZFRIENDS_NOISE_TAGLEN];
    size_t written = 0;
    if (szfriends_cipher_encrypt(&_send, NULL, 0, plaintext.bytes, plaintext.length, output.mutableBytes,
                                 output.length, &written) != SZFRIENDS_NOISE_OK) {
        [self failWith:error code:SZFriendsSessionErrorExpired reason:@"out of nonces"];
        return nil;
    }
    output.length = written;
    return output;
}

- (NSArray<SZFriendsSignalItem *> *)openPayload:(NSData *)payload error:(NSError **)error {
    if (!_established || _dead || payload.length <= SZFRIENDS_NOISE_TAGLEN ||
        payload.length > SZFriendsSignalPayloadMax) {
        [self failWith:error code:SZFriendsSessionErrorDecryptFailed reason:@"not an open payload here"];
        return nil;
    }
    NSMutableData *plaintext = [NSMutableData dataWithLength:payload.length];
    size_t length = 0;
    if (szfriends_cipher_decrypt(&_receive, NULL, 0, payload.bytes, payload.length, plaintext.mutableBytes,
                                 plaintext.length, &length) != SZFRIENDS_NOISE_OK) {
        [self failWith:error code:SZFriendsSessionErrorDecryptFailed reason:@"payload did not authenticate"];
        return nil;
    }
    plaintext.length = length;
    NSArray *items = SZFriendsDecodeSignalItems(plaintext, error);
    if (items == nil) [self die];
    return items;
}

- (NSData *)exportKeyWithLabel:(NSString *)label {
    NSData *labelBytes = [label dataUsingEncoding:NSUTF8StringEncoding];
    if (!_established || _handshakeHash.length != SZFRIENDS_NOISE_HASHLEN || labelBytes.length == 0) return nil;
    NSMutableData *output = [NSMutableData dataWithLength:32];
    crypto_generichash(output.mutableBytes, output.length, labelBytes.bytes, labelBytes.length, _handshakeHash.bytes,
                       _handshakeHash.length);
    return output;
}

@end
