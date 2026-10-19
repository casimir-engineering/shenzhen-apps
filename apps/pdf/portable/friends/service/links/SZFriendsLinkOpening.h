// The links area's opener-side and serving pieces that need the store: the sink that files a received link's file
// in the sender's conversation. Internal to the area; the helper uses SZFriendsLinks.h.

#import "service/links/SZFriendsLinksInternal.h"
#import "service/store/SZFriendsStore.h"
#import "service/store/SZFriendsStoreLinks.h"
#import "service/store/SZFriendsTransfers.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const SZFriendsLinkSenderDomain; // "SZFriends link sender v1": the metadata's "from" signature
// The history event after a link's file arrived; its argument "file" names it ("Sent you {file} through a link").
extern NSString *const SZFriendsEventReceivedThroughLink; // "received_through_link"

// receive_link's sink: the metadata must be signed by the sender's identity key (not this person's own, not someone
// blocked); the sender gets a row of their own if they have none (a link contact, relation Removed until they are
// added); the file is an accepted incoming transfer from the first byte, published through the transfer code's
// digest check, and the history then says it came through a link.
@interface SZFriendsLinkReceiver : NSObject <SZFriendsLinkSink>
- (instancetype)initWithStore:(SZFriendsStore *)store
                    transfers:(SZFriendsTransfers *)transfers
                  ownIdentity:(NSData *)ownIdentityKey
                       linkID:(NSData *)linkID NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, copy, nullable) void (^onStarted)(SZFriendsLinkMetadata *metadata);
@property(nonatomic, readonly, nullable) NSString *conversationID;
@property(nonatomic, readonly, nullable) NSString *fileName;
@end

NS_ASSUME_NONNULL_END
