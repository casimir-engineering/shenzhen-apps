#import "SPDFMarkdownTestSupport.h"

#import <PDFKit/PDFKit.h>

#import "../../markdown/SPDFMarkdownDocument.h"
#import "../../markdown/SPDFMarkdownDiagram.h"
#import "../../markdown/SPDFMarkdownTableDecorations.h"

static NSData* SPDFCreatePDF(SPDFMarkdownPaginationPlan* plan, NSAttributedString* string) {
    NSMutableData* data = [NSMutableData data];
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)data);
    CGRect mediaBox = CGRectMake(0, 0, plan.configuration.paperSize.width, plan.configuration.paperSize.height);
    CGContextRef context = CGPDFContextCreate(consumer, &mediaBox, NULL);
    for (NSUInteger page = 0; page < plan.pages.count; ++page) {
        CGPDFContextBeginPage(context, NULL);
        [plan drawPageAtIndex:page attributedString:string inContext:context];
        CGPDFContextEndPage(context);
    }
    CGPDFContextClose(context);
    CGContextRelease(context);
    CGDataConsumerRelease(consumer);
    return data;
}

static NSString* SPDFImageRoot; // removed by exact path at exit, so a failed check still leaves nothing behind
static void SPDFRemoveImageRoot(void) { [NSFileManager.defaultManager removeItemAtPath:SPDFImageRoot error:nil]; }
static NSURL* SPDFCreateImageDocument(void) {
    NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES
                                             attributes:nil error:nil];
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                      pixelsWide:96 pixelsHigh:480 bitsPerSample:8
                                                                    samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                    colorSpaceName:NSCalibratedRGBColorSpace
                                                                       bytesPerRow:0 bitsPerPixel:0];
    for (NSInteger y = 0; y < bitmap.pixelsHigh; ++y) {
        unsigned char* row = bitmap.bitmapData + y * bitmap.bytesPerRow;
        for (NSInteger x = 0; x < bitmap.pixelsWide; ++x) {
            row[x * 4 + 0] = 255;
            row[x * 4 + 1] = 0;
            row[x * 4 + 2] = 255;
            row[x * 4 + 3] = 255;
        }
    }
    NSData* PNG = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [PNG writeToFile:[root stringByAppendingPathComponent:@"local.png"] atomically:YES];
    NSString* documentPath = [root stringByAppendingPathComponent:@"image.md"];
    [@"# Exported image\n\n![Magenta proof](local.png)\n\nAfter image\n"
        writeToFile:documentPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    SPDFImageRoot = root;
    atexit(SPDFRemoveImageRoot);
    return [NSURL fileURLWithPath:documentPath];
}

static CGRect SPDFPDFMagentaBounds(NSData* data) {
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGPDFDocumentRef document = provider ? CGPDFDocumentCreateWithProvider(provider) : NULL;
    size_t width = 596;
    size_t height = 842;
    unsigned char* pixels = (unsigned char*)calloc(width * height, 4);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = pixels ? CGBitmapContextCreate(pixels, width, height, 8, width * 4, colorSpace,
                                                           kCGImageAlphaPremultipliedLast) : NULL;
    NSInteger minimumX = (NSInteger)width;
    NSInteger minimumY = (NSInteger)height;
    NSInteger maximumX = -1;
    NSInteger maximumY = -1;
    size_t pageCount = document ? CGPDFDocumentGetNumberOfPages(document) : 0;
    for (size_t pageIndex = 1; context && pageIndex <= pageCount && maximumX < 0; ++pageIndex) {
        CGPDFPageRef page = CGPDFDocumentGetPage(document, pageIndex);
        CGRect mediaBox = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
        CGContextSaveGState(context);
        CGContextSetRGBFillColor(context, 1, 1, 1, 1);
        CGContextFillRect(context, CGRectMake(0, 0, width, height));
        CGFloat scale = MIN(width / CGRectGetWidth(mediaBox), height / CGRectGetHeight(mediaBox));
        CGContextScaleCTM(context, scale, scale);
        CGContextDrawPDFPage(context, page);
        CGContextRestoreGState(context);
        for (size_t y = 0; y < height; ++y) {
            for (size_t x = 0; x < width; ++x) {
                unsigned char* pixel = pixels + (y * width + x) * 4;
                if (pixel[0] > 220 && pixel[1] < 120 && pixel[2] > 220) {
                    minimumX = MIN(minimumX, (NSInteger)x);
                    minimumY = MIN(minimumY, (NSInteger)y);
                    maximumX = MAX(maximumX, (NSInteger)x);
                    maximumY = MAX(maximumY, (NSInteger)y);
                }
            }
        }
    }
    if (context) CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    free(pixels);
    if (document) CGPDFDocumentRelease(document);
    if (provider) CGDataProviderRelease(provider);
    if (maximumX < 0) return CGRectNull;
    return CGRectMake(minimumX, minimumY, maximumX - minimumX + 1, maximumY - minimumY + 1);
}

