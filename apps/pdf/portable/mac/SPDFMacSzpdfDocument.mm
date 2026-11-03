// A document read and laid out in szpdf's own process (SPDFMacSzpdfInternal.h). Markdown and text go through the
// reader's own parser, renderer and paginator, at the document's own paper settings (A4 portrait unless its front
// matter says otherwise), as `--agent-command inspect` lays them out; PDFs through the core. Nothing here needs the
// app to run, and nothing touches a window.
#import "SPDFMacSzpdfInternal.h"
#import "SPDFMacMarkdownComments.h"
#import "SPDFMacMarkdownPrinting.h"
#import "SPDFMacSzpdfHeadingMatch.h"
#import "markdown/SPDFMarkdownAuthoring.h"
#import "markdown/SPDFMarkdownPaginator.h"
#import "markdown/SPDFMarkdownParser.h"
#import "markdown/SPDFMarkdownRenderer.h"
#import "markdown/SPDFTextDocumentFormats.h"

#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>

#include "shenzhen_pdf_core.h"
#include "spdf_outline.h"

@interface SPDFMacSzpdfDocument ()
@property(nonatomic, copy) NSString* path;
@property(nonatomic) BOOL markdown;
@property(nonatomic) NSUInteger pageCount;
@property(nonatomic, copy) NSArray<NSDictionary*>* headings;
@property(nonatomic, copy, nullable) NSString* source;
@property(nonatomic, copy, nullable) NSString* renderedText;
@property(nonatomic, nullable) id model;
@property(nonatomic, nullable) id rendered;
@property(nonatomic, nullable) id plan;
@property(nonatomic, nullable) SPDFMarkdownCommentAnchors* anchors;
@end

static NSString* CollapsedText(NSString* text) {
    NSArray* words = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]]
        componentsJoinedByString:@" "];
}

