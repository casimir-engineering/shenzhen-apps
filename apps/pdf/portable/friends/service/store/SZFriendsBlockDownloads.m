// Fast transfers on disk (ADR 0018 § 4 and 5), as the Rust core's store/blocks.rs: the receiver's block map beside
// its staging file, blocks written at their offsets and made durable in batches, the read-back that checks the tree
// and the BLAKE2b digest in one pass before publishing; the sender's tree beside its snapshot. No schema change:
// verified_bytes keeps meaning the contiguous durable prefix, so an older helper that meets the same partial file
// resumes from that prefix, and its recovery sweep deletes both sidecars (no row names them), which this one rebuilds.
//
// Sidecars are named by the transfer id: received/.partial/<id>.map and outgoing/<id>.tree.

#import <fcntl.h>
#import <sodium.h>
#import <sys/stat.h>
#import <unistd.h>

#import "service/store/SZFriendsStoreInternal.h"
#import "service/transfer/SZFriendsBlockFlow.h"

NS_ASSUME_NONNULL_BEGIN

// A durability batch: every 8 MiB or every second of received blocks.
static const uint64_t SZFriendsBlockBatchBytes = 8ull << 20;
static const NSTimeInterval SZFriendsBlockBatchInterval = 1.0;

static NSError *SZFriendsBlockError(SZFriendsStoreError code, NSString *why) {
    return SZFriendsStoreMakeError(code, why);
}

// One download by blocks: its assembly, staging file and map.
@interface SZFriendsBlockDownload : NSObject {
  @public
    int fd;
    int mapFD;
}
@property(nonatomic, strong) SZFriendsBlockAssembly *assembly;
@property(nonatomic, copy) NSData *digest;
@property(nonatomic, copy) NSString *partial;
@property(nonatomic, strong) SZFriendsBlockSet *durable;
@property(nonatomic, strong) NSMutableIndexSet *unsynced;
@property(nonatomic) uint64_t unsyncedBytes;
@property(nonatomic, nullable) NSDate *firstUnsynced;
@property(nonatomic, strong) NSMutableIndexSet *unreportedComplete;
@property(nonatomic, strong) NSMutableIndexSet *unreportedDurable;
@property(nonatomic, weak) id owner; // the session receiving its parts now
@property(nonatomic) BOOL checking;  // read back before it is saved (SZFriendsBlockCheck)
@end

@interface SZFriendsBlockCheck () {
  @public
    int fd; // a duplicate of the download's, so the check reads what was written
}
@property(nonatomic, copy) NSString *transferID;
@property(nonatomic, copy) NSString *conversationID;
@property(nonatomic, weak) SZFriendsBlockDownload *download;
@property(nonatomic) SZFriendsBlockGeometry geometry;
@property(nonatomic, copy) NSData *root;
@property(nonatomic, copy) NSData *digest;
@property(nonatomic) BOOL same; // the descriptor still names the staging file, at the offered size
@property(nonatomic) BOOL matches;
@end

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

static NSData *SZFriendsIndexRanges(NSIndexSet *indexes) {
    NSMutableData *out = [NSMutableData data];
    [indexes enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
        (void)stop;
        uint32_t pair[2] = {(uint32_t)range.location, (uint32_t)range.length};
        [out appendBytes:pair length:sizeof pair];
    }];
    return out;
}

static BOOL SZFriendsWriteAll(int fd, const void *bytes, size_t length, uint64_t offset) {
    size_t done = 0;
    while (done < length) {
        ssize_t put = pwrite(fd, (const uint8_t *)bytes + done, length - done, (off_t)(offset + done));
        if (put < 0 && errno == EINTR) continue;
        if (put <= 0) return NO;
        done += (size_t)put;
    }
    return YES;
}

static NSData *_Nullable SZFriendsReadAt(int fd, uint64_t offset, NSUInteger length) {
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

static int SZFriendsOpenPrivate(NSString *path, BOOL create) {
    return open(path.fileSystemRepresentation, O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0), 0600);
}

