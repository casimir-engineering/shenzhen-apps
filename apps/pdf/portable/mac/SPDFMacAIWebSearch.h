#pragma once
// web_search (ai-agent-capabilities.md § 2): one OpenRouter request on the person's own model and key, with
// OpenRouter's web search server tool (openrouter:web_search, Exa engine; docs checked 13 October 2026) and the same
// no-training, zero-retention routing as every assistant request (SPDFMacAIChatRequest). OpenRouter returns what the
// search found as url_citation annotations; those that carry the engine's excerpt become title, URL and snippet. The
// model's own reply in that request is not used. No other account or key.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const NSUInteger SPDFMacAIWebSearchMaximumResults; // 8

typedef void (^SPDFMacAIWebSearchReply)(NSInteger status, NSData* _Nullable body, NSError* _Nullable error);

@protocol SPDFMacAIWebSearchTransport <NSObject>
// Sends `request`; `reply` runs once, on any queue. Returns a block that cancels.
- (dispatch_block_t)sendRequest:(NSURLRequest*)request reply:(SPDFMacAIWebSearchReply)reply;
@end

// An ephemeral NSURLSession: no cookies, cache or stored credentials, redirects refused, at most 2 MB of answer.
@interface SPDFMacAIWebSearchSession : NSObject <SPDFMacAIWebSearchTransport>
@end

// The request for one search, or nil and an error when the model or key cannot be sent.
NSURLRequest* _Nullable SPDFMacAIWebSearchRequest(NSString* query, NSUInteger maxResults, NSString* model,
                                                  NSString* apiKey, NSError** error);
// [{title, url, snippet}] from a response body: citations with an excerpt and an http(s) URL, each URL once, at most
// `maxResults`, text clipped.
// `tokens` receives the usage OpenRouter reports (0 when it reports none).
NSArray<NSDictionary<NSString*, NSString*>*>* _Nullable SPDFMacAIWebSearchResults(NSData* body, NSUInteger maxResults,
                                                                                  NSUInteger* _Nullable tokens,
                                                                                  NSError** error);

typedef void (^SPDFMacAIWebSearchCompletion)(NSArray<NSDictionary<NSString*, NSString*>*>* _Nullable results,
                                             NSUInteger tokens, NSError* _Nullable error);

@interface SPDFMacAIWebSearcher : NSObject
- (instancetype)init; // SPDFMacAIWebSearchSession
- (instancetype)initWithTransport:(id<SPDFMacAIWebSearchTransport>)transport NS_DESIGNATED_INITIALIZER;
// The completion runs once, on the main thread; errors are in SPDFMacAIWebErrorDomain with text for the model. The
// returned block stops the search; the completion then runs with SPDFMacAIWebErrorCancelled.
- (dispatch_block_t)search:(NSString*)query maxResults:(NSUInteger)maxResults model:(NSString*)model
                    apiKey:(NSString*)apiKey completion:(SPDFMacAIWebSearchCompletion)completion;
@end

NS_ASSUME_NONNULL_END
