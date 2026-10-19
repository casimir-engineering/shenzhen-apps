// Keys, setup payloads, records and metadata of a download link (SZFriendsLinkWire.h). Byte for byte what the link
// pages do in WebCrypto (portable/server/friends/src/pages/script/link-crypto.js and receiver.js).

#import "service/links/SZFriendsLinkWire.h"

#import <sodium.h>

const NSUInteger SZFriendsLinkNonceLength = 16;
const NSUInteger SZFriendsLinkRecordMax = 65536;
const NSUInteger SZFriendsLinkChunkBytes = 65280;
const NSUInteger SZFriendsLinkCreditMax = 1024;

static const char SZFriendsLinkSetupLabel[] = "SZFriends link setup v1";
static const char SZFriendsLinkProofLabel[] = "SZFriends link proof v1";
static const char SZFriendsLinkSessionLabel[] = "SZFriends link session v1";
static const char SZFriendsLinkContentLabel[] = "SZFriends link content v1";
static const char SZFriendsLinkRecordLabel[] = "SZFriends link record v1";
static const NSUInteger SZFriendsLinkIVBytes = crypto_aead_aes256gcm_NPUBBYTES; // 12
static const NSUInteger SZFriendsLinkTagBytes = crypto_aead_aes256gcm_ABYTES;   // 16

static NSData *SZFriendsLinkBytes(const char *text) {
    return [NSData dataWithBytes:text length:strlen(text)];
}

// HKDF-SHA-256 (RFC 5869), 32 bytes: WebCrypto's deriveBits({name: "HKDF", hash: "SHA-256", salt, info}, 256).
static NSMutableData *SZFriendsLinkHKDF(NSData *secret, NSData *salt, NSData *info) {
    uint8_t prk[crypto_kdf_hkdf_sha256_KEYBYTES];
    crypto_kdf_hkdf_sha256_extract(prk, salt.bytes, salt.length, secret.bytes, secret.length);
    NSMutableData *key = [NSMutableData dataWithLength:32];
    crypto_kdf_hkdf_sha256_expand(key.mutableBytes, key.length, info.bytes, info.length, prk);
    sodium_memzero(prk, sizeof prk);
    return key;
}

static NSData *SZFriendsLinkAESSeal(NSData *key, const uint8_t iv[12], NSData *ad, NSData *plaintext) {
    NSMutableData *out = [NSMutableData dataWithLength:plaintext.length + SZFriendsLinkTagBytes];
    unsigned long long written = 0;
    crypto_aead_aes256gcm_encrypt(out.mutableBytes, &written, plaintext.bytes, plaintext.length, ad.bytes, ad.length,
                                  NULL, iv, key.bytes);
    return out;
}

static NSData *SZFriendsLinkAESOpen(NSData *key, const uint8_t iv[12], NSData *ad, const uint8_t *sealed,
                                    NSUInteger length) {
    if (length < SZFriendsLinkTagBytes) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:length - SZFriendsLinkTagBytes];
    unsigned long long written = 0;
    if (crypto_aead_aes256gcm_decrypt(out.mutableBytes, &written, NULL, sealed, length, ad.bytes, ad.length, iv,
                                      key.bytes) != 0) {
        return nil;
    }
    out.length = (NSUInteger)written;
    return out;
}

@implementation SZFriendsLinkKeys {
    NSData *_secret;
    NSMutableData *_setupKey, *_proofKey, *_sessionKey;
    NSData *_openerNonce, *_senderNonce;
}

- (instancetype)initWithLinkID:(NSData *)linkID secret:(NSData *)secret {
    if (linkID.length != 16 || secret.length != 32 || !crypto_aead_aes256gcm_is_available()) return nil;
    if ((self = [super init])) {
        _linkID = [linkID copy];
        _secret = [secret copy];
        _setupKey = SZFriendsLinkHKDF(secret, linkID, SZFriendsLinkBytes(SZFriendsLinkSetupLabel));
        _proofKey = SZFriendsLinkHKDF(secret, linkID, SZFriendsLinkBytes(SZFriendsLinkProofLabel));
    }
    return self;
}

