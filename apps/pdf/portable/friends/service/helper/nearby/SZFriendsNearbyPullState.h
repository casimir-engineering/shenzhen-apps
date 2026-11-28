// What a pull (SZFriendsNearbyService+Pulls.m) keeps about the file it copies and each device it asks. Only that file
// and its stall watchdog (+PullWatch.m) import it.

#import <Foundation/Foundation.h>

#import "service/helper/nearby/SZFriendsNearbyInternal.h"
#import "service/sync/SZFriendsAgain.h"
#import "service/sync/SZFriendsSync.h"
#import "service/transfer/SZFriendsBlockCopy.h"
#import "service/transfer/SZFriendsPull.h"

NS_ASSUME_NONNULL_BEGIN

// One device a pull asks: by AGAIN (the friend who sent the file) or by SYNC (another of the person's devices).
@interface SZFriendsPullHolder : NSObject
@property(nonatomic, weak) SZFriendsPeerLink *link;
@property(nonatomic) SZFriendsSourceID source;
@property(nonatomic) BOOL sync;
@property(nonatomic) SZFriendsRouteMethod route;
@property(nonatomic) BOOL up;  // its BLOCKS FOLLOW named the copy's tree: it serves
@property(nonatomic) BOOL out; // it answered NONE, or its tree is not the copy's: not asked again in this pull
@property(nonatomic) uint32_t delivered;
@end

@interface SZFriendsPullCopy : NSObject
@property(nonatomic, copy) NSString *transferID;
@property(nonatomic, strong, nullable) SZFriendsAgainFile *again;   // Get again
@property(nonatomic, strong, nullable) SZFriendsSyncFileRecord *own; // a copy from the person's own devices
@property(nonatomic, copy, nullable) NSString *friendConversation;   // the friend who sent it, who may give it too
@property(nonatomic) uint64_t size;
@property(nonatomic, strong) SZFriendsBlockCopy *blockCopy;
@property(nonatomic, strong, nullable) SZFriendsPull *pull;
@property(nonatomic, copy, nullable) NSData *root;
@property(nonatomic) uint8_t shift;
@property(nonatomic, strong) NSMutableArray<SZFriendsPullHolder *> *holders;
@property(nonatomic) uint32_t probes; // blocks asked before the tree was known, one per holder
@property(nonatomic) double startedAt; // monotonic seconds, for the log's rate
@property(nonatomic) double heardAt;   // a holder last sent its tree, HASHES or a PART (the stall watchdog)
@property(nonatomic) double loggedAt;  // the last progress line
@property(nonatomic) uint64_t loggedBytes;
@property(nonatomic) uint32_t stalls;       // the watchdog's rounds since a holder last sent anything
@property(nonatomic) double askedAgainAt;  // when the watchdog last asked the holders again; 0 before
@end

// Monotonic seconds, the pulls' clock.
double SZFriendsPullNow(void);
// The `n`th block of `ranges` (wrapping), so each holder's first ask is a different block.
uint32_t SZFriendsNthBlock(NSData *ranges, uint32_t n);
// A file no holder could give is tried again after this long.
extern const NSTimeInterval SZFriendsPullNotNow;

@interface SZFriendsNearbyService (PullsInternal)
- (nullable SZFriendsPullCopy *)currentPull;
- (void)askHolder:(SZFriendsPullHolder *)holder ranges:(NSData *)ranges;
- (void)stopHoldersOf:(SZFriendsPullCopy *)current; // a HAVE of every block: each holder still serving stops
@end

@interface SZFriendsNearbyService (PullWatch)
// Holders silent for 10, 20 then 40 s are asked again; silent through all three, the pull steps aside (+PullWatch.m).
- (void)unstickPull;
@end

NS_ASSUME_NONNULL_END
