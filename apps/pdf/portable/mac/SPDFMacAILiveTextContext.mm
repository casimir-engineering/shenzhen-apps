#import "SPDFMacAIDocumentContext.h"
#import "SPDFMacSearchFileCache.h"
#import "markdown/SPDFMarkdownDocument.h"
#import "markdown/SPDFTextDocumentFormats.h"
#import <CommonCrypto/CommonDigest.h>
static id LiveError(NSError** error, NSString* text) {
    if (error) *error=[NSError errorWithDomain:@"ShenzhenPDF.AI.Context" code:1 userInfo:@{NSLocalizedDescriptionKey:text}];
    return nil;
}
NSDictionary* SPDFAIDocumentContextForCandidate(NSDictionary* candidate, NSUInteger first, NSUInteger limit,
    NSProgress* progress, NSError** error) {
    NSString* path=candidate[@"readPath"] ?: candidate[@"path"];
    if (!SPDFIsRenderedTextDocumentPath(path))
        return SPDFAIDocumentContext(path,[candidate[@"landscape"] boolValue],first,limit,progress,error);
    SPDFMarkdownRenderedDocument* rendered=candidate[@"renderedDocument"];
    SPDFMarkdownPaginationPlan* plan=candidate[@"paginationPlan"];
    if (![candidate[@"sourceRevision"] isEqual:candidate[@"revision"]])
        return LiveError(error,@"This text snapshot belongs to an earlier source revision. Wait for the reader to reload it.");
    if (!rendered || !plan) return LiveError(error,@"Open this text document in the reader first so page citations match its current text size and layout.");
    if (!first || !limit || limit>100 || first>plan.pages.count) return LiveError(error,@"Invalid page range.");
    if (progress.cancelled || ![candidate[@"revision"] isEqual:SPDFSearchFileStamp(path)])
        return LiveError(error,@"The document changed or reading was cancelled.");
    NSString* text=rendered.attributedString.string;
    NSMutableArray* pages=[NSMutableArray array], *outline=[NSMutableArray array]; NSUInteger characters=0;
    BOOL truncated=NO;
    __block CC_SHA256_CTX digest; CC_SHA256_Init(&digest);
    __block CC_SHA256_CTX compatibilityDigest; CC_SHA256_Init(&compatibilityDigest);
    NSMutableSet* fontSizes=[NSMutableSet set];
    SPDFMarkdownPageConfiguration* config=plan.configuration;
    CGFloat geometry[]={config.paperSize.width,config.paperSize.height,config.printableRect.origin.x,
        config.printableRect.origin.y,config.printableRect.size.width,config.printableRect.size.height,
        config.headingKeepThreshold,(CGFloat)config.includesCodeLanguageControlSpacing};
    CC_SHA256_Update(&digest,geometry,sizeof(geometry));
    CC_SHA256_Update(&compatibilityDigest,geometry,sizeof(geometry));
    // Resource dependencies come from the rendered image runs, including
    // placeholders, rather than scanning source examples for apparent paths.
    __block NSError* dependencyError=nil;
    __block BOOL dependencyFailed=NO;
    __block NSUInteger dependencyBytes=0;
    NSMutableDictionary* dependencyStamps=[NSMutableDictionary dictionary];
    [rendered.attributedString enumerateAttributesInRange:NSMakeRange(0,rendered.attributedString.length)
        options:0 usingBlock:^(NSDictionary* attrs,NSRange range,BOOL* stop) {
        NSFont* font=attrs[NSFontAttributeName];
        if (font) { [fontSizes addObject:@(font.pointSize)]; CGFloat size=font.pointSize; CC_SHA256_Update(&digest,&size,sizeof(size)); }
        NSString* target=attrs[SPDFMarkdownImageTargetAttribute];
        if (![target isKindOfClass:NSString.class] || !target.length) return;
        NSURL* URL=[NSURL URLWithString:target relativeToURL:[NSURL fileURLWithPath:path]];
        NSString* dependency=target.isAbsolutePath ? target : (URL.isFileURL ? URL.path : nil);
        if (dependency) {
            NSString* base=path.stringByDeletingLastPathComponent.stringByResolvingSymlinksInPath;
            dependency=dependency.stringByResolvingSymlinksInPath;
            // Match the renderer's resource boundary; refused image placeholders
            // must not turn analysis into a reader for arbitrary local files.
            if (![dependency hasPrefix:[base stringByAppendingString:@"/"]]) dependency=nil;
        }
        if (dependency && !dependencyStamps[dependency]) {
            NSString* stamp=SPDFSearchFileStamp(dependency) ?: @"missing";
            dependencyStamps[dependency]=stamp;
            if (![stamp isEqual:@"missing"]) {
                struct stat info={};
                if (stat(dependency.fileSystemRepresentation,&info) || !S_ISREG(info.st_mode) ||
                    info.st_size<0 || (NSUInteger)info.st_size>32*1024*1024-dependencyBytes || dependencyStamps.count>128) {
                    dependencyFailed=YES;*stop=YES;return;
                }
                dependencyBytes+=(NSUInteger)info.st_size;
                NSString* hash=SPDFAIContentHash(dependency,progress,&dependencyError);
                if (!hash) { dependencyFailed=YES; *stop=YES;return; }
                NSData* content=[hash dataUsingEncoding:NSUTF8StringEncoding];
                CC_SHA256_Update(&digest,content.bytes,(CC_LONG)content.length);
                CC_SHA256_Update(&compatibilityDigest,content.bytes,(CC_LONG)content.length);
            }
        }
        NSTextAttachment* attachment=attrs[NSAttachmentAttributeName];
        if (attachment) {
            NSRect bounds=attachment.bounds; CC_SHA256_Update(&digest,&bounds,sizeof(bounds));
            // Remote images are already decoded by the reader. Fingerprint that
            // snapshot without initiating a download or consulting a resource store.
            if (!dependency && attachment.image) {
                NSUInteger pixels=0;
                for (NSImageRep* rep in attachment.image.representations)
                    pixels+=MAX((NSInteger)0,rep.pixelsWide)*MAX((NSInteger)0,rep.pixelsHigh);
                if (pixels>8*1024*1024) { dependencyFailed=YES;*stop=YES;return; }
                NSData* bytes=attachment.image.TIFFRepresentation;
                if (!bytes || bytes.length>32*1024*1024-dependencyBytes) {
                    dependencyFailed=YES;*stop=YES;return;
                }
                dependencyBytes+=bytes.length;
                CC_SHA256_Update(&digest,bytes.bytes,(CC_LONG)bytes.length);
                CC_SHA256_Update(&compatibilityDigest,bytes.bytes,(CC_LONG)bytes.length);
            }
        }
    }];
    if (dependencyFailed || progress.cancelled) return LiveError(error,@"Image dependency changed while reading.");
    NSData* textBytes=[text dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA256_Update(&digest,textBytes.bytes,(CC_LONG)textBytes.length);
    // Include the actual page-fragment boundaries, not only source bytes or
    // font preference: assets and language controls can also alter pagination.
    for (SPDFMarkdownPage* page in plan.pages) {
        uint64_t marker=UINT64_MAX; CC_SHA256_Update(&digest,&marker,sizeof(marker));
        for (SPDFMarkdownPageFragment* fragment in page.fragments) {
            CGFloat geometry[]={fragment.pageYOffset,fragment.height,fragment.xOffset,fragment.baselineOffset,fragment.scale};
            CC_SHA256_Update(&digest,geometry,sizeof(geometry));
            uint64_t range[2]={fragment.attributedRange.location,fragment.attributedRange.length};
            CC_SHA256_Update(&digest,range,sizeof(range));
        }
    }
    for (NSNumber* size in [fontSizes.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        double value=size.doubleValue;CC_SHA256_Update(&compatibilityDigest,&value,sizeof(value));
    }
    unsigned char compatibilityBytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(compatibilityBytes,&compatibilityDigest);
    NSMutableString* compatibility=[NSMutableString string];
    for (NSUInteger i=0;i<sizeof(compatibilityBytes);i++) [compatibility appendFormat:@"%02x",compatibilityBytes[i]];
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(bytes,&digest);
    NSMutableString* identity=[NSMutableString string];
    for (NSUInteger i=0;i<sizeof(bytes);i++) [identity appendFormat:@"%02x",bytes[i]];
    for (SPDFMarkdownRenderedHeading* heading in rendered.headings) {
        NSUInteger destination=0;
        for (SPDFMarkdownPage* page in plan.pages) {
            BOOL found=NO;
            for (SPDFMarkdownPageFragment* fragment in page.fragments)
                if (NSLocationInRange(heading.attributedRange.location,fragment.attributedRange)) { found=YES; break; }
            if (found) break; destination++;
        }
        if (destination<plan.pages.count && outline.count<1000)
            [outline addObject:@{@"title":heading.title ?: @"",@"page":@(destination+1),@"level":@(heading.level)}];
    }
    for (NSUInteger index=first-1;index<MIN(plan.pages.count,first-1+limit);index++) {
        if (progress.cancelled) return LiveError(error,@"Cancelled.");
        NSMutableString* pageText=[NSMutableString string];
        for (SPDFMarkdownPageFragment* fragment in plan.pages[index].fragments)
            if (NSMaxRange(fragment.attributedRange)<=text.length) {
                [pageText appendString:[text substringWithRange:fragment.attributedRange]]; [pageText appendString:@"\n"];
                if (pageText.length>=100000) { truncated=YES; break; }
            }
        if (pageText.length>100000) [pageText setString:SPDFAIBoundedText(pageText,100000)];
        [pages addObject:@{@"page":@(index+1),@"text":pageText}]; characters+=pageText.length;
        if (characters>=1000000) { truncated=YES; break; }
    }
    if (![candidate[@"revision"] isEqual:SPDFSearchFileStamp(path)]) return LiveError(error,@"Document changed while reading.");
    for (NSString* dependency in dependencyStamps)
        if (![dependencyStamps[dependency] isEqual:SPDFSearchFileStamp(dependency) ?: @"missing"])
            return LiveError(error,@"Image dependency changed while reading.");
    NSUInteger next=first+pages.count;
    return @{@"revision":candidate[@"revision"],@"layoutIdentity":identity,@"revisionCompatibility":compatibility,@"pageCount":@(plan.pages.count),@"pages":pages,
        @"outline":outline,@"truncated":@(truncated || next<=plan.pages.count),@"nextPage":next<=plan.pages.count ? @(next) : NSNull.null};
}
