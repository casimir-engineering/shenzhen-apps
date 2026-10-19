// The views' helper link (portable/friends/mac/SZFriendsHelperLink.h) as the send tool's way to Friends: intents go
// through the same client library connection the dropdown uses, so a send from the assistant and a send from the
// composer are the same send_message on the same socket.

#import <Foundation/Foundation.h>
#import "mac/SZFriendsHelperLink.h"
#import "SPDFMacFriendsSendProvider.h"

NS_ASSUME_NONNULL_BEGIN

// The helper capability that says outgoing messages' delivery can be watched without opening their conversation
// (PROTOCOL.md § Views, message_status; opening a conversation marks it read). Without it nothing is watched.
FOUNDATION_EXPORT NSString* const SPDFMacFriendsMessageStatusCapability; // "messages.status"

@interface SPDFMacFriendsLinkSender : NSObject <SPDFMacFriendsIntentSender>
- (instancetype)initWithLink:(SZFriendsHelperLink*)link NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
