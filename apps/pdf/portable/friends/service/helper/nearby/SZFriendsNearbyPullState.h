// What a pull (SZFriendsNearbyService+Pulls.m) keeps about the file it copies and each device it asks. Only that file
// imports it.

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
@end

NS_ASSUME_NONNULL_END
