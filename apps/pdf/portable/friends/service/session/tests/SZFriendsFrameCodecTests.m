// The transport frame codec (SZFriendsEncodeFrame / SZFriendsDecodeFrame): round trips for every type, unknown
// types, unknown and duplicate tags, per-type limits, required fields, truncation, the plaintext limit and the
// typed accessors.

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

#import "service/session/SZFriendsFrameSchema.h"
#import "service/session/SZFriendsHandshakePayload.h"

static NSData *SZFU64(uint64_t value, SZFriendsFieldTag tag) {
    return [SZFriendsFrame fieldWithUInt64:value tag:tag];
}

// Raw plaintext: a type byte, then (tag, value) pairs exactly as given, so tests can build what the encoder refuses.
static NSData *SZFRawFrame(uint8_t type, NSArray *tagValuePairs) {
    NSMutableData *data = [NSMutableData dataWithBytes:&type length:1];
    for (NSUInteger i = 0; i + 1 < tagValuePairs.count; i += 2) {
        uint8_t tag = (uint8_t)[tagValuePairs[i] unsignedIntValue];
        NSData *value = tagValuePairs[i + 1];
        uint8_t header[3] = {tag, (uint8_t)(value.length >> 8), (uint8_t)value.length};
        [data appendBytes:header length:3];
        [data appendData:value];
    }
    return data;
}

static NSDictionary<NSNumber *, NSDictionary *> *SZFSampleFields(void) {
    NSData *ident = SZFBytes(0x11, 16);
    NSData *sentAt = SZFU64(1760251668000, SZFriendsFieldSentAt);
    return @{
        @(SZFriendsFrameTypeHello) : @{},
        @(SZFriendsFrameTypeProfile) : @{@(SZFriendsFieldName) : [@"Mei" dataUsingEncoding:NSUTF8StringEncoding],
                                         @(SZFriendsFieldPictureSet) : SZFU64(1, SZFriendsFieldPictureSet),
                                         @(SZFriendsFieldPictureIndex) : SZFU64(4, SZFriendsFieldPictureIndex)},
        @(SZFriendsFrameTypePresenceSecret) : @{@(SZFriendsFieldID) : ident,
                                                @(SZFriendsFieldSecret) : SZFBytes(2, 32)},
        @(SZFriendsFrameTypeRequest) : @{@(SZFriendsFieldID) : ident, @(SZFriendsFieldSentAt) : sentAt},
        @(SZFriendsFrameTypeAccept) : @{@(SZFriendsFieldID) : ident},
        @(SZFriendsFrameTypeDecline) : @{@(SZFriendsFieldID) : ident, @(SZFriendsFieldReason) : SZFBytes(0, 1)},
        @(SZFriendsFrameTypeRequestByID) : @{
            @(SZFriendsFieldFriendsID) : [@"maple-river" dataUsingEncoding:NSUTF8StringEncoding],
            @(SZFriendsFieldToken) : SZFBytes(3, 16),
            @(SZFriendsFieldCallbackSecret) : SZFBytes(4, 32),
            @(SZFriendsFieldCertificate) : SZFBytes(5, 96),
            @(SZFriendsFieldStaticKey) : SZFBytes(6, 32),
            @(SZFriendsFieldSignature) : SZFBytes(7, 64),
        },
        @(SZFriendsFrameTypeReceived) : @{},
        @(SZFriendsFrameTypeCodeCommit) : @{@(SZFriendsFieldCommitment) : SZFBytes(8, 32)},
        @(SZFriendsFrameTypeCodeNonce) : @{@(SZFriendsFieldNonce) : SZFBytes(9, 32)},
        @(SZFriendsFrameTypeCodeReveal) : @{@(SZFriendsFieldNonce) : SZFBytes(10, 32)},
        @(SZFriendsFrameTypeMessage) : @{@(SZFriendsFieldID) : ident, @(SZFriendsFieldSentAt) : sentAt,
                                         @(SZFriendsFieldText) : [@"合同 ok" dataUsingEncoding:NSUTF8StringEncoding],
                                         @(SZFriendsFieldOfferIDs) : SZFBytes(12, 32),
                                         @(SZFriendsFieldViaAssistant) : SZFBytes(1, 1)},
        @(SZFriendsFrameTypeAck) : @{@(SZFriendsFieldID) : ident},
        @(SZFriendsFrameTypeOffer) : @{@(SZFriendsFieldID) : ident,
                                       @(SZFriendsFieldName) : [@"Site.pdf" dataUsingEncoding:NSUTF8StringEncoding],
                                       @(SZFriendsFieldFileType) : [@"com.adobe.pdf"
                                                                        dataUsingEncoding:NSUTF8StringEncoding],
                                       @(SZFriendsFieldSize) : SZFU64(123456, SZFriendsFieldSize),
                                       @(SZFriendsFieldDigest) : SZFBytes(13, 32),
                                       @(SZFriendsFieldViaAssistant) : SZFBytes(1, 1)},
        @(SZFriendsFrameTypeOfferReply) : @{@(SZFriendsFieldID) : ident, @(SZFriendsFieldAccept) : SZFBytes(1, 1),
                                            @(SZFriendsFieldOffset) : SZFU64(4096, SZFriendsFieldOffset)},
        @(SZFriendsFrameTypeCancel) : @{@(SZFriendsFieldID) : ident},
        @(SZFriendsFrameTypeChunk) : @{@(SZFriendsFieldID) : ident,
                                       @(SZFriendsFieldOffset) : SZFU64(0, SZFriendsFieldOffset),
                                       @(SZFriendsFieldData) : SZFBytes(14, 61440)},
        @(SZFriendsFrameTypeProgress) : @{@(SZFriendsFieldID) : ident,
                                          @(SZFriendsFieldOffset) : SZFU64(61440, SZFriendsFieldOffset)},
        @(SZFriendsFrameTypeDone) : @{@(SZFriendsFieldID) : ident, @(SZFriendsFieldDigest) : SZFBytes(15, 32)},
        @(SZFriendsFrameTypeRekey) : @{},
        @(SZFriendsFrameTypePing) : @{},
        @(SZFriendsFrameTypeClose) : @{@(SZFriendsFieldReason) : SZFBytes(1, 1)},
        @(SZFriendsFrameTypeThumbnail) : @{@(SZFriendsFieldID) : ident,
                                           @(SZFriendsFieldWidth) : SZFU64(136, SZFriendsFieldWidth),
                                           @(SZFriendsFieldHeight) : SZFU64(192, SZFriendsFieldHeight),
                                           @(SZFriendsFieldData) : SZFBytes(16, 64000)},
    };
}

