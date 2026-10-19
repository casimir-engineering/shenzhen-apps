// What one request may send to friends, decided from the request alone (ai-agent-capabilities.md § 1).
//
// The person's own message is the permission. A request built in AI chat may send only to the friends its `@` chips
// name; a `/` command in a friend's composer only to that conversation's friend. Files are only the ones the person
// attached to that request (`#` chips and drops). SPDFMacAIRequestContext fixes its chips when it is built, so nothing
// a tool returns, and no text in a friend's message, a document or a page, can add a recipient or a file here. The
// model names a recipient and files by the labels this scope offers; it never passes a conversation id or a path.
// A subagent (depth 1) may send nothing.

#import <Foundation/Foundation.h>
#import "SPDFMacAIRequestContext.h"
#import "SPDFMacFriendsSendText.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFMacFriendsSendToolName;     // friends_send_message
FOUNDATION_EXPORT const NSUInteger SPDFMacFriendsSendsPerRequest; // 3
FOUNDATION_EXPORT const NSUInteger SPDFMacFriendsMessageBytesMax; // 32 KiB, PROTOCOL.md's message limit
// Every message waits on a card for the person's Send, so it is at most what a card shows in full: the protocol's
// 32 KiB, which a literal card body holds whole (SPDFMacAIActivityBodyStyleLiteral), so AI chat and `/` share one
// limit and the person never presses Send on text the card cut off. Counted in bytes of UTF-8, as the card and the
// protocol count.
FOUNDATION_EXPORT const NSUInteger SPDFMacFriendsCheckedMessageLengthMax;
// What a message waiting for the person's Send says, the same on the AI chat card, a `/` proposal and a `/` draft:
// each shows the text and a Send, and nothing has gone yet.
FOUNDATION_EXPORT NSString* const SPDFMacFriendsNotSentYetNote;

// One friend this request may send to.
@interface SPDFMacFriendsSendRecipient : NSObject
@property(nonatomic, readonly, copy) NSString* conversationID;
@property(nonatomic, readonly, copy) NSString* name;  // as the person saw it on the chip: "Mei"
@property(nonatomic, readonly, copy) NSString* label; // unique among the request's recipients: the tool's `to`
@end

// One checked message: a recipient and files of this request, and text within the limits that the card can show
// whole (SPDFMacFriendsVisibleText).
@interface SPDFMacFriendsSendPlan : NSObject
@property(nonatomic, readonly) SPDFMacFriendsSendRecipient* recipient;
@property(nonatomic, readonly, copy) NSString* text;
@property(nonatomic, readonly, copy) NSArray<SPDFMacAIRequestChip*>* files;
@property(nonatomic, readonly, copy) NSArray<NSString*>* fileLabels;
@end

@interface SPDFMacFriendsSendScope : NSObject
- (instancetype)initWithContext:(SPDFMacAIRequestContext*)context NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Empty when the request may send to nobody: no chip naming a friend, or a subagent.
@property(nonatomic, readonly, copy) NSArray<SPDFMacFriendsSendRecipient*>* recipients;
// Labels of the files the request may send, in the order the person attached them.
@property(nonatomic, readonly, copy) NSArray<NSString*>* fileLabels;
// The tool's definition for this request: `to` limited to the recipients' labels, `attachments` (only when the
// person attached files) to the file labels. nil when there is no recipient.
- (nullable NSDictionary*)toolDefinitionWithSendsLeft:(NSUInteger)sendsLeft;
// The checked send, or nil and *error, a refusal written for the model.
- (nullable SPDFMacFriendsSendPlan*)planForArguments:(NSDictionary*)arguments
                                               error:(NSString* _Nullable* _Nullable)error;
@end

// The PROTOCOL.md file object for an attachment chip: path, display_name and, when bound, the exact revision.
NSDictionary* SPDFMacFriendsFileObject(SPDFMacAIRequestChip* chip);

NS_ASSUME_NONNULL_END
