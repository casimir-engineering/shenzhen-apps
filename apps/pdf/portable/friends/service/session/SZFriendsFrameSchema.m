// Per-type field rules and the field walker (SZFriendsFrameSchema.h).
//
// Limits are format bounds, not product rules: a name may be 1,024 bytes here while the presentation layer allows
// 40 characters, because the codec's job is to refuse what no honest peer sends before anything is allocated,
// and the store and presentation apply the product's own rules afterwards.

#import "service/session/SZFriendsFrameSchema.h"

#define RULE(tag_, min_, max_, flags_) {(uint8_t)(tag_), (uint16_t)(min_), (uint16_t)(max_), (uint8_t)(flags_)}
#define REQ SZFriendsFieldRuleRequired
#define ID_RULE RULE(SZFriendsFieldID, 16, 16, REQ)

enum {
    kNameMax = 1024,        // file names and display names, in UTF-8 bytes
    kFileTypeMax = 256,     // a uniform type identifier or an extension
    kFriendsIDMax = 64,     // "word-word-word" is at most 26 bytes; room for a longer future list
    kOfferIDsMax = 20 * 16, // PROTOCOL.md § Limits: 20 attachments per message
    kAttestationMax = 512,  // SZFriendsAttestationMax
};

static const SZFriendsFieldRule kProfile[] = {
    RULE(SZFriendsFieldName, 0, kNameMax, 0),
    RULE(SZFriendsFieldFriendsID, 0, kFriendsIDMax, 0),
    RULE(SZFriendsFieldPictureSet, 2, 2, 0),
    RULE(SZFriendsFieldPictureIndex, 2, 2, 0),
    RULE(SZFriendsFieldData, 1, 49152, 0), // SZFriendsFramePictureMax
    RULE(SZFriendsFieldAttestation, 1, kAttestationMax, 0),
};
static const SZFriendsFieldRule kPresenceSecret[] = {ID_RULE, RULE(SZFriendsFieldSecret, 32, 32, REQ)};
static const SZFriendsFieldRule kRequest[] = {
    ID_RULE,
    RULE(SZFriendsFieldSentAt, 8, 8, REQ),
    RULE(SZFriendsFieldText, 0, 32768, 0), // SZFriendsFrameTextMax
};
static const SZFriendsFieldRule kIDOnly[] = {ID_RULE};
static const SZFriendsFieldRule kIDAndReason[] = {ID_RULE, RULE(SZFriendsFieldReason, 1, 1, 0)};
static const SZFriendsFieldRule kRequestByID[] = {
    RULE(SZFriendsFieldFriendsID, 1, kFriendsIDMax, REQ),
    RULE(SZFriendsFieldToken, 16, 16, REQ),
    RULE(SZFriendsFieldCallbackSecret, 32, 32, REQ),
    RULE(SZFriendsFieldCertificate, 96, 96, REQ),
    RULE(SZFriendsFieldStaticKey, 32, 32, REQ),
    RULE(SZFriendsFieldSignature, 64, 64, REQ),
    RULE(SZFriendsFieldInviteProof, 32, 32, 0),
};
static const SZFriendsFieldRule kCodeCommit[] = {RULE(SZFriendsFieldCommitment, 32, 32, REQ)};
static const SZFriendsFieldRule kCodeNonce[] = {RULE(SZFriendsFieldNonce, 32, 32, REQ)};
static const SZFriendsFieldRule kMessage[] = {
    ID_RULE,
    RULE(SZFriendsFieldSentAt, 8, 8, REQ),
    RULE(SZFriendsFieldText, 0, 32768, 0),
    RULE(SZFriendsFieldOfferIDs, 16, kOfferIDsMax, SZFriendsFieldRuleMultipleOf16),
    RULE(SZFriendsFieldViaAssistant, 1, 1, SZFriendsFieldRuleBoolean),
};
static const SZFriendsFieldRule kOffer[] = {
    ID_RULE,
    RULE(SZFriendsFieldName, 1, kNameMax, REQ),
    RULE(SZFriendsFieldFileType, 0, kFileTypeMax, 0),
    RULE(SZFriendsFieldSize, 8, 8, REQ),
    RULE(SZFriendsFieldDigest, 32, 32, REQ),
    RULE(SZFriendsFieldViaAssistant, 1, 1, SZFriendsFieldRuleBoolean),
    RULE(SZFriendsFieldTreeRoot, 32, 32, 0),
    RULE(SZFriendsFieldBlockShift, 1, 1, 0),
};
static const SZFriendsFieldRule kOfferReply[] = {
    ID_RULE,
    RULE(SZFriendsFieldAccept, 1, 1, REQ | SZFriendsFieldRuleBoolean),
    RULE(SZFriendsFieldOffset, 8, 8, 0),
    RULE(SZFriendsFieldBlocks, 1, 1, SZFriendsFieldRuleBoolean),
};
// Minor 4 (ADR 0018 § 3). Whole leaves and whole ranges; how many and which is the transfer area's check.
static const SZFriendsFieldRule kHashes[] = {
    ID_RULE,
    RULE(SZFriendsFieldIndex, 4, 4, REQ),
    RULE(SZFriendsFieldHashes, 32, 64000, REQ | SZFriendsFieldRuleMultipleOf32), // 2,000 leaves
};
static const SZFriendsFieldRule kWant[] = {ID_RULE, RULE(SZFriendsFieldRanges, 8, 64000, REQ | SZFriendsFieldRuleMultipleOf8)};
static const SZFriendsFieldRule kPart[] = {
    ID_RULE,
    RULE(SZFriendsFieldOffset, 8, 8, REQ),
    RULE(SZFriendsFieldData, 1, 61440, REQ),
    RULE(SZFriendsFieldCodec, 1, 1, 0),
    RULE(SZFriendsFieldLength, 4, 4, 0),
};
static const SZFriendsFieldRule kHave[] = {
    ID_RULE,
    RULE(SZFriendsFieldRanges, 8, 64000, SZFriendsFieldRuleMultipleOf8),
    RULE(SZFriendsFieldDurable, 8, 64000, SZFriendsFieldRuleMultipleOf8),
};
static const SZFriendsFieldRule kChunk[] = {
    ID_RULE,
    RULE(SZFriendsFieldOffset, 8, 8, REQ),
    RULE(SZFriendsFieldData, 1, 61440, REQ), // SZFriendsChunkBytesWiFi, the largest chunk any route uses
};
static const SZFriendsFieldRule kProgress[] = {ID_RULE, RULE(SZFriendsFieldOffset, 8, 8, REQ)};
static const SZFriendsFieldRule kDone[] = {ID_RULE, RULE(SZFriendsFieldDigest, 32, 32, REQ)};
static const SZFriendsFieldRule kClose[] = {RULE(SZFriendsFieldReason, 1, 1, 0)};
// The sides are format bounds (any u16 but zero); the thumbnail area holds them to 192 px before decoding anything.
static const SZFriendsFieldRule kThumbnail[] = {
    ID_RULE,
    RULE(SZFriendsFieldWidth, 2, 2, REQ),
    RULE(SZFriendsFieldHeight, 2, 2, REQ),
    RULE(SZFriendsFieldData, 23, 64000, REQ), // a QOI stream holding one pixel, up to SZFriendsFrameThumbnailMax
};