static void SZFTestRoundTrips(void) {
    NSDictionary<NSNumber *, NSDictionary *> *samples = SZFSampleFields();
    SZF_CHECK(samples.count == 23, @"a sample for every frame type");
    for (NSNumber *type in samples) {
        SZFriendsFrame *frame = [SZFriendsFrame frameWithType:(SZFriendsFrameType)type.intValue fields:samples[type]];
        NSError *error = nil;
        NSData *plaintext = SZFriendsEncodeFrame(frame, &error);
        SZF_CHECK(plaintext != nil, @"type %@ encodes: %@", type, error);
        SZFriendsFrame *decoded = SZFriendsDecodeFrame(plaintext, &error);
        SZF_CHECK(decoded.type == frame.type && [decoded.fields isEqualToDictionary:frame.fields],
                  @"type %@ round trip: %@", type, error);
        SZF_CHECK([SZFriendsEncodeFrame(decoded, NULL) isEqualToData:plaintext], @"type %@ re-encodes the same", type);
    }
    // Fields go out in ascending tag order, so encoding is deterministic.
    NSData *ack = SZFriendsEncodeFrame([SZFriendsFrame frameWithType:SZFriendsFrameTypeAck
                                                              fields:@{@(SZFriendsFieldID) : SZFBytes(0xAB, 16)}],
                                       NULL);
    SZF_CHECK([SZFHexString(ack) isEqualToString:@"0d010010abababababababababababababababab"], @"ACK bytes %@",
              SZFHexString(ack));
}

