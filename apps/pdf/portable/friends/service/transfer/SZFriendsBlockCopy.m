// A copy by blocks that is not an offer (SZFriendsBlockCopy.h).

#import "service/transfer/SZFriendsBlockCopy.h"

#import <fcntl.h>
#import <sodium.h>
#import <sys/stat.h>
#import <unistd.h>

#import "service/transfer/SZFriendsBlockFlow.h"

// Blocks made durable together.
static const uint64_t SZFriendsCopyBatchBytes = 8ull << 20;

static BOOL SZFriendsCopyWriteAll(int fd, const void *bytes, size_t length, uint64_t offset) {
    size_t done = 0;
    while (done < length) {
        ssize_t wrote = pwrite(fd, (const uint8_t *)bytes + done, length - done, (off_t)(offset + done));
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) return NO;
        done += (size_t)wrote;
    }
    return YES;
}

static NSData *_Nullable SZFriendsCopyReadAt(int fd, uint64_t offset, NSUInteger length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    NSUInteger done = 0;
    while (done < length) {
        ssize_t got = pread(fd, (uint8_t *)data.mutableBytes + done, length - done, (off_t)(offset + done));
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return nil;
        done += (NSUInteger)got;
    }
    return data;
}

static BOOL SZFriendsCopyDurable(int fd) {
    return fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0;
}

// The blocks of `claimed` (or the first `whole` when `claimed` is nil) whose bytes in `fd` match their leaves.
static SZFriendsBlockSet *SZFriendsCopyRecheck(int fd, SZFriendsBlockGeometry geometry, NSData *leaves,
                                               SZFriendsBlockSet *_Nullable claimed, uint32_t whole) {
    SZFriendsBlockSet *intact = [[SZFriendsBlockSet alloc] initWithCount:geometry.blocks];
    for (uint32_t block = 0; block < geometry.blocks; block++) {
        if (claimed ? ![claimed contains:block] : block >= whole) continue;
        uint64_t offset = 0;
        NSUInteger length = 0;
        SZFriendsGeometrySpan(geometry, block, &offset, &length);
        NSData *data = SZFriendsCopyReadAt(fd, offset, length);
        uint8_t leaf[32];
        if (data == nil) continue;
        SZFriendsTreeLeaf(block, data.bytes, data.length, leaf);
        if (memcmp(leaf, (const uint8_t *)leaves.bytes + 32 * (NSUInteger)block, 32) == 0) [intact insert:block];
    }
    return intact;
}

@implementation SZFriendsBlockCopy {
    uint64_t _size;
    NSData *_digest;
    NSString *_mapPath;
    int _fd;
    int _mapFD;
    BOOL _followed;
    SZFriendsBlockGeometry _geometry;
    NSData *_root;
    SZFriendsBlockAssembly *_assembly;
    SZFriendsBlockSet *_durable;
    NSMutableIndexSet *_unsynced;
    uint64_t _unsyncedBytes; // before the leaves: the prefix an earlier copy by offset left
    NSMutableIndexSet *_unreported;
}

+ (nullable instancetype)openWithSize:(uint64_t)size digest:(NSData *)digest partial:(NSString *)partial {
    int fd = open(partial.fileSystemRepresentation, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0 || digest.length != 32) {
        if (fd >= 0) close(fd);
        return nil;
    }
    SZFriendsBlockCopy *copy = [[self alloc] initWithSize:size digest:digest partial:partial fd:fd];
    NSData *bytes = [NSData dataWithContentsOfFile:copy->_mapPath];
    SZFriendsBlockMap *map = bytes ? [SZFriendsBlockMap mapWithData:bytes] : nil;
    if (map != nil && map.geometry.size == size && [map.digest isEqualToData:digest]) {
        [copy adoptMap:map];
    } else {
        unlink(copy->_mapPath.fileSystemRepresentation);
    }
    return copy;
}

- (instancetype)initWithSize:(uint64_t)size digest:(NSData *)digest partial:(NSString *)partial fd:(int)fd {
    if ((self = [super init])) {
        _size = size;
        _digest = [digest copy];
        _partial = [partial copy];
        _mapPath = [partial stringByAppendingString:@".map"];
        _fd = fd;
        _mapFD = -1;
        _unsynced = [NSMutableIndexSet indexSet];
        _unreported = [NSMutableIndexSet indexSet];
        _durable = [[SZFriendsBlockSet alloc] initWithCount:0];
    }
    return self;
}