// Writes a whole sidecar and makes it durable before anything relies on it.
static BOOL SZFriendsWriteSidecar(NSString *path, NSData *bytes) {
    int fd = SZFriendsOpenPrivate(path, YES);
    if (fd < 0) return NO;
    BOOL ok = ftruncate(fd, 0) == 0 && SZFriendsWriteAll(fd, bytes.bytes, bytes.length, 0) && SZFriendsMakeDurable(fd);
    close(fd);
    return ok;
}

// The blocks of `claimed` whose bytes in `fd` match their leaves, read and hashed on every core.
static SZFriendsBlockSet *SZFriendsRecheck(int fd, SZFriendsBlockGeometry geometry, NSData *leaves,
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

static uint64_t SZFriendsDurablePrefix(SZFriendsBlockGeometry geometry, SZFriendsBlockSet *durable) {
    uint32_t blocks = durable.prefix;
    return blocks == geometry.blocks ? geometry.size : (uint64_t)blocks << geometry.shift;
}

@implementation SZFriendsTransfers (Blocks)

- (NSString *)blockMapPathForTransfer:(NSString *)transferID {
    return [self.receiver.partialDirectory stringByAppendingPathComponent:[transferID stringByAppendingString:@".map"]];
}

- (NSString *)senderTreePathForTransfer:(NSString *)transferID {
    return [self.outgoingDirectoryPath stringByAppendingPathComponent:[transferID stringByAppendingString:@".tree"]];
}

- (NSString *)outgoingDirectoryPath {
    return [self.receiver.partialDirectory.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent
        stringByAppendingPathComponent:@"outgoing"];
}

- (nullable SZFriendsBlockMap *)readMap:(NSString *)transferID {
    NSData *bytes = [NSData dataWithContentsOfFile:[self blockMapPathForTransfer:transferID]];
    return bytes ? [SZFriendsBlockMap mapWithData:bytes] : nil;
}

#pragma mark - Receiving

- (BOOL)recordOfferedTree:(NSString *)transferID
             conversation:(NSString *)conversationID
                 geometry:(SZFriendsBlockGeometry)geometry
                     root:(NSData *)root {
    SZFriendsTransferRecord *record = [self transferWithID:transferID];
    if (record == nil || record.outgoing || ![record.conversationID isEqualToString:conversationID] ||
        record.size != geometry.size || record.state != SZFriendsTransferStateWaitingForYou || root.length != 32) {
        return NO;
    }
    if ([self readMap:transferID] != nil) return YES;
    SZFriendsBlockMap *map = [[SZFriendsBlockMap alloc] initWithGeometry:geometry root:root digest:record.contentDigest];
    return SZFriendsEnsurePrivateDirectory(self.receiver.partialDirectory, NULL) &&
           SZFriendsWriteSidecar([self blockMapPathForTransfer:transferID], map.encoded);
}

- (BOOL)hasOfferedTree:(NSString *)transferID {
    SZFriendsTransferRecord *record = [self transferWithID:transferID];
    SZFriendsBlockMap *map = [self readMap:transferID];
    return record && map && map.geometry.size == record.size && [map.digest isEqualToData:record.contentDigest];
}

// On the store queue: the download's state, opening it when needed. The staging file goes to its full size; every
// block the map claims is re-read and checked before it counts (after an unclean exit the map may run ahead).
- (nullable SZFriendsBlockDownload *)openBlocks:(NSString *)transferID
                                   conversation:(NSString *)conversationID
                                             db:(SZFriendsStoreDB *)db
                                          error:(NSError **)error {
    SZFriendsBlockDownload *download = self.receiver.blockDownloads[transferID];
    if (download) return download;
    SZFriendsTransferRecord *record = SZFriendsTransferRowLoad(db, transferID);
    if (record == nil || record.outgoing || ![record.conversationID isEqualToString:conversationID ?: @""]) {
        SZFriendsFail(error, SZFriendsBlockError(SZFriendsStoreErrorInvalid, @"not this friend's transfer"));
        return nil;
    }
    if (record.state != SZFriendsTransferStateReceiving) {
        SZFriendsFail(error, SZFriendsBlockError(SZFriendsStoreErrorStale, @"no longer receiving"));
        return nil;
    }
    SZFriendsBlockMap *map = [self readMap:transferID];
    if (map == nil || map.geometry.size != record.size || ![map.digest isEqualToData:record.contentDigest]) {
        SZFriendsFail(error, SZFriendsBlockError(SZFriendsStoreErrorInvalid, @"no offered tree"));
        return nil;
    }
    NSString *partial = SZFriendsTransferRowPartialPath(db, transferID);
    int fd = partial ? SZFriendsOpenPrivate(partial, NO) : -1;
    if (fd < 0) {
        SZFriendsFail(error, SZFriendsBlockError(SZFriendsStoreErrorFileMissing, @"no staging file"));
        return nil;
    }
    [self.receiver forgetTransfer:transferID]; // the CHUNK flow's open file, if it had one
    download = [[SZFriendsBlockDownload alloc] init];
    download->fd = fd;
    struct stat info;
    // Preallocated to the size accepted, after the disk-space check acceptance made (ADR 0018 § 8).
    if (fstat(fd, &info) == 0 && (uint64_t)info.st_size < record.size) {
        fstore_t store = {F_ALLOCATECONTIG | F_ALLOCATEALL, F_PEOFPOSMODE, 0,
                          (off_t)(record.size - (uint64_t)info.st_size), 0};
        if (fcntl(fd, F_PREALLOCATE, &store) != 0) {
            store.fst_flags = F_ALLOCATEALL;
            fcntl(fd, F_PREALLOCATE, &store);
        }
        if (ftruncate(fd, (off_t)record.size) != 0) {
            SZFriendsFail(error, SZFriendsBlockError(SZFriendsStoreErrorDiskFull, @"cannot size the staging file"));
            return nil;
        }
    }
    download.digest = record.contentDigest;
    download.partial = partial;
    SZFriendsBlockGeometry geometry = map.geometry;
    if (map.leaves) {
        SZFriendsBlockSet *intact = SZFriendsRecheck(fd, geometry, map.leaves, map.durable);
        download.assembly = [SZFriendsBlockAssembly resumedWithGeometry:geometry root:map.root leaves:map.leaves
                                                               complete:intact];
        download->mapFD = SZFriendsOpenPrivate([self blockMapPathForTransfer:transferID], NO);
        if (download.assembly == nil || download->mapFD < 0) {
            SZFriendsFail(error, SZFriendsBlockError(SZFriendsStoreErrorInvalid, @"map does not check"));
            return nil;
        }
        if (![intact.bitmap isEqualToData:map.durable.bitmap]) {
            NSData *bitmap = intact.bitmap;
            SZFriendsWriteAll(download->mapFD, bitmap.bytes, bitmap.length, map.bitmapOffset);
            SZFriendsMakeDurable(download->mapFD);
        }
        download.durable = intact;
        uint64_t prefix = SZFriendsDurablePrefix(geometry, intact);
        if (prefix != record.verifiedBytes &&
            ![db transaction:^BOOL(NSError **inner) {
                return SZFriendsTransferRowUpdate(db, transferID, @{@"verified_bytes" : @(prefix)}, inner);
            } error:error]) {
            return nil;
        }
    } else {
        // Until the leaves are here, a prefix the CHUNK flow made durable stands (-blockHashes re-checks it).
        download.assembly = [[SZFriendsBlockAssembly alloc] initWithGeometry:geometry root:map.root];
        download.durable = [[SZFriendsBlockSet alloc] initWithCount:geometry.blocks];
    }
    self.receiver.blockDownloads[transferID] = download;
    return download;
}

- (BOOL)beginBlocks:(NSString *)transferID conversation:(NSString *)conversationID error:(NSError **)error {
    if ([self readMap:transferID] == nil) return NO;
    return [self.receiver onWriter:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return [self openBlocks:transferID conversation:conversationID db:db error:inner] != nil;
    } error:error];
}

