// The nearby service's copies by blocks that are not offers (ADR 0018 § 4, § 9.6): Get again and own-device copies
// pulled from every holder at once (SZFriendsNearbyService+Pulls.m) and served to whoever asks
// (SZFriendsNearbyService+Copies.m). Part of SZFriendsNearbyInternal.h, which imports it.

#import <Foundation/Foundation.h>

#import "service/helper/nearby/SZFriendsNearbyService.h"

@class SZFriendsFrame, SZFriendsPeerLink;

NS_ASSUME_NONNULL_BEGIN

// Get again and own-device copies pulled from every holder at once (ADR 0018 § 9.6; SZFriendsNearbyService+Pulls.m).
@interface SZFriendsNearbyService (Pulls)
// Copies on this session are the pull's to make (it negotiated fast transfers).
- (BOOL)pullsOnLink:(SZFriendsPeerLink *)link;
// Looks again, soon, at what to pull and who holds it (coalesced to four times a second).
- (void)schedulePullReconsider;
- (void)reconsiderPulls;
// A holder's answer to a pull's ask: BLOCKS FOLLOW (`root`) or NONE. YES when it was the pull's.
- (BOOL)link:(SZFriendsPeerLink *)link pullAnswer:(NSString *)transferID root:(nullable NSData *)root
       shift:(uint8_t)shift gone:(BOOL)gone;
// HASHES or a PART for the file being pulled: YES when it was.
- (BOOL)link:(SZFriendsPeerLink *)link receivedPullFrame:(SZFriendsFrame *)frame;
- (void)pullLinkClosed:(SZFriendsPeerLink *)link;
// The share of a file the pull has, when it is the one being pulled.
- (BOOL)pullFractionOfTransfer:(NSString *)transferID fraction:(double *)fraction;
@end

// Get again and own-device copies served by blocks (ADR 0018 § 4; SZFriendsNearbyService+Copies.m).
@interface SZFriendsNearbyService (Copies)
// Serves the file at `path` by blocks on the link: BLOCKS FOLLOW (AGAIN 5, or SYNC 8 when `sync`) with its tree at
// `shift`, then the leaves and the blocks in `ranges`. NO when it cannot (the caller answers NONE).
- (BOOL)serveCopyOnLink:(SZFriendsPeerLink *)link
               transfer:(NSString *)transferID
                   path:(NSString *)path
                   size:(uint64_t)size
                  shift:(uint8_t)shift
                 ranges:(NSData *)ranges
                   sync:(BOOL)sync;
// A HAVE for a file served by blocks on this link: YES when it was one.
- (BOOL)link:(SZFriendsPeerLink *)link receivedCopyHave:(SZFriendsFrame *)frame;
// HASHES or a PART of a file this side copies by blocks on this link (Get again, or from another of our devices): YES
// when it was one.
- (BOOL)link:(SZFriendsPeerLink *)link receivedCopyFrame:(SZFriendsFrame *)frame;
@end

NS_ASSUME_NONNULL_END
