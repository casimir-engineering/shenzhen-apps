#import "SPDFMacMarkdownPrinting.h"

#import <CoreGraphics/CoreGraphics.h>

#import "markdown/SPDFMarkdown.h"

@interface SPDFMacMarkdownPrintView ()
- (void)fitPlanPaperToPrintInfo:(NSPrintInfo*)info;
@end

@implementation SPDFMacMarkdownPrintView

- (instancetype)initWithPaginationPlan:(SPDFMarkdownPaginationPlan*)plan
                      attributedString:(NSAttributedString*)attributedString {
    NSSize paper = plan.configuration.paperSize;
    NSUInteger pageCount = MAX((NSUInteger)1, plan.pages.count);
    self = [super initWithFrame:NSMakeRect(0, 0, MAX(1.0, paper.width), MAX(1.0, paper.height) * pageCount)];
    if (self) {
        _paginationPlan = plan;
        _attributedString = [attributedString copy];
    }
    return self;
}

- (BOOL)isFlipped { return NO; }

// The plan's paper is authoritative; a differing printer paper only scales
// the finished page (centered), it never re-flows or re-margins the content.
- (void)fitPlanPaperToPrintInfo:(NSPrintInfo*)info {
    NSSize paper = _paginationPlan.configuration.paperSize;
    if (!info || paper.width <= 0 || paper.height <= 0) return;
    CGFloat savedScaling = info.scalingFactor;
    info.scalingFactor = 1.0;
    NSRect imageable = info.imageablePageBounds;
    info.scalingFactor = savedScaling;
    if (NSWidth(imageable) < 1 || NSHeight(imageable) < 1) return;
    CGFloat scale = MIN(NSWidth(imageable) / paper.width, NSHeight(imageable) / paper.height);
    if (!isfinite(scale) || scale <= 0) return;
    info.scalingFactor = MIN(1.0, scale);
    info.horizontallyCentered = YES;
    info.verticallyCentered = YES;
}

- (BOOL)knowsPageRange:(NSRangePointer)range {
    [self fitPlanPaperToPrintInfo:NSPrintOperation.currentOperation.printInfo];
    range->location = 1;
    range->length = MAX((NSUInteger)1, _paginationPlan.pages.count);
    return YES;
}

- (NSRect)rectForPage:(NSInteger)page {
    NSSize paper = _paginationPlan.configuration.paperSize;
    return NSMakeRect(0, paper.height * MAX((NSInteger)0, page - 1), paper.width, paper.height);
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSPrintOperation* operation = NSPrintOperation.currentOperation;
    NSInteger page = operation ? operation.currentPage : 1;
    NSUInteger index = page > 0 ? (NSUInteger)(page - 1) : 0;
    if (index >= _paginationPlan.pages.count) return;
    NSRect pageRect = [self rectForPage:page];
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, pageRect.origin.x, pageRect.origin.y);
    [_paginationPlan drawPageAtIndex:index attributedString:_attributedString inContext:context];
    CGContextRestoreGState(context);
}

@end

@implementation SPDFMacMarkdownPrintAdapter

+ (NSPrintOperation*)printOperationForPaginationPlan:(SPDFMarkdownPaginationPlan*)plan
                                    attributedString:(NSAttributedString*)attributedString
                                           printInfo:(NSPrintInfo*)printInfo {
    NSPrintInfo* effectiveInfo = [printInfo copy] ?: [NSPrintInfo.sharedPrintInfo copy];
    // Start the panel on paper turned the way the document was flowed, so a
    // landscape Markdown document prints at full size instead of being shrunk
    // onto a portrait sheet. Only the STARTING value: the panel still shows its
    // orientation control, and overruling it just falls back to the scale-to-fit
    // rule below, which is what any other paper mismatch already gets.
    effectiveInfo.orientation = plan.configuration.orientation == SPDFMarkdownPageOrientationLandscape
                                    ? NSPaperOrientationLandscape
                                    : NSPaperOrientationPortrait;
    SPDFMacMarkdownPrintView* view = [[SPDFMacMarkdownPrintView alloc] initWithPaginationPlan:plan
                                                                             attributedString:attributedString];
    [view fitPlanPaperToPrintInfo:effectiveInfo];
    NSPrintOperation* operation = [NSPrintOperation printOperationWithView:view printInfo:effectiveInfo];
    operation.printPanel.options |= NSPrintPanelShowsPreview | NSPrintPanelShowsPaperSize |
                                    NSPrintPanelShowsOrientation;
    operation.showsPrintPanel = YES;
    operation.showsProgressPanel = YES;
    return operation;
}

