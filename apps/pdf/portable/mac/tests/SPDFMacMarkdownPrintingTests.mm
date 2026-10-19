#import <AppKit/AppKit.h>
#import <PDFKit/PDFKit.h>

#import "../SPDFMacMarkdownPrinting.h"
#import "../SPDFMacMarkdownSession.h"
#import "../markdown/SPDFMarkdown.h"

#include <assert.h>
#include <stdio.h>

// Rasterizes one page of a produced PDF at 1:1 (one pixel per point) so pixel
// probes address exact page-coordinate positions. yFromTop counts down from
// the paper's top edge, matching pagination-plan geometry.
static unsigned char* RasterizePage(NSData* data, size_t pageNumber, size_t* outWidth, size_t* outHeight) {
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGPDFDocumentRef document = provider ? CGPDFDocumentCreateWithProvider(provider) : NULL;
    CGPDFPageRef page = document ? CGPDFDocumentGetPage(document, pageNumber) : NULL;
    assert(page);
    CGRect mediaBox = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
    size_t width = (size_t)ceil(CGRectGetWidth(mediaBox));
    size_t height = (size_t)ceil(CGRectGetHeight(mediaBox));
    unsigned char* pixels = (unsigned char*)calloc(width * height, 4);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context =
        CGBitmapContextCreate(pixels, width, height, 8, width * 4, colorSpace, kCGImageAlphaPremultipliedLast);
    assert(context);
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGContextDrawPDFPage(context, page);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    CGPDFDocumentRelease(document);
    CGDataProviderRelease(provider);
    *outWidth = width;
    *outHeight = height;
    return pixels;
}

static const unsigned char* PixelAt(const unsigned char* pixels, size_t width, size_t height, CGFloat x,
                                    CGFloat yFromTop) {
    size_t column = (size_t)MIN((CGFloat)width - 1, MAX((CGFloat)0, round(x)));
    size_t row = (size_t)MIN((CGFloat)height - 1, MAX((CGFloat)0, round(yFromTop)));
    return pixels + (row * width + column) * 4;
}

static BOOL SpinUntil(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return condition();
}