// The chain's own decoder checks its structure and signatures; the codec bounds only its size.
static const SZFriendsFieldRule kChain[] = {RULE(SZFriendsFieldChain, 3, 64000, REQ)}; // SZFriendsFrameChainMax
// Likewise the join message's own decoder (service/identity/SZFriendsJoinWire.m).
static const SZFriendsFieldRule kJoin[] = {RULE(SZFriendsFieldJoin, 1, 1000, REQ)}; // SZFriendsFrameJoinMax
// And the sync exchange's (service/sync/SZFriendsSyncExchange.m).
static const SZFriendsFieldRule kSync[] = {RULE(SZFriendsFieldSync, 1, 64000, REQ)}; // SZFriendsFrameSyncMax
// And getting a file again (ADR 0016; service/sync/SZFriendsAgain.m).
static const SZFriendsFieldRule kAgain[] = {RULE(SZFriendsFieldAgain, 1, 64000, REQ)}; // SZFriendsFrameAgainMax

static const SZFriendsFieldRule kHandshakePayload[] = {
    RULE(SZFriendsFieldName, 0, kNameMax, 0),
    RULE(SZFriendsFieldPictureSet, 2, 2, 0),
    RULE(SZFriendsFieldPictureIndex, 2, 2, 0),
    RULE(SZFriendsFieldData, 1, 49152, 0),
    RULE(SZFriendsFieldFriendsID, 0, kFriendsIDMax, 0),
    RULE(SZFriendsFieldToken, 16, 16, 0),
    RULE(SZFriendsFieldCertificate, 96, 96, 0),
    RULE(SZFriendsFieldMinorMin, 2, 2, 0),
    RULE(SZFriendsFieldMinorMax, 2, 2, 0),
    RULE(SZFriendsFieldCapabilities, 4, 4, 0),
    RULE(SZFriendsFieldRouteClass, 1, 1, 0),
    RULE(SZFriendsFieldAttestation, 1, kAttestationMax, 0),
    RULE(SZFriendsFieldLane, 16, 16, 0),
};

