// What changed (SPDFMacSzpdfInternal.h): between two versions' text, between two listings of comments, and the wait
// for the next change to a document's comments.
#import "SPDFMacSzpdfInternal.h"
#import "SPDFMacAgentComments.h"
#import "SPDFMacMarkdownComments.h"

#include <fcntl.h>
#include <unistd.h>
#include <vector>

#include "shenzhen_pdf_core.h"

#pragma mark - Lines

// One side of a block: lines from..to (from 1). A side with no lines has count 0, and `from` is the line the other
// side's lines come before.
static NSDictionary* Side(NSUInteger start, NSUInteger count) {
    return @{@"from" : @(start + 1), @"to" : @(start + count), @"count" : @(count)};
}

NSArray<NSDictionary*>* SPDFMacSzpdfDiffLines(NSArray<NSString*>* a, NSArray<NSString*>* b) {
    NSUInteger n = a.count, m = b.count, head = 0, tail = 0;
    while (head < n && head < m && [a[head] isEqualToString:b[head]]) head++;
    while (tail < n - head && tail < m - head && [a[n - 1 - tail] isEqualToString:b[m - 1 - tail]]) tail++;
    NSUInteger x = n - head - tail, y = m - head - tail;
    // Longest common subsequence of the middle; past a few million cells the middle is one changed block.
    std::vector<std::pair<NSUInteger, NSUInteger>> same;  // matched (i, j) in the middle, in order
    if (x && y && (unsigned long long)x * y <= 4000000ULL) {
        std::vector<std::vector<uint32_t>> length(x + 1, std::vector<uint32_t>(y + 1, 0));
        for (NSUInteger i = x; i-- > 0;)
            for (NSUInteger j = y; j-- > 0;)
                length[i][j] = [a[head + i] isEqualToString:b[head + j]] ? length[i + 1][j + 1] + 1
                                                                       : MAX(length[i + 1][j], length[i][j + 1]);
        NSUInteger i = 0, j = 0;
        while (i < x && j < y) {
            if ([a[head + i] isEqualToString:b[head + j]]) same.push_back({i++, j++});
            else if (length[i + 1][j] >= length[i][j + 1]) i++;
            else j++;
        }
    }
    same.push_back({x, y});
    NSMutableArray* blocks = [NSMutableArray array];
    NSUInteger i = 0, j = 0;
    for (auto pair : same) {
        if (pair.first > i || pair.second > j) {
            NSUInteger removed = pair.first - i, added = pair.second - j;
            NSArray* before = [a subarrayWithRange:NSMakeRange(head + i, removed)];
            NSArray* after = [b subarrayWithRange:NSMakeRange(head + j, added)];
            [blocks addObject:@{
                @"kind" : !removed ? @"added" : !added ? @"removed" : @"changed",
                @"old" : Side(head + i, removed),
                @"new" : Side(head + j, added),
                @"before" : [before componentsJoinedByString:@"\n"],
                @"after" : [after componentsJoinedByString:@"\n"],
            }];
        }
        i = pair.first + 1;
        j = pair.second + 1;
    }
    return blocks;
}

// The text of a version as lines, and for a PDF the page of each line.
static NSArray<NSString*>* VersionLines(NSString* path, NSMutableArray<NSNumber*>* pages, NSString** problem) {
    if (![path.pathExtension.lowercaseString isEqualToString:@"pdf"]) {
        NSString* text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!text) *problem = [NSString stringWithFormat:@"%@ could not be read as text.", path.lastPathComponent];
        return [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] componentsSeparatedByString:@"\n"];
    }
    char message[512] = {};
    spdf_document* doc = spdf_open(path.fileSystemRepresentation, message, sizeof(message));
    if (!doc) {
        *problem = message[0] ? @(message) : @"The PDF could not be opened.";
        return nil;
    }
    NSMutableArray* lines = [NSMutableArray array];
    for (int page = 0; page < spdf_page_count(doc); page++) {
        spdf_text_lines text = {};
        if (!spdf_extract_page_text_lines(doc, page, &text, message, sizeof(message))) continue;
        for (int i = 0; i < text.count; i++) {
            [lines addObject:@(text.items[i].text ?: "")];
            [pages addObject:@(page + 1)];
        }
        spdf_free_text_lines(&text);
    }
    spdf_close(doc);
    return lines;
}

