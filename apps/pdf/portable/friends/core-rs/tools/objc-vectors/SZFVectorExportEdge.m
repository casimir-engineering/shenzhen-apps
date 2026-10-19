// Vector export: the edge cases where Ed25519 and X25519 implementations are known to disagree, with the helper's
// verdict on each. Ed25519 goes through the helper's own +[SZFriendsIdentity verifySignature:...] (libsodium's
// crypto_sign_verify_detached under a Friends domain); X25519 through crypto_scalarmult, the call behind the Noise
// state machine's DH (szfriends_noise_handshake.c, mix_dh). The Rust core must reach the same accept or refuse.
//
// Signatures are built by hand from scalars, not by crypto_sign, so that a case can make the verification equation
// hold for a key or R that libsodium refuses on other grounds: a refusal then shows the check, not bad arithmetic.

#import "SZFVectorExport.h"

#import <sodium.h>

#import "service/identity/SZFriendsIdentityInternal.h"

static NSString *const SZFEdgeDomain = @"SZFriends request v1";

// The small-order encodings libsodium lists (ge25519_has_small_order), each canonical.
static NSData *SZFHexData(const char *hex) {
    NSMutableData *data = [NSMutableData dataWithLength:strlen(hex) / 2];
    if (sodium_hex2bin(data.mutableBytes, data.length, hex, strlen(hex), NULL, NULL, NULL) != 0) exit(1);
    return data;
}

static NSArray<NSArray *> *SZFSmallOrderPoints(void) {
    return @[
        @[ @"identity", SZFHexData("0100000000000000000000000000000000000000000000000000000000000000") ],
        @[ @"order 2", SZFHexData("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f") ],
        @[ @"order 4", SZFHexData("0000000000000000000000000000000000000000000000000000000000000000") ],
        @[ @"order 4, x negative", SZFHexData("0000000000000000000000000000000000000000000000000000000000000080") ],
        @[ @"order 8", SZFHexData("26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05") ],
        @[ @"order 8, x negative", SZFHexData("26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85") ],
        @[ @"order 8, other", SZFHexData("c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a") ],
        @[ @"order 8, other, x negative",
           SZFHexData("c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa") ],
    ];
}

static NSData *SZFEdScalar(NSString *label) {
    NSData *wide = SZFDerive(label, 64);
    NSMutableData *scalar = [NSMutableData dataWithLength:crypto_core_ed25519_SCALARBYTES];
    crypto_core_ed25519_scalar_reduce(scalar.mutableBytes, wide.bytes);
    return scalar;
}

static NSData *SZFBasePoint(NSData *scalar) {
    NSMutableData *point = [NSMutableData dataWithLength:crypto_core_ed25519_BYTES];
    if (crypto_scalarmult_ed25519_base_noclamp(point.mutableBytes, scalar.bytes) != 0) exit(1);
    return point;
}

static NSData *SZFAdd(NSData *p, NSData *q) {
    NSMutableData *sum = [NSMutableData dataWithLength:crypto_core_ed25519_BYTES];
    if (crypto_core_ed25519_add(sum.mutableBytes, p.bytes, q.bytes) != 0) exit(1);
    return sum;
}

static NSData *SZFInput(NSData *message) {
    NSMutableData *input = [SZFUTF8(SZFEdgeDomain) mutableCopy];
    [input appendData:message];
    return input;
}

// h = SHA-512(R || A || input) mod L, as the verifier computes it.
static NSData *SZFChallenge(NSData *r, NSData *a, NSData *message) {
    NSMutableData *all = [r mutableCopy];
    [all appendData:a];
    [all appendData:SZFInput(message)];
    unsigned char wide[crypto_hash_sha512_BYTES];
    crypto_hash_sha512(wide, all.bytes, all.length);
    NSMutableData *h = [NSMutableData dataWithLength:crypto_core_ed25519_SCALARBYTES];
    crypto_core_ed25519_scalar_reduce(h.mutableBytes, wide);
    return h;
}

