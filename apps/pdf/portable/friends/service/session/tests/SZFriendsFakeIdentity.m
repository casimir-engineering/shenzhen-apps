// A stand-in for the identity area's SZFriendsIdentity, so the session suite builds against the header alone and
// never touches a key store. Same key shapes and certificate as the header specifies: an Ed25519 identity key, a
// separate X25519 static key, and cert = pk || Sig(sk, "SZFriends static v1" || staticPublicKey).

#import "SZFriendsSessionTestSupport.h"

#import <sodium.h>

// The identity header grows with its own area; the fake implements what sessions call plus what exists today, and a
// method added later fails loudly (unrecognized selector) if a session test ever reaches it, instead of breaking
// this suite's build until the fake catches up.
#pragma clang diagnostic ignored "-Wincomplete-implementation"

static NSString *const kStaticDomain = @"SZFriends static v1";

static NSData *SZFSignedMessage(NSString *domain, NSData *message) {
    NSMutableData *signedBytes = [[domain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [signedBytes appendData:message];
    return signedBytes;
}

@implementation SZFriendsIdentity {
    NSData *_signingSecret; // 64 bytes, libsodium's seed || public key form
    NSData *_staticSecret;  // 32 bytes
    NSData *_certificate;
}
@synthesize publicKey = _publicKey, staticPublicKey = _staticPublicKey, logFingerprint = _logFingerprint;
@synthesize identityHash = _identityHash;

- (instancetype)initWithSigningSeed:(NSData *)seed staticPrivateKey:(NSData *)staticPrivateKey {
    if ((self = [super init])) {
        uint8_t pk[crypto_sign_PUBLICKEYBYTES], sk[crypto_sign_SECRETKEYBYTES], xpk[32];
        crypto_sign_seed_keypair(pk, sk, seed.bytes);
        crypto_scalarmult_base(xpk, staticPrivateKey.bytes);
        _publicKey = [NSData dataWithBytes:pk length:sizeof pk];
        _signingSecret = [NSData dataWithBytes:sk length:sizeof sk];
        _staticSecret = [staticPrivateKey copy];
        _staticPublicKey = [NSData dataWithBytes:xpk length:sizeof xpk];
        static const char kHashDomain[] = "SZFriends identity hash v1";
        uint8_t hash[32];
        crypto_generichash_state state;
        crypto_generichash_init(&state, NULL, 0, sizeof hash);
        crypto_generichash_update(&state, (const uint8_t *)kHashDomain, sizeof kHashDomain - 1);
        crypto_generichash_update(&state, pk, sizeof pk);
        crypto_generichash_final(&state, hash, sizeof hash);
        _identityHash = [NSData dataWithBytes:hash length:sizeof hash];
        _logFingerprint = [SZFHexString(_identityHash) substringToIndex:8];
        _certificate = [self szf_certificateForStaticKey:_staticPublicKey];
        sodium_memzero(sk, sizeof sk);
    }
    return self;
}

+ (instancetype)szf_newIdentity {
    return [[self alloc] initWithSigningSeed:SZFRandomBytes(32) staticPrivateKey:SZFRandomBytes(32)];
}

+ (instancetype)identityWithSigningSeed:(NSData *)signingSeed staticPrivateKey:(NSData *)staticPrivateKey {
    if (signingSeed.length != 32 || staticPrivateKey.length != 32) {
        return nil;
    }
    return [[self alloc] initWithSigningSeed:signingSeed staticPrivateKey:staticPrivateKey];
}

- (void)szf_setCertificate:(NSData *)certificate {
    _certificate = [certificate copy];
}

- (NSData *)szf_certificateForStaticKey:(NSData *)staticPublicKey {
    NSMutableData *certificate = [_publicKey mutableCopy];
    [certificate appendData:[self signatureForMessage:staticPublicKey domain:kStaticDomain]];
    return certificate;
}

- (NSData *)staticCertificate {
    return _certificate;
}

- (NSData *)signatureForMessage:(NSData *)message domain:(NSString *)domain {
    NSData *signedBytes = SZFSignedMessage(domain, message);
    uint8_t signature[crypto_sign_BYTES];
    crypto_sign_detached(signature, NULL, signedBytes.bytes, signedBytes.length, _signingSecret.bytes);
    return [NSData dataWithBytes:signature length:sizeof signature];
}

+ (BOOL)verifySignature:(NSData *)signature
             forMessage:(NSData *)message
                 domain:(NSString *)domain
              publicKey:(NSData *)publicKey {
    if (signature.length != crypto_sign_BYTES || publicKey.length != crypto_sign_PUBLICKEYBYTES) {
        return NO;
    }
    NSData *signedBytes = SZFSignedMessage(domain, message);
    return crypto_sign_verify_detached(signature.bytes, signedBytes.bytes, signedBytes.length, publicKey.bytes) == 0;
}

// A fresh mutable copy, as the header promises, so the channel may zero it.
- (NSData *)staticPrivateKey {
    return [_staticSecret mutableCopy];
}

@end

NSData *SZFriendsIdentityKeyFromCertificate(NSData *certificate, NSData *staticPublicKey) {
    if (certificate.length != 96 || staticPublicKey.length != 32) {
        return nil;
    }
    NSData *publicKey = [certificate subdataWithRange:NSMakeRange(0, 32)];
    NSData *signature = [certificate subdataWithRange:NSMakeRange(32, 64)];
    if (![SZFriendsIdentity verifySignature:signature
                                 forMessage:staticPublicKey
                                     domain:kStaticDomain
                                  publicKey:publicKey]) {
        return nil;
    }
    return publicKey;
}