// "## Setup" -> "Setup".
static NSString* WithoutMarks(NSString* heading) {
    NSUInteger i = 0;
    while (i < heading.length && [heading characterAtIndex:i] == '#') i++;
    return [[heading substringFromIndex:i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

static NSArray* MarkedDuplicates(NSArray<NSDictionary*>* rows) {
    NSCountedSet* titles = [NSCountedSet set];
    for (NSDictionary* row in rows) [titles addObject:[row[@"title"] lowercaseString]];
    NSMutableArray* marked = [NSMutableArray array];
    for (NSDictionary* row in rows) {
        NSMutableDictionary* copy = [row mutableCopy];
        copy[@"duplicate"] = @([titles countForObject:[row[@"title"] lowercaseString]] > 1);
        [marked addObject:copy];
    }
    return marked;
}

@implementation SPDFMacSzpdfDocument

+ (instancetype)documentAtPath:(NSString*)path failure:(NSDictionary**)failure {
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || directory) {
        if (failure) *failure = SPDFMacSzpdfFailure(@"not-found", [NSString stringWithFormat:@"No document at %@.", path], nil);
        return nil;
    }
    SPDFMacSzpdfDocument* document = [SPDFMacSzpdfDocument new];
    document.path = path;
    NSString* problem = nil;
    if ([path.pathExtension.lowercaseString isEqualToString:@"pdf"]) problem = [document loadPDF];
    else if (SPDFIsRenderedTextDocumentPath(path)) problem = [document loadMarkdown];
    else {
        if (failure) *failure = SPDFMacSzpdfFailure(@"unsupported", @"ShenzhenPDF reads PDF, Markdown, text and source files.", nil);
        return nil;
    }
    if (problem) {
        if (failure) *failure = SPDFMacSzpdfFailure(@"load-failed", problem, nil);
        return nil;
    }
    return document;
}

- (NSString*)loadMarkdown {
    NSError* error = nil;
    NSURL* url = [NSURL fileURLWithPath:self.path];
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] loadURL:url error:&error];
    if (!model) return error.localizedDescription ?: @"The document could not be read.";
    SPDFMarkdownPageConfiguration* config = SPDFMarkdownPageConfigurationForFrontMatter(
        model.frontMatter, [SPDFMarkdownPageConfiguration A4PortraitConfiguration], &error);
    if (!config) return error.localizedDescription ?: @"The page settings in the front matter are not valid.";
    config.includesCodeLanguageControlSpacing = YES;
    SPDFMarkdownRenderOptions* options = [SPDFMarkdownRenderOptions defaultOptions];
    options.pageContentSize = config.printableRect.size;
    SPDFMarkdownRenderedDocument* rendered = [[SPDFMarkdownRenderer new] renderModel:model options:options
                                                                  languageOverrides:nil];
    SPDFMarkdownPaginator* paginator = [SPDFMarkdownPaginator new];
    SPDFMarkdownPaginationPlan* plan =
        [paginator paginateItems:[paginator measureRenderedDocument:rendered
                                                     containerWidth:config.printableRect.size.width]
                   configuration:config];
    self.markdown = YES;
    self.model = model;
    self.rendered = rendered;
    self.plan = plan;
    self.pageCount = plan.pages.count;
    self.source = [NSString stringWithContentsOfFile:self.path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    self.renderedText = rendered.attributedString.string ?: @"";
    self.anchors = [[SPDFMarkdownCommentAnchors alloc] initWithSource:self.source rendered:self.renderedText];
    // Each rendered heading takes the next source heading with the same words: its line.
    NSArray<NSDictionary*>* sourceHeadings = self.anchors.sourceHeadings;
    NSUInteger next = 0;
    NSMutableArray* titles = [NSMutableArray array];
    NSMutableArray* levels = [NSMutableArray array];
    NSMutableArray* extras = [NSMutableArray array];
    for (SPDFMarkdownRenderedHeading* heading in rendered.headings) {
        NSString* title = CollapsedText(heading.title ?: @"");
        id line = NSNull.null;
        for (NSUInteger j = next; j < sourceHeadings.count && j < next + 8; j++)
            if ([CollapsedText(sourceHeadings[j][@"title"]) caseInsensitiveCompare:title] == NSOrderedSame) {
                line = sourceHeadings[j][@"line"];
                next = j + 1;
                break;
            }
        [titles addObject:title];
        [levels addObject:@(heading.level)];
        [extras addObject:@{@"page" : @([self pageForRenderedRange:heading.attributedRange]), @"line" : line}];
    }
    NSMutableArray* rows = [NSMutableArray array];
    NSArray* base = SPDFMacSzpdfHeadingRows(titles, levels);
    for (NSUInteger i = 0; i < base.count; i++) {
        NSMutableDictionary* row = [base[i] mutableCopy];
        [row addEntriesFromDictionary:extras[i]];
        [rows addObject:row];
    }
    self.headings = MarkedDuplicates(rows);
    return nil;
}

- (spdf_document*)openPDF:(NSString**)problem {
    char message[1024] = {};
    spdf_document* doc = spdf_open(self.path.fileSystemRepresentation, message, sizeof(message));
    if (doc && spdf_is_password_protected(doc)) {
        spdf_close(doc);
        doc = NULL;
        snprintf(message, sizeof(message), "This PDF is protected by a password.");
    }
    if (!doc && problem) *problem = message[0] ? @(message) : @"The PDF could not be opened.";
    return doc;
}

- (NSString*)loadPDF {
    NSString* problem = nil;
    spdf_document* doc = [self openPDF:&problem];
    if (!doc) return problem;
    self.pageCount = (NSUInteger)MAX(0, spdf_page_count(doc));
    spdf_outline outline = {};
    char message[256];
    NSMutableArray* titles = [NSMutableArray array];
    NSMutableArray* levels = [NSMutableArray array];
    NSMutableArray* pages = [NSMutableArray array];
    if (spdf_load_outline(doc, &outline, message, sizeof(message))) {
        for (int i = 0; i < outline.count; i++) {
            [titles addObject:CollapsedText(@(outline.items[i].title ?: ""))];
            [levels addObject:@(outline.items[i].level + 1)];
            [pages addObject:outline.items[i].page_index >= 0 ? @(outline.items[i].page_index + 1) : NSNull.null];
        }
        spdf_free_outline(&outline);
    }
    spdf_close(doc);
    NSMutableArray* rows = [NSMutableArray array];
    NSArray* base = SPDFMacSzpdfHeadingRows(titles, levels);
    for (NSUInteger i = 0; i < base.count; i++) {
        NSMutableDictionary* row = [base[i] mutableCopy];
        row[@"page"] = pages[i];
        row[@"line"] = NSNull.null;
        [rows addObject:row];
    }
    self.headings = MarkedDuplicates(rows);
    return nil;
}

- (NSUInteger)pageForRenderedRange:(NSRange)range {
    NSInteger page = [(SPDFMarkdownPaginationPlan*)self.plan firstPageIndexIntersectingRange:range];
    return page >= 0 ? (NSUInteger)page + 1 : 0;
}

- (NSDictionary*)placeOfRenderedRange:(NSRange)range {
    SPDFMarkdownComment* probe = [SPDFMarkdownComment new];
    if (![self.anchors anchorComment:probe toRenderedRange:range])
        return @{@"line" : NSNull.null, @"headingPath" : @[], @"context" : @""};
    NSMutableArray* path = [NSMutableArray array];
    for (NSString* heading in probe.headingPath) [path addObject:WithoutMarks(heading)];
    NSString* context = [NSString stringWithFormat:@"%@%@%@", probe.contextBefore, probe.quote, probe.contextAfter];
    return @{@"line" : probe.line > 0 ? @(probe.line) : NSNull.null, @"headingPath" : path, @"context" : context};
}

#pragma mark - Find

- (NSDictionary*)find:(NSString*)text caseSensitive:(BOOL)caseSensitive limit:(NSUInteger)limit {
    NSMutableArray* matches = [NSMutableArray array];
    NSUInteger count = 0;
    NSStringCompareOptions options = caseSensitive ? NSLiteralSearch : NSCaseInsensitiveSearch;
    if (self.markdown) {
        NSString* haystack = self.renderedText;
        NSRange search = NSMakeRange(0, haystack.length);
        while (text.length && search.length) {
            NSRange hit = [haystack rangeOfString:text options:options range:search];
            if (hit.location == NSNotFound) break;
            count++;
            if (matches.count < limit) {
                NSMutableDictionary* match = [[self placeOfRenderedRange:hit] mutableCopy];
                match[@"page"] = @([self pageForRenderedRange:hit]);
                match[@"text"] = [haystack substringWithRange:hit];
                [matches addObject:match];
            }
            search = NSMakeRange(NSMaxRange(hit), haystack.length - NSMaxRange(hit));
        }
        return @{@"path" : self.path, @"query" : text, @"count" : @(count), @"matches" : matches};
    }
    NSString* problem = nil;
    spdf_document* doc = [self openPDF:&problem];
    if (!doc) return SPDFMacSzpdfFailure(@"load-failed", problem, nil);
    for (int page = 0; page < (int)self.pageCount; page++) {
        spdf_text_lines lines = {};
        char message[256];
        if (!spdf_extract_page_text_lines(doc, page, &lines, message, sizeof(message))) continue;
        for (int i = 0; i < lines.count; i++) {
            NSString* line = @(lines.items[i].text ?: "");
            NSRange hit = [line rangeOfString:text options:options];
            for (; hit.location != NSNotFound;
                 hit = [line rangeOfString:text options:options
                                     range:NSMakeRange(NSMaxRange(hit), line.length - NSMaxRange(hit))]) {
                count++;
                if (matches.count >= limit) continue;
                NSMutableArray* path = [NSMutableArray array];
                for (NSDictionary* heading in self.headings)
                    if ([heading[@"page"] isKindOfClass:NSNumber.class] && [heading[@"page"] intValue] <= page + 1)
                        path = [heading[@"path"] mutableCopy];
                [matches addObject:@{@"page" : @(page + 1), @"line" : @(i + 1), @"headingPath" : path,
                                     @"text" : [line substringWithRange:hit], @"context" : CollapsedText(line)}];
            }
        }
        spdf_free_text_lines(&lines);
    }
    spdf_close(doc);
    return @{@"path" : self.path, @"query" : text, @"count" : @(count), @"matches" : matches};
}

#pragma mark - Pictures and PDF

static NSDictionary* WritePNG(CGImageRef image, NSString* output) {
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:output], CFSTR("public.png"), 1, NULL);
    BOOL written = NO;
    if (destination && image) {
        CGImageDestinationAddImage(destination, image, NULL);
        written = CGImageDestinationFinalize(destination);
    }
    if (destination) CFRelease(destination);
    if (!written) return SPDFMacSzpdfFailure(@"write-failed", [NSString stringWithFormat:@"Could not write %@.", output], nil);
    return @{@"path" : output, @"width" : @(CGImageGetWidth(image)), @"height" : @(CGImageGetHeight(image))};
}

