// The two sides of a transfer by blocks (ADR 0018 § 2 to 4), sans I/O, as the Rust core's transfer/assembly.rs and
// transfer/serve.rs: the receiver gathers PARTs into blocks and checks each against its leaf the moment it is
// complete; the sender serves the blocks a WANT names, checks each against its own leaf as it reads it, and keeps at
// most a window of blocks sent and not yet in a HAVE.

#import <Foundation/Foundation.h>

#import "service/transfer/SZFriendsTransferBlocks.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SZFriendsPartOutcome) {
    SZFriendsPartRefused = 0, // out of place, before the leaves, or past § 3's limits: close the session
    SZFriendsPartPending,     // stored; the block still misses bytes
    SZFriendsPartComplete,    // the block checked: write `data`, it is complete
    SZFriendsPartCorrupt,     // the block did not match its leaf: dropped, want it again
    SZFriendsPartLate,        // for a block already complete (two lanes, or before a WANT caught up): dropped
};

// The receiver's side. Nothing is taken before the leaves are complete and hash to the offered root; at most 64 blocks
// and 64 MiB are partly received at once.
@interface SZFriendsBlockAssembly : NSObject
- (instancetype)initWithGeometry:(SZFriendsBlockGeometry)geometry root:(NSData *)root NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Resuming from a map whose leaves check: `complete` are the blocks re-read and found intact. Nil when they do not.
+ (nullable instancetype)resumedWithGeometry:(SZFriendsBlockGeometry)geometry
                                        root:(NSData *)root
                                      leaves:(NSData *)leaves
                                    complete:(SZFriendsBlockSet *)complete;
@property(nonatomic, readonly) SZFriendsBlockGeometry geometry;
@property(nonatomic, readonly) NSData *root;
@property(nonatomic, readonly, nullable) NSData *leaves; // once checked
@property(nonatomic, readonly) SZFriendsBlockSet *complete;
// Leaves from one HASHES frame, in order from 0 (a new session may start them again from 0). YES with `done` once all
// are here and hash to the root; NO for leaves out of order, past the count, not matching the root, or differing
// from leaves already checked.
- (BOOL)acceptHashes:(NSData *)hashes index:(uint32_t)index done:(BOOL *)done;
// One PART's data at `offset` in the file. On Complete, `block` and `data` say what to write.
- (SZFriendsPartOutcome)acceptPart:(NSData *)data
                            offset:(uint64_t)offset
                             block:(uint32_t *)block
                              data:(NSData *_Nullable *_Nonnull)blockData;
// A complete block could not be written: wanted again.
- (void)unwritten:(uint32_t)block;
// Drops every partly received block: the session ended, and the next one sends them whole.
- (void)dropPartial;
@end

// The sender's side.
@interface SZFriendsBlockServe : NSObject
// `partBytes` is the route's part size; `windowBytes` what may be sent and not yet in a HAVE (at least two blocks,
// within § 3's 64 MiB).
- (instancetype)initWithTransferID:(NSData *)transferID
                          geometry:(SZFriendsBlockGeometry)geometry
                            leaves:(NSData *)leaves
                         partBytes:(NSUInteger)partBytes
                       windowBytes:(uint64_t)windowBytes NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) SZFriendsBlockGeometry geometry;
- (NSArray<SZFriendsFrame *> *)hashesFrames;
// Blocks the receiver is missing: queued, even if sent before, unless acknowledged since. NO for ranges past the file.
- (BOOL)want:(NSData *)ranges;
- (void)wantAll; // a first acceptance, before any WANT
// Blocks the receiver checked and wrote. NO for ranges past the file.
- (BOOL)have:(NSData *)ranges;
@property(nonatomic, readonly) BOOL allAcknowledged;
@property(nonatomic, readonly) BOOL idle; // nothing queued or being cut into parts
// The block to read next, when no block is being sent and the window has room; NO otherwise.
- (BOOL)nextBlock:(uint32_t *)block;
// That block as read from the snapshot: NO when it does not match its leaf (the snapshot changed).
- (BOOL)loadBlock:(uint32_t)block data:(NSData *)data;
// The data length of the next PART (0 when there is none), without taking it.
@property(nonatomic, readonly) NSUInteger nextPartLength;
// The next PART of the block being sent, or nil.
- (nullable SZFriendsFrame *)nextPart;
// Bytes sent and not yet acknowledged (liveness: a HAVE is due).
@property(nonatomic, readonly) BOOL awaitingHave;
@end

NS_ASSUME_NONNULL_END