#define RULES(array) ((SZFriendsFieldRules){(array), sizeof(array) / sizeof((array)[0])})

BOOL SZFriendsFrameRulesForType(uint8_t type, SZFriendsFieldRules *rules) {
    static const SZFriendsFieldRules kNone = {NULL, 0};
    switch ((SZFriendsFrameType)type) {
    case SZFriendsFrameTypeHello:
    case SZFriendsFrameTypeReceived: // fixed size on purpose: every device's reply is byte-identical (ADR 0004)
    case SZFriendsFrameTypeRekey:
    case SZFriendsFrameTypePing:
        *rules = kNone;
        return YES;
    case SZFriendsFrameTypeProfile: *rules = RULES(kProfile); return YES;
    case SZFriendsFrameTypePresenceSecret: *rules = RULES(kPresenceSecret); return YES;
    case SZFriendsFrameTypeRequest: *rules = RULES(kRequest); return YES;
    case SZFriendsFrameTypeAccept: *rules = RULES(kIDOnly); return YES;
    case SZFriendsFrameTypeDecline: *rules = RULES(kIDAndReason); return YES;
    case SZFriendsFrameTypeRequestByID: *rules = RULES(kRequestByID); return YES;
    case SZFriendsFrameTypeCodeCommit: *rules = RULES(kCodeCommit); return YES;
    case SZFriendsFrameTypeCodeNonce:
    case SZFriendsFrameTypeCodeReveal: *rules = RULES(kCodeNonce); return YES;
    case SZFriendsFrameTypeMessage: *rules = RULES(kMessage); return YES;
    case SZFriendsFrameTypeAck: *rules = RULES(kIDOnly); return YES;
    case SZFriendsFrameTypeOffer: *rules = RULES(kOffer); return YES;
    case SZFriendsFrameTypeOfferReply: *rules = RULES(kOfferReply); return YES;
    case SZFriendsFrameTypeCancel: *rules = RULES(kIDAndReason); return YES;
    case SZFriendsFrameTypeChunk: *rules = RULES(kChunk); return YES;
    case SZFriendsFrameTypeProgress: *rules = RULES(kProgress); return YES;
    case SZFriendsFrameTypeDone: *rules = RULES(kDone); return YES;
    case SZFriendsFrameTypeClose: *rules = RULES(kClose); return YES;
    case SZFriendsFrameTypeThumbnail: *rules = RULES(kThumbnail); return YES;
    case SZFriendsFrameTypeChain: *rules = RULES(kChain); return YES;
    case SZFriendsFrameTypeJoin: *rules = RULES(kJoin); return YES;
    case SZFriendsFrameTypeSync: *rules = RULES(kSync); return YES;
    case SZFriendsFrameTypeAgain: *rules = RULES(kAgain); return YES;
    case SZFriendsFrameTypeHashes: *rules = RULES(kHashes); return YES;
    case SZFriendsFrameTypeWant: *rules = RULES(kWant); return YES;
    case SZFriendsFrameTypePart: *rules = RULES(kPart); return YES;
    case SZFriendsFrameTypeHave: *rules = RULES(kHave); return YES;
    }
    return NO;
}

