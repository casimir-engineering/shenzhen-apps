// `/` in a friend's composer, run through the assistant's tool seam (ai-agent-capabilities.md § 1, brief
// § Interface).
//
// The command is the person's request with origin "friend composer" and that conversation's friend. It may read that
// one chat (its own Friends gate, never the AI chat's) and read documents with the reader's read-only tools. It never
// sends: friends_send_message only hands its message back (SPDFMacFriendsSendProvider -proposal), to that friend alone
// and with files the person attached in the composer, and the views show it above the composer with Send and Edit.
// A command that does not ask to send comes back as its answer, a draft for the composer with the person's own
// attachments. Either way only the person's Send sends. Nothing is saved: the session has no chat store, so a `/`
// command leaves no AI chat behind.

#import <Foundation/Foundation.h>
#import "SPDFMacAIChatSession.h"
#import "SPDFMacFriendsChatScope.h"
#import "SPDFMacFriendsSendProvider.h"

@class SPDFMacAISettingsSnapshot;

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMacFriendsSlashResult : NSObject
// YES when the assistant asked to send this message (friends_send_message), NO for its answer. Nothing was sent
// either way.
@property(nonatomic, readonly) BOOL proposed;
// The message: proposed, exactly what the person's Send queues; otherwise the draft for the composer.
@property(nonatomic, readonly, copy) NSString* text;
// Proposed: the attached files it asked to send. Otherwise the person's attachments, unchanged. The assistant never
// adds one.
@property(nonatomic, readonly, copy) NSArray<SPDFMacAIRequestChip*>* files;
// Proposed only: the checked message (recipient, text, files), for SPDFMacFriendsSendProvider -sendProposal:done:.
@property(nonatomic, readonly, nullable) SPDFMacFriendsSendPlan* plan;
@end

typedef void (^SPDFMacFriendsSlashCompletion)(SPDFMacFriendsSlashResult* _Nullable result, NSError* _Nullable error);

// The registry a `/` command runs with: the reader's tools offered read-only (`readerDefinitions` filtered to
// SPDFMacAIReaderReadOnlyToolNames()), Friends chats through `gate`, and sending through `sendProvider`.
SPDFMacAIToolRegistry* SPDFMacFriendsSlashRegistry(id<SPDFMacAIChatTools> readerTools,
                                                   NSArray<NSDictionary*>* readerDefinitions,
                                                   SPDFMacFriendsChatScopeGate* gate,
                                                   SPDFMacFriendsSendProvider* sendProvider);

// The task the model reads for a `/` command. The friend's name is the friend's own choice, so it is quoted as data.
NSString* SPDFMacFriendsSlashSystemPrompt(NSString* friendName, NSString* _Nullable language);

@interface SPDFMacFriendsSlashCommand : NSObject
// `session`: built over SPDFMacFriendsSlashRegistry with no store; `sendProvider` is the one in its registry.
- (instancetype)initWithSession:(SPDFMacAIChatSession*)session
                   sendProvider:(SPDFMacFriendsSendProvider*)sendProvider
                     friendChip:(SPDFMacAIRequestChip*)friendChip
                          files:(NSArray<SPDFMacAIRequestChip*>*)files
                       settings:(nullable SPDFMacAISettingsSnapshot*)settings NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// The conversation's friend as the chip names them ("Mei").
@property(nonatomic, readonly, copy) NSString* friendName;
// The provider in the command's registry, which also sends a proposal once the person presses Send.
@property(nonatomic, readonly) SPDFMacFriendsSendProvider* sendProvider;
// Starts the command. NO, with the completion already called, when it could not start. `progress` receives what the
// session is doing, worded for the person ("Thinking…", "Reading pages…"); completion runs once, on the main thread.
// After -cancel it runs with NSUserCancelledError.
- (BOOL)runPrompt:(NSString*)prompt model:(NSString*)model apiKey:(NSString*)key
         progress:(nullable void (^)(NSString* status))progress completion:(SPDFMacFriendsSlashCompletion)completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
