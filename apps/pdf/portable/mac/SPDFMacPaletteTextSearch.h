#import "markdown/SPDFTextDocumentFormats.h"
#import "SPDFMacSearchFileCache.h"
#import "SPDFMacCollectionPaletteModel.h"
#import "markdown/SPDFMarkdownDocument.h"
#import <PDFKit/PDFKit.h>

// Image dimensions can change pagination without editing the Markdown source.
// Retain only local dependency stamps; checking them never decodes an image.
static void SPDFPaletteImageStamps(NSArray<SPDFMarkdownBlock*>* blocks, NSString* source,
                                  NSMutableDictionary* stamps) {
    for (SPDFMarkdownBlock* block in blocks) {
        for (SPDFMarkdownInlineRun* run in block.runs) {
            if (!(run.traits & SPDFMarkdownInlineTraitImage) || !run.destination.length) continue;
            NSURLComponents* parts = [NSURLComponents componentsWithString:run.destination];
            if (parts.scheme.length || [run.destination hasPrefix:@"//"]) continue;
            NSString* relative = parts.path;
            if (!relative.length || relative.isAbsolutePath || [relative.pathComponents containsObject:@".."]) continue;
            NSString* path = [source.stringByDeletingLastPathComponent stringByAppendingPathComponent:relative];
            stamps[path] = SPDFSearchFileStamp(path) ?: @"missing";
        }
        SPDFPaletteImageStamps(block.children,source,stamps);
    }
}
static NSArray<NSString*>* SPDFPaletteTextPages(NSDictionary* candidate, NSProgress* progress) {
    NSString* path = candidate[@"path"];
    if (progress.cancelled || ![path isKindOfClass:NSString.class] || !path.length) return @[];
    struct stat info = {}; stat(path.fileSystemRepresentation, &info);
    NSString* variant = [candidate[@"markdownLandscape"] boolValue] ? @"landscape" : @"portrait";
    NSDictionary* cached = SPDFSearchCachedFileValidated(path,variant,(NSUInteger)MAX((off_t)1,info.st_size)*8, ^BOOL(id value) {
        NSDictionary* stamps = value[@"dependencies"];
        for (NSString* dependency in stamps)
            if (![stamps[dependency] isEqual:SPDFSearchFileStamp(dependency) ?: @"missing"]) return NO;
        return YES;
    }, ^id {
        NSMutableDictionary* stamps = [NSMutableDictionary dictionary];
        NSMutableArray* pages = [NSMutableArray array];
        if (SPDFIsRenderedTextDocumentPath(path)) {
            SPDFMarkdownDocument* doc = [SPDFMarkdownDocument documentWithURL:[NSURL fileURLWithPath:path]
                                                                       options:nil error:nil];
            if (!SPDFIsSourceDocumentPath(path)) SPDFPaletteImageStamps(doc.model.blocks,path,stamps);
            SPDFMarkdownPageConfiguration* fallback = [candidate[@"markdownLandscape"] boolValue]
                ? [SPDFMarkdownPageConfiguration A4LandscapeConfiguration]
                : [SPDFMarkdownPageConfiguration A4PortraitConfiguration];
            SPDFMarkdownPaginationPlan* plan = [doc paginationPlanForConfiguration:doc.authoredPageConfiguration ?: fallback];
            NSString* text = doc.renderedDocument.attributedString.string;
            for (SPDFMarkdownPage* page in plan.pages) {
                if (pages.count >= 10000) break;
                NSMutableString* pageText = [NSMutableString string];
                for (SPDFMarkdownPageFragment* fragment in page.fragments) {
                    if (NSMaxRange(fragment.attributedRange) > text.length) continue;
                    if (pageText.length) [pageText appendString:@" "];
                    [pageText appendString:[text substringWithRange:fragment.attributedRange]];
                }
                [pages addObject:[pageText copy]];
            }
        } else {
            PDFDocument* pdf = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:path]];
            if (pdf.isLocked) return nil;
            for (NSUInteger page = 0; page < MIN(pdf.pageCount,(NSUInteger)10000); page++) {
                if (progress.cancelled) return nil;
                [pages addObject:[pdf pageAtIndex:page].string ?: @""];
            }
        }
        return @{@"pages":[pages copy], @"dependencies":[stamps copy]};
    });
    return cached[@"pages"] ?: @[];
}
static NSArray<NSDictionary*>* SPDFPaletteOpenTextMatches(NSArray<NSDictionary*>* candidates, NSString* query,
                                                          NSProgress* progress) {
    NSMutableArray* results = [NSMutableArray array];
    NSUInteger visitedDocuments = 0, visitedPages = 0;
    for (NSDictionary* candidate in candidates) {
        if (progress.cancelled || results.count == 5 || visitedDocuments++ >= 128 || visitedPages >= 10000) break;
        NSArray* pages = SPDFPaletteTextPages(candidate,progress);
        for (NSUInteger page = 0; page < pages.count && results.count < 5 && visitedPages++ < 10000; page++) {
            if (progress.cancelled) return @[];
            NSString* text = pages[page];
            NSRange match = [text rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch];
            if (match.location == NSNotFound) continue;
            NSUInteger start = match.location > 60 ? match.location - 60 : 0;
            NSString* snippet = spdf_collection_palette_single_line([text substringWithRange:NSMakeRange(start,
                MIN(MAX((NSUInteger)190,match.length + 60), text.length - start))]);
            [results addObject:@{@"kind":@"collectionOpenText",
                @"title":[NSString stringWithFormat:@"%@ · page %lu", candidate[@"title"], (unsigned long)page + 1],
                @"subtitle":snippet, @"path":candidate[@"path"], @"page":@(page), @"query":query}];
        }
    }
    return results;
}
