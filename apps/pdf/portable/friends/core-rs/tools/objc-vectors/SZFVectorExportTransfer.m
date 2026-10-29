// Vector export: ADR 0018's fast-transfer vectors (fixtures/vectors/transfer/*.json), from the helper's own code.
//
// WP1 wrote these files from the ADR with the Rust core first (szfriends-core/tests/transfer_vectors.rs); this writes
// them again from the Objective-C helper's tree, codecs, sidecars and messages, in the same JSON layout byte for byte
// (serde_json's pretty printer: two-space indents, "key": value, keys in byte order, a final newline), so
// friends-vectors-check can compare the files with cmp. Every file's content uses the pattern `byte(i) = i mod 251`.

#import "SZFVectorExport.h"

#import <sodium.h>

#import "service/session/SZFriendsFrameSchema.h"
#import "service/session/SZFriendsHandshakePayload.h"
#import "service/session/SZFriendsSession.h"
#import "service/transfer/SZFriendsDirectWiFiBoost.h"
#import "service/transfer/SZFriendsTransferBlocks.h"

static const uint64_t kMiB = 1ull << 20;

#pragma mark - serde_json's pretty layout

static void SZFJSONString(NSMutableString *out, NSString *string) {
    [out appendString:@"\""];
    for (NSUInteger i = 0; i < string.length; i++) {
        unichar c = [string characterAtIndex:i];
        switch (c) {
        case '"': [out appendString:@"\\\""]; break;
        case '\\': [out appendString:@"\\\\"]; break;
        case '\n': [out appendString:@"\\n"]; break;
        case '\r': [out appendString:@"\\r"]; break;
        case '\t': [out appendString:@"\\t"]; break;
        case '\b': [out appendString:@"\\b"]; break;
        case '\f': [out appendString:@"\\f"]; break;
        default:
            if (c < 0x20) [out appendFormat:@"\\u%04x", c];
            else [out appendFormat:@"%C", c];
        }
    }
    [out appendString:@"\""];
}

static NSComparisonResult SZFByteOrder(NSString *a, NSString *b) {
    int order = strcmp(a.UTF8String, b.UTF8String);
    return order < 0 ? NSOrderedAscending : order > 0 ? NSOrderedDescending : NSOrderedSame;
}

static void SZFJSONValue(NSMutableString *out, id value, NSUInteger depth) {
    NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    NSString *inner = [@"" stringByPaddingToLength:(depth + 1) * 2 withString:@" " startingAtIndex:0];
    if ([value isKindOfClass:[NSString class]]) {
        SZFJSONString(out, value);
    } else if ([value isKindOfClass:[NSNumber class]]) {
        [out appendFormat:@"%llu", [value unsignedLongLongValue]];
    } else if (value == nil || value == [NSNull null]) {
        [out appendString:@"null"];
    } else if ([value isKindOfClass:[NSArray class]]) {
        NSArray *array = value;
        if (array.count == 0) {
            [out appendString:@"[]"];
            return;
        }
        [out appendString:@"[\n"];
        for (NSUInteger i = 0; i < array.count; i++) {
            [out appendString:inner];
            SZFJSONValue(out, array[i], depth + 1);
            [out appendString:i + 1 < array.count ? @",\n" : @"\n"];
        }
        [out appendFormat:@"%@]", indent];
    } else {
        NSDictionary *object = value;
        if (object.count == 0) {
            [out appendString:@"{}"];
            return;
        }
        NSArray *keys = [object.allKeys sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return SZFByteOrder(a, b);
        }];
        [out appendString:@"{\n"];
        for (NSUInteger i = 0; i < keys.count; i++) {
            [out appendString:inner];
            SZFJSONString(out, keys[i]);
            [out appendString:@": "];
            SZFJSONValue(out, object[keys[i]], depth + 1);
            [out appendString:i + 1 < keys.count ? @",\n" : @"\n"];
        }
        [out appendFormat:@"%@}", indent];
    }
}

#pragma mark - Inputs

