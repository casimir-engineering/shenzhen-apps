// run_subagents (mac/SPDFMacAISubagents.h): parallel read-only tasks inside one assistant request. Headless: a
// scripted model answering every conversation separately, scripted providers, the real chat session and registry,
// a temporary chat store. No network, no Keychain, no app; the one timeout used is 0.3 s.
#import <Cocoa/Cocoa.h>
#import "SPDFMacAISubagentsFakes.h"
#import "SPDFMacAISubagentsResultChecks.h"
#import "SPDFMacAISubagentsRunChecks.h"
#import "SPDFMacAISubagentsStopChecks.h"
#import "SPDFMacAISubagentsLimitChecks.h"
#import "SPDFMacAISubagentsStorageChecks.h"

int main(void) {
    @autoreleasepool {
        CheckTaskArguments();
        CheckFindings();
        CheckRowWords();
        CheckOfferedOnlyWhenOn();
        CheckTasksOnlyRead();
        CheckBudgets();
        CheckTimeoutReturnsPartialResults();
        CheckStopStopsEveryTask();
        CheckAbandonedRunStops();
        CheckCancelOneTask();
        CheckRowsAndSources();
        CheckFriendsScopeSurvivesTasks();
        CheckRunLimit();
        CheckRequestTurns();
        CheckRunTokenCap();
        CheckRowsAfterFriends();
        CheckFailedRows();
        CheckFriendsRequestKeepsNothing();
    }
    if (failures) {
        fprintf(stderr, "SPDFMacAISubagentsTests: %d failures\n", failures);
        return 1;
    }
    puts("SPDFMacAISubagentsTests passed");
    return 0;
}
