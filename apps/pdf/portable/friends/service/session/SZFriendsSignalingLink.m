// Download-link signalling (SZFriendsSignaling.h; friends-links.md § Signalling; ADR 0010 § Download links): the
// payloads between whoever opens a link (a browser, or an app's helper) and the sender's helper, sealed under keys
// derived from the link secret with primitives WebCrypto has, so the browser page can implement the same bytes.
// The sender reveals nothing and creates no peer connection until the opener has proved the secret over a fresh
// challenge (ADR 0009 § Who may reach the stack).

#import "service/session/SZFriendsSignaling.h"

#import <sodium.h>

#import "service/session/SZFriendsFrameSchema.h"

const NSUInteger SZFriendsLinkIDLength = 16;
const NSUInteger SZFriendsLinkSecretLength = 32;

static const char SZFriendsLinkSealLabel[] = "SZFriends link seal v1";
static const char SZFriendsLinkProofLabel[] = "SZFriends link proof v1";
static const char SZFriendsLinkExportLabel[] = "SZFriends link export v1";
static const NSUInteger SZFriendsLinkNonceBytes = crypto_aead_aes256gcm_NPUBBYTES; // 12
static const NSUInteger SZFriendsLinkTagBytes = crypto_aead_aes256gcm_ABYTES;      // 16
static const uint8_t SZFriendsLinkFromOpener = 1, SZFriendsLinkFromSender = 2;

static NSError *SZFriendsLinkError(SZFriendsSessionError code, NSString *reason) {
    return SZFriendsSessionMakeError(code, reason);
}

// HKDF-SHA-256 (RFC 5869) with the link id as salt: WebCrypto's deriveBits({name: "HKDF", hash: "SHA-256", salt,
// info}) gives the same 32 bytes.
static NSMutableData *SZFriendsLinkKey(NSData *secret, NSData *linkID, const char *info) {
    uint8_t prk[crypto_kdf_hkdf_sha256_KEYBYTES];
    crypto_kdf_hkdf_sha256_extract(prk, linkID.bytes, linkID.length, secret.bytes, secret.length);
    NSMutableData *key = [NSMutableData dataWithLength:32];
    crypto_kdf_hkdf_sha256_expand(key.mutableBytes, key.length, info, strlen(info), prk);
    sodium_memzero(prk, sizeof prk);
    return key;
}

static NSData *SZFriendsLinkHMAC(NSData *key, NSArray<NSData *> *parts) {
    crypto_auth_hmacsha256_state state;
    crypto_auth_hmacsha256_init(&state, key.bytes, key.length);
    for (NSData *part in parts) crypto_auth_hmacsha256_update(&state, part.bytes, part.length);
    NSMutableData *mac = [NSMutableData dataWithLength:crypto_auth_hmacsha256_BYTES];
    crypto_auth_hmacsha256_final(&state, mac.mutableBytes);
    return mac;
}

static NSData *SZFriendsLinkBytes(const char *text) {
    return [NSData dataWithBytes:text length:strlen(text)];
}

@implementation SZFriendsSignalingLink {
    NSData *_linkID;
    NSMutableData *_sealKey;
    NSMutableData *_proofKey;
    NSData *_nonce;
    NSData *_challenge;
    uint32_t _sent;
    uint32_t _received;
    BOOL _dead;
}

- (instancetype)initAsOpener:(BOOL)opener linkID:(NSData *)linkID secret:(NSData *)secret {
    if (linkID.length != SZFriendsLinkIDLength || secret.length != SZFriendsLinkSecretLength ||
        !crypto_aead_aes256gcm_is_available()) {
        return nil;
    }
    if ((self = [super init])) {
        _isOpener = opener;
        _linkID = [linkID copy];
        _sealKey = SZFriendsLinkKey(secret, linkID, SZFriendsLinkSealLabel);
        _proofKey = SZFriendsLinkKey(secret, linkID, SZFriendsLinkProofLabel);
    }
    return self;
}

