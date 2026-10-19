// Vector export: transport frames and handshake payloads (ADR 0001 § Wire format). Encodings of one frame of every
// type, and how the decoder treats malformed input: the Rust codec must accept and refuse exactly the same bytes.

#import "SZFVectorExport.h"

#import "service/session/SZFriendsHandshakePayload.h"
#import "service/session/SZFriendsSession.h"

static NSData *U(uint64_t value, SZFriendsFieldTag tag) { return [SZFriendsFrame fieldWithUInt64:value tag:tag]; }
static NSData *D(NSString *label, NSUInteger length) { return SZFDerive(label, length); }
static NSData *Repeat(uint8_t byte, NSUInteger length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    memset(data.mutableBytes, byte, length);
    return data;
}

static NSDictionary *Fields(NSDictionary<NSNumber *, NSData *> *fields) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSNumber *tag in fields) out[tag.stringValue] = SZFHexString(fields[tag]);
    return out;
}

// Large inputs as segments, to keep the file small: hex, or "bb*N" for a run of N bytes 0xbb (runs of 64 or more).
static NSArray<NSString *> *Compact(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    NSMutableData *pending = [NSMutableData data];
    for (NSUInteger i = 0; i < data.length;) {
        NSUInteger run = 1;
        while (i + run < data.length && bytes[i + run] == bytes[i]) run++;
        if (run >= 64) {
            if (pending.length) [segments addObject:SZFHexString(pending)];
            pending = [NSMutableData data];
            [segments addObject:[NSString stringWithFormat:@"%02x*%lu", bytes[i], (unsigned long)run]];
        } else {
            [pending appendBytes:bytes + i length:run];
        }
        i += run;
    }
    if (pending.length || segments.count == 0) [segments addObject:SZFHexString(pending)];
    return segments;
}

static NSDictionary *CompactFields(NSDictionary<NSNumber *, NSData *> *fields) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSNumber *tag in fields) out[tag.stringValue] = Compact(fields[tag]);
    return out;
}

