// The receiver's assembly and the sender's serving of a transfer by blocks (SZFriendsBlockFlow.h).

#import "service/transfer/SZFriendsBlockFlow.h"

#import <sodium.h>

static BOOL SZFriendsLeafMatches(uint32_t block, NSData *data, NSData *leaves) {
    uint8_t leaf[32];
    SZFriendsTreeLeaf(block, data.bytes, data.length, leaf);
    return (NSUInteger)block * 32 + 32 <= leaves.length &&
           sodium_memcmp(leaf, (const uint8_t *)leaves.bytes + (NSUInteger)block * 32, 32) == 0;
}

// One block partly received: its bytes and the intervals of it that arrived.
@interface SZFriendsPartialBlock : NSObject
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic, strong) NSMutableArray<NSValue *> *covered; // NSRange, sorted and merged
@end

@implementation SZFriendsPartialBlock
// Whether `range` lies inside one received interval.
- (BOOL)has:(NSRange)range {
    for (NSValue *value in _covered) {
        NSRange covered = value.rangeValue;
        if (covered.location <= range.location && NSMaxRange(range) <= NSMaxRange(covered)) return YES;
    }
    return NO;
}
- (NSUInteger)filled {
    NSUInteger total = 0;
    for (NSValue *range in _covered) total += range.rangeValue.length;
    return total;
}
- (void)cover:(NSRange)range {
    [_covered addObject:[NSValue valueWithRange:range]];
    [_covered sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        return a.rangeValue.location < b.rangeValue.location   ? NSOrderedAscending
               : a.rangeValue.location > b.rangeValue.location ? NSOrderedDescending
                                                               : NSOrderedSame;
    }];
    NSMutableArray<NSValue *> *merged = [NSMutableArray array];
    for (NSValue *value in _covered) {
        NSRange next = value.rangeValue;
        NSRange last = merged.lastObject.rangeValue;
        if (merged.count && next.location <= NSMaxRange(last)) {
            merged[merged.count - 1] = [NSValue valueWithRange:NSUnionRange(last, next)];
        } else {
            [merged addObject:value];
        }
    }
    _covered = merged;
}
@end

@implementation SZFriendsBlockAssembly {
    NSMutableData *_gathered; // leaves received so far, before they check
    BOOL _leavesChecked;
    NSMutableDictionary<NSNumber *, SZFriendsPartialBlock *> *_partial;
    uint64_t _partialBytes;
    NSMutableIndexSet *_arrived; // pieces arrived whole in blocks not yet complete, not yet in a HAVE
}

static const NSUInteger SZFriendsPieceBytes = 1u << 14;

NSData *SZFriendsIndexesAsRanges(NSIndexSet *indexes) {
    NSMutableData *pairs = [NSMutableData data];
    [indexes enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
        (void)stop;
        uint32_t pair[2] = {(uint32_t)range.location, (uint32_t)range.length};
        [pairs appendBytes:pair length:sizeof pair];
    }];
    return pairs;
}

- (instancetype)initWithGeometry:(SZFriendsBlockGeometry)geometry root:(NSData *)root {
    if ((self = [super init])) {
        _geometry = geometry;
        _root = [root copy];
        _gathered = [NSMutableData data];
        _complete = [[SZFriendsBlockSet alloc] initWithCount:geometry.blocks];
        _partial = [NSMutableDictionary dictionary];
        _arrived = [NSMutableIndexSet indexSet];
    }
    return self;
}

+ (instancetype)resumedWithGeometry:(SZFriendsBlockGeometry)geometry
                               root:(NSData *)root
                             leaves:(NSData *)leaves
                           complete:(SZFriendsBlockSet *)complete {
    if (![SZFriendsTreeRootOfLeaves(geometry, leaves) isEqualToData:root] || complete.blockCount != geometry.blocks) {
        return nil;
    }
    SZFriendsBlockAssembly *assembly = [[self alloc] initWithGeometry:geometry root:root];
    assembly->_gathered = [leaves mutableCopy];
    assembly->_leavesChecked = YES;
    assembly->_complete = [complete copy];
    return assembly;
}

- (NSData *)leaves {
    return _leavesChecked ? _gathered : nil;
}

