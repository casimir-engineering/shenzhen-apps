// Fast transfers on one friend's group of sessions (ADR 0018, PROTOCOL.md § Fast transfers), as the Rust helper's
// service/blocks.rs and service/lanes.rs: on a session that negotiated them, our OFFER announces the tree, the friend's
// helper takes the file by blocks (OFFER_REPLY with Blocks), we send the leaves (HASHES) and then the blocks it wants
// as PARTs, and it answers with HAVE as blocks check and become durable, and with ACK once the whole file checked and
// was saved. On every new session it asks for exactly what is still missing (WANT).
//
// One exchange per first session ("the head", lane 0). Lanes (more sessions with the same device, ADR 0018 § 6) join
// it: those this side opens, which the scheduler asks for, and those the friend opens, admitted by their token. The
// scheduler (WP2, SZFriendsScheduler) says which lane carries which block; each block is read through its leaf check
// and cut into that lane's parts (16 KiB on Bluetooth), which go out while the lane's queue is shallow. A PART's HAVE
// goes back on the lane that carried it, and the first late part of a block on a lane is answered with a HAVE there
// (§ 3). Control frames (HASHES, WANT, ACK) go on the head, and once it closed, on the lowest live lane (§ 6: the group
// goes on; the interop peer moves the head's files there, the helper ends the group with its first session). With anyone else nothing here runs and the CHUNK flow moves
// the file as before. The nearby service and the interop peer drive it, on the queue the sessions' callbacks run on.

#import <Foundation/Foundation.h>

#import "service/session/SZFriendsSession.h"
#import "service/store/SZFriendsStore.h"
#import "service/store/SZFriendsTransfers.h"
#import "service/transfer/SZFriendsLaneGroup.h"

NS_ASSUME_NONNULL_BEGIN

// The head's lane id within its exchange.
extern const SZFriendsLaneID SZFriendsHeadLane; // 0