- (void)dealloc {
    sodium_memzero(_sealKey.mutableBytes, _sealKey.length);
    sodium_memzero(_proofKey.mutableBytes, _proofKey.length);
}

// Opening something that breaks the exchange ends it; asking to seal out of order only refuses that payload.
- (BOOL)failWith:(NSError **)error code:(SZFriendsSessionError)code reason:(NSString *)reason {
    _dead = YES;
    return [self refuse:error code:code reason:reason];
}

- (BOOL)refuse:(NSError **)error code:(SZFriendsSessionError)code reason:(NSString *)reason {
    if (error) *error = SZFriendsLinkError(code, reason);
    return NO;
}

- (NSData *)proof {
    return SZFriendsLinkHMAC(_proofKey, @[ SZFriendsLinkBytes(SZFriendsLinkProofLabel), _linkID, _nonce, _challenge ]);
}

// The associated data of the `count`th payload from `direction`: the label, where it goes, its place, and what this
// exchange has agreed so far (the opener's first payload is the only one bound to nothing fresh).
- (NSData *)adForDirection:(uint8_t)direction count:(uint32_t)count {
    NSMutableData *ad = [SZFriendsLinkBytes(SZFriendsLinkSealLabel) mutableCopy];
    uint8_t place[5] = {direction, (uint8_t)(count >> 24), (uint8_t)(count >> 16), (uint8_t)(count >> 8),
                        (uint8_t)count};
    [ad appendBytes:place length:sizeof place];
    BOOL first = count == 0;
    if (direction == SZFriendsLinkFromSender || !first) [ad appendData:_nonce];
    if (!first) [ad appendData:_challenge];
    return ad;
}

- (NSData *)sealItems:(NSArray<SZFriendsSignalItem *> *)items error:(NSError **)error {
    if (_dead) {
        [self refuse:error code:SZFriendsSessionErrorProtocol reason:@"the exchange has failed"];
        return nil;
    }
    SZFriendsSignalItem *own = nil;
    if (_isOpener && _sent == 0) {
        NSMutableData *nonce = [NSMutableData dataWithLength:32];
        randombytes_buf(nonce.mutableBytes, nonce.length);
        _nonce = nonce;
        own = [SZFriendsSignalItem itemWithType:SZFriendsSignalItemLinkNonce
                                         fields:@{@(SZFriendsSignalTagNonce) : nonce}];
    } else if (_isOpener && _challenge == nil) {
        [self refuse:error code:SZFriendsSessionErrorProtocol reason:@"no challenge yet"];
        return nil;
    } else if (_isOpener && _sent == 1) {
        own = [SZFriendsSignalItem itemWithType:SZFriendsSignalItemLinkProof
                                         fields:@{@(SZFriendsSignalTagProof) : [self proof]}];
    } else if (!_isOpener && _sent == 0 && _nonce != nil) {
        NSMutableData *challenge = [NSMutableData dataWithLength:32];
        randombytes_buf(challenge.mutableBytes, challenge.length);
        _challenge = challenge;
        own = [SZFriendsSignalItem itemWithType:SZFriendsSignalItemLinkChallenge
                                         fields:@{@(SZFriendsSignalTagNonce) : challenge}];
    } else if (!_isOpener && !_proven) {
        // Gating: until the proof, the sender's only payload is its challenge.
        [self refuse:error code:SZFriendsSessionErrorProtocol reason:@"the opener has not proved the secret"];
        return nil;
    }
    NSArray *all = own ? [@[ own ] arrayByAddingObjectsFromArray:items] : items;
    NSData *plaintext = SZFriendsEncodeSignalItems(
        all, SZFriendsSignalPayloadMax - SZFriendsLinkNonceBytes - SZFriendsLinkTagBytes, error);
    if (plaintext == nil) return nil;
    uint8_t direction = _isOpener ? SZFriendsLinkFromOpener : SZFriendsLinkFromSender;
    NSData *ad = [self adForDirection:direction count:_sent];
    NSMutableData *output = [NSMutableData dataWithLength:SZFriendsLinkNonceBytes + plaintext.length +
                                                          SZFriendsLinkTagBytes];
    uint8_t *bytes = output.mutableBytes;
    randombytes_buf(bytes, SZFriendsLinkNonceBytes);
    unsigned long long written = 0;
    crypto_aead_aes256gcm_encrypt(bytes + SZFriendsLinkNonceBytes, &written, plaintext.bytes, plaintext.length,
                                  ad.bytes, ad.length, NULL, bytes, _sealKey.bytes);
    _sent += 1;
    return output;
}

