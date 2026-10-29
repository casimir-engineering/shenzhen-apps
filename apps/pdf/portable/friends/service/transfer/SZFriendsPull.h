// One file's blocks fetched from several sources at once (ADR 0018 § 9.6, WP6), sans I/O, as the Rust core's
// transfer/pull.rs: the same file (the same tree root) held by several devices, the friend's or this person's own,
// asked for in parts so that each block crosses one route about once and every holder serves at its own speed. The
// receiver drives WP2's scheduler with each source as a lane: a block given to a lane is asked of that source (WANT
// BLOCKS); a block that completes is credited to the source whose part completed it, which measures each source's
// rate; a copy the scheduler cancels (the block arrived from elsewhere) is reported to that source as a HAVE. A source
// that closes or falls silent gives its blocks back to the others. Ranges are packed (first, count) pairs.

#import <Foundation/Foundation.h>

#import "service/session/SZFriendsSession.h"
#import "service/transfer/SZFriendsTransferBlocks.h"

NS_ASSUME_NONNULL_BEGIN

typedef uint64_t SZFriendsSourceID; // a session with a device that holds the file, as the driver names it

@interface SZFriendsPullAction : NSObject
@property(nonatomic, readonly) BOOL want; // YES: ask for these blocks; NO: a HAVE, they arrived from elsewhere
@property(nonatomic, readonly) SZFriendsSourceID source;
@property(nonatomic, readonly) NSData *ranges;
@end

@interface SZFriendsPull : NSObject
// A pull of the blocks `missing` names (all of them for a new copy; what the map lacks when resuming).
- (instancetype)initWithGeometry:(SZFriendsBlockGeometry)geometry missing:(NSData *)missing now:(double)now
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) SZFriendsBlockGeometry geometry;
// A source is ready to serve (its BLOCKS FOLLOW arrived, and its leaves checked against the root).
- (void)sourceUp:(SZFriendsSourceID)source route:(SZFriendsRouteMethod)route now:(double)now;
// A source's session ended: what it was asked for and did not deliver goes to the others.
- (void)sourceDown:(SZFriendsSourceID)source now:(double)now;
- (void)heard:(SZFriendsSourceID)source now:(double)now;
// A block completed, checked and written; the part that completed it came from `source`.
- (void)arrived:(SZFriendsSourceID)source block:(uint32_t)block now:(double)now;
// A block failed its leaf: asked for again, alone.
- (void)failed:(uint32_t)block now:(double)now;
- (void)tick:(double)now;
- (double)nextTimer; // negative: none
@property(nonatomic, readonly) BOOL done;
// What to send to whom, one WANT and one HAVE per source at most.
- (NSArray<SZFriendsPullAction *> *)takeActions;
@end

NS_ASSUME_NONNULL_END