// `byte(i) = i mod 251` from `offset`.
static NSData *SZFPattern(uint64_t offset, NSUInteger length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    uint8_t *bytes = data.mutableBytes;
    uint8_t value = (uint8_t)(offset % 251);
    for (NSUInteger i = 0; i < length; i++) {
        bytes[i] = value;
        value = value == 250 ? 0 : value + 1;
    }
    return data;
}

static NSData *SZFLeavesOf(SZFriendsBlockGeometry geometry) {
    NSMutableData *leaves = [NSMutableData dataWithLength:(NSUInteger)geometry.blocks * 32];
    uint8_t *out = leaves.mutableBytes;
    dispatch_apply(geometry.blocks, DISPATCH_APPLY_AUTO, ^(size_t i) {
        uint64_t offset = 0;
        NSUInteger length = 0;
        SZFriendsGeometrySpan(geometry, (uint32_t)i, &offset, &length);
        NSData *block = SZFPattern(offset, length);
        SZFriendsTreeLeaf((uint32_t)i, block.bytes, block.length, out + i * 32);
    });
    return leaves;
}

static NSArray<NSString *> *SZFHexes(NSData *leaves) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < leaves.length; i += 32) {
        [out addObject:SZFHexString([leaves subdataWithRange:NSMakeRange(i, 32)])];
    }
    return out;
}

static NSData *SZFBlake2b(NSData *data) {
    NSMutableData *out = [NSMutableData dataWithLength:32];
    crypto_generichash(out.mutableBytes, 32, data.bytes, data.length, NULL, 0);
    return out;
}

static NSData *SZFBytesOf(NSString *hex) {
    NSMutableData *out = [NSMutableData data];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        uint8_t byte = (uint8_t)strtoul([[hex substringWithRange:NSMakeRange(i, 2)] UTF8String], NULL, 16);
        [out appendBytes:&byte length:1];
    }
    return out;
}

static NSData *SZFRepeat(uint8_t byte, NSUInteger count) {
    NSMutableData *out = [NSMutableData dataWithLength:count];
    memset(out.mutableBytes, byte, count);
    return out;
}

static NSData *SZFU32(uint32_t value) {
    uint8_t bytes[4] = {(uint8_t)(value >> 24), (uint8_t)(value >> 16), (uint8_t)(value >> 8), (uint8_t)value};
    return [NSData dataWithBytes:bytes length:4];
}

static NSData *SZFU64(uint64_t value) {
    uint8_t bytes[8];
    for (int i = 7; i >= 0; i--, value >>= 8) bytes[i] = (uint8_t)value;
    return [NSData dataWithBytes:bytes length:8];
}

static NSData *SZFRanges(const uint32_t *pairs, NSUInteger count) {
    return [NSData dataWithBytes:pairs length:count * 8];
}

#pragma mark - tree.json

static NSDictionary *SZFTreeCase(NSString *name, uint64_t size, uint8_t shift) {
    SZFriendsBlockGeometry geometry;
    SZFriendsGeometryMake(size, shift, &geometry);
    NSData *leaves = SZFLeavesOf(geometry);
    NSArray<NSData *> *levels = SZFriendsTreeLevels(leaves);
    NSData *top = SZFriendsTreeTop(leaves);
    NSMutableDictionary *entry = [@{
        @"name" : name, @"size" : @(size), @"shift" : @(shift), @"blocks" : @(geometry.blocks),
        @"leaves" : SZFHexes(leaves), @"top" : SZFHexString(top),
        @"root" : SZFHexString(SZFriendsTreeRoot(geometry, top)),
    } mutableCopy];
    if (geometry.blocks <= 8) {
        // Every node above the leaves, level by level.
        NSMutableArray *nodes = [NSMutableArray array];
        for (NSUInteger i = 1; i < levels.count; i++) [nodes addObject:SZFHexes(levels[i])];
        entry[@"nodes"] = nodes;
    }
    return entry;
}