// S = nonce + h * secret mod L. A nil secret means a key whose discrete logarithm is zero (small-order keys).
static NSData *SZFResponse(NSData *nonce, NSData *h, NSData *_Nullable secret) {
    NSMutableData *product = [NSMutableData dataWithLength:crypto_core_ed25519_SCALARBYTES];
    if (secret != nil) crypto_core_ed25519_scalar_mul(product.mutableBytes, h.bytes, secret.bytes);
    NSMutableData *s = [NSMutableData dataWithLength:crypto_core_ed25519_SCALARBYTES];
    crypto_core_ed25519_scalar_add(s.mutableBytes, nonce.bytes, product.bytes);
    return s;
}

static NSData *SZFSignature(NSData *r, NSData *s) {
    NSMutableData *signature = [r mutableCopy];
    [signature appendData:s];
    return signature;
}

static NSDictionary *SZFEdCase(NSString *name, NSData *key, NSData *message, NSData *signature, NSString *why) {
    BOOL accepted = [SZFriendsIdentity verifySignature:signature forMessage:message domain:SZFEdgeDomain publicKey:key];
    return @{
        @"name" : name, @"why" : why, @"domain" : SZFEdgeDomain, @"public_key" : SZFHexString(key),
        @"message" : SZFHexString(message), @"signature" : SZFHexString(signature), @"accepted" : @(accepted),
    };
}

// The first message `label n` whose challenge for (R, A) is, or is not, a multiple of 8: whether a torsion part of
// order 8 drops out of the cofactorless equation that libsodium checks.
static NSData *SZFMessageWithChallenge(NSString *label, NSData *r, NSData *a, BOOL multipleOfEight) {
    for (unsigned n = 0; n < 1000; n++) {
        NSData *message = SZFDerive([NSString stringWithFormat:@"%@ %u", label, n], 32);
        BOOL multiple = (((const uint8_t *)SZFChallenge(r, a, message).bytes)[0] & 7) == 0;
        if (multiple == multipleOfEight) return message;
    }
    exit(1);
}

