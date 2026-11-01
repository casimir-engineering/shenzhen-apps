// Shenzhen Friends views: conversations' latest snapshots, kept so a click on a friend shows the chat at once
// (internal).
//
// Opening a conversation asks the helper for it (open_conversation), and the answer takes a round trip. A page opens on
// what is kept here instead, and the helper's answer replaces it when it comes. What is kept comes from conversations
// this dropdown showed, and from previews (PROTOCOL.md § Views, conversation_preview): live while the pointer rests on
// a row, once for the first rows when the list shows. A preview marks nothing read and does not count as the
// conversation being on screen, so it changes nothing the person or the friend sees.

#import <Foundation/Foundation.h>

@class SZFriendsHelperLink;

NS_ASSUME_NONNULL_BEGIN

// Posted with the cache as its object by -forgetAll.
extern NSNotificationName const SZFriendsConversationCacheDidForgetNotification;

@interface SZFriendsConversationCache : NSObject
// One per link, shared by every dropdown and Settings on it: what one of them deletes, none of them shows again.
+ (instancetype)cacheForLink:(SZFriendsHelperLink *)link;
- (instancetype)init NS_UNAVAILABLE;
// The conversation's latest snapshot seen in this process, or nil.
- (nullable NSDictionary *)snapshotFor:(NSString *)conversationID;
- (void)remember:(NSDictionary *)data forConversation:(NSString *)conversationID;
// A live preview while the pointer rests on the conversation's row, one at a time; -stopFollowing: ends it and keeps
// what it brought. Nothing without a helper that announces conversation.preview.
- (void)follow:(NSString *)conversationID;
- (void)stopFollowing:(nullable NSString *)conversationID; // nil: whichever is followed
// One preview of each conversation, dropped after its first snapshot: the rows the list shows first. A conversation
// kept less than a minute ago, or being previewed, is not fetched again.
- (void)prefetch:(NSArray<NSString *> *)conversationIDs;
// Forgets everything kept, after a history was deleted or someone removed or blocked here.
- (void)forgetAll;
@end

NS_ASSUME_NONNULL_END