static NSDictionary *SZFTreeVectors(void) {
    NSMutableArray *cases = [NSMutableArray array];
    NSArray *named = @[
        @[ @"empty", @0 ], @[ @"one_byte", @1 ], @[ @"one_block_minus_one", @(kMiB - 1) ], @[ @"one_block", @(kMiB) ],
        @[ @"one_block_plus_one", @(kMiB + 1) ], @[ @"three_blocks_plus_7", @(3 * kMiB + 7) ]
    ];
    for (NSArray *pair in named) {
        SZFriendsBlockGeometry geometry;
        SZFriendsGeometryForSize([pair[1] unsignedLongLongValue], &geometry);
        [cases addObject:SZFTreeCase(pair[0], geometry.size, geometry.shift)];
    }
    [cases addObject:SZFTreeCase(@"three_blocks_plus_7_at_shift_21", 3 * kMiB + 7, 21)];
    [cases addObject:SZFTreeCase(@"one_gib_at_shift_20", 1ull << 30, 20)];
    [cases addObject:SZFTreeCase(@"one_gib_at_shift_21", 1ull << 30, 21)];
    NSMutableArray *geometries = [NSMutableArray array];
    for (NSNumber *size in @[ @0, @(kMiB), @(64ull << 30), @((64ull << 30) + 1), @(1ull << 40), @((1ull << 40) + 1) ]) {
        SZFriendsBlockGeometry geometry;
        if (SZFriendsGeometryForSize(size.unsignedLongLongValue, &geometry)) {
            [geometries addObject:@{@"size" : size, @"shift" : @(geometry.shift), @"blocks" : @(geometry.blocks)}];
        } else {
            [geometries addObject:@{@"size" : size, @"shift" : [NSNull null], @"blocks" : [NSNull null]}];
        }
    }
    return @{
        @"pattern" : @"byte(i) = i mod 251, i the offset in the file",
        @"prefixes" : @{
            @"leaf" : SZFHexString([NSData dataWithBytes:SZFriendsTreeLeafPrefix length:18]),
            @"node" : SZFHexString([NSData dataWithBytes:SZFriendsTreeNodePrefix length:18]),
            @"root" : SZFHexString([NSData dataWithBytes:SZFriendsTreeRootPrefix length:18]),
        },
        @"construction" : @[
            @"leaf(i) = BLAKE3(leaf prefix || u64be(i) || block i)",
            @"node = BLAKE3(node prefix || left || right); a lone last node moves up unchanged",
            @"root = BLAKE3(root prefix || u64be(size) || u8(shift) || top node)",
            @"an empty file is one empty block",
        ],
        @"geometry" : geometries,
        @"trees" : cases,
    };
}

#pragma mark - frames.json

static NSDictionary *SZFFieldsJSON(SZFriendsFrame *frame) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSNumber *tag in frame.fields) out[tag.stringValue] = @[ SZFHexString(frame.fields[tag]) ];
    return out;
}

static NSDictionary *SZFEncodeCase(NSString *name, SZFriendsFrame *frame) {
    NSData *encoded = SZFriendsEncodeFrame(frame, NULL);
    if (encoded == nil) {
        fprintf(stderr, "transfer vectors: %s does not encode\n", name.UTF8String);
        exit(1);
    }
    return @{@"name" : name, @"type" : @(frame.type), @"fields" : SZFFieldsJSON(frame),
             @"encoded" : SZFHexString(encoded)};
}

