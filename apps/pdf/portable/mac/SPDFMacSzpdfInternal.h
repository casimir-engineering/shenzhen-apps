#pragma once
// szpdf's parts (SPDFMacSzpdf.h), shared between its files and its tests (mac/tests/SPDFMacSzpdfTests.mm).
//
// - SPDFMacSzpdfHelp.mm: the command table behind parsing, `help` and `schema`, and the error codes.
// - SPDFMacSzpdfDocument.mm: a document read and laid out in the tool's own process, as the reader lays it out, for
//   the commands that need no window (headings, find, page pictures, export-pdf, comment add, check).
// - SPDFMacSzpdfCheck.mm, SPDFMacSzpdfFeatures.mm: `check` and `features`.
// - SPDFMacSzpdfChanges.mm: what changed between two versions' text, and between two listings of comments, and the
//   wait for the next change (event-driven: file system events, no polling).
#import <Foundation/Foundation.h>

@class SPDFMarkdownComment;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Answers

// {"ok": false, "error": {"code": code, "message": message}} plus `extra`.
FOUNDATION_EXPORT NSDictionary* SPDFMacSzpdfFailure(NSString* code, NSString* message,
                                                    NSDictionary* _Nullable extra);
// An answer in its final shape: "ok" added, and an "error" given as text (with "errorCode" beside it, as the reader
// answers) turned into {"code", "message"}.
FOUNDATION_EXPORT NSDictionary* SPDFMacSzpdfNormalized(NSDictionary* answer);
// ISO 8601 with seconds and the local offset: "2026-11-03T05:40:28+08:00".
FOUNDATION_EXPORT NSString* _Nullable SPDFMacSzpdfISODate(NSDate* _Nullable date);
FOUNDATION_EXPORT NSDate* _Nullable SPDFMacSzpdfParseISODate(NSString* text);

#pragma mark - At run time (SPDFMacSzpdf.mm, SPDFMacSzpdfComments.mm)

// Prints the answer in its final shape; the exit status (0 when ok).
FOUNDATION_EXPORT int SPDFMacSzpdfFinish(NSDictionary* answer);
// Every running reader that answers `state`, by pid.
FOUNDATION_EXPORT NSDictionary<NSNumber*, NSDictionary*>* SPDFMacSzpdfReaders(void);
FOUNDATION_EXPORT NSDictionary* SPDFMacSzpdfSend(pid_t pid, NSDictionary* request, NSTimeInterval timeout);
// The reader a request about `path` goes to, starting the app (with no document, behind) when none runs; never a
// Launch Services open of the document. 0 and `failure` when there is none.
FOUNDATION_EXPORT pid_t SPDFMacSzpdfReader(NSString* path, BOOL front, NSTimeInterval timeout,
                                           NSDictionary* _Nullable* _Nonnull failure);
FOUNDATION_EXPORT int SPDFMacSzpdfVersions(NSDictionary* command);
// comments, comment add, reply and resolve.
FOUNDATION_EXPORT int SPDFMacSzpdfComments(NSDictionary* command);

#pragma mark - Commands as data (SPDFMacSzpdfHelp.mm)

// One dictionary per command: name ("open", "comment add"), args (positional names; a trailing "?" is optional),
// flags, valued (options taking a value), usage, summary, options [[flag, text]], example, fields [[name, text]].
FOUNDATION_EXPORT NSArray<NSDictionary*>* SPDFMacSzpdfCommandTable(void);
FOUNDATION_EXPORT NSDictionary* _Nullable SPDFMacSzpdfCommandNamed(NSString* name);
FOUNDATION_EXPORT NSArray<NSArray<NSString*>*>* SPDFMacSzpdfErrorCodes(void);
// The overview (nil), one command's full help, or "errors".
FOUNDATION_EXPORT NSString* SPDFMacSzpdfHelpText(NSString* _Nullable name);
// The usage line and where to read more, printed after a usage mistake.
FOUNDATION_EXPORT NSString* SPDFMacSzpdfUsageText(NSString* _Nullable name);
FOUNDATION_EXPORT NSDictionary* SPDFMacSzpdfSchema(NSString* _Nullable name);

#pragma mark - A document laid out in this process (SPDFMacSzpdfDocument.mm)

@interface SPDFMacSzpdfDocument : NSObject
// nil and `failure` (an SPDFMacSzpdfFailure answer) when it cannot be read.
+ (nullable instancetype)documentAtPath:(NSString*)path failure:(NSDictionary* _Nullable* _Nullable)failure;
@property(nonatomic, readonly, copy) NSString* path;
@property(nonatomic, readonly) BOOL markdown;
@property(nonatomic, readonly) NSUInteger pageCount;
// level, title, path, page, line (Markdown, else null), duplicate.
@property(nonatomic, readonly, copy) NSArray<NSDictionary*>* headings;
// Markdown only.
@property(nonatomic, readonly, copy, nullable) NSString* source;
@property(nonatomic, readonly, copy, nullable) NSString* renderedText;
@property(nonatomic, readonly, nullable) id model;    // SPDFMarkdownDocumentModel
@property(nonatomic, readonly, nullable) id rendered; // SPDFMarkdownRenderedDocument
@property(nonatomic, readonly, nullable) id plan;     // SPDFMarkdownPaginationPlan
// {matches: [{page, line, headingPath, text, context}], count}.
- (NSDictionary*)find:(NSString*)text caseSensitive:(BOOL)caseSensitive limit:(NSUInteger)limit;
// Writes page `page` (from 1) as a PNG at `scale` pixels per point, optionally only `region` (x, y, w, h in points
// from the page's top left). The answer, or a failure.
- (NSDictionary*)writePage:(NSUInteger)page toPNG:(NSString*)output scale:(double)scale
                    region:(nullable NSArray<NSNumber*>*)region;