static NSArray *SZFEncodeCases(void) {
    NSData *ida = D(@"frame id a", 16), *idb = D(@"frame id b", 16);
    NSMutableData *offerIDs = [ida mutableCopy];
    [offerIDs appendData:idb];
    NSArray *cases = @[
        @[ @"hello", @(SZFriendsFrameTypeHello), @{} ],
        @[ @"profile", @(SZFriendsFrameTypeProfile), @{
            @(SZFriendsFieldName) : SZFUTF8(@"Mei"), @(SZFriendsFieldFriendsID) : SZFUTF8(@"maple-otter"),
            @(SZFriendsFieldPictureSet) : U(1, SZFriendsFieldPictureSet),
            @(SZFriendsFieldPictureIndex) : U(7, SZFriendsFieldPictureIndex),
            @(SZFriendsFieldAttestation) : D(@"attestation", 48)} ],
        @[ @"presence_secret", @(SZFriendsFrameTypePresenceSecret),
           @{@(SZFriendsFieldID) : ida, @(SZFriendsFieldSecret) : D(@"secret", 32)} ],
        @[ @"request", @(SZFriendsFrameTypeRequest), @{
            @(SZFriendsFieldID) : ida, @(SZFriendsFieldSentAt) : U(1760600000123, SZFriendsFieldSentAt),
            @(SZFriendsFieldText) : SZFUTF8(@"Hi, it's Mei from the workshop")} ],
        @[ @"accept", @(SZFriendsFrameTypeAccept), @{@(SZFriendsFieldID) : ida} ],
        @[ @"decline", @(SZFriendsFrameTypeDecline),
           @{@(SZFriendsFieldID) : ida, @(SZFriendsFieldReason) : U(1, SZFriendsFieldReason)} ],
        @[ @"received", @(SZFriendsFrameTypeReceived), @{} ],
        @[ @"code_commit", @(SZFriendsFrameTypeCodeCommit), @{@(SZFriendsFieldCommitment) : D(@"commit", 32)} ],
        @[ @"code_nonce", @(SZFriendsFrameTypeCodeNonce), @{@(SZFriendsFieldNonce) : D(@"nonce a", 32)} ],
        @[ @"code_reveal", @(SZFriendsFrameTypeCodeReveal), @{@(SZFriendsFieldNonce) : D(@"nonce b", 32)} ],
        @[ @"message", @(SZFriendsFrameTypeMessage), @{
            @(SZFriendsFieldID) : ida, @(SZFriendsFieldSentAt) : U(1760600000456, SZFriendsFieldSentAt),
            @(SZFriendsFieldText) : SZFUTF8(@"Gearbox 齿轮 ✓\nsecond line"),
            @(SZFriendsFieldOfferIDs) : offerIDs, @(SZFriendsFieldViaAssistant) : U(1, SZFriendsFieldViaAssistant)} ],
        @[ @"message_empty_text", @(SZFriendsFrameTypeMessage), @{
            @(SZFriendsFieldID) : idb, @(SZFriendsFieldSentAt) : U(0, SZFriendsFieldSentAt),
            @(SZFriendsFieldText) : [NSData data]} ],
        @[ @"ack", @(SZFriendsFrameTypeAck), @{@(SZFriendsFieldID) : ida} ],
        @[ @"offer", @(SZFriendsFrameTypeOffer), @{
            @(SZFriendsFieldID) : idb, @(SZFriendsFieldName) : SZFUTF8(@"Gearbox.sz3d"),
            @(SZFriendsFieldFileType) : SZFUTF8(@"sz3d"), @(SZFriendsFieldSize) : U(123456789, SZFriendsFieldSize),
            @(SZFriendsFieldDigest) : D(@"digest", 32),
            @(SZFriendsFieldViaAssistant) : U(0, SZFriendsFieldViaAssistant)} ],
        @[ @"offer_reply", @(SZFriendsFrameTypeOfferReply), @{
            @(SZFriendsFieldID) : idb, @(SZFriendsFieldAccept) : U(1, SZFriendsFieldAccept),
            @(SZFriendsFieldOffset) : U(4096, SZFriendsFieldOffset)} ],
        @[ @"cancel", @(SZFriendsFrameTypeCancel), @{@(SZFriendsFieldID) : idb} ],
        @[ @"chunk", @(SZFriendsFrameTypeChunk), @{
            @(SZFriendsFieldID) : idb, @(SZFriendsFieldOffset) : U(61440, SZFriendsFieldOffset),
            @(SZFriendsFieldData) : D(@"chunk data", 64)} ],
        @[ @"progress", @(SZFriendsFrameTypeProgress),
           @{@(SZFriendsFieldID) : idb, @(SZFriendsFieldOffset) : U(8388608, SZFriendsFieldOffset)} ],
        @[ @"done", @(SZFriendsFrameTypeDone),
           @{@(SZFriendsFieldID) : idb, @(SZFriendsFieldDigest) : D(@"digest", 32)} ],
        @[ @"rekey", @(SZFriendsFrameTypeRekey), @{} ],
        @[ @"ping", @(SZFriendsFrameTypePing), @{} ],
        @[ @"close", @(SZFriendsFrameTypeClose), @{@(SZFriendsFieldReason) : U(4, SZFriendsFieldReason)} ],
        @[ @"thumbnail", @(SZFriendsFrameTypeThumbnail), @{
            @(SZFriendsFieldID) : idb, @(SZFriendsFieldWidth) : U(64, SZFriendsFieldWidth),
            @(SZFriendsFieldHeight) : U(48, SZFriendsFieldHeight), @(SZFriendsFieldData) : D(@"qoi bytes", 23)} ],
        @[ @"chain", @(SZFriendsFrameTypeChain), @{@(33) : D(@"chain bytes", 40)} ],
        @[ @"join", @(SZFriendsFrameTypeJoin), @{@(34) : D(@"join bytes", 20)} ],
        @[ @"sync", @(SZFriendsFrameTypeSync), @{@(35) : D(@"sync bytes", 20)} ],
    ];
    NSMutableArray *out = [NSMutableArray array];
    for (NSArray *entry in cases) {
        SZFriendsFrame *frame = [SZFriendsFrame frameWithType:(SZFriendsFrameType)[entry[1] unsignedCharValue]
                                                       fields:entry[2]];
        NSError *error = nil;
        NSData *encoded = SZFriendsEncodeFrame(frame, &error);
        if (encoded == nil) {
            fprintf(stderr, "SZFVectorExport: %s does not encode: %s\n", [entry[0] UTF8String],
                    error.debugDescription.UTF8String);
            exit(1);
        }
        [out addObject:@{@"name" : entry[0], @"type" : entry[1], @"fields" : Fields(entry[2]),
                         @"encoded" : SZFHexString(encoded)}];
    }
    return out;
}