static NSArray* PageSpan(NSArray<NSNumber*>* pages, NSDictionary* side) {
    NSUInteger from = [side[@"from"] unsignedIntegerValue], count = [side[@"count"] unsignedIntegerValue];
    if (!pages.count) return @[];
    NSUInteger first = MIN(from, pages.count) - 1, last = count ? MIN(from + count - 1, pages.count) - 1 : first;
    return @[ pages[first], pages[last] ];
}

NSArray<NSDictionary*>* SPDFMacSzpdfVersionBlocks(NSString* older, NSString* newer, NSDictionary** failure) {
    NSMutableArray *oldPages = [NSMutableArray array], *newPages = [NSMutableArray array];
    NSString* problem = nil;
    NSArray* before = VersionLines(older, oldPages, &problem);
    NSArray* after = problem ? nil : VersionLines(newer, newPages, &problem);
    if (!before || !after) {
        if (failure) *failure = SPDFMacSzpdfFailure(@"load-failed", problem ?: @"A version could not be read.", nil);
        return nil;
    }
    NSArray* blocks = SPDFMacSzpdfDiffLines(before, after);
    if (!oldPages.count && !newPages.count) return blocks;
    NSMutableArray* paged = [NSMutableArray array];
    for (NSDictionary* block in blocks) {
        NSMutableDictionary* copy = [block mutableCopy];
        copy[@"oldPages"] = PageSpan(oldPages, block[@"old"]);
        copy[@"newPages"] = PageSpan(newPages, block[@"new"]);
        [paged addObject:copy];
    }
    return paged;
}

#pragma mark - Comments

static BOOL Later(id dateText, NSDate* since) {
    if (!since || ![dateText isKindOfClass:NSString.class]) return NO;
    NSDate* date = SPDFMacSzpdfParseISODate(dateText);
    return date && [date compare:since] == NSOrderedDescending;
}

static NSDictionary* Change(NSString* kind, NSDictionary* comment, NSDictionary* reply) {
    NSMutableDictionary* change = [@{@"kind" : kind, @"id" : comment[@"id"] ?: @"", @"quote" : comment[@"quote"] ?: @"",
                                     @"author" : comment[@"author"] ?: @"", @"date" : comment[@"date"] ?: NSNull.null,
                                     @"text" : comment[@"text"] ?: @"", @"status" : comment[@"status"] ?: @"open"}
        mutableCopy];
    for (NSString* key in @[ @"line", @"page", @"headingPath" ])
        if (comment[key]) change[key] = comment[key];
    if (reply) change[@"reply"] = reply;
    return change;
}

NSArray<NSDictionary*>* SPDFMacSzpdfCommentChanges(NSArray<NSDictionary*>* before, NSArray<NSDictionary*>* after,
                                                   NSDate* since) {
    NSMutableDictionary<NSString*, NSDictionary*>* old = [NSMutableDictionary dictionary];
    for (NSDictionary* comment in before) old[comment[@"id"]] = comment;
    NSMutableArray* changes = [NSMutableArray array];
    NSMutableSet* seen = [NSMutableSet set];
    for (NSDictionary* comment in after) {
        NSDictionary* was = old[comment[@"id"]];
        [seen addObject:comment[@"id"] ?: @""];
        if (!was || (Later(comment[@"date"], since) && [was isEqual:comment])) {
            [changes addObject:Change(@"added", comment, nil)];
            continue;
        }
        if (![was[@"text"] isEqual:comment[@"text"]]) [changes addObject:Change(@"edited", comment, nil)];
        if (![was[@"status"] isEqual:comment[@"status"]])
            [changes addObject:Change([comment[@"status"] isEqual:@"resolved"] ? @"resolved" : @"reopened", comment, nil)];
        NSArray *oldReplies = was[@"replies"] ?: @[], *replies = comment[@"replies"] ?: @[];
        for (NSUInteger i = 0; i < replies.count; i++)
            if (i >= oldReplies.count || ![oldReplies containsObject:replies[i]] || Later(replies[i][@"date"], since))
                [changes addObject:Change(@"reply", comment, replies[i])];
    }
    for (NSDictionary* comment in before)
        if (![seen containsObject:comment[@"id"]]) [changes addObject:Change(@"removed", comment, nil)];
    return changes;
}

#pragma mark - Waiting