- (void)dropBlocks:(NSString *)transferID {
    [self.store performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        (void)db;
        [self.receiver.blockDownloads removeObjectForKey:transferID];
    }];
    unlink([self blockMapPathForTransfer:transferID].fileSystemRepresentation);
}

- (BOOL)isReceivingBlocks:(NSString *)transferID {
    __block BOOL open = NO;
    [self.store performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        (void)db;
        open = self.receiver.blockDownloads[transferID] != nil;
    }];
    return open;
}

- (NSData *)blocksMissing:(NSString *)transferID {
    __block NSData *missing = [NSData data];
    [self.store performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        (void)db;
        SZFriendsBlockDownload *download = self.receiver.blockDownloads[transferID];
        if (download) missing = download.assembly.complete.missingRanges;
    }];
    return missing;
}

- (BOOL)acceptBlockHashes:(NSData *)hashes
                    index:(uint32_t)index
              forTransfer:(NSString *)transferID
         fromConversation:(NSString *)conversationID
                    error:(NSError **)error {
    NSString *mapPath = [self blockMapPathForTransfer:transferID];
    return [self.receiver onWriter:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsBlockDownload *download = [self openBlocks:transferID conversation:conversationID db:db error:inner];
        if (download == nil) return NO;
        BOOL done = NO;
        if (![download.assembly acceptHashes:hashes index:index done:&done]) {
            return SZFriendsFail(inner, SZFriendsBlockError(SZFriendsStoreErrorInvalid, @"bad leaves"));
        }
        if (!done || download->mapFD >= 0) return YES;
        SZFriendsBlockGeometry geometry = download.assembly.geometry;
        // A download begun by CHUNK: the whole blocks of its durable prefix count once they check, and are reported
        // at once, so the sender drops them from what it was asked for before the leaves arrived.
        uint64_t verified = SZFriendsTransferRowLoad(db, transferID).verifiedBytes;
        uint32_t whole = verified >= geometry.size ? geometry.blocks : (uint32_t)(verified >> geometry.shift);
        if (whole > 0 && download.durable.members == 0) {
            SZFriendsBlockSet *claimed = [[SZFriendsBlockSet alloc] initWithCount:geometry.blocks];
            [claimed insertFirst:0 count:whole];
            SZFriendsBlockSet *intact = SZFriendsRecheck(download->fd, geometry, download.assembly.leaves, claimed);
            download.assembly = [SZFriendsBlockAssembly resumedWithGeometry:geometry root:download.assembly.root
                                                                     leaves:download.assembly.leaves
                                                                   complete:intact];
            for (uint32_t block = 0; block < geometry.blocks; block++) {
                if (![intact contains:block]) continue;
                [download.unreportedComplete addIndex:block];
                [download.unreportedDurable addIndex:block];
            }
            download.durable = intact;
        }
        SZFriendsBlockMap *map = [[SZFriendsBlockMap alloc] initWithGeometry:geometry root:download.assembly.root
                                                                      digest:download.digest];
        map.leaves = download.assembly.leaves;
        map.durable = download.durable;
        if (!SZFriendsWriteSidecar(mapPath, map.encoded)) {
            return SZFriendsFail(inner, SZFriendsBlockError(SZFriendsStoreErrorDatabase, @"cannot write the map"));
        }
        download->mapFD = SZFriendsOpenPrivate(mapPath, NO);
        if (download->mapFD >= 0 && [self reusePreviousVersion:download transfer:transferID db:db] > 0) {
            [self flushBlocks:download transfer:transferID db:db error:NULL];
        }
        if (download.assembly.complete.full && download.durable.members == 0 && geometry.size == 0) {
            // An empty file: its one block is complete and nothing needs writing.
            [download.durable insert:0];
            [download.unreportedComplete addIndex:0];
            [download.unreportedDurable addIndex:0];
        }
        return download->mapFD >= 0;
    } error:error];
}

