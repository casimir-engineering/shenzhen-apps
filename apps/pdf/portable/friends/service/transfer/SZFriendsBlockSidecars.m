// Fast transfers' sidecars and the SYNC and AGAIN messages that copy by blocks (SZFriendsTransferBlocks.h), byte for
// byte the Rust core's transfer/sidecar.rs and transfer/copies.rs.

#import "service/transfer/SZFriendsTransferBlocks.h"
#import "service/transfer/SZFriendsBlockBytes.h"

#pragma mark - Sidecars

static const uint8_t SZFriendsMapMagic[8] = {'S', 'Z', 'F', 'R', 'M', 'A', 'P', 1};
static const uint8_t SZFriendsTreeMagic[8] = {'S', 'Z', 'F', 'R', 'T', 'R', 'E', 1};

static NSMutableData *SZFriendsSidecarHeader(const uint8_t magic[8], SZFriendsBlockGeometry geometry, NSData *root,
                                             NSData *digest, BOOL withLeaves) {
    NSMutableData *out = [NSMutableData dataWithLength:SZFriendsSidecarHeaderBytes];
    uint8_t *bytes = out.mutableBytes;
    memcpy(bytes, magic, 8);
    SZFriendsPutU64(bytes + 8, geometry.size);
    bytes[16] = geometry.shift;
    bytes[17] = withLeaves ? 1 : 0;
    SZFriendsPutU32(bytes + 20, geometry.blocks);
    memcpy(bytes + 24, root.bytes, MIN(root.length, (NSUInteger)32));
    memcpy(bytes + 56, digest.bytes, MIN(digest.length, (NSUInteger)32));
    return out;
}

static BOOL SZFriendsSidecarDecodeHeader(const uint8_t magic[8], NSData *data, SZFriendsBlockGeometry *geometry,
                                         NSData **root, NSData **digest, BOOL *withLeaves) {
    const uint8_t *bytes = data.bytes;
    if (data.length < SZFriendsSidecarHeaderBytes || memcmp(bytes, magic, 8) != 0 || (bytes[17] & ~1) != 0 ||
        bytes[18] != 0 || bytes[19] != 0) {
        return NO;
    }
    uint64_t size = 0;
    for (int i = 0; i < 8; i++) size = (size << 8) | bytes[8 + i];
    if (!SZFriendsGeometryMake(size, bytes[16], geometry) || SZFriendsU32(bytes + 20) != geometry->blocks) return NO;
    *root = [data subdataWithRange:NSMakeRange(24, 32)];
    *digest = [data subdataWithRange:NSMakeRange(56, 32)];
    *withLeaves = (bytes[17] & 1) != 0;
    return YES;
}

@implementation SZFriendsBlockMap

- (instancetype)initWithGeometry:(SZFriendsBlockGeometry)geometry root:(NSData *)root digest:(NSData *)digest {
    if ((self = [super init])) {
        _geometry = geometry;
        _root = [root copy];
        _digest = [digest copy];
        _durable = [[SZFriendsBlockSet alloc] initWithCount:geometry.blocks];
    }
    return self;
}

- (NSUInteger)bitmapOffset {
    return SZFriendsSidecarHeaderBytes + 32 * (NSUInteger)_geometry.blocks;
}

- (NSData *)encoded {
    NSMutableData *out = SZFriendsSidecarHeader(SZFriendsMapMagic, _geometry, _root, _digest, _leaves != nil);
    if (_leaves) {
        [out appendData:_leaves];
        [out appendData:_durable.bitmap];
    }
    return out;
}

+ (instancetype)mapWithData:(NSData *)data {
    SZFriendsBlockGeometry geometry;
    NSData *root = nil, *digest = nil;
    BOOL withLeaves = NO;
    if (!SZFriendsSidecarDecodeHeader(SZFriendsMapMagic, data, &geometry, &root, &digest, &withLeaves)) return nil;
    SZFriendsBlockMap *map = [[SZFriendsBlockMap alloc] initWithGeometry:geometry root:root digest:digest];
    if (!withLeaves) return data.length == SZFriendsSidecarHeaderBytes ? map : nil;
    NSUInteger bitmapOffset = map.bitmapOffset;
    if (data.length != bitmapOffset + ((NSUInteger)geometry.blocks + 7) / 8) return nil;
    NSData *leaves = [data subdataWithRange:NSMakeRange(SZFriendsSidecarHeaderBytes, 32 * (NSUInteger)geometry.blocks)];
    if (![SZFriendsTreeRootOfLeaves(geometry, leaves) isEqualToData:root]) return nil;
    SZFriendsBlockSet *durable =
        [SZFriendsBlockSet setWithCount:geometry.blocks
                                 bitmap:[data subdataWithRange:NSMakeRange(bitmapOffset, data.length - bitmapOffset)]];
    if (durable == nil) return nil;
    map.leaves = leaves;
    map.durable = durable;
    return map;
}

