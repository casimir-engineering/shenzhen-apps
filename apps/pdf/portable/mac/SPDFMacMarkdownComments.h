#pragma once
// Comments on Markdown documents. A Markdown file has nowhere to keep comments that most viewers show: an HTML
// comment is hidden everywhere, CriticMarkup's {>> <<} shows as raw braces on GitHub, and either would edit the
// owner's document. So the comments live beside it in "<title> - comments.md", a readable Markdown file for someone
// who never opens the app, and the app reads them back from it.
//
// A comment is anchored by the words it was made on (as the reader sees them, not the Markdown source) plus the
// heading path and line it was under, so small edits around the passage do not lose it. A comment whose words are
// gone stays, listed under "Unplaced". Foundation only: the file format and the anchoring are tested headlessly.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMarkdownComment : NSObject
@property(nonatomic, copy) NSString* author;
@property(nonatomic, copy) NSString* text;
@property(nonatomic, copy, nullable) NSDate* date;
// The commented words as rendered, whitespace collapsed.
@property(nonatomic, copy) NSString* quote;
// Display form, outermost first: @[@"## Setup", @"### Wiring"].
@property(nonatomic, copy) NSArray<NSString*>* headingPath;
// 1-based line in the Markdown source; 0 when unknown.
@property(nonatomic) NSInteger line;
// The rest of the passage around the quote, as written to the file ("…" marks a cut).
@property(nonatomic, copy) NSString* contextBefore;
@property(nonatomic, copy) NSString* contextAfter;
// Marked done. Written as " · Resolved" at the end of the comment's own byline ("**Raph** · 2026-11-01 15:20 ·
// Resolved"), never on a reply's.
@property(nonatomic) BOOL resolved;
// Range in the rendered document; location NSNotFound while the passage is not found.
@property(nonatomic) NSRange renderedRange;
@property(nonatomic, readonly, getter=isPlaced) BOOL placed;
@end

// "<dir>/<title> - comments.md" for "<dir>/<title>.md".
FOUNDATION_EXPORT NSString* SPDFMarkdownCommentsFilePath(NSString* documentPath);
// YES for a path that is itself a comments file (so it is never given comments of its own).
FOUNDATION_EXPORT BOOL SPDFMarkdownIsCommentsFilePath(NSString* path);
// The file's first line, "# Comments on <document name>".
FOUNDATION_EXPORT NSString* SPDFMarkdownCommentsHeader(NSString* documentName);
// Placed comments in document order, then the unplaced ones under "## Unplaced".
FOUNDATION_EXPORT NSString* SPDFMarkdownCommentsFileText(NSString* documentName,
                                                         NSArray<SPDFMarkdownComment*>* comments);
FOUNDATION_EXPORT NSArray<SPDFMarkdownComment*>* SPDFMarkdownCommentsParseFile(NSString* text);
// Document order: placed by rendered position, unplaced after them by line.
FOUNDATION_EXPORT NSArray<SPDFMarkdownComment*>* SPDFMarkdownCommentsSorted(NSArray<SPDFMarkdownComment*>* comments);

// Maps between the Markdown source and its rendered text. Built once per render; cheap to query.
@interface SPDFMarkdownCommentAnchors : NSObject
- (instancetype)initWithSource:(NSString*)source rendered:(NSString*)rendered NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// A new comment on `range` of the rendered text: sets quote, line, heading path, context and renderedRange.
// NO when the range holds no words.
- (BOOL)anchorComment:(SPDFMarkdownComment*)comment toRenderedRange:(NSRange)range;
// Finds the comment's words again after a (re)render. Returns YES when line, path, context or placement changed.
- (BOOL)placeComment:(SPDFMarkdownComment*)comment;
// The rendered block (paragraph, list item, table row) around `location`, for a comment made without a selection.
- (NSRange)blockRangeAtRenderedLocation:(NSUInteger)location;
@end

NS_ASSUME_NONNULL_END