// The blocks a new version takes from the version the same friend sent before (ADR 0018 § 9.5): the newest file of
// the same name received from them, still here; a block whose leaf matches at the same position is copied into the
// staging file and counts as arrived, reported in the next HAVE, so the sender sends only changed and new blocks.
- (NSUInteger)reusePreviousVersion:(SZFriendsBlockDownload *)download
                          transfer:(NSString *)transferID
                                db:(SZFriendsStoreDB *)db {
    SZFriendsTransferRecord *record = SZFriendsTransferRowLoad(db, transferID);
    if (record == nil) return 0;
    NSString *previous = SZFriendsTransferRows(db,
                                               @"WHERE conversation_id = ? AND outgoing = 0 AND state = ? AND "
                                               @"file_name = ? AND transfer_id != ? ORDER BY updated_at DESC LIMIT 1",
                                               @[ record.conversationID, @(SZFriendsTransferStateReceived),
                                                  record.fileName, transferID ])
                             .firstObject.receivedPath;
    NSData *leaves = download.assembly.leaves;
    if (previous == nil || leaves == nil) return 0;
    int old = open(previous.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (old < 0) return 0;
    struct stat info;
    uint64_t oldSize = fstat(old, &info) == 0 && S_ISREG(info.st_mode) ? (uint64_t)info.st_size : 0;
    SZFriendsBlockGeometry geometry = download.assembly.geometry;
    NSUInteger taken = 0;
    for (uint32_t block = 0; block < geometry.blocks; block++) {
        uint64_t offset = 0;
        NSUInteger length = 0;
        SZFriendsGeometrySpan(geometry, block, &offset, &length);
        if ([download.assembly.complete contains:block] || length == 0 || offset + length > oldSize) continue;
        NSData *bytes = SZFriendsReadAt(old, offset, length);
        uint8_t leaf[32];
        if (bytes == nil) continue;
        SZFriendsTreeLeaf(block, bytes.bytes, bytes.length, leaf);
        if (memcmp(leaf, (const uint8_t *)leaves.bytes + 32 * (NSUInteger)block, 32) != 0) continue;
        if (!SZFriendsWriteAll(download->fd, bytes.bytes, bytes.length, offset)) continue;
        if (![download.assembly markComplete:block]) continue;
        [download.unsynced addIndex:block];
        download.unsyncedBytes += length;
        if (download.firstUnsynced == nil) download.firstUnsynced = [NSDate date];
        [download.unreportedComplete addIndex:block];
        taken++;
    }
    close(old);
    return taken;
}

- (BOOL)flushBlocks:(SZFriendsBlockDownload *)download transfer:(NSString *)transferID db:(SZFriendsStoreDB *)db
              error:(NSError **)error {
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

- (SZFriendsBlockPartResult)acceptBlockPart:(NSData *)data
                                   atOffset:(uint64_t)offset
                                forTransfer:(NSString *)transferID
                           fromConversation:(NSString *)conversationID
                                      block:(uint32_t *)blockOut
                                      error:(NSError **)error {
    __block SZFriendsBlockPartResult result = SZFriendsBlockPartRefused;
    __block uint32_t block = 0;
    __block NSError *failure = nil;
    [self.receiver onWriter:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsBlockDownload *download = [self openBlocks:transferID conversation:conversationID db:db error:inner];
        if (download == nil) {
            if ((*inner).code == SZFriendsStoreErrorStale) result = SZFriendsBlockPartStale;
            failure = *inner;
            return NO;
        }
        NSData *blockData = nil;
        switch ([download.assembly acceptPart:data offset:offset block:&block data:&blockData]) {
        case SZFriendsPartRefused: return NO;
        case SZFriendsPartPending: result = SZFriendsBlockPartPending; return YES;
        case SZFriendsPartLate: result = SZFriendsBlockPartLate; return YES;
        case SZFriendsPartCorrupt: result = SZFriendsBlockPartCorrupt; return YES;
        case SZFriendsPartComplete: break;
        }
        uint64_t blockOffset = 0;
        NSUInteger length = 0;
        SZFriendsGeometrySpan(download.assembly.geometry, block, &blockOffset, &length);
        if (!SZFriendsWriteAll(download->fd, blockData.bytes, blockData.length, blockOffset)) {
            [download.assembly unwritten:block];
            failure = SZFriendsBlockError(errno == ENOSPC ? SZFriendsStoreErrorDiskFull : SZFriendsStoreErrorDatabase,
                                          @"cannot write the staging file");
            return NO;
        }
        [download.unsynced addIndex:block];
        download.unsyncedBytes += blockData.length;
        if (download.firstUnsynced == nil) download.firstUnsynced = [NSDate date];
        [download.unreportedComplete addIndex:block];
        result = SZFriendsBlockPartWritten;
        if (download.unsyncedBytes >= SZFriendsBlockBatchBytes || download.assembly.complete.full) {
            NSError *flushError = nil;
            if (![self flushBlocks:download transfer:transferID db:db error:&flushError]) failure = flushError;
        }
        return YES;
    } error:NULL];
    if (result == SZFriendsBlockPartRefused && error) {
        *error = failure ?: SZFriendsBlockError(SZFriendsStoreErrorInvalid, @"part out of place");
    }
    *blockOut = block;
    return result;
}

- (NSArray<NSString *> *)flushDueBlocks:(BOOL)all {
    NSMutableArray<NSString *> *flushed = [NSMutableArray array];
    [self.receiver onWriter:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        (void)inner;
        NSDate *now = [NSDate date];
        [self.receiver.blockDownloads enumerateKeysAndObjectsUsingBlock:^(NSString *transferID,
                                                                          SZFriendsBlockDownload *download,
                                                                          BOOL *stop) {
            (void)stop;
            if (download.firstUnsynced == nil) return;
            if (!all && [now timeIntervalSinceDate:download.firstUnsynced] < SZFriendsBlockBatchInterval) return;
            if ([self flushBlocks:download transfer:transferID db:db error:NULL]) [flushed addObject:transferID];
        }];
        return YES;
    } error:NULL];
    return flushed;
}

