// Friends chats in AI chat, only under a grant the person gave (brief § AI boundaries): an `@` chip or `/` for one
// request, or a time grant for all chats (SPDFMacFriendsChatGrant.h) for requests sent while it runs.
//
// Enforced here, in code, not by the prompt:
//   - a request without a grant has no Friends tools: none are offered to the model and a hallucinated call
//     is refused without reaching the helper;
//   - a time grant is checked at every call: once it expires or the person stops it, the tools go and calls are
//     refused, in the middle of a request too; a later grant never reopens a request made under an earlier one;
//   - a scoped request opens one helper scope (assistant_open_scope) and every call goes through it, so the helper
//     limits it to the chosen conversations; results naming any other conversation are dropped here as well;
//   - the scope ends with the request: the next message needs its own chip. Excerpts last only as long as their
//     request; the chat keeps stubs with their message ids, which reach a later request only when its scope covers
//     them, and nothing the model wrote after reading them reaches any other (SPDFMacFriendsChatHistory.h);
//   - a request that read Friends messages, or whose context still holds some, may only read (see
//     SPDFMacFriendsChatTools.h), so text inside a friend's message cannot make the assistant change anything.
// Friend messages reach the model only as JSON string values inside tool results, marked as other people's words.

#import <Foundation/Foundation.h>
#import "mac/SZFriendsHost.h"
#import "SPDFMacFriendsChatGrant.h"

NS_ASSUME_NONNULL_BEGIN

// What one message's `@` chips chose. conversationIDs nil means All Friends chats.
@interface SPDFMacFriendsScopeRequest : NSObject
@property(nonatomic, readonly, copy, nullable) NSArray<NSString*>* conversationIDs;
@property(nonatomic, readonly, copy) NSArray<NSString*>* labels; // "Mei", or "All Friends chats"
+ (instancetype)allChats;
+ (instancetype)conversationIDs:(NSArray<NSString*>*)conversationIDs labels:(NSArray<NSString*>*)labels;
// Several chips on one message: their union; any "All Friends chats" chip makes it all.
+ (nullable instancetype)union:(NSArray<SPDFMacFriendsScopeRequest*>*)requests;
@end

FOUNDATION_EXPORT NSString* const SPDFMacFriendsSearchToolName; // friends_search_chats
FOUNDATION_EXPORT NSString* const SPDFMacFriendsReadToolName;   // friends_read_messages
// Waiting for the helper to open a scope never holds a tool call longer than this.
FOUNDATION_EXPORT const NSTimeInterval SPDFMacFriendsScopeOpenTimeout;

NSArray<NSDictionary*>* SPDFMacFriendsChatToolDefinitions(void);
BOOL SPDFMacFriendsIsChatTool(NSString* name);

typedef void (^SPDFMacFriendsToolCompletion)(NSDictionary* result);

@interface SPDFMacFriendsChatScopeGate : NSObject
// `services` returns Friends' exported services, or nil while Friends is off or not connected.
- (instancetype)initWithServices:(id<SZFriendsServices> _Nullable (^)(void))services NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// The AI chat's time grant for all chats; nil for a gate that never reads under one (`/` in a friend's chat).
@property(nonatomic, nullable) SPDFMacFriendsChatGrant* grant;

// Called for every AI request just before it is sent, with the message's chips or nil. Ends any earlier scope.
- (void)beginRequestWithScope:(nullable SPDFMacFriendsScopeRequest*)scope;
// The same, for a request sent while the time grant with `grantToken` ran (0: none). The token counts only while
// it is `grant`'s active token: the request may then read every chat until that grant ends, and `scope` after.
- (void)beginRequestWithScope:(nullable SPDFMacFriendsScopeRequest*)scope grantToken:(uint64_t)grantToken;
// YES when the current request was begun with this scope (the same conversations, or both all) and token.
- (BOOL)requestMatchesScope:(nullable SPDFMacFriendsScopeRequest*)scope grantToken:(uint64_t)grantToken;
// The request finished, failed, was stopped or was never sent. Closes the helper scope.
- (void)endRequest;

// How long a tool call may wait for the helper to open the scope; SPDFMacFriendsScopeOpenTimeout by default.
@property(nonatomic) NSTimeInterval openTimeout;
// YES while the current request may read some chat: its chips, or its time grant while that still runs.
@property(nonatomic, readonly) BOOL requestHasScope;
// The refusal for a Friends tool the request does not have: no grant at all, or a time grant that has ended.
@property(nonatomic, readonly) NSString* unavailableMessage;
// YES once a Friends tool returned messages in the current request.
@property(nonatomic, readonly) BOOL requestReadChats;
// YES when the current request's scope covers every one of these conversations ("" is a conversation no excerpt
// could name, which only All Friends chats covers). NO for a request without a scope.
- (BOOL)scopeCoversConversations:(NSSet<NSString*>*)conversationIDs;
// The scoped transport calls this when what it sent for the current request still holds Friends excerpts, earlier
// ones included (SPDFMacFriendsChatHistory.h). Cleared when the request ends.
- (void)noteRequestContextHoldsChats;
// YES while the current request may only read: it read Friends messages, or its context holds some.
@property(nonatomic, readonly) BOOL requestIsReadOnly;
// Empty unless the current request carries a scope.
- (NSArray<NSDictionary*>*)toolDefinitionsForCurrentRequest;

// Runs a Friends tool. Completion runs once, on the main thread, with a tool result dictionary ({"error": ...} on
// refusal). Never reaches the helper for a request without a scope.
- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments
         completion:(SPDFMacFriendsToolCompletion)completion;
@end

// The assistant's citation link for one message, opened by the host to show the dropdown at that message.
NSURL* SPDFMacFriendsMessageCitationURL(NSString* conversationID, NSString* messageID);
// conversation and message ids from such a link; NO for any other URL.
BOOL SPDFMacFriendsParseMessageCitationURL(NSURL* url, NSString* _Nullable* _Nullable conversationID,
                                           NSString* _Nullable* _Nullable messageID);

// YES when a tool result in `chat` (an SPDFMacAIChatSession chat: messages with role and content) returned exactly this
// citation, so only a message a Friends tool actually read can be opened from an answer.
BOOL SPDFMacFriendsChatContainsCitation(NSDictionary* _Nullable chat, NSURL* url);

NS_ASSUME_NONNULL_END
