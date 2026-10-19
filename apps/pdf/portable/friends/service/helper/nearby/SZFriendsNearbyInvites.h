// Friend links in Add by ID (friends-links.md; SZFriendsSession.h SZFriendsFieldInviteProof): a request made through
// someone's friend link proves its invite token, bound to the NN session it travels in, and the holder accepts such a
// request at once while the invite is live. Internal to the helper's nearby service.

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsNearbyService (Invites)
// Requester: `frame` (REQUEST_BY_ID for `request`) with the proof of the invite the request presents, if it presents
// one; the frame unchanged otherwise.
- (SZFriendsFrame *)requestFrame:(SZFriendsFrame *)frame
                 presentingInvite:(SZFriendsIDRequestRecord *)request
                   handshakeHash:(NSData *)handshakeHash;
// Holder: the request proves one of our live invites; a one-time invite is used up by it. NO otherwise.
- (BOOL)requestUsesLiveInvite:(SZFriendsFrame *)frame handshakeHash:(NSData *)handshakeHash;
// Requester: our request `token` was made through someone's friend link (its answer then says so).
- (BOOL)requestTokenCameFromLink:(NSData *)token;
@end

NS_ASSUME_NONNULL_END