static void SZFExpectDecodeFailure(NSData *plaintext, NSString *label) {
    NSError *error = nil;
    SZF_CHECK(SZFriendsDecodeFrame(plaintext, &error) == nil && error.code == SZFriendsSessionErrorFrameInvalid,
              @"%@ must not decode", label);
}

static void SZFTestRejections(void) {
    NSData *ident = SZFBytes(1, 16);
    SZFExpectDecodeFailure([NSData data], @"empty plaintext");
    SZFExpectDecodeFailure(SZFRawFrame(0, @[]), @"type 0");
    SZFExpectDecodeFailure(SZFRawFrame(24, @[]), @"type 24");
    SZFExpectDecodeFailure(SZFRawFrame(255, @[]), @"type 255");
    SZFExpectDecodeFailure(SZFRawFrame(SZFriendsFrameTypeAck, @[ @1, ident, @1, ident ]), @"duplicate known tag");
    SZFExpectDecodeFailure(
        SZFRawFrame(SZFriendsFrameTypeAck, @[ @1, ident, @200, SZFBytes(0, 1), @200, SZFBytes(0, 1) ]),
        @"duplicate unknown tag");
    SZFExpectDecodeFailure(SZFRawFrame(SZFriendsFrameTypeAck, @[ @1, SZFBytes(1, 15) ]), @"short ID");
    SZFExpectDecodeFailure(SZFRawFrame(SZFriendsFrameTypeAck, @[]), @"missing required ID");
    SZFExpectDecodeFailure(SZFRawFrame(SZFriendsFrameTypeMessage,
                                       @[ @1, ident, @2, SZFBytes(0, 8), @3, SZFBytes('a', 32769) ]),
                           @"text over 32 KiB");
    SZFExpectDecodeFailure(SZFRawFrame(SZFriendsFrameTypeProfile, @[ @9, SZFBytes(0, 49153) ]),
                           @"picture over 48 KiB");
    SZFExpectDecodeFailure(
        SZFRawFrame(SZFriendsFrameTypeChunk, @[ @1, ident, @8, SZFBytes(0, 8), @9, SZFBytes(0, 61441) ]),
        @"chunk over 60 KiB");
    SZFExpectDecodeFailure(SZFRawFrame(SZFriendsFrameTypeChunk, @[ @1, ident, @8, SZFBytes(0, 8), @9, [NSData data] ]),
                           @"empty chunk");
    SZFExpectDecodeFailure(SZFRawFrame(SZFriendsFrameTypeOfferReply, @[ @1, ident, @12, SZFBytes(2, 1) ]),
                           @"Accept other than 0 or 1");
    SZFExpectDecodeFailure(
        SZFRawFrame(SZFriendsFrameTypeMessage, @[ @1, ident, @2, SZFBytes(0, 8), @29, SZFBytes(2, 1) ]),
        @"ViaAssistant other than 0 or 1");
    SZFExpectDecodeFailure(SZFRawFrame(SZFriendsFrameTypeMessage,
                                       @[ @1, ident, @2, SZFBytes(0, 8), @16, SZFBytes(0, 17) ]),
                           @"OfferIDs not a multiple of 16");
    SZFExpectDecodeFailure(SZFRawFrame(SZFriendsFrameTypeMessage,
                                       @[ @1, ident, @2, SZFBytes(0, 8), @16, SZFBytes(0, 21 * 16) ]),
                           @"more than 20 attached offers");

    // Truncation inside the field structure: a header cut short, and a length running past the end.
    NSMutableData *truncatedHeader = [SZFRawFrame(SZFriendsFrameTypeAck, @[ @1, ident ]) mutableCopy];
    [truncatedHeader appendBytes:"\x05\x00" length:2];
    SZFExpectDecodeFailure(truncatedHeader, @"truncated field header");
    NSMutableData *overrun = [SZFRawFrame(SZFriendsFrameTypeAck, @[ @1, ident ]) mutableCopy];
    ((uint8_t *)overrun.mutableBytes)[3] = 17;
    SZFExpectDecodeFailure(overrun, @"field length past the end");

    // The plaintext limit: one byte over 65,519 never decodes, whatever it holds.
    NSMutableData *oversized = [SZFRawFrame(SZFriendsFrameTypeChunk, @[ @1, ident, @8, SZFBytes(0, 8),
                                                                       @9, SZFBytes(0, 61440) ]) mutableCopy];
    NSUInteger padding = 65520 - oversized.length - 3; // an unknown field fills the rest
    uint8_t paddingHeader[3] = {201, (uint8_t)(padding >> 8), (uint8_t)padding};
    [oversized appendBytes:paddingHeader length:3];
    [oversized appendData:SZFBytes(0, padding)];
    SZF_CHECK(oversized.length == 65520, @"oversized fixture is %lu bytes", (unsigned long)oversized.length);
    [oversized setLength:65519];
    ((uint8_t *)oversized.mutableBytes)[61474 + 1] = (uint8_t)((padding - 1) >> 8);
    ((uint8_t *)oversized.mutableBytes)[61474 + 2] = (uint8_t)(padding - 1);
    SZF_CHECK(SZFriendsDecodeFrame(oversized, NULL) != nil, @"exactly 65,519 bytes decodes");
    [oversized appendBytes:"\0" length:1];
    ((uint8_t *)oversized.mutableBytes)[61474 + 1] = (uint8_t)(padding >> 8);
    ((uint8_t *)oversized.mutableBytes)[61474 + 2] = (uint8_t)padding;
    SZFExpectDecodeFailure(oversized, @"plaintext over 65,519 bytes");

    // The encoder is strict: fields outside the type, values out of limits, missing required fields.
    NSError *error = nil;
    SZF_CHECK(SZFriendsEncodeFrame([SZFriendsFrame frameWithType:SZFriendsFrameTypeAck
                                                          fields:@{@(SZFriendsFieldID) : ident,
                                                                   @(SZFriendsFieldText) : SZFBytes('a', 1)}],
                                   &error) == nil,
              @"encoder refuses a field the type does not define");
    SZF_CHECK(SZFriendsEncodeFrame([SZFriendsFrame frameWithType:SZFriendsFrameTypeMessage
                                                          fields:@{@(SZFriendsFieldID) : ident,
                                                                   @(SZFriendsFieldSentAt) : SZFBytes(0, 8),
                                                                   @(SZFriendsFieldText) : SZFBytes('a', 32769)}],
                                   &error) == nil,
              @"encoder refuses text over 32 KiB");
    SZF_CHECK(SZFriendsEncodeFrame([SZFriendsFrame frameWithType:(SZFriendsFrameType)99 fields:@{}], &error) == nil,
              @"encoder refuses an unknown type");
    SZF_CHECK(SZFriendsEncodeFrame([SZFriendsFrame frameWithType:SZFriendsFrameTypeChunk fields:@{}], &error) == nil,
              @"encoder refuses missing required fields");
}

