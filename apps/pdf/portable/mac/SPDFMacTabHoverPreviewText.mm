// Tab hover thumbnails of text pages: see SPDFMacTabHoverPreviewText.h.
#import "SPDFMacTabHoverPreviewText.h"

#import "SPDFMacMarkdownSessionPrivate.h"
#import "markdown/SPDFMarkdownDocument.h"

SPDFTabPreviewEntry* SPDFTabPreviewEntryForTextPage(SPDFMarkdownPaginationPlan* plan, NSAttributedString* text,
                                                    NSInteger pageIndex, CGFloat scale) {
    NSUInteger count = plan.pages.count;
    NSSize paper = plan.configuration.paperSize;
    NSSize points = SPDFTabPreviewPointSize(paper, kSPDFTabPreviewMaxPoints);
    if (!count || !text || points.width <= 0 || !(scale > 0)) return nil;
    NSUInteger page = (NSUInteger)MIN(MAX((NSInteger)0, pageIndex), (NSInteger)count - 1);
    size_t width = (size_t)lround(points.width * scale), height = (size_t)lround(points.height * scale);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    // Opaque, native byte order, like the page thumbnails scaled from pixels.
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                                                 kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextScaleCTM(context, (CGFloat)width / paper.width, (CGFloat)height / paper.height);
    // The paper's own colour first, then the page as the reader and print draw it.
    BOOL drew = [plan drawPageAtIndex:page attributedString:text inContext:context];
    CGImageRef image = drew ? CGBitmapContextCreateImage(context) : NULL;
    CGContextRelease(context);
    if (!image) return nil;
    SPDFTabPreviewEntry* entry = [[SPDFTabPreviewEntry alloc] initWithImage:image pointSize:points
                                                                  pageIndex:(NSInteger)page];
    CGImageRelease(image);
    entry.pageSize = paper;
    return entry;
}

SPDFTabPreviewEntry* SPDFTabPreviewEntryForTextFile(NSString* path, NSInteger pageIndex,
                                                    SPDFTabPreviewTextLayout layout, CGFloat scale) {
    @autoreleasepool {
        SPDFMarkdownRenderOptions* options = [SPDFMarkdownRenderOptions defaultOptionsForThemeVariant:layout.variant];
        options.fontScale = SPDFMacMarkdownClampFontScale(layout.fontScale);
        SPDFMarkdownPageOrientation orientation =
            layout.landscape ? SPDFMarkdownPageOrientationLandscape : SPDFMarkdownPageOrientationPortrait;
        options.pageContentSize = SPDFMacMarkdownPageContentSize(orientation);
        SPDFMarkdownPageConfiguration* paper = nil;
        SPDFMarkdownDocument* document =
            SPDFMacMarkdownLoadDocument([NSURL fileURLWithPath:path], options, orientation, nil, &paper, NULL);
        SPDFMarkdownRenderedDocument* rendered = document.renderedDocument;
        if (!rendered || !paper) return nil;
        SPDFMarkdownPaginationPlan* plan =
            SPDFMacMarkdownPlanForConfiguration(rendered, layout.variant, layout.preservesImageColors, paper);
        return SPDFTabPreviewEntryForTextPage(plan, rendered.attributedString, pageIndex, scale);
    }
}

NSString* SPDFTabPreviewTextStamp(NSString* path, SPDFTabPreviewTextLayout layout) {
    NSString* file = SPDFTabPreviewFileStamp(path);
    if (!file) return nil;
    return [NSString stringWithFormat:@"%@|text:%ld:%d:%.3f:%d", file, (long)layout.variant,
                                      layout.preservesImageColors ? 1 : 0, layout.fontScale, layout.landscape ? 1 : 0];
}
