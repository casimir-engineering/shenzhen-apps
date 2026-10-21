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
// A page whose HTML is nearly empty also gets a note that it shows its content with scripts, and document_links: its
// links that look like PDFs or datasheets.
NSDictionary* SPDFMacAIWebPageToolResult(SPDFMacAIWebPage* page, NSUInteger start);
// {notice, url, title, kind: "pdf", page_count, pages: [{page, text, scanned?, truncated?}], next_page?, truncated?,
// requested_url?, note?} from SPDFMacAIWebDocumentPages' result.
NSDictionary* SPDFMacAIWebDocumentToolResult(SPDFMacAIWebPage* page, NSDictionary* pages);
// {notice, url, title, snippet}: a search result's excerpt, given when the page itself could not be read.
NSDictionary* SPDFMacAIWebExcerptResult(NSDictionary* searchResult);
// HTML with almost no readable text: what it shows comes from scripts.
BOOL SPDFMacAIWebPageIsScripted(SPDFMacAIWebPage* page);
// The page's links that look like PDFs or datasheets, at most 20: [{text, url}].
NSArray<NSDictionary*>* SPDFMacAIWebDocumentLinks(SPDFMacAIWebPage* page);

// Step row text, read by the person using the chat. A search's detail is its query; a page's detail is only its
// redirect, its page count when it is a PDF and its length note, empty when it has none.
NSString* SPDFMacAIWebSearchStepDetail(NSString* query);
NSString* SPDFMacAIWebSearchStepStatus(NSUInteger count);
NSString* SPDFMacAIWebPageStepDetail(SPDFMacAIWebPage* page);
// An opened page's status: nil, or that a page built by scripts had almost nothing to read, and whether a PDF it links
// to can be opened instead.
NSString* _Nullable SPDFMacAIWebPageStepStatus(SPDFMacAIWebPage* page);
// The step's rows (SPDFMacAIActivityLinksKey): [{url, title, host}], at most 16. A search's https results come first,
// then its http results, which the chat lists after the links as not secure, never as links; a page has its one https
// row, and a PDF a second one, "Open in ShenzhenPDF" (SPDFMacAIWebDocumentLink). The title falls back to the host.
NSArray<NSDictionary*>* SPDFMacAIWebSearchStepLinks(NSArray<NSDictionary*>* results);
NSArray<NSDictionary*>* SPDFMacAIWebPageStepLinks(SPDFMacAIWebPage* page);
// A site's name as step rows and titles show it: the address's host in lower case, without "www." or a final dot.
NSString* SPDFMacAIWebShownHost(NSString* link);
// The status of a search that did not complete.
NSString* SPDFMacAIWebStatusForError(NSError* _Nullable error, BOOL search);
// The status of a page that did not open, for the person reading the chat: what happened on `site` (the shown host),
// then what the assistant does next: use the search result's summary when `usingExcerpt`, else carry on without it.
NSString* SPDFMacAIWebPageFailureStatus(NSError* _Nullable error, NSString* site, BOOL usingExcerpt);

NS_ASSUME_NONNULL_END