- (BOOL)blocksPending {
    __block BOOL pending = NO;
    [self.store performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        (void)db;
        for (SZFriendsBlockDownload *download in self.receiver.blockDownloads.allValues) {
            pending |= download.firstUnsynced != nil;
        }
    }];
    return pending;
}

- (void)takeBlockHave:(NSString *)transferID complete:(NSData **)complete durable:(NSData **)durable {
    __block NSData *c = [NSData data], *d = [NSData data];
    [self.store performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        (void)db;
        SZFriendsBlockDownload *download = self.receiver.blockDownloads[transferID];
        if (download == nil) return;
        c = SZFriendsIndexRanges(download.unreportedComplete);
        d = SZFriendsIndexRanges(download.unreportedDurable);
        [download.unreportedComplete removeAllIndexes];
        [download.unreportedDurable removeAllIndexes];
    }];
    *complete = c;
    *durable = d;
}

- (BOOL)blocksAllDurable:(NSString *)transferID {
    __block BOOL full = NO;
    [self.store performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        (void)db;
        SZFriendsBlockDownload *download = self.receiver.blockDownloads[transferID];
        full = download != nil && download.durable.full;
    }];
    return full;
}

- (void)claimBlocks:(NSString *)transferID forSession:(id)session {
    [self.store performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        (void)db;
        ((SZFriendsBlockDownload *)self.receiver.blockDownloads[transferID]).owner = session;
    }];
}