static NSArray *SZFEd25519Cases(void) {
    NSMutableArray *cases = [NSMutableArray array];
    NSData *secret = SZFEdScalar(@"edge secret"), *nonce = SZFEdScalar(@"edge nonce");
    NSData *key = SZFBasePoint(secret), *r = SZFBasePoint(nonce);
    NSData *message = SZFDerive(@"edge message", 32);
    NSData *s = SZFResponse(nonce, SZFChallenge(r, key, message), secret);
    [cases addObject:SZFEdCase(@"valid", key, message, SZFSignature(r, s), @"the control case")];

    // S + L: the same scalar, not reduced (malleability).
    static const uint8_t order[32] = {0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7,
                                      0xa2, 0xde, 0xf9, 0xde, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                                      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10};
    NSMutableData *unreduced = [s mutableCopy];
    sodium_add(unreduced.mutableBytes, order, sizeof order);
    [cases addObject:SZFEdCase(@"S not canonical", key, message, SZFSignature(r, unreduced), @"S + L")];

    for (NSArray *point in SZFSmallOrderPoints()) {
        NSData *torsion = point[1];
        // Small-order key, with S = r: the equation holds whenever h * A is the identity.
        NSData *forKey = SZFMessageWithChallenge(@"small key", r, torsion, YES);
        [cases addObject:SZFEdCase([@"small-order key: " stringByAppendingString:point[0]], torsion, forKey,
                                   SZFSignature(r, SZFResponse(nonce, SZFChallenge(r, torsion, forKey), nil)),
                                   @"the equation holds; refused for the key's order")];
        // Small-order R: R = torsion, S = h * a, so S * B - h * A is the identity: the equation holds for R = 1.
        NSData *zero = [NSMutableData dataWithLength:32];
        NSData *forR = SZFResponse(zero, SZFChallenge(torsion, key, message), secret);
        [cases addObject:SZFEdCase([@"small-order R: " stringByAppendingString:point[0]], key, message,
                                   SZFSignature(torsion, forR), @"refused for R's order (the equation holds for 1)")];
    }

    // Mixed order: a key of the prime-order subgroup plus a point of order 8. The cofactorless equation holds only
    // when 8 divides h, so libsodium accepts one of these and refuses the other.
    NSData *eight = SZFSmallOrderPoints()[4][1];
    NSData *mixed = SZFAdd(key, eight);
    for (NSNumber *multiple in @[ @YES, @NO ]) {
        NSData *forMixed = SZFMessageWithChallenge(@"mixed key", r, mixed, multiple.boolValue);
        NSData *signature = SZFSignature(r, SZFResponse(nonce, SZFChallenge(r, mixed, forMixed), secret));
        NSString *name = multiple.boolValue ? @"mixed-order key, 8 divides h" : @"mixed-order key, 8 does not divide h";
        [cases addObject:SZFEdCase(name, mixed, forMixed, signature, @"cofactorless verification")];
    }
    NSData *mixedR = SZFAdd(r, eight);
    NSData *forMixedR = SZFMessageWithChallenge(@"mixed r", mixedR, key, YES);
    [cases addObject:SZFEdCase(@"mixed-order R", key, forMixedR,
                               SZFSignature(mixedR, SZFResponse(nonce, SZFChallenge(mixedR, key, forMixedR), secret)),
                               @"R carries a torsion part the equation cannot produce")];

    // Non-canonical encodings: y = p + 1 (the identity), and y = p + k for small k, sign bit clear and set.
    for (unsigned k = 1; k < 19; k++) {
        NSMutableData *encoding = [SZFHexData("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")
            mutableCopy];
        ((uint8_t *)encoding.mutableBytes)[0] += (uint8_t)k;
        for (int sign = 0; sign < 2; sign++) {
            NSMutableData *keyBytes = [encoding mutableCopy];
            if (sign) ((uint8_t *)keyBytes.mutableBytes)[31] |= 0x80;
            NSString *name = [NSString stringWithFormat:@"key y = p + %u%@", k, sign ? @", x negative" : @""];
            NSData *signature = SZFSignature(r, SZFResponse(nonce, SZFChallenge(r, keyBytes, message), secret));
            [cases addObject:SZFEdCase(name, keyBytes, message, signature, @"a non-canonical key encoding")];
        }
    }
    NSMutableData *rNegativeZero = [SZFSmallOrderPoints()[0][1] mutableCopy];
    ((uint8_t *)rNegativeZero.mutableBytes)[31] |= 0x80;
    [cases addObject:SZFEdCase(@"R is the identity with x negative", key, message,
                               SZFSignature(rNegativeZero, SZFResponse([NSMutableData dataWithLength:32],
                                                                       SZFChallenge(rNegativeZero, key, message),
                                                                       secret)),
                               @"a non-canonical encoding of a small-order R")];
    return cases;
}

static NSArray *SZFX25519Cases(void) {
    NSArray<NSString *> *points = @[
        @"0000000000000000000000000000000000000000000000000000000000000000",
        @"0100000000000000000000000000000000000000000000000000000000000000",
        @"e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
        @"5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
        @"ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        @"edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        @"eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        @"0200000000000000000000000000000000000000000000000000000000000000",
        @"0900000000000000000000000000000000000000000000000000000000000000",
    ];
    NSData *private = SZFDeriveClampedKey(@"edge x25519 private");
    NSMutableArray *cases = [NSMutableArray array];
    for (NSString *hex in points) {
        for (int high = 0; high < 2; high++) {
            NSMutableData *point = [SZFHexData(hex.UTF8String) mutableCopy];
            if (high) ((uint8_t *)point.mutableBytes)[31] |= 0x80;
            NSMutableData *shared = [NSMutableData dataWithLength:crypto_scalarmult_BYTES];
            BOOL ok = crypto_scalarmult(shared.mutableBytes, private.bytes, point.bytes) == 0;
            [cases addObject:@{
                @"private_key" : SZFHexString(private), @"public_key" : SZFHexString(point),
                @"shared" : ok ? SZFHexString(shared) : [NSNull null],
            }];
        }
    }
    return cases;
}

NSDictionary *SZFExportEdgeCases(void) {
    return @{@"ed25519" : SZFEd25519Cases(), @"x25519" : SZFX25519Cases()};
}
