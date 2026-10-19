#pragma once
// What one sandbox run becomes: the JSON object the model reads, and what the person sees in the chat (the step's
// status, PNG images with Save, CSV tables as cards). Pure apart from the activity calls, so each rule is testable.
#import <Foundation/Foundation.h>

#import "SPDFMacAIChatActivity.h"

NS_ASSUME_NONNULL_BEGIN

// The model's result stays under this many bytes of JSON: the chat session replaces anything over 100,000 with an
// error, which would lose the output entirely.
FOUNDATION_EXPORT const NSUInteger SPDFMacAIPythonResultBudget;

// The stored notice on a step or table card from a request that read Friends chats, which keeps neither.
FOUNDATION_EXPORT NSString* const SPDFMacAIPythonFriendsNotice;
// The stored title a request-only table card keeps in place of its model-chosen file name (D4).
FOUNDATION_EXPORT NSString* const SPDFMacAIPythonStoredTableTitle;

@interface SPDFMacAIPythonPresentation : NSObject
@property(nonatomic, copy) NSDictionary* modelResult;
@property(nonatomic, copy) NSString* title;  // the finished step's title: "Ran Python", "Python run failed", …
@property(nonatomic, copy) NSString* state;  // SPDFMacAIActivityState*
@property(nonatomic, copy) NSString* status; // the step's status line, for the person
@property(nonatomic, copy) NSString* detail; // the step's expanded detail: the code alone, for the code box
// What it printed (stdout), clipped, for the step's plain output block; empty when it printed nothing.
@property(nonatomic, copy) NSString* output;
// A line for the person under the output, or nil: charts drawn but withheld in a request with Friends chats.
@property(nonatomic, copy, nullable) NSString* note;
@end

// Presents a helper result (status "completed", "failed" or "stopped"; mac/python-sandbox/SPDFPythonSandbox.h).
// Images and tables are added to `activity`; with `requestOnly` (the request read Friends chats) tables are kept only
// for the request and images are not shown at all, because a saved picture cannot be reduced to a stub.
SPDFMacAIPythonPresentation* SPDFMacAIPythonPresent(NSDictionary* result, NSString* code,
                                                    id<SPDFMacAIActivityReporting> _Nullable activity,
                                                    BOOL requestOnly);

// The step's status line for a helper result: "Finished in 0.4 s", "Stopped: it ran for more than 30 s", …
NSString* SPDFMacAIPythonStatusLine(NSDictionary* result);

// RFC 4180 rows (quoted fields, doubled quotes, newlines inside quotes) split on `separator`, at most `maxRows`
// rows of `maxColumns` cells; `totalRows` counts every row.
NSArray<NSArray<NSString*>*>* SPDFMacAIPythonParseTable(NSString* text, unichar separator, NSUInteger maxRows,
                                                        NSUInteger maxColumns, NSUInteger* _Nullable totalRows);

// A Markdown table of `rows` (the first is the header) within `budget` characters, dropping rows that do not fit.
// Pipes and line breaks inside cells are escaped so a cell can never end the table early.
NSString* SPDFMacAIPythonMarkdownTable(NSArray<NSArray<NSString*>*>* rows, NSUInteger budget,
                                       NSUInteger* _Nullable shownRows);

// `text` cut to at most `limit` characters, at a character boundary, with "…" when cut.
NSString* SPDFMacAIPythonClip(NSString* text, NSUInteger limit);

NS_ASSUME_NONNULL_END
