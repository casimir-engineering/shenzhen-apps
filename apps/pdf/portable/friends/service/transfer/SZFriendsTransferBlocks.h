// Fast transfers (ADR 0018, PROTOCOL.md § Fast transfers), the pure parts the Objective-C helper shares with the Rust
// core's szfriends-core/src/transfer/: block geometry, the BLAKE3 hash tree, block sets and ranges, the two sidecar
// formats and the SYNC and AGAIN block messages. No I/O except hashing a file; the store reads and writes, the helper
// moves the frames. fixtures/vectors/transfer/ pins every byte, and tools/objc-vectors writes them from this code.

#import <Foundation/Foundation.h>

#import "service/session/SZFriendsSession.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Geometry (ADR 0018 § 2)

// Blocks of 2^shift bytes, the last one shorter: shift 20 (1 MiB) up to 64 GiB, then the smallest shift up to 24
// (16 MiB) that keeps 65,536 blocks or fewer. An empty file is one empty block, so every file has a tree; a file over
// 1 TiB has no geometry and goes by CHUNK.
extern const uint8_t SZFriendsBlockShiftMin;   // 20
extern const uint8_t SZFriendsBlockShiftMax;   // 24
extern const uint32_t SZFriendsBlocksMax;      // 65,536
extern const NSUInteger SZFriendsLeavesPerHashes; // 2,000 leaves (64,000 bytes) per HASHES frame
extern const NSUInteger SZFriendsRangesPerField;  // 8,000 pairs per Ranges or Durable field
extern const NSUInteger SZFriendsPartBytesMax;    // 61,440 bytes of data per PART
extern const NSUInteger SZFriendsBlocksInFlightMax;   // 64 blocks wanted and partly received per transfer
extern const uint64_t SZFriendsBytesInFlightMax;      // 64 MiB of them

typedef struct {
    uint64_t size;
    uint8_t shift;
    uint32_t blocks;
} SZFriendsBlockGeometry;

// The geometry this build offers a file of `size` bytes; NO over 1 TiB.
BOOL SZFriendsGeometryForSize(uint64_t size, SZFriendsBlockGeometry *geometry);
// An offered geometry: any shift from 20 to 24 that keeps the block count within limits; NO otherwise.
BOOL SZFriendsGeometryMake(uint64_t size, uint8_t shift, SZFriendsBlockGeometry *geometry);
// Block `index`'s offset and length; the last block is shorter, an empty file's only block is empty.
void SZFriendsGeometrySpan(SZFriendsBlockGeometry geometry, uint32_t index, uint64_t *offset, NSUInteger *length);

#pragma mark - The tree (ADR 0018 § 2)

// leaf(i) = BLAKE3("SZFriends leaf v1\0" || u64be(i) || block i)
// node    = BLAKE3("SZFriends node v1\0" || left || right)       a lone last node moves up unchanged
// root    = BLAKE3("SZFriends root v1\0" || u64be(size) || u8(shift) || top node)
extern const uint8_t SZFriendsTreeLeafPrefix[18], SZFriendsTreeNodePrefix[18], SZFriendsTreeRootPrefix[18];

void SZFriendsTreeLeaf(uint32_t index, const void *block, size_t length, uint8_t *out);
void SZFriendsTreeNode(const uint8_t *left, const uint8_t *right, uint8_t *out);
// Every level from the leaves (32 bytes each, concatenated) up to the single top node.
NSArray<NSData *> *SZFriendsTreeLevels(NSData *leaves);
// The top node of the leaves (32 zero bytes for none).
NSData *SZFriendsTreeTop(NSData *leaves);
NSData *SZFriendsTreeRoot(SZFriendsBlockGeometry geometry, NSData *top);
// The root of a complete list of leaves; nil when the count is not the geometry's.
NSData *_Nullable SZFriendsTreeRootOfLeaves(SZFriendsBlockGeometry geometry, NSData *leaves);

// Hashes the first `geometry.size` bytes of `fd` in one read pass: every leaf on every core and, when `digest` is
// given, the BLAKE2b-256 content digest of the same bytes on one more thread. NO on a read error or a short file.
BOOL SZFriendsHashFileTree(int fd, SZFriendsBlockGeometry geometry, NSData *_Nullable *_Nonnull leaves,
                           NSData *_Nullable *_Nullable digest);

#pragma mark - Block sets and ranges (ADR 0018 § 3)

// A set of block indexes below a fixed count. Its bitmap form (bit i % 8 of byte i / 8, most significant first) is
// the block map sidecar's.
@interface SZFriendsBlockSet : NSObject <NSCopying>
- (instancetype)initWithCount:(uint32_t)count NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// From a bitmap of exactly the right length whose padding bits are clear; nil otherwise.
+ (nullable instancetype)setWithCount:(uint32_t)count bitmap:(NSData *)bitmap;
@property(nonatomic, readonly) uint32_t count;   // the blocks the set ranges over
@property(nonatomic, readonly) uint32_t members;
@property(nonatomic, readonly) BOOL full;
- (BOOL)contains:(uint32_t)index;
- (BOOL)insert:(uint32_t)index; // YES when it was not in the set
- (BOOL)remove:(uint32_t)index; // YES when it was
- (void)insertFirst:(uint32_t)first count:(uint32_t)count;
// Whether every range (pairs of u32 first, count) lies below the count.
- (BOOL)fitsRanges:(NSData *)ranges;
- (NSData *)ranges;        // the members as ascending pairs, host order (SZFriendsRangesEncode puts them on the wire)
- (NSData *)missingRanges; // what is not in the set, the same way
- (uint32_t)prefix;        // the first n indexes from 0 that are all in the set
- (NSData *)bitmap;
@end