SZFriendsFieldRules SZFriendsHandshakePayloadRules(void) {
    return RULES(kHandshakePayload);
}

const SZFriendsFieldRule *SZFriendsFindFieldRule(SZFriendsFieldRules rules, uint8_t tag) {
    for (size_t i = 0; i < rules.count; i++) {
        if (rules.rules[i].tag == tag) {
            return &rules.rules[i];
        }
    }
    return NULL;
}

static BOOL SZFriendsFieldBytesAllowed(const SZFriendsFieldRule *rule, const uint8_t *bytes, NSUInteger length) {
    if (length < rule->minLength || length > rule->maxLength) {
        return NO;
    }
    if ((rule->flags & SZFriendsFieldRuleBoolean) && bytes[0] > 1) {
        return NO;
    }
    if ((rule->flags & SZFriendsFieldRuleMultipleOf16) && length % 16 != 0) {
        return NO;
    }
    if ((rule->flags & SZFriendsFieldRuleMultipleOf32) && length % 32 != 0) {
        return NO;
    }
    if ((rule->flags & SZFriendsFieldRuleMultipleOf8) && length % 8 != 0) {
        return NO;
    }
    return YES;
}

BOOL SZFriendsFieldValueAllowed(const SZFriendsFieldRule *rule, NSData *value) {
    return SZFriendsFieldBytesAllowed(rule, value.bytes, value.length);
}

NSUInteger SZFriendsIntegerFieldWidth(uint8_t tag) {
    switch ((SZFriendsFieldTag)tag) {
    case SZFriendsFieldSentAt:
    case SZFriendsFieldSize:
    case SZFriendsFieldOffset:
        return 8;
    case SZFriendsFieldCapabilities:
    case SZFriendsFieldIndex:
    case SZFriendsFieldLength:
        return 4;
    case SZFriendsFieldPictureSet:
    case SZFriendsFieldPictureIndex:
    case SZFriendsFieldMinorMin:
    case SZFriendsFieldMinorMax:
    case SZFriendsFieldWidth:
    case SZFriendsFieldHeight:
        return 2;
    case SZFriendsFieldAccept:
    case SZFriendsFieldReason:
    case SZFriendsFieldRouteClass:
    case SZFriendsFieldViaAssistant:
    case SZFriendsFieldBlockShift:
    case SZFriendsFieldBlocks:
    case SZFriendsFieldCodec:
        return 1;
    default:
        return 0;
    }
}

NSError *SZFriendsSessionMakeError(SZFriendsSessionError code, NSString *logDescription) {
    return [NSError errorWithDomain:SZFriendsSessionErrorDomain
                               code:code
                           userInfo:@{NSDebugDescriptionErrorKey : logDescription}];
}

static NSDictionary *SZFriendsFail(NSError **error, NSString *description) {
    if (error) {
        *error = SZFriendsSessionMakeError(SZFriendsSessionErrorFrameInvalid, description);
    }
    return nil;
}

static BOOL SZFriendsRefuse(NSError **error, NSString *description) {
    SZFriendsFail(error, description);
    return NO;
}

