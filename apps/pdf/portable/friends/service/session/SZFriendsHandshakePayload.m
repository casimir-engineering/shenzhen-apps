// Handshake payload encoding and SZFriendsHandshakeOptions (SZFriendsHandshakePayload.h, SZFriendsSession.h).

#import "service/session/SZFriendsHandshakePayload.h"

#import "service/session/SZFriendsFrameSchema.h"

BOOL SZFriendsIsProfileTag(uint8_t tag) {
    switch ((SZFriendsFieldTag)tag) {
    case SZFriendsFieldName:
    case SZFriendsFieldFriendsID:
    case SZFriendsFieldPictureSet:
    case SZFriendsFieldPictureIndex:
    case SZFriendsFieldData:
        return YES;
    default:
        return NO;
    }
}

BOOL SZFriendsNegotiateMinor(uint16_t localMin, uint16_t localMax, uint16_t remoteMin, uint16_t remoteMax,
                             uint16_t *negotiated) {
    if (localMin > localMax || remoteMin > remoteMax) {
        return NO;
    }
    uint16_t low = localMin > remoteMin ? localMin : remoteMin;
    uint16_t high = localMax < remoteMax ? localMax : remoteMax;
    if (low > high) {
        return NO;
    }
    *negotiated = high;
    return YES;
}

@implementation SZFriendsHandshakePayload

+ (instancetype)localPayload {
    SZFriendsHandshakePayload *payload = [[self alloc] init];
    payload.hasMinorRange = YES;
    payload.minorMin = 0;
    payload.minorMax = SZFriendsSessionMinor;
    payload.capabilities = 0;
    return payload;
}

- (NSData *)encodedDataWithError:(NSError **)error {
    NSMutableDictionary<NSNumber *, NSData *> *fields = [NSMutableDictionary dictionary];
    for (NSNumber *tag in _profile) {
        if (!SZFriendsIsProfileTag(tag.unsignedCharValue) || tag.unsignedIntegerValue > 255) {
            if (error) {
                *error = SZFriendsSessionMakeError(SZFriendsSessionErrorFrameInvalid,
                                                   [NSString stringWithFormat:@"tag %@ is not a profile field", tag]);
            }
            return nil;
        }
        fields[tag] = _profile[tag];
    }
    if (_certificate) {
        fields[@(SZFriendsFieldCertificate)] = _certificate;
    }
    if (_requestToken) {
        fields[@(SZFriendsFieldToken)] = _requestToken;
    }
    if (_attestation) {
        fields[@(SZFriendsFieldAttestation)] = _attestation;
    }
    if (_hasMinorRange) {
        fields[@(SZFriendsFieldMinorMin)] = [SZFriendsFrame fieldWithUInt64:_minorMin tag:SZFriendsFieldMinorMin];
        fields[@(SZFriendsFieldMinorMax)] = [SZFriendsFrame fieldWithUInt64:_minorMax tag:SZFriendsFieldMinorMax];
        fields[@(SZFriendsFieldCapabilities)] = [SZFriendsFrame fieldWithUInt64:_capabilities
                                                                            tag:SZFriendsFieldCapabilities];
    }
    if (_hasRouteClass) {
        fields[@(SZFriendsFieldRouteClass)] = [SZFriendsFrame fieldWithUInt64:_routeClass
                                                                          tag:SZFriendsFieldRouteClass];
    }
    if (_lane) {
        fields[@(SZFriendsFieldLane)] = _lane;
    }
    NSMutableData *output = [NSMutableData data];
    return SZFriendsAppendFields(output, fields, SZFriendsHandshakePayloadRules(), error) ? output : nil;
}

static uint64_t SZFriendsBigEndian(NSData *data) {
    const uint8_t *bytes = data.bytes;
    uint64_t value = 0;
    for (NSUInteger i = 0; i < data.length; i++) {
        value = (value << 8) | bytes[i];
    }
    return value;
}

+ (instancetype)payloadWithData:(NSData *)data error:(NSError **)error {
    NSDictionary<NSNumber *, NSData *> *fields = SZFriendsDecodeFields(data, 0, SZFriendsHandshakePayloadRules(),
                                                                       error);
    if (fields == nil) {
        return nil;
    }
    SZFriendsHandshakePayload *payload = [[self alloc] init];
    payload.certificate = fields[@(SZFriendsFieldCertificate)];
    payload.requestToken = fields[@(SZFriendsFieldToken)];
    payload.attestation = fields[@(SZFriendsFieldAttestation)];
    NSData *minorMin = fields[@(SZFriendsFieldMinorMin)];
    NSData *minorMax = fields[@(SZFriendsFieldMinorMax)];
    if (minorMin && minorMax) {
        payload.hasMinorRange = YES;
        payload.minorMin = (uint16_t)SZFriendsBigEndian(minorMin);
        payload.minorMax = (uint16_t)SZFriendsBigEndian(minorMax);
    }
    NSData *capabilities = fields[@(SZFriendsFieldCapabilities)];
    payload.capabilities = capabilities ? (uint32_t)SZFriendsBigEndian(capabilities) : 0;
    NSData *route = fields[@(SZFriendsFieldRouteClass)];
    if (route) {
        payload.hasRouteClass = YES;
        payload.routeClass = (uint8_t)SZFriendsBigEndian(route);
    }
    NSMutableDictionary<NSNumber *, NSData *> *profile = [NSMutableDictionary dictionary];
    for (NSNumber *tag in fields) {
        if (SZFriendsIsProfileTag(tag.unsignedCharValue)) {
            profile[tag] = fields[tag];
        }
    }
    payload.profile = profile.count ? profile : nil;
    payload.lane = fields[@(SZFriendsFieldLane)];
    return payload;
}

@end

@implementation SZFriendsHandshakeOptions

- (id)copyWithZone:(NSZone *)zone {
    SZFriendsHandshakeOptions *copy = [[[self class] allocWithZone:zone] init];
    copy.pattern = _pattern;
    copy.route = _route;
    copy.remoteStaticKey = _remoteStaticKey;
    copy.expectedIdentityKey = _expectedIdentityKey;
    copy.requestToken = _requestToken;
    copy.browseOnly = _browseOnly;
    copy.lane = _lane;
    return copy;
}

@end