// The verdict is the helper's own decoder's; a difference from WP1's file is a difference in behaviour.
static NSDictionary *SZFDecodeCase(NSString *name, NSData *input) {
    SZFriendsFrame *frame = SZFriendsDecodeFrame(input, NULL);
    id shown;
    if (input.length > 4096) {
        // Long inputs as segments: the head in hex, then the run of the last byte that ends them.
        const uint8_t *bytes = input.bytes;
        uint8_t last = bytes[input.length - 1];
        NSUInteger run = 0;
        while (run < input.length && bytes[input.length - 1 - run] == last) run++;
        shown = @[ SZFHexString([input subdataWithRange:NSMakeRange(0, input.length - run)]),
                   [NSString stringWithFormat:@"%02x*%lu", last, (unsigned long)run] ];
    } else {
        shown = SZFHexString(input);
    }
    NSMutableDictionary *entry = [@{@"name" : name, @"input" : shown, @"ok" : @(frame != nil ? 1 : 0)} mutableCopy];
    if (frame != nil) {
        entry[@"type"] = @(frame.type);
        entry[@"fields"] = SZFFieldsJSON(frame);
    }
    return entry;
}

static NSData *SZFRaw(SZFriendsFrameType type, NSArray<NSArray *> *fields) {
    uint8_t first = type;
    NSMutableData *out = [NSMutableData dataWithBytes:&first length:1];
    for (NSArray *field in fields) {
        NSData *value = field[1];
        uint8_t head[3] = {(uint8_t)[field[0] unsignedIntValue], (uint8_t)(value.length >> 8), (uint8_t)value.length};
        [out appendBytes:head length:3];
        [out appendData:value];
    }
    return out;
}

static SZFriendsFrame *SZFFrame(SZFriendsFrameType type, NSDictionary *fields) {
    return [SZFriendsFrame frameWithType:type fields:fields];
}