- (void)blocksSessionEnded:(NSArray<NSString *> *)transferIDs session:(id)session {
    [self.store performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        (void)db;
        for (NSString *transferID in transferIDs) {
            SZFriendsBlockDownload *download = self.receiver.blockDownloads[transferID];
            if (download.owner == nil || download.owner == session) [download.assembly dropPartial];
        }
    }];
}

// ADR 0018 § 5: every block durable, the file is read back through the descriptor that wrote it, its tree and BLAKE2b
// digest computed in one pass on every core, and it is published only when both match the offer. Otherwise it is
// deleted and the transfer fails (DigestMismatch), as a CHUNK transfer whose digest differs.
- (BOOL)finishBlockTransfer:(NSString *)transferID fromConversation:(NSString *)conversationID
                      error:(NSError **)error {
    SZFriendsBlockCheck *check = [self beginBlockCheck:transferID fromConversation:conversationID error:error];
    if (check == nil) return NO;
    [check run];
    return [self completeBlockCheck:check error:error];
}

- (nullable SZFriendsBlockCheck *)beginBlockCheck:(NSString *)transferID
                                 fromConversation:(NSString *)conversationID
                                            error:(NSError **)error {
    __block SZFriendsBlockCheck *check = nil;
    BOOL ok = [self.receiver onWriter:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsBlockDownload *download = [self openBlocks:transferID conversation:conversationID db:db error:inner];
        if (download == nil || ![self flushBlocks:download transfer:transferID db:db error:inner]) return NO;
        if (download.checking) {
            return SZFriendsFail(inner, SZFriendsBlockError(SZFriendsStoreErrorStale, @"being checked"));
        }
        if (!download.durable.full) {
            return SZFriendsFail(inner, SZFriendsBlockError(SZFriendsStoreErrorInvalid, @"file is incomplete"));
        }
        SZFriendsTransferRecord *record = SZFriendsTransferRowLoad(db, transferID);
        struct stat opened, named;
        check = [[SZFriendsBlockCheck alloc] init];
        check.same = fstat(download->fd, &opened) == 0 &&
                     lstat(download.partial.fileSystemRepresentation, &named) == 0 && S_ISREG(named.st_mode) &&
                     opened.st_dev == named.st_dev && opened.st_ino == named.st_ino &&
                     (uint64_t)opened.st_size == record.size;
        check->fd = dup(download->fd);
        check.transferID = transferID;
        check.conversationID = conversationID;
        check.download = download;
        check.geometry = download.assembly.geometry;
        check.root = download.assembly.root;
        check.digest = record.contentDigest ?: [NSData data];
        download.checking = YES;
        return YES;
    } error:error];
    return ok ? check : nil;
}

