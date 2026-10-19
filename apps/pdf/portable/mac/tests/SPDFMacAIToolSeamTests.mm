// The assistant's tool seam (mac/SPDFMacAIToolProvider.h): request context, registry, the chat session on it,
// child sessions, activity, calls kept for their request only and the capability settings. Headless: a scripted
// model, scripted providers, a temporary chat store; no network, no Keychain, no app.
#import <Cocoa/Cocoa.h>
#import "SPDFMacAIToolSeamFakes.h"
#import "SPDFMacAIRequestSeamChecks.h"
#import "SPDFMacAIRegistrySeamChecks.h"
#import "SPDFMacAISessionSeamChecks.h"
#import "SPDFMacAIActivitySeamChecks.h"
#import "SPDFMacAIStorageSeamChecks.h"
#import "SPDFMacAIVisibleTextChecks.h"
#import "SPDFMacAIRunningToolChecks.h"

int main(void) {
    @autoreleasepool {
        CheckRequestContext();
        CheckRequestBudget();
        CheckSettingsSnapshot();
        CheckRegistry();
        CheckSessionLifecycle();
        CheckSaveFailureEndsRequest();
        CheckSessionBudgets();
        CheckChildSessions();
        CheckActivity();
        CheckVisibleText();
        CheckSharedInvisibleCases();
        CheckRunningTool();
        CheckStoredRequestOnlyMessages();
        CheckRequestOnlyCallsLeaveNothing();
    }
    if (failures) { fprintf(stderr, "SPDFMacAIToolSeamTests: %d failures\n", failures); return 1; }
    puts("SPDFMacAIToolSeamTests passed");
    return 0;
}
