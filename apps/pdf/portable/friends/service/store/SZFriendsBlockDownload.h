// Shared by the store's files for fast transfers (SZFriendsBlockDownloads.m receives, SZFriendsBlockCheck.m checks a
// download before it is saved and serves our own offers, SZFriendsBlockFiles.m holds what both use): a download by
// blocks, the check's state, and the file helpers.

#import "service/store/SZFriendsStoreInternal.h"
#import "service/transfer/SZFriendsBlockFlow.h"

NS_ASSUME_NONNULL_BEGIN

static inline NSError *SZFriendsBlockError(SZFriendsStoreError code, NSString *why) {
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

NSData *SZFriendsIndexRanges(NSIndexSet *indexes);
BOOL SZFriendsWriteAll(int fd, const void *bytes, size_t length, uint64_t offset);
NSData *_Nullable SZFriendsReadAt(int fd, uint64_t offset, NSUInteger length);
int SZFriendsOpenPrivate(NSString *path, BOOL create);
BOOL SZFriendsWriteSidecar(NSString *path, NSData *bytes);
SZFriendsBlockSet *SZFriendsRecheck(int fd, SZFriendsBlockGeometry geometry, NSData *leaves, SZFriendsBlockSet *claimed);
uint64_t SZFriendsDurablePrefix(SZFriendsBlockGeometry geometry, SZFriendsBlockSet *durable);

// SZFriendsBlockDownloads.m's, for the check.
@interface SZFriendsTransfers (BlocksInternal)
- (NSString *)blockMapPathForTransfer:(NSString *)transferID;
- (NSString *)senderTreePathForTransfer:(NSString *)transferID;
- (nullable SZFriendsBlockDownload *)openBlocks:(NSString *)transferID
                                   conversation:(NSString *)conversationID
                                             db:(SZFriendsStoreDB *)db
                                          error:(NSError **)error;
- (BOOL)flushBlocks:(SZFriendsBlockDownload *)download transfer:(NSString *)transferID db:(SZFriendsStoreDB *)db
              error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