static NSDictionary *SZFFrameVectors(void) {
    NSData *id_ = SZFBytesOf(@"1fb38b3957c13dfa57e5b603761145a3");
    SZFriendsBlockGeometry geometry;
    SZFriendsGeometryForSize(3 * kMiB + 7, &geometry);
    NSData *leaves = SZFLeavesOf(geometry);
    NSData *root = SZFriendsTreeRootOfLeaves(geometry, leaves);
    NSData *digest = SZFBlake2b(SZFPattern(0, (NSUInteger)(3 * kMiB + 7)));
    uint8_t shift = geometry.shift, one = 1, codec = 1;
    NSData *uno = [NSData dataWithBytes:&one length:1];
    NSDictionary *offer = @{
        @(SZFriendsFieldID) : id_, @(SZFriendsFieldName) : SZFUTF8(@"pattern.bin"),
        @(SZFriendsFieldFileType) : SZFUTF8(@"bin"), @(SZFriendsFieldSize) : SZFU64(3 * kMiB + 7),
        @(SZFriendsFieldDigest) : digest, @(SZFriendsFieldTreeRoot) : root,
        @(SZFriendsFieldBlockShift) : [NSData dataWithBytes:&shift length:1],
    };
    uint32_t want[] = {0, 2, 2, 1, 5, 1}, haveRanges[] = {0, 3}, haveDurable[] = {0, 1}, durableOnly[] = {1, 2};
    // Pieces (field 47): 16 KiB units counted from the start of the file (ADR 0018 § 3).
    uint32_t wantPieces[] = {70, 6, 130, 2}, block2[] = {2, 1}, block0[] = {0, 1}, havePieces[] = {64, 16},
             threeTwo[] = {3, 2};
    uint8_t compressed[] = {0x28, 0xb5, 0x2f, 0xfd};
    NSArray *encode = @[
        SZFEncodeCase(@"offer_with_tree", SZFFrame(SZFriendsFrameTypeOffer, offer)),
        SZFEncodeCase(@"offer_reply_blocks", SZFFrame(SZFriendsFrameTypeOfferReply, @{
            @(SZFriendsFieldID) : id_, @(SZFriendsFieldAccept) : uno, @(SZFriendsFieldBlocks) : uno})),
        SZFEncodeCase(@"hashes", SZFriendsHashesFrames(id_, leaves).firstObject),
        SZFEncodeCase(@"hashes_second_frame", SZFFrame(SZFriendsFrameTypeHashes, @{
            @(SZFriendsFieldID) : id_, @(SZFriendsFieldIndex) : SZFU32(2000),
            @(SZFriendsFieldHashes) : [leaves subdataWithRange:NSMakeRange(3 * 32, 32)]})),
        SZFEncodeCase(@"want", SZFriendsWantFrames(id_, SZFRanges(want, 3)).firstObject),
        SZFEncodeCase(@"part", SZFriendsPartFrame(id_, kMiB, SZFUTF8(@"hello"))),
        SZFEncodeCase(@"part_compressed", SZFFrame(SZFriendsFrameTypePart, @{
            @(SZFriendsFieldID) : id_, @(SZFriendsFieldOffset) : SZFU64(0),
            @(SZFriendsFieldData) : [NSData dataWithBytes:compressed length:4],
            @(SZFriendsFieldCodec) : [NSData dataWithBytes:&codec length:1], @(SZFriendsFieldLength) : SZFU32(61440)})),
        SZFEncodeCase(@"have", SZFriendsHaveFrames(id_, SZFRanges(haveRanges, 1), SZFRanges(haveDurable, 1)).firstObject),
        SZFEncodeCase(@"have_durable_only", SZFriendsHaveFrames(id_, [NSData data], SZFRanges(durableOnly, 1)).firstObject),
        SZFEncodeCase(@"want_pieces_only",
                      SZFriendsWantFramesWithPieces(id_, [NSData data], SZFRanges(wantPieces, 2)).firstObject),
        SZFEncodeCase(@"want_blocks_and_pieces",
                      SZFriendsWantFramesWithPieces(id_, SZFRanges(block2, 1), SZFRanges(wantPieces, 1)).firstObject),
        SZFEncodeCase(@"have_pieces_and_ranges",
                      SZFriendsHaveFramesWithPieces(id_, SZFRanges(block0, 1), SZFRanges(block0, 1),
                                                    SZFRanges(havePieces, 1)).firstObject),
        // BOOST (ADR 0019), the Wi-Fi Direct boost's five steps; the link is the one 64 bytes of 0x2a make.
        SZFEncodeCase(@"boost_propose", [[SZFriendsBoostMessage propose:SZFriendsBoostCanJoin] frameForTransfer:id_]),
        SZFEncodeCase(@"boost_ready",
                      [[SZFriendsBoostMessage ready:SZFriendsBoostCanHost | SZFriendsBoostCanJoin |
                                                    SZFriendsBoostHostKeepsWiFi | SZFriendsBoostJoinKeepsWiFi]
                          frameForTransfer:id_]),
        SZFEncodeCase(@"boost_host", [[SZFriendsBoostMessage host:[SZFriendsBoostLink linkFromRandom:SZFRepeat(0x2a, 64)]
                                                          address:[NSData dataWithBytes:(const uint8_t[]){192, 168, 49, 1} length:4]
                                                             port:49200] frameForTransfer:id_]),
        SZFEncodeCase(@"boost_end", [[SZFriendsBoostMessage end:SZFriendsBoostReasonSlower] frameForTransfer:id_]),
        SZFEncodeCase(@"boost_decline",
                      [[SZFriendsBoostMessage decline:SZFriendsBoostReasonNotNow] frameForTransfer:id_]),
    ];
    NSData *threeTwoField = SZFriendsRangesEncode(SZFRanges(threeTwo, 1)).firstObject;
    NSArray *idField = @[ @(SZFriendsFieldID), id_ ];
    NSArray *decode = @[
        SZFDecodeCase(@"hashes_not_whole_leaves", SZFRaw(SZFriendsFrameTypeHashes, @[
            idField, @[ @(SZFriendsFieldIndex), SZFRepeat(0, 4) ], @[ @(SZFriendsFieldHashes), SZFRepeat(1, 33) ] ])),
        SZFDecodeCase(@"hashes_without_index",
                      SZFRaw(SZFriendsFrameTypeHashes, @[ idField, @[ @(SZFriendsFieldHashes), SZFRepeat(1, 32) ] ])),
        SZFDecodeCase(@"hashes_index_two_bytes", SZFRaw(SZFriendsFrameTypeHashes, @[
            idField, @[ @(SZFriendsFieldIndex), SZFRepeat(0, 2) ], @[ @(SZFriendsFieldHashes), SZFRepeat(1, 32) ] ])),
        SZFDecodeCase(@"hashes_2001_leaves", SZFRaw(SZFriendsFrameTypeHashes, @[
            idField, @[ @(SZFriendsFieldIndex), SZFRepeat(0, 4) ], @[ @(SZFriendsFieldHashes), SZFRepeat(1, 64032) ] ])),
        SZFDecodeCase(@"want_without_ranges", SZFRaw(SZFriendsFrameTypeWant, @[ idField ])),
        SZFDecodeCase(@"want_half_a_range",
                      SZFRaw(SZFriendsFrameTypeWant, @[ idField, @[ @(SZFriendsFieldRanges), SZFRepeat(0, 4) ] ])),
        // WANT carries Ranges, Pieces or both: at least one ("want_without_ranges" has neither).
        SZFDecodeCase(@"want_pieces_half_a_range",
                      SZFRaw(SZFriendsFrameTypeWant, @[ idField, @[ @(SZFriendsFieldPieces), SZFRepeat(0, 4) ] ])),
        SZFDecodeCase(@"want_pieces_only",
                      SZFRaw(SZFriendsFrameTypeWant, @[ idField, @[ @(SZFriendsFieldPieces), threeTwoField ] ])),
        SZFDecodeCase(@"have_pieces_only",
                      SZFRaw(SZFriendsFrameTypeHave, @[ idField, @[ @(SZFriendsFieldPieces), threeTwoField ] ])),
        SZFDecodeCase(@"want_8001_ranges",
                      SZFRaw(SZFriendsFrameTypeWant, @[ idField, @[ @(SZFriendsFieldRanges), SZFRepeat(0, 64008) ] ])),
        SZFDecodeCase(@"part_61441_bytes", SZFRaw(SZFriendsFrameTypePart, @[
            idField, @[ @(SZFriendsFieldOffset), SZFRepeat(0, 8) ], @[ @(SZFriendsFieldData), SZFRepeat(0xbb, 61441) ]
        ])),
        SZFDecodeCase(@"part_without_offset",
                      SZFRaw(SZFriendsFrameTypePart, @[ idField, @[ @(SZFriendsFieldData), SZFRepeat(1, 1) ] ])),
        SZFDecodeCase(@"part_length_two_bytes", SZFRaw(SZFriendsFrameTypePart, @[
            idField, @[ @(SZFriendsFieldOffset), SZFRepeat(0, 8) ], @[ @(SZFriendsFieldData), SZFRepeat(1, 1) ],
            @[ @(SZFriendsFieldLength), SZFRepeat(0, 2) ]
        ])),
        SZFDecodeCase(@"have_with_nothing", SZFRaw(SZFriendsFrameTypeHave, @[ idField ])),
        SZFDecodeCase(@"offer_reply_blocks_not_boolean", SZFRaw(SZFriendsFrameTypeOfferReply, @[
            idField, @[ @(SZFriendsFieldAccept), SZFRepeat(1, 1) ], @[ @(SZFriendsFieldBlocks), SZFRepeat(2, 1) ] ])),
        SZFDecodeCase(@"offer_tree_root_short", SZFRaw(SZFriendsFrameTypeOffer, @[
            idField, @[ @(SZFriendsFieldName), SZFUTF8(@"a") ], @[ @(SZFriendsFieldSize), SZFRepeat(0, 8) ],
            @[ @(SZFriendsFieldDigest), SZFRepeat(0, 32) ], @[ @(SZFriendsFieldTreeRoot), SZFRepeat(0, 31) ]
        ])),
        SZFDecodeCase(@"boost_without_step", SZFRaw(SZFriendsFrameTypeBoost, @[ idField ])),
        SZFDecodeCase(@"boost_network_33_bytes", SZFRaw(SZFriendsFrameTypeBoost, @[
            idField, @[ @(SZFriendsFieldStep), SZFRepeat(3, 1) ], @[ @(SZFriendsFieldNetwork), SZFRepeat('D', 33) ] ])),
        SZFDecodeCase(@"boost_passphrase_7_bytes", SZFRaw(SZFriendsFrameTypeBoost, @[
            idField, @[ @(SZFriendsFieldStep), SZFRepeat(3, 1) ], @[ @(SZFriendsFieldPassphrase), SZFRepeat('p', 7) ] ])),
        SZFDecodeCase(@"boost_port_one_byte", SZFRaw(SZFriendsFrameTypeBoost, @[
            idField, @[ @(SZFriendsFieldStep), SZFRepeat(3, 1) ], @[ @(SZFriendsFieldPort), SZFRepeat(1, 1) ] ])),
        SZFDecodeCase(@"chunk_ignores_part_fields", SZFRaw(SZFriendsFrameTypeChunk, @[
            idField, @[ @(SZFriendsFieldOffset), SZFRepeat(0, 8) ], @[ @(SZFriendsFieldData), SZFRepeat(1, 1) ],
            @[ @(SZFriendsFieldCodec), SZFRepeat(1, 1) ]
        ])),
    ];
    NSArray *rangeCases = @[
        @[ @"one", @"0000000000000001" ], @[ @"two", @"00000000000000030000000500000001" ],
        @[ @"adjacent", @"00000000000000030000000300000001" ], @[ @"last_block", @"ffffffff00000001" ],
        @[ @"empty_range", @"0000000400000000" ], @[ @"overlapping", @"00000000000000030000000200000001" ],
        @[ @"descending", @"00000005000000010000000000000001" ], @[ @"past_the_last_block", @"ffffffff00000002" ],
    ];
    NSMutableArray *ranges = [NSMutableArray array];
    for (NSArray *range in rangeCases) {
        NSData *input = SZFBytesOf(range[1]);
        [ranges addObject:@{@"name" : range[0], @"input" : range[1], @"ok" : @(SZFriendsRangesDecode(input) ? 1 : 0)}];
    }
    SZFriendsHandshakePayload *fast = [SZFriendsHandshakePayload localPayload];
    fast.capabilities = SZFriendsCapabilityFastTransfers;
    SZFriendsHandshakePayload *lane = [SZFriendsHandshakePayload localPayload];
    lane.capabilities = SZFriendsCapabilityFastTransfers;
    lane.hasRouteClass = YES;
    lane.routeClass = SZFriendsRouteMethodLAN;
    lane.lane = SZFriendsLaneToken(SZFRepeat(0x5a, 64), 1);
    return @{
        @"session_minor" : @(SZFriendsSessionMinor),
        @"capabilities" : @{@"fast_transfers" : @(SZFriendsCapabilityFastTransfers),
                            @"aes_lanes" : @(SZFriendsCapabilityAESLanes),
                            @"compressed_parts" : @(SZFriendsCapabilityCompressedParts)},
        @"close_lane_refused" : @(SZFriendsCloseReasonLaneRefused),
        @"piece_shift" : @(SZFriendsPieceShift),
        @"encode" : encode,
        @"decode" : decode,
        @"ranges" : ranges,
        @"handshake_payloads" : @[
            @{@"name" : @"fast_transfers", @"encoded" : SZFHexString([fast encodedDataWithError:NULL])},
            @{@"name" : @"lane", @"encoded" : SZFHexString([lane encodedDataWithError:NULL])},
        ],
    };
}