- (NSDictionary*)writePDF:(NSString*)output;
// Markdown: a new comment anchored to the words of a source line, a quote or a heading (the reader's own anchoring),
// or a failure in `failure`.
- (nullable SPDFMarkdownComment*)commentAt:(NSDictionary*)where failure:(NSDictionary* _Nullable* _Nullable)failure;
// The page (from 1) a rendered range is on; 0 when unknown.
- (NSUInteger)pageForRenderedRange:(NSRange)range;
// {line, headingPath, context} of a rendered range.
- (NSDictionary*)placeOfRenderedRange:(NSRange)range;
@end

#pragma mark - check and features

FOUNDATION_EXPORT NSDictionary* SPDFMacSzpdfCheck(SPDFMacSzpdfDocument* document);
// "md", "pdf" or "all".
FOUNDATION_EXPORT NSDictionary* SPDFMacSzpdfFeatures(NSString* format);

#pragma mark - Changes (SPDFMacSzpdfChanges.mm)

// Changed blocks between two texts' lines: kind (added, removed, changed), old/new {from, to} (lines from 1; for an
// added block old.from is the line it comes after... see the file), before, after.
FOUNDATION_EXPORT NSArray<NSDictionary*>* SPDFMacSzpdfDiffLines(NSArray<NSString*>* before, NSArray<NSString*>* after);
// The blocks between two versions' files: Markdown and text by source line, PDFs by the text of their pages (each
// block then also gives oldPages/newPages). nil and `failure` when a file cannot be read.
FOUNDATION_EXPORT NSArray<NSDictionary*>* _Nullable SPDFMacSzpdfVersionBlocks(NSString* older, NSString* newer,
                                                                             NSDictionary* _Nullable* _Nullable failure);
// What differs between two comment listings (the "comments" arrays szpdf prints): added, reply, edited, resolved,
// reopened, removed. With `since`, comments and replies in `after` dated later count as new even when `before` has
// them.
FOUNDATION_EXPORT NSArray<NSDictionary*>* SPDFMacSzpdfCommentChanges(NSArray<NSDictionary*>* before,
                                                                    NSArray<NSDictionary*>* after,
                                                                    NSDate* _Nullable since);
// Waits, on file system events for the document and its folder, until its comments change from what they are now
// (or something is dated after `since`), then calls `done` once on `queue` with {path, changes, timedOut}.
FOUNDATION_EXPORT void SPDFMacSzpdfWatchComments(NSString* path, NSDate* _Nullable since, NSTimeInterval timeout,
                                                 dispatch_queue_t queue, void (^done)(NSDictionary* answer));

#pragma mark - Annotate's commands and operation schema (SPDFMacSzpdfAnnotateCommands.mm)

// `szpdf annotate ...` and `szpdf canvas ...` read their own command lines: an operation's flags are its arguments,
// typed by the operation's schema (spdf_paint_schema()), so the general parser never sees them.
FOUNDATION_EXPORT BOOL SPDFMacSzpdfIsAnnotateCommand(NSArray<NSString*>* arguments);
// {"command": "annotate", target (a real path or a tab id), ops [...], script?, state?, timeout},
// {"command": "annotate-schema", op?}, {"command": "canvas-new", width?, height?, background?, front, timeout} or
// {"command": "help", topic}; nil and a usage `error` (userInfo "command") otherwise.
FOUNDATION_EXPORT NSDictionary* _Nullable SPDFMacSzpdfParseAnnotateArguments(NSArray<NSString*>* arguments,
                                                                            NSString* directory, NSError** error);
// The two commands' rows for SPDFMacSzpdfCommandTable (also declared in SPDFMacAnnotateAgents.h). A row's "more" is
// text help prints after the options (the operation list).
FOUNDATION_EXPORT NSArray<NSDictionary*>* SPDFMacSzpdfAnnotateCommandRows(void);
// `szpdf annotate schema [op]`: the whole schema, or one operation's with the shared $defs.
FOUNDATION_EXPORT NSDictionary* SPDFMacSzpdfAnnotateSchemaAnswer(NSString* _Nullable op);

// spdf_paint_schema() as Foundation objects, parsed once; the operation names in § 6 order; one operation's schema
// (nil when unknown); a property with its "$ref" resolved against "$defs".
FOUNDATION_EXPORT NSDictionary* SPDFAnnotateSchemaObject(void);
FOUNDATION_EXPORT NSArray<NSString*>* SPDFAnnotateOperationNames(void);
FOUNDATION_EXPORT NSDictionary* _Nullable SPDFAnnotateOperationSchema(NSString* _Nullable name);
FOUNDATION_EXPORT NSDictionary* SPDFAnnotateResolvedProperty(NSDictionary* property);
// Every operation on one line, "name {argument*: type, ...} summary", and the shared types: the assistant's reference.
FOUNDATION_EXPORT NSString* SPDFAnnotateOperationReference(void);
// "tab-<pid>-<n>" (SPDFAnnotateTabIdentifier in SPDFMacAnnotateAgents.h).
FOUNDATION_EXPORT BOOL SPDFAnnotateIsTabIdentifier(NSString* _Nullable text);
// "path" and "out" made absolute against `directory`.
FOUNDATION_EXPORT NSDictionary* SPDFAnnotateAbsoluteArguments(NSDictionary* op, NSString* directory);

NS_ASSUME_NONNULL_END