// The wait's state, touched only on its own serial queue.
@interface SPDFMacSzpdfCommentsWait : NSObject
@property(nonatomic, copy) NSString* path;
@property(nonatomic, copy) NSArray* baseline;
@property(nonatomic) NSDate* since;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) dispatch_queue_t replyQueue;
@property(nonatomic, copy) void (^done)(NSDictionary*);
@property(nonatomic) NSMutableArray* sources;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL checkPending;
@end

@implementation SPDFMacSzpdfCommentsWait

- (NSString*)watchedFile {
    BOOL pdf = [self.path.pathExtension.lowercaseString isEqualToString:@"pdf"];
    return pdf ? self.path : SPDFMarkdownCommentsFilePath(self.path);
}

- (void)watch:(NSString*)path mask:(unsigned long)mask {
    int fd = open(path.fileSystemRepresentation, O_EVTONLY | O_CLOEXEC);
    if (fd < 0) return;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd, mask, self.queue);
    __weak SPDFMacSzpdfCommentsWait* weakSelf = self;
    dispatch_source_set_event_handler(source, ^{ [weakSelf somethingChanged]; });
    dispatch_source_set_cancel_handler(source, ^{ close(fd); });
    [self.sources addObject:source];
    dispatch_resume(source);
}

// The folder (an atomic save renames a new file in) and the file itself (written in place), watched afresh after each
// event because a rename leaves the old file's watch on a file that is gone.
- (void)arm {
    for (dispatch_source_t source in self.sources) dispatch_source_cancel(source);
    [self.sources removeAllObjects];
    [self watch:self.path.stringByDeletingLastPathComponent mask:DISPATCH_VNODE_WRITE];
    [self watch:[self watchedFile]
           mask:DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME |
                DISPATCH_VNODE_ATTRIB];
}

- (void)somethingChanged {
    if (self.finished || self.checkPending) return;
    // A save is often several events (write, rename, attributes): look once they have settled.
    self.checkPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), self.queue, ^{
      self.checkPending = NO;
      [self check];
    });
}

- (void)check {
    if (self.finished) return;
    NSDictionary* listing = SPDFMacAgentListComments(self.path, nil);
    NSArray* changes = listing ? SPDFMacSzpdfCommentChanges(self.baseline, listing[@"comments"], self.since) : @[];
    if (changes.count) [self finish:changes timedOut:NO];
    else [self arm];
}

- (void)finish:(NSArray*)changes timedOut:(BOOL)timedOut {
    if (self.finished) return;
    self.finished = YES;
    for (dispatch_source_t source in self.sources) dispatch_source_cancel(source);
    [self.sources removeAllObjects];
    NSDictionary* answer = @{@"path" : self.path, @"changes" : changes, @"timedOut" : @(timedOut)};
    void (^done)(NSDictionary*) = self.done;
    dispatch_async(self.replyQueue, ^{ done(answer); });
}

@end

void SPDFMacSzpdfWatchComments(NSString* path, NSDate* since, NSTimeInterval timeout, dispatch_queue_t queue,
                               void (^done)(NSDictionary* answer)) {
    SPDFMacSzpdfCommentsWait* wait = [SPDFMacSzpdfCommentsWait new];
    wait.path = path;
    wait.since = since;
    wait.replyQueue = queue;
    wait.done = done;
    wait.sources = [NSMutableArray array];
    wait.queue = dispatch_queue_create("szpdf comments wait", DISPATCH_QUEUE_SERIAL);
    dispatch_async(wait.queue, ^{
      NSError* error = nil;
      NSDictionary* listing = SPDFMacAgentListComments(path, &error);
      if (!listing) {
          wait.finished = YES;
          NSDictionary* failure = SPDFMacSzpdfFailure(@"not-found", error.localizedDescription ?: @"No document.", nil);
          dispatch_async(queue, ^{ done(failure); });
          return;
      }
      wait.baseline = listing[@"comments"];
      NSArray* already = since ? SPDFMacSzpdfCommentChanges(wait.baseline, wait.baseline, since) : @[];
      if (already.count) {
          [wait finish:already timedOut:NO];
          return;
      }
      [wait arm];
      // The wait keeps itself alive until it finishes: this block holds it.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), wait.queue,
                     ^{ [wait finish:@[] timedOut:YES]; });
    });
}
