#pragma once
// web_search and open_page for the assistant (ai-agent-capabilities.md § 2), as a provider on the tool seam
// (SPDFMacAIToolProvider.h). Offered only while "Let the assistant search the web" is on in the request's settings snapshot.
// Results and pages go back to the model as quoted data with a notice, and each search and page shows in the chat as
// a step row with the results as links. open_page opens only addresses the person typed, search results and links of
// pages already opened (SPDFMacAIWebProvenance.h), only on the public internet (SPDFMacAIWebAddress.h). A request
// that includes Friends chats (SPDFMacAIRequestContext.includesFriendsChats) is offered neither tool, nor are its
// subagents; its model is told why with each turn. Both tools only read, so subagents may use them otherwise.
#import <Foundation/Foundation.h>
#import "SPDFMacAIToolProvider.h"
#import "SPDFMacAIWebFetcher.h"
#import "SPDFMacAIWebSearch.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFMacAIWebToolProviderIdentifier; // "web"

// Reads the person's OpenRouter key when a search runs, never earlier; nil with an error when it cannot.
typedef NSString* _Nullable (^SPDFMacAIWebKeySource)(NSError** error);

@interface SPDFMacAIWebToolProvider : NSObject <SPDFMacAIToolProvider>
- (instancetype)initWithSearcher:(SPDFMacAIWebSearcher*)searcher fetcher:(SPDFMacAIWebFetcher*)fetcher
                          apiKey:(SPDFMacAIWebKeySource)apiKey NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Per request, subagents included: each search is a paid model call and each page a visit the site sees.
@property(nonatomic) NSUInteger maxSearchesPerRequest; // 10
@property(nonatomic) NSUInteger maxPagesPerRequest;    // 20
// Opens of one site (SPDFMacAIWebShownHost: "www." and case folded) per request, a redirect's landing site counted too.
@property(nonatomic) NSUInteger maxPagesPerSitePerRequest; // 3
@end

NS_ASSUME_NONNULL_END