- (void)dealloc {
    for (NSMutableData *key in @[ _setupKey ?: [NSMutableData data], _proofKey ?: [NSMutableData data],
                                  _sessionKey ?: [NSMutableData data] ]) {
        sodium_memzero(key.mutableBytes, key.length);
    }
}

- (BOOL)hasSession {
    return _sessionKey != nil;
}

- (void)setOpenerNonce:(NSData *)openerNonce senderNonce:(NSData *)senderNonce {
    if (openerNonce.length != SZFriendsLinkNonceLength || senderNonce.length != SZFriendsLinkNonceLength) return;
    _openerNonce = [openerNonce copy];
    _senderNonce = [senderNonce copy];
    NSMutableData *salt = [openerNonce mutableCopy];
    [salt appendData:senderNonce];
    _sessionKey = SZFriendsLinkHKDF(_secret, salt, SZFriendsLinkBytes(SZFriendsLinkSessionLabel));
}

- (NSData *)setupAD:(SZFriendsLinkSide)side {
    NSMutableData *ad = [SZFriendsLinkBytes(SZFriendsLinkSetupLabel) mutableCopy];
    uint8_t from = side;
    [ad appendBytes:&from length:1];
    [ad appendData:_linkID];
    return ad;
}

- (NSData *)sealMessage:(NSDictionary<NSString *, id> *)message from:(SZFriendsLinkSide)side {
    if (![message[@"t"] isKindOfClass:[NSString class]]) return nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:NULL];
    if (json == nil) return nil;
    uint8_t iv[12];
    randombytes_buf(iv, sizeof iv);
    NSMutableData *out = [NSMutableData dataWithBytes:iv length:sizeof iv];
    [out appendData:SZFriendsLinkAESSeal(_sessionKey ?: _setupKey, iv, [self setupAD:side], json)];
    return out;
}

- (NSDictionary<NSString *, id> *)openPayload:(NSData *)payload from:(SZFriendsLinkSide)side {
    if (payload.length < SZFriendsLinkIVBytes + SZFriendsLinkTagBytes) return nil;
    const uint8_t *bytes = payload.bytes;
    NSData *plain = SZFriendsLinkAESOpen(_sessionKey ?: _setupKey, bytes, [self setupAD:side],
                                         bytes + SZFriendsLinkIVBytes, payload.length - SZFriendsLinkIVBytes);
    id object = plain ? [NSJSONSerialization JSONObjectWithData:plain options:0 error:NULL] : nil;
    if (![object isKindOfClass:[NSDictionary class]] || ![object[@"t"] isKindOfClass:[NSString class]]) return nil;
    return object;
}

- (NSData *)proof {
    if (_senderNonce == nil) return nil;
    crypto_auth_hmacsha256_state state;
    crypto_auth_hmacsha256_init(&state, _proofKey.bytes, _proofKey.length);
    crypto_auth_hmacsha256_update(&state, (const unsigned char *)SZFriendsLinkProofLabel,
                                  strlen(SZFriendsLinkProofLabel));
    crypto_auth_hmacsha256_update(&state, _linkID.bytes, _linkID.length);
    crypto_auth_hmacsha256_update(&state, _senderNonce.bytes, _senderNonce.length);
    crypto_auth_hmacsha256_update(&state, _openerNonce.bytes, _openerNonce.length);
    NSMutableData *mac = [NSMutableData dataWithLength:crypto_auth_hmacsha256_BYTES];
    crypto_auth_hmacsha256_final(&state, mac.mutableBytes);
    return mac;
}

- (BOOL)verifyProof:(NSData *)proof {
    NSData *expected = [self proof];
    return expected != nil && proof.length == expected.length &&
           sodium_memcmp(proof.bytes, expected.bytes, expected.length) == 0;
}

