// Web search and pages for the assistant (mac/SPDFMacAIWebToolProvider.h, ai-agent-capabilities.md § 2). Headless:
// a scripted resolver, connector, OpenRouter transport and model. The real connector and resolver run on loopback
// only; nothing reaches the network, the Keychain or a provider.
#import <Cocoa/Cocoa.h>
#import "SPDFMacAIWebFakes.h"
#import "SPDFMacAIWebAddressChecks.h"
#import "SPDFMacAIWebHTTPChecks.h"
#import "SPDFMacAIWebFetchChecks.h"
#import "SPDFMacAIWebConnectionChecks.h"
#import "SPDFMacAIWebSearchChecks.h"
#import "SPDFMacAIWebProviderChecks.h"
#import "SPDFMacAIWebProvenanceChecks.h"
#import "SPDFMacAIWebSessionChecks.h"
#import "SPDFMacAIWebFriendsChecks.h"
#import "SPDFMacAIWebBrowserChecks.h"

int main(void) {
    @autoreleasepool {
        CheckAddressKinds();
        CheckTargets();
        CheckRequest();
        CheckResponseParser();
        CheckReadableText();
        CheckFetchBasics();
        CheckFetchRedirects();
        CheckFetchRebinding();
        CheckFetchLimits();
        CheckRealConnector();
        CheckSearchRequest();
        CheckSearchResults();
        CheckSearcher();
        CheckProviderSwitch();
        CheckProviderSearch();
        CheckProviderProvenance();
        CheckProviderPages();
        CheckProviderSiteLimits();
        CheckProvenanceEchoes();
        CheckProvenanceRedirects();
        CheckFriendsNoWeb();
        CheckStepLinks();
        CheckSessionRoundTrip();
        CheckSessionEcho();
        CheckFriendsSavedChat();
        CheckReaderRegistration();
        CheckBrowserFetch();
        CheckDocumentPages();
        CheckProviderDocuments();
        CheckFailureCopy();
        [NSFileManager.defaultManager removeItemAtURL:WebDocumentFolder() error:nil];
    }
    if (failures) { fprintf(stderr, "SPDFMacAIWebTests: %d failures\n", failures); return 1; }
    puts("SPDFMacAIWebTests passed");
    return 0;
}
