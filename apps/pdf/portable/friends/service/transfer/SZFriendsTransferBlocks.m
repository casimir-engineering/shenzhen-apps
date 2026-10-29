// Fast transfers' pure parts (SZFriendsTransferBlocks.h), byte for byte the Rust core's transfer/ modules.

#import "service/transfer/SZFriendsTransferBlocks.h"
#import "service/transfer/SZFriendsBlockBytes.h"

#import <sodium.h>
#import <unistd.h>

#import "blake3.h"

const uint8_t SZFriendsBlockShiftMin = 20;
const uint8_t SZFriendsBlockShiftMax = 24;
const uint32_t SZFriendsBlocksMax = 65536;
const NSUInteger SZFriendsLeavesPerHashes = 2000;
const NSUInteger SZFriendsRangesPerField = 8000;
const NSUInteger SZFriendsPartBytesMax = 61440;
const NSUInteger SZFriendsBlocksInFlightMax = 64;
const uint64_t SZFriendsBytesInFlightMax = 64ull << 20;
const NSUInteger SZFriendsSidecarHeaderBytes = 88;

const uint8_t SZFriendsTreeLeafPrefix[18] = "SZFriends leaf v1";
const uint8_t SZFriendsTreeNodePrefix[18] = "SZFriends node v1";
const uint8_t SZFriendsTreeRootPrefix[18] = "SZFriends root v1";

#pragma mark - Geometry

BOOL SZFriendsGeometryMake(uint64_t size, uint8_t shift, SZFriendsBlockGeometry *geometry) {
    if (shift < SZFriendsBlockShiftMin || shift > SZFriendsBlockShiftMax) return NO;
    uint64_t blocks = size == 0 ? 1 : ((size - 1) >> shift) + 1;
    if (blocks > SZFriendsBlocksMax) return NO;
    *geometry = (SZFriendsBlockGeometry){size, shift, (uint32_t)blocks};
    return YES;
}

BOOL SZFriendsGeometryForSize(uint64_t size, SZFriendsBlockGeometry *geometry) {
    for (uint8_t shift = SZFriendsBlockShiftMin; shift <= SZFriendsBlockShiftMax; shift++) {
        if (SZFriendsGeometryMake(size, shift, geometry)) return YES;
    }
    return NO;
}

void SZFriendsGeometrySpan(SZFriendsBlockGeometry geometry, uint32_t index, uint64_t *offset, NSUInteger *length) {
    uint64_t start = (uint64_t)index << geometry.shift;
    uint64_t left = geometry.size > start ? geometry.size - start : 0;
    *offset = start;
    *length = (NSUInteger)MIN(left, 1ull << geometry.shift);
}

#pragma mark - The tree

void SZFriendsTreeLeaf(uint32_t index, const void *block, size_t length, uint8_t *out) {
    blake3_hasher hasher;
    blake3_hasher_init(&hasher);
    uint8_t position[8];
    SZFriendsPutU64(position, index);
    blake3_hasher_update(&hasher, SZFriendsTreeLeafPrefix, sizeof SZFriendsTreeLeafPrefix);
    blake3_hasher_update(&hasher, position, sizeof position);
    blake3_hasher_update(&hasher, block, length);
    blake3_hasher_finalize(&hasher, out, 32);
}

void SZFriendsTreeNode(const uint8_t *left, const uint8_t *right, uint8_t *out) {
    blake3_hasher hasher;
    blake3_hasher_init(&hasher);
    blake3_hasher_update(&hasher, SZFriendsTreeNodePrefix, sizeof SZFriendsTreeNodePrefix);
    blake3_hasher_update(&hasher, left, 32);
    blake3_hasher_update(&hasher, right, 32);
    blake3_hasher_finalize(&hasher, out, 32);
}

NSArray<NSData *> *SZFriendsTreeLevels(NSData *leaves) {
    NSMutableArray<NSData *> *levels = [NSMutableArray arrayWithObject:[leaves copy]];
    while (levels.lastObject.length > 32) {
        NSData *below = levels.lastObject;
        NSUInteger count = below.length / 32;
        NSMutableData *above = [NSMutableData dataWithLength:((count + 1) / 2) * 32];
        const uint8_t *in = below.bytes;
        uint8_t *out = above.mutableBytes;
        for (NSUInteger i = 0; i < count; i += 2) {
            if (i + 1 < count) SZFriendsTreeNode(in + i * 32, in + (i + 1) * 32, out + (i / 2) * 32);
            else memcpy(out + (i / 2) * 32, in + i * 32, 32); // a lone last node moves up unchanged
        }
        [levels addObject:above];
    }
    return levels;
}