- (void)dealloc {
    if (_fd >= 0) close(_fd);
    if (_mapFD >= 0) close(_mapFD);
}

- (void)adoptMap:(SZFriendsBlockMap *)map {
    _followed = YES;
    _geometry = map.geometry;
    _root = map.root;
    _durable = [[SZFriendsBlockSet alloc] initWithCount:_geometry.blocks];
    if (map.leaves == nil) {
        _assembly = [[SZFriendsBlockAssembly alloc] initWithGeometry:_geometry root:_root];
        return;
    }
    struct stat info;
    if (fstat(_fd, &info) == 0 && (uint64_t)info.st_size < _size) ftruncate(_fd, (off_t)_size);
    // The map may run ahead of the disk after an unclean exit: what it claims counts once it checks.
    SZFriendsBlockSet *intact = SZFriendsCopyRecheck(_fd, _geometry, map.leaves, map.durable, 0);
    _assembly = [SZFriendsBlockAssembly resumedWithGeometry:_geometry root:_root leaves:map.leaves complete:intact];
    _durable = intact;
    _mapFD = open(_mapPath.fileSystemRepresentation, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
}

- (uint8_t)shift {
    if (_followed) return _geometry.shift;
    SZFriendsBlockGeometry geometry;
    return SZFriendsGeometryForSize(_size, &geometry) ? geometry.shift : 20;
}

- (NSData *)missing {
    if (_assembly.leaves != nil) return _assembly.complete.missingRanges;
    SZFriendsBlockGeometry geometry;
    uint32_t blocks = SZFriendsGeometryMake(_size, self.shift, &geometry) ? geometry.blocks : 1;
    uint32_t pair[2] = {0, blocks};
    return [NSData dataWithBytes:pair length:sizeof pair];
}

- (BOOL)followRoot:(NSData *)root shift:(uint8_t)shift {
    SZFriendsBlockGeometry geometry;
    if (root.length != 32 || !SZFriendsGeometryMake(_size, shift, &geometry)) return NO;
    if (_followed && [_root isEqualToData:root] && _geometry.shift == geometry.shift) return YES;
    struct stat info;
    uint64_t prefix = fstat(_fd, &info) == 0 ? MIN((uint64_t)info.st_size, _size) : 0;
    _followed = YES;
    _geometry = geometry;
    _root = [root copy];
    _assembly = [[SZFriendsBlockAssembly alloc] initWithGeometry:geometry root:_root];
    _durable = [[SZFriendsBlockSet alloc] initWithCount:geometry.blocks];
    if (_mapFD >= 0) close(_mapFD);
    _mapFD = -1;
    unlink(_mapPath.fileSystemRepresentation);
    // A prefix an earlier copy by offset left: its whole blocks count once the leaves arrive and they check.
    _unsyncedBytes = prefix;
    return YES;
}

- (BOOL)acceptHashes:(NSData *)hashes index:(uint32_t)index done:(BOOL *)done {
    *done = NO;
    if (_assembly == nil || ![_assembly acceptHashes:hashes index:index done:done]) return NO;
    if (!*done || _mapFD >= 0) return YES;
    NSData *leaves = _assembly.leaves;
    uint64_t prefix = _unsyncedBytes;
    _unsyncedBytes = 0;
    uint32_t whole = prefix >= _geometry.size ? _geometry.blocks : (uint32_t)(prefix >> _geometry.shift);
    SZFriendsBlockSet *intact = SZFriendsCopyRecheck(_fd, _geometry, leaves, nil, whole);
    if (_geometry.size == 0) [intact insert:0]; // an empty file is one empty block, complete once its leaf checks
    _assembly = [SZFriendsBlockAssembly resumedWithGeometry:_geometry root:_root leaves:leaves complete:intact];
    ftruncate(_fd, (off_t)_size);
    _durable = intact;
    for (uint32_t block = 0; block < _geometry.blocks; block++) {
        if ([intact contains:block]) [_unreported addIndex:block];
    }
    SZFriendsBlockMap *map = [[SZFriendsBlockMap alloc] initWithGeometry:_geometry root:_root digest:_digest];
    map.leaves = leaves;
    map.durable = intact;
    NSData *encoded = map.encoded;
    int mapFD = open(_mapPath.fileSystemRepresentation, O_RDWR | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (mapFD < 0 || !SZFriendsCopyWriteAll(mapFD, encoded.bytes, encoded.length, 0)) {
        if (mapFD >= 0) close(mapFD);
        return NO;
    }
    _mapFD = mapFD;
    return YES;
}

- (SZFriendsCopyPart)acceptPart:(NSData *)data offset:(uint64_t)offset block:(uint32_t *)blockOut {
    if (_assembly == nil) return SZFriendsCopyPartRefused;
    uint32_t block = 0;
    NSData *blockData = nil;
    switch ([_assembly acceptPart:data offset:offset block:&block data:&blockData]) {
    case SZFriendsPartRefused: return SZFriendsCopyPartRefused;
    case SZFriendsPartPending: return SZFriendsCopyPartPending;
    case SZFriendsPartLate: return SZFriendsCopyPartLate;
    case SZFriendsPartCorrupt: *blockOut = block; return SZFriendsCopyPartCorrupt;
    case SZFriendsPartComplete: break;
    }
    *blockOut = block;
    uint64_t at = 0;
    NSUInteger length = 0;
    SZFriendsGeometrySpan(_geometry, block, &at, &length);
    if (!SZFriendsCopyWriteAll(_fd, blockData.bytes, blockData.length, at)) {
        [_assembly unwritten:block];
        return SZFriendsCopyPartRefused;
    }
    [_unsynced addIndex:block];
    _unsyncedBytes += blockData.length;
    [_unreported addIndex:block];
    BOOL complete = _assembly.complete.full;
    if ((complete || _unsyncedBytes >= SZFriendsCopyBatchBytes) && ![self flush]) return SZFriendsCopyPartRefused;
    return complete ? SZFriendsCopyPartComplete : SZFriendsCopyPartWritten;
}

- (BOOL)leavesKnown {
    return _assembly.leaves != nil;
}

- (BOOL)complete {
    return _assembly.leaves != nil && _assembly.complete.full;
}

- (NSUInteger)unreportedCount {
    return _unreported.count;
}

- (NSData *)takeHave {
    NSMutableData *pairs = [NSMutableData data];
    [_unreported enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
        (void)stop;
        uint32_t pair[2] = {(uint32_t)range.location, (uint32_t)range.length};
        [pairs appendBytes:pair length:sizeof pair];
    }];
    [_unreported removeAllIndexes];
    return pairs;
}

- (uint64_t)receivedBytes {
    if (_assembly.leaves == nil) return 0;
    uint64_t bytes = 0;
    for (uint32_t block = 0; block < _geometry.blocks; block++) {
        if (![_assembly.complete contains:block]) continue;
        uint64_t offset = 0;
        NSUInteger length = 0;
        SZFriendsGeometrySpan(_geometry, block, &offset, &length);
        bytes += length;
    }
    return bytes;
}

// A durability batch: the blocks, then the map's bitmap, both flushed.
- (BOOL)flush {
    if (_mapFD < 0 || _unsynced.count == 0) return YES;
    if (!SZFriendsCopyDurable(_fd)) return NO;
    [_unsynced enumerateIndexesUsingBlock:^(NSUInteger block, BOOL *stop) {
        (void)stop;
        [self->_durable insert:(uint32_t)block];
    }];
    [_unsynced removeAllIndexes];
    _unsyncedBytes = 0;
    NSData *bitmap = _durable.bitmap;
    NSUInteger offset = SZFriendsSidecarHeaderBytes + 32 * (NSUInteger)_geometry.blocks;
    return SZFriendsCopyWriteAll(_mapFD, bitmap.bytes, bitmap.length, offset) && SZFriendsCopyDurable(_mapFD);
}

- (nullable NSString *)finish {
    [self flush];
    NSData *leaves = nil, *digest = nil;
    struct stat info;
    BOOL good = _followed && SZFriendsHashFileTree(_fd, _geometry, &leaves, &digest) &&
                [SZFriendsTreeRootOfLeaves(_geometry, leaves) isEqualToData:_root] && digest.length == 32 &&
                sodium_memcmp(digest.bytes, _digest.bytes, 32) == 0 && fstat(_fd, &info) == 0 &&
                (uint64_t)info.st_size == _size;
    unlink(_mapPath.fileSystemRepresentation);
    close(_fd);
    _fd = -1;
    if (_mapFD >= 0) close(_mapFD);
    _mapFD = -1;
    if (good) return _partial;
    unlink(_partial.fileSystemRepresentation);
    return nil;
}

- (void)pause {
    [self flush];
}

@end
