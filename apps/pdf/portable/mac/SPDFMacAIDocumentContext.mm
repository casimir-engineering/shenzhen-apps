#import "SPDFMacAIDocumentContext.h"
#import "SPDFMacSearchFileCache.h"
#import "markdown/SPDFTextDocumentFormats.h"
#import "markdown/SPDFMarkdownDocument.h"
#import <CommonCrypto/CommonDigest.h>
#include "shenzhen_pdf_core.h"

static id ContextError(NSError** error, NSString* message) {
    if (error) *error=[NSError errorWithDomain:@"ShenzhenPDF.AI.Context" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return nil;
}
NSString* SPDFAIBoundedText(NSString* text, NSUInteger max) {
    if (text.length<=max) return text;
    if (!max) return @"";
    NSRange boundary=[text rangeOfComposedCharacterSequenceAtIndex:max];
    return [text substringToIndex:boundary.location];
}
NSString* SPDFAIContentHash(NSString* path, NSProgress* progress, NSError** error) {
    NSString* stamp=SPDFSearchFileStamp(path);
    NSInputStream* stream=[NSInputStream inputStreamWithFileAtPath:path];
    [stream open];
    CC_SHA256_CTX context; CC_SHA256_Init(&context);
    uint8_t bytes[65536]; NSInteger count;
    while (!progress.cancelled && (count=[stream read:bytes maxLength:sizeof(bytes)])>0)
        CC_SHA256_Update(&context,bytes,(CC_LONG)count);
    NSError* failure=stream.streamError; [stream close];
    if (failure || progress.cancelled || !stamp || ![stamp isEqual:SPDFSearchFileStamp(path)])
        return ContextError(error,progress.cancelled ? @"Cancelled." : @"Document changed or could not be read.");
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest,&context);
    NSMutableString* result=[NSMutableString stringWithCapacity:64];
    for (NSUInteger i=0;i<sizeof(digest);i++) [result appendFormat:@"%02x",digest[i]];
    return result;
}
static NSDictionary* ExtractContext(NSString* path, BOOL landscape, NSUInteger firstPage,
    NSUInteger pageLimit, NSProgress* progress, NSError** error) {
    if (!path.isAbsolutePath || !firstPage || !pageLimit || pageLimit>100)
        return ContextError(error,@"Request 1–100 pages beginning at a positive page number.");
    if (progress.cancelled) return ContextError(error,@"Cancelled.");
    struct stat info={};
    if (stat(path.fileSystemRepresentation,&info) || !S_ISREG(info.st_mode) || info.st_size>256LL*1024*1024)
        return ContextError(error,@"Document is unavailable or exceeds the 256 MiB analysis budget.");
    NSString* stamp=SPDFSearchFileStamp(path);
    NSMutableArray* pages=[NSMutableArray array]; NSMutableArray* outline=[NSMutableArray array];
    NSUInteger count=0, characters=0; BOOL truncated=NO;
    if (SPDFIsRenderedTextDocumentPath(path)) {
        SPDFMarkdownDocument* doc=[SPDFMarkdownDocument documentWithURL:[NSURL fileURLWithPath:path] options:nil error:error];
        if (!doc) return nil;
        SPDFMarkdownPageConfiguration* config=landscape ? [SPDFMarkdownPageConfiguration A4LandscapeConfiguration] :
            [SPDFMarkdownPageConfiguration A4PortraitConfiguration];
        SPDFMarkdownPaginationPlan* plan=[doc paginationPlanForConfiguration:doc.authoredPageConfiguration ?: config];
        count=plan.pages.count;
        NSString* text=doc.renderedDocument.attributedString.string;
        for (SPDFMarkdownRenderedHeading* heading in doc.renderedDocument.headings) {
            NSUInteger destination=0;
            for (SPDFMarkdownPage* page in plan.pages) {
                BOOL found=NO;
                for (SPDFMarkdownPageFragment* fragment in page.fragments)
                    if (NSLocationInRange(heading.attributedRange.location,fragment.attributedRange)) { found=YES; break; }
                if (found) break; destination++;
            }
            if (destination<count && outline.count<1000) [outline addObject:@{@"title":SPDFAIBoundedText(heading.title,256),
                @"page":@(destination+1),@"level":@(heading.level)}];
        }
        for (NSUInteger index=firstPage-1;index<MIN(count,firstPage-1+pageLimit);index++) {
            if (progress.cancelled) return ContextError(error,@"Cancelled.");
            NSMutableString* pageText=[NSMutableString string];
            for (SPDFMarkdownPageFragment* fragment in plan.pages[index].fragments)
                if (NSMaxRange(fragment.attributedRange)<=text.length) {
                    [pageText appendString:[text substringWithRange:fragment.attributedRange]];
                    [pageText appendString:@"\n"];
                }
            NSString* bounded=SPDFAIBoundedText(pageText,100000);
            if (bounded.length<pageText.length) truncated=YES;
            characters+=bounded.length;
            [pages addObject:@{@"page":@(index+1),@"text":bounded}];
            if (characters>=1000000) { truncated=YES; break; }
        }
    } else {
        char message[1024]={}; spdf_document* doc=spdf_open(path.fileSystemRepresentation,message,sizeof(message));
        if (!doc) return ContextError(error,@"Document is locked or cannot be read.");
        count=MAX(0,spdf_page_count(doc)); spdf_outline headings={};
        if (spdf_load_outline(doc,&headings,message,sizeof(message)))
            for (int i=0;i<headings.count && i<1000;i++) {
                spdf_outline_item item=headings.items[i];
                if (item.page_index>=0 && item.page_index<(int)count)
                    [outline addObject:@{@"title":SPDFAIBoundedText(item.title ? [NSString stringWithUTF8String:item.title] : @"",256),
                        @"page":@(item.page_index+1),@"level":@(item.level+1)}];
            }
        spdf_free_outline(&headings);
        for (NSUInteger index=firstPage-1;index<MIN(count,firstPage-1+pageLimit) && !progress.cancelled;index++) {
            spdf_text_lines lines={}; NSMutableString* text=[NSMutableString string];
            if (!spdf_extract_page_text_lines(doc,(int)index,&lines,message,sizeof(message))) {
                spdf_free_text_lines(&lines); spdf_close(doc); return ContextError(error,@"Page text extraction failed.");
            }
            for (int i=0;i<lines.count;i++) {
                NSString* line=lines.items[i].text ? [NSString stringWithUTF8String:lines.items[i].text] : @"";
                [text appendString:line ?: @""]; [text appendString:@"\n"];
                if (text.length>=100000) { truncated=YES; break; }
            }
            spdf_free_text_lines(&lines); NSString* bounded=SPDFAIBoundedText(text,100000); characters+=bounded.length;
            [pages addObject:@{@"page":@(index+1),@"text":bounded}];
            if (characters>=1000000) { truncated=YES; break; }
        }
        spdf_close(doc);
    }
    if (progress.cancelled) return ContextError(error,@"Cancelled.");
    if (![stamp isEqual:SPDFSearchFileStamp(path)]) return ContextError(error,@"Document changed during extraction. Retry.");
    if (firstPage>count) return ContextError(error,@"Page is outside the document.");
    NSUInteger next=firstPage+pages.count;
    return @{@"revision":stamp,@"pageCount":@(count),@"pages":pages,@"outline":outline,
        @"truncated":@(truncated || next<=count),@"nextPage":next<=count ? @(next) : NSNull.null};
}
NSDictionary* SPDFAIDocumentContext(NSString* path, BOOL landscape, NSUInteger firstPage,
    NSUInteger pageLimit, NSProgress* progress, NSError** error) {
    if (progress.cancelled) return ContextError(error,@"Cancelled.");
    // Native fixed-layout pages are immutable under a file stamp. Repeated
    // questions reuse the existing bounded search cache rather than parsing
    // the document again; text layouts use their explicit live snapshot path.
    if (SPDFIsRenderedTextDocumentPath(path)) return ExtractContext(path,landscape,firstPage,pageLimit,progress,error);
    __block NSError* failure=nil;
    NSString* variant=[NSString stringWithFormat:@"ai-pages-v1-%lu-%lu",(unsigned long)firstPage,(unsigned long)pageLimit];
    NSDictionary* value=SPDFSearchCachedFile(path,variant,2*1024*1024,^id {
        return ExtractContext(path,landscape,firstPage,pageLimit,progress,&failure);
    });
    if (progress.cancelled) return ContextError(error,@"Cancelled.");
    if (!value && error) *error=failure ?: [NSError errorWithDomain:@"ShenzhenPDF.AI.Context" code:1
        userInfo:@{NSLocalizedDescriptionKey:@"Document changed or could not be read."}];
    return value;
}
NSArray<NSDictionary*>* SPDFAISearchContext(NSDictionary* context, NSString* query, NSUInteger limit) {
    NSMutableArray* matches=[NSMutableArray array];
    if (!query.length || !limit) return matches;
    for (NSDictionary* page in context[@"pages"]) {
        NSString* text=page[@"text"]; NSRange remaining=NSMakeRange(0,text.length);
        while (remaining.length && matches.count<MIN(limit,(NSUInteger)50)) {
            NSRange hit=[text rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch range:remaining];
            if (hit.location==NSNotFound) break;
            NSUInteger start=hit.location>100 ? hit.location-100 : 0, end=MIN(text.length,NSMaxRange(hit)+160);
            [matches addObject:@{@"page":page[@"page"],@"text":[text substringWithRange:NSMakeRange(start,end-start)],
                @"matchOffset":@(hit.location-start),@"matchLength":@(hit.length),@"revision":context[@"revision"] ?: @""}];
            remaining=NSMakeRange(NSMaxRange(hit),text.length-NSMaxRange(hit));
        }
        if (matches.count>=MIN(limit,(NSUInteger)50)) break;
    }
    return matches;
}
