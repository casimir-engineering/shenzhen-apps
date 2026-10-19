// The identity keys: generation, the static-key certificate, domain-separated signatures and the identity hash.

#import "service/identity/SZFriendsIdentityInternal.h"

#include <sodium.h>

static NSString *const SZFriendsStaticCertificateDomain = @"SZFriends static v1";
static NSString *const SZFriendsIdentityHashDomain = @"SZFriends identity hash v1";
static const uint8_t SZFriendsSecretMagic[4] = {'S', 'Z', 'F', 'I'};
static const uint8_t SZFriendsSecretVersion = 1;

// Secrets live in sodium_malloc memory: guard pages around it, locked out of swap, zeroed by sodium_free. Kept
// read-only after setup, so a stray write through a bad pointer faults instead of silently changing a key.
typedef struct {
    unsigned char signingSeed[crypto_sign_SEEDBYTES];
    unsigned char signingSecret[crypto_sign_SECRETKEYBYTES];
    unsigned char staticSecret[crypto_scalarmult_SCALARBYTES];
} SZFriendsIdentitySecrets;

// X25519 private keys are kept in the one form RFC 7748 § 5 clamps them to, as X25519 uses them anyway. WHY:
// clamping ignores four bits, so a flip there would load as the same public key from different stored bytes; with
// the stored form fixed, any damaged bit is caught on load (identityFromSecret:).
static void SZFClamp(unsigned char key[crypto_scalarmult_SCALARBYTES]) {
    key[0] &= 248;
    key[31] &= 127;
    key[31] |= 64;
}

NSArray<NSString *> *SZFriendsSignatureDomains(void) {
    // The host's check-in and release domains are defined in service/host; they are repeated here because this list
    // is what every signature is checked against, and the identity area may not include the host's private header.
    return @[ SZFriendsStaticCertificateDomain, @"SZFriends request v1", @"SZFriends checkin v1",
              @"SZFriends release v1", @"SZFriends link sender v1", @"SZFriends chain link v1",
              @"SZFriends device consent v1", @"SZFriends sync event v1" ];
}

// YES when `domain` and a listed domain differ but one starts with the other: the byte strings domain || message
// could then coincide across purposes. Equal domains are the same purpose and fine; unrelated ones (a test's "r")
// cannot collide with the list.
static BOOL SZFDomainCollides(NSString *domain) {
    for (NSString *listed in SZFriendsSignatureDomains()) {
        if ([domain isEqualToString:listed]) return NO;
        if ([domain hasPrefix:listed] || [listed hasPrefix:domain]) return YES;
    }
    return NO;
}

static NSData *SZFDomainPrefixed(NSString *domain, NSData *message) {
    if (domain.length == 0) {
        [NSException raise:NSInvalidArgumentException format:@"Friends signatures need a non-empty domain"];
    }
    NSMutableData *input = [[domain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [input appendData:message];
    return input;
}

NSData *_Nullable SZFriendsIdentityHash(NSData *publicKey) {
    if (publicKey.length != crypto_sign_PUBLICKEYBYTES) return nil;
    SZFriendsIdentityRequireSodium();
    NSData *input = SZFDomainPrefixed(SZFriendsIdentityHashDomain, publicKey);
    unsigned char hash[32];
    crypto_generichash(hash, sizeof hash, input.bytes, input.length, NULL, 0);
    return [NSData dataWithBytes:hash length:sizeof hash];
}

@implementation SZFriendsIdentity {
    SZFriendsIdentitySecrets *_secrets;
}

// Takes ownership of `secrets`, which must hold the seed and the static private key.
- (instancetype)initWithSecrets:(SZFriendsIdentitySecrets *)secrets {
    if ((self = [super init])) {
        _secrets = secrets;
        unsigned char signingPublic[crypto_sign_PUBLICKEYBYTES];
        unsigned char staticPublic[crypto_scalarmult_BYTES];
        crypto_sign_seed_keypair(signingPublic, _secrets->signingSecret, _secrets->signingSeed);
        crypto_scalarmult_base(staticPublic, _secrets->staticSecret);
        sodium_mprotect_readonly(_secrets);
        _publicKey = [NSData dataWithBytes:signingPublic length:sizeof signingPublic];
        _staticPublicKey = [NSData dataWithBytes:staticPublic length:sizeof staticPublic];
        NSMutableData *certificate = [_publicKey mutableCopy];
        [certificate appendData:[self signatureForMessage:_staticPublicKey domain:SZFriendsStaticCertificateDomain]];
        _staticCertificate = certificate;
        _identityHash = SZFriendsIdentityHash(_publicKey);
        const unsigned char *hash = _identityHash.bytes;
        _logFingerprint = [NSString stringWithFormat:@"%02x%02x%02x%02x", hash[0], hash[1], hash[2], hash[3]];
    }
    return self;
}

- (void)dealloc {
    if (_secrets != NULL) sodium_free(_secrets);
}

static SZFriendsIdentitySecrets *SZFAllocateSecrets(void) {
    SZFriendsIdentityRequireSodium();
    SZFriendsIdentitySecrets *secrets = sodium_malloc(sizeof *secrets);
    if (secrets == NULL) [NSException raise:NSMallocException format:@"No secure memory for a Friends identity"];
    return secrets;
}

+ (instancetype)generatedIdentity {
    SZFriendsIdentitySecrets *secrets = SZFAllocateSecrets();
    randombytes_buf(secrets->signingSeed, sizeof secrets->signingSeed);
    randombytes_buf(secrets->staticSecret, sizeof secrets->staticSecret);
    SZFClamp(secrets->staticSecret);
    return [[self alloc] initWithSecrets:secrets];
}

+ (nullable instancetype)identityWithSigningSeed:(NSData *)signingSeed staticPrivateKey:(NSData *)staticPrivateKey {
    if (signingSeed.length != crypto_sign_SEEDBYTES) return nil;
    if (staticPrivateKey.length != crypto_scalarmult_SCALARBYTES) return nil;
    SZFriendsIdentitySecrets *secrets = SZFAllocateSecrets();
    memcpy(secrets->signingSeed, signingSeed.bytes, sizeof secrets->signingSeed);
    memcpy(secrets->staticSecret, staticPrivateKey.bytes, sizeof secrets->staticSecret);
    return [[self alloc] initWithSecrets:secrets];
}

+ (nullable instancetype)identityFromSecret:(NSData *)secret error:(NSError **)error {
    const unsigned char *bytes = secret.bytes;
    if (secret.length != SZFriendsIdentitySecretLength || memcmp(bytes, SZFriendsSecretMagic, 4) != 0 ||
        bytes[4] != SZFriendsSecretVersion || (bytes[37] & 7) != 0 || (bytes[68] & 0xc0) != 0x40) {
        if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorCorrupt,
            @"The stored Friends key is not in a format this app reads.", nil);
        return nil;
    }
    SZFriendsIdentity *identity = [self identityWithSigningSeed:[NSData dataWithBytesNoCopy:(void *)(bytes + 5)
                                                                                     length:32 freeWhenDone:NO]
                                               staticPrivateKey:[NSData dataWithBytesNoCopy:(void *)(bytes + 37)
                                                                                     length:32 freeWhenDone:NO]];
    if (sodium_memcmp(identity.publicKey.bytes, bytes + 69, 32) != 0 ||
        sodium_memcmp(identity.staticPublicKey.bytes, bytes + 101, 32) != 0) {
        if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorCorrupt,
                                                       @"The stored Friends key is damaged.", nil);
        return nil;
    }
    return identity;
}