// Raw plaintext: a type byte, then tag, u16be length, value for each part.
static NSData *Raw(uint8_t type, NSArray<NSArray *> *parts) {
    NSMutableData *out = [NSMutableData dataWithBytes:&type length:1];
    for (NSArray *part in parts) {
        NSData *value = part[1];
        uint8_t header[3] = {[part[0] unsignedCharValue], (uint8_t)(value.length >> 8), (uint8_t)value.length};
        [out appendBytes:header length:3];
        [out appendData:value];
    }
    return out;
}

static NSArray *SZFDecodeCases(void) {
    NSData *ida = D(@"frame id a", 16), *at = U(5, SZFriendsFieldSentAt);
    NSMutableData *truncated = [Raw(12, @[ @[ @1, ida ] ]) mutableCopy];
    [truncated appendBytes:"\x02\x00" length:2];
    NSMutableData *overrun = [Raw(13, @[]) mutableCopy];
    [overrun appendBytes:"\x01\x00\x20" length:3];
    [overrun appendData:ida];
    NSArray *cases = @[
        @[ @"message", Raw(12, @[ @[ @1, ida ], @[ @2, at ], @[ @3, SZFUTF8(@"hi") ] ]) ],
        @[ @"fields_out_of_order", Raw(12, @[ @[ @3, SZFUTF8(@"hi") ], @[ @2, at ], @[ @1, ida ] ]) ],
        @[ @"empty", [NSData data] ],
        @[ @"unknown_type", Raw(200, @[]) ],
        @[ @"type_zero", Raw(0, @[]) ],
        @[ @"truncated_header", truncated ],
        @[ @"overrun", overrun ],
        @[ @"duplicate_tag", Raw(13, @[ @[ @1, ida ], @[ @1, ida ] ]) ],
        @[ @"duplicate_unknown_tag", Raw(13, @[ @[ @1, ida ], @[ @200, ida ], @[ @200, ida ] ]) ],
        @[ @"id_too_short", Raw(13, @[ @[ @1, [ida subdataWithRange:NSMakeRange(0, 15)] ] ]) ],
        @[ @"missing_required", Raw(12, @[ @[ @1, ida ], @[ @3, SZFUTF8(@"hi") ] ]) ],
        @[ @"unknown_tag_ignored", Raw(13, @[ @[ @1, ida ], @[ @200, SZFUTF8(@"later") ] ]) ],
        @[ @"other_types_tag_ignored", Raw(13, @[ @[ @1, ida ], @[ @13, D(@"secret", 32) ] ]) ],
        @[ @"other_types_tag_any_length", Raw(13, @[ @[ @1, ida ], @[ @13, D(@"secret", 20) ] ]) ],
        @[ @"via_assistant_two", Raw(12, @[ @[ @1, ida ], @[ @2, at ], @[ @29, Repeat(2, 1) ] ]) ],
        @[ @"accept_two", Raw(15, @[ @[ @1, ida ], @[ @12, Repeat(2, 1) ] ]) ],
        @[ @"offer_ids_17", Raw(12, @[ @[ @1, ida ], @[ @2, at ], @[ @16, Repeat(3, 17) ] ]) ],
        @[ @"offer_ids_336", Raw(12, @[ @[ @1, ida ], @[ @2, at ], @[ @16, Repeat(3, 336) ] ]) ],
        @[ @"offer_ids_320", Raw(12, @[ @[ @1, ida ], @[ @2, at ], @[ @16, Repeat(3, 320) ] ]) ],
        @[ @"text_32768", Raw(12, @[ @[ @1, ida ], @[ @2, at ], @[ @3, Repeat('a', 32768) ] ]) ],
        @[ @"text_32769", Raw(12, @[ @[ @1, ida ], @[ @2, at ], @[ @3, Repeat('a', 32769) ] ]) ],
        @[ @"text_invalid_utf8_passes_codec", Raw(12, @[ @[ @1, ida ], @[ @2, at ], @[ @3, Repeat(0xff, 3) ] ]) ],
        @[ @"hello_with_fields", Raw(1, @[ @[ @1, ida ], @[ @9, SZFUTF8(@"x") ] ]) ],
        @[ @"hello_duplicate", Raw(1, @[ @[ @9, ida ], @[ @9, ida ] ]) ],
        @[ @"received_empty", Raw(8, @[]) ],
        @[ @"chunk_empty_data",
           Raw(17, @[ @[ @1, ida ], @[ @8, U(0, SZFriendsFieldOffset) ], @[ @9, [NSData data] ] ]) ],
        @[ @"chunk_61441", Raw(17, @[ @[ @1, ida ], @[ @8, U(0, SZFriendsFieldOffset) ], @[ @9, Repeat(1, 61441) ] ]) ],
        @[ @"thumbnail_22", Raw(23, @[ @[ @1, ida ], @[ @30, U(1, SZFriendsFieldWidth) ],
                                       @[ @31, U(1, SZFriendsFieldHeight) ], @[ @9, Repeat(1, 22) ] ]) ],
        @[ @"close_no_reason", Raw(22, @[]) ],
        @[ @"close_reason_99", Raw(22, @[ @[ @23, Repeat(99, 1) ] ]) ],
        @[ @"offset_seven_bytes", Raw(18, @[ @[ @1, ida ], @[ @8, Repeat(0, 7) ] ]) ],
        // Type, then 3 + 64,000 bytes of SYNC, then an unknown field padding the frame to the limit and one past it.
        @[ @"plaintext_65519", Raw(26, @[ @[ @35, Repeat(5, 64000) ], @[ @200, Repeat(6, 65519 - 64007) ] ]) ],
        @[ @"plaintext_65520", Raw(26, @[ @[ @35, Repeat(5, 64000) ], @[ @200, Repeat(6, 65520 - 64007) ] ]) ],
        @[ @"sync_64001", Raw(26, @[ @[ @35, Repeat(5, 64001) ] ]) ],
        @[ @"join_1001", Raw(25, @[ @[ @34, Repeat(5, 1001) ] ]) ],
    ];
    NSMutableArray *out = [NSMutableArray array];
    for (NSArray *entry in cases) {
        NSError *error = nil;
        SZFriendsFrame *frame = SZFriendsDecodeFrame(entry[1], &error);
        NSMutableDictionary *result = [@{@"name" : entry[0], @"input" : Compact(entry[1]), @"ok" : @(frame != nil)}
            mutableCopy];
        if (frame) {
            result[@"type"] = @(frame.type);
            result[@"fields"] = CompactFields(frame.fields);
        }
        [out addObject:result];
    }
    return out;
}