#pragma mark - lanes.json, sidecars.json, messages.json

static NSDictionary *SZFLaneVectors(void) {
    NSMutableData *counting = [NSMutableData dataWithLength:64];
    for (NSUInteger i = 0; i < 64; i++) ((uint8_t *)counting.mutableBytes)[i] = (uint8_t)i;
    NSMutableArray *lanes = [NSMutableArray array];
    for (NSArray *pair in @[ @[ counting, @1 ], @[ SZFRepeat(0xa5, 64), @15 ] ]) {
        uint8_t index = [pair[1] unsignedCharValue];
        [lanes addObject:@{@"h" : SZFHexString(pair[0]), @"index" : pair[1],
                           @"token" : SZFHexString(SZFriendsLaneToken(pair[0], index))}];
    }
    return @{@"construction" : @"keyed BLAKE2b-128, key h (64 bytes), over \"SZFriends lane v1\" || u8 index",
             @"lanes" : lanes};
}

static NSDictionary *SZFSidecarVectors(void) {
    uint64_t size = 3 * kMiB + 7;
    SZFriendsBlockGeometry geometry;
    SZFriendsGeometryForSize(size, &geometry);
    NSData *leaves = SZFLeavesOf(geometry);
    NSData *root = SZFriendsTreeRootOfLeaves(geometry, leaves);
    NSData *digest = SZFBlake2b(SZFPattern(0, (NSUInteger)size));
    SZFriendsBlockMap *offered = [[SZFriendsBlockMap alloc] initWithGeometry:geometry root:root digest:digest];
    SZFriendsBlockMap *checked = [[SZFriendsBlockMap alloc] initWithGeometry:geometry root:root digest:digest];
    checked.leaves = leaves;
    [checked.durable insert:0];
    [checked.durable insert:2];
    return @{
        @"file" : @{@"size" : @(size), @"shift" : @(geometry.shift), @"pattern" : @"byte(i) = i mod 251"},
        @"map_at_offer" : SZFHexString(offered.encoded),
        @"map_blocks_0_and_2_durable" : SZFHexString(checked.encoded),
        @"tree" : SZFHexString(SZFriendsSenderTreeEncode(geometry, root, digest, leaves)),
    };
}