NSData *SZFriendsTreeTop(NSData *leaves) {
    NSData *top = SZFriendsTreeLevels(leaves).lastObject;
    return top.length == 32 ? top : [NSMutableData dataWithLength:32];
}

NSData *SZFriendsTreeRoot(SZFriendsBlockGeometry geometry, NSData *top) {
    blake3_hasher hasher;
    blake3_hasher_init(&hasher);
    uint8_t size[8];
    SZFriendsPutU64(size, geometry.size);
    blake3_hasher_update(&hasher, SZFriendsTreeRootPrefix, sizeof SZFriendsTreeRootPrefix);
    blake3_hasher_update(&hasher, size, sizeof size);
    blake3_hasher_update(&hasher, &geometry.shift, 1);
    blake3_hasher_update(&hasher, top.bytes, MIN(top.length, (NSUInteger)32));
    uint8_t out[32];
    blake3_hasher_finalize(&hasher, out, sizeof out);
    return [NSData dataWithBytes:out length:sizeof out];
}

NSData *SZFriendsTreeRootOfLeaves(SZFriendsBlockGeometry geometry, NSData *leaves) {
    if (leaves.length != (NSUInteger)geometry.blocks * 32) return nil;
    return SZFriendsTreeRoot(geometry, SZFriendsTreeTop(leaves));
}

// Blocks read and hashed together: enough to keep every core busy, bounded in memory.
static const uint64_t SZFriendsHashBatchBytes = 64ull << 20;

static BOOL SZFriendsReadFully(int fd, uint8_t *buffer, size_t length, uint64_t offset) {
    size_t done = 0;
    while (done < length) {
        ssize_t got = pread(fd, buffer + done, length - done, (off_t)(offset + done));
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return NO;
        done += (size_t)got;
    }
    return YES;
}

BOOL SZFriendsHashFileTree(int fd, SZFriendsBlockGeometry geometry, NSData **leavesOut, NSData **digestOut) {
    NSMutableData *leaves = [NSMutableData dataWithLength:(NSUInteger)geometry.blocks * 32];
    uint64_t blockBytes = 1ull << geometry.shift;
    uint32_t perBatch = (uint32_t)MAX(1, SZFriendsHashBatchBytes / blockBytes);
    uint8_t *buffer = malloc((size_t)MIN((uint64_t)perBatch * blockBytes, MAX(geometry.size, (uint64_t)1)));
    if (buffer == NULL) return NO;
    crypto_generichash_state state;
    crypto_generichash_init(&state, NULL, 0, 32);
    crypto_generichash_state *digest = digestOut ? &state : NULL;
    dispatch_queue_t digestQueue = dispatch_queue_create("szfriends.tree.digest", DISPATCH_QUEUE_SERIAL);
    uint8_t *leafBytes = leaves.mutableBytes;
    BOOL ok = YES;
    for (uint32_t first = 0; ok && first < geometry.blocks; first += perBatch) {
        uint32_t count = MIN(perBatch, geometry.blocks - first);
        uint64_t offset = (uint64_t)first << geometry.shift;
        uint64_t length = MIN((uint64_t)count * blockBytes, geometry.size - offset);
        if (length > 0 && !SZFriendsReadFully(fd, buffer, (size_t)length, offset)) {
            ok = NO;
            break;
        }
        // The digest of this batch on its own thread while every core hashes its leaves.
        dispatch_group_t group = dispatch_group_create();
        if (digest) {
            dispatch_group_async(group, digestQueue, ^{
                crypto_generichash_update(digest, buffer, (unsigned long long)length);
            });
        }
        dispatch_apply(count, DISPATCH_APPLY_AUTO, ^(size_t i) {
            uint64_t start = (uint64_t)i * blockBytes;
            size_t size = (size_t)MIN(blockBytes, length - MIN(start, length));
            SZFriendsTreeLeaf(first + (uint32_t)i, buffer + start, size, leafBytes + ((size_t)first + i) * 32);
        });
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    }
    free(buffer);
    if (!ok) return NO;
    *leavesOut = leaves;
    if (digestOut) {
        uint8_t out[32];
        crypto_generichash_final(&state, out, sizeof out);
        *digestOut = [NSData dataWithBytes:out length:sizeof out];
    }
    return YES;
}

#pragma mark - Block sets and ranges

@implementation SZFriendsBlockSet {
    NSMutableData *_bits; // one bit per block, uint64_t words
}

