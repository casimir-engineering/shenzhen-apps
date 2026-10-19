// Signalling items (SZFriendsSignaling.h): the one format every signalling payload and rendezvous record body uses.
// Pure: no keys here; SZFriendsSignalingNoise.m, SZFriendsSignalingLink.m and SZFriendsSignalingRecord.m seal it.

#import "service/session/SZFriendsSignaling.h"

#import "service/session/SZFriendsFrameSchema.h"

const NSUInteger SZFriendsSignalPayloadMax = 4096;
const NSUInteger SZFriendsSignalSDPMax = 3072;
const NSUInteger SZFriendsSignalCandidateMax = 256;
const NSUInteger SZFriendsSignalFrameMax = 1024;
const NSTimeInterval SZFriendsSignalClockSkewMax = 300;
const uint16_t SZFriendsSignalMinor = 0;

typedef struct {
    uint16_t min, max;
} SZFriendsSignalLength;

// Lengths of every known field; {0, 0} for a tag this build does not know (skipped when read).
static SZFriendsSignalLength SZFriendsSignalFieldLength(uint8_t tag) {
    switch ((SZFriendsSignalTag)tag) {
    case SZFriendsSignalTagConnection:
    case SZFriendsSignalTagKind:
    case SZFriendsSignalTagTechnique:
    case SZFriendsSignalTagNATClass:
    case SZFriendsSignalTagReason:
        return (SZFriendsSignalLength){1, 1};
    case SZFriendsSignalTagNATStep:
    case SZFriendsSignalTagMinorMin:
    case SZFriendsSignalTagMinorMax:
        return (SZFriendsSignalLength){2, 2};
    case SZFriendsSignalTagTime:
        return (SZFriendsSignalLength){8, 8};
    case SZFriendsSignalTagToken:
        return (SZFriendsSignalLength){16, 16};
    case SZFriendsSignalTagFingerprint:
    case SZFriendsSignalTagNonce:
    case SZFriendsSignalTagProof:
        return (SZFriendsSignalLength){32, 32};
    case SZFriendsSignalTagCertificate:
        return (SZFriendsSignalLength){96, 96};
    case SZFriendsSignalTagSDP:
        return (SZFriendsSignalLength){1, (uint16_t)SZFriendsSignalSDPMax};
    case SZFriendsSignalTagCandidate:
        return (SZFriendsSignalLength){1, (uint16_t)SZFriendsSignalCandidateMax};
    case SZFriendsSignalTagAttestation:
        return (SZFriendsSignalLength){1, (uint16_t)SZFriendsAttestationMax};
    case SZFriendsSignalTagFrame:
        return (SZFriendsSignalLength){1, (uint16_t)SZFriendsSignalFrameMax};
    }
    return (SZFriendsSignalLength){0, 0};
}

// The fields each known type must carry; nil for a type this build does not know.
static NSArray<NSNumber *> *SZFriendsSignalRequiredTags(uint8_t type) {
    switch ((SZFriendsSignalItemType)type) {
    case SZFriendsSignalItemHello:
        return @[ @(SZFriendsSignalTagMinorMin), @(SZFriendsSignalTagMinorMax) ];
    case SZFriendsSignalItemDescription:
        return @[ @(SZFriendsSignalTagConnection), @(SZFriendsSignalTagKind), @(SZFriendsSignalTagSDP),
                  @(SZFriendsSignalTagFingerprint) ];
    case SZFriendsSignalItemCandidate:
        return @[ @(SZFriendsSignalTagConnection), @(SZFriendsSignalTagTechnique), @(SZFriendsSignalTagCandidate) ];
    case SZFriendsSignalItemCandidatesEnd:
        return @[ @(SZFriendsSignalTagConnection) ];
    case SZFriendsSignalItemNAT:
        return @[ @(SZFriendsSignalTagNATClass) ];
    case SZFriendsSignalItemStart:
        return @[ @(SZFriendsSignalTagConnection), @(SZFriendsSignalTagKind) ];
    case SZFriendsSignalItemFrame:
        return @[ @(SZFriendsSignalTagFrame) ];
    case SZFriendsSignalItemEnd:
        return @[ @(SZFriendsSignalTagReason) ];
    case SZFriendsSignalItemLinkNonce:
    case SZFriendsSignalItemLinkChallenge:
        return @[ @(SZFriendsSignalTagNonce) ];
    case SZFriendsSignalItemLinkProof:
        return @[ @(SZFriendsSignalTagProof) ];
    }
    return nil;
}

// SDP is UTF-8 without NUL; a candidate line is printable ASCII, so it can never smuggle a second SDP line (CR LF)
// into whatever the transport builds from it.
static BOOL SZFriendsSignalTextValid(uint8_t tag, NSData *value) {
    if (tag != SZFriendsSignalTagSDP && tag != SZFriendsSignalTagCandidate) return YES;
    const uint8_t *bytes = value.bytes;
    for (NSUInteger i = 0; i < value.length; i++) {
        if (bytes[i] == 0) return NO;
        if (tag == SZFriendsSignalTagCandidate && (bytes[i] < 0x20 || bytes[i] > 0x7e)) return NO;
    }
    return [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding] != nil;
}

