// Sending to friends for the person: the friends_send_message tool (ai-agent-capabilities.md § 1, brief § AI
// boundaries, "Sending for the person"). SPDFMacFriendsSendRules.h decides who may receive what; this provider
// offers the tool only when that is someone, counts messages, and puts each one in front of the person
// (SPDFMacFriendsSendCards.h).
//
//   - No chip, no tool: the tool is offered only to a request whose own message names friends with `@` (AI chat) or,
//     for `/`, typed in a friend's composer. The registry refuses a call to a tool the request was not offered.
//   - At most 3 messages per request; text up to 32 KiB, every character of it visible (SPDFMacFriendsSendText.h);
//     files only the person's own `#` chips and drops.
//   - The person sends. No call queues anything. In AI chat the message waits on a card showing the recipient, the
//     text as literal characters and the files, with Send and Discard; a `/` command hands it back to the composer
//     (-proposal), shown above it with Send and Edit. Only the person's Send queues it, exactly as shown, as
//     send_message with "via_assistant": true, so both chats show "Via the assistant". Text the person did not write
//     (a friend's message, a document, a web page, a helper's summary, even the open document's title or a friend's
//     chosen name) can steer what the model writes, and nothing short of the person reading every character can tell
//     a planted instruction from their request, so no request is trusted to send by itself.
//
// The read-only rule. A request that read Friends messages may only read (SPDFMacFriendsToolProvider.h), so a friend's
// message cannot make the assistant change anything. This tool stays exempt (-isReadOnlyTool: answers YES) because
// it can do no more than put a message in front of the person, and only their own click sends it. Let a call send by
// itself and the exemption must go. The other place the answer counts is a subagent's read-only tool set, and this
// provider never offers the tool to a subagent (depth 1) and refuses it there if called.

#import <Foundation/Foundation.h>
#import "SPDFMacAIToolProvider.h"
#import "SPDFMacFriendsSendRules.h"

@class SPDFMacAIChatActivity;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFMacFriendsSendProviderIdentifier; // "friends.send"
FOUNDATION_EXPORT NSString* const SPDFMacFriendsSendCardKind;           // "friends.send"
// The helper capability that says an outgoing message still queued or connecting can be withdrawn with the
// cancel_message intent (PROTOCOL.md § Capabilities). Without it a card offers no Cancel for a message's text.
FOUNDATION_EXPORT NSString* const SPDFMacFriendsCancelMessageCapability; // "messages.cancel"

typedef void (^SPDFMacFriendsIntentReply)(NSDictionary* _Nullable result, NSString* _Nullable errorCode,
                                          NSString* _Nullable errorMessage);
// message_id -> PROTOCOL.md message_status ({state, label}).
typedef void (^SPDFMacFriendsStatusHandler)(NSDictionary<NSString*, NSDictionary*>* statuses);

// What reaches the helper: the views' helper link in the app (SPDFMacFriendsLinkSender.h), a fake in tests.
@protocol SPDFMacFriendsIntentSender <NSObject>
// NO while Friends is off or not connected; nothing is sent then.
@property(nonatomic, readonly) BOOL friendsReady;
@property(nonatomic, readonly, copy) NSSet<NSString*>* helperCapabilities;
// One intent (PROTOCOL.md § Intents). `reply` runs exactly once, on the main thread, with the result or the error
// code and the helper's display-ready message (nil when it has none).
- (void)sendIntent:(NSString*)type fields:(NSDictionary*)fields reply:(SPDFMacFriendsIntentReply)reply;
@optional
// Delivery status of these outgoing messages, now and whenever it changes, on the main thread, without marking
// anything read. nil when the helper cannot report it (SPDFMacFriendsLinkSender.h).
- (nullable id)watchMessages:(NSArray<NSString*>*)messageIDs handler:(SPDFMacFriendsStatusHandler)handler;
- (void)stopWatching:(id)watch;
// One of Friends' static strings (PROTOCOL.md § Static strings, welcome.strings), so a card says what Friends says;
// nil before the helper's welcome or when it has no such string.
- (nullable NSString*)staticStringForKey:(NSString*)key;
@end

// One message Friends accepted after the person's Send.
@interface SPDFMacFriendsSendRecord : NSObject
- (instancetype)initWithPlan:(SPDFMacFriendsSendPlan*)plan messageID:(nullable NSString*)messageID
                   transfers:(nullable NSArray<NSString*>*)transfers NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) SPDFMacFriendsSendRecipient* recipient;
@property(nonatomic, readonly, copy) NSString* text;
@property(nonatomic, readonly, copy) NSArray<SPDFMacAIRequestChip*>* files;
@property(nonatomic, readonly, copy) NSString* messageID;
@property(nonatomic, readonly, copy) NSArray<NSString*>* transferIDs;
@end

@interface SPDFMacFriendsSendProvider : NSObject <SPDFMacAIToolProvider>
// `sender` is asked at each send, so Friends may connect and disconnect between requests; nil means not connected.
- (instancetype)initWithSender:(id<SPDFMacFriendsIntentSender> _Nullable (^)(void))sender NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// The card's Show: opens the Friends dropdown at the sent message. No Show without it.
@property(nonatomic, copy, nullable) void (^showMessage)(NSString* conversationID, NSString* messageID);
// Set by a `/` command: where its message goes instead of a card (above the composer, for the person to send). Each
// call of the tool replaces the message, so the command's last word is what the person sees.
@property(nonatomic, copy, nullable) void (^proposal)(SPDFMacAIRequestContext* context, SPDFMacFriendsSendPlan* plan);
// Messages this request may still put in front of the person.
- (NSUInteger)sendsLeftForContext:(SPDFMacAIRequestContext*)context;
// The person pressed Send on a `/` proposal: queues exactly `plan` (text and files) to its friend with via_assistant,
// as the card's Send does. `done` runs once, on the main thread, with nil or an error written for the person.
- (void)sendProposal:(SPDFMacFriendsSendPlan*)plan done:(void (^)(NSError* _Nullable error))done;
// See SPDFMacFriendsSendCards: the window's chat calls this whenever it changes.
- (void)restoreCardsInActivity:(nullable SPDFMacAIChatActivity*)activity;
@end

NS_ASSUME_NONNULL_END