- (BOOL)acceptHashes:(NSData *)hashes index:(uint32_t)index done:(BOOL *)done {
    *done = NO;
    if (hashes.length == 0 || hashes.length % 32 != 0) return NO;
    uint64_t end = (uint64_t)index + hashes.length / 32;
    if (end > _geometry.blocks) return NO;
    if (_leavesChecked) {
        // Sent again at the start of a later session: they must be the ones already checked.
        return [[_gathered subdataWithRange:NSMakeRange((NSUInteger)index * 32, hashes.length)] isEqualToData:hashes];
    }
    if (index == 0) _gathered.length = 0;
    if ((NSUInteger)index * 32 != _gathered.length) return NO;
    [_gathered appendData:hashes];
    if (_gathered.length < (NSUInteger)_geometry.blocks * 32) return YES;
    if (![SZFriendsTreeRootOfLeaves(_geometry, _gathered) isEqualToData:_root]) {
        _gathered.length = 0;
        return NO;
    }
    _leavesChecked = YES;
    *done = YES;
    // An empty file is one empty block: complete as soon as its leaf checks.
    if (_geometry.size == 0 && SZFriendsLeafMatches(0, [NSData data], _gathered)) [_complete insert:0];
    return YES;
}

- (SZFriendsPartOutcome)acceptPart:(NSData *)data offset:(uint64_t)offset block:(uint32_t *)blockOut
                              data:(NSData **)blockData {
    if (!_leavesChecked || data.length == 0) return SZFriendsPartRefused;
    uint64_t end = offset + data.length;
    if (end < offset || end > _geometry.size) return SZFriendsPartRefused;
    uint32_t block = (uint32_t)(offset >> _geometry.shift);
    if ((uint32_t)((end - 1) >> _geometry.shift) != block) return SZFriendsPartRefused;
    if ([_complete contains:block]) return SZFriendsPartLate;
    uint64_t blockOffset = 0;
    NSUInteger blockLength = 0;
    SZFriendsGeometrySpan(_geometry, block, &blockOffset, &blockLength);
    SZFriendsPartialBlock *partial = _partial[@(block)];
    if (partial == nil) {
        if (_partial.count >= SZFriendsBlocksInFlightMax || _partialBytes + blockLength > SZFriendsBytesInFlightMax) {
            return SZFriendsPartRefused;
        }
        partial = [[SZFriendsPartialBlock alloc] init];
        partial.data = [NSMutableData dataWithLength:blockLength];
        partial.covered = [NSMutableArray array];
        _partial[@(block)] = partial;
        _partialBytes += blockLength;
    }
    NSRange range = NSMakeRange((NSUInteger)(offset - blockOffset), data.length);
    // The pieces this part may complete, those not whole before it (§ 3: reported in HAVE's Pieces).
    NSMutableIndexSet *fresh = [NSMutableIndexSet indexSet];
    for (NSUInteger p = range.location / SZFriendsPieceBytes * SZFriendsPieceBytes; p < NSMaxRange(range);
         p += SZFriendsPieceBytes) {
        if (![partial has:NSMakeRange(p, MIN(SZFriendsPieceBytes, blockLength - p))]) [fresh addIndex:p];
    }
    [partial.data replaceBytesInRange:range withBytes:data.bytes];
    [partial cover:range];
    NSUInteger firstPiece = (NSUInteger)(blockOffset / SZFriendsPieceBytes);
    [fresh enumerateIndexesUsingBlock:^(NSUInteger p, BOOL *stop) {
        (void)stop;
        if ([partial has:NSMakeRange(p, MIN(SZFriendsPieceBytes, blockLength - p))]) {
            [self->_arrived addIndex:firstPiece + p / SZFriendsPieceBytes];
        }
    }];
    if (partial.filled < blockLength) return SZFriendsPartPending;
    [_partial removeObjectForKey:@(block)];
    _partialBytes -= blockLength;
    *blockOut = block;
    if (!SZFriendsLeafMatches(block, partial.data, _gathered)) return SZFriendsPartCorrupt;
    [_complete insert:block];
    *blockData = partial.data;
    return SZFriendsPartComplete;
}

- (void)unwritten:(uint32_t)block {
    [_complete remove:block];
}

