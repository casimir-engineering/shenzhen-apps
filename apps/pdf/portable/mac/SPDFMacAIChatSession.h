#pragma once
#import <Foundation/Foundation.h>
#import "SPDFMacAIToolRegistry.h"
#import "SPDFMacAIChatActivity.h"
@class SPDFMacAITransport, SPDFMacAIChatStore;
@protocol SPDFMacAIChatTools <NSObject>
- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments completion:(void (^)(NSDictionary*))completion;
@property(nonatomic, readonly) BOOL canUndo;
- (void)cancel;
- (BOOL)undoLastAction:(NSError**)error;
@optional
- (NSDictionary*)conversationContext;
@property(nonatomic,readonly) BOOL canRedo;
- (void)undoWithCompletion:(void (^)(NSDictionary*))completion;
- (void)redoWithCompletion:(void (^)(NSDictionary*))completion;
// The chat as its file keeps it, asked on every save. Tools whose results must not outlive the request that read
// them (Friends excerpts) return stubs in their place and may mark the chat; once the request has ended the open chat
// keeps the stored messages too. A message must depend only on the messages before it, or the store refuses the
// next save as a conflict.
- (NSDictionary*)chatForStorage:(NSDictionary*)chat;
// The messages a chat title may be built from. The title request runs after the request has ended.
- (NSArray<NSDictionary*>*)messagesForTitle:(NSArray<NSDictionary*>*)messages;
@end
typedef NS_ENUM(NSInteger, SPDFMacAIChatActivityState) {
    SPDFMacAIChatActivityIdle, SPDFMacAIChatActivityThinking, SPDFMacAIChatActivityWorking,
    SPDFMacAIChatActivityCompleted, SPDFMacAIChatActivityError, SPDFMacAIChatActivityStopped,
    SPDFMacAIChatActivityPaused, SPDFMacAIChatActivitySummarizing
};
@interface SPDFMacAIChatSession : NSObject
@property(nonatomic, copy) void (^changed)(void);
@property(nonatomic, copy) NSString* defaultLanguage;
@property(nonatomic, readonly) NSDictionary* chat;
@property(nonatomic, readonly) BOOL running;
@property(nonatomic, readonly) BOOL canUndo;
@property(nonatomic, readonly) BOOL canRedo;
- (void)performHistoryAction:(BOOL)redo;
@property(nonatomic, readonly) NSString* status;
@property(nonatomic, readonly) SPDFMacAIChatActivityState activityState;
@property(nonatomic, readonly) NSString* activityDetail;
// The tool the request is running now ("web_search"), nil otherwise. An identifier, never shown: each view words it
// for the person who reads it ("Searching the web…", SPDFChatRunningToolText). Meanwhile `status` says "Working…".
@property(nonatomic, readonly, copy) NSString* runningTool;
// One tools object and fixed definitions, as before tool providers (SPDFMacAIToolRegistry -initWithLegacyTools:).
- (instancetype)initWithTransport:(SPDFMacAITransport*)transport tools:(id<SPDFMacAIChatTools>)tools
    definitions:(NSArray*)definitions store:(SPDFMacAIChatStore*)store;
// Tools from a registry of providers (SPDFMacAIToolProvider.h), offered per request. `store` nil saves nothing.
// Calls a provider keeps for their request only (-isRequestOnlyTool:context:) are saved as stubs from the first
// save on (SPDFMacAIChatStoredRequestOnlyMessages), and the open chat holds the stubs once the request ends. In a
// request that includes Friends chats, so are calls to a tool that request did not offer, whether no provider owns
// it or its provider held it back: no provider's rule covers what the model put in them.
- (instancetype)initWithTransport:(SPDFMacAITransport*)transport registry:(SPDFMacAIToolRegistry*)registry
    store:(SPDFMacAIChatStore*)store;
