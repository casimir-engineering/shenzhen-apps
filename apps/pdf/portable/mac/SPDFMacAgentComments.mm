// Comments as data (SPDFMacAgentComments.h).
#import "SPDFMacAgentComments.h"
#import "SPDFMacAIFileTransaction.h"
#import "SPDFMacMarkdownComments.h"
#import "SPDFMacSearchFileCache.h"

#import <CommonCrypto/CommonDigest.h>

#include <vector>

#include "shenzhen_pdf_core.h"
#include "spdf_comment_dates.h"
#include "spdf_outline.h"

NSString* const SPDFMacAgentCommentsErrorCodeKey = @"szpdfCode";

static NSError* CodedError(NSString* code, NSString* message) {
    return [NSError errorWithDomain:@"ShenzhenPDF.AgentComments" code:1
                           userInfo:@{NSLocalizedDescriptionKey : message, SPDFMacAgentCommentsErrorCodeKey : code}];
}

static NSError* CommentsError(NSString* message) { return CodedError(@"failed", message); }

static NSString* ShortHash(NSString* prefix, NSString* text) {
    NSData* data = [text dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return [NSString stringWithFormat:@"%@%02x%02x%02x%02x", prefix, digest[0], digest[1], digest[2], digest[3]];
}

// Ids made unique within one listing: a second comment with the same hash gets "-2", and so on.
static NSString* Unique(NSString* identifier, NSMutableDictionary<NSString*, NSNumber*>* seen) {
    NSInteger count = seen[identifier].integerValue + 1;
    seen[identifier] = @(count);
    return count == 1 ? identifier : [NSString stringWithFormat:@"%@-%ld", identifier, (long)count];
}

// "2026-11-03T05:40:28+08:00": seconds and the local offset, as the comments file keeps them.
static NSString* ISODate(NSDate* date) {
    static NSISO8601DateFormatter* formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      formatter = [NSISO8601DateFormatter new];
      formatter.timeZone = NSTimeZone.localTimeZone;
      formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return date ? [formatter stringFromDate:date] : nil;
}

static NSString* MinuteText(NSDate* date) {
    return date ? [NSString stringWithFormat:@"%.0f", floor(date.timeIntervalSince1970 / 60)] : @"";
}

#pragma mark - Markdown

NSString* SPDFMacAgentMarkdownCommentID(SPDFMarkdownComment* comment) {
    return ShortHash(@"m", [@[ comment.author ?: @"", MinuteText(comment.date), comment.quote ?: @"",
                               comment.contextBefore ?: @"" ] componentsJoinedByString:@"\u001f"]);
}

// "## Setup" -> "Setup": the file keeps a heading's marks so a reader sees its level; the data does not need them.
static NSString* HeadingTitle(NSString* heading) {
    NSUInteger i = 0;
    while (i < heading.length && [heading characterAtIndex:i] == '#') i++;
    return [[heading substringFromIndex:i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

NSDictionary* SPDFMacAgentMarkdownCommentJSON(SPDFMarkdownComment* comment, NSString* identifier) {
    NSMutableArray* path = [NSMutableArray array];
    for (NSString* heading in comment.headingPath) [path addObject:HeadingTitle(heading)];
    NSMutableArray* replies = [NSMutableArray array];
    for (SPDFMarkdownCommentReply* reply in comment.replies)
        [replies addObject:@{@"author" : reply.author ?: @"", @"date" : ISODate(reply.date) ?: [NSNull null],
                             @"text" : reply.text ?: @""}];
    return @{
        @"id" : identifier,
        @"line" : comment.line > 0 ? @(comment.line) : [NSNull null],
        @"quote" : comment.quote ?: @"",
        @"headingPath" : path,
        @"author" : comment.author ?: @"",
        @"date" : ISODate(comment.date) ?: [NSNull null],
        @"status" : comment.resolved ? @"resolved" : @"open",
        @"text" : comment.text ?: @"",
        @"replies" : replies,
    };
}

// The comments file's comments, in its order. Those above "## Unplaced" are marked placed (in file order) so that
// writing the file back keeps them where they were: the tool does not lay the document out to find them again, and
// the reader re-anchors them the next time it shows the document.
static NSMutableArray<SPDFMarkdownComment*>* ReadMarkdownComments(NSString* file) {
    NSString* text = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSRange unplaced = [text rangeOfString:@"\n## Unplaced\n"];
    NSString* placedText = unplaced.location == NSNotFound ? text : [text substringToIndex:unplaced.location];
    NSMutableArray<SPDFMarkdownComment*>* comments = [SPDFMarkdownCommentsParseFile(placedText) mutableCopy];
    for (NSUInteger i = 0; i < comments.count; i++) comments[i].renderedRange = NSMakeRange(i, 0);
    if (unplaced.location != NSNotFound)
        [comments addObjectsFromArray:SPDFMarkdownCommentsParseFile([text substringFromIndex:unplaced.location])];
    return comments;
}

static NSArray<NSString*>* MarkdownIDs(NSArray<SPDFMarkdownComment*>* comments) {
    NSMutableArray* ids = [NSMutableArray array];
    NSMutableDictionary* seen = [NSMutableDictionary dictionary];
    for (SPDFMarkdownComment* comment in comments) [ids addObject:Unique(SPDFMacAgentMarkdownCommentID(comment), seen)];
    return ids;
}

static NSDictionary* ChangeMarkdownComment(NSString* path, NSString* identifier, NSError** error,
                                           void (^change)(SPDFMarkdownComment* comment)) {
    NSString* file = SPDFMarkdownCommentsFilePath(path);
    NSMutableArray<SPDFMarkdownComment*>* comments = ReadMarkdownComments(file);
    NSUInteger index = [MarkdownIDs(comments) indexOfObject:identifier];
    if (index == NSNotFound) {
        if (error) *error = CodedError(@"comment-not-found", [NSString stringWithFormat:@"No comment %@ on this document; "
                                                                                       @"szpdf comments lists them.", identifier]);
        return nil;
    }
    change(comments[index]);
    NSString* text = SPDFMarkdownCommentsFileText(path.lastPathComponent, comments);
    if (![text writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:error]) return nil;
    [NSNotificationCenter.defaultCenter postNotificationName:SPDFMarkdownCommentsDidChangeNotification object:path];
    return SPDFMacAgentMarkdownCommentJSON(comments[index], identifier);
}

#pragma mark - PDF

typedef struct {
    spdf_comments comments;
    std::vector<NSString*> ids;
} PDFComments;

static BOOL LoadPDFComments(spdf_document* doc, PDFComments& out, char* message, size_t length) {
    if (!spdf_load_comments(doc, &out.comments, message, length)) return NO;
    NSMutableDictionary* seen = [NSMutableDictionary dictionary];
    for (int i = 0; i < out.comments.count; i++) {
        spdf_comment_item item = out.comments.items[i];
        NSString* key = [NSString stringWithFormat:@"%d\u001f%.0f,%.0f,%.0f,%.0f\u001f%s\u001f%s", item.page_index,
                                                   item.bounds.x0, item.bounds.y0, item.bounds.x1, item.bounds.y1,
                                                   item.author ?: "", item.text ?: ""];
        out.ids.push_back(Unique(ShortHash(@"p", key), seen));
    }
    return YES;
}

static NSString* PDFQuote(spdf_document* doc, spdf_comment_item item) {
    const char* types[] = {"Highlight", "Underline", "StrikeOut", "Squiggly"};
    BOOL marksText = NO;
    for (const char* type : types) marksText |= item.type && strcmp(item.type, type) == 0;
    if (!marksText) return @"";
    char* text = NULL;
    char message[256];
    if (!spdf_page_text_in_rects(doc, item.page_index, &item.bounds, 1, &text, message, sizeof(message))) return @"";
    NSString* quote = text ? @(text) : @"";
    spdf_free_string(text);
    NSArray* words = [quote componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]]
        componentsJoinedByString:@" "];
}

static NSArray<NSString*>* PDFHeadingPath(spdf_outline* outline, int page) {
    NSMutableArray<NSString*>* path = [NSMutableArray array];
    std::vector<int> levels;
    for (int i = 0; outline && i < outline->count; i++) {
        if (outline->items[i].page_index > page || outline->items[i].page_index < 0) continue;
        while (!levels.empty() && levels.back() >= outline->items[i].level) {
            levels.pop_back();
            [path removeLastObject];
        }
        levels.push_back(outline->items[i].level);
        [path addObject:@(outline->items[i].title ?: "")];
    }
    return path;
}

static NSDictionary* PDFCommentJSON(spdf_document* doc, PDFComments& all, int index, spdf_outline* outline) {
    spdf_comment_item item = all.comments.items[index];
    NSMutableArray* replies = [NSMutableArray array];
    for (int i = 0; i < all.comments.count; i++) {
        spdf_comment_item reply = all.comments.items[i];
        if (reply.in_reply_to != item.index) continue;
        [replies addObject:@{@"author" : @(reply.author ?: ""), @"text" : @(reply.text ?: ""),
                             @"date" : reply.modified > 0 ? ISODate([NSDate dateWithTimeIntervalSince1970:reply.modified])
                                                          : [NSNull null]}];
    }
    return @{
        @"id" : all.ids[(size_t)index],
        @"page" : @(item.page_index + 1),
        @"type" : @(item.type ?: ""),
        @"quote" : PDFQuote(doc, item),
        @"headingPath" : PDFHeadingPath(outline, item.page_index),
        @"author" : @(item.author ?: ""),
        @"date" : item.modified > 0 ? ISODate([NSDate dateWithTimeIntervalSince1970:item.modified]) : [NSNull null],
        @"status" : item.resolved ? @"resolved" : @"open",
        @"text" : @(item.text ?: ""),
        @"replies" : replies,
    };
}

static spdf_document* OpenPDF(NSString* path, NSError** error) {
    char message[1024] = {};
    spdf_document* doc = spdf_open(path.fileSystemRepresentation, message, sizeof(message));
    if (doc && spdf_is_password_protected(doc)) {
        spdf_close(doc);
        doc = NULL;
        snprintf(message, sizeof(message), "This PDF is protected by a password; open it in ShenzhenPDF instead.");
    }
    if (!doc && error) *error = CodedError(@"load-failed", message[0] ? @(message) : @"The PDF could not be opened.");
    return doc;
}

// The listing of one PDF: every comment that answers no other, each with its replies.
static NSDictionary* ListPDF(NSString* path, NSString* onlyID, NSError** error) {
    spdf_document* doc = OpenPDF(path, error);
    if (!doc) return nil;
    PDFComments all = {};
    char message[1024] = {};
    BOOL loaded = LoadPDFComments(doc, all, message, sizeof(message));
    spdf_outline outline = {};
    char outlineError[256];
    BOOL hasOutline = loaded && spdf_load_outline(doc, &outline, outlineError, sizeof(outlineError));
    NSMutableArray* comments = [NSMutableArray array];
    for (int i = 0; loaded && i < all.comments.count; i++)
        if (all.comments.items[i].in_reply_to < 0 && (!onlyID || [all.ids[(size_t)i] isEqualToString:onlyID]))
            [comments addObject:PDFCommentJSON(doc, all, i, hasOutline ? &outline : NULL)];
    if (hasOutline) spdf_free_outline(&outline);
    spdf_free_comments(&all.comments);
    spdf_close(doc);
    if (!loaded) {
        if (error) *error = CommentsError(message[0] ? @(message) : @"The comments could not be read.");
        return nil;
    }
    return @{@"path" : path, @"kind" : @"pdf", @"comments" : comments};
}

static NSDictionary* ChangePDFComment(NSString* path, NSString* identifier, NSError** error,
                                      BOOL (^change)(spdf_document* doc, int index, char* message, size_t length)) {
    __block BOOL found = NO;
    NSString* revision = SPDFSearchFileStamp(path);
    NSDictionary* receipt = SPDFAIMutatePDF(path, revision, nil, ^BOOL(spdf_document* doc, char* message, size_t length) {
      PDFComments all = {};
      if (!LoadPDFComments(doc, all, message, length)) return NO;
      int index = -1;
      for (int i = 0; i < all.comments.count; i++)
          if ([all.ids[(size_t)i] isEqualToString:identifier] && all.comments.items[i].in_reply_to < 0)
              index = all.comments.items[i].index;
      spdf_free_comments(&all.comments);
      found = index >= 0;
      if (!found) snprintf(message, length, "No comment %s on this document.", identifier.UTF8String);
      return found && change(doc, index, message, length);
    }, error);
    if (!receipt) {
        if (!found && error) *error = CodedError(@"comment-not-found", (*error).localizedDescription ?: @"No such comment.");
        return nil;
    }
    NSDictionary* listing = ListPDF(path, identifier, error);
    return [listing[@"comments"] firstObject] ?: @{@"id" : identifier};
}

#pragma mark - Either kind

static BOOL IsPDF(NSString* path) { return [path.pathExtension.lowercaseString isEqualToString:@"pdf"]; }

static BOOL Check(NSString* path, NSError** error) {
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || directory) {
        if (error) *error = CodedError(@"not-found", [NSString stringWithFormat:@"No document at %@.", path]);
        return NO;
    }
    if (!IsPDF(path) && SPDFMarkdownIsCommentsFilePath(path)) {
        if (error) *error = CodedError(@"unsupported", @"This is a comments file; name the document it belongs to.");
        return NO;
    }
    return YES;
}

NSDictionary* SPDFMacAgentListComments(NSString* path, NSError** error) {
    if (!Check(path, error)) return nil;
    if (IsPDF(path)) return ListPDF(path, nil, error);
    NSString* file = SPDFMarkdownCommentsFilePath(path);
    NSArray<SPDFMarkdownComment*>* comments = ReadMarkdownComments(file);
    NSArray<NSString*>* ids = MarkdownIDs(comments);
    NSMutableArray* rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < comments.count; i++) [rows addObject:SPDFMacAgentMarkdownCommentJSON(comments[i], ids[i])];
    return @{@"path" : path, @"kind" : @"markdown", @"commentsFile" : file, @"comments" : rows};
}