- (BOOL)markComplete:(uint32_t)block {
    SZFriendsPartialBlock *partial = _partial[@(block)];
    if (partial != nil) {
        _partialBytes -= partial.data.length;
        [_partial removeObjectForKey:@(block)];
    }
    if ([_complete contains:block]) return NO;
    [_complete insert:block];
    return YES;
}

- (void)dropPartial {
    [_partial removeAllObjects];
    _partialBytes = 0;
    [_arrived removeAllIndexes];
}

- (NSUInteger)partialCount {
    return _partial.count;
}

- (NSData *)missingBlocksBesidesPartial {
    SZFriendsBlockSet *wanted = [_complete copy];
    for (NSNumber *block in _partial) [wanted insert:block.unsignedIntValue];
    return wanted.missingRanges;
}

- (NSData *)missingPieces {
    NSMutableIndexSet *pieces = [NSMutableIndexSet indexSet];
    for (NSNumber *key in _partial) {
        uint32_t block = key.unsignedIntValue;
        SZFriendsPartialBlock *partial = _partial[key];
        uint64_t offset = 0;
        NSUInteger length = 0;
        SZFriendsGeometrySpan(_geometry, block, &offset, &length);
        NSUInteger first = (NSUInteger)(offset / SZFriendsPieceBytes);
        for (NSUInteger start = 0; start < length; start += SZFriendsPieceBytes) {
            if (![partial has:NSMakeRange(start, MIN(SZFriendsPieceBytes, length - start))]) {
                [pieces addIndex:first + start / SZFriendsPieceBytes];
            }
        }
    }
    return SZFriendsIndexesAsRanges(pieces);
}

- (NSData *)takeArrivedPieces {
    uint8_t shift = _geometry.shift - 14;
    NSMutableIndexSet *pieces = [NSMutableIndexSet indexSet];
    [_arrived enumerateIndexesUsingBlock:^(NSUInteger p, BOOL *stop) {
        (void)stop;
        if (![self->_complete contains:(uint32_t)(p >> shift)]) [pieces addIndex:p];
    }];
    [_arrived removeAllIndexes];
    return SZFriendsIndexesAsRanges(pieces);
}

@end

@implementation SZFriendsBlockServe {
    NSData *_transferID;
    NSData *_leaves;
    NSMutableIndexSet *_queue;
    NSMutableIndexSet *_inFlight;
    SZFriendsBlockSet *_acknowledged;
    NSData *_currentData;
    uint32_t _currentBlock;
    NSUInteger _currentSent;
    NSUInteger _partBytes;
    uint64_t _windowBytes;
}

- (instancetype)initWithTransferID:(NSData *)transferID
                          geometry:(SZFriendsBlockGeometry)geometry
                            leaves:(NSData *)leaves
                         partBytes:(NSUInteger)partBytes
                       windowBytes:(uint64_t)windowBytes {
    if ((self = [super init])) {
        _transferID = [transferID copy];
        _geometry = geometry;
        _leaves = [leaves copy];
        _queue = [NSMutableIndexSet indexSet];
        _inFlight = [NSMutableIndexSet indexSet];
        _acknowledged = [[SZFriendsBlockSet alloc] initWithCount:geometry.blocks];
        _partBytes = MIN(MAX(partBytes, (NSUInteger)1), SZFriendsPartBytesMax);
        _windowBytes = MIN(MAX(windowBytes, 2ull << geometry.shift), SZFriendsBytesInFlightMax);
    }
    return self;
}

- (NSArray<SZFriendsFrame *> *)hashesFrames {
    return SZFriendsHashesFrames(_transferID, _leaves);
}

- (BOOL)want:(NSData *)ranges {
    if (![_acknowledged fitsRanges:ranges]) return NO;
    const uint32_t *pairs = ranges.bytes;
    for (NSUInteger i = 0; i < ranges.length / 8; i++) {
        for (uint64_t block = pairs[2 * i]; block < (uint64_t)pairs[2 * i] + pairs[2 * i + 1]; block++) {
            [_inFlight removeIndex:(NSUInteger)block];
            [_acknowledged remove:(uint32_t)block];
            if (_currentData == nil || _currentBlock != block) [_queue addIndex:(NSUInteger)block];
        }
    }
    return YES;
}