- (BOOL)completeBlockCheck:(SZFriendsBlockCheck *)check error:(NSError **)error {
    __block BOOL mismatch = NO;
    NSString *transferID = check.transferID;
    NSString *mapPath = [self blockMapPathForTransfer:transferID];
    BOOL ok = [self.receiver onWriter:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsBlockDownload *download = self.receiver.blockDownloads[transferID];
        if (download == nil || download != check.download) {
            // Cancelled or declined while it was read: nothing to save.
            return SZFriendsFail(inner, SZFriendsBlockError(SZFriendsStoreErrorStale, @"no longer receiving"));
        }
        download.checking = NO;
        SZFriendsTransferRecord *record = SZFriendsTransferRowLoad(db, transferID);
        NSString *partial = download.partial;
        [self.receiver.blockDownloads removeObjectForKey:transferID]; // closes both descriptors
        unlink(mapPath.fileSystemRepresentation);
        if (check.matches && record != nil) return [self.receiver publish:record from:partial db:db error:inner];
        mismatch = YES;
        return [self.receiver failMismatched:transferID partial:partial db:db error:inner];
    } error:error];
    if (ok && mismatch) {
        return SZFriendsFail(error, SZFriendsBlockError(SZFriendsStoreErrorDigestMismatch, @"digest mismatch"));
    }
    return ok;
}

#pragma mark - Sending

