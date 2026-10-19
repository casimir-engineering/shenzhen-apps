#pragma once
#import <Foundation/Foundation.h>
// Pure context-budget and compaction math for the document assistant. No I/O.
// A transcript may contain {"role":"compaction","local":true,"summary":...}: the
// model sees that summary instead of every message before it. Earlier messages
// stay in the saved chat for display, search and citation checks.
FOUNDATION_EXPORT const NSUInteger SPDFMacAIDefaultContextTokens;
FOUNDATION_EXPORT const NSUInteger SPDFMacAIOutputReserveTokens;
// The usable model window: the catalog value when known, otherwise a large default.
NSUInteger SPDFMacAIContextTokens(NSUInteger modelContextTokens);
// Tokens available for the request: window minus the reply reserve.
NSUInteger SPDFMacAIInputBudget(NSUInteger contextTokens);
// Automatic compaction starts above this estimate.
NSUInteger SPDFMacAICompactionThreshold(NSUInteger inputBudget);
// Largest single tool result kept verbatim, in UTF-8 bytes.
NSUInteger SPDFMacAIToolResultLimit(NSUInteger inputBudget);
// Conservative estimate (about 3 UTF-8 bytes per token, page images counted flat).
NSUInteger SPDFMacAIEstimateTokens(id JSONValue);
NSUInteger SPDFMacAIEstimateMessageTokens(NSDictionary* message);
// Index of the first message the model still sees verbatim, and the summary that precedes it.
NSUInteger SPDFMacAICompactionStart(NSArray<NSDictionary*>* messages);
NSString* SPDFMacAICompactionSummary(NSArray<NSDictionary*>* messages);
// Where to cut so that messages from the cut onward fit `keepTokens`. Cuts land only
// on user turns (or, when one turn alone is too large, on an assistant step), never
// between a tool call and its result. NSNotFound when nothing can be summarized.
NSUInteger SPDFMacAICompactionCut(NSArray<NSDictionary*>* messages, NSUInteger keepTokens);
// Manual compaction keeps the latest user turn verbatim.
NSUInteger SPDFMacAIManualCompactionCut(NSArray<NSDictionary*>* messages);
// The summarizer's input: the previous summary plus messages [start, cut), with
// bulky tool results clipped so the request fits `maxTokens`. nil if it cannot fit.
NSString* SPDFMacAICompactionInput(NSArray<NSDictionary*>* messages, NSUInteger cut, NSUInteger maxTokens);
// The transcript after compaction: a marker at `cut`, and summarized tool results
// reduced to their citations so the saved chat stays small and links stay verifiable.
NSArray<NSDictionary*>* SPDFMacAICompactedMessages(NSArray<NSDictionary*>* messages, NSUInteger cut, NSString* summary);
