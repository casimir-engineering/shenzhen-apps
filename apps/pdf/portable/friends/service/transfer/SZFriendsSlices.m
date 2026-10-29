// The sender's side of pieces (SZFriendsSlices.h).

#import "service/transfer/SZFriendsSlices.h"

#import "service/transfer/SZFriendsBlockFlow.h"

const uint8_t SZFriendsSliceShift = 18;
static const uint8_t SZFriendsPieceShiftBits = 14;
static const NSUInteger SZFriendsSlicesCachedBlocks = 16;

// Unit ranges at `fromShift` as ranges of the units at `toShift` that hold them (`toShift` the larger) or that they
// hold (`toShift` the smaller), within `units` of those.
static NSData *SZFriendsConvertRanges(NSData *ranges, uint8_t fromShift, uint8_t toShift, uint64_t units) {
    NSMutableData *out = [NSMutableData data];
    const uint32_t *pairs = ranges.bytes;
    for (NSUInteger i = 0; i < ranges.length / 8; i++) {
        uint64_t first = pairs[2 * i], count = pairs[2 * i + 1], start, end;
        if (toShift >= fromShift) {
            uint8_t d = toShift - fromShift;
            start = first >> d;
            end = (first + count + (1ull << d) - 1) >> d;
        } else {
            uint8_t d = fromShift - toShift;
            start = first << d;
            end = MIN((first + count) << d, units);
        }
        end = MIN(end, units);
        if (start >= end) continue;
        uint32_t *last = out.length ? (uint32_t *)out.mutableBytes + out.length / 4 - 2 : NULL;
        if (last && (uint64_t)last[0] + last[1] >= start) {
            last[1] = (uint32_t)MAX((uint64_t)last[1], end - last[0]);
        } else {
            uint32_t pair[2] = {(uint32_t)start, (uint32_t)(end - start)};
            [out appendBytes:pair length:sizeof pair];
        }
    }
    return out;
}

@implementation SZFriendsSliceSend {
    SZFriendsBlockGeometry _blocks;
    uint8_t _unit;
    NSMutableIndexSet *_acked;
    NSMutableDictionary<NSNumber *, NSData *> *_cache;
    NSMutableArray<NSNumber *> *_order;
}

- (instancetype)initWithGeometry:(SZFriendsBlockGeometry)blocks pieces:(BOOL)pieces {
    if ((self = [super init])) {
        _blocks = blocks;
        _unit = pieces ? MIN(SZFriendsSliceShift, blocks.shift) : blocks.shift;
        _acked = [NSMutableIndexSet indexSet];
        _cache = [NSMutableDictionary dictionary];
        _order = [NSMutableArray array];
    }
    return self;
}

- (SZFriendsBlockGeometry)units {
    uint64_t count = (_blocks.size + (1ull << _unit) - 1) >> _unit;
    return (SZFriendsBlockGeometry){_blocks.size, _unit, (uint32_t)MAX(count, 1)};
}

- (NSData *)unitsOfBlocks:(NSData *)ranges {
    return SZFriendsConvertRanges(ranges, _blocks.shift, _unit, self.units.blocks);
}

- (NSData *)unitsOfPieces:(NSData *)pieces {
    return SZFriendsConvertRanges(pieces, SZFriendsPieceShiftBits, _unit, self.units.blocks);
}

- (uint32_t)blockOfUnit:(uint32_t)unit {
    return unit >> (_blocks.shift - _unit);
}

- (NSRange)piecesOfSlice:(uint32_t)slice {
    uint64_t per = 1ull << (_unit - SZFriendsPieceShiftBits);
    uint64_t all = MAX((_blocks.size + (1ull << SZFriendsPieceShiftBits) - 1) >> SZFriendsPieceShiftBits, 1);
    uint64_t start = MIN(slice * per, all), end = MIN((slice + 1) * per, all);
    return NSMakeRange((NSUInteger)start, (NSUInteger)(end - start));
}

- (NSData *)havePieces:(NSData *)pieces {
    const uint32_t *pairs = pieces.bytes;
    for (NSUInteger i = 0; i < pieces.length / 8; i++) [_acked addIndexesInRange:NSMakeRange(pairs[2 * i], pairs[2 * i + 1])];
    NSMutableIndexSet *done = [NSMutableIndexSet indexSet];
    NSData *units = [self unitsOfPieces:pieces];
    const uint32_t *unitPairs = units.bytes;
    for (NSUInteger i = 0; i < units.length / 8; i++) {
        for (uint32_t slice = unitPairs[2 * i]; slice < unitPairs[2 * i] + unitPairs[2 * i + 1]; slice++) {
            if ([_acked containsIndexesInRange:[self piecesOfSlice:slice]]) [done addIndex:slice];
        }
    }
    return SZFriendsIndexesAsRanges(done);
}