- (NSMutableData *)secretItem {
    NSMutableData *item = [NSMutableData dataWithCapacity:SZFriendsIdentitySecretLength];
    [item appendBytes:SZFriendsSecretMagic length:4];
    [item appendBytes:&SZFriendsSecretVersion length:1];
    [item appendBytes:_secrets->signingSeed length:sizeof _secrets->signingSeed];
    // Clamped like generated keys, so an identity built from unclamped test-vector keys also round-trips.
    unsigned char clamped[crypto_scalarmult_SCALARBYTES];
    memcpy(clamped, _secrets->staticSecret, sizeof clamped);
    SZFClamp(clamped);
    [item appendBytes:clamped length:sizeof clamped];
    sodium_memzero(clamped, sizeof clamped);
    [item appendData:_publicKey];
    [item appendData:_staticPublicKey];
    return item;
}

- (NSData *)signatureForMessage:(NSData *)message domain:(NSString *)domain {
    if (SZFDomainCollides(domain)) {
        [NSException raise:NSInvalidArgumentException format:@"A Friends signature domain collides by prefix"];
    }
    NSData *input = SZFDomainPrefixed(domain, message);
    unsigned char signature[crypto_sign_BYTES];
    crypto_sign_detached(signature, NULL, input.bytes, input.length, _secrets->signingSecret);
    return [NSData dataWithBytes:signature length:sizeof signature];
}

+ (BOOL)verifySignature:(NSData *)signature
             forMessage:(NSData *)message
                 domain:(NSString *)domain
              publicKey:(NSData *)publicKey {
    if (signature.length != crypto_sign_BYTES || publicKey.length != crypto_sign_PUBLICKEYBYTES) return NO;
    if (domain.length == 0 || SZFDomainCollides(domain)) return NO;
    SZFriendsIdentityRequireSodium();
    NSData *input = SZFDomainPrefixed(domain, message);
    // libsodium rejects non-canonical signatures and small-order keys here, so a malleated signature or a
    // degenerate key never verifies.
    return crypto_sign_verify_detached(signature.bytes, input.bytes, input.length, publicKey.bytes) == 0;
}

- (NSData *)staticPrivateKey {
    return [NSMutableData dataWithBytes:_secrets->staticSecret length:sizeof _secrets->staticSecret];
}

- (NSString *)description {
    // Never the keys: descriptions end up in logs.
    return [NSString stringWithFormat:@"<SZFriendsIdentity %@>", _logFingerprint];
}

@end

NSData *_Nullable SZFriendsIdentityKeyFromCertificate(NSData *certificate, NSData *staticPublicKey) {
    if (certificate.length != crypto_sign_PUBLICKEYBYTES + crypto_sign_BYTES) return nil;
    if (staticPublicKey.length != crypto_scalarmult_BYTES) return nil;
    NSData *identityKey = [certificate subdataWithRange:NSMakeRange(0, crypto_sign_PUBLICKEYBYTES)];
    NSData *signature = [certificate subdataWithRange:NSMakeRange(crypto_sign_PUBLICKEYBYTES, crypto_sign_BYTES)];
    BOOL valid = [SZFriendsIdentity verifySignature:signature
                                         forMessage:staticPublicKey
                                             domain:SZFriendsStaticCertificateDomain
                                          publicKey:identityKey];
    return valid ? identityKey : nil;
}