- (NSDictionary*)writePage:(NSUInteger)page toPNG:(NSString*)output scale:(double)scale region:(NSArray<NSNumber*>*)region {
    if (page < 1 || page > self.pageCount)
        return SPDFMacSzpdfFailure(@"page-out-of-range",
                                   [NSString stringWithFormat:@"The document has %lu pages.", (unsigned long)self.pageCount],
                                   @{@"pageCount" : @(self.pageCount)});
    if (![NSFileManager.defaultManager fileExistsAtPath:output.stringByDeletingLastPathComponent])
        return SPDFMacSzpdfFailure(@"not-found", @"The folder for the picture does not exist.", nil);
    NSDictionary* answer = nil;
    CGRect cut = region ? CGRectMake(region[0].doubleValue, region[1].doubleValue, region[2].doubleValue,
                                     region[3].doubleValue)
                        : CGRectNull;
    if (self.markdown) {
        SPDFMarkdownPaginationPlan* plan = self.plan;
        NSBitmapImageRep* rep = [SPDFMacMarkdownPrintAdapter imageRepForPageAtIndex:page - 1 paginationPlan:plan
                                                                   attributedString:[self.rendered attributedString]
                                                                              scale:scale];
        CGImageRef image = rep.CGImage;
        if (!image) return SPDFMacSzpdfFailure(@"failed", @"The page could not be drawn.", nil);
        CGImageRef cropped = NULL;
        if (!CGRectIsNull(cut)) {
            CGRect pixels = CGRectIntegral(CGRectMake(cut.origin.x * scale, cut.origin.y * scale, cut.size.width * scale,
                                                      cut.size.height * scale));
            cropped = CGImageCreateWithImageInRect(image, pixels);
            if (!cropped) return SPDFMacSzpdfFailure(@"usage", @"The region is outside the page.", nil);
        }
        answer = WritePNG(cropped ?: image, output);
        if (cropped) CGImageRelease(cropped);
    } else {
        NSString* problem = nil;
        spdf_document* doc = [self openPDF:&problem];
        if (!doc) return SPDFMacSzpdfFailure(@"load-failed", problem, nil);
        spdf_bitmap bitmap = {};
        char message[512] = {};
        BOOL drawn = CGRectIsNull(cut)
                         ? spdf_render_page_rgba(doc, (int)page - 1, (float)scale, &bitmap, message, sizeof(message))
                         : spdf_render_page_region_rgba(doc, (int)page - 1, (float)scale,
                                                        spdf_rect{(float)cut.origin.x, (float)cut.origin.y,
                                                                  (float)CGRectGetMaxX(cut), (float)CGRectGetMaxY(cut)},
                                                        &bitmap, message, sizeof(message));
        spdf_close(doc);
        if (!drawn) return SPDFMacSzpdfFailure(@"failed", message[0] ? @(message) : @"The page could not be drawn.", nil);
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, bitmap.rgba, (size_t)bitmap.stride * bitmap.height, NULL);
        CGImageRef image = CGImageCreate((size_t)bitmap.width, (size_t)bitmap.height, 8, 32, (size_t)bitmap.stride, space,
                                         kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault, provider, NULL,
                                         false, kCGRenderingIntentDefault);
        answer = WritePNG(image, output);
        CGImageRelease(image);
        CGDataProviderRelease(provider);
        CGColorSpaceRelease(space);
        spdf_free_bitmap(&bitmap);
    }
    if (answer[@"error"]) return answer;
    NSMutableDictionary* stamped = [answer mutableCopy];
    stamped[@"page"] = @(page);
    stamped[@"scale"] = @(scale);
    stamped[@"document"] = self.path;
    if (region) stamped[@"region"] = region;
    return stamped;
}