static BOOL SPDFPDFContainsMagentaImage(NSData* data) {
    return !CGRectIsNull(SPDFPDFMagentaBounds(data));
}

// Counts raster pixels on page 1 within `tolerance` of one concrete RGB value.
static NSUInteger SPDFPDFPixelCountNear(NSData* data, int red, int green, int blue, int tolerance) {
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGPDFDocumentRef document = provider ? CGPDFDocumentCreateWithProvider(provider) : NULL;
    CGPDFPageRef page = document ? CGPDFDocumentGetPage(document, 1) : NULL;
    size_t width = 596;
    size_t height = 842;
    unsigned char* pixels = (unsigned char*)calloc(width * height, 4);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = pixels ? CGBitmapContextCreate(pixels, width, height, 8, width * 4, colorSpace,
                                                           kCGImageAlphaPremultipliedLast) : NULL;
    NSUInteger matched = 0;
    if (context && page) {
        CGContextSetRGBFillColor(context, 1, 1, 1, 1);
        CGContextFillRect(context, CGRectMake(0, 0, width, height));
        CGContextDrawPDFPage(context, page);
        for (size_t index = 0; index < width * height; ++index) {
            unsigned char* pixel = pixels + index * 4;
            if (abs((int)pixel[0] - red) <= tolerance && abs((int)pixel[1] - green) <= tolerance &&
                abs((int)pixel[2] - blue) <= tolerance)
                ++matched;
        }
    }
    if (context) CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    free(pixels);
    if (document) CGPDFDocumentRelease(document);
    if (provider) CGDataProviderRelease(provider);
    return matched;
}

// Counts raster pixels close to the concrete #F6F8FA code-box fill on page 1.
static NSUInteger SPDFPDFCodeBoxFillPixelCount(NSData* data) {
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGPDFDocumentRef document = provider ? CGPDFDocumentCreateWithProvider(provider) : NULL;
    CGPDFPageRef page = document ? CGPDFDocumentGetPage(document, 1) : NULL;
    size_t width = 596;
    size_t height = 842;
    unsigned char* pixels = (unsigned char*)calloc(width * height, 4);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = pixels ? CGBitmapContextCreate(pixels, width, height, 8, width * 4, colorSpace,
                                                           kCGImageAlphaPremultipliedLast) : NULL;
    if (context && page) {
        CGContextSetRGBFillColor(context, 1, 1, 1, 1);
        CGContextFillRect(context, CGRectMake(0, 0, width, height));
        CGContextDrawPDFPage(context, page);
    }
    NSUInteger filled = 0;
    if (context && page) {
        for (size_t index = 0; index < width * height; ++index) {
            unsigned char* pixel = pixels + index * 4;
            if (abs((int)pixel[0] - 246) <= 6 && abs((int)pixel[1] - 248) <= 6 && abs((int)pixel[2] - 250) <= 5)
                ++filled;
        }
    }
    if (context) CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    free(pixels);
    if (document) CGPDFDocumentRelease(document);
    if (provider) CGDataProviderRelease(provider);
    return filled;
}

