#import "SPDFMacCollectionStorePrivate.h"
#import "markdown/SPDFMarkdownDocument.h"
#import "markdown/SPDFTextDocumentParser.h"

NSArray* SPDFCollectionMarkdownTextPages(NSData* bytes, NSString* path, NSArray* assets, NSURL* root) {
    Class documentClass=NSClassFromString(@"SPDFMarkdownDocument");
    if (!documentClass) {
        // Foundation-only storage tools can still search text, but must not invent rendered page numbers.
        NSString* text=SPDFIsSourceDocumentPath(path) ? SPDFDecodeSourceDocument(bytes,nil) :
            [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
        text=text ?: @"";
        if (text.length>2*1024*1024) text=[text substringToIndex:2*1024*1024];
        return text.length ? @[@{@"page":@0,@"text":text}] : @[];
    }
    // Rendering reads only this captured dependency tree, never newly changed live files or the network.
    NSURL* temporary=[[root URLByAppendingPathComponent:@"indexing"] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (!SPDFCollectionMakeDirectory(temporary,nil)) return @[];
    NSMutableArray* pages=[NSMutableArray array];
    @try {
        NSURL* source=[temporary URLByAppendingPathComponent:path.lastPathComponent];
        if (!SPDFCollectionAtomicData(bytes,source,0400,nil)) return @[];
        for (NSDictionary* asset in assets) {
            NSURL* target=[temporary URLByAppendingPathComponent:asset[@"relativePath"]];
            if (!SPDFCollectionMakeDirectory(target.URLByDeletingLastPathComponent,nil) ||
                !SPDFCollectionAtomicData(asset[@"data"],target,0400,nil)) return @[];
        }
        SPDFMarkdownDocument* doc=[documentClass documentWithURL:source options:nil error:nil];
        if (!doc) return @[];
        SPDFMarkdownPageConfiguration* config=doc.authoredPageConfiguration;
        if (!config) config=[NSClassFromString(@"SPDFMarkdownPageConfiguration") A4PortraitConfiguration];
        SPDFMarkdownPaginationPlan* plan=[doc paginationPlanForConfiguration:config];
        NSString* canonical=doc.renderedDocument.attributedString.string; NSUInteger total=0;
        for (SPDFMarkdownPage* page in plan.pages) {
            if (pages.count>=2000 || total>=2*1024*1024) break;
            NSRange range=NSMakeRange(NSNotFound,0);
            for (SPDFMarkdownPageFragment* fragment in page.fragments) {
                NSRange r=fragment.attributedRange;
                if (!r.length || NSMaxRange(r)>canonical.length) continue;
                range=range.location==NSNotFound ? r : NSUnionRange(range,r);
            }
            if (range.location==NSNotFound) continue;
            NSString* text=[canonical substringWithRange:range];
            if (text.length>65536) text=[text substringToIndex:65536];
            [pages addObject:@{@"page":@(page.pageIndex+1),@"text":text,
                              @"canonicalLocation":@(range.location)}]; total+=text.length;
        }
    } @catch (NSException* exception) {
        (void)exception; return @[];
    } @finally {
        [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
    }
    return pages;
}
