// SZFriendsFrame and the transport frame codec (SZFriendsSession.h § Frames).

#import "service/session/SZFriendsFrameSchema.h"

@implementation SZFriendsFrame

- (instancetype)initWithType:(SZFriendsFrameType)type fields:(NSDictionary<NSNumber *, NSData *> *)fields {
    if ((self = [super init])) {
        _type = type;
        _fields = [fields copy];
    }
    return self;
}

+ (instancetype)frameWithType:(SZFriendsFrameType)type fields:(NSDictionary<NSNumber *, NSData *> *)fields {
    return [[self alloc] initWithType:type fields:fields];
}

// A frame built in memory has not been through the codec yet, so the accessors apply the same rule the decoder
// would rather than trusting the dictionary.
- (NSData *)dataForTag:(SZFriendsFieldTag)tag {
    SZFriendsFieldRules rules;
    if (!SZFriendsFrameRulesForType(_type, &rules)) {
        return nil;
    }
    const SZFriendsFieldRule *rule = SZFriendsFindFieldRule(rules, tag);
    NSData *value = _fields[@(tag)];
    if (rule == NULL || ![value isKindOfClass:[NSData class]] || !SZFriendsFieldValueAllowed(rule, value)) {
        return nil;
    }
    return value;
}

- (NSString *)stringForTag:(SZFriendsFieldTag)tag {
    NSData *value = [self dataForTag:tag];
    return value ? [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding] : nil;
}

- (BOOL)getUInt64:(uint64_t *)value forTag:(SZFriendsFieldTag)tag {
    NSUInteger width = SZFriendsIntegerFieldWidth(tag);
    NSData *data = [self dataForTag:tag];
    if (width == 0 || data.length != width) {
        return NO;
    }
    const uint8_t *bytes = data.bytes;
    uint64_t result = 0;
    for (NSUInteger i = 0; i < width; i++) {
        result = (result << 8) | bytes[i];
    }
    if (value) {
        *value = result;
    }
    return YES;
}

+ (NSData *)fieldWithUInt64:(uint64_t)value tag:(SZFriendsFieldTag)tag {
    NSUInteger width = SZFriendsIntegerFieldWidth(tag);
    if (width == 0 || (width < 8 && value >> (8 * width) != 0)) {
        return nil;
    }
    uint8_t bytes[8];
    for (NSUInteger i = 0; i < width; i++) {
        bytes[i] = (uint8_t)(value >> (8 * (width - 1 - i)));
    }
    return [NSData dataWithBytes:bytes length:width];
}

// Tags only, never values: frames carry message text, keys and secrets, none of which belong in a log.
- (NSString *)description {
    NSArray *tags = [_fields.allKeys sortedArrayUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"<SZFriendsFrame type=%u tags=%@>", (unsigned)_type,
                                      [tags componentsJoinedByString:@","]];
}

@end

NSData *SZFriendsEncodeFrame(SZFriendsFrame *frame, NSError **error) {
    SZFriendsFieldRules rules;
    uint8_t type = frame.type;
    if (!SZFriendsFrameRulesForType(type, &rules)) {
        if (error) {
            *error = SZFriendsSessionMakeError(SZFriendsSessionErrorFrameInvalid,
                                               [NSString stringWithFormat:@"unknown frame type %u", type]);
        }
        return nil;
    }
    NSMutableData *output = [NSMutableData dataWithBytes:&type length:1];
    if (!SZFriendsAppendFields(output, frame.fields, rules, error)) {
        return nil;
    }
    if (output.length > SZFriendsFramePlaintextMax) {
        if (error) {
            *error = SZFriendsSessionMakeError(SZFriendsSessionErrorFrameInvalid, @"frame over the plaintext limit");
        }
        return nil;
    }
    return output;
}

SZFriendsFrame *SZFriendsDecodeFrame(NSData *plaintext, NSError **error) {
    if (plaintext.length == 0 || plaintext.length > SZFriendsFramePlaintextMax) {
        if (error) {
            *error = SZFriendsSessionMakeError(SZFriendsSessionErrorFrameInvalid,
                                               [NSString stringWithFormat:@"frame of %lu bytes",
                                                                          (unsigned long)plaintext.length]);
        }
        return nil;
    }
    uint8_t type = ((const uint8_t *)plaintext.bytes)[0];
    SZFriendsFieldRules rules;
    if (!SZFriendsFrameRulesForType(type, &rules)) {
        if (error) {
            *error = SZFriendsSessionMakeError(SZFriendsSessionErrorFrameInvalid,
                                               [NSString stringWithFormat:@"unknown frame type %u", type]);
        }
        return nil;
    }
    NSDictionary<NSNumber *, NSData *> *fields = SZFriendsDecodeFields(plaintext, 1, rules, error);
    return fields ? [SZFriendsFrame frameWithType:(SZFriendsFrameType)type fields:fields] : nil;
}