// Rasterizes page 1 and reads the RGB value at one top-down pixel coordinate.
static BOOL SPDFPDFPixelOnFirstPage(NSData* data, NSInteger x, NSInteger y, unsigned char rgb[3]) {
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGPDFDocumentRef document = provider ? CGPDFDocumentCreateWithProvider(provider) : NULL;
    CGPDFPageRef page = document ? CGPDFDocumentGetPage(document, 1) : NULL;
    size_t width = 596;
    size_t height = 842;
    unsigned char* pixels = (unsigned char*)calloc(width * height, 4);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = pixels ? CGBitmapContextCreate(pixels, width, height, 8, width * 4, colorSpace,
                                                           kCGImageAlphaPremultipliedLast) : NULL;
    BOOL sampled = NO;
    if (context && page && x >= 0 && y >= 0 && (size_t)x < width && (size_t)y < height) {
        CGContextSetRGBFillColor(context, 1, 1, 1, 1);
        CGContextFillRect(context, CGRectMake(0, 0, width, height));
        CGContextDrawPDFPage(context, page);
        unsigned char* pixel = pixels + ((size_t)y * width + (size_t)x) * 4;
        rgb[0] = pixel[0];
        rgb[1] = pixel[1];
        rgb[2] = pixel[2];
        sampled = YES;
    }
    if (context) CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    free(pixels);
    if (document) CGPDFDocumentRelease(document);
    if (provider) CGDataProviderRelease(provider);
    return sampled;
}

// Image XObjects on the first page: the proof that an export carries no
// embedded bitmap (a native diagram must be pure vector).
static size_t SPDFPDFImageXObjectCount(NSData* data) {
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGPDFDocumentRef document = provider ? CGPDFDocumentCreateWithProvider(provider) : NULL;
    CGPDFPageRef page = document ? CGPDFDocumentGetPage(document, 1) : NULL;
    CGPDFDictionaryRef pageDictionary = page ? CGPDFPageGetDictionary(page) : NULL;
    CGPDFDictionaryRef resources = NULL;
    CGPDFDictionaryRef xObjects = NULL;
    size_t count = 0;
    if (pageDictionary && CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources) &&
        CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects))
        count = CGPDFDictionaryGetCount(xObjects);
    if (document) CGPDFDocumentRelease(document);
    if (provider) CGDataProviderRelease(provider);
    return count;
}

static BOOL SPDFPixelNear(const unsigned char rgb[3], int red, int green, int blue, int tolerance) {
    return abs((int)rgb[0] - red) <= tolerance && abs((int)rgb[1] - green) <= tolerance &&
           abs((int)rgb[2] - blue) <= tolerance;
}

static NSUInteger SPDFPDFDarkPixelCount(NSData* data) {
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGPDFDocumentRef document = provider ? CGPDFDocumentCreateWithProvider(provider) : NULL;
    CGPDFPageRef page = document ? CGPDFDocumentGetPage(document, 1) : NULL;
    size_t width = 596;
    size_t height = 842;
    unsigned char* pixels = (unsigned char*)calloc(width * height, 4);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = pixels ? CGBitmapContextCreate(pixels, width, height, 8, width * 4, colorSpace,
                                                           kCGImageAlphaPremultipliedLast) : NULL;
    if (context && page) {
        CGContextSetRGBFillColor(context, 1, 1, 1, 1);
        CGContextFillRect(context, CGRectMake(0, 0, width, height));
        CGContextDrawPDFPage(context, page);
    }
    NSUInteger dark = 0;
    if (context && page) {
        for (size_t index = 0; index < width * height; ++index) {
            unsigned char* pixel = pixels + index * 4;
            if (pixel[0] < 100 && pixel[1] < 100 && pixel[2] < 100) ++dark;
        }
    }
    if (context) CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    free(pixels);
    if (document) CGPDFDocumentRelease(document);
    if (provider) CGDataProviderRelease(provider);
    return dark;
}

