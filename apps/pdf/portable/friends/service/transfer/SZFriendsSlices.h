// The sender's side of pieces (ADR 0018 § 3, § 7), as the Rust core's transfer/slices.rs: the scheduler works in
// 256 KiB slices, a block's quarter, so a slow lane takes 1.5 s of Bluetooth at a time; pieces (16 KiB) the receiver
// acknowledged in HAVE are never sent again, so a lost lane or route costs what was in flight. Blocks stay what is read
// and checked against its leaf; a few checked blocks are kept while their slices go out on several lanes. With a peer
// without pieces (capability bit 3), the unit is the whole block, which is all that peer acknowledges.
// Ranges are packed host-order (first, count) pairs, as SZFriendsTransferBlocks.h has them.

#import <Foundation/Foundation.h>

#import "service/session/SZFriendsSession.h"
#import "service/transfer/SZFriendsTransferBlocks.h"

NS_ASSUME_NONNULL_BEGIN

extern const uint8_t SZFriendsSliceShift; // 18: 256 KiB

@interface SZFriendsSliceSend : NSObject
- (instancetype)initWithGeometry:(SZFriendsBlockGeometry)blocks pieces:(BOOL)pieces NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// The scheduler's geometry for this file: its units (slices, or whole blocks).
@property(nonatomic, readonly) SZFriendsBlockGeometry units;
// The units of these blocks (a WANT's or HAVE's Ranges), and those holding these pieces.
- (NSData *)unitsOfBlocks:(NSData *)ranges;
- (NSData *)unitsOfPieces:(NSData *)pieces;
- (uint32_t)blockOfUnit:(uint32_t)unit;
// HAVE's Pieces: acknowledged; the slices now wholly acknowledged, for the scheduler.
- (NSData *)havePieces:(NSData *)pieces;
// HAVE's Ranges: these blocks are complete; their pieces and kept data are no longer needed.
- (void)haveBlocks:(NSData *)ranges;
// WANT: these blocks wanted whole, these pieces again.
- (void)wantBlocks:(NSData *)ranges pieces:(NSData *)pieces;
- (nullable NSData *)cachedBlock:(uint32_t)block;
// A block read and checked against its leaf, kept for its other slices.
- (void)keepBlock:(uint32_t)block data:(NSData *)data;
// The PARTs of `unit` not yet acknowledged, cut at `partBytes`, from its block's kept data.
- (NSArray<SZFriendsFrame *> *)partsOfUnit:(uint32_t)unit transferID:(NSData *)transferID partBytes:(NSUInteger)partBytes;
@end

NS_ASSUME_NONNULL_END
