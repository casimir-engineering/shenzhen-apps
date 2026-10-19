// Friends chats as an AI tool provider (portable/mac/SPDFMacAIToolProvider.h): the same enforcement as
// SPDFMacFriendsScopedChatTools and SPDFMacFriendsScopedTransport (SPDFMacFriendsChatTools.h), expressed through the
// registry instead of by wrapping the session's tools and transport.
//
//   - Tools: friends_search_chats and friends_read_messages, offered only while the gate's request carries a scope,
//     which comes from the request's Friends chips (and, for `/`, the conversation it was typed in), or from the
//     time grant the AI chat request was sent under (SPDFMacFriendsChatGrant.h) while it still runs. A call without
//     a scope is refused by the registry before it reaches the gate.
//   - Read-only: once the request read Friends messages, or what it sends still holds some, -readOnlyReasonForContext:
//     makes the registry refuse every tool that is not read-only, in this request and while later context holds
//     them, so a friend's message cannot act through the assistant.
//   - History: each model turn's messages pass through SPDFMacFriendsRedactChatHistory; the chat file keeps stubs
//     (SPDFMacFriendsStoredChatHistory) and titles are built without Friends answers.
//
// One gate is one request at a time. The AI chat shares the window's gate with the composer's `@` scoper, which
// opens the scope as the person sends; -beginRequestWithContext: then finds it open and keeps it. A `/` request in a
// friend conversation needs a provider with its own gate, so it never shares a scope with the AI chat.

#import <AppKit/AppKit.h>
#import "SPDFMacAIToolProvider.h"
#import "SPDFMacFriendsChatScope.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFMacFriendsToolProviderIdentifier; // "friends"

@interface SPDFMacFriendsToolProvider : NSObject <SPDFMacAIToolProvider>
- (instancetype)initWithGate:(SPDFMacFriendsChatScopeGate*)gate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) SPDFMacFriendsChatScopeGate* gate;
@end

// The Friends chats one request may read by its own chips: the union of its Friends chips and, for `/`, its
// conversation. nil when it has neither. A time grant's chip is not one of them: it counts only while its grant runs.
SPDFMacFriendsScopeRequest* _Nullable SPDFMacFriendsScopeForContext(SPDFMacAIRequestContext* context);
// The time grant an AI chat request was sent under (its SPDFMacFriendsGrantChip's token), 0 for none.
uint64_t SPDFMacFriendsGrantTokenForContext(SPDFMacAIRequestContext* context);
// One Friends chip per `@` chip in the composer's text, in order.
NSArray<SPDFMacAIRequestChip*>* SPDFMacFriendsChipsInText(NSAttributedString* text);

NS_ASSUME_NONNULL_END
