#pragma once
// The chat session's own state, shared by its implementation files: SPDFMacAIChatSession.mm (requests, tools,
// saving), SPDFMacAIChatSessionSummaries.mm (titles, summaries of earlier messages, asking again from an edited
// question) and SPDFMacAIChatSessionCalls.mm (reading a reply's calls, Retry). Nothing else imports this.
#import "SPDFMacAIChatSession.h"
#import "SPDFMacAIChatStore.h"
#import "SPDFMacAITransport.h"
#import "SPDFMacAIChatProgress.h"

@interface SPDFMacAIChatSession () {
    @package
    SPDFMacAITransport* _transport; SPDFMacAIToolRegistry* _registry; SPDFMacAIChatActivity* _activity;
    SPDFMacAIRequestContext* _context; BOOL _wrapUpSent;
    SPDFMacAIRequestContext* _parentContext; SPDFMacAIRequestBudget* _childBudget; // a child session's request
    SPDFMacAIChatStore* _store; NSMutableDictionary* _mutableChat; NSMutableArray* _messages;
    SPDFMacAIRequestToken* _visionWork; SPDFMacAIRequestToken* _request; SPDFMacAIRequestToken* _titleRequest;
    NSUInteger _generation; BOOL _changedDocument;
    NSDictionary* _readerContext; NSMutableDictionary* _reasoning;
    NSString* _model; NSString* _key; BOOL _running; NSString* _status; SPDFMacAIChatActivityState _activityState;
    NSString* _runningTool; NSString* _runningToolProgress;
    // Calls whose provider keeps them for their request only: saved as stubs from their first save, so the file
    // never holds their arguments even when Stop or a crash comes before their result.
    NSMutableSet<NSString*>* _requestOnlyCalls;
    // Summaries made for the current request, whether one failed, whether a refused request was retried after one,
    // and what the request's tool definitions cost (0 until estimated).
    NSUInteger _compactions; BOOL _compactionFailed; BOOL _contextRetried; NSUInteger _definitionTokens;
    // How often in a row this request asked the model again for calls it could not read (SPDFMacAIChatSessionCalls.mm),
    // whether the request that ended may be sent again (canRetry), and the latest unreadable call (memory only).
    NSUInteger _argumentsRetries; BOOL _retryable; NSDictionary* _unreadableCall;
    // Long requests (SPDFMacAIChatSessionRecovery.mm): whether steps still get somewhere, a note the model reads with
    // its next request only (a loop it is in, a reply that could not be used), replies in a row that could not be
    // used, connection attempts in a row that failed, and the reason a request is being wound up early.
    SPDFMacAIProgressGuard* _progress; NSString* _pendingNote; NSUInteger _replyRetries; NSUInteger _connectionRetries;
    BOOL _windUp; NSString* _windUpReason;
    // The request paused before finishing and Continue may resume it; the next request is that Continue.
    BOOL _canContinue; BOOL _continuing;
}
- (void)notify;
- (BOOL)persist;
- (void)stopAfterSaveFailure:(NSError*)error;
// The chat as its file keeps it (request-only content as stubs, Friends excerpts replaced).
- (NSDictionary*)storedChatFrom:(NSDictionary*)chat;
// Saves the chat. `expected`: the stored messages this save rewrites (an edit or a summary); nil may only append.
// Once the request has ended, the open chat keeps what the file keeps. A session with no store saves nothing.
- (BOOL)saveReplacing:(NSArray*)expected error:(NSError**)error;
- (NSString*)requestSystemPrompt;
- (void)nextRequest:(NSUInteger)generation;
- (void)finish:(NSString*)status;
- (void)finish:(NSString*)status state:(SPDFMacAIChatActivityState)state;
@end

@interface SPDFMacAIChatSession (RecoveryInternal)
// The most calls of one reply that run; the rest are answered "send again".
FOUNDATION_EXPORT const NSUInteger SPDFMacAICallsRunPerReply;
// A reply that can't be used and did no work (unreadable, empty, cut off, too large, or no reply at all because the
// connection failed): asked again within the request, with a note saying what went wrong, until that keeps failing;
// then the request winds up with what it has. `error` is the transport's, or nil for a reply the session refused.
- (void)recoverFromUnusableReply:(NSError*)error problem:(NSString*)problem generation:(NSUInteger)generation;
// Ends the request early but usefully: one more reply without tools says what was done and what is left, then the
// chat offers Continue. `reason` (model-facing, optional) says why.
- (void)windUpWithReason:(NSString*)reason generation:(NSUInteger)generation;
// The wind-up's own reply could not be used: the app writes the answer itself, then offers Continue.
- (void)pauseWithLocalSummary:(NSString*)status;
// The wind-up's reply is in the chat: the request pauses with Continue.
- (void)pauseAfterWindUp;
// What the person reads beside Continue.
@property(nonatomic, readonly) NSString* pausedStatus;
// Answers every call that has no result yet with `content`, so the history stays a valid conversation.
- (void)completeOpenCallsWith:(NSString*)content;
// A finished step's calls, for the progress guard; its verdict may nudge the model or wind the request up.
- (void)recordCall:(NSDictionary*)call arguments:(NSDictionary*)arguments result:(NSDictionary*)result;
- (void)endStepWithGeneration:(NSUInteger)generation;
// The trailing system messages for this request: the wind-up instruction, or a pending note.
- (NSArray<NSDictionary*>*)trailingNotesWrappingUp:(BOOL)wrappingUp;
@end

@interface SPDFMacAIChatSession (SummariesInternal)
- (void)suggestTitleWithKey:(NSString*)key;
- (NSUInteger)estimatedRequestTokens;
- (void)compactAt:(NSUInteger)cut generation:(NSUInteger)generation completion:(void (^)(BOOL ok))completion;
- (BOOL)retryAfterContextError:(NSError*)error generation:(NSUInteger)generation;
@end

@interface SPDFMacAIChatSession (CallsInternal)
// The reply's calls with arguments the tools can run, each kept as strict JSON (SPDFMacAIToolArguments.h); nil when
// the reply has been dealt with instead: the request finished, or the model was asked once to send unreadable calls
// again. No call of a batch with an unreadable one runs.
- (NSArray*)runnableCalls:(NSArray*)calls message:(NSDictionary*)message offered:(NSSet*)offered
    generation:(NSUInteger)generation;
- (void)markRequestOnlyCalls:(NSArray*)calls offered:(NSSet*)offered;
- (void)finish:(NSString*)status retryable:(BOOL)retryable;
@end
