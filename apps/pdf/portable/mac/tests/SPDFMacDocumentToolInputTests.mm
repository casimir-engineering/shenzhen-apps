#define SPDF_TEXT_DOCUMENT_FORMAT_TESTING 1
#import "SPDFMacDocumentToolInput.h"
#import "SPDFMacDocumentFormats.h"
#import "SPDFMacTranslationPolicy.h"
#import <ImageIO/ImageIO.h>
#import <PDFKit/PDFKit.h>
#include "shenzhen_pdf_core.h"

static void Check(BOOL condition, NSString* message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static NSString* Read(NSString* root, NSString* name) {
    return [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:name]
        encoding:NSUTF8StringEncoding error:nil] ?: @"";
}
int main(int argc, const char* argv[]) {
    @autoreleasepool {
        Check(argc == 3, @"fixtures and repository required");
        NSString* folder = @(argv[1]); NSString* root = [@(argv[2]) stringByAppendingPathComponent:@"portable/mac"];
        // A path that does not exist still offers OCR: this must be pure policy,
        // never a file read, catalog initialization, or toolchain lookup at launch.
        for (NSString* ext in @[@"PDF", @"png", @"jpg", @"tiff", @"gif", @"bmp", @"jp2", @"jbig2", @"psd", @"svg"])
            Check(SPDFOCRPathSupported([@"/absent/document." stringByAppendingString:ext]), ext);
        for (NSString* ext in @[@"md", @"txt", @"py", @"epub", @"webp", @"heic", @"jxr"])
            Check(!SPDFOCRPathSupported([@"/absent/document." stringByAppendingString:ext]), ext);
        for (NSUInteger i = 0; i < sizeof(SPDFSourceFormatPairs) / sizeof(SPDFSourceFormatPairs[0]); ++i) {
            NSString* path = [@"source." stringByAppendingString:SPDFSourceFormatPairs[i].extension];
            spdf_translation_context context = {};
            context.markdownActive = SPDFIsRenderedTextDocumentPath(path);
            Check(spdf_translation_command_enabled(context), [@"whole text translation: " stringByAppendingString:path]);
            context.hasSelection = true;
            Check(spdf_translation_selection_enabled(context), [@"selection translation: " stringByAppendingString:path]);
        }
        Check(SPDFSourceDocumentCatalogBuildCount == 0, @"capability checks do no launch catalog work");
        // Real MuPDF conversion: all pages, source bytes untouched, readable PDF.
        for (NSString* name in @[@"picture.png", @"drawing.svg", @"drawing.svgz", @"book.epub", @"book.fb2",
                                @"book.mobi", @"word.docx", @"sheet.xlsx", @"slides.pptx"]) {
            NSString* path = [folder stringByAppendingPathComponent:name];
            NSData* before = [NSData dataWithContentsOfFile:path];
            NSError* error = nil;
            NSString* output = SPDFCreateToolPDF(path, @"test", &error);
            Check(output != nil, [NSString stringWithFormat:@"%@ exported: %@", name, error]);
            PDFDocument* pdf = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:output]];
            Check(pdf.pageCount > 0, [@"readable PDF: " stringByAppendingString:name]);
            Check([[NSData dataWithContentsOfFile:path] isEqual:before], @"conversion never mutates the source");
            if ([name isEqualToString:@"book.epub"] || [name isEqualToString:@"word.docx"])
                Check(pdf.string.length > 0, @"native text survives conversion for translation");
            NSData* first = [NSData dataWithContentsOfFile:output];
            NSString* second = SPDFCreateToolPDF(path, @"test", &error);
            Check(second && ![second isEqual:output] && [[NSData dataWithContentsOfFile:output] isEqual:first],
                @"existing renditions are never overwritten");
        }
        // Multipage image input must not silently OCR only its first page.
        NSString* png = [folder stringByAppendingPathComponent:@"picture.png"];
        CGImageSourceRef input = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:png], NULL);
        CGImageRef image = CGImageSourceCreateImageAtIndex(input, 0, NULL);
        NSString* tiff = [folder stringByAppendingPathComponent:@"multipage.tiff"];
        CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)[NSURL fileURLWithPath:tiff], CFSTR("public.tiff"), 2, NULL);
        CGImageDestinationAddImage(destination, image, NULL); CGImageDestinationAddImage(destination, image, NULL);
        Check(CGImageDestinationFinalize(destination), @"multipage TIFF fixture");
        CFRelease(destination); CGImageRelease(image); CFRelease(input);
        NSError* error = nil;
        NSString* output = SPDFCreateToolPDF(tiff, @"ocr", &error);
        Check(output && [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:output]].pageCount == 2,
              @"OCR rendition includes both TIFF pages");
        NSString* chosen = [folder stringByAppendingPathComponent:@"chosen-output"];
        [NSFileManager.defaultManager createDirectoryAtPath:chosen withIntermediateDirectories:YES attributes:nil error:nil];
        NSString* elsewhere = SPDFCreateToolPDF(png, @"ocr", &error, chosen);
        Check(elsewhere && [elsewhere.stringByDeletingLastPathComponent isEqual:chosen],
              @"read-only/Collection sources can write their rendition in a chosen folder");
        NSString* broken = [folder stringByAppendingPathComponent:@"broken.png"];
        [@"not an image" writeToFile:broken atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Check(!SPDFCreateToolPDF(broken, @"ocr", &error) && error, @"invalid input reports an error");
        Check(![NSFileManager.defaultManager fileExistsAtPath:[folder stringByAppendingPathComponent:@"broken-ocr.pdf"]],
              @"failed export removes its partial PDF");
        NSString* app = Read(root, @"ShenzhenPDFMac.mm");
        Check([app containsString:@"enabled:hasDoc && SPDFOCRPathSupported(_path)"] &&
              [app containsString:@"_ocrButton.enabled = hasDoc && SPDFOCRPathSupported(_path)"] &&
              [app containsString:@"if (action == @selector(ocrDocument:)) return hasDoc && SPDFOCRPathSupported(_path)"],
              @"toolbar, overflow, File menu all admit images");
        Check([app containsString:@"[self beginImageOCRWithLanguage:language displayName:displayName]"] &&
              [app containsString:@"[self beginNativeDocumentTranslation]"], @"commands route through real PDF conversion");
        Check([Read(root, @"SPDFMacMarkdownIntegration.mm") containsString:@"SPDFIsRenderedTextDocumentPath(_path)"],
              @"translation's text-session gate covers every supported source format");
        Check([Read(root, @"SPDFMacDocumentToolInputIntegration.mm") containsString:
               @"dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)"],
              @"conversion is deferred until an explicit action and leaves the UI thread free");
        printf("SPDFMacDocumentToolInputTests passed\n");
    }
    return 0;
}