static NSError *SZFriendsSignalInvalid(NSString *reason) {
    return SZFriendsSessionMakeError(SZFriendsSessionErrorFrameInvalid, reason);
}

static NSData *SZFriendsSignalUInt(uint64_t value, NSUInteger width) {
    uint8_t bytes[8];
    for (NSUInteger i = 0; i < width; i++) bytes[i] = (uint8_t)(value >> (8 * (width - 1 - i)));
    return [NSData dataWithBytes:bytes length:width];
}

@implementation SZFriendsSignalItem

+ (instancetype)itemWithType:(SZFriendsSignalItemType)type fields:(NSDictionary<NSNumber *, NSData *> *)fields {
    SZFriendsSignalItem *item = [[self alloc] init];
    item->_type = type;
    item->_fields = [fields copy];
    return item;
}

+ (instancetype)descriptionWithConnection:(uint8_t)connection
                                     kind:(uint8_t)kind
                                      sdp:(NSString *)sdp
                              fingerprint:(NSData *)fingerprint {
    return [self itemWithType:SZFriendsSignalItemDescription
                       fields:@{
                           @(SZFriendsSignalTagConnection) : SZFriendsSignalUInt(connection, 1),
                           @(SZFriendsSignalTagKind) : SZFriendsSignalUInt(kind, 1),
                           @(SZFriendsSignalTagSDP) : [sdp dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data],
                           @(SZFriendsSignalTagFingerprint) : fingerprint,
                       }];
}

+ (instancetype)candidateWithConnection:(uint8_t)connection technique:(uint8_t)technique line:(NSString *)line {
    return [self itemWithType:SZFriendsSignalItemCandidate
                       fields:@{
                           @(SZFriendsSignalTagConnection) : SZFriendsSignalUInt(connection, 1),
                           @(SZFriendsSignalTagTechnique) : SZFriendsSignalUInt(technique, 1),
                           @(SZFriendsSignalTagCandidate) : [line dataUsingEncoding:NSUTF8StringEncoding]
                               ?: [NSData data],
                       }];
}

+ (instancetype)candidatesEndWithConnection:(uint8_t)connection {
    return [self itemWithType:SZFriendsSignalItemCandidatesEnd
                       fields:@{@(SZFriendsSignalTagConnection) : SZFriendsSignalUInt(connection, 1)}];
}

+ (instancetype)natWithClass:(SZFriendsSignalNATClass)natClass step:(int16_t)step {
    NSMutableDictionary *fields = [@{@(SZFriendsSignalTagNATClass) : SZFriendsSignalUInt(natClass, 1)} mutableCopy];
    if (natClass == SZFriendsSignalNATPerDestination) {
        fields[@(SZFriendsSignalTagNATStep)] = SZFriendsSignalUInt((uint16_t)step, 2);
    }
    return [self itemWithType:SZFriendsSignalItemNAT fields:fields];
}

+ (instancetype)startWithConnection:(uint8_t)connection kind:(uint8_t)kind {
    return [self itemWithType:SZFriendsSignalItemStart
                       fields:@{
                           @(SZFriendsSignalTagConnection) : SZFriendsSignalUInt(connection, 1),
                           @(SZFriendsSignalTagKind) : SZFriendsSignalUInt(kind, 1),
                       }];
}

+ (instancetype)frameItemWithData:(NSData *)encodedFrame {
    return [self itemWithType:SZFriendsSignalItemFrame fields:@{@(SZFriendsSignalTagFrame) : encodedFrame}];
}

+ (instancetype)endWithReason:(SZFriendsSignalEndReason)reason {
    return [self itemWithType:SZFriendsSignalItemEnd
                       fields:@{@(SZFriendsSignalTagReason) : SZFriendsSignalUInt(reason, 1)}];
}

- (NSData *)dataForTag:(SZFriendsSignalTag)tag {
    return _fields[@(tag)];
}

- (NSString *)stringForTag:(SZFriendsSignalTag)tag {
    NSData *value = _fields[@(tag)];
    return value ? [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding] : nil;
}

- (BOOL)getUnsigned:(uint64_t *)value forTag:(SZFriendsSignalTag)tag {
    NSData *data = _fields[@(tag)];
    if (data == nil || data.length > 8) return NO;
    uint64_t result = 0;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) result = (result << 8) | bytes[i];
    *value = result;
    return YES;
}

- (int16_t)natStep {
    uint64_t raw = 0;
    return [self getUnsigned:&raw forTag:SZFriendsSignalTagNATStep] ? (int16_t)(uint16_t)raw : 0;
}

@end

static void SZFriendsAppendU16(NSMutableData *output, NSUInteger value) {
    uint8_t bytes[2] = {(uint8_t)(value >> 8), (uint8_t)value};
    [output appendBytes:bytes length:2];
}

