#pragma once
// What the web tools say: their definitions and results for the model, and the step rows' text for the person
// (SPDFMacAIWebToolProvider.h). Pure.
#import <Foundation/Foundation.h>
#import "SPDFMacAIWebFetcher.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFMacAIWebSearchToolName; // web_search
FOUNDATION_EXPORT NSString* const SPDFMacAIWebPageToolName;   // open_page
// The longest part of a page's text one open_page result carries, in UTF-8 bytes. The chat refuses any tool result
// over 100,000 bytes of JSON, so a 200 KB page is read in parts (next_start).
FOUNDATION_EXPORT const NSUInteger SPDFMacAIWebPagePartBytes;

NSArray<NSDictionary*>* SPDFMacAIWebToolDefinitions(void);
// {notice, query, results}.
NSDictionary* SPDFMacAIWebSearchToolResult(NSString* query, NSArray<NSDictionary*>* results);
// {notice, url, title, text, start, next_start?, truncated, links?, requested_url?}: the part of the page's text that
// starts at `start` (a UTF-16 offset, as next_start gives it), its links with the first part only.
NSDictionary* SPDFMacAIWebPageToolResult(SPDFMacAIWebPage* page, NSUInteger start);

// Step row text, read by the person using the chat. A search's detail is its query; a page's detail is only its
// redirect and length notes, empty when it has neither.
NSString* SPDFMacAIWebSearchStepDetail(NSString* query);
NSString* SPDFMacAIWebSearchStepStatus(NSUInteger count);
NSString* SPDFMacAIWebPageStepDetail(SPDFMacAIWebPage* page);
// The step's rows (SPDFMacAIActivityLinksKey): [{url, title, host}], at most 16. A search's https results come first,
// then its http results, which the chat lists after the links as not secure, never as links; a page has its one https
// row. The title falls back to the host.
NSArray<NSDictionary*>* SPDFMacAIWebSearchStepLinks(NSArray<NSDictionary*>* results);
NSArray<NSDictionary*>* SPDFMacAIWebPageStepLinks(SPDFMacAIWebPage* page);
// A site's name as step rows and titles show it: the address's host in lower case, without "www." or a final dot.
NSString* SPDFMacAIWebShownHost(NSString* link);
// The status of a search or page that did not complete.
NSString* SPDFMacAIWebStatusForError(NSError* _Nullable error, BOOL search);

NS_ASSUME_NONNULL_END