int main(void) {
    @autoreleasepool {
        (void)NSApplication.sharedApplication;
        NSString* path = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"md"]];
        NSMutableString* markdown =
            [NSMutableString stringWithString:@"# Release Notes\n"
                                              @"Zanzibar anchors the geometry probe of this exported page.\n\n"
                                              @"```\nprint_safe();\n```\n\n"
                                              @"## Details\nA second section verifies heading pagination stays "
                                              @"selectable.\n\n## Appendix\n"];
        // Enough filler to overflow onto later pages, so single-page copies
        // can prove they capture exactly one page. Yggdrasil ends the text.
        for (int paragraph = 1; paragraph <= 40; ++paragraph)
            [markdown appendFormat:@"Filler paragraph %d keeps the appendix flowing toward another page.\n\n",
                                   paragraph];
        [markdown appendString:@"Yggdrasil closes the appendix on the final page.\n"];
        assert([markdown writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);

        // Build the exact rendition + plan the on-screen session uses: the
        // user's current font scale and the reserved language-control band.
        SPDFMarkdownRenderOptions* options = [SPDFMarkdownRenderOptions defaultOptions];
        options.fontScale = 1.5;
        SPDFMarkdownDocument* document = [SPDFMarkdownDocument documentWithURL:[NSURL fileURLWithPath:path]
                                                                       options:options
                                                                         error:nil];
        assert(document);
        SPDFMarkdownRenderedDocument* rendered = document.renderedDocument;
        SPDFMarkdownPaginator* paginator = [SPDFMarkdownPaginator new];
        SPDFMarkdownPageConfiguration* configuration = [SPDFMarkdownPageConfiguration A4PortraitConfiguration];
        configuration.includesCodeLanguageControlSpacing = YES;
        NSArray* items = [paginator measureRenderedDocument:rendered
                                             containerWidth:NSWidth(configuration.printableRect)];
        SPDFMarkdownPaginationPlan* plan = [paginator paginateItems:items configuration:configuration];
        assert(plan.pages.count >= 1);

        // The export plan is the screen plan: A4 geometry with the language
        // control band still reserved (the pill itself is screen chrome).
        assert(plan.configuration.includesCodeLanguageControlSpacing);
        SPDFMarkdownPaginationItem* codeItem = nil;
        for (SPDFMarkdownPaginationItem* item in plan.items)
            if (item.kind == SPDFMarkdownBlockKindCode) codeItem = item;
        assert(codeItem != nil && codeItem.lines.firstObject.attributedRange.length == 0 &&
               fabs(codeItem.lines.firstObject.height - 48.0) < 0.001);

        // Print never repaginates: the view keeps the given plan, and a
        // differing printer paper only scales the finished page, centered.
        NSPrintInfo* letter = [NSPrintInfo.sharedPrintInfo copy];
        letter.paperSize = NSMakeSize(612, 792);
        letter.leftMargin = 30;
        letter.rightMargin = 30;
        letter.topMargin = 30;
        letter.bottomMargin = 30;
        letter.scalingFactor = 1.0;
        NSPrintOperation* operation = [SPDFMacMarkdownPrintAdapter printOperationForPaginationPlan:plan
                                                                                  attributedString:rendered.attributedString
                                                                                         printInfo:letter];
        assert(operation.printPanel.options & NSPrintPanelShowsPreview);
        assert(operation.printPanel.options & NSPrintPanelShowsPaperSize);
        SPDFMacMarkdownPrintView* view = (SPDFMacMarkdownPrintView*)operation.view;
        assert([view isKindOfClass:SPDFMacMarkdownPrintView.class]);
        assert(view.paginationPlan == plan);
        NSRange range = NSMakeRange(0, 0);
        assert([view knowsPageRange:&range]);
        assert(range.location == 1 && range.length == plan.pages.count);
        NSRect pageRect = [view rectForPage:1];
        assert(NSEqualSizes(pageRect.size, plan.configuration.paperSize));
        NSPrintInfo* operationInfo = operation.printInfo;
        assert(operationInfo.horizontallyCentered && operationInfo.verticallyCentered);
        assert(operationInfo.scalingFactor > 0.5 && operationInfo.scalingFactor <= 1.0001);
        // Letter minus 30pt margins cannot hold a full A4 page unscaled.
        assert(operationInfo.scalingFactor < 0.999);

        // Save-as-PDF draws the plan's own pages; no NSPrintInfo involved.
        NSString* output = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"pdf"]];
        NSError* error = nil;
        assert([SPDFMacMarkdownPrintAdapter writePaginationPlan:plan
                                               attributedString:rendered.attributedString
                                                          toURL:[NSURL fileURLWithPath:output]
                                                          error:&error]);
        assert(!error);
        NSData* PDFData = [NSData dataWithContentsOfFile:output];
        PDFDocument* PDF = [[PDFDocument alloc] initWithData:PDFData];
        assert(PDF.pageCount == plan.pages.count);
        NSRect mediaBox = [[PDF pageAtIndex:0] boundsForBox:kPDFDisplayBoxMediaBox];
        assert(fabs(NSWidth(mediaBox) - plan.configuration.paperSize.width) < 0.5 &&
               fabs(NSHeight(mediaBox) - plan.configuration.paperSize.height) < 0.5);
        NSMutableString* text = [NSMutableString string];
        for (NSUInteger index = 0; index < PDF.pageCount; ++index)
            [text appendString:[PDF pageAtIndex:index].string ?: @""];
        assert([text containsString:@"Release Notes"]);
        assert([text containsString:@"Zanzibar"] && [text containsString:@"selectable"]);

        // Geometry probe: the probe word lands exactly where the screen plan
        // placed its line fragment (same margins, same scaled fonts).
        CGFloat printableLeft = NSMinX(plan.configuration.printableRect);
        CGFloat printableTopY = plan.configuration.paperSize.height - plan.configuration.topContentInset;
        NSUInteger probeLocation = [rendered.attributedString.string rangeOfString:@"Zanzibar"].location;
        assert(probeLocation != NSNotFound);
        SPDFMarkdownPageFragment* probeFragment = nil;
        NSUInteger probePageIndex = 0;
        for (SPDFMarkdownPage* page in plan.pages) {
            for (SPDFMarkdownPageFragment* fragment in page.fragments) {
                if (fragment.attributedRange.length && NSLocationInRange(probeLocation, fragment.attributedRange)) {
                    probeFragment = fragment;
                    probePageIndex = page.pageIndex;
                    break;
                }
            }
            if (probeFragment) break;
        }
        assert(probeFragment != nil);
        PDFSelection* found = [PDF findString:@"Zanzibar" withOptions:0].firstObject;
        assert(found != nil);
        PDFPage* foundPage = found.pages.firstObject;
        assert([PDF indexForPage:foundPage] == probePageIndex);
        NSRect foundBounds = [found boundsForPage:foundPage];
        CGFloat fragmentTopY = printableTopY - probeFragment.pageYOffset;
        CGFloat baselineY = fragmentTopY - probeFragment.baselineOffset;
        assert(fabs(NSMinX(foundBounds) - (printableLeft + probeFragment.xOffset)) < 3.0);
        assert(NSMaxY(foundBounds) <= fragmentTopY + 2.0);
        assert(NSMinY(foundBounds) >= fragmentTopY - probeFragment.height - 2.0);
        assert(NSMinY(foundBounds) <= baselineY + 1.0 && NSMaxY(foundBounds) > baselineY);

        // Raster probe: the code box paints its concrete fill exactly at the
        // decoration rect the screen canvas uses, and the margins stay paper.
        SPDFMarkdownPageDecoration* codeBox = nil;
        NSUInteger codePageIndex = 0;
        for (NSUInteger pageIndex = 0; pageIndex < plan.pages.count && !codeBox; ++pageIndex) {
            for (SPDFMarkdownPageDecoration* decoration in [plan decorationsForPageIndex:pageIndex]) {
                if (decoration.type == SPDFMarkdownPageDecorationTypeCodeBox) {
                    codeBox = decoration;
                    codePageIndex = pageIndex;
                    break;
                }
            }
        }
        assert(codeBox != nil);
        size_t rasterWidth = 0;
        size_t rasterHeight = 0;
        unsigned char* pixels = RasterizePage(PDFData, codePageIndex + 1, &rasterWidth, &rasterHeight);
        CGFloat topInset = plan.configuration.topContentInset;
        // Sample inside the box (right of the short code line) for the fill.
        const unsigned char* fill = PixelAt(pixels, rasterWidth, rasterHeight,
                                            printableLeft + NSMaxX(codeBox.rect) - 20.0,
                                            topInset + NSMidY(codeBox.rect));
        assert(abs((int)fill[0] - 246) <= 5 && abs((int)fill[1] - 248) <= 5 && abs((int)fill[2] - 250) <= 5);
        // Just above the box sits the unpainted outer margin (pure paper).
        const unsigned char* aboveBox = PixelAt(pixels, rasterWidth, rasterHeight,
                                                printableLeft + NSMidX(codeBox.rect),
                                                topInset + NSMinY(codeBox.rect) - 7.0);
        assert(aboveBox[0] >= 250 && aboveBox[1] >= 250 && aboveBox[2] >= 250);
        // The top margin above the printable area stays untouched paper.
        const unsigned char* margin =
            PixelAt(pixels, rasterWidth, rasterHeight, plan.configuration.paperSize.width * 0.5, topInset * 0.5);
        assert(margin[0] >= 250 && margin[1] >= 250 && margin[2] >= 250);
        free(pixels);

        // Copy Page: a single-page PDF containing exactly the asked-for page
        // at the plan's paper size — last page's probe word, no first-page one.
        assert(plan.pages.count >= 2);
        NSUInteger lastPage = plan.pages.count - 1;
        NSData* lastPageData = [SPDFMacMarkdownPrintAdapter PDFDataForPageAtIndex:lastPage
                                                                   paginationPlan:plan
                                                                 attributedString:rendered.attributedString];
        PDFDocument* lastPagePDF = [[PDFDocument alloc] initWithData:lastPageData];
        assert(lastPagePDF.pageCount == 1);
        NSRect copyBox = [[lastPagePDF pageAtIndex:0] boundsForBox:kPDFDisplayBoxMediaBox];
        assert(fabs(NSWidth(copyBox) - plan.configuration.paperSize.width) < 0.5 &&
               fabs(NSHeight(copyBox) - plan.configuration.paperSize.height) < 0.5);
        NSString* lastPageText = [lastPagePDF pageAtIndex:0].string ?: @"";
        assert([lastPageText containsString:@"Yggdrasil"] && ![lastPageText containsString:@"Zanzibar"]);
        NSData* firstPageData = [SPDFMacMarkdownPrintAdapter PDFDataForPageAtIndex:0
                                                                    paginationPlan:plan
                                                                  attributedString:rendered.attributedString];
        NSString* firstPageText = [[[PDFDocument alloc] initWithData:firstPageData] pageAtIndex:0].string ?: @"";
        assert([firstPageText containsString:@"Zanzibar"] && ![firstPageText containsString:@"Yggdrasil"]);
        assert(![SPDFMacMarkdownPrintAdapter PDFDataForPageAtIndex:plan.pages.count
                                                    paginationPlan:plan
                                                  attributedString:rendered.attributedString]);

        // Copy Page Image: a 2x raster of the same draw call — paper-sized in
        // points, white unpainted margins, and dark text pixels somewhere.
        NSBitmapImageRep* rep = [SPDFMacMarkdownPrintAdapter imageRepForPageAtIndex:0
                                                                     paginationPlan:plan
                                                                   attributedString:rendered.attributedString
                                                                              scale:2.0];
        assert(rep != nil);
        assert(rep.pixelsWide == (NSInteger)lround(plan.configuration.paperSize.width * 2.0));
        assert(rep.pixelsHigh == (NSInteger)lround(plan.configuration.paperSize.height * 2.0));
        assert(fabs(rep.size.width - plan.configuration.paperSize.width) < 0.5 &&
               fabs(rep.size.height - plan.configuration.paperSize.height) < 0.5);
        NSInteger cornerXs[] = {1, rep.pixelsWide - 2};
        NSInteger cornerYs[] = {1, rep.pixelsHigh - 2};
        for (NSInteger cornerX : cornerXs)
            for (NSInteger cornerY : cornerYs) {
                NSColor* corner = [rep colorAtX:cornerX y:cornerY];
                assert(corner.redComponent > 0.97 && corner.greenComponent > 0.97 && corner.blueComponent > 0.97);
            }
        BOOL foundDarkPixel = NO;
        for (NSInteger y = 0; y < rep.pixelsHigh && !foundDarkPixel; y += 2)
            for (NSInteger x = 0; x < rep.pixelsWide && !foundDarkPixel; x += 2) {
                NSColor* color = [rep colorAtX:x y:y];
                foundDarkPixel = color.redComponent < 0.35 && color.greenComponent < 0.35 &&
                                 color.blueComponent < 0.35;
            }
        assert(foundDarkPixel);

        // Pasteboard conventions match the PDF tab: Copy Page declares PDF
        // data plus a temp-file URL, Copy Page Image an NSImage (TIFF-backed).
        NSPasteboard* pagePasteboard = [NSPasteboard pasteboardWithUniqueName];
        assert([SPDFMacMarkdownPrintAdapter copyPageAtIndex:lastPage
                                             paginationPlan:plan
                                           attributedString:rendered.attributedString
                                                   fileName:@"printing-tests - page 2.pdf"
                                               toPasteboard:pagePasteboard]);
        NSData* pastedPDFData = [pagePasteboard dataForType:NSPasteboardTypePDF];
        PDFDocument* pastedPDF = [[PDFDocument alloc] initWithData:pastedPDFData];
        assert(pastedPDF.pageCount == 1 && [[pastedPDF pageAtIndex:0].string containsString:@"Yggdrasil"]);
        NSString* pastedURLString = [pagePasteboard stringForType:NSPasteboardTypeFileURL];
        NSURL* pastedURL = pastedURLString.length ? [NSURL URLWithString:pastedURLString] : nil;
        assert(pastedURL.isFileURL && [NSFileManager.defaultManager fileExistsAtPath:pastedURL.path]);
        NSPasteboard* imagePasteboard = [NSPasteboard pasteboardWithUniqueName];
        assert([SPDFMacMarkdownPrintAdapter copyPageImageAtIndex:0
                                                  paginationPlan:plan
                                                attributedString:rendered.attributedString
                                                    toPasteboard:imagePasteboard]);
        NSBitmapImageRep* pastedRep =
            [NSBitmapImageRep imageRepWithData:[imagePasteboard dataForType:NSPasteboardTypeTIFF]];
        assert(pastedRep != nil && pastedRep.pixelsWide == rep.pixelsWide && pastedRep.pixelsHigh == rep.pixelsHigh);
        [pagePasteboard releaseGlobally];
        [imagePasteboard releaseGlobally];
        [NSFileManager.defaultManager removeItemAtURL:pastedURL error:nil];

        // ---------------------------------------------------------------
        // Every Markdown export is the LIGHT rendition, whatever the reader
        // is showing. A file carrying our dark paper would be wrong wherever
        // it is opened next, which is exactly why the PDF side already exports
        // the document's own colors.
        // ---------------------------------------------------------------
        NSView* host = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
        dispatch_queue_t queue = dispatch_queue_create("markdown.export.test", DISPATCH_QUEUE_CONCURRENT);
        SPDFMacMarkdownSession* session =
            [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]];
        __block BOOL loaded = NO;
        [session activateInHostView:host
                          workQueue:queue
                       scrollOrigin:NSZeroPoint
                      selectedRange:NSMakeRange(0, 0)
                          pageIndex:0
                               zoom:1.0
                            fitMode:SPDFMacMarkdownPageFitPage
                             anchor:nil
                         completion:^(BOOL success, NSError* error) {
                           assert(success && !error);
                           loaded = YES;
                         }];
        assert(SpinUntil(
            ^BOOL {
              return loaded && session.paginationPlan != nil;
            },
            10.0));

        // LIGHT: the export rendition IS the live one. Identical objects —
        // proof that nothing extra is rendered, paginated or allocated on the
        // common path.
        assert(session.themeVariant == SPDFMarkdownThemeVariantLight);
        assert(session.exportPaginationPlan == session.paginationPlan);
        assert(session.exportAttributedString == session.renderedDocument.attributedString);

        // DARK: the screen goes dark, the export does not.
        __block NSUInteger themeRenders = 0;
        session.statusHandler = ^(NSString* status) {
          if ([status isEqualToString:@"Reading theme updated."]) themeRenders++;
        };
        [session applyThemeVariant:SPDFMarkdownThemeVariantDark];
        assert(SpinUntil(
            ^BOOL {
              return themeRenders == 1 &&
                     session.paginationPlan.configuration.themeVariant == SPDFMarkdownThemeVariantDark;
            },
            10.0));
        SPDFMarkdownPaginationPlan* exportPlan = session.exportPaginationPlan;
        NSAttributedString* exportText = session.exportAttributedString;
        assert(exportPlan != nil && exportText != nil);
        assert(exportPlan != session.paginationPlan);
        assert(exportPlan.configuration.themeVariant == SPDFMarkdownThemeVariantLight);
        // WYSIWYG in every respect except the palette: same paper, same page
        // breaks, same reserved language-control band.
        assert(exportPlan.pages.count == session.paginationPlan.pages.count);
        assert(fabs(exportPlan.configuration.paperSize.width - session.paginationPlan.configuration.paperSize.width) <
                   0.01 &&
               fabs(exportPlan.configuration.paperSize.height -
                    session.paginationPlan.configuration.paperSize.height) < 0.01);
        assert(exportPlan.configuration.includesCodeLanguageControlSpacing ==
               session.paginationPlan.configuration.includesCodeLanguageControlSpacing);
        // Built once and cached until the next rerender replaces the installed
        // rendition.
        assert(session.exportPaginationPlan == exportPlan && session.exportAttributedString == exportText);

        // The exported PDF really is light: white paper, dark body text.
        NSBitmapImageRep* darkThemeExport = [SPDFMacMarkdownPrintAdapter imageRepForPageAtIndex:0
                                                                                 paginationPlan:exportPlan
                                                                               attributedString:exportText
                                                                                          scale:1.0];
        assert(darkThemeExport != nil);
        NSColor* exportPaper = [darkThemeExport colorAtX:darkThemeExport.pixelsWide / 2 y:4];
        assert(exportPaper.redComponent > 0.99 && exportPaper.greenComponent > 0.99 &&
               exportPaper.blueComponent > 0.99);
        BOOL exportHasDarkText = NO;
        for (NSInteger y = 0; y < darkThemeExport.pixelsHigh && !exportHasDarkText; ++y)
            for (NSInteger x = 0; x < darkThemeExport.pixelsWide && !exportHasDarkText; ++x) {
                NSColor* color = [darkThemeExport colorAtX:x y:y];
                exportHasDarkText = color.redComponent < 0.35 && color.greenComponent < 0.35 &&
                                    color.blueComponent < 0.35;
            }
        assert(exportHasDarkText);

        // ...while the on-screen plan drawn with the same call is still dark
        // paper, so this is a real export-only substitution and not the theme
        // silently failing to apply.
        NSBitmapImageRep* screenRaster =
            [SPDFMacMarkdownPrintAdapter imageRepForPageAtIndex:0
                                                 paginationPlan:session.paginationPlan
                                               attributedString:session.renderedDocument.attributedString
                                                          scale:1.0];
        NSColor* screenPaper = [screenRaster colorAtX:screenRaster.pixelsWide / 2 y:4];
        assert(screenPaper.redComponent < 0.2 && screenPaper.greenComponent < 0.2 &&
               screenPaper.blueComponent < 0.2);

        // A rerender invalidates the cache: the next export is rebuilt, still
        // light, and still page-for-page with the new screen plan.
        [session applyFontScale:1.25];
        assert(SpinUntil(
            ^BOOL {
              return session.exportPaginationPlan != exportPlan;
            },
            10.0));
        assert(session.exportPaginationPlan.configuration.themeVariant == SPDFMarkdownThemeVariantLight);
        assert(session.exportPaginationPlan.pages.count == session.paginationPlan.pages.count);

        // Back to light: the export collapses onto the live plan again.
        [session applyThemeVariant:SPDFMarkdownThemeVariantLight];
        assert(SpinUntil(
            ^BOOL {
              return session.paginationPlan.configuration.themeVariant == SPDFMarkdownThemeVariantLight;
            },
            10.0));
        assert(session.exportPaginationPlan == session.paginationPlan);
        assert(session.exportAttributedString == session.renderedDocument.attributedString);
        [session deactivate];

        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        [NSFileManager.defaultManager removeItemAtPath:output error:nil];
        puts("SPDFMacMarkdownPrintingTests passed");
    }
    return 0;
}