- (NSDictionary*)writePDF:(NSString*)output {
    if (!self.markdown) return SPDFMacSzpdfFailure(@"unsupported", @"export-pdf lays out Markdown and text documents.", nil);
    NSError* error = nil;
    if (![SPDFMacMarkdownPrintAdapter writePaginationPlan:self.plan attributedString:[self.rendered attributedString]
                                                    toURL:[NSURL fileURLWithPath:output] error:&error])
        return SPDFMacSzpdfFailure(@"write-failed", error.localizedDescription ?: @"The PDF could not be written.", nil);
    return @{@"path" : output, @"document" : self.path, @"pageCount" : @(self.pageCount)};
}

#pragma mark - Where a new comment goes

- (NSArray*)occurrencesOf:(NSString*)quote {
    NSMutableArray* found = [NSMutableArray array];
    NSString* haystack = self.renderedText;
    NSRange search = NSMakeRange(0, haystack.length);
    while (quote.length && search.length) {
        NSRange hit = [haystack rangeOfString:quote options:NSLiteralSearch range:search];
        if (hit.location == NSNotFound) break;
        [found addObject:[NSValue valueWithRange:hit]];
        search = NSMakeRange(NSMaxRange(hit), haystack.length - NSMaxRange(hit));
    }
    return found;
}

