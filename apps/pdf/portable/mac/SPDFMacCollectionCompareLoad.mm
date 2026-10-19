#import "markdown/SPDFTextDocumentFormats.h"
#import "SPDFMacCollectionCompare.h"
#import "markdown/SPDFMarkdownDocument.h"
#import <CommonCrypto/CommonDigest.h>

extern NSData* SPDFCollectionPagePixels(PDFPage* page);
extern void SPDFCollectionComparePair(SPDFCollectionPagePair* pair, PDFPage* oldPage, PDFPage* newPage);

static BOOL fail(NSString* message, NSError** error) {
    if (error) *error = [NSError errorWithDomain:@"ShenzhenPDF.CollectionComparison" code:1
                                      userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}

static PDFDocument* LoadDocument(NSURL* URL, NSProgress* progress, BOOL comparison, NSError** error) {
    if (progress.cancelled) return nil;
    if (!URL.isFileURL) { fail(@"Preview requires a local document.", error); return nil; }
    NSNumber* byteCount = nil;
    [URL getResourceValue:&byteCount forKey:NSURLFileSizeKey error:nil];
    if (byteCount.unsignedLongLongValue > (comparison ? 256ULL : 512ULL)*1024*1024) {
        fail(comparison ? @"Comparison is limited to 256 MB per version. Save a smaller page range and compare that."
             : @"Preview is limited to 512 MB. Use Save a Copy to open the document separately.",error);
        return nil;
    }
    if (!SPDFIsRenderedTextDocumentPath(URL.path)) {
        // Own the bytes: a live source can be replaced while this window is
        // open. A URL-backed PDFDocument could otherwise change beneath it.
        NSData* data = [NSData dataWithContentsOfURL:URL options:0 error:error];
        PDFDocument* pdf = data ? [[PDFDocument alloc] initWithData:data] : nil;
        if (!pdf || pdf.isLocked) {
            fail(pdf.isLocked ? @"Unlock and export the protected document before previewing it."
                              : @"The document could not be read for preview.", error);
            return nil;
        }
        return pdf;
    }
    SPDFMarkdownDocument* markdown = [SPDFMarkdownDocument documentWithURL:URL options:nil error:error];
    if (!markdown || progress.cancelled) return nil;
    SPDFMarkdownPageConfiguration* configuration = markdown.authoredPageConfiguration ?:
        [SPDFMarkdownPageConfiguration A4PortraitConfiguration];
    SPDFMarkdownPaginationPlan* plan = [markdown paginationPlanForConfiguration:configuration];
    if (plan.pages.count > (comparison ? 1000UL : 2000UL)) {
        fail(comparison ? @"Comparison is limited to 1,000 pages per version."
            : @"Preview is limited to 2,000 pages. Use Save a Copy to open the complete document separately.",error);
        return nil;
    }
    NSMutableData* data = [NSMutableData data];
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)data);
    CGRect mediaBox = CGRectMake(0, 0, configuration.paperSize.width, configuration.paperSize.height);
    CGContextRef context = CGPDFContextCreate(consumer, &mediaBox, NULL);
    CGDataConsumerRelease(consumer);
    if (!context) { fail(@"Could not prepare the text preview pages.", error); return nil; }
    for (NSUInteger index = 0; index < plan.pages.count && !progress.cancelled; index++) {
        CGPDFContextBeginPage(context, NULL);
        [plan drawPageAtIndex:index attributedString:markdown.renderedDocument.attributedString inContext:context];
        CGPDFContextEndPage(context);
    }
    CGPDFContextClose(context);
    CGContextRelease(context);
    return progress.cancelled ? nil : [[PDFDocument alloc] initWithData:data];
}

PDFDocument* SPDFCollectionLoadPreviewDocument(NSURL* URL, NSProgress* progress, NSError** error) {
    return LoadDocument(URL,progress,NO,error);
}

static NSString* digest(NSData* data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString* hash = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(bytes); i++) [hash appendFormat:@"%02x", bytes[i]];
    return hash;
}

static NSData* fingerprintPixels(PDFPage* page, NSRange footerRange) {
    NSMutableData* pixels = [SPDFCollectionPagePixels(page) mutableCopy];
    if (footerRange.location == NSNotFound || pixels.length != 384*384*4) return pixels;
    NSRect box = [page boundsForBox:kPDFDisplayBoxMediaBox];
    for (PDFSelection* line in [[page selectionForRange:footerRange] selectionsByLine]) {
        NSRect rect = [line boundsForPage:page];
        int top = MAX(0,(int)floor((1-(NSMaxY(rect)-NSMinY(box))/MAX(1,box.size.height))*384)-2);
        int bottom = MIN(384,(int)ceil((1-(NSMinY(rect)-NSMinY(box))/MAX(1,box.size.height))*384)+2);
        // Erase the counter's whole horizontal band. Its centering and digit
        // widths change when a page is inserted; masking only its own glyph
        // bounds would give the two versions different fingerprint masks.
        if (top < bottom) memset((unsigned char*)pixels.mutableBytes+top*384*4,255,(bottom-top)*384*4);
    }
    return pixels;
}

