// The "<title> - comments.md" file (SPDFMacMarkdownComments.h): written for a person reading it in any Markdown
// viewer, and parsed back by the app. Each comment is one block between "---" rules:
//
//   **Line 12** · ## Setup › ### Wiring
//
//   > The board needs **two pull-ups on SDA** before power-on.
//
//   **Raph** · 2026-11-01 15:20
//
//   Check the value.
//
//   - **Agent** · 2026-11-01 16:00
//
//     Done: 4.7 kΩ on both.
//
// Replies follow the comment as list items, each with its own byline and its text indented under it.
// The bold words inside the quote are the commented ones; every other "*" in the file is escaped, so the parser
// finds them without guessing.

#import "SPDFMacMarkdownComments.h"

static NSString* const kSeparator = @"---";
static NSString* const kUnplacedHeading = @"## Unplaced";
static NSString* const kPathSeparator = @" › ";
static NSString* const kResolvedSuffix = @" · Resolved";

@implementation SPDFMarkdownCommentReply
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _author = @"";
    _text = @"";
    return self;
}
@end

@implementation SPDFMarkdownComment
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _author = @"";
    _text = @"";
    _quote = @"";
    _headingPath = @[];
    _contextBefore = @"";
    _contextAfter = @"";
    _replies = @[];
    _renderedRange = NSMakeRange(NSNotFound, 0);
    return self;
}
- (BOOL)isPlaced {
    return _renderedRange.location != NSNotFound;
}
@end

NSString* SPDFMarkdownCommentsFilePath(NSString* documentPath) {
    NSString* title = documentPath.lastPathComponent.stringByDeletingPathExtension;
    NSString* name = [NSString stringWithFormat:@"%@ - comments.md", title.length ? title : @"Document"];
    return [documentPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:name];
}

BOOL SPDFMarkdownIsCommentsFilePath(NSString* path) {
    return [path.lastPathComponent.lowercaseString hasSuffix:@" - comments.md"];
}

static NSDateFormatter* DateFormatter(void) {
    static NSDateFormatter* formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      formatter = [NSDateFormatter new];
      formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
      formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    });
    return formatter;
}

// Backslash-escapes what Markdown would otherwise turn into formatting, so the reader sees the text as written and
// the only unescaped "**" in a quote line are the markers around the commented words.
static NSString* Escape(NSString* text) {
    NSCharacterSet* special = [NSCharacterSet characterSetWithCharactersInString:@"\\`*_[]<~"];
    NSMutableString* out = [NSMutableString stringWithCapacity:text.length + 8];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ([special characterIsMember:c]) [out appendString:@"\\"];
        [out appendFormat:@"%C", c];
    }
    return out;
}

static NSString* Unescape(NSString* text) {
    NSMutableString* out = [NSMutableString stringWithCapacity:text.length];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '\\' && i + 1 < text.length) {
            unichar next = [text characterAtIndex:i + 1];
            if (next < 128 && ispunct(next)) {
                [out appendFormat:@"%C", next];
                i++;
                continue;
            }
        }
        [out appendFormat:@"%C", c];
    }
    return out;
}

