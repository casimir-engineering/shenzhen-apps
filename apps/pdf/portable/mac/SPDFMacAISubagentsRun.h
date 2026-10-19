#pragma once
// One run_subagents call (SPDFMacAISubagents.h): its tasks' child sessions, their rows in the chat, the timeout, and
// the result the main assistant reads. Main thread only, like the seam.
//
// Accounting (the numbers are in SPDFMacAISubagents.h). The request's budget pays for the tasks' tokens and tool calls,
// not their model turns. A child budget carved straight from the request (SPDFMacAIRequestBudget
// -childBudgetWithSteps:) would charge each task turn to the request's 12 steps, which four tasks making a few calls
// each use up before they finish, leaving the main assistant only its tools-off wrap-up turn to answer in. So the
// tasks draw on a pool of their own, carved from the request's task turns (`requestTurns`, one per request across its
// runs, which every task turn is charged to):
//   - turns: an equal share of the request's task turns left, at most 12 a task; refused under 2 a task;
//   - tool calls: 12 a task, fewer if the request has fewer left;
//   - tokens: SPDFMacAISubagentsTokensPerRun for the run, or less when the request's remaining tokens, split into one
//     share per task plus one kept back for the main assistant, give less; tasks share it equally.
// A task may still take one turn without tools after its own turns run out, to say what it found (the session's
// wrap-up turn); its tokens are charged like any other. When the run ends, however it ends, the pool's tokens and tool
// calls are charged to the request. Nothing else runs in the request meanwhile (the session waits for this tool), so
// charging at the end spends exactly what charging along the way would.
#import <Foundation/Foundation.h>
#import "SPDFMacAIToolProvider.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMacAISubagentRun : NSObject
// `tasks` as SPDFMacAISubagentTasks returns them; `providers` the providers whose read-only tools tasks may use;
// `requestTurns` the request's task turns, shared by every run in it (only its steps are read and charged).
- (instancetype)initWithTasks:(NSArray<NSDictionary<NSString*, NSString*>*>*)tasks
                      context:(SPDFMacAIRequestContext*)context
                    providers:(NSSet<NSString*>*)providers
                      timeout:(NSTimeInterval)timeout
                 requestTurns:(SPDFMacAIRequestBudget*)requestTurns NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) SPDFMacAIRequestContext* context;
// YES once -startWithCompletion: made and started its tasks; NO when it refused (budget, request ended).
@property(nonatomic, readonly) BOOL started;
// Starts every task. `completion` runs once, on the main thread, with the tool result: {"error"} when no task could
// start, otherwise {"tasks": [...], "timed_out", "note"}.
- (void)startWithCompletion:(SPDFMacAIToolCompletion)completion;
// The request was stopped or abandoned: every task stops and the completion gets what they had.
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
