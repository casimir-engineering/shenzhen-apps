#pragma once
// open_page's fetch of one https page (ai-agent-capabilities.md § 2). For every hop, the first and each redirect:
// the URL is checked (SPDFMacAIWebTargetForURL), the name resolved, every address it resolves to checked, and the
// connection made to one of those checked addresses, never to the name again. At most 3 redirects, a size limit on
// what is read and on the text kept, one deadline for the whole fetch, no cookies, credentials or referrer.
#import <Foundation/Foundation.h>
#import "SPDFMacAIWebConnection.h"
#import "SPDFMacAIWebText.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMacAIWebPage : NSObject
@property(nonatomic, readonly) NSURL* URL;          // where the text came from, after any redirects
@property(nonatomic, readonly) NSURL* requestedURL;
@property(nonatomic, readonly) NSUInteger redirects;
@property(nonatomic, readonly, copy) NSString* address; // the checked address the page was read from
@property(nonatomic, readonly) SPDFMacAIWebReadable* readable;
@property(nonatomic, readonly) BOOL truncated;       // the page holds more than the limits keep
@end

typedef void (^SPDFMacAIWebPageCompletion)(SPDFMacAIWebPage* _Nullable page, NSError* _Nullable error);

@interface SPDFMacAIWebFetcher : NSObject
// The system resolver and the TLS connector.
- (instancetype)init;
- (instancetype)initWithResolver:(id<SPDFMacAIWebResolving>)resolver connector:(id<SPDFMacAIWebConnecting>)connector
    NS_DESIGNATED_INITIALIZER;
@property(nonatomic) NSTimeInterval timeout;  // the whole fetch, redirects included: 30 s
@property(nonatomic) NSUInteger maxRedirects; // 3
@property(nonatomic) NSUInteger maxBodyBytes; // read from the site per hop: 2 MB
@property(nonatomic) NSUInteger maxTextBytes; // readable text kept: 200 KB
// The completion runs once, on the main thread, with a page or an SPDFMacAIWebErrorDomain error. The returned block
// stops the fetch; the completion then runs with SPDFMacAIWebErrorCancelled.
- (dispatch_block_t)fetchURL:(NSURL*)URL completion:(SPDFMacAIWebPageCompletion)completion;
@end

NS_ASSUME_NONNULL_END