- (instancetype)initWithCount:(uint32_t)count {
    if ((self = [super init])) {
        _blockCount = count;
        _bits = [NSMutableData dataWithLength:(((NSUInteger)count + 63) / 64) * 8];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    SZFriendsBlockSet *copy = [[SZFriendsBlockSet allocWithZone:zone] initWithCount:_blockCount];
    copy->_bits = [_bits mutableCopy];
    copy->_members = _members;
    return copy;
}

+ (instancetype)setWithCount:(uint32_t)count bitmap:(NSData *)bitmap {
    if (bitmap.length != ((NSUInteger)count + 7) / 8) return nil;
    SZFriendsBlockSet *set = [[SZFriendsBlockSet alloc] initWithCount:count];
    const uint8_t *bytes = bitmap.bytes;
    for (NSUInteger byte = 0; byte < bitmap.length; byte++) {
        for (uint32_t bit = 0; bit < 8; bit++) {
            if (!(bytes[byte] & (0x80 >> bit))) continue;
            uint64_t index = (uint64_t)byte * 8 + bit;
            if (index >= count) return nil;
            [set insert:(uint32_t)index];
        }
    }
    return set;
}

- (BOOL)full {
    return _members == _blockCount;
}

- (BOOL)contains:(uint32_t)index {
    const uint64_t *words = _bits.bytes;
    return index < _blockCount && (words[index / 64] & (1ull << (index % 64))) != 0;
}

- (BOOL)insert:(uint32_t)index {
    if (index >= _blockCount || [self contains:index]) return NO;
    ((uint64_t *)_bits.mutableBytes)[index / 64] |= 1ull << (index % 64);
    _members++;
    return YES;
}

- (BOOL)remove:(uint32_t)index {
    if (![self contains:index]) return NO;
    ((uint64_t *)_bits.mutableBytes)[index / 64] &= ~(1ull << (index % 64));
    _members--;
    return YES;
}

- (void)insertFirst:(uint32_t)first count:(uint32_t)count {
    uint64_t end = MIN((uint64_t)first + count, (uint64_t)_blockCount);
    for (uint64_t index = first; index < end; index++) [self insert:(uint32_t)index];
}

- (BOOL)fitsRanges:(NSData *)ranges {
    const uint32_t *pairs = ranges.bytes;
    for (NSUInteger i = 0; i < ranges.length / 8; i++) {
        if ((uint64_t)pairs[2 * i] + pairs[2 * i + 1] > _blockCount) return NO;
    }
    return YES;
}

- (NSData *)runsWhere:(BOOL)present {
    NSMutableData *out = [NSMutableData data];
    uint32_t run[2] = {0, 0};
    for (uint32_t index = 0; index < _blockCount; index++) {
        if ([self contains:index] != present) continue;
        if (run[1] > 0 && run[0] + run[1] == index) {
            run[1]++;
            continue;
        }
        if (run[1] > 0) [out appendBytes:run length:sizeof run];
        run[0] = index;
        run[1] = 1;
    }
    if (run[1] > 0) [out appendBytes:run length:sizeof run];
    return out;
}

- (NSData *)ranges {
    return [self runsWhere:YES];
}

- (NSData *)missingRanges {
    return [self runsWhere:NO];
}

- (uint32_t)prefix {
    for (uint32_t index = 0; index < _blockCount; index++) {
        if (![self contains:index]) return index;
    }
    return _blockCount;
}

- (NSData *)bitmap {
    NSMutableData *out = [NSMutableData dataWithLength:((NSUInteger)_blockCount + 7) / 8];
    uint8_t *bytes = out.mutableBytes;
    for (uint32_t index = 0; index < _blockCount; index++) {
        if ([self contains:index]) bytes[index / 8] |= (uint8_t)(0x80 >> (index % 8));
    }
    return out;
}

@end

NSData *SZFriendsRangesDecode(NSData *field) {
    if (field.length % 8 != 0 || field.length / 8 > SZFriendsRangesPerField) return nil;
    NSMutableData *out = [NSMutableData dataWithCapacity:field.length];
    const uint8_t *bytes = field.bytes;
    uint64_t nextFree = 0;
    for (NSUInteger i = 0; i < field.length; i += 8) {
        uint32_t pair[2] = {SZFriendsU32(bytes + i), SZFriendsU32(bytes + i + 4)};
        uint64_t end = (uint64_t)pair[0] + pair[1];
        if (pair[1] == 0 || pair[0] < nextFree || end > (uint64_t)UINT32_MAX + 1) return nil;
        nextFree = end;
        [out appendBytes:pair length:sizeof pair];
    }
    return out;
}

NSArray<NSData *> *SZFriendsRangesEncode(NSData *ranges) {
    NSMutableData *merged = [NSMutableData data];
    const uint32_t *pairs = ranges.bytes;
    for (NSUInteger i = 0; i < ranges.length / 8; i++) {
        uint32_t first = pairs[2 * i], count = pairs[2 * i + 1];
        if (count == 0) continue;
        uint32_t *last = merged.length ? (uint32_t *)merged.mutableBytes + merged.length / 4 - 2 : NULL;
        if (last && (uint64_t)last[0] + last[1] == first) {
            last[1] += count;
        } else {
            uint32_t pair[2] = {first, count};
            [merged appendBytes:pair length:sizeof pair];
        }
    }
    NSMutableArray<NSData *> *fields = [NSMutableArray array];
    const uint32_t *runs = merged.bytes;
    NSUInteger total = merged.length / 8;
    for (NSUInteger start = 0; start < total; start += SZFriendsRangesPerField) {
        NSUInteger n = MIN(SZFriendsRangesPerField, total - start);
        NSMutableData *field = [NSMutableData dataWithLength:n * 8];
        uint8_t *out = field.mutableBytes;
        for (NSUInteger i = 0; i < n; i++) {
            SZFriendsPutU32(out + i * 8, runs[2 * (start + i)]);
            SZFriendsPutU32(out + i * 8 + 4, runs[2 * (start + i) + 1]);
        }
        [fields addObject:field];
    }
    return fields;
}

NSData *SZFriendsRange(uint32_t first, uint32_t count) {
    uint32_t pair[2] = {first, count};
    return [NSData dataWithBytes:pair length:sizeof pair];
}

#pragma mark - Minor-4 frames

NSArray<SZFriendsFrame *> *SZFriendsHashesFrames(NSData *transferID, NSData *leaves) {
    NSMutableArray<SZFriendsFrame *> *frames = [NSMutableArray array];
    NSUInteger per = SZFriendsLeavesPerHashes * 32;
    for (NSUInteger start = 0; start < leaves.length; start += per) {
        uint8_t index[4];
        SZFriendsPutU32(index, (uint32_t)(start / 32));
        NSRange range = NSMakeRange(start, MIN(per, leaves.length - start));
        [frames addObject:[SZFriendsFrame frameWithType:SZFriendsFrameTypeHashes
                                                 fields:@{
                                                     @(SZFriendsFieldID) : transferID,
                                                     @(SZFriendsFieldIndex) : [NSData dataWithBytes:index length:4],
                                                     @(SZFriendsFieldHashes) : [leaves subdataWithRange:range],
                                                 }]];
    }
    return frames;
}

NSArray<SZFriendsFrame *> *SZFriendsWantFrames(NSData *transferID, NSData *missing) {
    NSMutableArray<SZFriendsFrame *> *frames = [NSMutableArray array];
    for (NSData *field in SZFriendsRangesEncode(missing)) {
        [frames addObject:[SZFriendsFrame frameWithType:SZFriendsFrameTypeWant
                                                 fields:@{@(SZFriendsFieldID) : transferID,
                                                          @(SZFriendsFieldRanges) : field}]];
    }
    return frames;
}

// Frames of `type` carrying each field's ranges, as many as the longest field needs (szfriends-core frames::paired).
static NSArray<SZFriendsFrame *> *SZFriendsPairedFrames(SZFriendsFrameType type, NSData *transferID,
                                                        NSArray<NSNumber *> *tags, NSArray<NSData *> *ranges) {
    NSMutableArray<NSArray<NSData *> *> *encoded = [NSMutableArray array];
    NSUInteger frameCount = 0;
    for (NSData *pairs in ranges) {
        NSArray<NSData *> *fields = SZFriendsRangesEncode(pairs);
        [encoded addObject:fields];
        frameCount = MAX(frameCount, fields.count);
    }
    NSMutableArray<SZFriendsFrame *> *frames = [NSMutableArray array];
    for (NSUInteger i = 0; i < frameCount; i++) {
        NSMutableDictionary *fields = [NSMutableDictionary dictionaryWithObject:transferID forKey:@(SZFriendsFieldID)];
        for (NSUInteger f = 0; f < tags.count; f++) {
            if (i < encoded[f].count) fields[tags[f]] = encoded[f][i];
        }
        [frames addObject:[SZFriendsFrame frameWithType:type fields:fields]];
    }
    return frames;
}

NSArray<SZFriendsFrame *> *SZFriendsHaveFrames(NSData *transferID, NSData *complete, NSData *durable) {
    return SZFriendsPairedFrames(SZFriendsFrameTypeHave, transferID,
                                 @[ @(SZFriendsFieldRanges), @(SZFriendsFieldDurable) ], @[ complete, durable ]);
}

NSArray<SZFriendsFrame *> *SZFriendsWantFramesWithPieces(NSData *transferID, NSData *blocks, NSData *pieces) {
    return SZFriendsPairedFrames(SZFriendsFrameTypeWant, transferID,
                                 @[ @(SZFriendsFieldRanges), @(SZFriendsFieldPieces) ], @[ blocks, pieces ]);
}

NSArray<SZFriendsFrame *> *SZFriendsHaveFramesWithPieces(NSData *transferID, NSData *complete, NSData *durable,
                                                         NSData *pieces) {
    return SZFriendsPairedFrames(SZFriendsFrameTypeHave, transferID,
                                 @[ @(SZFriendsFieldRanges), @(SZFriendsFieldDurable), @(SZFriendsFieldPieces) ],
                                 @[ complete, durable, pieces ]);
}

const uint8_t SZFriendsPieceShift = 14;

BOOL SZFriendsWholePieces(uint64_t start, uint64_t end, uint64_t size, uint32_t *first, uint32_t *count) {
    uint64_t piece = 1ull << SZFriendsPieceShift;
    uint64_t from = (start + piece - 1) >> SZFriendsPieceShift;
    uint64_t to = end >= size ? (size + piece - 1) >> SZFriendsPieceShift : end >> SZFriendsPieceShift;
    if (to <= from) return NO;
    *first = (uint32_t)from;
    *count = (uint32_t)(to - from);
    return YES;
}

NSData *SZFriendsBlocksWithPieces(SZFriendsBlockGeometry geometry, NSData *blocks, NSData *pieces) {
    NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
    const uint32_t *pairs = blocks.bytes;
    for (NSUInteger i = 0; i < blocks.length / 8; i++) [set addIndexesInRange:NSMakeRange(pairs[2 * i], pairs[2 * i + 1])];
    uint64_t pieceCount = (geometry.size + (1ull << SZFriendsPieceShift) - 1) >> SZFriendsPieceShift;
    pairs = pieces.bytes;
    for (NSUInteger i = 0; i < pieces.length / 8; i++) {
        uint64_t first = pairs[2 * i], count = pairs[2 * i + 1];
        if (count == 0 || first + count > MAX(pieceCount, 1)) return nil;
        uint64_t firstBlock = (first << SZFriendsPieceShift) >> geometry.shift;
        uint64_t lastBlock = (((first + count) << SZFriendsPieceShift) - 1) >> geometry.shift;
        [set addIndexesInRange:NSMakeRange((NSUInteger)firstBlock, (NSUInteger)(lastBlock - firstBlock + 1))];
    }
    NSMutableData *out = [NSMutableData data];
    [set enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
        (void)stop;
        uint32_t pair[2] = {(uint32_t)range.location, (uint32_t)range.length};
        [out appendBytes:pair length:sizeof pair];
    }];
    return out;
}