- (void)wantAll {
    [self want:SZFriendsRange(0, _geometry.blocks)];
}

- (BOOL)have:(NSData *)ranges {
    if (![_acknowledged fitsRanges:ranges]) return NO;
    const uint32_t *pairs = ranges.bytes;
    for (NSUInteger i = 0; i < ranges.length / 8; i++) {
        for (uint64_t block = pairs[2 * i]; block < (uint64_t)pairs[2 * i] + pairs[2 * i + 1]; block++) {
            [_inFlight removeIndex:(NSUInteger)block];
            [_queue removeIndex:(NSUInteger)block];
            [_acknowledged insert:(uint32_t)block];
        }
    }
    return YES;
}

- (BOOL)allAcknowledged {
    return _acknowledged.full;
}

- (BOOL)idle {
    return _queue.count == 0 && _currentData == nil;
}

- (BOOL)awaitingHave {
    return _inFlight.count > 0;
}

- (uint64_t)inFlightBytes {
    __block uint64_t total = 0;
    [_inFlight enumerateIndexesUsingBlock:^(NSUInteger block, BOOL *stop) {
        (void)stop;
        uint64_t offset = 0;
        NSUInteger length = 0;
        SZFriendsGeometrySpan(self->_geometry, (uint32_t)block, &offset, &length);
        total += length;
    }];
    return total;
}

- (BOOL)nextBlock:(uint32_t *)block {
    if (_currentData != nil || _inFlight.count >= SZFriendsBlocksInFlightMax || _queue.count == 0) return NO;
    uint32_t first = (uint32_t)_queue.firstIndex;
    uint64_t offset = 0;
    NSUInteger length = 0;
    SZFriendsGeometrySpan(_geometry, first, &offset, &length);
    if (_inFlight.count > 0 && [self inFlightBytes] + length > _windowBytes) return NO;
    *block = first;
    return YES;
}

- (BOOL)checkBlock:(uint32_t)block data:(NSData *)data {
    uint64_t offset = 0;
    NSUInteger length = 0;
    if (block >= _geometry.blocks) return NO;
    SZFriendsGeometrySpan(_geometry, block, &offset, &length);
    return data.length == length && SZFriendsLeafMatches(block, data, _leaves);
}

- (BOOL)loadBlock:(uint32_t)block data:(NSData *)data {
    uint64_t offset = 0;
    NSUInteger length = 0;
    SZFriendsGeometrySpan(_geometry, block, &offset, &length);
    if (data.length != length || !SZFriendsLeafMatches(block, data, _leaves)) return NO;
    [_queue removeIndex:block];
    [_inFlight addIndex:block];
    _currentBlock = block;
    _currentData = data;
    _currentSent = 0;
    return YES;
}

- (void)setPartBytes:(NSUInteger)partBytes {
    _partBytes = MIN(MAX(partBytes, (NSUInteger)1), SZFriendsPartBytesMax);
}

- (NSUInteger)nextPartLength {
    return _currentData ? MIN(_currentSent + _partBytes, _currentData.length) - _currentSent : 0;
}

- (SZFriendsFrame *)nextPart {
    if (_currentData == nil) return nil;
    uint64_t offset = 0;
    NSUInteger length = 0;
    SZFriendsGeometrySpan(_geometry, _currentBlock, &offset, &length);
    NSUInteger end = MIN(_currentSent + _partBytes, _currentData.length);
    SZFriendsFrame *frame = nil;
    if (end > _currentSent) {
        // A view of the block, not a copy: each copy of a 60 KiB part was a fresh allocation whose pages faulted in,
        // as costly as encrypting it. The block stays alive until the last part using it is encoded.
        NSData *block = _currentData;
        NSData *slice = [[NSData alloc] initWithBytesNoCopy:(void *)((const uint8_t *)block.bytes + _currentSent)
                                                     length:end - _currentSent
                                                deallocator:^(void *bytes, NSUInteger length) {
                                                    (void)bytes, (void)length, (void)block;
                                                }];
        frame = SZFriendsPartFrame(_transferID, offset + _currentSent, slice);
    }
    _currentSent = end;
    if (_currentSent >= _currentData.length) _currentData = nil;
    return frame;
}

@end
