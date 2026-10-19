// The join exchange's messages, codes and keyed tags (SZFriendsJoinInternal.h), and the request a new computer signs.

#import "service/identity/SZFriendsJoinInternal.h"

#import <sodium.h>

#import "service/identity/SZFriendsCPace.h"
#import "service/identity/SZFriendsIdentity.h"

const NSUInteger SZFriendsJoinCodeDigits = 8;
const NSUInteger SZFriendsJoinAttemptsMax = 3;
const NSTimeInterval SZFriendsJoinCodeLifetime = 300;
const NSUInteger SZFriendsJoinOpenRequestsMax = 3;
const NSUInteger SZFriendsJoinNewRequestsPerHour = 6;
const NSTimeInterval SZFriendsJoinRequestLifetime = 1800;
const NSTimeInterval SZFriendsJoinClockSkewMax = 600;
const NSUInteger SZFriendsJoinMessageMax = 1000;
const NSUInteger SZFriendsJoinPartMax = 900;

NSString *const SZFriendsJoinResponderTagDomain = @"SZFriends join responder v1";
NSString *const SZFriendsJoinInitiatorTagDomain = @"SZFriends join initiator v1";
NSString *const SZFriendsJoinWelcomeTagDomain = @"SZFriends join welcome v1";
static NSString *const kRequestDomain = @"SZFriends join request v1";
static NSString *const kChannelDomain = @"SZFriends join v1";
static const uint8_t kVersion = 1;

#pragma mark - Fields

typedef struct {
    uint8_t tag;
    uint16_t min;
    uint16_t max;
} SZFriendsJoinFieldBounds;

static const SZFriendsJoinFieldBounds kBounds[] = {
    {SZFriendsJoinTagRequestID, 16, 16},  {SZFriendsJoinTagDeviceKey, 32, 32}, {SZFriendsJoinTagStaticKey, 32, 32},
    {SZFriendsJoinTagName, 1, 64},        {SZFriendsJoinTagSystem, 1, 64},     {SZFriendsJoinTagFriendsID, 1, 64},
    {SZFriendsJoinTagTime, 8, 8},         {SZFriendsJoinTagSignature, 64, 64}, {SZFriendsJoinTagShare, 32, 32},
    {SZFriendsJoinTagRootKey, 32, 32},    {SZFriendsJoinTagTag, 32, 32},       {SZFriendsJoinTagConsent, 64, 64},
    {SZFriendsJoinTagPartIndex, 1, 1},    {SZFriendsJoinTagPartCount, 1, 1},   {SZFriendsJoinTagPartData, 1, 900},
    {SZFriendsJoinTagReason, 1, 1},       {SZFriendsJoinTagChain, 1, 64000},   {SZFriendsJoinTagProfile, 1, 65535},
    {SZFriendsJoinTagIDState, 1, 1},      {SZFriendsJoinTagApproverKey, 32, 32},
};

static const SZFriendsJoinFieldBounds *BoundsOf(uint8_t tag) {
    for (size_t i = 0; i < sizeof kBounds / sizeof kBounds[0]; i++) {
        if (kBounds[i].tag == tag) return &kBounds[i];
    }
    return NULL;
}

// Exactly the fields each kind carries.
static NSArray<NSNumber *> *FieldsOfKind(SZFriendsJoinMessageKind kind) {
    switch ((uint8_t)kind) {
    case SZFriendsJoinMessageRequest:
        return @[ @1, @2, @3, @4, @5, @6, @7, @8 ];
    case SZFriendsJoinMessageCode:
        return @[ @(SZFriendsJoinTagRequestID), @(SZFriendsJoinTagShare) ];
    case SZFriendsJoinMessageReply:
        return @[ @(SZFriendsJoinTagShare), @(SZFriendsJoinTagRootKey), @(SZFriendsJoinTagTag),
                  @(SZFriendsJoinTagApproverKey) ];
    case SZFriendsJoinMessageConfirm:
        return @[ @(SZFriendsJoinTagTag), @(SZFriendsJoinTagConsent) ];
    case SZFriendsJoinMessagePart:
        return @[ @(SZFriendsJoinTagPartIndex), @(SZFriendsJoinTagPartCount), @(SZFriendsJoinTagPartData) ];
    case SZFriendsJoinMessageEnded:
        return @[ @(SZFriendsJoinTagReason) ];
    case 7: // SZFriendsJoinMessageWelcome
        return @[ @(SZFriendsJoinTagTag), @(SZFriendsJoinTagChain), @(SZFriendsJoinTagProfile),
                  @(SZFriendsJoinTagIDState) ];
    default:
        return nil;
    }
}

