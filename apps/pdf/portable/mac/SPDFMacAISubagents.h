#pragma once
// run_subagents: the assistant splits one question into 1–4 research tasks that run in parallel, each in its own
// read-only conversation with the same model, and gets back short summaries with sources (plan:
// portable/docs/plans/ai-agent-capabilities.md § 3; the seam it plugs into: SPDFMacAIToolProvider.h).
//
//   - Offered only in the person's own request (depth 0) while AI Settings' subagents switch is on, and refused
//     everywhere else with a reason the model reads.
//   - Each task is a child session (SPDFMacAIChatSession -childSessionWithFilter:) that sees only the read-only tools
//     of `taskProviders` (SPDFMacAISubagentToolProviders(): document reads, web search and pages, Python). Never
//     Friends: a task's findings come back as this tool's result, where the Friends provider's checks on its own
//     excerpts (scope, and what the chat file keeps) cannot follow them. Never sending, edits or app controls (not
//     read-only), and never run_subagents itself: this provider is not one of the task providers, offers nothing at
//     depth 1, and the session refuses a child's child anyway.
//   - Budgets (SPDFMacAISubagentsRun.h explains the accounting):
//       - at most 2 runs per request (SPDFMacAISubagentsRunsPerRequest), counting runs whose tasks started; after
//         the second the tool is no longer offered, and a call is refused with the reason;
//       - 48 task turns per request (SPDFMacAISubagentsTurnsPerRequest), every turn of every task in every run
//         charged to it: one run of four tasks at their full 12 turns, or two smaller runs. Each task of a run gets
//         an equal share, at most 12; a run is refused when that share would be under 2 turns;
//       - 12 tool calls per task (SPDFMacAISubagentsToolCallsPerTask);
//       - at most 600,000 tokens per run (SPDFMacAISubagentsTokensPerRun), split equally between its tasks, and never
//         more than the request's remaining tokens leave after keeping one equal share for the main assistant to
//         answer with. 150,000 a task when four run: twelve turns whose context grows to about 20,000 tokens over a
//         few page reads.
//   - One timeout for the whole tool (`timeout`): tasks still running are stopped and the tool returns what every
//     task has so far. Stop on the request stops every task; each task's row has Cancel for that task alone.
//   - The chat shows one step row per task, a "helper" to the person: its title, what it is doing now as the status,
//     and "Asked: " with its instructions, then what it found (or why it didn't finish), as the detail. In a request
//     that includes Friends chats (SPDFMacAIRequestContext includesFriendsChats) the main assistant may have copied a
//     friend's words into a task's instructions, and the findings can echo them, so the chat file keeps neither: the
//     rows are request-only with a stored title ("Helper") in place of the model's, and the call itself is
//     (-isRequestOnlyTool:context:), so its tasks and findings are stubbed in the saved messages too.
//   - Results: per task a status, a summary of at most 2,000 characters, and sources: document citations a tool in
//     that task really returned (so the main chat can verify and link them) and web addresses its tools returned.
#import <Foundation/Foundation.h>
#import "SPDFMacAIToolProvider.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFMacAISubagentsToolName;           // "run_subagents"
FOUNDATION_EXPORT NSString* const SPDFMacAISubagentsProviderIdentifier; // "subagents"
FOUNDATION_EXPORT const NSUInteger SPDFMacAISubagentsMaximumTasks;      // 4
FOUNDATION_EXPORT const NSUInteger SPDFMacAISubagentsToolCallsPerTask;  // 12
FOUNDATION_EXPORT const NSUInteger SPDFMacAISubagentsRunsPerRequest;    // 2
FOUNDATION_EXPORT const NSUInteger SPDFMacAISubagentsTurnsPerRequest;   // 48
FOUNDATION_EXPORT const NSUInteger SPDFMacAISubagentsTokensPerRun;      // 600,000

// The providers whose read-only tools a task may use: "reader" (SPDFMacAIIntegration's own tools), "web" and
// "python". An allowlist, not "every read-only tool": a provider joins only when someone decided its reads are safe
// to run unattended and to keep in a saved summary.
NSSet<NSString*>* SPDFMacAISubagentToolProviders(void);

@interface SPDFMacAISubagentsProvider : NSObject <SPDFMacAIToolProvider>
// Seconds before the whole tool stops its tasks and returns what they have. 180: twelve tool calls at the 5–10 s a
// model turn usually takes, with room for a web page or a Python run among them.
@property(nonatomic) NSTimeInterval timeout;
// SPDFMacAISubagentToolProviders() unless changed.
@property(nonatomic, copy) NSSet<NSString*>* taskProviders;
// SPDFMacAISubagentsTurnsPerRequest unless changed (tests use a few, rather than script 48 task turns).
@property(nonatomic) NSUInteger turnsPerRequest;
@end

NS_ASSUME_NONNULL_END
