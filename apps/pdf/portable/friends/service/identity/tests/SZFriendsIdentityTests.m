// Identity keys, the static-key certificate, domain-separated signatures, the identity hash, and the manager's
// rule that an identity which exists but cannot be used is reported, never regenerated.

#import "service/identity/SZFriendsIdentityInternal.h"
#import "SZFriendsIdentityTestSupport.h"

#include <sodium.h>

// An in-memory key store whose failures are scripted, recording what the manager asked of it.
@interface SZFFakeKeyStore : NSObject <SZFriendsKeyStore>
@property(nonatomic) NSMutableDictionary<NSString *, NSData *> *items;
@property(nonatomic) NSMutableArray<NSString *> *calls;
@property(nonatomic) BOOL failReads, failStores, failDeletes, returnOtherBytes;
@end

@implementation SZFFakeKeyStore
- (instancetype)init {
    if ((self = [super init])) {
        _items = [NSMutableDictionary dictionary];
        _calls = [NSMutableArray array];
    }
    return self;
}
- (nullable NSData *)secretNamed:(NSString *)name error:(NSError **)error {
    [_calls addObject:@"read"];
    if (_failReads) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:errSecInteractionNotAllowed
                                            userInfo:nil];
        return nil;
    }
    NSData *data = _items[name];
    if (data != nil && _returnOtherBytes) return [NSMutableData dataWithLength:data.length];
    return data != nil ? [data mutableCopy] : nil;
}
- (BOOL)storeSecret:(NSData *)secret named:(NSString *)name error:(NSError **)error {
    [_calls addObject:@"store"];
    if (_failStores || _items[name] != nil) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:errSecDuplicateItem userInfo:nil];
        return NO;
    }
    _items[name] = [secret copy];
    return YES;
}
- (BOOL)deleteSecretNamed:(NSString *)name error:(NSError **)error {
    [_calls addObject:@"delete"];
    if (_failDeletes) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:errSecInteractionNotAllowed
                                            userInfo:nil];
        return NO;
    }
    [_items removeObjectForKey:name];
    return YES;
}
@end

static NSData *Concat(NSData *a, NSData *b) {
    NSMutableData *joined = [a mutableCopy];
    [joined appendData:b];
    return joined;
}