@interface SZFriendsBlockExchange : NSObject
// `send` queues a frame on the head session (YES when queued); `queued` says how many bulk frames wait in it (nil:
// never wait). `route` is the head's route.
- (instancetype)initWithTransfers:(SZFriendsTransfers *)transfers
                   conversationID:(NSString *)conversationID
                            route:(SZFriendsRouteMethod)route
                             send:(BOOL (^)(SZFriendsFrame *frame))send
                           queued:(nullable NSUInteger (^)(void))queued NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Something visible changed (a transfer's state or progress).
@property(nonatomic, copy, nullable) void (^onChanged)(void);
// A file received by blocks checked and was saved, and its ACK went out (when the session that received it still
// lives: the driver acknowledges it on the friend's live session otherwise).
@property(nonatomic, copy, nullable) void (^onReceived)(NSString *transferID);
// One of our files started going by blocks: its ACK will say their device checked it.
@property(nonatomic, copy, nullable) void (^onSending)(NSString *transferID);
// A WANT for one of our files: where in it the receiver asks us to start (the first block wanted, in bytes), and
// whether this session resumes a transfer an earlier one began.
@property(nonatomic, copy, nullable) void (^onWanted)(NSString *transferID, uint64_t offset, BOOL resumed);
// Tests' rate cap (SZFriendsHelperTestHooks.chunkBytesPerSecond): YES holds this part back, and the caller pumps
// again once it may; NO counts it as sent.
@property(nonatomic, copy, nullable) BOOL (^pace)(NSUInteger bytes);
// A batch is waiting to become durable: call -flushDue within a second.
@property(nonatomic, copy, nullable) void (^onFlushNeeded)(void);
// The scheduler asks for one more lane on `route` (dial the friend's device there with -reserveLane:) or gives one up.
@property(nonatomic, copy, nullable) void (^onOpenLane)(SZFriendsRouteMethod route);
@property(nonatomic, copy, nullable) void (^onCloseLane)(SZFriendsLaneID lane);
// Monotonic seconds (tests replace it).
@property(nonatomic, copy) double (^clock)(void);
// Both sides set capability bit 3 (SZFriendsSecureChannel.pieces, ADR 0018 § 3): WANT and HAVE carry Pieces, and
// our files go out in 256 KiB slices whose acknowledged pieces are never sent again. Set before the first transfer.
@property(nonatomic) BOOL pieces;
// Whether a direct Wi-Fi lane leaves this device on its Wi-Fi network (AWDL on Macs): YES by default here.
@property(nonatomic) BOOL directWiFiKeepsInternet;
// The queue the exchange is driven on. When set, the check before a received file is saved runs on a queue of its
// own and its result comes back here; nil runs it in place (tests, the interop peer).
@property(nonatomic, strong, nullable) dispatch_queue_t queue;
// Whether a received file's check has run for over a second: its row says "Finishing…" (onChanged says when).
- (BOOL)showsFinishing:(NSString *)transferID;

#pragma mark Lanes

// The head negotiated fast transfers: lanes may join, by tokens from its handshake hash `h`. `initiator`: this side
// dialed the head (it opens odd lane indexes, the friend even ones).
- (void)formGroupWithHandshakeHash:(NSData *)h initiator:(BOOL)initiator;
@property(nonatomic, readonly, nullable) SZFriendsLaneGroup *group;
// Outbound: an index and token for a lane on `route`, reserved for `lane` until -laneUp: or -laneDown:; 0 past the
// limits.
- (uint8_t)reserveLane:(SZFriendsLaneID)lane route:(SZFriendsRouteMethod)route token:(NSData *_Nullable *_Nullable)token;
// Inbound: the lane the friend opened, whose token must name a free index (CLOSE LaneRefused otherwise).
- (SZFriendsLaneRefusal)admitLane:(SZFriendsLaneID)lane token:(NSData *)token route:(SZFriendsRouteMethod)route;
// A reserved or admitted lane went live: parts may go on it.
- (void)laneUp:(SZFriendsLaneID)lane
          send:(BOOL (^)(SZFriendsFrame *frame))send
        queued:(nullable NSUInteger (^)(void))queued;
// A session of the group closed or a lane's dial failed: its blocks go to the others. YES when the group is over (no
// live lane is left, or there is no group and the head closed); NO when it goes on, on -controlLane.
- (BOOL)laneDown:(SZFriendsLaneID)lane;
// Where control frames go: the head, or the lane that took over from it.
@property(nonatomic, readonly) SZFriendsLaneID controlLane;

#pragma mark Offers and replies

// Our OFFER: adds the tree's fields when the snapshot's tree is known (the channel strips them for older peers).
+ (void)addTreeOfTransfer:(SZFriendsTransferRecord *)record
                 toFields:(NSMutableDictionary<NSNumber *, NSData *> *)fields
                transfers:(SZFriendsTransfers *)transfers;
// Their OFFER (already recorded): keeps the tree it announced for when the person accepts.
- (void)noteOffer:(SZFriendsFrame *)offer transferID:(NSString *)transferID;
// Our OFFER_REPLY accepting: takes the file by blocks when its tree is known, unless every byte is here already (the
// same file held here, ADR 0018 § 9.5): then the reply's Offset is the whole file and only DONE follows.
+ (void)addBlocksToReply:(NSMutableDictionary<NSNumber *, NSData *> *)fields
             forTransfer:(NSString *)transferID
               transfers:(SZFriendsTransfers *)transfers;
// A new session and an unfinished download: YES when it resumes by blocks (WANT sent); NO for CHUNK.
- (BOOL)resumeIncoming:(SZFriendsTransferRecord *)record;
// The same on the session that just accepted it by blocks (OFFER_REPLY with Blocks): no WANT, since the sender starts
// with every block on that reply, and a WANT for blocks already in flight would have them sent again.
- (BOOL)beginIncoming:(SZFriendsTransferRecord *)record;
// OFFER_REPLY accepting with Blocks: YES when the file now goes by blocks.
- (BOOL)offerTakenByBlocks:(NSString *)transferID;

#pragma mark Frames and time

// HASHES, WANT, PART or HAVE that came on `lane`: NO when it is unsolicited (close that session as a protocol error).
- (BOOL)handleFrame:(SZFriendsFrame *)frame lane:(SZFriendsLaneID)lane;
- (BOOL)handleFrame:(SZFriendsFrame *)frame; // on -controlLane
// What the exchange holds now, for a stalled transfer's diagnosis: lanes, files received and sent, the scheduler's view.
- (NSDictionary *)debugState;
// Why the last frame was refused (-handleFrame: returned NO), for the driver's log.
@property(nonatomic, readonly, copy, nullable) NSString *lastRefusal;
// A write on `lane` completed (its bulk queue shortened): the lane is moving, and more parts may go.
- (void)written:(SZFriendsLaneID)lane;
// A byte from the friend on `lane` (any frame).
- (void)heard:(SZFriendsLaneID)lane;
// The scheduler's timers (silent lanes): call at -nextTimer, or every second while it carries transfers.
- (void)tick;
@property(nonatomic, readonly) double nextTimer; // negative for none
// The next parts of every file going by blocks, within each lane's queue.
- (void)pump;
// Durability batches that came due; their HAVEs, and the check and ACK of files now complete.
- (void)flushDue;
// The head session ended: what was written becomes durable, partly received blocks are dropped.
- (void)sessionEnded;
// Stops carrying a transfer (cancelled, declined, finished elsewhere).
- (void)endTransfer:(NSString *)transferID;
@property(nonatomic, readonly) BOOL carriesTransfers; // keepalive (ADR 0018 § 7)
@property(nonatomic, readonly) BOOL awaitingPeer;     // watch for silence: a HAVE due, or blocks wanted from the peer
@property(nonatomic, readonly) NSSet<NSString *> *receiving;
@property(nonatomic, readonly) NSSet<NSString *> *sending;
// The scheduler's measured rate on `route` (bytes per second; 0 while nothing is measured or nothing is sent).
- (double)rateOfRoute:(SZFriendsRouteMethod)route;
// Bytes of one of our files the receiver acknowledged on this group (its row's progress); 0 when not sending it.
- (uint64_t)acknowledgedBytesOfTransfer:(NSString *)transferID;
@end

NS_ASSUME_NONNULL_END
