// Rendezvous record blobs (SZFriendsSignaling.h, ADR 0010): sealed under the publisher's presence secret, which only
// friends hold, and signed inside by the device that made them. The host keeps them opaque and answers a lookup for
// anyone else with 512 bytes of filler, which these blobs cannot be told apart from without the secret.

#import "service/session/SZFriendsSignaling.h"

#import <sodium.h>

#import "service/identity/SZFriendsIdentity.h"
#import "service/session/SZFriendsFrameSchema.h"

const NSUInteger SZFriendsRendezvousSealedLength = 512;
const NSUInteger SZFriendsRendezvousBodyMax = 365;

static NSString *const SZFriendsRendezvousKeyDomain = @"SZFriends rendezvous key v1";
static NSString *const SZFriendsRendezvousSealDomain = @"SZFriends rendezvous seal v1";
static const uint8_t SZFriendsRendezvousVersion = 1;
// version, window, device key, signature, body length: what precedes the body inside.
static const NSUInteger SZFriendsRendezvousHeaderLength = 1 + 8 + 32 + 64 + 2;
static const NSUInteger SZFriendsRendezvousPlaintextLength =
    512 - crypto_aead_xchacha20poly1305_ietf_NPUBBYTES - crypto_aead_xchacha20poly1305_ietf_ABYTES;

@implementation SZFriendsRendezvousRecord

- (instancetype)initWithDeviceKey:(NSData *)deviceKey window:(int64_t)window items:(NSArray *)items {
    if ((self = [super init])) {
        _deviceKey = [deviceKey copy];
        _window = window;
        _items = [items copy];
    }
    return self;
}

@end

