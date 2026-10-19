// CPace over ristretto255 and SHA-512 (SZFriendsCPace.h). Every step follows draft-irtf-cfrg-cpace-13 literally, so
// the Appendix B.3 vectors check each one on its own.

#import "service/identity/SZFriendsCPace.h"

#import <sodium.h>

const NSUInteger SZFriendsCPaceShareLength = crypto_core_ristretto255_BYTES;
const NSUInteger SZFriendsCPaceScalarLength = crypto_core_ristretto255_SCALARBYTES;
const NSUInteger SZFriendsCPaceISKLength = crypto_hash_sha512_BYTES;

static NSString *const kDSI = @"CPaceRistretto255";
static NSString *const kDSIISK = @"CPaceRistretto255_ISK";
static const NSUInteger kHashBlockBytes = 128; // SHA-512's s_in_bytes

static NSData *Bytes(NSString *string) { return [string dataUsingEncoding:NSUTF8StringEncoding]; }

static NSData *SZFriendsCPaceLEB128(NSUInteger value) {
    NSMutableData *out = [NSMutableData data];
    do {
        uint8_t byte = value & 0x7f;
        value >>= 7;
        if (value != 0) byte |= 0x80;
        [out appendBytes:&byte length:1];
    } while (value != 0);
    return out;
}

NSData *SZFriendsCPacePrependLength(NSData *data) {
    NSMutableData *out = [SZFriendsCPaceLEB128(data.length) mutableCopy];
    [out appendData:data];
    return out;
}

NSData *SZFriendsCPaceLVCat(NSArray<NSData *> *parts) {
    NSMutableData *out = [NSMutableData data];
    for (NSData *part in parts) [out appendData:SZFriendsCPacePrependLength(part)];
    return out;
}

NSData *SZFriendsCPaceGeneratorString(NSData *prs, NSData *ci, NSData *sid) {
    NSData *dsi = Bytes(kDSI);
    NSInteger used = 1 + (NSInteger)SZFriendsCPacePrependLength(prs).length +
                     (NSInteger)SZFriendsCPacePrependLength(dsi).length;
    NSUInteger zpad = (NSInteger)kHashBlockBytes > used ? (NSUInteger)((NSInteger)kHashBlockBytes - used) : 0;
    return SZFriendsCPaceLVCat(@[ dsi, prs, [NSMutableData dataWithLength:zpad], ci, sid ]);
}

NSData *SZFriendsCPaceGenerator(NSData *prs, NSData *ci, NSData *sid) {
    NSData *string = SZFriendsCPaceGeneratorString(prs, ci, sid);
    uint8_t hash[crypto_hash_sha512_BYTES];
    crypto_hash_sha512(hash, string.bytes, string.length);
    uint8_t element[crypto_core_ristretto255_BYTES];
    int failed = crypto_core_ristretto255_from_hash(element, hash);
    sodium_memzero(hash, sizeof hash);
    return failed == 0 ? [NSData dataWithBytes:element length:sizeof element] : nil;
}

NSData *SZFriendsCPaceRandomScalar(void) {
    NSMutableData *scalar = [NSMutableData dataWithLength:crypto_core_ristretto255_SCALARBYTES];
    crypto_core_ristretto255_scalar_random(scalar.mutableBytes);
    return scalar;
}

// Both checks of the draft's scalar_mult_vfy happen in libsodium's call: it refuses an encoding that is not a
// canonical ristretto255 element and a result that is the identity. Scalars are below 2^253, so its clearing of the
// top bit changes nothing.
NSData *SZFriendsCPaceScalarMult(NSData *scalar, NSData *element) {
    if (scalar.length != crypto_core_ristretto255_SCALARBYTES || element.length != crypto_core_ristretto255_BYTES) {
        return nil;
    }
    uint8_t out[crypto_scalarmult_ristretto255_BYTES];
    if (crypto_scalarmult_ristretto255(out, scalar.bytes, element.bytes) != 0) return nil;
    return [NSData dataWithBytes:out length:sizeof out];
}

NSData *SZFriendsCPaceScalarMultVfy(NSData *scalar, NSData *element) {
    if (element.length != crypto_core_ristretto255_BYTES || !crypto_core_ristretto255_is_valid_point(element.bytes)) {
        return nil;
    }
    return SZFriendsCPaceScalarMult(scalar, element);
}

NSData *SZFriendsCPaceISK(NSData *sid, NSData *secret, NSData *shareA, NSData *adA, NSData *shareB, NSData *adB) {
    NSMutableData *input = [SZFriendsCPaceLVCat(@[ Bytes(kDSIISK), sid, secret ]) mutableCopy];
    [input appendData:SZFriendsCPaceLVCat(@[ shareA, adA ])];
    [input appendData:SZFriendsCPaceLVCat(@[ shareB, adB ])];
    NSMutableData *isk = [NSMutableData dataWithLength:crypto_hash_sha512_BYTES];
    crypto_hash_sha512(isk.mutableBytes, input.bytes, input.length);
    sodium_memzero(input.mutableBytes, input.length);
    return isk;
}

@implementation SZFriendsCPace {
    NSData *_scalar;
    NSData *_sessionID;
}

- (instancetype)initWithPassword:(NSData *)password
               channelIdentifier:(NSData *)channelIdentifier
                       sessionID:(NSData *)sessionID
                          scalar:(NSData *)scalar {
    self = [super init];
    if (self == nil) return nil;
    NSData *generator = SZFriendsCPaceGenerator(password, channelIdentifier, sessionID);
    _scalar = scalar ?: SZFriendsCPaceRandomScalar();
    _sessionID = [sessionID copy];
    _share = generator ? SZFriendsCPaceScalarMult(_scalar, generator) : nil;
    return _share.length == SZFriendsCPaceShareLength ? self : nil;
}

- (NSData *)iskAsInitiatorWithAD:(NSData *)ownAD peerShare:(NSData *)peerShare peerAD:(NSData *)peerAD {
    NSData *secret = SZFriendsCPaceScalarMultVfy(_scalar, peerShare);
    return secret ? SZFriendsCPaceISK(_sessionID, secret, _share, ownAD, peerShare, peerAD) : nil;
}

- (NSData *)iskAsResponderWithAD:(NSData *)ownAD peerShare:(NSData *)peerShare peerAD:(NSData *)peerAD {
    NSData *secret = SZFriendsCPaceScalarMultVfy(_scalar, peerShare);
    return secret ? SZFriendsCPaceISK(_sessionID, secret, peerShare, peerAD, _share, ownAD) : nil;
}

@end