static NSString* Trimmed(NSString* text) {
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// A body line that would end the comment, or turn into a heading or rule, gets a leading backslash; Markdown shows
// the line unchanged and the parser drops the backslash again.
static BOOL ParseReplyByline(NSString* line, SPDFMarkdownCommentReply* reply);
static BOOL BodyLineNeedsEscape(NSString* line) {
    NSString* t = Trimmed(line);
    if (ParseReplyByline(line, nil)) return YES; // would start a reply
    if ([t hasPrefix:@"#"]) return YES;
    if (t.length < 3) return NO;
    for (NSString* mark in @[ @"-", @"*", @"_" ]) {
        NSString* rest = [[t stringByReplacingOccurrencesOfString:mark withString:@""]
            stringByReplacingOccurrencesOfString:@" " withString:@""];
        if (rest.length == 0) return YES;
    }
    return NO;
}

NSArray<SPDFMarkdownComment*>* SPDFMarkdownCommentsSorted(NSArray<SPDFMarkdownComment*>* comments) {
    return [comments sortedArrayWithOptions:NSSortStable
                            usingComparator:^NSComparisonResult(SPDFMarkdownComment* a, SPDFMarkdownComment* b) {
                              if (a.placed != b.placed) return a.placed ? NSOrderedAscending : NSOrderedDescending;
                              NSUInteger x = a.placed ? a.renderedRange.location : (NSUInteger)MAX(0, a.line);
                              NSUInteger y = b.placed ? b.renderedRange.location : (NSUInteger)MAX(0, b.line);
                              return x < y ? NSOrderedAscending : x > y ? NSOrderedDescending : NSOrderedSame;
                            }];
}

static void AppendComment(NSMutableString* out, SPDFMarkdownComment* comment) {
    [out appendFormat:@"%@\n\n", kSeparator];
    NSMutableArray* path = [NSMutableArray array];
    for (NSString* heading in comment.headingPath) [path addObject:Escape(heading)];
    NSString* where = comment.line > 0 ? [NSString stringWithFormat:@"**Line %ld**", (long)comment.line] : @"**Line ?**";
    if (path.count) where = [where stringByAppendingFormat:@" · %@", [path componentsJoinedByString:kPathSeparator]];
    [out appendFormat:@"%@\n\n", where];
    [out appendFormat:@"> %@**%@**%@\n\n", Escape(comment.contextBefore), Escape(comment.quote),
                      Escape(comment.contextAfter)];
    NSString* date = [DateFormatter() stringFromDate:comment.date ?: NSDate.date];
    NSString* author = Trimmed(comment.author);
    NSString* byline = author.length ? [NSString stringWithFormat:@"**%@** · %@", Escape(author), date] : date;
    [out appendFormat:@"%@%@\n\n", byline, comment.resolved ? kResolvedSuffix : @""];
    for (NSString* line in [Trimmed(comment.text) componentsSeparatedByString:@"\n"])
        [out appendFormat:@"%@%@\n", BodyLineNeedsEscape(line) ? @"\\" : @"", line];
    [out appendString:@"\n"];
    for (SPDFMarkdownCommentReply* reply in comment.replies) {
        NSString* when = [DateFormatter() stringFromDate:reply.date ?: NSDate.date];
        NSString* by = Trimmed(reply.author);
        [out appendFormat:@"- %@\n\n", by.length ? [NSString stringWithFormat:@"**%@** · %@", Escape(by), when] : when];
        for (NSString* line in [Trimmed(reply.text) componentsSeparatedByString:@"\n"])
            [out appendFormat:@"%@%@%@\n", line.length ? @"  " : @"", BodyLineNeedsEscape(line) ? @"\\" : @"", line];
        [out appendString:@"\n"];
    }
}

NSString* SPDFMarkdownCommentsHeader(NSString* documentName) {
    return [NSString stringWithFormat:@"# Comments on %@", Escape(documentName)];
}

NSString* SPDFMarkdownCommentsFileText(NSString* documentName, NSArray<SPDFMarkdownComment*>* comments) {
    NSMutableString* out = [NSMutableString stringWithFormat:@"%@\n\n", SPDFMarkdownCommentsHeader(documentName)];
    BOOL unplacedStarted = NO;
    for (SPDFMarkdownComment* comment in SPDFMarkdownCommentsSorted(comments)) {
        if (!comment.placed && !unplacedStarted) {
            unplacedStarted = YES;
            [out appendFormat:@"%@\n\n", kUnplacedHeading];
            [out appendFormat:@"The passages these comments were on are no longer in %@.\n\n", Escape(documentName)];
        }
        AppendComment(out, comment);
    }
    return out;
}

// "> before **quote** after": the first two unescaped "**" bound the quote.
static void ParseQuote(NSString* line, SPDFMarkdownComment* comment) {
    NSMutableArray<NSNumber*>* marks = [NSMutableArray array];
    for (NSUInteger i = 0; i + 1 < line.length && marks.count < 2; i++) {
        unichar c = [line characterAtIndex:i];
        if (c == '\\') { i++; continue; }
        if (c == '*' && [line characterAtIndex:i + 1] == '*') { [marks addObject:@(i)]; i++; }
    }
    if (marks.count < 2) {
        comment.quote = Unescape(line);
        return;
    }
    NSUInteger open = marks[0].unsignedIntegerValue, close = marks[1].unsignedIntegerValue;
    comment.contextBefore = Unescape([line substringToIndex:open]);
    comment.quote = Unescape([line substringWithRange:NSMakeRange(open + 2, close - open - 2)]);
    comment.contextAfter = Unescape([line substringFromIndex:close + 2]);
}

static void ParseLocation(NSString* line, SPDFMarkdownComment* comment) {
    NSScanner* scanner = [NSScanner scannerWithString:line];
    scanner.charactersToBeSkipped = nil;
    NSInteger number = 0;
    if ([scanner scanString:@"**Line " intoString:NULL] && [scanner scanInteger:&number]) comment.line = number;
    NSRange dot = [line rangeOfString:@"** · "];
    if (dot.location == NSNotFound) return;
    NSString* path = [line substringFromIndex:NSMaxRange(dot)];
    NSMutableArray* headings = [NSMutableArray array];
    for (NSString* part in [path componentsSeparatedByString:kPathSeparator])
        if (Trimmed(part).length) [headings addObject:Unescape(Trimmed(part))];
    comment.headingPath = headings;
}

static BOOL ParseByline(NSString* line, SPDFMarkdownComment* comment) {
    BOOL resolved = [line hasSuffix:kResolvedSuffix];
    if (resolved) line = [line substringToIndex:line.length - kResolvedSuffix.length];
    NSString* author = @"";
    NSString* date = line;
    if ([line hasPrefix:@"**"]) {
        NSRange end = [line rangeOfString:@"** · " options:NSBackwardsSearch];
        if (end.location == NSNotFound || end.location < 2) return NO;
        author = Unescape([line substringWithRange:NSMakeRange(2, end.location - 2)]);
        date = [line substringFromIndex:NSMaxRange(end)];
    }
    NSDate* parsed = [DateFormatter() dateFromString:Trimmed(date)];
    if (!parsed) return NO;
    comment.author = author;
    comment.date = parsed;
    comment.resolved = resolved;
    return YES;
}

// "- **Agent** · 2026-11-01 16:00" or "- 2026-11-01 16:00": a reply's byline. `reply` may be nil (a test only).
static BOOL ParseReplyByline(NSString* line, SPDFMarkdownCommentReply* reply) {
    if (![line hasPrefix:@"- "]) return NO;
    NSString* rest = Trimmed([line substringFromIndex:2]);
    NSString* author = @"";
    NSString* date = rest;
    if ([rest hasPrefix:@"**"]) {
        NSRange end = [rest rangeOfString:@"** · " options:NSBackwardsSearch];
        if (end.location == NSNotFound || end.location < 2) return NO;
        author = Unescape([rest substringWithRange:NSMakeRange(2, end.location - 2)]);
        date = [rest substringFromIndex:NSMaxRange(end)];
    }
    NSDate* parsed = [DateFormatter() dateFromString:Trimmed(date)];
    if (!parsed) return NO;
    reply.author = author;
    reply.date = parsed;
    return YES;
}

static NSString* Unescaped(NSString* line) {
    if ([line hasPrefix:@"\\"] && line.length > 1 && BodyLineNeedsEscape([line substringFromIndex:1]))
        return [line substringFromIndex:1];
    return line;
}

static SPDFMarkdownComment* ParseEntry(NSArray<NSString*>* lines) {
    SPDFMarkdownComment* comment = [SPDFMarkdownComment new];
    NSUInteger i = 0;
    while (i < lines.count && !Trimmed(lines[i]).length) i++;
    if (i < lines.count && [lines[i] hasPrefix:@"**Line "]) ParseLocation(lines[i++], comment);
    while (i < lines.count && !Trimmed(lines[i]).length) i++;
    NSMutableArray* quote = [NSMutableArray array];
    for (; i < lines.count && [lines[i] hasPrefix:@">"]; i++)
        [quote addObject:Trimmed([lines[i] substringFromIndex:1])];
    if (quote.count) ParseQuote([quote componentsJoinedByString:@" "], comment);
    while (i < lines.count && !Trimmed(lines[i]).length) i++;
    if (i < lines.count && ParseByline(Trimmed(lines[i]), comment)) i++;
    NSMutableArray* body = [NSMutableArray array];
    NSMutableArray<SPDFMarkdownCommentReply*>* replies = [NSMutableArray array];
    __block NSMutableArray<NSString*>* replyLines = nil;
    void (^finishReply)(void) = ^{
      if (replies.count) replies.lastObject.text = Trimmed([replyLines componentsJoinedByString:@"\n"]);
    };
    for (; i < lines.count; i++) {
        NSString* line = lines[i];
        SPDFMarkdownCommentReply* reply = [SPDFMarkdownCommentReply new];
        if (ParseReplyByline(line, reply)) {
            finishReply();
            [replies addObject:reply];
            replyLines = [NSMutableArray array];
        } else if (replyLines) {
            [replyLines addObject:Unescaped([line hasPrefix:@"  "] ? [line substringFromIndex:2] : line)];
        } else {
            [body addObject:Unescaped(line)];
        }
    }
    finishReply();
    comment.replies = replies;
    comment.text = Trimmed([body componentsJoinedByString:@"\n"]);
    if (!comment.quote.length && !comment.text.length) return nil;
    return comment;
}

NSArray<SPDFMarkdownComment*>* SPDFMarkdownCommentsParseFile(NSString* text) {
    NSMutableArray<SPDFMarkdownComment*>* comments = [NSMutableArray array];
    NSArray<NSString*>* lines =
        [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] componentsSeparatedByString:@"\n"];
    __block NSMutableArray<NSString*>* entry = nil;
    void (^finish)(void) = ^{
      SPDFMarkdownComment* comment = entry ? ParseEntry(entry) : nil;
      if (comment) [comments addObject:comment];
    };
    for (NSString* line in lines) {
        NSString* trimmed = Trimmed(line);
        if ([trimmed isEqualToString:kSeparator]) {
            finish();
            entry = [NSMutableArray array];
        } else if ([trimmed hasPrefix:@"## "] || [trimmed hasPrefix:@"# "]) {
            finish();
            entry = nil;
        } else {
            [entry addObject:line];
        }
    }
    finish();
    return comments;
}