@end

NSData *SZFriendsSenderTreeEncode(SZFriendsBlockGeometry geometry, NSData *root, NSData *digest, NSData *leaves) {
    NSMutableData *out = SZFriendsSidecarHeader(SZFriendsTreeMagic, geometry, root, digest, YES);
    [out appendData:leaves];
    return out;
}

NSData *SZFriendsSenderTreeDecode(NSData *data, SZFriendsBlockGeometry *geometry, NSData **root, NSData **digest) {
    BOOL withLeaves = NO;
    if (!SZFriendsSidecarDecodeHeader(SZFriendsTreeMagic, data, geometry, root, digest, &withLeaves) || !withLeaves ||
        data.length != SZFriendsSidecarHeaderBytes + 32 * (NSUInteger)geometry->blocks) {
        return nil;
    }
    NSData *leaves = [data subdataWithRange:NSMakeRange(SZFriendsSidecarHeaderBytes, 32 * (NSUInteger)geometry->blocks)];
    return [SZFriendsTreeRootOfLeaves(*geometry, leaves) isEqualToData:*root] ? leaves : nil;
}

#pragma mark - SYNC and AGAIN block messages

static NSData *_Nullable SZFriendsWantBody(uint8_t shift, NSData *ranges) {
    NSArray<NSData *> *fields = SZFriendsRangesEncode(ranges);
    if (fields.count != 1) return nil;
    NSMutableData *out = [NSMutableData dataWithBytes:&shift length:1];
    [out appendData:fields[0]];
    return out;
}

static NSData *_Nullable SZFriendsFollowBody(NSData *root, uint8_t shift) {
    if (root.length != 32) return nil;
    NSMutableData *out = [root mutableCopy];
    [out appendBytes:&shift length:1];
    return out;
}

static NSData *_Nullable SZFriendsSyncMessage(uint8_t kind, NSString *transferID, NSData *_Nullable body) {
    NSData *id_ = [transferID dataUsingEncoding:NSUTF8StringEncoding];
    if (body == nil || id_.length == 0 || id_.length > 64) return nil;
    uint8_t head[2] = {kind, (uint8_t)id_.length};
    NSMutableData *out = [NSMutableData dataWithBytes:head length:sizeof head];
    [out appendData:id_];
    [out appendData:body];
    return out;
}

static NSData *_Nullable SZFriendsAgainMessage(uint8_t kind, NSString *transferID, NSData *_Nullable body) {
    if (body == nil || transferID.length != 32) return nil;
    NSMutableData *out = [NSMutableData dataWithBytes:&kind length:1];
    for (NSUInteger i = 0; i < 32; i += 2) {
        unichar high = [transferID characterAtIndex:i], low = [transferID characterAtIndex:i + 1];
        int h = isxdigit(high) && !isupper(high) ? digittoint(high) : -1;
        int l = isxdigit(low) && !isupper(low) ? digittoint(low) : -1;
        if (h < 0 || l < 0) return nil;
        uint8_t byte = (uint8_t)(h << 4 | l);
        [out appendBytes:&byte length:1];
    }
    [out appendData:body];
    return out;
}

NSData *SZFriendsSyncWantBlocks(NSString *transferID, uint8_t shift, NSData *ranges) {
    return SZFriendsSyncMessage(7, transferID, SZFriendsWantBody(shift, ranges));
}

NSData *SZFriendsSyncBlocksFollow(NSString *transferID, NSData *root, uint8_t shift) {
    return SZFriendsSyncMessage(8, transferID, SZFriendsFollowBody(root, shift));
}

NSData *SZFriendsAgainWantBlocks(NSString *transferID, uint8_t shift, NSData *ranges) {
    return SZFriendsAgainMessage(4, transferID, SZFriendsWantBody(shift, ranges));
}

NSData *SZFriendsAgainBlocksFollow(NSString *transferID, NSData *root, uint8_t shift) {
    return SZFriendsAgainMessage(5, transferID, SZFriendsFollowBody(root, shift));
}