- (void)haveBlocks:(NSData *)ranges {
    NSData *pieces = SZFriendsConvertRanges(ranges, _blocks.shift, SZFriendsPieceShiftBits, UINT32_MAX);
    const uint32_t *pairs = pieces.bytes;
    for (NSUInteger i = 0; i < pieces.length / 8; i++) {
        [_acked removeIndexesInRange:NSMakeRange(pairs[2 * i], pairs[2 * i + 1])];
    }
    pairs = ranges.bytes;
    for (NSUInteger i = 0; i < ranges.length / 8; i++) {
        for (uint32_t block = pairs[2 * i]; block < pairs[2 * i] + pairs[2 * i + 1]; block++) {
            [_cache removeObjectForKey:@(block)];
        }
    }
}

- (void)wantBlocks:(NSData *)ranges pieces:(NSData *)pieces {
    NSMutableData *all = [SZFriendsConvertRanges(ranges, _blocks.shift, SZFriendsPieceShiftBits, UINT32_MAX) mutableCopy];
    [all appendData:pieces];
    const uint32_t *pairs = all.bytes;
    for (NSUInteger i = 0; i < all.length / 8; i++) {
        [_acked removeIndexesInRange:NSMakeRange(pairs[2 * i], pairs[2 * i + 1])];
    }
}

- (nullable NSData *)cachedBlock:(uint32_t)block {
    return _cache[@(block)];
}

- (void)keepBlock:(uint32_t)block data:(NSData *)data {
    if (_cache[@(block)] == nil) [_order addObject:@(block)];
    _cache[@(block)] = data;
    // Blocks dropped by a HAVE leave stale entries in the order: skipped as they come up.
    while (_cache.count > SZFriendsSlicesCachedBlocks && _order.count > 0) {
        [_cache removeObjectForKey:_order.firstObject];
        [_order removeObjectAtIndex:0];
    }
    if (_order.count > 4 * SZFriendsSlicesCachedBlocks) {
        [_order filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSNumber *b, id bindings) {
                    (void)bindings;
                    return self->_cache[b] != nil;
                }]];
    }
}

- (NSArray<SZFriendsFrame *> *)partsOfUnit:(uint32_t)unit transferID:(NSData *)transferID partBytes:(NSUInteger)partBytes {
    uint32_t block = [self blockOfUnit:unit];
    NSData *data = _cache[@(block)];
    if (data == nil) return @[];
    uint64_t blockOffset = 0;
    NSUInteger blockLength = 0;
    SZFriendsGeometrySpan(_blocks, block, &blockOffset, &blockLength);
    uint64_t piece = 1ull << SZFriendsPieceShiftBits;
    NSMutableArray<NSValue *> *runs = [NSMutableArray array]; // byte ranges in the file
    NSRange pieces = [self piecesOfSlice:unit];
    for (NSUInteger p = pieces.location; p < NSMaxRange(pieces); p++) {
        if ([_acked containsIndex:p]) continue;
        uint64_t start = p * piece, end = MIN((p + 1) * piece, _blocks.size);
        NSRange last = runs.lastObject.rangeValue;
        if (runs.count && NSMaxRange(last) == start) {
            runs[runs.count - 1] = [NSValue valueWithRange:NSMakeRange(last.location, (NSUInteger)(end - last.location))];
        } else {
            [runs addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)(end - start))]];
        }
    }
    NSUInteger size = MIN(MAX(partBytes, (NSUInteger)1), SZFriendsPartBytesMax);
    NSMutableArray<SZFriendsFrame *> *out = [NSMutableArray array];
    for (NSValue *value in runs) {
        NSRange run = value.rangeValue;
        for (uint64_t at = run.location; at < NSMaxRange(run);) {
            uint64_t next = MIN(at + size, (uint64_t)NSMaxRange(run));
            // A view of the kept block, not a copy (a copy per part costs as much as encrypting it); the view holds
            // the block alive until the part is encoded, even once the cache let it go.
            NSData *view = [[NSData alloc] initWithBytesNoCopy:(void *)((const uint8_t *)data.bytes + (at - blockOffset))
                                                        length:(NSUInteger)(next - at)
                                                   deallocator:^(void *bytes, NSUInteger length) {
                                                       (void)bytes, (void)length, (void)data;
                                                   }];
            [out addObject:SZFriendsPartFrame(transferID, at, view)];
            at = next;
        }
    }
    return out;
}

@end