- (NSData *)contentKeyForAttempt:(uint8_t)attempt {
    if (_senderNonce == nil) return nil;
    NSMutableData *salt = [_openerNonce mutableCopy];
    [salt appendData:_senderNonce];
    NSMutableData *info = [SZFriendsLinkBytes(SZFriendsLinkContentLabel) mutableCopy];
    [info appendBytes:&attempt length:1];
    return SZFriendsLinkHKDF(_secret, salt, info);
}

@end

#pragma mark - Records

static void SZFriendsLinkRecordNonce(uint8_t nonce[12], uint8_t type, uint64_t index) {
    memset(nonce, 0, 12);
    nonce[0] = type;
    for (int i = 0; i < 8; i++) nonce[4 + i] = (uint8_t)(index >> (56 - 8 * i));
}

NSData *SZFriendsLinkSealRecord(NSData *contentKey, SZFriendsLinkRecordType type, uint64_t index,
                                NSData *plaintext) {
    if (contentKey.length != 32 || 1 + plaintext.length + SZFriendsLinkTagBytes > SZFriendsLinkRecordMax) return nil;
    uint8_t nonce[12];
    SZFriendsLinkRecordNonce(nonce, type, index);
    uint8_t byte = type;
    NSMutableData *record = [NSMutableData dataWithBytes:&byte length:1];
    [record appendData:SZFriendsLinkAESSeal(contentKey, nonce, SZFriendsLinkBytes(SZFriendsLinkRecordLabel),
                                            plaintext)];
    return record;
}

NSData *SZFriendsLinkOpenRecord(NSData *contentKey, NSArray<NSNumber *> *types, uint64_t index, NSData *record,
                                SZFriendsLinkRecordType *type) {
    const uint8_t *bytes = record.bytes;
    if (contentKey.length != 32 || record.length < 1 + SZFriendsLinkTagBytes ||
        record.length > SZFriendsLinkRecordMax || ![types containsObject:@(bytes[0])]) {
        return nil;
    }
    uint8_t nonce[12];
    SZFriendsLinkRecordNonce(nonce, bytes[0], index);
    NSData *plain = SZFriendsLinkAESOpen(contentKey, nonce, SZFriendsLinkBytes(SZFriendsLinkRecordLabel), bytes + 1,
                                         record.length - 1);
    if (plain && type) *type = (SZFriendsLinkRecordType)bytes[0];
    return plain;
}

#pragma mark - Metadata

