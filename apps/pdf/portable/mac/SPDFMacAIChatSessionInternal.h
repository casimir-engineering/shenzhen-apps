#pragma once
// The chat session's own state, shared by its two implementation files: SPDFMacAIChatSession.mm (requests, tools,
// saving) and SPDFMacAIChatSessionSummaries.mm (titles, summaries of earlier messages, asking again from an edited
// question). Nothing else imports this.
#import "SPDFMacAIChatSession.h"
#import "SPDFMacAIChatStore.h"
#import "SPDFMacAITransport.h"

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
@end

@interface SPDFMacAIChatSession (SummariesInternal)
- (void)suggestTitleWithKey:(NSString*)key;
- (NSUInteger)estimatedRequestTokens;
- (void)compactAt:(NSUInteger)cut generation:(NSUInteger)generation completion:(void (^)(BOOL ok))completion;
- (BOOL)retryAfterContextError:(NSError*)error generation:(NSUInteger)generation;
@end