// Names are shown on the person's other computers: valid UTF-8 and no control characters, as chain labels.
static BOOL LabelIsClean(NSData *bytes) {
    NSString *text = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
    if (text == nil || text.length == 0) return NO;
    NSRange bad = [text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet];
    return bad.location == NSNotFound && [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                                                 .length > 0;
}

static BOOL FieldIsValid(uint8_t tag, NSData *value) {
    const SZFriendsJoinFieldBounds *bounds = BoundsOf(tag);
    if (bounds == NULL || value.length < bounds->min || value.length > bounds->max) return NO;
    if (tag == SZFriendsJoinTagName || tag == SZFriendsJoinTagSystem || tag == SZFriendsJoinTagFriendsID) {
        return LabelIsClean(value);
    }
    if (tag == SZFriendsJoinTagPartCount) return ((const uint8_t *)value.bytes)[0] >= 1;
    return YES;
}

NSData *SZFriendsJoinEncode(SZFriendsJoinMessageKind kind, NSDictionary<NSNumber *, NSData *> *fields) {
    NSArray<NSNumber *> *tags = FieldsOfKind(kind);
    if (tags == nil || fields.count != tags.count) return nil;
    NSMutableData *out = [NSMutableData dataWithCapacity:256];
    uint8_t head[2] = {kVersion, (uint8_t)kind};
    [out appendBytes:head length:2];
    for (NSNumber *tag in [tags sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *value = fields[tag];
        if (value == nil || !FieldIsValid(tag.unsignedCharValue, value)) return nil;
        uint8_t field[3] = {tag.unsignedCharValue, (uint8_t)(value.length >> 8), (uint8_t)value.length};
        [out appendBytes:field length:3];
        [out appendData:value];
    }
    return out;
}

NSDictionary<NSNumber *, NSData *> *SZFriendsJoinDecode(NSData *message, SZFriendsJoinMessageKind kind) {
    NSArray<NSNumber *> *tags = FieldsOfKind(kind);
    const uint8_t *bytes = message.bytes;
    NSUInteger length = message.length;
    if (tags == nil || length < 2 || bytes[0] != kVersion || bytes[1] != (uint8_t)kind) return nil;
    if (kind != SZFriendsJoinMessageWelcome && length > SZFriendsJoinMessageMax) return nil;
    NSMutableDictionary<NSNumber *, NSData *> *fields = [NSMutableDictionary dictionary];
    NSUInteger offset = 2;
    int previous = -1;
    while (offset < length) {
        if (length - offset < 3) return nil;
        uint8_t tag = bytes[offset];
        NSUInteger size = ((NSUInteger)bytes[offset + 1] << 8) | bytes[offset + 2];
        offset += 3;
        if ((int)tag <= previous || size > length - offset || ![tags containsObject:@(tag)]) return nil;
        NSData *value = [message subdataWithRange:NSMakeRange(offset, size)];
        if (!FieldIsValid(tag, value)) return nil;
        fields[@(tag)] = value;
        previous = tag;
        offset += size;
    }
    return fields.count == tags.count ? fields : nil;
}

SZFriendsJoinMessageKind SZFriendsJoinMessageKindOf(NSData *message) {
    if (message.length < 2) return 0;
    const uint8_t *bytes = message.bytes;
    uint8_t kind = bytes[1];
    return bytes[0] == kVersion && kind >= SZFriendsJoinMessageRequest && kind <= SZFriendsJoinMessageEnded
               ? (SZFriendsJoinMessageKind)kind
               : 0;
}

NSData *SZFriendsJoinUInt8(uint8_t value) { return [NSData dataWithBytes:&value length:1]; }

NSData *SZFriendsJoinUInt64(uint64_t value) {
    uint8_t bytes[8];
    for (int i = 0; i < 8; i++) bytes[i] = (uint8_t)(value >> (56 - 8 * i));
    return [NSData dataWithBytes:bytes length:8];
}

uint64_t SZFriendsJoinReadUInt64(NSData *data) {
    if (data.length != 8) return 0;
    const uint8_t *bytes = data.bytes;
    uint64_t value = 0;
    for (int i = 0; i < 8; i++) value = (value << 8) | bytes[i];
    return value;
}

NSData *SZFriendsJoinEndedMessage(SZFriendsJoinEndReason reason) {
    return SZFriendsJoinEncode(SZFriendsJoinMessageEnded, @{@(SZFriendsJoinTagReason) : SZFriendsJoinUInt8(reason)});
}

SZFriendsJoinEndReason SZFriendsJoinEndReasonOf(NSData *message) {
    NSData *reason = SZFriendsJoinDecode(message, SZFriendsJoinMessageEnded)[@(SZFriendsJoinTagReason)];
    uint8_t value = reason.length == 1 ? ((const uint8_t *)reason.bytes)[0] : 0;
    return value >= SZFriendsJoinEndDenied && value <= SZFriendsJoinEndTooManyAttempts ? value : 0;
}

#pragma mark - Codes

NSString *SZFriendsJoinNewCode(void) {
    // 10^8 fits a u32, and randombytes_uniform draws without modulo bias.
    return [NSString stringWithFormat:@"%08u", randombytes_uniform(100000000u)];
}

NSString *SZFriendsJoinNormalizedCode(NSString *typed) {
    NSMutableString *digits = [NSMutableString string];
    __block BOOL bad = NO;
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@" -   ‑　"];
    [typed enumerateSubstringsInRange:NSMakeRange(0, typed.length)
                              options:NSStringEnumerationByComposedCharacterSequences
                           usingBlock:^(NSString *character, NSRange r, NSRange e, BOOL *stop) {
                               (void)r;
                               (void)e;
                               unichar c = character.length == 1 ? [character characterAtIndex:0] : 0;
                               if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
                               else if (c >= 0xFF10 && c <= 0xFF19) [digits appendFormat:@"%C", (unichar)(c - 0xFEE0)];
                               else if (c == 0 || ![separators characterIsMember:c]) bad = *stop = YES;
                           }];
    return !bad && digits.length == SZFriendsJoinCodeDigits ? digits : nil;
}

#pragma mark - Tags

NSData *SZFriendsJoinTag(NSData *isk, NSString *domain, NSData *extra) {
    NSMutableData *input = [[domain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (extra != nil) [input appendData:extra];
    NSMutableData *tag = [NSMutableData dataWithLength:32];
    crypto_generichash(tag.mutableBytes, 32, input.bytes, input.length, isk.bytes, isk.length);
    return tag;
}

BOOL SZFriendsJoinTagsEqual(NSData *a, NSData *b) {
    return a.length == 32 && b.length == 32 && sodium_memcmp(a.bytes, b.bytes, 32) == 0;
}

NSData *SZFriendsJoinChannelIdentifier(NSData *requestID, NSData *deviceKey, NSData *staticKey) {
    return SZFriendsCPaceLVCat(@[ [kChannelDomain dataUsingEncoding:NSUTF8StringEncoding], requestID, deviceKey,
                                  staticKey ]);
}

NSData *SZFriendsJoinApproverAD(NSData *approverKey, NSData *rootKey) {
    NSMutableData *ad = [approverKey mutableCopy];
    [ad appendData:rootKey];
    return ad;
}

#pragma mark - Requests

static NSData *SignedPart(NSDictionary<NSNumber *, NSData *> *fields) {
    // The request's fields without the signature, in order, each as tag || length || value.
    NSMutableData *out = [NSMutableData data];
    for (uint8_t tag = SZFriendsJoinTagRequestID; tag < SZFriendsJoinTagSignature; tag++) {
        NSData *value = fields[@(tag)];
        uint8_t head[3] = {tag, (uint8_t)(value.length >> 8), (uint8_t)value.length};
        [out appendBytes:head length:3];
        if (value) [out appendData:value];
    }
    return out;
}

NSData *SZFriendsJoinRequestMessage(SZFriendsIdentity *device, NSData *requestID, NSString *friendsID,
                                    NSString *name, NSString *system, NSDate *now) {
    NSData *nameBytes = [name dataUsingEncoding:NSUTF8StringEncoding];
    NSData *systemBytes = [system dataUsingEncoding:NSUTF8StringEncoding];
    NSData *idBytes = [friendsID dataUsingEncoding:NSUTF8StringEncoding];
    if (requestID.length != 16 || !nameBytes || !systemBytes || !idBytes) return nil;
    NSMutableDictionary<NSNumber *, NSData *> *fields = [@{
        @(SZFriendsJoinTagRequestID) : requestID,
        @(SZFriendsJoinTagDeviceKey) : device.publicKey,
        @(SZFriendsJoinTagStaticKey) : device.staticPublicKey,
        @(SZFriendsJoinTagName) : nameBytes,
        @(SZFriendsJoinTagSystem) : systemBytes,
        @(SZFriendsJoinTagFriendsID) : idBytes,
        @(SZFriendsJoinTagTime) : SZFriendsJoinUInt64((uint64_t)llround(now.timeIntervalSince1970 * 1000)),
    } mutableCopy];
    fields[@(SZFriendsJoinTagSignature)] = [device signatureForMessage:SignedPart(fields) domain:kRequestDomain];
    return SZFriendsJoinEncode(SZFriendsJoinMessageRequest, fields);
}

NSDictionary<NSNumber *, NSData *> *SZFriendsJoinVerifiedRequest(NSData *message) {
    NSDictionary<NSNumber *, NSData *> *fields = SZFriendsJoinDecode(message, SZFriendsJoinMessageRequest);
    if (fields == nil) return nil;
    BOOL valid = [SZFriendsIdentity verifySignature:fields[@(SZFriendsJoinTagSignature)]
                                         forMessage:SignedPart(fields)
                                             domain:kRequestDomain
                                          publicKey:fields[@(SZFriendsJoinTagDeviceKey)]];
    return valid ? fields : nil;
}

#pragma mark - Value objects

@implementation SZFriendsJoinRequest

- (instancetype)initWithFields:(NSDictionary<NSNumber *, NSData *> *)fields receivedAt:(NSDate *)receivedAt {
    self = [super init];
    if (self == nil) return nil;
    _requestID = fields[@(SZFriendsJoinTagRequestID)];
    _deviceKey = fields[@(SZFriendsJoinTagDeviceKey)];
    _staticKey = fields[@(SZFriendsJoinTagStaticKey)];
    _name = [[NSString alloc] initWithData:fields[@(SZFriendsJoinTagName)] encoding:NSUTF8StringEncoding];
    _system = [[NSString alloc] initWithData:fields[@(SZFriendsJoinTagSystem)] encoding:NSUTF8StringEncoding];
    _friendsID = [[NSString alloc] initWithData:fields[@(SZFriendsJoinTagFriendsID)] encoding:NSUTF8StringEncoding];
    _sentAt = [NSDate dateWithTimeIntervalSince1970:SZFriendsJoinReadUInt64(fields[@(SZFriendsJoinTagTime)]) / 1000.0];
    _receivedAt = receivedAt;
    _lastHeardAt = receivedAt;
    _state = SZFriendsJoinRequestWaiting;
    return self;
}

@end

@implementation SZFriendsJoinStep

+ (instancetype)stepWithKind:(SZFriendsJoinStepKind)kind {
    SZFriendsJoinStep *step = [[self alloc] init];
    step->_kind = kind;
    return step;
}

+ (instancetype)sendStep:(NSData *)message {
    SZFriendsJoinStep *step = [self stepWithKind:SZFriendsJoinStepSend];
    step->_message = message;
    return step;
}

+ (instancetype)endedStep:(SZFriendsJoinEndReason)reason {
    SZFriendsJoinStep *step = [self stepWithKind:reason != 0 ? SZFriendsJoinStepEnded : SZFriendsJoinStepFailed];
    step->_reason = reason;
    return step;
}

+ (instancetype)joinedStepWithChain:(SZFriendsDeviceChain *)chain profile:(NSData *)profile state:(NSInteger)state {
    SZFriendsJoinStep *step = [self stepWithKind:SZFriendsJoinStepJoined];
    step->_chain = chain;
    step->_profile = profile;
    step->_friendsIDState = state;
    return step;
}

@end
