// A copy by blocks that is not an offer (ADR 0018 § 4), as the Rust core's transfer/block_copy.rs: Get again from a
// friend (AGAIN 4 and 5) and a file copied from another of the person's computers (SYNC 7 and 8). The serving side
// announces its tree (BLOCKS FOLLOW), sends the leaves (HASHES) and the blocks asked for (PART); this side checks each
// block against its leaf, writes it into its staging file, keeps a map beside it (<partial>.map) so the next session,
// or the next start, asks only for what is missing (WANT BLOCKS), and before the file counts checks the whole of it
// against the BLAKE2b digest it is known by: the leaves are only the serving side's word, the digest is the file's.

#import <Foundation/Foundation.h>

#import "service/transfer/SZFriendsTransferBlocks.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SZFriendsCopyPart) {
    SZFriendsCopyPartPending,  // stored; its block still misses bytes
    SZFriendsCopyPartWritten,  // a block checked and was written: reported in the next HAVE
    SZFriendsCopyPartCorrupt,  // a block did not match its leaf: wanted again, alone
    SZFriendsCopyPartComplete, // every block is here and durable: -finish
    SZFriendsCopyPartLate,     // for a block already here
    SZFriendsCopyPartRefused,  // out of place, or before BLOCKS FOLLOW and the leaves
};

@interface SZFriendsBlockCopy : NSObject
// Opens the staging file at `partial` (made when missing) and the map beside it, if an earlier session left one for
// this size and digest; nil when the file cannot be opened.
+ (nullable instancetype)openWithSize:(uint64_t)size digest:(NSData *)digest partial:(NSString *)partial;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSString *partial;
// The shift to ask with: the announced tree's, else this build's for the size.
@property(nonatomic, readonly) uint8_t shift;
// What to ask for (packed (first, count) pairs): every block not yet here, all of them before a tree was announced.
- (NSData *)missing;
// BLOCKS FOLLOW: the serving side's tree. The same tree as before keeps what arrived; another starts over. NO for a
// tree that cannot be this file's.
- (BOOL)followRoot:(NSData *)root shift:(uint8_t)shift;
// Leaves from HASHES: NO for leaves that do not hash to the announced root; `*done` once all are here.
- (BOOL)acceptHashes:(NSData *)hashes index:(uint32_t)index done:(BOOL *)done;
- (SZFriendsCopyPart)acceptPart:(NSData *)data offset:(uint64_t)offset block:(uint32_t *)block;
@property(nonatomic, readonly) BOOL complete;
// The leaves are here and checked against the announced root (this session's HASHES, or the map's).
@property(nonatomic, readonly) BOOL leavesKnown;
// Blocks written and not yet in a HAVE, and those blocks as packed pairs (taken).
@property(nonatomic, readonly) NSUInteger unreportedCount;
- (NSData *)takeHave;
// Bytes of the blocks here, for the row's progress.
@property(nonatomic, readonly) uint64_t receivedBytes;
// The whole file read back: its path when its tree is the announced one and its digest the known one (the map goes),
// nil when it is not (the copy is deleted).
- (nullable NSString *)finish;
// Stops without deleting: what arrived waits for the next copy.
- (void)pause;
@end

NS_ASSUME_NONNULL_END