int main(void) {
    @autoreleasepool {
        NSError* error = nil;
        SPDFMarkdownDocument* document = [SPDFMarkdownDocument documentWithURL:SPDFFixtureURL(@"commonmark-gfm.md")
                                                                        options:nil error:&error];
        SPDFMarkdownPageConfiguration* configuration = SPDFMarkdownPageConfiguration.A4PortraitConfiguration;
        SPDFMarkdownPaginationPlan* plan = [document paginationPlanForConfiguration:configuration];
        NSData* data = SPDFCreatePDF(plan, document.renderedDocument.attributedString);
        PDFDocument* PDF = [[PDFDocument alloc] initWithData:data];
        SPDFExpect(PDF.pageCount == plan.pages.count && PDF.pageCount > 0,
                   @"drawable plan produces the planned page count");
        PDFPage* first = [PDF pageAtIndex:0];
        NSRect mediaBox = [first boundsForBox:kPDFDisplayBoxMediaBox];
        SPDFExpect(fabs(NSWidth(mediaBox) - 595.2756) < 0.1 && fabs(NSHeight(mediaBox) - 841.8898) < 0.1,
                   @"PDF MediaBox is A4 portrait");
        NSString* extracted = PDF.string ?: @"";
        SPDFExpect([extracted containsString:@"Shenzhen PDF Markdown"],
                   @"PDF text remains vector/selectable and extractable");
        SPDFExpect([extracted containsString:@"Finished task"],
                   @"structural content remains selectable in the PDF adapter");
        SPDFExpect(SPDFPDFCodeBoxFillPixelCount(data) > 2000,
                   @"exported fenced code paints one continuous filled box behind the code lines");
        BOOL plannedCodeBox = NO;
        for (NSUInteger pageIndex = 0; pageIndex < plan.pages.count; ++pageIndex)
            for (SPDFMarkdownPageDecoration* decoration in [plan decorationsForPageIndex:pageIndex])
                if (decoration.type == SPDFMarkdownPageDecorationTypeCodeBox &&
                    fabs(NSWidth(decoration.rect) - NSWidth(configuration.printableRect)) < 0.01)
                    plannedCodeBox = YES;
        SPDFExpect(plannedCodeBox, @"the export plan exposes full-width code-box decoration geometry");
        __block NSData* darkAppearancePDF = nil;
        [[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua] performAsCurrentDrawingAppearance:^{
            darkAppearancePDF = SPDFCreatePDF(plan, document.renderedDocument.attributedString);
        }];
        PDFDocument* darkPDF = [[PDFDocument alloc] initWithData:darkAppearancePDF];
        SPDFExpect([(darkPDF.string ?: @"") containsString:@"Shenzhen PDF Markdown"] &&
                       SPDFPDFDarkPixelCount(darkAppearancePDF) > 500,
                   @"dark appearance exports selectable dark text through a concrete print palette");

        // Table chrome raster probe: the header band paints its Primer gray on
        // paper, unstriped body rows stay paper white, and the striped row
        // carries its very subtle fill. Sample x sits just inside the table's
        // measured right edge, well clear of the short left-aligned cell
        // glyphs and of the column-boundary hairlines.
        SPDFMarkdownParser* tableParser = [SPDFMarkdownParser new];
        SPDFMarkdownDocumentModel* tableModel =
            [tableParser parseString:@"| A | B | C |\n| --- | --- | --- |\n| a1 | b1 | c1 |\n| a2 | b2 | c2 |\n"
                           sourceURL:nil
                               error:&error];
        SPDFMarkdownDocument* tableDocument =
            [[SPDFMarkdownDocument alloc] initWithModel:tableModel
                                                 options:SPDFMarkdownRenderOptions.defaultOptions];
        SPDFMarkdownPaginationPlan* tablePlan = [tableDocument paginationPlanForConfiguration:configuration];
        SPDFMarkdownPageDecoration* headerBand = nil;
        SPDFMarkdownPageDecoration* stripeBand = nil;
        NSUInteger tableGridLines = 0;
        for (SPDFMarkdownPageDecoration* decoration in [tablePlan decorationsForPageIndex:0]) {
            if (decoration.type == SPDFMarkdownPageDecorationTypeTableHeaderBand) headerBand = decoration;
            if (decoration.type == SPDFMarkdownPageDecorationTypeTableStripe) stripeBand = decoration;
            if (decoration.type == SPDFMarkdownPageDecorationTypeTableGridLine) ++tableGridLines;
        }
        SPDFExpect(headerBand != nil && stripeBand != nil && tableGridLines == 8,
                   @"the exported table plan holds a header band, one stripe, and the full 8-line grid");
        NSData* tablePDF = SPDFCreatePDF(tablePlan, tableDocument.renderedDocument.attributedString);
        NSArray<NSNumber*>* tableColumnBoundaries = nil;
        for (SPDFMarkdownPaginationItem* item in tablePlan.items)
            if (item.tableRowInfo) tableColumnBoundaries = item.tableRowInfo.columnBoundaries;
        SPDFExpect(tableColumnBoundaries.count == 4 &&
                       fabs(NSWidth(headerBand.rect) - tableColumnBoundaries.lastObject.doubleValue) < 0.001,
                   @"the exported header band spans the measured column boundaries");
        CGFloat probeX = NSMinX(configuration.printableRect) + tableColumnBoundaries.lastObject.doubleValue - 6;
        CGFloat probeTop = configuration.topContentInset;
        unsigned char headerRGB[3] = {0, 0, 0};
        unsigned char plainRGB[3] = {0, 0, 0};
        unsigned char stripeRGB[3] = {0, 0, 0};
        BOOL headerSampled = SPDFPDFPixelOnFirstPage(tablePDF, lround(probeX),
                                                     lround(probeTop + NSMidY(headerBand.rect)), headerRGB);
        // The unstriped first body row sits between the header band and stripe.
        CGFloat plainRowMidY = (NSMaxY(headerBand.rect) + NSMinY(stripeBand.rect)) / 2;
        BOOL plainSampled = SPDFPDFPixelOnFirstPage(tablePDF, lround(probeX),
                                                    lround(probeTop + plainRowMidY), plainRGB);
        BOOL stripeSampled = SPDFPDFPixelOnFirstPage(tablePDF, lround(probeX),
                                                     lround(probeTop + NSMidY(stripeBand.rect)), stripeRGB);
        SPDFExpect(headerSampled && SPDFPixelNear(headerRGB, 234, 238, 242, 3),
                   @"the exported header row paints the concrete #EAEEF2 band, darker than the stripe");
        SPDFExpect(plainSampled && SPDFPixelNear(plainRGB, 255, 255, 255, 2),
                   @"an unstriped body row stays paper white in the exported PDF");
        SPDFExpect(stripeSampled && SPDFPixelNear(stripeRGB, 250, 251, 252, 2),
                   @"the striped body row carries the subtle #FAFBFC fill in the exported PDF");

        // WYSIWYG dark export: a Dark-theme plan (dark render options + dark
        // page configuration, exactly what the session builds) paints the
        // Obsidian #1E1E1E paper and #262626 code boxes into the PDF while the
        // text stays vector-selectable. LIGHT stays the explicit expectation
        // of every probe above.
        SPDFMarkdownRenderOptions* darkOptions =
            [SPDFMarkdownRenderOptions defaultOptionsForThemeVariant:SPDFMarkdownThemeVariantDark];
        SPDFMarkdownDocument* darkDocument = [SPDFMarkdownDocument documentWithURL:SPDFFixtureURL(@"commonmark-gfm.md")
                                                                            options:darkOptions
                                                                              error:&error];
        SPDFMarkdownPageConfiguration* darkConfiguration = SPDFMarkdownPageConfiguration.A4PortraitConfiguration;
        darkConfiguration.themeVariant = SPDFMarkdownThemeVariantDark;
        SPDFExpect(((SPDFMarkdownPageConfiguration*)[darkConfiguration copy]).themeVariant ==
                           SPDFMarkdownThemeVariantDark &&
                       SPDFMarkdownPageConfiguration.A4PortraitConfiguration.themeVariant ==
                           SPDFMarkdownThemeVariantLight,
                   @"page configurations copy their theme variant and default to Light");
        SPDFMarkdownPaginationPlan* darkPlan = [darkDocument paginationPlanForConfiguration:darkConfiguration];
        NSData* darkThemeData = SPDFCreatePDF(darkPlan, darkDocument.renderedDocument.attributedString);
        PDFDocument* darkThemePDF = [[PDFDocument alloc] initWithData:darkThemeData];
        SPDFExpect([(darkThemePDF.string ?: @"") containsString:@"Shenzhen PDF Markdown"],
                   @"dark-theme export keeps vector/selectable text");
        unsigned char darkPaperRGB[3] = {0, 0, 0};
        SPDFExpect(SPDFPDFPixelOnFirstPage(darkThemeData, 8, 8, darkPaperRGB) &&
                       SPDFPixelNear(darkPaperRGB, 30, 30, 30, 2),
                   @"dark-theme export paints the Obsidian #1E1E1E paper edge to edge");
        SPDFExpect(SPDFPDFPixelCountNear(darkThemeData, 38, 38, 38, 3) > 2000,
                   @"dark-theme export paints one continuous #262626 code box behind the code lines");

        // Native diagrams export as VECTOR artwork with SELECTABLE text: the
        // labels come back out of the PDF as text, the node boxes paint their
        // concrete #F6F8FA fill as paths, and the page carries no image
        // XObject at all (no bitmap is produced anywhere on this path).
        SPDFMarkdownDocumentModel* diagramModel =
            [tableParser parseString:@"```mermaid\ngraph TD\n  A[Ingest] --> B[Publish]\n```\n"
                           sourceURL:nil
                               error:&error];
        SPDFMarkdownDocument* diagramDocument =
            [[SPDFMarkdownDocument alloc] initWithModel:diagramModel
                                                 options:SPDFMarkdownRenderOptions.defaultOptions];
        SPDFMarkdownPaginationPlan* diagramPlan = [diagramDocument paginationPlanForConfiguration:configuration];
        NSData* diagramPDF = SPDFCreatePDF(diagramPlan, diagramDocument.renderedDocument.attributedString);
        PDFDocument* diagramPDFDocument = [[PDFDocument alloc] initWithData:diagramPDF];
        NSString* diagramPageText = [diagramPDFDocument pageAtIndex:0].string ?: @"";
        SPDFExpect([diagramPageText containsString:@"Ingest"] && [diagramPageText containsString:@"Publish"],
                   @"diagram labels export as SELECTABLE PDF text");
        SPDFExpect(SPDFPDFImageXObjectCount(diagramPDF) == 0,
                   @"an exported diagram embeds NO bitmap: its artwork is vector paths");
        SPDFExpect(SPDFPDFPixelCountNear(diagramPDF, 246, 248, 250, 3) > 500,
                   @"the exported diagram paints its node boxes with the concrete #F6F8FA fill");
        SPDFMarkdownPageDecoration* diagramDecoration = nil;
        for (SPDFMarkdownPageDecoration* decoration in [diagramPlan decorationsForPageIndex:0])
            if (decoration.type == SPDFMarkdownPageDecorationTypeDiagram) diagramDecoration = decoration;
        SPDFExpect(diagramDecoration != nil && diagramDecoration.diagramLayout.shapes.count > 0 &&
                       fabs(NSWidth(diagramDecoration.rect) - diagramDecoration.diagramLayout.size.width) < 0.01,
                   @"the export plan exposes one diagram decoration carrying the resolved vector shapes");
        PDFSelection* diagramSelection = [diagramPDFDocument findString:@"Ingest" withOptions:0].firstObject;
        NSRect diagramLabelBounds = diagramSelection
                                        ? [diagramSelection boundsForPage:diagramSelection.pages.firstObject]
                                        : NSZeroRect;
        CGFloat decorationBottom = configuration.paperSize.height - configuration.topContentInset -
                                   NSMaxY(diagramDecoration.rect);
        SPDFExpect(diagramSelection != nil && NSMinY(diagramLabelBounds) >= decorationBottom - 2 &&
                       NSMaxY(diagramLabelBounds) <=
                           decorationBottom + NSHeight(diagramDecoration.rect) + 2,
                   @"an exported diagram label sits inside its own diagram artwork box");

        SPDFMarkdownDocument* imageDocument = [SPDFMarkdownDocument documentWithURL:SPDFCreateImageDocument()
                                                                             options:nil error:&error];
        SPDFMarkdownPaginationPlan* imagePlan =
            [imageDocument paginationPlanForConfiguration:SPDFMarkdownPageConfiguration.A4PortraitConfiguration];
        NSData* imagePDF = SPDFCreatePDF(imagePlan, imageDocument.renderedDocument.attributedString);
        PDFDocument* imagePDFDocument = [[PDFDocument alloc] initWithData:imagePDF];
        SPDFExpect([(imagePDFDocument.string ?: @"") containsString:@"Magenta proof"],
                   @"local-image captions remain selectable in PDF output");
        SPDFExpect(SPDFPDFContainsMagentaImage(imagePDF),
                   @"a real local image attachment is painted into the exported PDF");
        __block NSUInteger attachmentLocation = NSNotFound;
        [imageDocument.renderedDocument.attributedString
            enumerateAttribute:NSAttachmentAttributeName
                       inRange:NSMakeRange(0, imageDocument.renderedDocument.attributedString.length)
                       options:0
                    usingBlock:^(id attachment, NSRange range, BOOL* stop) {
            if (attachment) {
                attachmentLocation = range.location;
                *stop = YES;
            }
        }];
        SPDFMarkdownPageFragment* imageFragment = nil;
        for (SPDFMarkdownPageFragment* fragment in imagePlan.pages.firstObject.fragments) {
            if (attachmentLocation != NSNotFound && NSLocationInRange(attachmentLocation, fragment.attributedRange)) {
                imageFragment = fragment;
                break;
            }
        }
        CGRect magentaBounds = SPDFPDFMagentaBounds(imagePDF);
        CGFloat fragmentBottom = configuration.paperSize.height - NSMinY(configuration.printableRect) -
                                 imageFragment.pageYOffset - imageFragment.height;
        CGFloat fragmentTop = fragmentBottom + imageFragment.height;
        CGFloat imageBottom = configuration.paperSize.height - CGRectGetMaxY(magentaBounds);
        CGFloat imageTop = configuration.paperSize.height - CGRectGetMinY(magentaBounds);
        SPDFExpect(imageFragment && !CGRectIsNull(magentaBounds) &&
                       imageBottom >= fragmentBottom - 2 && imageTop <= fragmentTop + 2,
                   @"PDF attachments remain inside their exact TextKit line fragment without covering adjacent text");

        SPDFMarkdownPageConfiguration* smallPaper =
            [SPDFMarkdownPageConfiguration configurationForPaperSize:NSMakeSize(120, 120)
                                                        printableRect:NSMakeRect(20, 20, 80, 80)];
        SPDFMarkdownPaginationPlan* smallPlan = [imageDocument paginationPlanForConfiguration:smallPaper];
        BOOL foundScaledFragment = NO;
        for (SPDFMarkdownPage* page in smallPlan.pages)
            for (SPDFMarkdownPageFragment* fragment in page.fragments)
                if (fragment.scale < 0.999) foundScaledFragment = YES;
        NSData* smallPDF = SPDFCreatePDF(smallPlan, imageDocument.renderedDocument.attributedString);
        SPDFExpect(foundScaledFragment && SPDFPDFContainsMagentaImage(smallPDF),
                   @"over-tall local images are scaled into small printable pages and remain visible");

        // Asymmetric printable rects (NSPrintInfo-style top != bottom margins)
        // must anchor content to the TOP margin. Paper 500x700 with printable
        // (40, 30, 420, 600): top margin 70, bottom margin 30, so the first
        // baseline sits at NSMaxY(printable) - baselineOffset = 630 - 15 = 615.
        // The old NSMinY-based math drew it 40pt higher, at 700 - 30 - 15 = 655.
        SPDFMarkdownPageConfiguration* asymmetric =
            [SPDFMarkdownPageConfiguration configurationForPaperSize:NSMakeSize(500, 700)
                                                        printableRect:NSMakeRect(40, 30, 420, 600)];
        SPDFExpect(fabs(asymmetric.topContentInset - 70) < 0.001 &&
                       fabs(SPDFMarkdownPageConfiguration.A4PortraitConfiguration.topContentInset - 61.2) < 0.001,
                   @"topContentInset reports the true top margin, not the bottom one");
        NSString* probeText = @"BaselineProbe";
        NSAttributedString* probeString = [[NSAttributedString alloc]
            initWithString:probeText
                attributes:@{
                    NSFontAttributeName : [NSFont systemFontOfSize:14],
                    NSForegroundColorAttributeName : NSColor.blackColor,
                }];
        SPDFMarkdownTextLine* probeLine =
            [[SPDFMarkdownTextLine alloc] initWithAttributedRange:NSMakeRange(0, probeText.length)
                                                           height:20
                                                          xOffset:0
                                                   baselineOffset:15];
        SPDFMarkdownPaginationItem* probeItem =
            [[SPDFMarkdownPaginationItem alloc] initWithBlockIndex:0
                                                              kind:SPDFMarkdownBlockKindParagraph
                                                      headingLevel:0
                                                             lines:@[ probeLine ]];
        SPDFMarkdownPaginationPlan* asymmetricPlan = [[SPDFMarkdownPaginator new] paginateItems:@[ probeItem ]
                                                                                  configuration:asymmetric];
        PDFDocument* asymmetricPDF = [[PDFDocument alloc] initWithData:SPDFCreatePDF(asymmetricPlan, probeString)];
        PDFSelection* probeSelection = [asymmetricPDF findString:probeText withOptions:0].firstObject;
        NSRect probeBounds = probeSelection
                                 ? [probeSelection boundsForPage:probeSelection.pages.firstObject]
                                 : NSZeroRect;
        CGFloat expectedBaseline = NSMaxY(asymmetric.printableRect) - probeLine.baselineOffset;
        SPDFExpect(probeSelection != nil && NSMaxY(probeBounds) <= NSMaxY(asymmetric.printableRect) + 2 &&
                       NSMinY(probeBounds) >= NSMaxY(asymmetric.printableRect) - probeLine.height - 2 &&
                       NSMinY(probeBounds) <= expectedBaseline + 1 && NSMaxY(probeBounds) > expectedBaseline &&
                       fabs(NSMinX(probeBounds) - NSMinX(asymmetric.printableRect)) < 3,
                   @"asymmetric margins draw the first baseline at NSMaxY(printable) - baselineOffset");
    }
    return SPDFFinishTests(@"SPDFMarkdownPDFAdapterTests");
}
