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
    // The digest streamed as the blocks arrived, caught up here (after a restart it reads the file); the tree read
    // back on every core. Without a streamed digest the same pass hashes both, as before.
    if (_streamed && _complete && fd >= 0) {
        [_streamed advanceWithFile:fd geometry:_geometry complete:_complete block:0 fresh:nil];
        digest = [_streamed finishWithBlocks:_geometry.blocks];
    }
    _streamed = nil;
    BOOL hashed = _same && fd >= 0 && SZFriendsHashFileTree(fd, _geometry, &leaves, digest ? NULL : &digest);
    _matches = hashed && [SZFriendsTreeRootOfLeaves(_geometry, leaves) isEqualToData:_root] && digest.length == 32 &&
               _digest.length == 32 && sodium_memcmp(digest.bytes, _digest.bytes, 32) == 0;
}
@end

// Blocks queued for the digest at most: a receiver faster than BLAKE2b waits rather than holding the whole file.
static const long SZFriendsDigestBacklog = 32;
// Read back on the store queue for one block at most: blocks that completed out of order. More (a resumed download's
// whole prefix, a previous version's blocks reused) would hold the queue for seconds, past the sessions' silence
// limit; streaming stops instead, and the check hashes the file whole, off the queue.
static const uint64_t SZFriendsDigestCatchUpBytes = 256ull << 20;

@implementation SZFriendsStreamedDigest {
    dispatch_queue_t _queue;
    dispatch_semaphore_t _room;
    crypto_generichash_state *_state; // on the queue only; aligned as libsodium declares it
    uint32_t _next;
    BOOL _stopped;
}
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("szfriends.blocks.digest", DISPATCH_QUEUE_SERIAL);
        _room = dispatch_semaphore_create(SZFriendsDigestBacklog);
        if (posix_memalign((void **)&_state, 64, sizeof *_state) != 0) {
            _state = NULL;
            _stopped = YES;
        } else {
            crypto_generichash_init(_state, NULL, 0, 32);
        }
    }
    return self;
}
- (void)dealloc {
    // A block still queued holds self, so nothing is queued here.
    if (_state) {
        sodium_memzero(_state, sizeof *_state);
        free(_state);
    }
}
- (void)advanceWithFile:(int)fd
               geometry:(SZFriendsBlockGeometry)geometry
               complete:(SZFriendsBlockSet *)complete
                  block:(uint32_t)block
                  fresh:(nullable NSData *)fresh {
    uint64_t read = 0;
    while (!_stopped && _next < geometry.blocks && [complete contains:_next]) {
        NSData *data = fresh && block == _next ? fresh : nil;
        if (data == nil) {
            uint64_t offset = 0;
            NSUInteger length = 0;
            SZFriendsGeometrySpan(geometry, _next, &offset, &length);
            read += length;
            if (fresh && read > SZFriendsDigestCatchUpBytes) {
                _stopped = YES;
                return;
            }
            data = SZFriendsReadAt(fd, offset, length);
        }
        if (data == nil) {
            _stopped = YES;
            return;
        }
        dispatch_semaphore_wait(_room, DISPATCH_TIME_FOREVER);
        dispatch_async(_queue, ^{
            crypto_generichash_update(self->_state, data.bytes, (unsigned long long)data.length);
            dispatch_semaphore_signal(self->_room);
        });
        _next++;
    }
}
- (nullable NSData *)finishWithBlocks:(uint32_t)blocks {
    __block NSData *digest = nil;
    BOOL complete = !_stopped && _next == blocks;
    _stopped = YES;
    dispatch_sync(_queue, ^{
        if (!complete) return;
        uint8_t out[32];
        crypto_generichash_final(self->_state, out, sizeof out);
        digest = [NSData dataWithBytes:out length:sizeof out];
    });
    return digest;
}
@end

@implementation SZFriendsBlockFlush
@end

@implementation SZFriendsBlockDownload
- (instancetype)init {
    if ((self = [super init])) {
        fd = -1;
        mapFD = -1;
        _unsynced = [NSMutableIndexSet indexSet];
        _unreportedComplete = [NSMutableIndexSet indexSet];
        _unreportedDurable = [NSMutableIndexSet indexSet];
        _streamed = [[SZFriendsStreamedDigest alloc] init];
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
