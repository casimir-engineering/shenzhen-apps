// Durability batches for the block downloads (SZFriendsBlockDownloads.m receives the blocks): made durable in place,
// or off the store queue while parts keep arriving, and counted once settled.

#import <unistd.h>

#import "service/store/SZFriendsBlockDownload.h"

NS_ASSUME_NONNULL_BEGIN

@implementation SZFriendsTransfers (BlockDurability)

// Where durability batches run while parts keep arriving: one at a time, for every download.
static dispatch_queue_t SZFriendsBlockFlushQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("szfriends.blocks.durable", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// On the store queue: a batch of blocks already durable counts, and the prefix is committed for older helpers.
- (BOOL)blocksMadeDurable:(NSIndexSet *)blocks
                 download:(SZFriendsBlockDownload *)download
                 transfer:(NSString *)transferID
                       db:(SZFriendsStoreDB *)db
                    error:(NSError **)error {
    [blocks enumerateIndexesUsingBlock:^(NSUInteger block, BOOL *stop) {
        (void)stop;
        [download.durable insert:(uint32_t)block];
    }];
    [download.unreportedDurable addIndexes:blocks];
    uint64_t prefix = SZFriendsDurablePrefix(download.assembly.geometry, download.durable);
    return [db transaction:^BOOL(NSError **inner) {
        return SZFriendsTransferRowUpdate(db, transferID, @{@"verified_bytes" : @(prefix)}, inner);
    } error:error];
}

// On the store queue: the background batch, once it ran (waiting for it when `wait`), counts or goes back to unsynced.
// YES when there is none left.
- (BOOL)settleBlockFlush:(SZFriendsBlockDownload *)download
                transfer:(NSString *)transferID
                      db:(SZFriendsStoreDB *)db
                    wait:(BOOL)wait {
    SZFriendsBlockFlush *flush = download.flush;
    if (flush == nil) return YES;
    if (!flush.done) {
        if (!wait) return NO;
        dispatch_sync(SZFriendsBlockFlushQueue(), ^{
        });
    }
    download.flush = nil;
    if (flush.ok) {
        [self blocksMadeDurable:flush.blocks download:download transfer:transferID db:db error:NULL];
    } else {
        [download.unsynced addIndexes:flush.blocks];
        download.unsyncedBytes += flush.bytes;
        if (download.firstUnsynced == nil) download.firstUnsynced = [NSDate date];
    }
    return YES;
}

// A durability batch off the store queue, so the parts arriving meanwhile are not held up by the disk: the same steps
// as -flushBlocks: on duplicates of both descriptors, against a bitmap that claims only this batch's blocks beyond
// those already durable. It counts once settled; until then the blocks are neither unsynced nor durable.
- (void)flushBlocksInBackground:(SZFriendsBlockDownload *)download transfer:(NSString *)transferID {
    if (download.flush != nil || download.unsynced.count == 0 || download->mapFD < 0) return;
    int fd = dup(download->fd), mapFD = dup(download->mapFD);
    if (fd < 0 || mapFD < 0) {
        if (fd >= 0) close(fd);
        if (mapFD >= 0) close(mapFD);
        return; // the next batch flushes in place
    }
    SZFriendsBlockFlush *flush = [[SZFriendsBlockFlush alloc] init];
    flush.blocks = download.unsynced;
    flush.bytes = download.unsyncedBytes;
    SZFriendsBlockSet *claimed = [download.durable copy];
    [flush.blocks enumerateIndexesUsingBlock:^(NSUInteger block, BOOL *stop) {
        (void)stop;
        [claimed insert:(uint32_t)block];
    }];
    NSData *bitmap = claimed.bitmap;
    NSUInteger bitmapOffset = SZFriendsSidecarHeaderBytes + 32 * (NSUInteger)download.assembly.geometry.blocks;
    download.flush = flush;
    [download.unsynced removeAllIndexes];
    download.unsyncedBytes = 0;
    download.firstUnsynced = nil;
    __weak SZFriendsTransfers *weakSelf = self;
    dispatch_async(SZFriendsBlockFlushQueue(), ^{
        flush.ok = SZFriendsOrderWrites(fd) && SZFriendsWriteAll(mapFD, bitmap.bytes, bitmap.length, bitmapOffset) &&
                   SZFriendsMakeDurable(mapFD);
        close(fd);
        close(mapFD);
        flush.done = YES;
        // Settled on the store queue from elsewhere: a flush in place waits on this queue from the store queue.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            SZFriendsTransfers *strongSelf = weakSelf;
            [strongSelf.store performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
                SZFriendsBlockDownload *current = strongSelf.receiver.blockDownloads[transferID];
                if (db != nil && current == download && current.flush == flush) {
                    [strongSelf settleBlockFlush:current transfer:transferID db:db wait:NO];
                }
            }];
        });
    });
}

- (BOOL)flushBlocks:(SZFriendsBlockDownload *)download transfer:(NSString *)transferID db:(SZFriendsStoreDB *)db
              error:(NSError **)error {
    [self settleBlockFlush:download transfer:transferID db:db wait:YES];
    if (download.unsynced.count == 0 || download->mapFD < 0) return YES;
    // The blocks ordered before the bitmap that claims them, then both durable with one full flush; then the prefix
    // committed for older helpers.
    if (!SZFriendsOrderWrites(download->fd)) {
        return SZFriendsFail(error, SZFriendsBlockError(SZFriendsStoreErrorDatabase, @"fsync failed"));
    }
    [download.unsynced enumerateIndexesUsingBlock:^(NSUInteger block, BOOL *stop) {
        (void)stop;
        [download.durable insert:(uint32_t)block];
    }];
    SZFriendsBlockGeometry geometry = download.assembly.geometry;
    NSData *bitmap = download.durable.bitmap;
    NSUInteger bitmapOffset = SZFriendsSidecarHeaderBytes + 32 * (NSUInteger)geometry.blocks;
    if (!SZFriendsWriteAll(download->mapFD, bitmap.bytes, bitmap.length, bitmapOffset) ||
        !SZFriendsMakeDurable(download->mapFD)) {
        return SZFriendsFail(error, SZFriendsBlockError(SZFriendsStoreErrorDatabase, @"cannot write the map"));
    }
    [download.unreportedDurable addIndexes:download.unsynced];
    [download.unsynced removeAllIndexes];
    download.unsyncedBytes = 0;
    download.firstUnsynced = nil;
    uint64_t prefix = SZFriendsDurablePrefix(geometry, download.durable);
    return [db transaction:^BOOL(NSError **inner) {
        return SZFriendsTransferRowUpdate(db, transferID, @{@"verified_bytes" : @(prefix)}, inner);
    } error:error];
}

@end

NS_ASSUME_NONNULL_END
