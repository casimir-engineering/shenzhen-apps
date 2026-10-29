// The store's downloads by blocks, their check and the file helpers both sides use (SZFriendsBlockDownload.h).

#import <fcntl.h>
#import <sodium.h>
#import <sys/stat.h>
#import <unistd.h>

#import "service/store/SZFriendsBlockDownload.h"

NS_ASSUME_NONNULL_BEGIN

@implementation SZFriendsBlockCheck
- (instancetype)init {
    if ((self = [super init])) fd = -1;
    return self;
}
- (void)dealloc {
    if (fd >= 0) close(fd);
}
- (void)run {
    NSData *leaves = nil, *digest = nil;
    _matches = _same && fd >= 0 && SZFriendsHashFileTree(fd, _geometry, &leaves, &digest) &&
               [SZFriendsTreeRootOfLeaves(_geometry, leaves) isEqualToData:_root] && digest.length == 32 &&
               _digest.length == 32 && sodium_memcmp(digest.bytes, _digest.bytes, 32) == 0;
}
@end

@implementation SZFriendsBlockDownload
- (instancetype)init {
    if ((self = [super init])) {
        fd = -1;
        mapFD = -1;
        _unsynced = [NSMutableIndexSet indexSet];
        _unreportedComplete = [NSMutableIndexSet indexSet];
        _unreportedDurable = [NSMutableIndexSet indexSet];
    }
    return self;
}
- (void)dealloc {
    if (fd >= 0) close(fd);
    if (mapFD >= 0) close(mapFD);
}
@end

NSData *SZFriendsIndexRanges(NSIndexSet *indexes) {
    NSMutableData *out = [NSMutableData data];
    [indexes enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
        (void)stop;
        uint32_t pair[2] = {(uint32_t)range.location, (uint32_t)range.length};
        [out appendBytes:pair length:sizeof pair];
    }];
    return out;
}

BOOL SZFriendsWriteAll(int fd, const void *bytes, size_t length, uint64_t offset) {
    size_t done = 0;
    while (done < length) {
        ssize_t put = pwrite(fd, (const uint8_t *)bytes + done, length - done, (off_t)(offset + done));
        if (put < 0 && errno == EINTR) continue;
        if (put <= 0) return NO;
        done += (size_t)put;
    }
    return YES;
}

NSData *_Nullable SZFriendsReadAt(int fd, uint64_t offset, NSUInteger length) {
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

int SZFriendsOpenPrivate(NSString *path, BOOL create) {
    return open(path.fileSystemRepresentation, O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0), 0600);
}

// Writes a whole sidecar and makes it durable before anything relies on it.
BOOL SZFriendsWriteSidecar(NSString *path, NSData *bytes) {
    int fd = SZFriendsOpenPrivate(path, YES);
    if (fd < 0) return NO;
    BOOL ok = ftruncate(fd, 0) == 0 && SZFriendsWriteAll(fd, bytes.bytes, bytes.length, 0) && SZFriendsMakeDurable(fd);
    close(fd);
    return ok;
}

// The blocks of `claimed` whose bytes in `fd` match their leaves, read and hashed on every core.
SZFriendsBlockSet *SZFriendsRecheck(int fd, SZFriendsBlockGeometry geometry, NSData *leaves,
                                           SZFriendsBlockSet *claimed) {
    SZFriendsBlockSet *intact = [[SZFriendsBlockSet alloc] initWithCount:geometry.blocks];
    NSMutableArray<NSNumber *> *wanted = [NSMutableArray array];
    for (uint32_t block = 0; block < geometry.blocks; block++) {
        if ([claimed contains:block]) [wanted addObject:@(block)];
    }
    NSUInteger count = wanted.count;
    BOOL *ok = calloc(MAX(count, (NSUInteger)1), sizeof(BOOL));
    for (NSUInteger start = 0; start < count; start += 64) {
        NSUInteger n = MIN((NSUInteger)64, count - start);
        dispatch_apply(n, DISPATCH_APPLY_AUTO, ^(size_t i) {
            uint32_t block = wanted[start + i].unsignedIntValue;
            uint64_t offset = 0;
            NSUInteger length = 0;
            SZFriendsGeometrySpan(geometry, block, &offset, &length);
            NSData *data = SZFriendsReadAt(fd, offset, length);
            uint8_t leaf[32];
            if (data == nil) return;
            SZFriendsTreeLeaf(block, data.bytes, data.length, leaf);
            ok[start + i] = sodium_memcmp(leaf, (const uint8_t *)leaves.bytes + (NSUInteger)block * 32, 32) == 0;
        });
    }
    for (NSUInteger i = 0; i < count; i++) {
        if (ok[i]) [intact insert:wanted[i].unsignedIntValue];
    }
    free(ok);
    return intact;
}

uint64_t SZFriendsDurablePrefix(SZFriendsBlockGeometry geometry, SZFriendsBlockSet *durable) {
    uint32_t blocks = durable.prefix;
    return blocks == geometry.blocks ? geometry.size : (uint64_t)blocks << geometry.shift;
}

NS_ASSUME_NONNULL_END
