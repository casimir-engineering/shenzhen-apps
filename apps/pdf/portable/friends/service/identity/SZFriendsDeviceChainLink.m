// One device-chain link: its byte format, signature and consent (ADR 0012 § Format), and the local device's labels.
//
//   version u8 (1) | kind u8 | milliseconds u64be | parent count u8 | parents (32 each) | signer (32) | subject (32)
//   genesis, add:  static key (32) | name length u8 | name | system length u8 | system | consent (64)
//   rename:        name length u8 | name | system length u8 | system
//   revoke:        nothing more
//   then the signer's signature (64), domain "SZFriends chain link v1", over root key (32) || every byte before it.
//
// Signing the root key binds a link to one person's chain, so it cannot be replayed into another. The hash children
// name is BLAKE2b-256("SZFriends chain hash v1" || the whole link, signature included).

#import "service/identity/SZFriendsDeviceChainInternal.h"
#import "service/identity/SZFriendsIdentity.h"

#include <sodium.h>

NSErrorDomain const SZFriendsDeviceChainErrorDomain = @"SZFriendsDeviceChainErrorDomain";
NSString *const SZFriendsChainLinkDomain = @"SZFriends chain link v1";
NSString *const SZFriendsDeviceConsentDomain = @"SZFriends device consent v1";
static NSString *const SZFriendsChainHashDomain = @"SZFriends chain hash v1";

const NSUInteger SZFriendsDeviceChainMaxLinks = 128;
const NSUInteger SZFriendsDeviceChainRenameLimit = 112;
const NSUInteger SZFriendsDeviceChainEncodedMax = 64000;
const NSUInteger SZFriendsDeviceChainParentsMax = 8;
const NSUInteger SZFriendsDeviceNameMax = 64;
const NSUInteger SZFriendsDeviceSystemMax = 64;

static const uint8_t SZFLinkVersion = 1;

NSError *SZFriendsChainError(SZFriendsDeviceChainError code, NSString *description) {
    return [NSError errorWithDomain:SZFriendsDeviceChainErrorDomain
                               code:code
                           userInfo:@{NSDebugDescriptionErrorKey : description}];
}

static BOOL SZFChainFail(NSError **error, SZFriendsDeviceChainError code, NSString *description) {
    if (error) *error = SZFriendsChainError(code, description);
    return NO;
}

static BOOL SZFKindCarriesKeys(SZFriendsChainLinkKind kind) {
    return kind == SZFriendsChainLinkGenesis || kind == SZFriendsChainLinkAdd;
}

static BOOL SZFKindCarriesLabels(SZFriendsChainLinkKind kind) {
    return kind != SZFriendsChainLinkRevoke;
}

// C0 and C1 controls only: format characters such as the zero-width joiner hold emoji together in a name.
static NSCharacterSet *SZFControls(void) {
    NSMutableCharacterSet *controls = [NSMutableCharacterSet characterSetWithRange:NSMakeRange(0, 0x20)];
    [controls addCharactersInRange:NSMakeRange(0x7F, 0x21)];
    return controls;
}