// Draws the plan's pages in pageRange into a fresh PDF at the plan's paper
// size; both the full-document write and the single-page copy consume this.
static NSData* SPDFMarkdownPlanPDFData(SPDFMarkdownPaginationPlan* plan, NSAttributedString* attributedString,
                                       NSRange pageRange) {
    if (!plan || !attributedString || pageRange.length == 0) return nil;
    if (NSMaxRange(pageRange) > plan.pages.count) return nil;
    NSMutableData* data = [NSMutableData data];
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)data);
    CGRect mediaBox = CGRectMake(0, 0, plan.configuration.paperSize.width, plan.configuration.paperSize.height);
    CGContextRef context = CGPDFContextCreate(consumer, &mediaBox, NULL);
    CGDataConsumerRelease(consumer);
    if (!context) return nil;
    for (NSUInteger page = pageRange.location; page < NSMaxRange(pageRange); ++page) {
        CGPDFContextBeginPage(context, NULL);
        [plan drawPageAtIndex:page attributedString:attributedString inContext:context];
        CGPDFContextEndPage(context);
    }
    CGPDFContextClose(context);
    CGContextRelease(context);
    return data;
}

+ (BOOL)writePaginationPlan:(SPDFMarkdownPaginationPlan*)plan
           attributedString:(NSAttributedString*)attributedString
                      toURL:(NSURL*)URL
                      error:(NSError**)error {
    if (!URL.isFileURL) return NO;
    NSData* data = SPDFMarkdownPlanPDFData(plan, attributedString, NSMakeRange(0, plan.pages.count));
    return data && [data writeToURL:URL options:NSDataWritingAtomic error:error];
}

+ (NSData*)PDFDataForPageAtIndex:(NSUInteger)pageIndex
                  paginationPlan:(SPDFMarkdownPaginationPlan*)plan
                attributedString:(NSAttributedString*)attributedString {
    return SPDFMarkdownPlanPDFData(plan, attributedString, NSMakeRange(pageIndex, 1));
}

+ (NSBitmapImageRep*)imageRepForPageAtIndex:(NSUInteger)pageIndex
                             paginationPlan:(SPDFMarkdownPaginationPlan*)plan
                           attributedString:(NSAttributedString*)attributedString
                                      scale:(CGFloat)scale {
    if (!plan || !attributedString || pageIndex >= plan.pages.count || scale <= 0) return nil;
    NSSize paper = plan.configuration.paperSize;
    NSInteger pixelsWide = (NSInteger)lround(paper.width * scale);
    NSInteger pixelsHigh = (NSInteger)lround(paper.height * scale);
    if (pixelsWide < 1 || pixelsHigh < 1) return nil;
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                    pixelsWide:pixelsWide
                                                                    pixelsHigh:pixelsHigh
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSCalibratedRGBColorSpace
                                                                   bytesPerRow:0
                                                                  bitsPerPixel:0];
    NSGraphicsContext* graphicsContext = rep ? [NSGraphicsContext graphicsContextWithBitmapImageRep:rep] : nil;
    if (!graphicsContext) return nil;
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = graphicsContext;
    CGContextRef context = graphicsContext.CGContext;
    CGContextScaleCTM(context, scale, scale);
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, paper.width, paper.height));
    [plan drawPageAtIndex:pageIndex attributedString:attributedString inContext:context];
    [graphicsContext flushGraphics];
    [NSGraphicsContext restoreGraphicsState];
    rep.size = paper;
    return rep;
}

+ (BOOL)copyPageAtIndex:(NSUInteger)pageIndex
         paginationPlan:(SPDFMarkdownPaginationPlan*)plan
       attributedString:(NSAttributedString*)attributedString
               fileName:(NSString*)fileName
           toPasteboard:(NSPasteboard*)pasteboard {
    NSData* data = [self PDFDataForPageAtIndex:pageIndex paginationPlan:plan attributedString:attributedString];
    if (!data || !pasteboard || !fileName.length) return NO;
    NSPasteboardItem* item = [[NSPasteboardItem alloc] init];
    [item setData:data forType:NSPasteboardTypePDF];
    NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ShenzhenPDF-copy"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    NSString* tempPath = [directory stringByAppendingPathComponent:fileName];
    if ([data writeToFile:tempPath atomically:YES])
        [item setString:[NSURL fileURLWithPath:tempPath].absoluteString forType:NSPasteboardTypeFileURL];
    [pasteboard clearContents];
    return [pasteboard writeObjects:@[ item ]];
}

+ (BOOL)copyPageImageAtIndex:(NSUInteger)pageIndex
              paginationPlan:(SPDFMarkdownPaginationPlan*)plan
            attributedString:(NSAttributedString*)attributedString
                toPasteboard:(NSPasteboard*)pasteboard {
    NSBitmapImageRep* rep = [self imageRepForPageAtIndex:pageIndex
                                          paginationPlan:plan
                                        attributedString:attributedString
                                                   scale:2.0];
    if (!rep || !pasteboard) return NO;
    NSImage* image = [[NSImage alloc] initWithSize:rep.size];
    [image addRepresentation:rep];
    [pasteboard clearContents];
    return [pasteboard writeObjects:@[ image ]];
}

@end