NSDictionary* SPDFMacAgentReplyToComment(NSString* path, NSString* identifier, NSString* text, NSString* author,
                                         NSError** error) {
    if (!Check(path, error)) return nil;
    if (!text.length) {
        if (error) *error = CommentsError(@"A reply needs text.");
        return nil;
    }
    if (IsPDF(path))
        return ChangePDFComment(path, identifier, error, ^BOOL(spdf_document* doc, int index, char* message, size_t n) {
          return spdf_add_comment_reply(doc, index, text.UTF8String, author.UTF8String, message, n);
        });
    return ChangeMarkdownComment(path, identifier, error, ^(SPDFMarkdownComment* comment) {
      SPDFMarkdownCommentReply* reply = [SPDFMarkdownCommentReply new];
      reply.author = author;
      reply.text = text;
      reply.date = NSDate.date;
      comment.replies = [comment.replies arrayByAddingObject:reply];
    });
}

NSDictionary* SPDFMacAgentResolveComment(NSString* path, NSString* identifier, BOOL resolved, NSString* author,
                                         NSError** error) {
    if (!Check(path, error)) return nil;
    if (IsPDF(path))
        return ChangePDFComment(path, identifier, error, ^BOOL(spdf_document* doc, int index, char* message, size_t n) {
          return spdf_set_comment_resolved(doc, index, resolved, author.UTF8String, message, n);
        });
    return ChangeMarkdownComment(path, identifier, error, ^(SPDFMarkdownComment* comment) {
      comment.resolved = resolved;
    });
}