NSString *SZFriendsChainLabel(NSString *text, NSUInteger maxBytes) {
    NSString *trimmed = [[text componentsSeparatedByCharactersInSet:SZFControls()] componentsJoinedByString:@""];
    trimmed = [trimmed stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableString *label = [NSMutableString string];
    __block NSUInteger bytes = 0;
    [trimmed enumerateSubstringsInRange:NSMakeRange(0, trimmed.length)
                                options:NSStringEnumerationByComposedCharacterSequences
                             usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
                                 (void)range, (void)enclosing;
                                 NSUInteger length = [character lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                                 if (bytes + length > maxBytes) {
                                     *stop = YES;
                                     return;
                                 }
                                 bytes += length;
                                 [label appendString:character];
                             }];
    return label;
}

NSData *SZFriendsDeviceConsent(SZFriendsIdentity *device, NSData *rootKey) {
    NSMutableData *message = [rootKey mutableCopy];
    [message appendData:device.publicKey];
    [message appendData:device.staticPublicKey];
    return [device signatureForMessage:message domain:SZFriendsDeviceConsentDomain];
}

BOOL SZFriendsVerifyDeviceConsent(NSData *consent, NSData *deviceKey, NSData *staticKey, NSData *rootKey) {
    if (rootKey.length != 32 || deviceKey.length != 32 || staticKey.length != 32) return NO;
    NSMutableData *message = [rootKey mutableCopy];
    [message appendData:deviceKey];
    [message appendData:staticKey];
    return [SZFriendsIdentity verifySignature:consent
                                   forMessage:message
                                       domain:SZFriendsDeviceConsentDomain
                                    publicKey:deviceKey];
}

NSString *SZFriendsLocalDeviceName(void) {
    // The computer name from Sharing settings, which NSHost reads from the system configuration without a lookup.
    NSString *name = SZFriendsChainLabel(NSHost.currentHost.localizedName ?: @"", SZFriendsDeviceNameMax);
    return name.length > 0 ? name : @"Mac";
}

NSString *SZFriendsLocalDeviceSystem(void) {
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    if (version.patchVersion != 0) {
        return [NSString stringWithFormat:@"macOS %ld.%ld.%ld", (long)version.majorVersion, (long)version.minorVersion,
                                          (long)version.patchVersion];
    }
    return [NSString stringWithFormat:@"macOS %ld.%ld", (long)version.majorVersion, (long)version.minorVersion];
}

#pragma mark - Reading bytes

typedef struct {
    const uint8_t *bytes;
    NSUInteger length;
    NSUInteger position;
} SZFChainReader;

static const uint8_t *SZFTake(SZFChainReader *reader, NSUInteger count) {
    if (reader->length - reader->position < count) return NULL;
    const uint8_t *start = reader->bytes + reader->position;
    reader->position += count;
    return start;
}

static NSData *SZFTakeData(SZFChainReader *reader, NSUInteger count) {
    const uint8_t *start = SZFTake(reader, count);
    return start ? [NSData dataWithBytes:start length:count] : nil;
}

// A length-prefixed label: 1 to `maxBytes` bytes of valid UTF-8 that trimming would not change.
static NSString *SZFTakeLabel(SZFChainReader *reader, NSUInteger maxBytes) {
    const uint8_t *length = SZFTake(reader, 1);
    if (length == NULL || *length == 0 || *length > maxBytes) return nil;
    NSData *bytes = SZFTakeData(reader, *length);
    NSString *label = bytes ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : nil;
    if (label == nil || ![SZFriendsChainLabel(label, maxBytes) isEqualToString:label]) return nil;
    return label;
}

static void SZFAppendLabel(NSMutableData *out, NSString *label) {
    NSData *bytes = [label dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t length = (uint8_t)bytes.length;
    [out appendBytes:&length length:1];
    [out appendData:bytes];
}

static NSData *SZFLinkHash(NSData *encoded) {
    NSMutableData *input = [[SZFriendsChainHashDomain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [input appendData:encoded];
    unsigned char hash[32];
    crypto_generichash(hash, sizeof hash, input.bytes, input.length, NULL, 0);
    return [NSData dataWithBytes:hash length:sizeof hash];
}

static NSData *SZFSignedMessage(NSData *rootKey, NSData *body) {
    NSMutableData *message = [rootKey mutableCopy];
    [message appendData:body];
    return message;
}

@implementation SZFriendsChainLink

- (instancetype)initWithKind:(SZFriendsChainLinkKind)kind
                     parents:(NSArray<NSData *> *)parents
                      signer:(NSData *)signer
                     subject:(NSData *)subject
                   staticKey:(NSData *)staticKey
                     consent:(NSData *)consent
                        name:(NSString *)name
                      system:(NSString *)system
                milliseconds:(uint64_t)milliseconds
                     encoded:(NSData *)encoded {
    if ((self = [super init])) {
        _kind = kind;
        _parentHashes = [parents copy];
        _signerKey = [signer copy];
        _subjectKey = [subject copy];
        _subjectStaticKey = [staticKey copy];
        _consent = [consent copy];
        _name = [name copy];
        _system = [system copy];
        _milliseconds = milliseconds;
        _date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)milliseconds / 1000.0];
        _encodedData = [encoded copy];
        _linkHash = SZFLinkHash(encoded);
    }
    return self;
}

// The body: every byte the signature covers after the root key.
static NSMutableData *SZFLinkBody(SZFriendsChainLinkKind kind, NSArray<NSData *> *parents, NSData *signer,
                                  NSData *subject, NSData *staticKey, NSString *name, NSString *system,
                                  NSData *consent, uint64_t milliseconds) {
    NSMutableData *body = [NSMutableData data];
    uint8_t head[2] = {SZFLinkVersion, kind};
    [body appendBytes:head length:2];
    uint8_t time[8];
    for (int i = 0; i < 8; i++) time[i] = (uint8_t)(milliseconds >> (56 - 8 * i));
    [body appendBytes:time length:8];
    uint8_t count = (uint8_t)parents.count;
    [body appendBytes:&count length:1];
    for (NSData *parent in parents) [body appendData:parent];
    [body appendData:signer];
    [body appendData:subject];
    if (SZFKindCarriesKeys(kind)) [body appendData:staticKey];
    if (SZFKindCarriesLabels(kind)) {
        SZFAppendLabel(body, name);
        SZFAppendLabel(body, system);
    }
    if (SZFKindCarriesKeys(kind)) [body appendData:consent];
    return body;
}

+ (nullable instancetype)signedLinkWithKind:(SZFriendsChainLinkKind)kind
                                    parents:(NSArray<NSData *> *)parents
                                     signer:(SZFriendsIdentity *)signer
                                    rootKey:(NSData *)rootKey
                                 subjectKey:(NSData *)subjectKey
                                  staticKey:(nullable NSData *)staticKey
                                    consent:(nullable NSData *)consent
                                       name:(nullable NSString *)name
                                     system:(nullable NSString *)system
                                       date:(NSDate *)date
                                      error:(NSError **)error {
    NSString *cleanName = name ? SZFriendsChainLabel(name, SZFriendsDeviceNameMax) : nil;
    NSString *cleanSystem = system ? SZFriendsChainLabel(system, SZFriendsDeviceSystemMax) : nil;
    BOOL keysOK = !SZFKindCarriesKeys(kind) || (staticKey.length == 32 && consent.length == 64);
    BOOL labelsOK = !SZFKindCarriesLabels(kind) || (cleanName.length > 0 && cleanSystem.length > 0);
    if (!keysOK || !labelsOK || subjectKey.length != 32 || rootKey.length != 32 ||
        parents.count > SZFriendsDeviceChainParentsMax) {
        SZFChainFail(error, SZFriendsDeviceChainErrorRefused, @"a link needs both labels and the device's keys");
        return nil;
    }
    double seconds = MAX(date.timeIntervalSince1970, 0);
    uint64_t milliseconds = (uint64_t)llround(seconds * 1000.0);
    NSMutableData *encoded = SZFLinkBody(kind, parents, signer.publicKey, subjectKey, staticKey, cleanName,
                                         cleanSystem, consent, milliseconds);
    NSData *signature = [signer signatureForMessage:SZFSignedMessage(rootKey, encoded) domain:SZFriendsChainLinkDomain];
    [encoded appendData:signature];
    return [[self alloc] initWithKind:kind parents:parents signer:signer.publicKey subject:subjectKey
                            staticKey:staticKey consent:consent name:cleanName system:cleanSystem
                         milliseconds:milliseconds encoded:encoded];
}

+ (nullable instancetype)linkWithData:(NSData *)data rootKey:(nullable NSData *)rootKey error:(NSError **)error {
    SZFChainReader reader = {data.bytes, data.length, 0};
    const uint8_t *head = SZFTake(&reader, 2);
    const uint8_t *time = SZFTake(&reader, 8);
    const uint8_t *count = SZFTake(&reader, 1);
    if (head == NULL || time == NULL || count == NULL || head[0] != SZFLinkVersion ||
        head[1] > SZFriendsChainLinkRename) {
        SZFChainFail(error, SZFriendsDeviceChainErrorMalformed, @"a link of an unknown version or kind");
        return nil;
    }
    SZFriendsChainLinkKind kind = head[1];
    BOOL genesis = kind == SZFriendsChainLinkGenesis;
    if (genesis ? *count != 0 : (*count == 0 || *count > SZFriendsDeviceChainParentsMax)) {
        SZFChainFail(error, SZFriendsDeviceChainErrorMalformed, @"a link with the wrong number of parents");
        return nil;
    }
    uint64_t milliseconds = 0;
    for (int i = 0; i < 8; i++) milliseconds = (milliseconds << 8) | time[i];
    NSMutableArray<NSData *> *parents = [NSMutableArray array];
    for (uint8_t i = 0; i < *count; i++) {
        NSData *parent = SZFTakeData(&reader, 32);
        if (parent == nil || [parents containsObject:parent]) {
            SZFChainFail(error, SZFriendsDeviceChainErrorMalformed, @"a link names a parent twice or is cut");
            return nil;
        }
        [parents addObject:parent];
    }
    NSData *signer = SZFTakeData(&reader, 32), *subject = SZFTakeData(&reader, 32);
    NSData *staticKey = SZFKindCarriesKeys(kind) ? SZFTakeData(&reader, 32) : nil;
    NSString *name = SZFKindCarriesLabels(kind) ? SZFTakeLabel(&reader, SZFriendsDeviceNameMax) : nil;
    NSString *system = SZFKindCarriesLabels(kind) ? SZFTakeLabel(&reader, SZFriendsDeviceSystemMax) : nil;
    NSData *consent = SZFKindCarriesKeys(kind) ? SZFTakeData(&reader, 64) : nil;
    NSUInteger bodyLength = reader.position;
    NSData *signature = SZFTakeData(&reader, 64);
    BOOL fieldsOK = signer && subject && signature && (!SZFKindCarriesKeys(kind) || (staticKey && consent)) &&
                    (!SZFKindCarriesLabels(kind) || (name && system));
    if (!fieldsOK || reader.position != reader.length) {
        SZFChainFail(error, SZFriendsDeviceChainErrorMalformed, @"a link is cut, too long or has a bad label");
        return nil;
    }
    BOOL selfSigned = genesis || kind == SZFriendsChainLinkRename;
    if (selfSigned && ![signer isEqualToData:subject]) {
        SZFChainFail(error, SZFriendsDeviceChainErrorUnauthorized, @"genesis and renames are signed by their device");
        return nil;
    }
    NSData *root = genesis ? signer : rootKey;
    if (root == nil) {
        SZFChainFail(error, SZFriendsDeviceChainErrorMalformed, @"a link before the genesis that names its root");
        return nil;
    }
    if (root.length != 32 || (genesis && rootKey != nil && ![rootKey isEqualToData:signer])) {
        SZFChainFail(error, SZFriendsDeviceChainErrorWrongRoot, @"a genesis signed by another root");
        return nil;
    }
    NSData *body = [data subdataWithRange:NSMakeRange(0, bodyLength)];
    if (![SZFriendsIdentity verifySignature:signature
                                 forMessage:SZFSignedMessage(root, body)
                                     domain:SZFriendsChainLinkDomain
                                  publicKey:signer] ||
        (consent != nil && !SZFriendsVerifyDeviceConsent(consent, subject, staticKey, root))) {
        SZFChainFail(error, SZFriendsDeviceChainErrorForged, @"a link's signature or consent does not verify");
        return nil;
    }
    return [[self alloc] initWithKind:kind parents:parents signer:signer subject:subject staticKey:staticKey
                              consent:consent name:name system:system milliseconds:milliseconds encoded:data];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<SZFriendsChainLink %u %02x%02x%02x%02x>", self.kind,
                                      ((const uint8_t *)_linkHash.bytes)[0], ((const uint8_t *)_linkHash.bytes)[1],
                                      ((const uint8_t *)_linkHash.bytes)[2], ((const uint8_t *)_linkHash.bytes)[3]];
}

@end