- (BOOL)senderTreeForTransfer:(SZFriendsTransferRecord *)record
                      compute:(BOOL)compute
                     geometry:(SZFriendsBlockGeometry *)geometry
                         root:(NSData *_Nullable *_Nonnull)root
                       leaves:(NSData *_Nullable *_Nonnull)leaves {
    NSString *path = [self senderTreePathForTransfer:record.transferID];
    NSData *bytes = [NSData dataWithContentsOfFile:path];
    NSData *digest = nil;
    if (bytes) {
        NSData *stored = SZFriendsSenderTreeDecode(bytes, geometry, root, &digest);
        if (stored && [digest isEqualToData:record.contentDigest] && geometry->size == record.size) {
            *leaves = stored;
            return YES;
        }
    }
    if (!compute || !SZFriendsGeometryForSize(record.size, geometry) || record.stagedPath == nil) return NO;
    int fd = open(record.stagedPath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return NO;
    struct stat info;
    NSData *hashedLeaves = nil, *hashedDigest = nil;
    BOOL ok = fstat(fd, &info) == 0 && (uint64_t)info.st_size == record.size &&
              SZFriendsHashFileTree(fd, *geometry, &hashedLeaves, &hashedDigest) &&
              [hashedDigest isEqualToData:record.contentDigest];
    close(fd);
    if (!ok) return NO;
    *leaves = hashedLeaves;
    *root = SZFriendsTreeRootOfLeaves(*geometry, hashedLeaves);
    // A cache: a write that fails only costs hashing again.
    SZFriendsWriteSidecar(path, SZFriendsSenderTreeEncode(*geometry, *root, record.contentDigest, hashedLeaves));
    return YES;
}

- (nullable SZFriendsTransferRecord *)peerTookBlocks:(NSString *)transferID
                                    fromConversation:(NSString *)conversationID
                                               first:(BOOL *)first
                                               error:(NSError **)error {
    __block SZFriendsTransferRecord *result = nil;
    __block BOOL accepted = NO;
    BOOL ok = [self.store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsTransferRecord *record = SZFriendsTransferRowLoad(db, transferID);
        if (record == nil || !record.outgoing || ![record.conversationID isEqualToString:conversationID]) {
            return SZFriendsFail(inner, SZFriendsBlockError(SZFriendsStoreErrorInvalid, @"not our offer to them"));
        }
        if (record.state == SZFriendsTransferStateSending) {
            accepted = NO;
        } else if (SZFriendsTransferNextState(YES, record.state, SZFriendsTransferEventAccepted) ==
                   SZFriendsTransferStateSending) {
            accepted = YES;
        } else {
            return SZFriendsFail(inner, SZFriendsBlockError(SZFriendsStoreErrorStale, @"offer is no longer offered"));
        }
        struct stat info;
        if (record.stagedPath == nil || stat(record.stagedPath.fileSystemRepresentation, &info) != 0 ||
            (uint64_t)info.st_size != record.size) {
            SZFriendsTransferRowApplyEvent(db, transferID, SZFriendsTransferEventFailed,
                                           SZFriendsTransferFailureSourceMissing, NULL);
            return SZFriendsFail(inner, SZFriendsBlockError(SZFriendsStoreErrorFileMissing, @"snapshot missing"));
        }
        if (accepted && !SZFriendsTransferRowApplyEvent(db, transferID, SZFriendsTransferEventAccepted, nil, inner)) {
            return NO;
        }
        result = SZFriendsTransferRowLoad(db, transferID);
        return YES;
    } error:error];
    *first = accepted;
    return ok ? result : nil;
}

- (nullable NSData *)readOutgoingBlock:(uint32_t)index
                           ofTransfer:(SZFriendsTransferRecord *)record
                             geometry:(SZFriendsBlockGeometry)geometry {
    if (record.stagedPath == nil) return nil;
    int fd = open(record.stagedPath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    uint64_t offset = 0;
    NSUInteger length = 0;
    SZFriendsGeometrySpan(geometry, index, &offset, &length);
    NSData *data = SZFriendsReadAt(fd, offset, length);
    close(fd);
    return data;
}

@end

NS_ASSUME_NONNULL_END
