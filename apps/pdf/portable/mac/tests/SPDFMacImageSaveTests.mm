#import "SPDFMacImageSave.h"
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <PDFKit/PDFKit.h>
#include <unistd.h>

static NSString* protectedDirectory;
@interface SPDFMacCollectionStore : NSObject
+ (instancetype)defaultStore;
- (BOOL)isArchivePath:(NSString*)path;
@end
@implementation SPDFMacCollectionStore
+ (instancetype)defaultStore { static id store = [self new]; return store; }
- (BOOL)isArchivePath:(NSString*)path { return protectedDirectory && [path hasPrefix:[protectedDirectory stringByAppendingString:@"/"]]; }
@end

static void Check(BOOL condition, NSString* message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static CGImageRef TransparentImage(void) {
    unsigned char pixels[4 * 4 * 4];
    for (NSUInteger i = 0; i < sizeof(pixels); i += 4) {
        pixels[i] = 128; pixels[i+1] = 0; pixels[i+2] = 0; pixels[i+3] = 128;
    }
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, 4, 4, 8, 16, space, kCGImageAlphaPremultipliedLast);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context); CGColorSpaceRelease(space); return image;
}
static void WriteImage(NSString* path, CFStringRef type, size_t frames) {
    CGImageRef image = TransparentImage();
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], type, frames, NULL);
    for (size_t frame = 0; frame < frames; ++frame)
        CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)@{(__bridge NSString*)kCGImagePropertyTIFFDictionary:
            @{(__bridge NSString*)kCGImagePropertyTIFFImageDescription:@"Metadata retained"}});
    Check(CGImageDestinationFinalize(destination), @"image fixture writes");
    CFRelease(destination); CGImageRelease(image);
}
int main(int argc, const char* argv[]) {
    @autoreleasepool {
        Check(argc == 2, @"repository required");
        NSString* folder = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager* fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        NSError* error = nil;
        for (NSString* extension in @[@"png", @"tiff", @"gif"]) {
            NSString* source = [folder stringByAppendingPathComponent:[@"source." stringByAppendingString:extension]];
            CFStringRef type = [extension isEqual:@"png"] ? CFSTR("public.png") :
                ([extension isEqual:@"tiff"] ? CFSTR("public.tiff") : CFSTR("com.compuserve.gif"));
            WriteImage(source, type, [extension isEqual:@"png"] ? 1 : 2);
            NSString* copy = [folder stringByAppendingPathComponent:[@"copy." stringByAppendingString:extension]];
            NSData* original = [NSData dataWithContentsOfFile:source];
            Check(SPDFSaveImageCopy(source, copy, NO, &error), error.localizedDescription);
            Check([[NSData dataWithContentsOfFile:copy] isEqual:original], @"image copy preserves every byte, alpha, frames, metadata");
            Check([[NSData dataWithContentsOfFile:source] isEqual:original], @"source stays unchanged");
            NSString* pdfPath = [folder stringByAppendingPathComponent:[extension stringByAppendingPathExtension:@"pdf"]];
            Check(SPDFSaveImageCopy(source, pdfPath, YES, &error), error.localizedDescription);
            PDFDocument* pdf = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:pdfPath]];
            Check(pdf.pageCount == ([extension isEqual:@"tiff"] ? 2 : 1), @"PDF preserves all reader-visible pages");
            Check([[NSData dataWithContentsOfFile:source] isEqual:original], @"PDF conversion does not change image");
            if ([extension isEqual:@"png"]) {
                CGPDFDocumentRef document = CGPDFDocumentCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:pdfPath]);
                unsigned char pixels[20 * 20 * 4] = {};
                CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
                CGContextRef context = CGBitmapContextCreate(pixels, 20, 20, 8, 80, space, kCGImageAlphaPremultipliedLast);
                CGPDFPageRef page = CGPDFDocumentGetPage(document, 1);
                CGContextConcatCTM(context, CGPDFPageGetDrawingTransform(page, kCGPDFMediaBox, CGRectMake(0,0,20,20), 0, YES));
                CGContextDrawPDFPage(context, page);
                NSUInteger alpha = pixels[(10 * 20 + 10) * 4 + 3];
                Check(alpha > 100 && alpha < 160, @"PDF retains PNG transparency");
                CGContextRelease(context); CGColorSpaceRelease(space); CGPDFDocumentRelease(document);
            }
        }
        NSString* png = [folder stringByAppendingPathComponent:@"source.png"];
        NSData* original = [NSData dataWithContentsOfFile:png];
        Check(!SPDFSaveImageCopy(png, png, NO, &error), @"cannot overwrite source");
        NSString* alias = [folder stringByAppendingPathComponent:@"alias.png"];
        [fm createSymbolicLinkAtPath:alias withDestinationPath:png error:nil];
        Check(!SPDFSaveImageCopy(png, alias, YES, &error), @"symlink cannot overwrite source");
        NSString* hard = [folder stringByAppendingPathComponent:@"hard.png"];
        Check(link(png.fileSystemRepresentation, hard.fileSystemRepresentation) == 0, @"hard link fixture");
        Check(!SPDFSaveImageCopy(png, hard, NO, &error), @"hard link cannot overwrite source");
        [fm setAttributes:@{NSFilePosixPermissions:@0400} ofItemAtPath:png error:nil];
        NSString* writable = [folder stringByAppendingPathComponent:@"writable.png"];
        Check(SPDFSaveImageCopy(png, writable, NO, &error) &&
            [[fm attributesOfItemAtPath:writable error:nil][NSFilePosixPermissions] unsignedIntegerValue] == 0600 &&
            [[fm attributesOfItemAtPath:png error:nil][NSFilePosixPermissions] unsignedIntegerValue] == 0400,
            @"private writable copy is created without changing source permissions");
        protectedDirectory = [folder stringByAppendingPathComponent:@"archive"];
        [fm createDirectoryAtPath:protectedDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        Check(!SPDFSaveImageCopy(png, [protectedDirectory stringByAppendingPathComponent:@"copy.png"], NO, &error),
            @"worker rejects Collection destinations");
        protectedDirectory = nil;
        NSString* dereferenced = [folder stringByAppendingPathComponent:@"dereferenced.png"];
        Check(SPDFSaveImageCopy(alias, dereferenced, NO, &error) &&
            [[NSData dataWithContentsOfFile:dereferenced] isEqual:original] &&
            ![fm destinationOfSymbolicLinkAtPath:dereferenced error:nil], @"saving a symlink copies image bytes");
        NSString* invalid = [folder stringByAppendingPathComponent:@"invalid.png"];
        [@"invalid" writeToFile:invalid atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString* existing = [folder stringByAppendingPathComponent:@"existing.pdf"];
        NSData* sentinel = [@"existing destination" dataUsingEncoding:NSUTF8StringEncoding];
        [sentinel writeToFile:existing atomically:YES];
        Check(!SPDFSaveImageCopy(invalid, existing, YES, &error) &&
            [[NSData dataWithContentsOfFile:existing] isEqual:sentinel], @"failed conversion leaves destination intact");
        NSDictionary* beforeChange = SPDFImageSaveDestinationIdentity(existing);
        [@"changed externally" writeToFile:existing atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSData* changed = [NSData dataWithContentsOfFile:existing];
        Check(!SPDFSaveImageCopy(png, existing, YES, &error, beforeChange) &&
            [[NSData dataWithContentsOfFile:existing] isEqual:changed], @"changed destination is not overwritten after protection");
        NSString* appeared = [folder stringByAppendingPathComponent:@"appeared.pdf"];
        NSDictionary* absent = SPDFImageSaveDestinationIdentity(appeared);
        [sentinel writeToFile:appeared atomically:YES];
        Check(!SPDFSaveImageCopy(png, appeared, YES, &error, absent) &&
            [[NSData dataWithContentsOfFile:appeared] isEqual:sentinel], @"newly appeared destination requires a fresh confirmation");
        Check(SPDFSaveImageCopy(png, existing, YES, &error) &&
            [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:existing]].pageCount == 1,
            @"confirmed replacement installs a complete PDF");
        Check([[NSData dataWithContentsOfFile:png] isEqual:original], @"original survives every Save As path");
        for (NSString* name in [fm contentsOfDirectoryAtPath:folder error:nil])
            Check(![name hasPrefix:@".szpdf-image-"], @"no temporary outputs left behind");
        NSString* root = [@(argv[1]) stringByAppendingPathComponent:@"portable/mac"];
        NSString* app = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"ShenzhenPDFMac.mm"]
            encoding:NSUTF8StringEncoding error:nil];
        NSString* integration = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"SPDFMacImageSaveIntegration.mm"] encoding:NSUTF8StringEncoding error:nil];
        Check([integration containsString:@"if ([self saveActiveImageAs]) return;"] &&
            [app containsString:@"return markdown || (hasDoc && SPDFOCRPathSupported(_path));"], @"Save As admits and routes image tabs");
        [fm removeItemAtPath:folder error:nil];
        printf("SPDFMacImageSaveTests passed\n");
    }
    return 0;
}
