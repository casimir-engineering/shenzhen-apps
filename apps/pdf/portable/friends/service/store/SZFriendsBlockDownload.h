// Shared by the store's files for fast transfers (SZFriendsBlockDownloads.m receives, SZFriendsBlockCheck.m checks a
// download before it is saved and serves our own offers, SZFriendsBlockFiles.m holds what both use): a download by
// blocks, the check's state, and the file helpers.

#import "service/store/SZFriendsStoreInternal.h"
#import "service/transfer/SZFriendsBlockFlow.h"

NS_ASSUME_NONNULL_BEGIN

static inline NSError *SZFriendsBlockError(SZFriendsStoreError code, NSString *why) {
    return SZFriendsStoreMakeError(code, why);
}

// The file's BLAKE2b-256 content digest computed while its blocks arrive (ADR 0018 § 5), on a queue of its own, as the
// Rust core's StreamedDigest: blocks go in in order, each as it completes when it is the next one, and later blocks
// that completed earlier read back from the staging file. It covers the bytes as they arrived and were checked against
// their leaves; the tree read back before saving covers the disk, so the two together prove the file on disk has the
// offered digest, without one single-threaded pass over the whole file at the end.
@interface SZFriendsStreamedDigest : NSObject
// On the store queue: feeds every complete block from the next one on; `fresh` is block `block`'s bytes, just
// written. A read that fails stops streaming, and the check then hashes the file whole.
- (void)advanceWithFile:(int)fd
               geometry:(SZFriendsBlockGeometry)geometry
               complete:(SZFriendsBlockSet *)complete
                  block:(uint32_t)block
                  fresh:(nullable NSData *)fresh;
// The digest once all `blocks` went in; nil when streaming stopped or did not reach the end. Waits for the queue.
- (nullable NSData *)finishWithBlocks:(uint32_t)blocks;
@end

// A durability batch running off the store queue (SZFriendsBlockDownloads+Durability.m): the blocks it makes
// durable, the bytes they hold, and once it ran, whether every step succeeded.
@interface SZFriendsBlockFlush : NSObject
@property(nonatomic, copy) NSIndexSet *blocks;
@property(nonatomic) uint64_t bytes;
@property(atomic) BOOL done;
@property(atomic) BOOL ok;
@end

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
@property(nonatomic, strong) SZFriendsStreamedDigest *streamed;
@property(nonatomic, strong, nullable) SZFriendsBlockFlush *flush; // the batch in the background, until settled
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
@property(nonatomic, strong, nullable) SZFriendsStreamedDigest *streamed; // the download's, finished by -run
@property(nonatomic, strong, nullable) SZFriendsBlockSet *complete;       // the blocks it has, all of them
@property(nonatomic) BOOL same; // the descriptor still names the staging file, at the offered size
@property(nonatomic) BOOL matches;
@end

NSData *SZFriendsIndexRanges(NSIndexSet *indexes);
BOOL SZFriendsWriteAll(int fd, const void *bytes, size_t length, uint64_t offset);
NSData *_Nullable SZFriendsReadAt(int fd, uint64_t offset, NSUInteger length);
int SZFriendsOpenPrivate(NSString *path, BOOL create);
BOOL SZFriendsWriteSidecar(NSString *path, NSData *bytes);
SZFriendsBlockSet *SZFriendsRecheck(int fd, SZFriendsBlockGeometry geometry, NSData *leaves, SZFriendsBlockSet *claimed);
uint64_t SZFriendsDurablePrefix(SZFriendsBlockGeometry geometry, SZFriendsBlockSet *durable);

// SZFriendsBlockDownloads.m's and SZFriendsBlockDownloads+Durability.m's, for the check and each other.
@interface SZFriendsTransfers (BlocksInternal)
- (NSString *)blockMapPathForTransfer:(NSString *)transferID;
- (NSString *)senderTreePathForTransfer:(NSString *)transferID;
- (nullable SZFriendsBlockDownload *)openBlocks:(NSString *)transferID
                                   conversation:(NSString *)conversationID
                                             db:(SZFriendsStoreDB *)db
                                          error:(NSError **)error;
- (BOOL)flushBlocks:(SZFriendsBlockDownload *)download transfer:(NSString *)transferID db:(SZFriendsStoreDB *)db
              error:(NSError **)error;
// SZFriendsBlockDownloads+Durability.m's, for the receive path.
- (BOOL)settleBlockFlush:(SZFriendsBlockDownload *)download
                transfer:(NSString *)transferID
                      db:(SZFriendsStoreDB *)db
                    wait:(BOOL)wait;
- (void)flushBlocksInBackground:(SZFriendsBlockDownload *)download transfer:(NSString *)transferID;
@end

NS_ASSUME_NONNULL_END