SZFriendsFrame *SZFriendsPartFrame(NSData *transferID, uint64_t offset, NSData *data) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypePart
                                  fields:@{
                                      @(SZFriendsFieldID) : transferID,
                                      @(SZFriendsFieldOffset) : [SZFriendsFrame fieldWithUInt64:offset
                                                                                            tag:SZFriendsFieldOffset],
                                      @(SZFriendsFieldData) : data,
                                  }];
}

NSData *SZFriendsFrameRanges(SZFriendsFrame *frame, SZFriendsFieldTag tag) {
    NSData *field = [frame dataForTag:tag];
    return field ? SZFriendsRangesDecode(field) : [NSData data];
}

BOOL SZFriendsOfferedTree(SZFriendsFrame *offer, SZFriendsBlockGeometry *geometry, NSData **root) {
    NSData *treeRoot = [offer dataForTag:SZFriendsFieldTreeRoot];
    NSData *shift = [offer dataForTag:SZFriendsFieldBlockShift];
    uint64_t size = 0;
    if (treeRoot.length != 32 || shift.length != 1 || ![offer getUInt64:&size forTag:SZFriendsFieldSize]) return NO;
    if (!SZFriendsGeometryMake(size, ((const uint8_t *)shift.bytes)[0], geometry)) return NO;
    *root = treeRoot;
    return YES;
}