#pragma mark - New comments

NSDictionary* SPDFMacAgentAddMarkdownComment(NSString* path, SPDFMarkdownComment* comment, NSError** error) {
    if (!Check(path, error)) return nil;
    NSString* file = SPDFMarkdownCommentsFilePath(path);
    NSMutableArray<SPDFMarkdownComment*>* comments = ReadMarkdownComments(file);
    // Placed among the others by its line: the reader puts it exactly where it belongs when it next lays it out.
    NSUInteger at = 0;
    while (at < comments.count && comments[at].placed && comments[at].line <= comment.line) at++;
    [comments insertObject:comment atIndex:at];
    for (NSUInteger i = 0; i < comments.count; i++)
        if (comments[i].placed || comments[i] == comment) comments[i].renderedRange = NSMakeRange(i, 0);
    NSString* text = SPDFMarkdownCommentsFileText(path.lastPathComponent, comments);
    if (![text writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        if (error) *error = CodedError(@"write-failed", [NSString stringWithFormat:@"Could not write %@.", file.lastPathComponent]);
        return nil;
    }
    [NSNotificationCenter.defaultCenter postNotificationName:SPDFMarkdownCommentsDidChangeNotification object:path];
    NSArray<NSString*>* ids = MarkdownIDs(ReadMarkdownComments(file));
    NSUInteger index = [ReadMarkdownComments(file) indexOfObjectPassingTest:^BOOL(SPDFMarkdownComment* c, NSUInteger i, BOOL* stop) {
      (void)i; (void)stop;
      return [c.quote isEqualToString:comment.quote] && [c.text isEqualToString:comment.text] &&
             [c.author isEqualToString:comment.author] && fabs([c.date timeIntervalSinceDate:comment.date]) < 1;
    }];
    return SPDFMacAgentMarkdownCommentJSON(comment, index != NSNotFound ? ids[index] : SPDFMacAgentMarkdownCommentID(comment));
}

NSDictionary* SPDFMacAgentAddPDFComment(NSString* path, NSDictionary* where, NSString* text, NSString* author,
                                        NSError** error) {
    if (!Check(path, error)) return nil;
    __block int page = -1;
    NSString* revision = SPDFSearchFileStamp(path);
    __block NSString* code = @"failed";
    NSDictionary* receipt = SPDFAIMutatePDF(path, revision, nil, ^BOOL(spdf_document* doc, char* message, size_t length) {
      int pages = spdf_page_count(doc);
      if (where[@"quote"]) {
          NSString* quote = where[@"quote"];
          spdf_rect rects[256], hit[256];
          int found = 0, count = 0;
          NSMutableArray* places = [NSMutableArray array];
          for (int p = 0; p < pages; p++) {
              int n = spdf_search_page_rects(doc, p, quote.UTF8String, rects, 256, message, length);
              if (n <= 0) continue;
              [places addObject:@(p + 1)];
              found += n;
              if (page < 0) {
                  page = p, count = n;
                  memcpy(hit, rects, sizeof(spdf_rect) * (size_t)n);
              }
          }
          // A match across lines comes as one rectangle per line, each below the last.
          BOOL oneHit = places.count == 1;
          for (int i = 1; oneHit && i < count; i++)
              oneHit = hit[i].y0 > hit[i - 1].y0 && hit[i].y0 - hit[i - 1].y1 < 2 * (hit[i - 1].y1 - hit[i - 1].y0);
          if (found == 0) {
              code = @"quote-not-found";
              snprintf(message, length, "\"%s\" is not in the PDF's text.", quote.UTF8String);
              return NO;
          }
          if (!oneHit) {
              code = @"quote-ambiguous";
              snprintf(message, length, "\"%s\" occurs more than once (pages %s); quote more words.", quote.UTF8String,
                       [places componentsJoinedByString:@", "].UTF8String);
              return NO;
          }
          return spdf_add_highlight_comment(doc, page, hit, count, text.UTF8String, author.UTF8String, message, length) &&
                 spdf_date_newest_comment(doc, page, message, length);
      }
      page = (int)[where[@"page"] integerValue] - 1;
      if (page < 0 || page >= pages) {
          code = @"page-out-of-range";
          snprintf(message, length, "The document has %d pages.", pages);
          return NO;
      }
      return spdf_add_text_comment(doc, page, 24, 24, text.UTF8String, author.UTF8String, message, length) &&
             spdf_date_newest_comment(doc, page, message, length);
    }, error);
    if (!receipt) {
        if (error) *error = CodedError(code, (*error).localizedDescription ?: @"The comment could not be added.");
        return nil;
    }
    NSDictionary* listing = ListPDF(path, nil, error);
    for (NSDictionary* comment in [listing[@"comments"] reverseObjectEnumerator])
        if ([comment[@"page"] intValue] == page + 1 && [comment[@"text"] isEqualToString:text]) return comment;
    return @{@"page" : @(page + 1), @"text" : text};
}
