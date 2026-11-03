#pragma once
// Comments as data, for `szpdf comments` and `szpdf comment reply|resolve` (SPDFMacSzpdf.mm): the same comments the
// reader shows, read and written where the reader keeps them. A Markdown document's live in "<title> - comments.md"
// beside it (SPDFMacMarkdownComments.h); a PDF's are annotations inside it (replies with /IRT, "resolved" as the review
// state Acrobat writes; core/spdf_comment_review.h). A PDF is changed through a staged copy that replaces the file
// only if nobody changed it meanwhile (SPDFMacAIFileTransaction.h).
//
// A comment's id is a short hash of what does not change while it lives: for Markdown its author, time and quoted
// words; for a PDF its page, place, author and text. Replying or resolving keeps it.
#import <Foundation/Foundation.h>

@class SPDFMarkdownComment;

NS_ASSUME_NONNULL_BEGIN

// "m" and 8 hex digits, from the comment's author, minute, quoted words and the words before them.
FOUNDATION_EXPORT NSString* SPDFMacAgentMarkdownCommentID(SPDFMarkdownComment* comment);
// A comment as the tool prints it: id, line, quote, headingPath, author, date (ISO 8601), status (open or resolved),
// text and replies.
FOUNDATION_EXPORT NSDictionary* SPDFMacAgentMarkdownCommentJSON(SPDFMarkdownComment* comment, NSString* identifier);

// {path, kind ("markdown" or "pdf"), commentsFile (Markdown), comments: [...]}, or nil and `error`.
FOUNDATION_EXPORT NSDictionary* _Nullable SPDFMacAgentListComments(NSString* path, NSError** error);
// Adds a reply to comment `identifier`; answers the updated comment.
FOUNDATION_EXPORT NSDictionary* _Nullable SPDFMacAgentReplyToComment(NSString* path, NSString* identifier,
                                                                     NSString* text, NSString* author,
                                                                     NSError** error);
// Marks comment `identifier` resolved (or open again); answers the updated comment.
FOUNDATION_EXPORT NSDictionary* _Nullable SPDFMacAgentResolveComment(NSString* path, NSString* identifier,
                                                                     BOOL resolved, NSString* author,
                                                                     NSError** error);

// Errors from these functions carry a stable szpdf error code (szpdf help errors) under this key.
FOUNDATION_EXPORT NSString* const SPDFMacAgentCommentsErrorCodeKey;

// A new Markdown comment, already anchored (quote, line, heading path, context; SPDFMacMarkdownComments.h), written into
// the comments file in line order; answers it with its id.
FOUNDATION_EXPORT NSDictionary* _Nullable SPDFMacAgentAddMarkdownComment(NSString* path, SPDFMarkdownComment* comment,
                                                                         NSError** error);
// A new PDF comment: a highlight on `where[@"quote"]` (which must occur once) or a note at the top of
// `where[@"page"]`; answers it with its id.
FOUNDATION_EXPORT NSDictionary* _Nullable SPDFMacAgentAddPDFComment(NSString* path, NSDictionary* where, NSString* text,
                                                                    NSString* author, NSError** error);

NS_ASSUME_NONNULL_END