NSDictionary<NSNumber *, NSData *> *SZFriendsDecodeFields(NSData *data, NSUInteger offset, SZFriendsFieldRules rules,
                                                         NSError **error) {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    uint8_t seen[32] = {0};

    // Pass 1 reads only: every length, duplicate and limit is checked before anything sized by the peer exists.
    for (NSUInteger position = offset; position < length;) {
        if (length - position < 3) {
            return SZFriendsFail(error, @"truncated field header");
        }
        uint8_t tag = bytes[position];
        NSUInteger fieldLength = ((NSUInteger)bytes[position + 1] << 8) | bytes[position + 2];
        position += 3;
        if (fieldLength > length - position) {
            return SZFriendsFail(error, [NSString stringWithFormat:@"field %u overruns the frame", tag]);
        }
        if (seen[tag >> 3] & (1u << (tag & 7))) {
            return SZFriendsFail(error, [NSString stringWithFormat:@"duplicate field %u", tag]);
        }
        seen[tag >> 3] |= (uint8_t)(1u << (tag & 7));
        const SZFriendsFieldRule *rule = SZFriendsFindFieldRule(rules, tag);
        if (rule != NULL && !SZFriendsFieldBytesAllowed(rule, bytes + position, fieldLength)) {
            return SZFriendsFail(error, [NSString stringWithFormat:@"field %u outside its limits (%lu bytes)", tag,
                                                                   (unsigned long)fieldLength]);
        }
        position += fieldLength;
    }
    for (size_t i = 0; i < rules.count; i++) {
        uint8_t tag = rules.rules[i].tag;
        if ((rules.rules[i].flags & SZFriendsFieldRuleRequired) && !(seen[tag >> 3] & (1u << (tag & 7)))) {
            return SZFriendsFail(error, [NSString stringWithFormat:@"missing field %u", tag]);
        }
    }

    NSMutableDictionary<NSNumber *, NSData *> *fields = [NSMutableDictionary dictionary];
    for (NSUInteger position = offset; position < length;) {
        uint8_t tag = bytes[position];
        NSUInteger fieldLength = ((NSUInteger)bytes[position + 1] << 8) | bytes[position + 2];
        position += 3;
        if (SZFriendsFindFieldRule(rules, tag) != NULL) {
            fields[@(tag)] = [data subdataWithRange:NSMakeRange(position, fieldLength)];
        }
        position += fieldLength;
    }
    return fields;
}

BOOL SZFriendsAppendFields(NSMutableData *output, NSDictionary<NSNumber *, NSData *> *fields,
                           SZFriendsFieldRules rules, NSError **error) {
    for (NSNumber *key in fields) {
        NSInteger tag = key.integerValue;
        const SZFriendsFieldRule *rule = (tag >= 0 && tag <= 255) ? SZFriendsFindFieldRule(rules, (uint8_t)tag) : NULL;
        if (rule == NULL) {
            return SZFriendsRefuse(error, [NSString stringWithFormat:@"field %ld is not defined here", (long)tag]);
        }
        NSData *value = fields[key];
        if (![value isKindOfClass:[NSData class]] || !SZFriendsFieldValueAllowed(rule, value)) {
            return SZFriendsRefuse(error, [NSString stringWithFormat:@"field %ld outside its limits", (long)tag]);
        }
    }
    for (size_t i = 0; i < rules.count; i++) {
        if ((rules.rules[i].flags & SZFriendsFieldRuleRequired) && fields[@(rules.rules[i].tag)] == nil) {
            return SZFriendsRefuse(error, [NSString stringWithFormat:@"missing field %u", rules.rules[i].tag]);
        }
    }
    NSArray<NSNumber *> *tags = [fields.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *key in tags) {
        NSData *value = fields[key];
        uint8_t header[3] = {(uint8_t)key.unsignedIntValue, (uint8_t)(value.length >> 8), (uint8_t)value.length};
        [output appendBytes:header length:sizeof header];
        [output appendData:value];
    }
    return YES;
}