// Ranges on the wire are pairs of u32be (first, count), ascending, not overlapping, never empty, at most 8,000 per
// field. In memory they are the same pairs in host order, packed as uint32_t[2] in an NSData.
// Decodes a Ranges or Durable value; nil for anything not canonical enough to trust.
NSData *_Nullable SZFriendsRangesDecode(NSData *field);
// Encodes ascending, non-overlapping ranges, merging adjacent ones, into fields of at most 8,000 pairs each.
NSArray<NSData *> *SZFriendsRangesEncode(NSData *ranges);
// One range as an NSData for the calls above.
NSData *SZFriendsRange(uint32_t first, uint32_t count);

#pragma mark - Minor-4 frames (ADR 0018 § 3)

// HASHES frames carrying every leaf in order, 2,000 per frame.
NSArray<SZFriendsFrame *> *SZFriendsHashesFrames(NSData *transferID, NSData *leaves);
// WANT frames naming `missing`; none when nothing is missing.
NSArray<SZFriendsFrame *> *SZFriendsWantFrames(NSData *transferID, NSData *missing);
// HAVE frames for blocks newly complete and newly durable; none when neither changed.
NSArray<SZFriendsFrame *> *SZFriendsHaveFrames(NSData *transferID, NSData *complete, NSData *durable);
SZFriendsFrame *SZFriendsPartFrame(NSData *transferID, uint64_t offset, NSData *data);
// A Ranges or Durable field decoded: empty when the frame lacks it, nil when it is malformed.
NSData *_Nullable SZFriendsFrameRanges(SZFriendsFrame *frame, SZFriendsFieldTag tag);
// The tree an OFFER announces, when it announces one that fits its size.
BOOL SZFriendsOfferedTree(SZFriendsFrame *offer, SZFriendsBlockGeometry *geometry, NSData *_Nullable *_Nonnull root);

#pragma mark - Sidecars (ADR 0018 § 4)

// Both start with the same 88-byte header, integers big-endian:
//   0 magic (8): "SZFRMAP\x01" (receiver, received/.partial/<id>.map) or "SZFRTRE\x01" (sender, outgoing/<id>.tree)
//   8 size (8) | 16 shift (1) | 17 flags (1; bit 0: the leaves follow) | 18 zero (2) | 20 block count (4)
//   24 TreeRoot (32) | 56 the offered BLAKE2b-256 digest (32)
// then the leaves (32 x blocks), and in a map with leaves the durable bitmap (ceil(blocks / 8) bytes).
extern const NSUInteger SZFriendsSidecarHeaderBytes; // 88

@interface SZFriendsBlockMap : NSObject
@property(nonatomic) SZFriendsBlockGeometry geometry;
@property(nonatomic, copy) NSData *root;
@property(nonatomic, copy) NSData *digest;
@property(nonatomic, copy, nullable) NSData *leaves; // nil until HASHES checked against the root
@property(nonatomic, strong) SZFriendsBlockSet *durable;
- (instancetype)initWithGeometry:(SZFriendsBlockGeometry)geometry root:(NSData *)root digest:(NSData *)digest;
- (NSUInteger)bitmapOffset;
- (NSData *)encoded;
// nil for anything malformed, or leaves that do not hash to the root.
+ (nullable instancetype)mapWithData:(NSData *)data;
@end

// The sender's tree: the header and every leaf of its snapshot.
NSData *SZFriendsSenderTreeEncode(SZFriendsBlockGeometry geometry, NSData *root, NSData *digest, NSData *leaves);
// The leaves, checked against the root; nil for anything malformed.
NSData *_Nullable SZFriendsSenderTreeDecode(NSData *data, SZFriendsBlockGeometry *geometry, NSData *_Nullable *_Nonnull root,
                                            NSData *_Nullable *_Nonnull digest);

#pragma mark - SYNC and AGAIN block messages (ADR 0018 § 4)

//   SYNC  7 WANT BLOCKS    id length u8 | id | shift u8 | ranges (u32be first, u32be count)*
//   SYNC  8 BLOCKS FOLLOW  id length u8 | id | root (32) | shift u8
//   AGAIN 4 WANT BLOCKS    id (16) | shift u8 | ranges
//   AGAIN 5 BLOCKS FOLLOW  id (16) | root (32) | shift u8
// The id is the transfer's 32 lowercase hex digits; SYNC carries it as text, AGAIN as its 16 bytes.
NSData *_Nullable SZFriendsSyncWantBlocks(NSString *transferID, uint8_t shift, NSData *ranges);
NSData *_Nullable SZFriendsSyncBlocksFollow(NSString *transferID, NSData *root, uint8_t shift);
NSData *_Nullable SZFriendsAgainWantBlocks(NSString *transferID, uint8_t shift, NSData *ranges);
NSData *_Nullable SZFriendsAgainBlocksFollow(NSString *transferID, NSData *root, uint8_t shift);

NS_ASSUME_NONNULL_END