- (SPDFMarkdownComment*)commentAt:(NSDictionary*)where failure:(NSDictionary**)failure {
    NSRange range = NSMakeRange(NSNotFound, 0);
    if (where[@"line"]) {
        NSInteger line = [where[@"line"] integerValue];
        NSInteger lines = (NSInteger)[self.source componentsSeparatedByString:@"\n"].count;
        NSRange words = line <= lines ? [self.anchors renderedRangeForSourceLine:line] : NSMakeRange(NSNotFound, 0);
        if (words.location == NSNotFound) {
            *failure = SPDFMacSzpdfFailure(@"line-out-of-range",
                                           line > lines ? [NSString stringWithFormat:@"The document has %ld lines.", (long)lines]
                                                        : [NSString stringWithFormat:@"Line %ld shows no words of its own "
                                                                                     @"(blank, code, a table rule or front "
                                                                                     @"matter); use --quote.", (long)line],
                                           nil);
            return nil;
        }
        range = [self.anchors blockRangeAtRenderedLocation:words.location];
    } else if (where[@"quote"]) {
        NSString* quote = CollapsedText(where[@"quote"]);
        NSArray* found = [self occurrencesOf:quote];
        if (found.count != 1) {
            NSMutableArray* places = [NSMutableArray array];
            for (NSValue* hit in [found subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)10, found.count))]) {
                NSMutableDictionary* place = [[self placeOfRenderedRange:hit.rangeValue] mutableCopy];
                place[@"page"] = @([self pageForRenderedRange:hit.rangeValue]);
                [places addObject:place];
            }
            *failure = found.count
                           ? SPDFMacSzpdfFailure(@"quote-ambiguous",
                                                 [NSString stringWithFormat:@"“%@” occurs %lu times; quote more words "
                                                                            @"or use --line (the first 10 are in \"matches\").", quote,
                                                                            (unsigned long)found.count],
                                                 @{@"matches" : places})
                           : SPDFMacSzpdfFailure(@"quote-not-found",
                                                 [NSString stringWithFormat:@"“%@” is not in the document as shown "
                                                                            @"(quote the words as they read, without "
                                                                            @"Markdown marks).", quote],
                                                 nil);
            return nil;
        }
        range = [found.firstObject rangeValue];
    } else {
        NSDictionary* match = SPDFMacSzpdfMatchHeading(self.headings, where[@"heading"]);
        if (!match[@"index"]) {
            *failure = SPDFMacSzpdfNormalized(match);
            return nil;
        }
        NSArray* headings = [self.rendered headings];
        range = [headings[[match[@"index"] unsignedIntegerValue]] attributedRange];
    }
    SPDFMarkdownComment* comment = [SPDFMarkdownComment new];
    if (![self.anchors anchorComment:comment toRenderedRange:range]) {
        *failure = SPDFMacSzpdfFailure(@"line-out-of-range", @"There are no words to comment on there.", nil);
        return nil;
    }
    return comment;
}

@end
