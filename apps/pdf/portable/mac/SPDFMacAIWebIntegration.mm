// Registers web search and pages with the AI chat's tool registry (SPDFMacAIToolProvider.h § 2): SPDFMacAIIntegration
// finds this method by its aiToolProvider prefix when the chat is first used, never at launch. Nothing here reads the
// key or touches the network; the provider reads the key only when a search runs inside a request the person sent.
#import "SPDFMacAIIntegration.h"
#import "SPDFMacAIWebToolProvider.h"

@interface ShenzhenMacDelegate (SPDFMacAIWebKeySource)
// SPDFMacAIIntegration's own read of the saved key for an explicit send: no Keychain prompt, so a search can never
// put one up in the middle of a request.
- (NSString*)aiAPIKeyForSending:(NSError**)error;
@end

@implementation ShenzhenMacDelegate (SPDFMacAIWebTools)

- (id<SPDFMacAIToolProvider>)aiToolProviderWeb {
    __weak ShenzhenMacDelegate* owner = self;
    return [[SPDFMacAIWebToolProvider alloc] initWithSearcher:[SPDFMacAIWebSearcher new]
                                                      fetcher:[SPDFMacAIWebFetcher new]
                                                       apiKey:^NSString*(NSError** error) {
        return [owner aiAPIKeyForSending:error];
    }];
}

@end