static NSDictionary *SZFMessageVectors(void) {
    NSString *id_ = @"1fb38b3957c13dfa57e5b603761145a3";
    uint32_t pairs[] = {0, 2, 3, 1};
    NSData *ranges = SZFRanges(pairs, 2), *root = SZFRepeat(0x42, 32);
    return @{
        @"sync" : @[
            @{@"name" : @"want_blocks", @"kind" : @7, @"encoded" : SZFHexString(SZFriendsSyncWantBlocks(id_, 20, ranges))},
            @{@"name" : @"blocks_follow", @"kind" : @8,
              @"encoded" : SZFHexString(SZFriendsSyncBlocksFollow(id_, root, 20))},
        ],
        @"again" : @[
            @{@"name" : @"want_blocks", @"kind" : @4,
              @"encoded" : SZFHexString(SZFriendsAgainWantBlocks(id_, 20, ranges))},
            @{@"name" : @"blocks_follow", @"kind" : @5,
              @"encoded" : SZFHexString(SZFriendsAgainBlocksFollow(id_, root, 20))},
        ],
    };
}

BOOL SZFExportTransfer(NSString *directory) {
    NSString *transfer = [directory stringByAppendingPathComponent:@"transfer"];
    [NSFileManager.defaultManager createDirectoryAtPath:transfer withIntermediateDirectories:YES attributes:nil
                                                  error:NULL];
    NSDictionary *files = @{
        @"tree.json" : SZFTreeVectors(), @"frames.json" : SZFFrameVectors(), @"lanes.json" : SZFLaneVectors(),
        @"sidecars.json" : SZFSidecarVectors(), @"messages.json" : SZFMessageVectors(),
    };
    for (NSString *name in files) {
        NSMutableString *text = [NSMutableString string];
        SZFJSONValue(text, files[name], 0);
        [text appendString:@"\n"];
        NSError *error = nil;
        if (![text writeToFile:[transfer stringByAppendingPathComponent:name] atomically:YES
                      encoding:NSUTF8StringEncoding error:&error]) {
            fprintf(stderr, "transfer vectors: %s\n", error.localizedDescription.UTF8String);
            return NO;
        }
    }
    return YES;
}