static void SZFTestUnknownTagsAndAccessors(void) {
    NSData *ident = SZFBytes(1, 16);
    // A tag this type does not define is ignored, known elsewhere (Text) or unknown everywhere (200).
    NSData *plaintext = SZFRawFrame(SZFriendsFrameTypeAck,
                                    @[ @200, SZFBytes(9, 5), @1, ident, @3, SZFBytes('x', 3) ]);
    SZFriendsFrame *frame = SZFriendsDecodeFrame(plaintext, NULL);
    SZF_CHECK(frame && frame.fields.count == 1 && [[frame dataForTag:SZFriendsFieldID] isEqualToData:ident],
              @"unknown and foreign tags are dropped");

    SZFriendsFrame *offer = SZFriendsDecodeFrame(
        SZFRawFrame(SZFriendsFrameTypeOffer, @[ @1, ident, @4, [@"a.pdf" dataUsingEncoding:NSUTF8StringEncoding],
                                                @6, SZFU64(0x0102030405060708, SZFriendsFieldSize), @7,
                                                SZFBytes(0, 32) ]),
        NULL);
    uint64_t size = 0;
    SZF_CHECK([offer getUInt64:&size forTag:SZFriendsFieldSize] && size == 0x0102030405060708, @"u64 big-endian");
    SZF_CHECK(![offer getUInt64:&size forTag:SZFriendsFieldName], @"a string is not an integer");
    SZF_CHECK([[offer stringForTag:SZFriendsFieldName] isEqualToString:@"a.pdf"], @"string accessor");
    SZF_CHECK([offer dataForTag:SZFriendsFieldText] == nil, @"absent field");

    SZFriendsFrame *badText = [SZFriendsFrame frameWithType:SZFriendsFrameTypeMessage
                                                     fields:@{@(SZFriendsFieldText) : SZFHex(@"c328")}];
    SZF_CHECK([badText stringForTag:SZFriendsFieldText] == nil, @"invalid UTF-8 gives nil");
    SZFriendsFrame *wrongLength = [SZFriendsFrame frameWithType:SZFriendsFrameTypeAck
                                                         fields:@{@(SZFriendsFieldID) : SZFBytes(1, 15)}];
    SZF_CHECK([wrongLength dataForTag:SZFriendsFieldID] == nil, @"wrong-length field reads as absent");

    SZF_CHECK([[SZFriendsFrame fieldWithUInt64:0x0102 tag:SZFriendsFieldPictureSet] isEqualToData:SZFHex(@"0102")],
              @"u16 field");
    SZF_CHECK([SZFriendsFrame fieldWithUInt64:0x10000 tag:SZFriendsFieldPictureSet] == nil, @"u16 overflow refused");
    SZF_CHECK([SZFriendsFrame fieldWithUInt64:1 tag:SZFriendsFieldText] == nil, @"not an integer tag");
    SZFriendsFrame *picture = [SZFriendsFrame frameWithType:SZFriendsFrameTypeProfile
                                                     fields:@{@(SZFriendsFieldPictureIndex) : SZFHex(@"0007")}];
    uint64_t index = 0;
    SZF_CHECK([picture getUInt64:&index forTag:SZFriendsFieldPictureIndex] && index == 7, @"u16 accessor");
    SZF_CHECK([[SZFMessageFrame(@"secret words") description] rangeOfString:@"secret"].location == NSNotFound,
              @"descriptions never include values");
}