// Checks one item's fields for its type, whether encoding or decoding. Unknown tags were dropped before.
static BOOL SZFriendsSignalItemValid(uint8_t type, NSDictionary<NSNumber *, NSData *> *fields, NSString **reason) {
    for (NSNumber *tag in SZFriendsSignalRequiredTags(type)) {
        if (fields[tag] == nil) {
            *reason = [NSString stringWithFormat:@"item %u lacks field %@", type, tag];
            return NO;
        }
    }
    for (NSNumber *tag in fields) {
        SZFriendsSignalLength length = SZFriendsSignalFieldLength(tag.unsignedCharValue);
        NSData *value = fields[tag];
        if (length.max == 0 || value.length < length.min || value.length > length.max ||
            !SZFriendsSignalTextValid(tag.unsignedCharValue, value)) {
            *reason = [NSString stringWithFormat:@"item %u field %@ is invalid", type, tag];
            return NO;
        }
    }
    return YES;
}

NSData *SZFriendsEncodeSignalItems(NSArray<SZFriendsSignalItem *> *items, NSUInteger capacity, NSError **error) {
    NSMutableData *output = [NSMutableData data];
    for (SZFriendsSignalItem *item in items) {
        NSString *reason = nil;
        if (SZFriendsSignalRequiredTags(item.type) == nil || item.fields.count == 0 ||
            !SZFriendsSignalItemValid(item.type, item.fields, &reason)) {
            if (error) *error = SZFriendsSignalInvalid(reason ?: @"unknown or empty item");
            return nil;
        }
        NSMutableData *value = [NSMutableData data];
        NSArray<NSNumber *> *tags = [item.fields.allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (NSNumber *tag in tags) {
            uint8_t tagByte = tag.unsignedCharValue;
            [value appendBytes:&tagByte length:1];
            SZFriendsAppendU16(value, item.fields[tag].length);
            [value appendData:item.fields[tag]];
        }
        if (value.length > UINT16_MAX) {
            if (error) *error = SZFriendsSignalInvalid(@"item too long");
            return nil;
        }
        uint8_t type = item.type;
        [output appendBytes:&type length:1];
        SZFriendsAppendU16(output, value.length);
        [output appendData:value];
    }
    if (output.length == 0 || output.length > capacity) {
        if (error) *error = SZFriendsSignalInvalid(@"no items, or more than fit");
        return nil;
    }
    return output;
}

// Fields of one item value; nil for a truncated field or a duplicate tag. Unknown tags are skipped.
static NSDictionary<NSNumber *, NSData *> *SZFriendsDecodeSignalFields(const uint8_t *bytes, NSUInteger length) {
    NSMutableDictionary<NSNumber *, NSData *> *fields = [NSMutableDictionary dictionary];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    NSUInteger offset = 0;
    while (offset < length) {
        if (length - offset < 3) return nil;
        uint8_t tag = bytes[offset];
        NSUInteger fieldLength = ((NSUInteger)bytes[offset + 1] << 8) | bytes[offset + 2];
        offset += 3;
        if (fieldLength > length - offset || [seen containsObject:@(tag)]) return nil;
        [seen addObject:@(tag)];
        if (SZFriendsSignalFieldLength(tag).max != 0) {
            fields[@(tag)] = [NSData dataWithBytes:bytes + offset length:fieldLength];
        }
        offset += fieldLength;
    }
    return fields;
}

NSArray<SZFriendsSignalItem *> *SZFriendsDecodeSignalItems(NSData *plaintext, NSError **error) {
    const uint8_t *bytes = plaintext.bytes;
    NSUInteger length = plaintext.length, offset = 0;
    NSMutableArray<SZFriendsSignalItem *> *items = [NSMutableArray array];
    if (length == 0 || length > SZFriendsSignalPayloadMax) {
        if (error) *error = SZFriendsSignalInvalid(@"empty or oversized signalling plaintext");
        return nil;
    }
    while (offset < length) {
        NSUInteger itemLength = length - offset >= 3 ? ((NSUInteger)bytes[offset + 1] << 8) | bytes[offset + 2] : 0;
        if (length - offset < 3 || itemLength > length - offset - 3) {
            if (error) *error = SZFriendsSignalInvalid(@"truncated signalling item");
            return nil;
        }
        uint8_t type = bytes[offset];
        NSDictionary *fields = SZFriendsDecodeSignalFields(bytes + offset + 3, itemLength);
        offset += 3 + itemLength;
        NSString *reason = nil;
        if (fields == nil) {
            if (error) *error = SZFriendsSignalInvalid(@"malformed signalling fields");
            return nil;
        }
        if (SZFriendsSignalRequiredTags(type) == nil) continue; // a later version's item
        if (!SZFriendsSignalItemValid(type, fields, &reason)) {
            if (error) *error = SZFriendsSignalInvalid(reason);
            return nil;
        }
        [items addObject:[SZFriendsSignalItem itemWithType:type fields:fields]];
    }
    return items;
}