static NSDictionary *SZFPayloadEntry(NSString *name, SZFriendsHandshakePayload *payload) {
    return @{@"name" : name, @"encoded" : SZFHexString([payload encodedDataWithError:NULL])};
}

static NSArray *SZFPayloadCases(void) {
    SZFriendsHandshakePayload *local = [SZFriendsHandshakePayload localPayload];
    SZFriendsHandshakePayload *full = [SZFriendsHandshakePayload localPayload];
    full.certificate = D(@"certificate", 96);
    full.requestToken = D(@"token", 16);
    full.attestation = D(@"attestation", 100);
    full.hasRouteClass = YES;
    full.routeClass = 4;
    full.capabilities = 0x80000001;
    full.profile = @{
        @(SZFriendsFieldName) : SZFUTF8(@"Mei"),
        @(SZFriendsFieldPictureSet) : U(1, SZFriendsFieldPictureSet),
        @(SZFriendsFieldPictureIndex) : U(3, SZFriendsFieldPictureIndex),
    };
    return @[ SZFPayloadEntry(@"local", local), SZFPayloadEntry(@"full", full),
              SZFPayloadEntry(@"empty", [[SZFriendsHandshakePayload alloc] init]) ];
}

static NSArray *SZFPayloadDecodeCases(void) {
    NSData *(^raw)(NSArray *) = ^NSData *(NSArray *parts) {
        return [Raw(0, parts) subdataWithRange:NSMakeRange(1, Raw(0, parts).length - 1)];
    };
    NSArray *cases = @[
        @[ @"range_and_route", raw(@[ @[ @24, U(0, 24) ], @[ @25, U(2, 25) ], @[ @27, U(5, 27) ] ]) ],
        @[ @"min_without_max", raw(@[ @[ @24, U(1, 24) ] ]) ],
        @[ @"unknown_tag", raw(@[ @[ @200, SZFUTF8(@"x") ], @[ @26, U(7, 26) ] ]) ],
        @[ @"frame_tag_ignored", raw(@[ @[ @1, D(@"x", 16) ] ]) ],
        @[ @"duplicate", raw(@[ @[ @27, U(1, 27) ], @[ @27, U(1, 27) ] ]) ],
        @[ @"short_certificate", raw(@[ @[ @20, D(@"c", 32) ] ]) ],
        @[ @"profile_fields", raw(@[ @[ @4, SZFUTF8(@"Kenji") ], @[ @17, SZFUTF8(@"stone-river") ] ]) ],
        @[ @"attestation_513", raw(@[ @[ @28, Repeat(1, 513) ] ]) ],
    ];
    NSMutableArray *out = [NSMutableArray array];
    for (NSArray *entry in cases) {
        SZFriendsHandshakePayload *payload = [SZFriendsHandshakePayload payloadWithData:entry[1] error:NULL];
        NSMutableDictionary *result = [@{@"name" : entry[0], @"input" : Compact(entry[1]),
                                         @"ok" : @(payload != nil)} mutableCopy];
        if (payload) {
            result[@"has_minor_range"] = @(payload.hasMinorRange);
            result[@"minor_min"] = @(payload.minorMin);
            result[@"minor_max"] = @(payload.minorMax);
            result[@"capabilities"] = @(payload.capabilities);
            result[@"route_class"] = payload.hasRouteClass ? @(payload.routeClass) : [NSNull null];
            result[@"certificate"] = payload.certificate ? SZFHexString(payload.certificate) : [NSNull null];
            result[@"profile"] = payload.profile ? Fields(payload.profile) : [NSNull null];
        }
        [out addObject:result];
    }
    return out;
}