// Handshake payloads use the same fields; this pins their bytes so a change to the wire format cannot slip in.
static void SZFTestPayloadBytes(void) {
    SZFriendsHandshakePayload *payload = [SZFriendsHandshakePayload localPayload];
    payload.certificate = SZFBytes(0xCC, 96);
    payload.requestToken = SZFBytes(0x11, 16);
    payload.hasRouteClass = YES;
    payload.routeClass = SZFriendsRouteMethodLAN;
    NSMutableString *expected = [NSMutableString stringWithString:@"120010"];
    [expected appendString:SZFHexString(SZFBytes(0x11, 16))];
    [expected appendString:@"140060"];
    [expected appendString:SZFHexString(SZFBytes(0xCC, 96))];
    [expected appendString:@"180002000019000200041a0004000000001b000101"]; // minor range 0...4
    SZF_CHECK([SZFHexString([payload encodedDataWithError:NULL]) isEqualToString:expected], @"payload bytes");
    SZFriendsHandshakePayload *decoded = [SZFriendsHandshakePayload payloadWithData:SZFHex(expected) error:NULL];
    SZF_CHECK(decoded.hasMinorRange && decoded.minorMax == 4 && decoded.hasRouteClass && decoded.routeClass == 1 &&
                  [decoded.requestToken isEqualToData:SZFBytes(0x11, 16)] && decoded.profile == nil,
              @"payload decodes");
    payload.profile = @{@(SZFriendsFieldText) : SZFBytes('a', 1)};
    SZF_CHECK([payload encodedDataWithError:NULL] == nil, @"only profile fields may ride in a profile");
}

void SZFRunFrameCodecTests(void) {
    SZFTestPayloadBytes();
    SZFTestRoundTrips();
    SZFTestRejections();
    SZFTestUnknownTagsAndAccessors();
}