@property(nonatomic, readonly) SPDFMacAIToolRegistry* registry;
// Step rows, cards and images; saved with the chat under "activity". Every request's context reports here.
@property(nonatomic, readonly) SPDFMacAIChatActivity* activity;
// The running request's context, nil between requests.
@property(nonatomic, readonly) SPDFMacAIRequestContext* currentContext;
// 0 for the person's chat, 1 for a child session.
@property(nonatomic, readonly) NSUInteger depth;
// nil: the document assistant's own prompt. A child session's task prompt goes here.
@property(nonatomic, copy) NSString* systemPrompt;
// Once per request, after it ends in any way (completed, error, paused, stopped).
@property(nonatomic, copy) void (^requestFinished)(SPDFMacAIChatActivityState state);
- (void)newChat;
- (void)loadChat:(NSDictionary*)chat;
// The person's message with no chips (tests, and callers that have no composer).
- (void)send:(NSString*)text model:(NSString*)model apiKey:(NSString*)key;
// The selected model's context window in tokens; 0 uses a large default.
@property(nonatomic) NSUInteger contextTokens;
// One request. `context` must be new (a context runs once) and its activity should be this session's.
- (void)sendContext:(SPDFMacAIRequestContext*)context model:(NSString*)model apiKey:(NSString*)key;
// A child conversation for one subagent task, made while this session's request runs: the same transport, model
// and key, this registry seen through `filter`, nothing saved, and `budget` for its turns and tool calls (carve it
// from currentContext.budget so the request pays for it). Stop on this request stops it. nil with an error inside
// a child session (one level only) or when no request is running.
- (SPDFMacAIChatSession*)childSessionWithFilter:(SPDFMacAIToolFilter*)filter budget:(SPDFMacAIRequestBudget*)budget
    error:(NSError**)error;
// Runs a child session's task as its request, the context derived from the parent's (same chips and activity).
- (BOOL)sendTask:(NSString*)task error:(NSError**)error;
// The newest assistant text in the chat, or nil: a child session's answer.
- (NSString*)latestAnswer;
- (NSArray<NSDictionary*>*)liveActivityActionsForEntry:(NSString*)identifier;
- (BOOL)performActivityAction:(NSString*)action forEntry:(NSString*)identifier;
// Stop. The providers' -cancel comes only when the person's session (depth 0) has a request, Undo or Redo running: a
// child's providers are its parent's, and an idle session has nothing of theirs to stop.
- (void)cancel;
- (BOOL)undo:(NSError**)error;
@end
// Answers that couldn't be used (SPDFMacAIChatSessionCalls.mm).
@interface SPDFMacAIChatSession (Calls)
// The request ended on an answer that couldn't be used (cut off, unreadable, empty) and sending the latest question
// again is safe: it changed no document. The chat then offers Retry, which resends retryMessageIndex's question.
@property(nonatomic, readonly) BOOL canRetry;
// The latest question in the chat, or NSNotFound.
@property(nonatomic, readonly) NSUInteger retryMessageIndex;
// The latest call whose arguments couldn't be read: tool name, problem (SPDFMacAIToolArgumentsProblem), length and
// the first 4 KB as the provider sent them. Memory only, never saved with the chat: for diagnosing a provider.
@property(nonatomic, readonly) NSDictionary* lastUnreadableCall;
@end
// Long chats and edited questions (SPDFMacAIChatSessionSummaries.mm).
@interface SPDFMacAIChatSession (Summaries)
// Summarize everything before the latest question so the chat can keep going.
@property(nonatomic, readonly) BOOL canCompact;
- (void)compactWithModel:(NSString*)model apiKey:(NSString*)key;
// Replace an earlier question, discard everything after it, and ask again from there.
// Stops a reply in progress first. NO when the message cannot be edited or saved.
- (BOOL)resendFromMessageAtIndex:(NSUInteger)index text:(NSString*)text model:(NSString*)model apiKey:(NSString*)key;
// The same with the edited question's own request (its settings and chips). Not in a child session.
- (BOOL)resendFromMessageAtIndex:(NSUInteger)index context:(SPDFMacAIRequestContext*)context model:(NSString*)model
    apiKey:(NSString*)key;
@end
