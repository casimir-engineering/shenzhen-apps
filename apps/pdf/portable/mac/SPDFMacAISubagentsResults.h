#pragma once
// Pure pieces of run_subagents (SPDFMacAISubagents.h): reading its arguments, turning a task's answer into what the
// main assistant receives, and the words a task's row shows. No session, no app; headless tests call them directly.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Limits on what the model may ask for, refused rather than clipped so the model learns them.
FOUNDATION_EXPORT const NSUInteger SPDFMacAISubagentTitleLimit;        // 80 characters
FOUNDATION_EXPORT const NSUInteger SPDFMacAISubagentInstructionsLimit; // 4,000 characters
// What the main assistant receives of one task's answer.
FOUNDATION_EXPORT const NSUInteger SPDFMacAISubagentSummaryLimit;      // 2,000 characters
FOUNDATION_EXPORT const NSUInteger SPDFMacAISubagentSourceLimit;       // 8 sources

// The tasks in run_subagents' arguments as [{title, instructions}], titles on one line; or nil and *refusal, a
// sentence for the model saying what to fix.
NSArray<NSDictionary<NSString*, NSString*>*>* _Nullable SPDFMacAISubagentTasks(id _Nullable arguments,
                                                                               NSString* _Nullable* _Nullable refusal);

// One task's answer as the main assistant receives it: {summary, sources}. `chat` is the task session's chat.
//   - summary: the answer, clipped; a document link whose citation no tool in `chat` returned, and any other link no
//     tool result mentions, keeps its text but loses its address, so the main assistant cannot pass on an invented
//     source as a link.
//   - sources: [{title, citation}] for document citations (the key SPDFMacAIChatContainsCitation looks for, so the
//     main chat verifies them like its own tools' citations) and [{title, url}] for web addresses, in order, unique.
NSDictionary<NSString*, id>* SPDFMacAISubagentFindings(NSString* _Nullable answer, NSDictionary* _Nullable chat);

// `text` cut to at most `limit` characters, the last one an ellipsis, never inside an emoji or accented letter.
NSString* SPDFMacAISubagentClipped(NSString* text, NSUInteger limit);
// Markdown links reduced to their text, for a row's plain-text detail.
NSString* SPDFMacAISubagentPlainText(NSString* _Nullable markdown);

// The tool a task's session is running now, read from its messages: the call after the last answered one in the
// newest assistant turn. nil when it is not running a tool.
NSString* _Nullable SPDFMacAISubagentCurrentTool(NSArray* _Nullable messages);
// What a task's row says while that tool runs ("Searching documents…"), for the person watching.
NSString* SPDFMacAISubagentStepText(NSString* _Nullable tool);
// What the main chat's heading says while a run's parts work: "Working on 3 parts…", then "Working on 3 parts,
// 1 finished…" as each ends, however it ends (its row says how).
NSString* SPDFMacAISubagentProgressText(NSUInteger parts, NSUInteger finished);
// One sentence for the main assistant's prompt when the person's message itself points at work that splits into
// parts: two or more files on its chips (`documents`, their names as the chips show them), or wording that asks to
// compare or go through several documents ("compare", "each document", "所有文件"). nil otherwise. A pattern match,
// no model call, and a hint the model weighs, never a decision: "compare page 2 with page 3" matches too.
NSString* _Nullable SPDFMacAISubagentSplitHint(NSString* _Nullable text, NSArray<NSString*>* documents);
// Why a task didn't finish, as one short line under what it was asked: the problem's first sentence, clipped. The
// session's errors are written for a person but some end in advice for the main chat ("Start a new chat"), which
// would be wrong under a helper. nil when there is nothing to say.
NSString* _Nullable SPDFMacAISubagentProblemLine(NSString* _Nullable problem);

NS_ASSUME_NONNULL_END