static void TestGoldenVectors(void) {
    // RFC 8032 § 7.1 tests 1 and 2 (Ed25519) and RFC 7748 § 6.1 (X25519, Alice and Bob).
    NSData *seed1 = SZFHex(@"9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
    NSData *seed2 = SZFHex(@"4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb");
    NSData *alice = SZFHex(@"77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
    NSData *bob = SZFHex(@"5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
    SZFriendsIdentity *one = [SZFriendsIdentity identityWithSigningSeed:seed1 staticPrivateKey:alice];
    SZFriendsIdentity *two = [SZFriendsIdentity identityWithSigningSeed:seed2 staticPrivateKey:bob];
    SZFExpect([one.publicKey isEqualToData:SZFHex(@"d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")],
              @"RFC 8032 test 1 public key, got %@", one.publicKey);
    SZFExpect([two.publicKey isEqualToData:SZFHex(@"3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")],
              @"RFC 8032 test 2 public key");
    SZFExpect([one.staticPublicKey isEqualToData:
                   SZFHex(@"8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")], @"RFC 7748 Alice");
    SZFExpect([two.staticPublicKey isEqualToData:
                   SZFHex(@"de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")], @"RFC 7748 Bob");
    SZFExpect([[one staticPrivateKey] isEqualToData:alice], @"static private key returned as given");

    // A signature is plain Ed25519 over UTF-8(domain) || message: with domain "r" and an empty message the input is
    // RFC 8032 test 2's one-byte message 0x72, so the signature must be that test's.
    NSData *signature = [two signatureForMessage:[NSData data] domain:@"r"];
    SZFExpect([signature isEqualToData:SZFHex(@"92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
                                              @"085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")],
              @"RFC 8032 test 2 signature, got %@", signature);

    // The certificate, computed independently: publicKey || Ed25519(seed, "SZFriends static v1" || static key).
    unsigned char pk[32], sk[64], expected[64];
    crypto_sign_seed_keypair(pk, sk, seed1.bytes);
    NSData *certInput = Concat([@"SZFriends static v1" dataUsingEncoding:NSUTF8StringEncoding], one.staticPublicKey);
    crypto_sign_detached(expected, NULL, certInput.bytes, certInput.length, sk);
    NSData *expectedCert = Concat(one.publicKey, [NSData dataWithBytes:expected length:64]);
    SZFExpect([one.staticCertificate isEqualToData:expectedCert], @"certificate bytes");

    // The identity hash, computed independently.
    NSData *hashInput = Concat([@"SZFriends identity hash v1" dataUsingEncoding:NSUTF8StringEncoding], one.publicKey);
    unsigned char hash[32];
    crypto_generichash(hash, 32, hashInput.bytes, hashInput.length, NULL, 0);
    SZFExpect([one.identityHash isEqualToData:[NSData dataWithBytes:hash length:32]], @"identity hash");
    SZFExpect([SZFriendsIdentityHash(one.publicKey) isEqualToData:one.identityHash], @"hash function agrees");
    SZFExpect(SZFriendsIdentityHash([NSData dataWithBytes:hash length:31]) == nil, @"hash needs a 32-byte key");
    NSString *fingerprint = [NSString stringWithFormat:@"%02x%02x%02x%02x", hash[0], hash[1], hash[2], hash[3]];
    SZFExpect([one.logFingerprint isEqualToString:fingerprint], @"fingerprint %@", one.logFingerprint);
    SZFExpect([one.description rangeOfString:@"d75a98"].location == NSNotFound, @"description shows no key");

    // Test-vector keys are not clamped; the stored item clamps, and loading it gives the same identity.
    SZFriendsIdentity *reloaded = [SZFriendsIdentity identityFromSecret:[one secretItem] error:NULL];
    SZFExpect([reloaded.staticPublicKey isEqualToData:one.staticPublicKey] &&
                  [reloaded.publicKey isEqualToData:one.publicKey], @"unclamped vector key round-trips");
    SZFExpect([SZFriendsIdentity identityWithSigningSeed:[seed1 subdataWithRange:NSMakeRange(0, 31)]
                                       staticPrivateKey:alice] == nil, @"short seed refused");
}

static void TestCertificateAndSignatures(void) {
    SZFriendsIdentity *me = [SZFriendsIdentity generatedIdentity];
    SZFriendsIdentity *other = [SZFriendsIdentity generatedIdentity];
    SZFExpect(me.publicKey.length == 32 && me.staticPublicKey.length == 32 && me.staticCertificate.length == 96,
              @"key and certificate sizes");
    SZFExpect(![me.publicKey isEqualToData:other.publicKey], @"fresh identities differ");
    NSData *bound = SZFriendsIdentityKeyFromCertificate(me.staticCertificate, me.staticPublicKey);
    SZFExpect([bound isEqualToData:me.publicKey], @"certificate yields its identity key");
    SZFExpect(SZFriendsIdentityKeyFromCertificate(me.staticCertificate, other.staticPublicKey) == nil,
              @"certificate does not bind another static key");
    for (NSUInteger i = 0; i < me.staticCertificate.length; i++) {
        NSMutableData *tampered = [me.staticCertificate mutableCopy];
        ((uint8_t *)tampered.mutableBytes)[i] ^= 0x01;
        SZFExpect(SZFriendsIdentityKeyFromCertificate(tampered, me.staticPublicKey) == nil, @"flipped byte %lu",
                  (unsigned long)i);
    }
    SZFExpect(SZFriendsIdentityKeyFromCertificate([me.staticCertificate subdataWithRange:NSMakeRange(0, 95)],
                                                  me.staticPublicKey) == nil, @"short certificate");
    SZFExpect(SZFriendsIdentityKeyFromCertificate(me.staticCertificate, [NSData data]) == nil, @"empty static key");

    NSData *message = [@"check-in bytes" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *signature = [me signatureForMessage:message domain:@"SZFriends request v1"];
    SZFExpect([SZFriendsIdentity verifySignature:signature forMessage:message domain:@"SZFriends request v1"
                                       publicKey:me.publicKey], @"verifies");
    SZFExpect(![SZFriendsIdentity verifySignature:signature forMessage:message domain:@"SZFriends checkin v1"
                                        publicKey:me.publicKey], @"another domain does not verify");
    SZFExpect(![SZFriendsIdentity verifySignature:signature forMessage:[@"check-in byteS"
        dataUsingEncoding:NSUTF8StringEncoding] domain:@"SZFriends request v1" publicKey:me.publicKey], @"message");
    SZFExpect(![SZFriendsIdentity verifySignature:signature forMessage:message domain:@"SZFriends request v1"
                                        publicKey:other.publicKey], @"another key does not verify");
    SZFExpect(![SZFriendsIdentity verifySignature:signature forMessage:message domain:@""
                                        publicKey:me.publicKey], @"empty domain never verifies");
    SZFExpect(![SZFriendsIdentity verifySignature:[signature subdataWithRange:NSMakeRange(0, 63)] forMessage:message
                                           domain:@"SZFriends request v1" publicKey:me.publicKey], @"short signature");
    // The certificate's own signature is a static-domain signature and nothing else.
    NSData *certSignature = [me.staticCertificate subdataWithRange:NSMakeRange(32, 64)];
    SZFExpect(![SZFriendsIdentity verifySignature:certSignature forMessage:me.staticPublicKey
                                           domain:@"SZFriends request v1" publicKey:me.publicKey], @"cert domain");
    SZFExpect(SZFRaises(NSInvalidArgumentException, ^{ [me signatureForMessage:message domain:@""]; }),
              @"signing with an empty domain raises");

    NSMutableData *copy = (NSMutableData *)[me staticPrivateKey];
    SZFExpect([copy isKindOfClass:[NSMutableData class]] && copy.length == 32, @"mutable private key copy");
    sodium_memzero(copy.mutableBytes, copy.length);
    SZFExpect(![[me staticPrivateKey] isEqualToData:copy], @"zeroing a copy leaves the key intact");
}

// Signatures are Ed25519 over domain || message with no separator, so two domains where one starts with the other
// could share signed bytes (security review, low finding "signature domain separation").
static void TestSignatureDomainsArePrefixFree(void) {
    NSArray<NSString *> *domains = SZFriendsSignatureDomains();
    SZFExpect([domains containsObject:@"SZFriends static v1"] && [domains containsObject:@"SZFriends request v1"] &&
                  [domains containsObject:@"SZFriends checkin v1"] && [domains containsObject:@"SZFriends release v1"],
              @"every domain in use is listed: %@", domains);
    for (NSString *a in domains) {
        for (NSString *b in domains) {
            SZFExpect(a == b || ![a hasPrefix:b], @"%@ starts with %@", a, b);
        }
    }
    SZFriendsIdentity *me = [SZFriendsIdentity generatedIdentity];
    NSData *key = me.staticPublicKey;
    NSMutableData *tail = [[@" v1" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [tail appendData:key];
    // A later "SZFriends static" signature over " v1" || key would be a valid static certificate; it is refused.
    SZFExpect(SZFRaises(NSInvalidArgumentException, ^{ [me signatureForMessage:tail domain:@"SZFriends static"]; }),
              @"a domain that is a prefix of a listed one is refused");
    SZFExpect(SZFRaises(NSInvalidArgumentException, ^{ [me signatureForMessage:key domain:@"SZFriends static v1x"]; }),
              @"a domain that extends a listed one is refused");
    NSData *certSignature = [me.staticCertificate subdataWithRange:NSMakeRange(32, 64)];
    SZFExpect(![SZFriendsIdentity verifySignature:certSignature forMessage:tail domain:@"SZFriends static"
                                        publicKey:me.publicKey], @"and never verifies");
}

static void TestSecretItem(void) {
    SZFriendsIdentity *me = [SZFriendsIdentity generatedIdentity];
    NSMutableData *item = [me secretItem];
    SZFExpect(item.length == SZFriendsIdentitySecretLength && memcmp(item.bytes, "SZFI\x01", 5) == 0, @"layout");
    SZFriendsIdentity *loaded = [SZFriendsIdentity identityFromSecret:item error:NULL];
    SZFExpect([loaded.publicKey isEqualToData:me.publicKey] && [loaded.staticCertificate isEqualToData:
                                                                    me.staticCertificate], @"round trip");
    // Every single-byte change is caught: header, private keys (public keys no longer match) or public keys.
    for (NSUInteger i = 0; i < item.length; i++) {
        NSMutableData *damaged = [item mutableCopy];
        ((uint8_t *)damaged.mutableBytes)[i] ^= 0x80;
        NSError *error = nil;
        SZFExpect([SZFriendsIdentity identityFromSecret:damaged error:&error] == nil &&
                      error.code == SZFriendsIdentityErrorCorrupt, @"damaged byte %lu", (unsigned long)i);
    }
    NSError *error = nil;
    SZFExpect([SZFriendsIdentity identityFromSecret:[item subdataWithRange:NSMakeRange(0, 132)] error:&error] == nil &&
                  error.code == SZFriendsIdentityErrorCorrupt, @"truncated");
}

static void TestManager(void) {
    SZFFakeKeyStore *store = [[SZFFakeKeyStore alloc] init];
    SZFriendsIdentityManager *manager = [[SZFriendsIdentityManager alloc] initWithKeyStore:store];
    SZFriendsIdentityState state = SZFriendsIdentityStateReady;
    NSError *error = nil;
    SZFriendsIdentity *created = [manager loadOrCreateWithState:&state error:&error];
    SZFExpect(created != nil && state == SZFriendsIdentityStateCreated, @"first start creates: %@", error);
    SZFExpect([store.calls isEqualToArray:(@[ @"read", @"store", @"read" ])], @"read, store, read back: %@",
              store.calls);
    SZFriendsIdentity *loaded = [manager loadOrCreateWithState:&state error:&error];
    SZFExpect([loaded.publicKey isEqualToData:created.publicKey] && state == SZFriendsIdentityStateReady, @"reload");

    // Unreadable: Unavailable, and nothing is written — the existing secret must survive for a later reset.
    [store.calls removeAllObjects];
    store.failReads = YES;
    state = SZFriendsIdentityStateReady;
    error = nil;
    SZFExpect([manager loadOrCreateWithState:&state error:&error] == nil, @"unreadable gives no identity");
    SZFExpect(state == SZFriendsIdentityStateUnavailable && error.code == SZFriendsIdentityErrorUnavailable,
              @"state %ld error %@", (long)state, error);
    SZFExpect(![store.calls containsObject:@"store"] && ![store.calls containsObject:@"delete"], @"never regenerated");
    store.failReads = NO;

    // Corrupt: Unavailable with Corrupt, and again nothing written.
    store.items[@"identity"] = [NSData dataWithBytes:"SZFI\x01" length:5];
    [store.calls removeAllObjects];
    error = nil;
    SZFExpect([manager loadOrCreateWithState:&state error:&error] == nil, @"corrupt gives no identity");
    SZFExpect(state == SZFriendsIdentityStateUnavailable && error.code == SZFriendsIdentityErrorCorrupt,
              @"corrupt: %@", error);
    SZFExpect([store.calls isEqualToArray:@[ @"read" ]], @"corrupt never regenerated: %@", store.calls);
    SZFExpect([manager loadOrCreateWithState:NULL error:NULL] == nil, @"NULL state and error pointers are allowed");

    // Reset deletes, then creates a different identity.
    error = nil;
    SZFriendsIdentity *reset = [manager resetIdentityWithError:&error];
    SZFExpect(reset != nil && ![reset.publicKey isEqualToData:created.publicKey], @"reset: %@", error);
    SZFExpect([[manager loadOrCreateWithState:&state error:NULL].publicKey isEqualToData:reset.publicKey], @"kept");
    store.failDeletes = YES;
    [store.calls removeAllObjects];
    error = nil;
    SZFExpect([manager resetIdentityWithError:&error] == nil && error != nil, @"failed delete fails the reset");
    SZFExpect(![store.calls containsObject:@"store"], @"nothing created when the delete failed");
    store.failDeletes = NO;

    // A store that cannot save, or saves what it cannot return, gives no identity: tomorrow it would be a new key.
    SZFFakeKeyStore *broken = [[SZFFakeKeyStore alloc] init];
    broken.failStores = YES;
    error = nil;
    SZFExpect([[[SZFriendsIdentityManager alloc] initWithKeyStore:broken] loadOrCreateWithState:&state error:&error] ==
                  nil && state == SZFriendsIdentityStateUnavailable && error.code == SZFriendsIdentityErrorStoreFailed,
              @"store failure: %@", error);
    SZFFakeKeyStore *lossy = [[SZFFakeKeyStore alloc] init];
    lossy.returnOtherBytes = YES;
    error = nil;
    SZFExpect([[[SZFriendsIdentityManager alloc] initWithKeyStore:lossy] loadOrCreateWithState:&state error:&error] ==
                  nil && error.code == SZFriendsIdentityErrorStoreFailed, @"read-back mismatch: %@", error);

    // The real file store end to end, in a temporary state directory.
    NSString *root = SZFMakeTemporaryDirectory(@"manager");
    id<SZFriendsKeyStore> files = SZFriendsDefaultKeyStore(root, @{@"SZFRIENDS_STATE_DIR" : root});
    SZFriendsIdentity *first = [[[SZFriendsIdentityManager alloc] initWithKeyStore:files] loadOrCreateWithState:&state
                                                                                                         error:NULL];
    SZFriendsIdentity *again = [[[SZFriendsIdentityManager alloc] initWithKeyStore:files] loadOrCreateWithState:&state
                                                                                                         error:NULL];
    SZFExpect(first != nil && [again.publicKey isEqualToData:first.publicKey] && state == SZFriendsIdentityStateReady,
              @"file store keeps the identity across managers");
    SZFRemoveTemporaryDirectory(root);
}

int main(void) {
    @autoreleasepool {
        TestGoldenVectors();
        TestCertificateAndSignatures();
        TestSignatureDomainsArePrefixFree();
        TestSecretItem();
        TestManager();
        return SZFFinish("SZFriendsIdentityTests");
    }
}
