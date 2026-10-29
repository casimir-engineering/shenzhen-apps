// Shared by SZFriendsBlockExchange.m (lanes, offers, receiving, endings) and SZFriendsBlockExchange+Sending.m (our
// files going by blocks): the exchange's state, its lanes' links and queued parts, and the helpers both use.

#import "service/transfer/SZFriendsBlockExchange.h"

#import <time.h>

#import "service/transfer/SZFriendsBlockFlow.h"
#import "service/transfer/SZFriendsScheduler.h"
#import "service/transfer/SZFriendsSlices.h"

NS_ASSUME_NONNULL_BEGIN

// Parts queued in a lane's channel ahead of its link, as for CHUNKs: a message still overtakes them.
static const NSUInteger SZFriendsBulkDepth = 4;

static inline NSString *SZFriendsBlockHex(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

static inline NSData *_Nullable SZFriendsBlockBytes(NSString *hex) {
    if (hex.length != 32) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:16];
    uint8_t *bytes = out.mutableBytes;
    for (NSUInteger i = 0; i < 16; i++) {
        unichar high = [hex characterAtIndex:2 * i], low = [hex characterAtIndex:2 * i + 1];
        if (!isxdigit(high) || !isxdigit(low)) return nil;
        bytes[i] = (uint8_t)(digittoint(high) << 4 | digittoint(low));
    }
    return out;
}

// What each route's PARTs carry (§ 9.8: 16 KiB on Bluetooth).
static inline NSUInteger SZFriendsPartBytesFor(SZFriendsRouteMethod route) {
    return route == SZFriendsRouteMethodBluetooth ? 16 << 10 : SZFriendsPartBytesMax;
}

// A session of the group: how to send on it and how much waits in it.
@interface SZFriendsLaneLink : NSObject
@property(nonatomic) SZFriendsRouteMethod route;
@property(nonatomic, copy) BOOL (^send)(SZFriendsFrame *);
@property(nonatomic, copy, nullable) NSUInteger (^queued)(void);
@end

// One part waiting for its lane's queue.
@interface SZFriendsQueuedPart : NSObject
@property(nonatomic) uint32_t block;
@property(nonatomic, strong) SZFriendsFrame *frame;
@property(nonatomic) BOOL last;
@end

// One of our files going by blocks on this group.
@interface SZFriendsBlockSend : NSObject
@property(nonatomic, strong) SZFriendsBlockServe *serve; // the leaves, the leaf check and what was acknowledged
@property(nonatomic, strong) SZFriendsSliceSend *slices; // the scheduler's units, acknowledged pieces, checked blocks
@property(nonatomic, strong) SZFriendsTransferRecord *record;
@property(nonatomic) SZFriendsTransferKey key;
@property(nonatomic) BOOL resumed; // began on an earlier session
// The friend's helper has the leaves (a HAVE came back): parts may go on lanes, which could otherwise overtake
// HASHES on the head. A WANT proves nothing: the receiver sends one as it accepts, before the leaves arrive.
@property(nonatomic) BOOL lanesOK;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableArray<SZFriendsQueuedPart *> *> *lanes;
@end

// Pieces are reported at least every 256 KiB of parts, after every part on Bluetooth (ADR 0018 § 3).
static const NSUInteger SZFriendsPieceHaveBytes = 256 << 10;

// Packed pairs merged into sorted, disjoint pairs.
static inline NSData *SZFriendsMergedRanges(NSArray<NSData *> *lists) {
    NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
    for (NSData *list in lists) {
        const uint32_t *pairs = list.bytes;
        for (NSUInteger i = 0; i < list.length / 8; i++) [set addIndexesInRange:NSMakeRange(pairs[2 * i], pairs[2 * i + 1])];
    }
    return SZFriendsIndexesAsRanges(set);
}

// A check shorter than this shows nothing: the row goes from the last block straight to saved.
static const double SZFriendsFinishingAfter = 1.0;

@interface SZFriendsBlockExchange () {
    SZFriendsTransfers *_transfers;
    NSString *_conversationID;
    NSMutableDictionary<NSNumber *, SZFriendsLaneLink *> *_links; // live sessions of the group, the head included
    SZFriendsScheduler *_scheduler;
    SZFriendsTransferKey _nextKey;
    NSMutableDictionary<NSString *, SZFriendsBlockSend *> *_senders;
    NSMutableSet<NSString *> *_receivers;
    NSMutableSet<NSString *> *_lateAnswered; // "lane:transfer:block"
    SZFriendsLaneID _control;                // the lane control frames go on: the head, or once it closed, -group.first
    NSMutableDictionary<NSString *, NSNumber *> *_finishing; // transfer id -> when its check began (clock)
    NSMutableDictionary<NSString *, NSNumber *> *_pieceBytes; // transfer id -> part bytes since its last piece HAVE
    NSMutableDictionary<NSString *, NSMutableIndexSet *> *_early; // transfer id -> blocks whose parts came before leaves
}
- (void)changed;
- (BOOL)sendOn:(SZFriendsLaneID)lane frame:(SZFriendsFrame *)frame;
- (BOOL)sendOnHead:(SZFriendsFrame *)frame;
- (void)feedScheduler;
- (SZFriendsScheduler *)scheduler;
- (void)runActions;
- (void)progressed:(NSString *)transferID lane:(SZFriendsLaneID)lane;
- (void)checked:(NSString *)transferID saved:(BOOL)saved error:(nullable NSError *)error;
- (BOOL)hashes:(SZFriendsFrame *)frame transfer:(NSString *)transferID;
- (BOOL)part:(SZFriendsFrame *)frame transfer:(NSString *)transferID lane:(SZFriendsLaneID)lane;
- (void)piecesArrived:(NSString *)transferID lane:(SZFriendsLaneID)lane bytes:(NSUInteger)bytes;
@end

@interface SZFriendsBlockExchange (Sending)
- (nullable SZFriendsBlockSend *)startSending:(NSString *)transferID;
- (BOOL)want:(SZFriendsFrame *)frame transfer:(NSString *)transferID;
- (BOOL)have:(SZFriendsFrame *)frame transfer:(NSString *)transferID;
- (void)assignBlock:(uint32_t)unit transfer:(SZFriendsTransferKey)key lane:(SZFriendsLaneID)lane;
- (double)nextTimer;
@end

NS_ASSUME_NONNULL_END
