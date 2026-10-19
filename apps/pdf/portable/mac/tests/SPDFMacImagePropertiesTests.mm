#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import "../SPDFMacImageProperties.h"
#include "spdf_image_properties.h"
#include <sys/stat.h>

static int failures;
static void Check(BOOL condition, const char* label) {
    if (!condition) { fprintf(stderr, "FAIL %s\n", label); ++failures; }
}
static NSDictionary* Rows(NSString* path) {
    NSMutableDictionary* result = [NSMutableDictionary dictionary];
    for (NSDictionary* row in SPDFImagePropertyRows(path)) result[row[@"label"]] = row[@"value"];
    return result;
}
static void Fixture(NSString* path, CFStringRef type, NSDictionary* metadata, size_t frames = 1) {
    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, 48, 32, 8, 0, color, kCGImageAlphaPremultipliedLast);
    CGContextSetRGBFillColor(context, 0.2, 0.5, 0.8, 0.5);
    CGContextFillRect(context, CGRectMake(0, 0, 48, 32));
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], type, frames, NULL);
    for (size_t i = 0; i < frames; ++i) CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)metadata);
    Check(CGImageDestinationFinalize(destination), "fixture encoded");
    CFRelease(destination); CGImageRelease(image); CGContextRelease(context); CGColorSpaceRelease(color);
}
int main(void) {
    @autoreleasepool {
        NSString* temp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:temp withIntermediateDirectories:YES attributes:nil error:nil];
        NSString* png = [temp stringByAppendingPathComponent:@"sample.png"];
        Fixture(png, CFSTR("public.png"), @{(id)kCGImagePropertyDPIWidth: @144, (id)kCGImagePropertyDPIHeight: @144});
        NSDictionary* pngRows = Rows(png);
        Check([pngRows[@"Pixel dimensions"] isEqual:@"48 × 32 pixels"], "source pixels, not page points");
        Check([pngRows[@"Resolution"] containsString:@"144"], "embedded resolution");
        Check([pngRows[@"Color model"] isEqual:@"RGB"], "RGB color model");
        Check([pngRows[@"Color profile"] length] > 0, "embedded color profile");
        Check([pngRows[@"Bit depth"] isEqual:@"8 bits per component"], "component depth");
        Check([pngRows[@"Alpha channel"] isEqual:@"Yes"], "alpha metadata");
        NSString* untagged = [temp stringByAppendingPathComponent:@"untagged.png"];
        Fixture(untagged, CFSTR("public.png"), @{});
        Check(Rows(untagged)[@"Resolution"] == nil, "untagged image does not invent resolution");
        NSString* untaggedJPEG = [temp stringByAppendingPathComponent:@"untagged.jpg"];
        Fixture(untaggedJPEG, CFSTR("public.jpeg"), @{});
        Check(Rows(untaggedJPEG)[@"Resolution"] == nil, "untagged JPEG does not invent resolution");
        NSString* jpeg = [temp stringByAppendingPathComponent:@"camera.jpg"];
        Fixture(jpeg, CFSTR("public.jpeg"), @{(id)kCGImagePropertyOrientation: @6,
            (id)kCGImagePropertyTIFFDictionary: @{(id)kCGImagePropertyTIFFMake: @"Sample", (id)kCGImagePropertyTIFFModel: @"Camera"},
            (id)kCGImagePropertyExifDictionary: @{(id)kCGImagePropertyExifExposureTime: @0.008,
                (id)kCGImagePropertyExifFNumber: @2.8, (id)kCGImagePropertyExifISOSpeedRatings: @[@200],
                (id)kCGImagePropertyExifFocalLength: @35}});
        NSDictionary* cameraRows = Rows(jpeg);
        Check([cameraRows[@"Camera"] isEqual:@"Sample Camera"], "camera metadata");
        Check([cameraRows[@"Exposure"] isEqual:@"1/125 s"], "exposure metadata");
        Check([cameraRows[@"Orientation"] isEqual:@"Rotated 90° clockwise"], "EXIF orientation separate from stored pixels");
        NSString* gif = [temp stringByAppendingPathComponent:@"animated.gif"];
        Fixture(gif, CFSTR("com.compuserve.gif"), @{}, 2);
        Check([Rows(gif)[@"Frames / images"] isEqual:@"2"], "frame count");
        NSString* ppm = [temp stringByAppendingPathComponent:@"raster.ppm"];
        [@"P3\n2 1\n255\n255 0 0 0 255 0\n" writeToFile:ppm atomically:YES encoding:NSUTF8StringEncoding error:nil];
        spdf_image_properties raw = {};
        Check(spdf_read_image_properties(ppm.fileSystemRepresentation, &raw), "MuPDF header-only fallback");
        Check(raw.width == 2 && raw.height == 1 && raw.components == 3, "fallback source dimensions and components");
        Check([Rows(ppm)[@"Pixel dimensions"] isEqual:@"2 × 1 pixels"], "PNM properties");
        NSString* fifo = [temp stringByAppendingPathComponent:@"must-not-read.md"];
        mkfifo(fifo.fileSystemRepresentation, 0600);
        NSString* rasterFIFO = [temp stringByAppendingPathComponent:@"must-not-read.png"];
        mkfifo(rasterFIFO.fileSystemRepresentation, 0600);
        Check(SPDFImagePropertyRows(rasterFIFO).count == 0, "nonregular image rejected without blocking");
        Check(SPDFImagePropertyRows(fifo).count == 0, "nonimage returns without opening named pipe");
        Check(SPDFImagePropertyRows([temp stringByAppendingPathComponent:@"missing.png"]).count == 0, "missing image graceful");
        Check(!SPDFPathIsRasterImage(@"vector.svg") && !SPDFPathIsRasterImage(@"vector.svgz"), "vectors never called pixel images");
        Check(SPDFPathIsRasterImage(@"PHOTO.JPEG") && SPDFPathIsRasterImage(@"scan.jbig2"), "linked formats recognized");
        [NSFileManager.defaultManager removeItemAtPath:temp error:nil];
    }
    if (!failures) puts("All image property tests passed");
    return failures ? 1 : 0;
}