- (NSArray<SZFriendsSignalItem *> *)openPayload:(NSData *)payload error:(NSError **)error {
    uint8_t direction = _isOpener ? SZFriendsLinkFromSender : SZFriendsLinkFromOpener;
    BOOL contextKnown = direction == SZFriendsLinkFromOpener ? (_received == 0 || _challenge != nil)
                                                             : (_nonce != nil && (_received == 0 || _challenge));
    if (_dead || !contextKnown || payload.length <= SZFriendsLinkNonceBytes + SZFriendsLinkTagBytes ||
        payload.length > SZFriendsSignalPayloadMax) {
        [self failWith:error code:SZFriendsSessionErrorDecryptFailed reason:@"not a payload for this exchange now"];
        return nil;
    }
    NSData *ad = [self adForDirection:direction count:_received];
    const uint8_t *bytes = payload.bytes;
    NSMutableData *plaintext = [NSMutableData dataWithLength:payload.length];
    unsigned long long length = 0;
    if (crypto_aead_aes256gcm_decrypt(plaintext.mutableBytes, &length, NULL, bytes + SZFriendsLinkNonceBytes,
                                      payload.length - SZFriendsLinkNonceBytes, ad.bytes, ad.length, bytes,
                                      _sealKey.bytes) != 0) {
        [self failWith:error code:SZFriendsSessionErrorDecryptFailed reason:@"payload did not open"];
        return nil;
    }
    plaintext.length = (NSUInteger)length;
    NSArray<SZFriendsSignalItem *> *items = SZFriendsDecodeSignalItems(plaintext, error);
    if (items == nil) {
        _dead = YES;
        return nil;
    }
    SZFriendsSignalItemType expected = 0;
    if (!_isOpener && _received == 0) expected = SZFriendsSignalItemLinkNonce;
    if (!_isOpener && _received == 1) expected = SZFriendsSignalItemLinkProof;
    if (_isOpener && _received == 0) expected = SZFriendsSignalItemLinkChallenge;
    if (expected != 0) {
        SZFriendsSignalItem *first = items.firstObject;
        if (first.type != expected) {
            [self failWith:error code:SZFriendsSessionErrorHandshakeFailed reason:@"payload out of order"];
            return nil;
        }
        if (expected == SZFriendsSignalItemLinkNonce) _nonce = [first dataForTag:SZFriendsSignalTagNonce];
        if (expected == SZFriendsSignalItemLinkChallenge) _challenge = [first dataForTag:SZFriendsSignalTagNonce];
        if (expected == SZFriendsSignalItemLinkProof) {
            NSData *proof = [first dataForTag:SZFriendsSignalTagProof];
            if (sodium_memcmp(proof.bytes, [self proof].bytes, crypto_auth_hmacsha256_BYTES) != 0) {
                [self failWith:error code:SZFriendsSessionErrorRejected reason:@"the link secret was not proved"];
                return nil;
            }
            _proven = YES;
        }
        items = [items subarrayWithRange:NSMakeRange(1, items.count - 1)];
    }
    _received += 1;
    return items;
}

- (NSData *)exportKeyWithLabel:(NSString *)label {
    NSData *labelBytes = [label dataUsingEncoding:NSUTF8StringEncoding];
    if (_nonce == nil || _challenge == nil || labelBytes.length == 0) return nil;
    return SZFriendsLinkHMAC(_proofKey,
                             @[ SZFriendsLinkBytes(SZFriendsLinkExportLabel), labelBytes, _nonce, _challenge ]);
}

@end