static NSArray *SZFNegotiationCases(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSArray<NSArray<NSNumber *> *> *ranges = @[ @[ @0, @2, @0, @1 ], @[ @0, @2, @3, @4 ], @[ @1, @1, @0, @5 ],
                                                @[ @2, @1, @0, @2 ], @[ @0, @0, @0, @0 ], @[ @0, @65535, @7, @9 ] ];
    for (NSArray<NSNumber *> *r in ranges) {
        uint16_t negotiated = 0;
        BOOL ok = SZFriendsNegotiateMinor(r[0].unsignedShortValue, r[1].unsignedShortValue, r[2].unsignedShortValue,
                                          r[3].unsignedShortValue, &negotiated);
        [out addObject:@{@"local" : @[ r[0], r[1] ], @"remote" : @[ r[2], r[3] ],
                         @"negotiated" : ok ? @(negotiated) : [NSNull null]}];
    }
    return out;
}

NSDictionary *SZFExportFrames(void) {
    return @{
        @"encode" : SZFEncodeCases(),
        @"decode" : SZFDecodeCases(),
        @"handshake_payloads" : SZFPayloadCases(),
        @"handshake_payload_decode" : SZFPayloadDecodeCases(),
        @"minor_negotiation" : SZFNegotiationCases(),
        @"session_minor" : @(SZFriendsSessionMinor),
        @"session_major" : @(SZFriendsSessionMajor),
        @"plaintext_max" : @(SZFriendsFramePlaintextMax),
    };
}