NSData *SZFriendsRendezvousKey(NSData *identityKey) {
    if (identityKey.length != 32) return nil;
    NSMutableData *input = [[SZFriendsRendezvousKeyDomain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [input appendData:identityKey];
    NSMutableData *digest = [NSMutableData dataWithLength:crypto_hash_sha256_BYTES];
    crypto_hash_sha256(digest.mutableBytes, input.bytes, input.length);
    return digest;
}

static NSMutableData *SZFriendsRendezvousSealKey(NSData *presenceSecret) {
    NSData *label = [SZFriendsRendezvousSealDomain dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *key = [NSMutableData dataWithLength:crypto_aead_xchacha20poly1305_ietf_KEYBYTES];
    crypto_generichash(key.mutableBytes, key.length, label.bytes, label.length, presenceSecret.bytes,
                       presenceSecret.length);
    return key;
}

static NSData *SZFriendsRendezvousAD(NSData *rdvKey) {
    NSMutableData *ad = [[SZFriendsRendezvousSealDomain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [ad appendData:rdvKey];
    return ad;
}

// What the device signs, after the domain: rdv key || version || window || device key || body.
static NSData *SZFriendsRendezvousSigned(NSData *rdvKey, int64_t window, NSData *deviceKey, NSData *body) {
    NSMutableData *message = [rdvKey mutableCopy];
    uint8_t header[9] = {SZFriendsRendezvousVersion};
    for (int i = 0; i < 8; i++) header[1 + i] = (uint8_t)((uint64_t)window >> (56 - 8 * i));
    [message appendBytes:header length:sizeof header];
    [message appendData:deviceKey];
    [message appendData:body];
    return message;
}

static NSError *SZFriendsRendezvousError(NSString *reason) {
    return SZFriendsSessionMakeError(SZFriendsSessionErrorFrameInvalid, reason);
}

NSData *SZFriendsSealRendezvousRecord(SZFriendsIdentity *device, NSData *personKey, NSData *presenceSecret,
                                      int64_t window, NSArray<SZFriendsSignalItem *> *items, NSError **error) {
    NSData *rdvKey = SZFriendsRendezvousKey(personKey);
    if (rdvKey == nil || presenceSecret.length != 32 || device.publicKey.length != 32) {
        if (error) *error = SZFriendsRendezvousError(@"a record needs a 32-byte key and secret");
        return nil;
    }
    NSData *body = items.count ? SZFriendsEncodeSignalItems(items, SZFriendsRendezvousBodyMax, error) : [NSData data];
    if (body == nil) return nil;
    NSData *signature = [device signatureForMessage:SZFriendsRendezvousSigned(rdvKey, window, device.publicKey, body)
                                             domain:SZFriendsRendezvousSealDomain];
    NSMutableData *plaintext = [NSMutableData dataWithLength:SZFriendsRendezvousPlaintextLength];
    uint8_t *bytes = plaintext.mutableBytes;
    bytes[0] = SZFriendsRendezvousVersion;
    for (int i = 0; i < 8; i++) bytes[1 + i] = (uint8_t)((uint64_t)window >> (56 - 8 * i));
    memcpy(bytes + 9, device.publicKey.bytes, 32);
    memcpy(bytes + 41, signature.bytes, 64);
    bytes[105] = (uint8_t)(body.length >> 8);
    bytes[106] = (uint8_t)body.length;
    memcpy(bytes + SZFriendsRendezvousHeaderLength, body.bytes, body.length);

    NSMutableData *sealed = [NSMutableData dataWithLength:SZFriendsRendezvousSealedLength];
    uint8_t *out = sealed.mutableBytes;
    randombytes_buf(out, crypto_aead_xchacha20poly1305_ietf_NPUBBYTES);
    NSMutableData *key = SZFriendsRendezvousSealKey(presenceSecret);
    NSData *ad = SZFriendsRendezvousAD(rdvKey);
    unsigned long long written = 0;
    crypto_aead_xchacha20poly1305_ietf_encrypt(out + crypto_aead_xchacha20poly1305_ietf_NPUBBYTES, &written, bytes,
                                               plaintext.length, ad.bytes, ad.length, NULL, out, key.bytes);
    sodium_memzero(key.mutableBytes, key.length);
    return written == SZFriendsRendezvousSealedLength - crypto_aead_xchacha20poly1305_ietf_NPUBBYTES ? sealed : nil;
}

SZFriendsRendezvousRecord *SZFriendsOpenRendezvousRecord(NSData *sealed, NSData *personKey, NSData *presenceSecret,
                                                        NSArray<NSData *> *deviceKeys, int64_t window) {
    NSData *rdvKey = SZFriendsRendezvousKey(personKey);
    if (sealed.length != SZFriendsRendezvousSealedLength || rdvKey == nil || presenceSecret.length != 32) return nil;
    const uint8_t *in = sealed.bytes;
    NSMutableData *plaintext = [NSMutableData dataWithLength:SZFriendsRendezvousPlaintextLength];
    NSMutableData *key = SZFriendsRendezvousSealKey(presenceSecret);
    NSData *ad = SZFriendsRendezvousAD(rdvKey);
    unsigned long long length = 0;
    int opened = crypto_aead_xchacha20poly1305_ietf_decrypt(
        plaintext.mutableBytes, &length, NULL, in + crypto_aead_xchacha20poly1305_ietf_NPUBBYTES,
        sealed.length - crypto_aead_xchacha20poly1305_ietf_NPUBBYTES, ad.bytes, ad.length, in, key.bytes);
    sodium_memzero(key.mutableBytes, key.length);
    if (opened != 0 || length != SZFriendsRendezvousPlaintextLength) return nil;
    const uint8_t *bytes = plaintext.bytes;
    uint64_t rawWindow = 0;
    for (int i = 0; i < 8; i++) rawWindow = (rawWindow << 8) | bytes[1 + i];
    int64_t recordWindow = (int64_t)rawWindow;
    NSUInteger bodyLength = ((NSUInteger)bytes[105] << 8) | bytes[106];
    if (bytes[0] != SZFriendsRendezvousVersion || bodyLength > SZFriendsRendezvousBodyMax ||
        recordWindow < window - 1 || recordWindow > window + 1) {
        return nil;
    }
    NSData *deviceKey = [NSData dataWithBytes:bytes + 9 length:32];
    NSData *signature = [NSData dataWithBytes:bytes + 41 length:64];
    NSData *body = [NSData dataWithBytes:bytes + SZFriendsRendezvousHeaderLength length:bodyLength];
    if (![deviceKeys containsObject:deviceKey] ||
        ![SZFriendsIdentity verifySignature:signature
                                 forMessage:SZFriendsRendezvousSigned(rdvKey, recordWindow, deviceKey, body)
                                     domain:SZFriendsRendezvousSealDomain
                                  publicKey:deviceKey]) {
        return nil;
    }
    NSArray *items = bodyLength ? SZFriendsDecodeSignalItems(body, NULL) : @[];
    return items ? [[SZFriendsRendezvousRecord alloc] initWithDeviceKey:deviceKey window:recordWindow items:items]
                 : nil;
}