static NSArray<NSString*>* pageKeys(PDFDocument* document, NSProgress* progress) {
    NSMutableArray* keys = [NSMutableArray array];
    NSRegularExpression* footer = [NSRegularExpression regularExpressionWithPattern:@"Page [0-9]+ of [0-9]+\\s*$"
                                                                           options:0 error:nil];
    NSCharacterSet* whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSUInteger index = 0; index < document.pageCount && !progress.cancelled; index++) {
        @autoreleasepool {
            PDFPage* page = [document pageAtIndex:index];
            NSString* text = page.string ?: @"";
            NSRange footerRange = [footer firstMatchInString:text options:0 range:NSMakeRange(0,text.length)].range;
            if (!footerRange.length) footerRange = NSMakeRange(NSNotFound,0);
            text = [footer stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0,text.length)
                                              withTemplate:@""];
            text = [[text componentsSeparatedByCharactersInSet:whitespace] componentsJoinedByString:@""];
            // Text alone aliases every figure/scan page bearing the same
            // header. Both components are needed even when selectable text
            // exists; only generated page-counter geometry is excluded.
            NSString* textHash = digest([text dataUsingEncoding:NSUTF8StringEncoding]);
            NSData* pixels = fingerprintPixels(page,footerRange);
            [keys addObject:[NSString stringWithFormat:@"%@:%@",textHash,digest(pixels ?: NSData.data)]];
            progress.completedUnitCount++;
        }
    }
    return keys;
}

SPDFCollectionComparison* SPDFCollectionBuildComparison(NSURL* oldURL, NSURL* newURL,
                                                       NSProgress* progress, NSError** error) {
    PDFDocument* oldDocument = LoadDocument(oldURL, progress, YES, error);
    if (!oldDocument || progress.cancelled) return nil;
    PDFDocument* updatedDocument = LoadDocument(newURL, progress, YES, error);
    if (!updatedDocument || progress.cancelled) return nil;
    if (MAX(oldDocument.pageCount, updatedDocument.pageCount) > 1000) {
        fail(@"Comparison is limited to 1,000 pages per version. Save a smaller page range and compare that.", error);
        return nil;
    }
    progress.totalUnitCount = (oldDocument.pageCount + updatedDocument.pageCount) * 2;
    NSArray* oldKeys = pageKeys(oldDocument, progress);
    NSArray* newKeys = pageKeys(updatedDocument, progress);
    if (progress.cancelled) return nil;
    NSArray* alignment = SPDFCollectionAlignPages(oldKeys, newKeys);
    NSMutableArray* pairs = [NSMutableArray array];
    NSUInteger regionCount = 0;
    for (NSArray* indices in alignment) {
        if (progress.cancelled) return nil;
        @autoreleasepool {
            SPDFCollectionPagePair* pair = [SPDFCollectionPagePair new];
            pair.oldIndex = [indices[0] integerValue];
            pair.newIndex = [indices[1] integerValue];
            PDFPage* oldPage = pair.oldIndex < 0 ? nil : [oldDocument pageAtIndex:pair.oldIndex];
            PDFPage* newPage = pair.newIndex < 0 ? nil : [updatedDocument pageAtIndex:pair.newIndex];
            if (oldPage && newPage && [oldKeys[pair.oldIndex] isEqual:newKeys[pair.newIndex]]) {
                // The hybrid signature already rendered unchanged pages, so
                // do not rasterize them again in the detailed-diff pass.
                pair.removedRects = @[]; pair.addedRects = @[];
            } else SPDFCollectionComparePair(pair, oldPage, newPage);
            regionCount += pair.removedRects.count + pair.addedRects.count;
            if (regionCount > 50000) {
                fail(@"These versions contain more than 50,000 changed regions. Compare a smaller page range.",error);
                return nil;
            }
            [pairs addObject:pair];
            progress.completedUnitCount += 2;
        }
    }
    SPDFCollectionComparison* result = [SPDFCollectionComparison new];
    result.oldDocument = oldDocument;
    result.updatedDocument = updatedDocument;
    result.pairs = pairs;
    progress.completedUnitCount = progress.totalUnitCount;
    return result;
}
