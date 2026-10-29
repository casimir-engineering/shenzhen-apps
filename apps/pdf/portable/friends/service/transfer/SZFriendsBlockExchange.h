// Fast transfers on one session (ADR 0018, PROTOCOL.md § Fast transfers), as the Rust helper's service/blocks.rs: on a
// session that negotiated them, our OFFER announces the tree, the friend's helper takes the file by blocks
// (OFFER_REPLY with Blocks), we send the leaves (HASHES) and then the blocks it wants as PARTs, and it answers with
// HAVE as blocks check and become durable, and with ACK once the whole file checked and was saved. On every new
// session it asks for exactly what is still missing (WANT). With anyone else nothing here runs and the CHUNK flow
// moves the file as before. One exchange per session; the nearby service and the interop peer both drive it, on the
// queue the session's callbacks run on.

#import <Foundation/Foundation.h>

#import "service/session/SZFriendsSession.h"
#import "service/store/SZFriendsStore.h"
#import "service/store/SZFriendsTransfers.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsBlockExchange : NSObject
// `send` queues a frame on the session (YES when queued). `route` sizes parts and the window.
- (instancetype)initWithTransfers:(SZFriendsTransfers *)transfers
                   conversationID:(NSString *)conversationID
                            route:(SZFriendsRouteMethod)route
                             send:(BOOL (^)(SZFriendsFrame *frame))send NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Something visible changed (a transfer's state or progress).
@property(nonatomic, copy, nullable) void (^onChanged)(void);
// A file received by blocks checked and was saved, and its ACK went out.
@property(nonatomic, copy, nullable) void (^onReceived)(NSString *transferID);
// One of our files started going by blocks: its ACK will say their device checked it.
@property(nonatomic, copy, nullable) void (^onSending)(NSString *transferID);
// A WANT for one of our files: where in it the receiver asks us to start (the first block wanted, in bytes), and
// whether this session resumes a transfer an earlier one began.
@property(nonatomic, copy, nullable) void (^onWanted)(NSString *transferID, uint64_t offset, BOOL resumed);
// Tests' rate cap (SZFriendsHelperTestHooks.chunkBytesPerSecond): YES holds this part back, and the caller pumps
// again once it may go; NO counts it as sent.
@property(nonatomic, copy, nullable) BOOL (^pace)(NSUInteger bytes);
// A batch is waiting to become durable: call -flushDue within a second.
@property(nonatomic, copy, nullable) void (^onFlushNeeded)(void);

// Our OFFER: adds the tree's fields when the snapshot's tree is known (the channel strips them for older peers).
+ (void)addTreeOfTransfer:(SZFriendsTransferRecord *)record
                 toFields:(NSMutableDictionary<NSNumber *, NSData *> *)fields
                transfers:(SZFriendsTransfers *)transfers;
// Their OFFER (already recorded): keeps the tree it announced for when the person accepts.
- (void)noteOffer:(SZFriendsFrame *)offer transferID:(NSString *)transferID;
// Our OFFER_REPLY accepting: takes the file by blocks when its tree is known.
+ (void)addBlocksToReply:(NSMutableDictionary<NSNumber *, NSData *> *)fields
             forTransfer:(NSString *)transferID
               transfers:(SZFriendsTransfers *)transfers;
// A new session and an unfinished download: YES when it resumes by blocks (WANT sent); NO for CHUNK.
- (BOOL)resumeIncoming:(SZFriendsTransferRecord *)record;
// OFFER_REPLY accepting with Blocks: YES when the file now goes by blocks on this session.
- (BOOL)offerTakenByBlocks:(NSString *)transferID;
// HASHES, WANT, PART or HAVE: NO when it is unsolicited (close the session with a protocol error).
- (BOOL)handleFrame:(SZFriendsFrame *)frame;
// The next parts of every file going by blocks, within each one's window.
- (void)pump;
// Durability batches that came due; their HAVEs, and the check and ACK of files now complete.
- (void)flushDue;
// The session ended: what was written becomes durable, partly received blocks are dropped.
- (void)sessionEnded;
// Stops carrying a transfer (cancelled, declined, finished elsewhere).
- (void)endTransfer:(NSString *)transferID;
@property(nonatomic, readonly) BOOL carriesTransfers; // keepalive (ADR 0018 § 7)
// Watch for silence: a HAVE is due for blocks sent, or blocks are wanted from the peer.
@property(nonatomic, readonly) BOOL awaitingPeer;
@property(nonatomic, readonly) NSSet<NSString *> *receiving;
@property(nonatomic, readonly) NSSet<NSString *> *sending;
@end

NS_ASSUME_NONNULL_END