static void SZFriendsLinkAppendText(NSMutableData *bytes, NSString *text) {
    NSData *utf8 = [text ?: @"" dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    uint32_t length = CFSwapInt32HostToBig((uint32_t)utf8.length);
    [bytes appendBytes:&length length:4];
    [bytes appendData:utf8];
}

static NSString *SZFriendsLinkText(id value, NSUInteger maxCharacters) {
    if (![value isKindOfClass:[NSString class]] || [value length] > maxCharacters) return nil;
    return [value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location == NSNotFound ? value : nil;
}

static NSData *SZFriendsLinkDecodedField(NSDictionary *object, NSString *key, NSUInteger length) {
    id value = object[key];
    NSData *data = [value isKindOfClass:[NSString class]] ? SZFriendsLinkBase64URLDecode(value) : nil;
    return data.length == length ? data : nil;
}

static const uint8_t SZFriendsLinkPNGSignature[8] = {0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a};

@implementation SZFriendsLinkMetadata

- (NSData *)signedBytesForLinkID:(NSData *)linkID {
    NSMutableData *bytes = [linkID mutableCopy];
    [bytes appendData:self.sha256 ?: [NSData data]];
    [bytes appendData:self.blake2b ?: [NSData data]];
    uint64_t size = CFSwapInt64HostToBig(self.size);
    [bytes appendBytes:&size length:8];
    SZFriendsLinkAppendText(bytes, self.name);
    SZFriendsLinkAppendText(bytes, self.senderFriendsID);
    SZFriendsLinkAppendText(bytes, self.senderName);
    return bytes;
}

- (NSData *)plaintextWithThumbnail:(BOOL)thumbnail {
    NSMutableDictionary *object = [@{
        @"name" : self.name ?: @"", @"size" : @(self.size),
        @"type" : self.mediaType.length ? self.mediaType : @"application/octet-stream",
        @"sha256" : SZFriendsLinkBase64URLEncode(self.sha256 ?: [NSData data]), @"sender" : self.senderName ?: @"",
    } mutableCopy];
    if (self.senderIdentityKey.length == 32 && self.blake2b.length == 32 && self.senderSignature.length == 64) {
        object[@"from"] = @{
            @"identity_key" : SZFriendsLinkBase64URLEncode(self.senderIdentityKey),
            @"friends_id" : self.senderFriendsID ?: @"", @"blake2b" : SZFriendsLinkBase64URLEncode(self.blake2b),
            @"sig" : SZFriendsLinkBase64URLEncode(self.senderSignature),
        };
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    uint32_t length = CFSwapInt32HostToBig((uint32_t)json.length);
    NSMutableData *plain = [NSMutableData dataWithBytes:&length length:4];
    [plain appendData:json];
    if (thumbnail && self.thumbnailPNG) [plain appendData:self.thumbnailPNG];
    return plain;
}

- (NSData *)recordPlaintext {
    NSUInteger room = SZFriendsLinkRecordMax - 1 - SZFriendsLinkTagBytes;
    NSData *plain = [self plaintextWithThumbnail:YES];
    if (plain.length > room) plain = [self plaintextWithThumbnail:NO];
    return plain.length <= room ? plain : nil;
}

+ (instancetype)metadataFromRecordPlaintext:(NSData *)plaintext {
    if (plaintext.length < 4) return nil;
    uint32_t length = 0;
    memcpy(&length, plaintext.bytes, 4);
    length = CFSwapInt32BigToHost(length);
    if ((uint64_t)length + 4 > plaintext.length) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:[plaintext subdataWithRange:NSMakeRange(4, length)] options:0
                                                  error:NULL];
    if (![object isKindOfClass:[NSDictionary class]]) return nil;
    SZFriendsLinkMetadata *metadata = [[SZFriendsLinkMetadata alloc] init];
    metadata.name = SZFriendsLinkText(object[@"name"], 255);
    metadata.mediaType = SZFriendsLinkText(object[@"type"] ?: @"application/octet-stream", 255);
    metadata.sha256 = SZFriendsLinkDecodedField(object, @"sha256", 32);
    metadata.senderName = SZFriendsLinkText(object[@"sender"] ?: @"", 160);
    id size = object[@"size"];
    BOOL integer = [size isKindOfClass:[NSNumber class]] && !CFNumberIsFloatType((__bridge CFNumberRef)size) &&
                   strcmp([size objCType], @encode(char)) != 0 && [size longLongValue] >= 0 &&
                   [size longLongValue] <= (1LL << 53) - 1;
    if (metadata.name.length == 0 || metadata.mediaType == nil || metadata.sha256 == nil || !integer ||
        metadata.senderName == nil) {
        return nil;
    }
    metadata.size = [size unsignedLongLongValue];
    NSData *rest = [plaintext subdataWithRange:NSMakeRange(4 + length, plaintext.length - 4 - length)];
    if (rest.length > sizeof SZFriendsLinkPNGSignature &&
        memcmp(rest.bytes, SZFriendsLinkPNGSignature, sizeof SZFriendsLinkPNGSignature) == 0) {
        metadata.thumbnailPNG = rest;
    }
    NSDictionary *from = [object[@"from"] isKindOfClass:[NSDictionary class]] ? object[@"from"] : nil;
    if (from) {
        metadata.senderIdentityKey = SZFriendsLinkDecodedField(from, @"identity_key", 32);
        metadata.blake2b = SZFriendsLinkDecodedField(from, @"blake2b", 32);
        metadata.senderSignature = SZFriendsLinkDecodedField(from, @"sig", 64);
        metadata.senderFriendsID = SZFriendsLinkText(from[@"friends_id"], 64);
    }
    return metadata;
}

@end
